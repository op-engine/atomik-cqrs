//! Projection runtime: named, resumable read-model projections over the event stream.
//!
//! A Projection is a named cursor: on each run it loads its checkpoint, queries
//! for events written after that position, calls the caller-supplied `apply`
//! function for each event in global_seq order, then saves the checkpoint.
//!
//! Delivery is at-least-once: if a checkpoint save fails, the batch replays on
//! the next run. `apply` must be idempotent.
//!
//! Drive projections from a scheduled task, a Cloudflare Workers Cron Trigger,
//! or inline after append_events. For cross-service fan-out, see atomik-relay.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cqrs = @import("cqrs.zig");
const event_store = @import("event_store.zig");

// ============================================================================
// CHECKPOINT STORE
// ============================================================================

/// Pluggable persistence for projection checkpoints (last processed global_seq).
/// Production: PostgresCheckpointStore (src/adapters/postgres.zig).
/// Tests / WASM: InMemoryCheckpointStore (below).
pub const CheckpointStore = struct {
    ctx: *anyopaque,
    load_fn: *const fn (ctx: *anyopaque, allocator: Allocator, name: []const u8) anyerror!u64,
    save_fn: *const fn (ctx: *anyopaque, name: []const u8, position: u64) anyerror!void,
    deinit_fn: *const fn (ctx: *anyopaque) void,

    /// Returns the last saved position for `name`, or 0 if never saved.
    pub fn load(self: *CheckpointStore, allocator: Allocator, name: []const u8) !u64 {
        return self.load_fn(self.ctx, allocator, name);
    }

    /// Persist `position` as the checkpoint for `name`.
    pub fn save(self: *CheckpointStore, name: []const u8, position: u64) !void {
        return self.save_fn(self.ctx, name, position);
    }

    pub fn deinit(self: *CheckpointStore) void {
        self.deinit_fn(self.ctx);
    }
};

// ============================================================================
// IN-MEMORY CHECKPOINT STORE
// ============================================================================

/// Hash-map backed checkpoint store. Suitable for unit tests and
/// wasm32-freestanding targets where checkpoints reset on process restart.
pub const InMemoryCheckpointStore = struct {
    allocator: Allocator,
    map: std.StringHashMap(u64),

    pub fn init(allocator: Allocator) InMemoryCheckpointStore {
        return .{ .allocator = allocator, .map = std.StringHashMap(u64).init(allocator) };
    }

    pub fn to_store(self: *InMemoryCheckpointStore) CheckpointStore {
        return .{
            .ctx = self,
            .load_fn = load_impl,
            .save_fn = save_impl,
            .deinit_fn = deinit_impl,
        };
    }

    fn load_impl(ctx: *anyopaque, allocator: Allocator, name: []const u8) anyerror!u64 {
        _ = allocator;
        const self: *InMemoryCheckpointStore = @ptrCast(@alignCast(ctx));
        return self.map.get(name) orelse 0;
    }

    fn save_impl(ctx: *anyopaque, name: []const u8, position: u64) anyerror!void {
        const self: *InMemoryCheckpointStore = @ptrCast(@alignCast(ctx));
        const gop = try self.map.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
        }
        gop.value_ptr.* = position;
    }

    fn deinit_impl(ctx: *anyopaque) void {
        const self: *InMemoryCheckpointStore = @ptrCast(@alignCast(ctx));
        var it = self.map.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.map.deinit();
    }
};

// ============================================================================
// PROJECTION
// ============================================================================

/// A named, resumable read-model projection.
///
/// `name` must be unique per projection; it is the checkpoint key.
/// `filters` selects which events to process; an empty QueryFilters receives
/// all events for the tenant in global_seq order.
/// `apply` is called once per event. Returning an error aborts the run; the
/// checkpoint does not advance past the batch that contained the failing event.
pub const Projection = struct {
    name: []const u8,
    tenant_id: cqrs.UUID,
    filters: cqrs.QueryFilters,
    apply: ApplyFn,
    ctx: *anyopaque,

    pub const ApplyFn = *const fn (ctx: *anyopaque, event: cqrs.DomainEvent) anyerror!void;
};

// ============================================================================
// PROJECTION RUNNER
// ============================================================================

/// Result of a single ProjectionRunner.run call.
pub const RunResult = struct {
    events_processed: usize,
    last_position: u64,
};

/// Drives projections against an EventStoreAdapter, resuming from checkpoints.
///
/// Thread safety: same as the underlying EventStoreAdapter and CheckpointStore;
/// safe for single-threaded callers only in this release.
pub const ProjectionRunner = struct {
    allocator: Allocator,
    store: *event_store.EventStoreAdapter,
    checkpoints: CheckpointStore,

    pub fn init(
        allocator: Allocator,
        store: *event_store.EventStoreAdapter,
        checkpoints: CheckpointStore,
    ) ProjectionRunner {
        return .{ .allocator = allocator, .store = store, .checkpoints = checkpoints };
    }

    /// Process all unprocessed events for `projection` and advance its checkpoint.
    ///
    /// Fetches events with global_seq > last checkpoint in ascending order,
    /// calls projection.apply for each, then saves the checkpoint once for the
    /// whole batch. If apply errors, the checkpoint is not saved and the batch
    /// will replay on the next run; apply must be idempotent.
    pub fn run(self: *ProjectionRunner, projection: Projection) !RunResult {
        const from = try self.checkpoints.load(self.allocator, projection.name);

        var filters = projection.filters;
        filters.after_seq = from;

        const events = try self.store.query(projection.tenant_id, filters);
        defer self.allocator.free(events);

        if (events.len == 0) return RunResult{ .events_processed = 0, .last_position = from };

        for (events) |event| {
            try projection.apply(projection.ctx, event);
        }

        const last_position = events[events.len - 1].global_seq;
        try self.checkpoints.save(projection.name, last_position);

        return RunResult{
            .events_processed = events.len,
            .last_position = last_position,
        };
    }

    pub fn deinit(self: *ProjectionRunner) void {
        self.checkpoints.deinit();
    }
};

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

// Test helper: holds both ArrayList and allocator since Zig 0.16 ArrayList
// is unmanaged (allocator passed per-operation, not stored in struct).
const Collector = struct {
    allocator: Allocator,
    seen: std.ArrayList([]const u8),

    fn init(allocator: Allocator) Collector {
        return .{ .allocator = allocator, .seen = .empty };
    }

    fn deinit(self: *Collector) void {
        self.seen.deinit(self.allocator);
    }
};

fn collectEventTypes(ctx: *anyopaque, event: cqrs.DomainEvent) anyerror!void {
    const col: *Collector = @ptrCast(@alignCast(ctx));
    try col.seen.append(col.allocator, event.event_type);
}

test "ProjectionRunner processes new events and advances checkpoint" {
    var mem_store = event_store.InMemoryStore.init(testing.allocator);
    var adapter = mem_store.to_adapter();
    defer adapter.deinit();

    var cp_store = InMemoryCheckpointStore.init(testing.allocator);
    const checkpoints = cp_store.to_store();

    var runner = ProjectionRunner.init(testing.allocator, &adapter, checkpoints);
    defer runner.deinit();

    const tenant_id = cqrs.generate_uuid();
    const aggregate_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = aggregate_id, .aggregate_type = "Order", .event_type = "OrderCreated", .tenant_id = tenant_id, .version = 1, .timestamp = 1, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = aggregate_id, .aggregate_type = "Order", .event_type = "OrderShipped", .tenant_id = tenant_id, .version = 2, .timestamp = 2, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });

    var col = Collector.init(testing.allocator);
    defer col.deinit();

    const proj = Projection{
        .name = "order-summary",
        .tenant_id = tenant_id,
        .filters = .{},
        .apply = collectEventTypes,
        .ctx = &col,
    };

    const result = try runner.run(proj);
    try testing.expectEqual(@as(usize, 2), result.events_processed);
    try testing.expectEqual(@as(usize, 2), col.seen.items.len);
    try testing.expectEqualStrings("OrderCreated", col.seen.items[0]);
    try testing.expectEqualStrings("OrderShipped", col.seen.items[1]);
}

test "ProjectionRunner resumes from checkpoint on subsequent run" {
    var mem_store = event_store.InMemoryStore.init(testing.allocator);
    var adapter = mem_store.to_adapter();
    defer adapter.deinit();

    var cp_store = InMemoryCheckpointStore.init(testing.allocator);
    const checkpoints = cp_store.to_store();

    var runner = ProjectionRunner.init(testing.allocator, &adapter, checkpoints);
    defer runner.deinit();

    const tenant_id = cqrs.generate_uuid();
    const aggregate_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = aggregate_id, .aggregate_type = "Order", .event_type = "OrderCreated", .tenant_id = tenant_id, .version = 1, .timestamp = 1, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = aggregate_id, .aggregate_type = "Order", .event_type = "OrderShipped", .tenant_id = tenant_id, .version = 2, .timestamp = 2, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });

    var col = Collector.init(testing.allocator);
    defer col.deinit();

    const proj = Projection{
        .name = "order-summary",
        .tenant_id = tenant_id,
        .filters = .{},
        .apply = collectEventTypes,
        .ctx = &col,
    };

    // First run: processes both events.
    const first = try runner.run(proj);
    try testing.expectEqual(@as(usize, 2), first.events_processed);

    // Second run: checkpoint is at the end, nothing to process.
    const second = try runner.run(proj);
    try testing.expectEqual(@as(usize, 0), second.events_processed);
    try testing.expectEqual(@as(usize, 2), col.seen.items.len);

    // Append a new event then run again.
    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = aggregate_id, .aggregate_type = "Order", .event_type = "OrderCancelled", .tenant_id = tenant_id, .version = 3, .timestamp = 3, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });

    const third = try runner.run(proj);
    try testing.expectEqual(@as(usize, 1), third.events_processed);
    try testing.expectEqual(@as(usize, 3), col.seen.items.len);
    try testing.expectEqualStrings("OrderCancelled", col.seen.items[2]);
}

test "ProjectionRunner filters by aggregate_type" {
    var mem_store = event_store.InMemoryStore.init(testing.allocator);
    var adapter = mem_store.to_adapter();
    defer adapter.deinit();

    var cp_store = InMemoryCheckpointStore.init(testing.allocator);
    const checkpoints = cp_store.to_store();

    var runner = ProjectionRunner.init(testing.allocator, &adapter, checkpoints);
    defer runner.deinit();

    const tenant_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "OrderCreated", .tenant_id = tenant_id, .version = 1, .timestamp = 1, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Invoice", .event_type = "InvoiceIssued", .tenant_id = tenant_id, .version = 1, .timestamp = 2, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });

    var col = Collector.init(testing.allocator);
    defer col.deinit();

    const result = try runner.run(Projection{
        .name = "invoice-projection",
        .tenant_id = tenant_id,
        .filters = .{ .aggregate_type = "Invoice" },
        .apply = collectEventTypes,
        .ctx = &col,
    });

    try testing.expectEqual(@as(usize, 1), result.events_processed);
    try testing.expectEqualStrings("InvoiceIssued", col.seen.items[0]);
}

test "ProjectionRunner does not advance checkpoint when apply errors" {
    var mem_store = event_store.InMemoryStore.init(testing.allocator);
    var adapter = mem_store.to_adapter();
    defer adapter.deinit();

    var cp_store = InMemoryCheckpointStore.init(testing.allocator);
    const checkpoints = cp_store.to_store();

    var runner = ProjectionRunner.init(testing.allocator, &adapter, checkpoints);

    const tenant_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "OrderCreated", .tenant_id = tenant_id, .version = 1, .timestamp = 1, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });

    const proj = Projection{
        .name = "failing-projection",
        .tenant_id = tenant_id,
        .filters = .{},
        .apply = struct {
            fn apply(_: *anyopaque, _: cqrs.DomainEvent) anyerror!void {
                return error.ApplyFailed;
            }
        }.apply,
        .ctx = undefined,
    };

    try testing.expectError(error.ApplyFailed, runner.run(proj));

    // The checkpoint must still be 0: the batch errored before save was called.
    const pos = cp_store.map.get("failing-projection") orelse 0;
    try testing.expectEqual(@as(u64, 0), pos);

    runner.deinit();
}
