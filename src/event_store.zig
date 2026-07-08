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
};

/// Abstract event-store adapter. Implementations provide concrete storage
/// operations and convert themselves to this vtable-style interface via a
/// `to_adapter()` method (see adapters/postgres.zig for an example).
pub const EventStoreAdapter = struct {
    allocator: Allocator,
    context: *anyopaque,

    create_schema_fn: *const fn (ctx: *anyopaque) anyerror!void,
    append_events_fn: *const fn (ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, events: []const cqrs.DomainEvent) anyerror!void,
    get_events_fn: *const fn (ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, aggregate_id: cqrs.UUID, aggregate_type: []const u8) anyerror![]cqrs.DomainEvent,
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

    pub fn get_events(self: *EventStoreAdapter, tenant_id: cqrs.UUID, aggregate_id: cqrs.UUID, aggregate_type: []const u8) ![]cqrs.DomainEvent {
        return self.get_events_fn(self.context, self.allocator, tenant_id, aggregate_id, aggregate_type);
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
// TESTS
// ============================================================================
// A minimal in-memory adapter, used only to exercise the EventStoreAdapter
// vtable shape. Real backends live under adapters/.

const InMemoryStore = struct {
    allocator: Allocator,
    events: std.ArrayList(cqrs.DomainEvent),

    fn init(allocator: Allocator) InMemoryStore {
        return .{ .allocator = allocator, .events = .empty };
    }

    fn to_adapter(self: *InMemoryStore) EventStoreAdapter {
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
        for (events) |event| try self.events.append(self.allocator, event);
    }

    fn get_events_impl(ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, aggregate_id: cqrs.UUID, aggregate_type: []const u8) anyerror![]cqrs.DomainEvent {
        _ = tenant_id;
        _ = aggregate_type;
        const self: *InMemoryStore = @ptrCast(@alignCast(ctx));
        var out: std.ArrayList(cqrs.DomainEvent) = .empty;
        for (self.events.items) |event| {
            if (std.mem.eql(u8, &event.aggregate_id, &aggregate_id)) try out.append(allocator, event);
        }
        return out.toOwnedSlice(allocator);
    }

    fn query_impl(ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, filters: cqrs.QueryFilters) anyerror![]cqrs.DomainEvent {
        _ = tenant_id;
        const self: *InMemoryStore = @ptrCast(@alignCast(ctx));
        var out: std.ArrayList(cqrs.DomainEvent) = .empty;
        for (self.events.items) |event| {
            if (filters.aggregate_type) |at| {
                if (!std.mem.eql(u8, event.aggregate_type, at)) continue;
            }
            try out.append(allocator, event);
        }
        return out.toOwnedSlice(allocator);
    }

    fn find_by_idempotency_key_impl(ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, key: []const u8) anyerror!?cqrs.IdempotencyResult {
        _ = ctx;
        _ = allocator;
        _ = tenant_id;
        _ = key;
        return null;
    }

    fn store_idempotency_impl(ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, key: []const u8, result: cqrs.IdempotencyResult) anyerror!void {
        _ = ctx;
        _ = allocator;
        _ = tenant_id;
        _ = key;
        _ = result;
    }

    fn deinit_impl(ctx: *anyopaque) void {
        const self: *InMemoryStore = @ptrCast(@alignCast(ctx));
        self.events.deinit(self.allocator);
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

    const events = try adapter.get_events(tenant_id, aggregate_id, "Widget");
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
