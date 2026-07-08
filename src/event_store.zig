//! Generic event-store adapter interface. Implementations (Postgres, MySQL,
//! SQLite, or an in-memory test double) plug in here; this module has no
//! opinion on the underlying storage engine or the application's domain.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cqrs = @import("cqrs.zig");

pub const EventStoreError = error{
    AdapterNotInitialized,
    OperationFailed,
    SchemaCreationFailed,
    OptimisticConcurrencyConflict,
};

/// Abstract event-store adapter. Implementations provide concrete storage
/// operations and convert themselves to this vtable-style interface via a
/// `to_adapter()` method (see adapters/postgres.zig for an example).
pub const EventStoreAdapter = struct {
    allocator: Allocator,
    context: *anyopaque,

    create_schema_fn: *const fn (ctx: *anyopaque) anyerror!void,
    append_events_fn: *const fn (ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, events: []const cqrs.DomainEvent) anyerror!void,
    /// `after_version = 0` returns all events (versions start at 1).
    /// Pass a snapshot's version to skip already-replayed events.
    get_events_fn: *const fn (ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, aggregate_id: cqrs.UUID, aggregate_type: []const u8, after_version: u32) anyerror![]cqrs.DomainEvent,
    query_fn: *const fn (ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, filters: cqrs.QueryFilters) anyerror![]cqrs.DomainEvent,
    find_by_idempotency_key_fn: *const fn (ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, key: []const u8) anyerror!?cqrs.IdempotencyResult,
    store_idempotency_fn: *const fn (ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, key: []const u8, result: cqrs.IdempotencyResult) anyerror!void,
    deinit_fn: *const fn (ctx: *anyopaque) void,

    pub fn create_schema(self: *EventStoreAdapter) !void {
        return self.create_schema_fn(self.context);
    }

    pub fn append_events(self: *EventStoreAdapter, tenant_id: cqrs.UUID, events: []const cqrs.DomainEvent) !void {
        return self.append_events_fn(self.context, self.allocator, tenant_id, events);
    }

    /// Returns events for an aggregate in version-ascending order.
    /// Pass `after_version = 0` to load the full history.
    /// Pass a snapshot's `.version` to skip events that are already captured
    /// in the snapshot — only events at version > after_version are returned.
    pub fn get_events(self: *EventStoreAdapter, tenant_id: cqrs.UUID, aggregate_id: cqrs.UUID, aggregate_type: []const u8, after_version: u32) ![]cqrs.DomainEvent {
        return self.get_events_fn(self.context, self.allocator, tenant_id, aggregate_id, aggregate_type, after_version);
    }

    pub fn query(self: *EventStoreAdapter, tenant_id: cqrs.UUID, filters: cqrs.QueryFilters) ![]cqrs.DomainEvent {
        return self.query_fn(self.context, self.allocator, tenant_id, filters);
    }

    pub fn find_by_idempotency_key(self: *EventStoreAdapter, tenant_id: cqrs.UUID, key: []const u8) !?cqrs.IdempotencyResult {
        return self.find_by_idempotency_key_fn(self.context, self.allocator, tenant_id, key);
    }

    pub fn store_idempotency(self: *EventStoreAdapter, tenant_id: cqrs.UUID, key: []const u8, result: cqrs.IdempotencyResult) !void {
        return self.store_idempotency_fn(self.context, self.allocator, tenant_id, key, result);
    }

    pub fn deinit(self: *EventStoreAdapter) void {
        self.deinit_fn(self.context);
    }
};

// ============================================================================
// IN-MEMORY STORE (public; useful for tests and wasm32-freestanding targets)
// ============================================================================

/// A non-persistent EventStoreAdapter backed by ArrayLists. Suitable for
/// unit tests and the WASM edge harness. Assigns monotonically increasing
/// global_seq values starting at 1 so projections work correctly in tests.
/// Idempotency uses first-write-wins semantics matching the PostgreSQL adapter.
pub const InMemoryStore = struct {
    allocator: Allocator,
    events: std.ArrayList(cqrs.DomainEvent),
    next_seq: u64,
    idempotency: std.StringHashMap(cqrs.IdempotencyResult),

    pub fn init(allocator: Allocator) InMemoryStore {
        return .{
            .allocator = allocator,
            .events = .empty,
            .next_seq = 1,
            .idempotency = std.StringHashMap(cqrs.IdempotencyResult).init(allocator),
        };
    }

    pub fn to_adapter(self: *InMemoryStore) EventStoreAdapter {
        return .{
            .allocator = self.allocator,
            .context = self,
            .create_schema_fn = create_schema_impl,
            .append_events_fn = append_events_impl,
            .get_events_fn = get_events_impl,
            .query_fn = query_impl,
            .find_by_idempotency_key_fn = find_by_idempotency_key_impl,
            .store_idempotency_fn = store_idempotency_impl,
            .deinit_fn = deinit_impl,
        };
    }

    fn create_schema_impl(ctx: *anyopaque) anyerror!void {
        _ = ctx;
    }

    fn append_events_impl(ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, events: []const cqrs.DomainEvent) anyerror!void {
        _ = allocator;
        _ = tenant_id;
        const self: *InMemoryStore = @ptrCast(@alignCast(ctx));
        // Validate the whole batch before writing anything — same atomicity
        // guarantee as the PostgreSQL UNIQUE INDEX on (tenant_id, aggregate_id, version).
        for (events) |incoming| {
            for (self.events.items) |stored| {
                if (!std.mem.eql(u8, &stored.tenant_id, &incoming.tenant_id)) continue;
                if (!std.mem.eql(u8, &stored.aggregate_id, &incoming.aggregate_id)) continue;
                if (stored.version == incoming.version) return error.OptimisticConcurrencyConflict;
            }
        }
        for (events) |event| {
            var e = event;
            e.global_seq = self.next_seq;
            self.next_seq += 1;
            try self.events.append(self.allocator, e);
        }
    }

    fn get_events_impl(ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, aggregate_id: cqrs.UUID, aggregate_type: []const u8, after_version: u32) anyerror![]cqrs.DomainEvent {
        const self: *InMemoryStore = @ptrCast(@alignCast(ctx));
        var out: std.ArrayList(cqrs.DomainEvent) = .empty;
        for (self.events.items) |event| {
            if (!std.mem.eql(u8, &event.tenant_id, &tenant_id)) continue;
            if (!std.mem.eql(u8, &event.aggregate_id, &aggregate_id)) continue;
            if (!std.mem.eql(u8, event.aggregate_type, aggregate_type)) continue;
            if (event.version <= after_version) continue;
            try out.append(allocator, event);
        }
        // Sort by version ascending so load_from_history replays correctly
        // even when events were appended out of order.
        std.mem.sort(cqrs.DomainEvent, out.items, {}, struct {
            fn cmp(_: void, a: cqrs.DomainEvent, b: cqrs.DomainEvent) bool {
                return a.version < b.version;
            }
        }.cmp);
        return out.toOwnedSlice(allocator);
    }

    fn query_impl(ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, filters: cqrs.QueryFilters) anyerror![]cqrs.DomainEvent {
        const self: *InMemoryStore = @ptrCast(@alignCast(ctx));
        var out: std.ArrayList(cqrs.DomainEvent) = .empty;
        for (self.events.items) |event| {
            if (!std.mem.eql(u8, &event.tenant_id, &tenant_id)) continue;
            if (filters.after_seq) |seq| {
                if (event.global_seq <= seq) continue;
            }
            if (filters.aggregate_type) |at| {
                if (!std.mem.eql(u8, event.aggregate_type, at)) continue;
            }
            if (filters.event_type) |et| {
                if (!std.mem.eql(u8, event.event_type, et)) continue;
            }
            if (filters.start_time) |st| {
                if (event.timestamp < st) continue;
            }
            if (filters.end_time) |et| {
                if (event.timestamp > et) continue;
            }
            try out.append(allocator, event);
            if (filters.limit) |limit| {
                if (out.items.len >= limit) break;
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn find_by_idempotency_key_impl(ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, key: []const u8) anyerror!?cqrs.IdempotencyResult {
        _ = tenant_id;
        const self: *InMemoryStore = @ptrCast(@alignCast(ctx));
        const stored = self.idempotency.get(key) orelse return null;
        return cqrs.IdempotencyResult{
            .command_type = try allocator.dupe(u8, stored.command_type),
            .result = try allocator.dupe(u8, stored.result),
            .created_at = stored.created_at,
        };
    }

    fn store_idempotency_impl(ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, key: []const u8, result: cqrs.IdempotencyResult) anyerror!void {
        _ = allocator;
        _ = tenant_id;
        const self: *InMemoryStore = @ptrCast(@alignCast(ctx));
        // First write wins: matches ON CONFLICT DO NOTHING semantics of the
        // PostgreSQL adapter. Callers may retry with the same key safely.
        if (self.idempotency.contains(key)) return;
        const key_dupe = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_dupe);
        const ct_dupe = try self.allocator.dupe(u8, result.command_type);
        errdefer self.allocator.free(ct_dupe);
        const r_dupe = try self.allocator.dupe(u8, result.result);
        errdefer self.allocator.free(r_dupe);
        try self.idempotency.put(key_dupe, cqrs.IdempotencyResult{
            .command_type = ct_dupe,
            .result = r_dupe,
            .created_at = result.created_at,
        });
    }

    fn deinit_impl(ctx: *anyopaque) void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ctx));
        self.events.deinit(self.allocator);
        var it = self.idempotency.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.command_type);
            self.allocator.free(entry.value_ptr.result);
        }
        self.idempotency.deinit();
    }
};

// ============================================================================
// SNAPSHOT STORE INTERFACE
// ============================================================================

/// Vtable for loading and persisting aggregate snapshots. Decoupled from
/// EventStoreAdapter so snapshots can be stored in a different backend
/// (e.g., object storage, a separate table, or just in-memory for tests).
pub const SnapshotStore = struct {
    allocator: Allocator,
    context: *anyopaque,

    /// Returns the latest snapshot for the aggregate, or null if none exists.
    /// Caller owns all strings in the returned Snapshot.
    load_fn: *const fn (ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, aggregate_id: cqrs.UUID, aggregate_type: []const u8) anyerror!?cqrs.Snapshot,
    /// Persist a snapshot. Replaces any existing snapshot for the same
    /// (tenant_id, aggregate_id) pair — only the latest version is kept.
    save_fn: *const fn (ctx: *anyopaque, tenant_id: cqrs.UUID, snapshot: cqrs.Snapshot) anyerror!void,
    deinit_fn: *const fn (ctx: *anyopaque) void,

    pub fn load(self: *SnapshotStore, tenant_id: cqrs.UUID, aggregate_id: cqrs.UUID, aggregate_type: []const u8) !?cqrs.Snapshot {
        return self.load_fn(self.context, self.allocator, tenant_id, aggregate_id, aggregate_type);
    }

    pub fn save(self: *SnapshotStore, tenant_id: cqrs.UUID, snapshot: cqrs.Snapshot) !void {
        return self.save_fn(self.context, tenant_id, snapshot);
    }

    pub fn deinit(self: *SnapshotStore) void {
        self.deinit_fn(self.context);
    }
};

/// In-memory SnapshotStore backed by an ArrayList. Keeps at most one snapshot
/// per (tenant_id, aggregate_id) pair; a newer save replaces the older entry.
/// For tests and the WASM edge harness only — snapshots are not persisted across
/// restarts.
pub const InMemorySnapshotStore = struct {
    allocator: Allocator,
    entries: std.ArrayList(Entry),

    const Entry = struct {
        tenant_id: cqrs.UUID,
        aggregate_id: cqrs.UUID,
        /// All slice fields below are owned by the InMemorySnapshotStore's allocator.
        aggregate_type: []const u8,
        state: []const u8,
        version: u32,
        created_at: i64,
    };

    pub fn init(allocator: Allocator) InMemorySnapshotStore {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn to_store(self: *InMemorySnapshotStore) SnapshotStore {
        return .{
            .allocator = self.allocator,
            .context = self,
            .load_fn = load_impl,
            .save_fn = save_impl,
            .deinit_fn = deinit_impl,
        };
    }

    fn load_impl(ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, aggregate_id: cqrs.UUID, aggregate_type: []const u8) anyerror!?cqrs.Snapshot {
        const self: *InMemorySnapshotStore = @ptrCast(@alignCast(ctx));
        // Return the entry with the highest version for this aggregate.
        var best: ?*const Entry = null;
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, &entry.tenant_id, &tenant_id)) continue;
            if (!std.mem.eql(u8, &entry.aggregate_id, &aggregate_id)) continue;
            if (!std.mem.eql(u8, entry.aggregate_type, aggregate_type)) continue;
            if (best == null or entry.version > best.?.version) best = entry;
        }
        const e = best orelse return null;
        return cqrs.Snapshot{
            .aggregate_id = e.aggregate_id,
            .aggregate_type = try allocator.dupe(u8, e.aggregate_type),
            .version = e.version,
            .state = try allocator.dupe(u8, e.state),
            .created_at = e.created_at,
        };
    }

    fn save_impl(ctx: *anyopaque, tenant_id: cqrs.UUID, snapshot: cqrs.Snapshot) anyerror!void {
        const self: *InMemorySnapshotStore = @ptrCast(@alignCast(ctx));
        // Replace existing entry for this aggregate, or append a new one.
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, &entry.tenant_id, &tenant_id)) continue;
            if (!std.mem.eql(u8, &entry.aggregate_id, &snapshot.aggregate_id)) continue;
            // Free old owned strings before overwriting.
            self.allocator.free(entry.aggregate_type);
            self.allocator.free(entry.state);
            entry.aggregate_type = try self.allocator.dupe(u8, snapshot.aggregate_type);
            entry.state = try self.allocator.dupe(u8, snapshot.state);
            entry.version = snapshot.version;
            entry.created_at = snapshot.created_at;
            return;
        }
        // No existing entry — append a new one.
        try self.entries.append(self.allocator, .{
            .tenant_id = tenant_id,
            .aggregate_id = snapshot.aggregate_id,
            .aggregate_type = try self.allocator.dupe(u8, snapshot.aggregate_type),
            .state = try self.allocator.dupe(u8, snapshot.state),
            .version = snapshot.version,
            .created_at = snapshot.created_at,
        });
    }

    fn deinit_impl(ctx: *anyopaque) void {
        const self: *InMemorySnapshotStore = @ptrCast(@alignCast(ctx));
        for (self.entries.items) |entry| {
            self.allocator.free(entry.aggregate_type);
            self.allocator.free(entry.state);
        }
        self.entries.deinit(self.allocator);
    }
};

test "event store adapter appends and retrieves events for an aggregate" {
    var store = InMemoryStore.init(std.testing.allocator);
    var adapter = store.to_adapter();
    defer adapter.deinit();

    const tenant_id = cqrs.generate_uuid();
    const aggregate_id = cqrs.generate_uuid();

    const event = cqrs.DomainEvent{
        .event_id = cqrs.generate_uuid(),
        .aggregate_id = aggregate_id,
        .aggregate_type = "Widget",
        .event_type = "WidgetCreated",
        .tenant_id = tenant_id,
        .version = 1,
        .timestamp = 0,
        .user_id = cqrs.generate_uuid(),
        .data = "{}",
    };

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{event});

    const events = try adapter.get_events(tenant_id, aggregate_id, "Widget", 0);
    defer std.testing.allocator.free(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("WidgetCreated", events[0].event_type);
}

test "event store adapter query filters by aggregate_type" {
    var store = InMemoryStore.init(std.testing.allocator);
    var adapter = store.to_adapter();
    defer adapter.deinit();

    const tenant_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        .{
            .event_id = cqrs.generate_uuid(),
            .aggregate_id = cqrs.generate_uuid(),
            .aggregate_type = "Widget",
            .event_type = "WidgetCreated",
            .tenant_id = tenant_id,
            .version = 1,
            .timestamp = 0,
            .user_id = cqrs.generate_uuid(),
            .data = "{}",
        },
        .{
            .event_id = cqrs.generate_uuid(),
            .aggregate_id = cqrs.generate_uuid(),
            .aggregate_type = "Gadget",
            .event_type = "GadgetCreated",
            .tenant_id = tenant_id,
            .version = 1,
            .timestamp = 0,
            .user_id = cqrs.generate_uuid(),
            .data = "{}",
        },
    });

    const events = try adapter.query(tenant_id, .{ .aggregate_type = "Widget" });
    defer std.testing.allocator.free(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("Widget", events[0].aggregate_type);
}

test "event store adapter enforces tenant isolation" {
    var store = InMemoryStore.init(std.testing.allocator);
    var adapter = store.to_adapter();
    defer adapter.deinit();

    const tenant_a = cqrs.generate_uuid();
    const tenant_b = cqrs.generate_uuid();
    const agg_a = cqrs.generate_uuid();
    const agg_b = cqrs.generate_uuid();

    try adapter.append_events(tenant_a, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = agg_a, .aggregate_type = "Order", .event_type = "OrderCreated", .tenant_id = tenant_a, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });
    try adapter.append_events(tenant_b, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = agg_b, .aggregate_type = "Order", .event_type = "OrderCreated", .tenant_id = tenant_b, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });

    const a_events = try adapter.get_events(tenant_a, agg_a, "Order", 0);
    defer std.testing.allocator.free(a_events);
    try std.testing.expectEqual(@as(usize, 1), a_events.len);

    // Tenant A must not see tenant B's aggregate even with the same aggregate type.
    const cross_tenant = try adapter.get_events(tenant_a, agg_b, "Order", 0);
    defer std.testing.allocator.free(cross_tenant);
    try std.testing.expectEqual(@as(usize, 0), cross_tenant.len);

    // query() is also scoped: each tenant sees only its own events.
    const a_query = try adapter.query(tenant_a, .{});
    defer std.testing.allocator.free(a_query);
    try std.testing.expectEqual(@as(usize, 1), a_query.len);

    const b_query = try adapter.query(tenant_b, .{});
    defer std.testing.allocator.free(b_query);
    try std.testing.expectEqual(@as(usize, 1), b_query.len);
}

test "event store adapter get_events returns events in version ascending order" {
    var store = InMemoryStore.init(std.testing.allocator);
    var adapter = store.to_adapter();
    defer adapter.deinit();

    const tenant_id = cqrs.generate_uuid();
    const agg_id = cqrs.generate_uuid();

    // Append in reverse version order to prove get_events sorts them.
    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = agg_id, .aggregate_type = "Order", .event_type = "OrderShipped", .tenant_id = tenant_id, .version = 3, .timestamp = 3, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = agg_id, .aggregate_type = "Order", .event_type = "OrderCreated", .tenant_id = tenant_id, .version = 1, .timestamp = 1, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = agg_id, .aggregate_type = "Order", .event_type = "OrderConfirmed", .tenant_id = tenant_id, .version = 2, .timestamp = 2, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });

    const events = try adapter.get_events(tenant_id, agg_id, "Order", 0);
    defer std.testing.allocator.free(events);

    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(@as(u32, 1), events[0].version);
    try std.testing.expectEqual(@as(u32, 2), events[1].version);
    try std.testing.expectEqual(@as(u32, 3), events[2].version);
}

test "event store adapter query filters by event_type" {
    var store = InMemoryStore.init(std.testing.allocator);
    var adapter = store.to_adapter();
    defer adapter.deinit();

    const tenant_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "OrderCreated", .tenant_id = tenant_id, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "OrderShipped", .tenant_id = tenant_id, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "OrderCreated", .tenant_id = tenant_id, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });

    const events = try adapter.query(tenant_id, .{ .event_type = "OrderCreated" });
    defer std.testing.allocator.free(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    for (events) |e| try std.testing.expectEqualStrings("OrderCreated", e.event_type);
}

test "event store adapter query filters by time range" {
    var store = InMemoryStore.init(std.testing.allocator);
    var adapter = store.to_adapter();
    defer adapter.deinit();

    const tenant_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "E1", .tenant_id = tenant_id, .version = 1, .timestamp = 100, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "E2", .tenant_id = tenant_id, .version = 1, .timestamp = 200, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "E3", .tenant_id = tenant_id, .version = 1, .timestamp = 300, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });

    const events = try adapter.query(tenant_id, .{ .start_time = 150, .end_time = 250 });
    defer std.testing.allocator.free(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("E2", events[0].event_type);
}

test "event store adapter query respects limit" {
    var store = InMemoryStore.init(std.testing.allocator);
    var adapter = store.to_adapter();
    defer adapter.deinit();

    const tenant_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "E1", .tenant_id = tenant_id, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "E2", .tenant_id = tenant_id, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "E3", .tenant_id = tenant_id, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });

    const events = try adapter.query(tenant_id, .{ .limit = 2 });
    defer std.testing.allocator.free(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
}

test "event store adapter query filters events after sequence position" {
    var store = InMemoryStore.init(std.testing.allocator);
    var adapter = store.to_adapter();
    defer adapter.deinit();

    const tenant_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "E1", .tenant_id = tenant_id, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "E2", .tenant_id = tenant_id, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = cqrs.generate_uuid(), .aggregate_type = "Order", .event_type = "E3", .tenant_id = tenant_id, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });

    // global_seq values 1, 2, 3 are assigned in order. after_seq=1 returns E2 and E3.
    const events = try adapter.query(tenant_id, .{ .after_seq = 1 });
    defer std.testing.allocator.free(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("E2", events[0].event_type);
    try std.testing.expectEqualStrings("E3", events[1].event_type);
}

test "event store adapter idempotency stores and retrieves result" {
    var store = InMemoryStore.init(std.testing.allocator);
    var adapter = store.to_adapter();
    defer adapter.deinit();

    const tenant_id = cqrs.generate_uuid();
    const key = "cmd-abc-123";

    const not_found = try adapter.find_by_idempotency_key(tenant_id, key);
    try std.testing.expectEqual(@as(?cqrs.IdempotencyResult, null), not_found);

    try adapter.store_idempotency(tenant_id, key, cqrs.IdempotencyResult{
        .command_type = "CreateOrder",
        .result = "{\"order_id\":\"x\"}",
        .created_at = 1234567890,
    });

    const found = try adapter.find_by_idempotency_key(tenant_id, key);
    try std.testing.expect(found != null);
    defer {
        if (found) |r| {
            std.testing.allocator.free(r.command_type);
            std.testing.allocator.free(r.result);
        }
    }
    try std.testing.expectEqualStrings("CreateOrder", found.?.command_type);
    try std.testing.expectEqualStrings("{\"order_id\":\"x\"}", found.?.result);
    try std.testing.expectEqual(@as(i64, 1234567890), found.?.created_at);
}

test "event store adapter idempotency first write wins on duplicate key" {
    var store = InMemoryStore.init(std.testing.allocator);
    var adapter = store.to_adapter();
    defer adapter.deinit();

    const tenant_id = cqrs.generate_uuid();
    const key = "idempotency-key";

    try adapter.store_idempotency(tenant_id, key, cqrs.IdempotencyResult{
        .command_type = "CreateOrder",
        .result = "{\"order_id\":\"first\"}",
        .created_at = 1,
    });
    try adapter.store_idempotency(tenant_id, key, cqrs.IdempotencyResult{
        .command_type = "CreateOrder",
        .result = "{\"order_id\":\"second\"}",
        .created_at = 2,
    });

    const found = try adapter.find_by_idempotency_key(tenant_id, key);
    try std.testing.expect(found != null);
    defer {
        if (found) |r| {
            std.testing.allocator.free(r.command_type);
            std.testing.allocator.free(r.result);
        }
    }
    try std.testing.expectEqualStrings("{\"order_id\":\"first\"}", found.?.result);
}

test "event store adapter enforces OCC: duplicate version returns OptimisticConcurrencyConflict" {
    var store = InMemoryStore.init(std.testing.allocator);
    var adapter = store.to_adapter();
    defer adapter.deinit();

    const tenant_id = cqrs.generate_uuid();
    const agg_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = agg_id, .aggregate_type = "Order", .event_type = "OrderCreated", .tenant_id = tenant_id, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });

    try std.testing.expectError(
        error.OptimisticConcurrencyConflict,
        adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
            .{ .event_id = cqrs.generate_uuid(), .aggregate_id = agg_id, .aggregate_type = "Order", .event_type = "OrderCreated", .tenant_id = tenant_id, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
        }),
    );
}

test "event store adapter get_events respects after_version for snapshot optimization" {
    var store = InMemoryStore.init(std.testing.allocator);
    var adapter = store.to_adapter();
    defer adapter.deinit();

    const tenant_id = cqrs.generate_uuid();
    const agg_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = agg_id, .aggregate_type = "Order", .event_type = "OrderCreated", .tenant_id = tenant_id, .version = 1, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = agg_id, .aggregate_type = "Order", .event_type = "OrderConfirmed", .tenant_id = tenant_id, .version = 2, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
        .{ .event_id = cqrs.generate_uuid(), .aggregate_id = agg_id, .aggregate_type = "Order", .event_type = "OrderShipped", .tenant_id = tenant_id, .version = 3, .timestamp = 0, .user_id = cqrs.generate_uuid(), .data = "{}" },
    });

    // A snapshot at version 2 means we only need to replay version 3 onwards.
    const events = try adapter.get_events(tenant_id, agg_id, "Order", 2);
    defer std.testing.allocator.free(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("OrderShipped", events[0].event_type);
    try std.testing.expectEqual(@as(u32, 3), events[0].version);
}

test "InMemorySnapshotStore saves and loads snapshot" {
    var snap_store_impl = InMemorySnapshotStore.init(std.testing.allocator);
    var snap_store = snap_store_impl.to_store();
    defer snap_store.deinit();

    const tenant_id = cqrs.generate_uuid();
    const agg_id = cqrs.generate_uuid();

    const missing = try snap_store.load(tenant_id, agg_id, "Order");
    try std.testing.expectEqual(@as(?cqrs.Snapshot, null), missing);

    try snap_store.save(tenant_id, cqrs.Snapshot{
        .aggregate_id = agg_id,
        .aggregate_type = "Order",
        .version = 5,
        .state = "{\"total\":100}",
        .created_at = 1000,
    });

    const found = try snap_store.load(tenant_id, agg_id, "Order");
    try std.testing.expect(found != null);
    defer {
        if (found) |s| {
            std.testing.allocator.free(s.aggregate_type);
            std.testing.allocator.free(s.state);
        }
    }
    try std.testing.expectEqual(@as(u32, 5), found.?.version);
    try std.testing.expectEqualStrings("{\"total\":100}", found.?.state);
}

test "InMemorySnapshotStore save replaces existing snapshot for same aggregate" {
    var snap_store_impl = InMemorySnapshotStore.init(std.testing.allocator);
    var snap_store = snap_store_impl.to_store();
    defer snap_store.deinit();

    const tenant_id = cqrs.generate_uuid();
    const agg_id = cqrs.generate_uuid();

    try snap_store.save(tenant_id, cqrs.Snapshot{
        .aggregate_id = agg_id,
        .aggregate_type = "Order",
        .version = 5,
        .state = "{\"total\":100}",
        .created_at = 1000,
    });
    // Save a newer snapshot — should replace, not accumulate.
    try snap_store.save(tenant_id, cqrs.Snapshot{
        .aggregate_id = agg_id,
        .aggregate_type = "Order",
        .version = 10,
        .state = "{\"total\":250}",
        .created_at = 2000,
    });

    const found = try snap_store.load(tenant_id, agg_id, "Order");
    try std.testing.expect(found != null);
    defer {
        if (found) |s| {
            std.testing.allocator.free(s.aggregate_type);
            std.testing.allocator.free(s.state);
        }
    }
    try std.testing.expectEqual(@as(u32, 10), found.?.version);
    try std.testing.expectEqualStrings("{\"total\":250}", found.?.state);
}
