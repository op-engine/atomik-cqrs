//! WASM entry point for Cloudflare Workers (wasm32-freestanding). This is a
//! test harness that proves the library builds and runs at the edge - it
//! is not shipped application code. Exercises the router + cqrs + event
//! store modules end to end using an in-memory adapter (no real DB
//! connection is possible from a demo running purely in the Worker's
//! WASM sandbox).

const std = @import("std");
const atomik = @import("atomik-cqrs");

// Fixed-size heap — no OS allocator available in freestanding WASM.
var heap: [256 * 1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&heap);

// Output buffer JS reads the response from after each call.
var output_buf: [64 * 1024]u8 = undefined;

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @trap();
}

// Allocate a slice in the WASM heap; JS writes request bytes here.
export fn alloc(len: usize) [*]u8 {
    const buf = fba.allocator().alloc(u8, len) catch @trap();
    return buf.ptr;
}

export fn dealloc(ptr: [*]u8, len: usize) void {
    fba.allocator().free(ptr[0..len]);
}

// Returns the address of output_buf so JS can read the response.
export fn get_output_ptr() [*]u8 {
    return &output_buf;
}

// Handle an HTTP request. Returns the byte length of the JSON written to
// output_buf. The JSON has the shape: {"status":<n>,"body":<json>}
export fn handle_request(
    method_ptr: [*]const u8,
    method_len: usize,
    path_ptr: [*]const u8,
    path_len: usize,
    body_ptr: [*]const u8,
    body_len: usize,
) usize {
    // Note: method/path/body point into the same fba-backed heap that JS's
    // alloc() calls just wrote into for *this* request. Resetting fba must
    // wait until after the response is safely copied into `output_buf`
    // (a separate static buffer) - resetting first would let dispatch's
    // own allocations overwrite the still-unread request strings.
    const allocator = fba.allocator();

    const method = method_ptr[0..method_len];
    const path = path_ptr[0..path_len];
    const body: []const u8 = if (body_len > 0) body_ptr[0..body_len] else "";

    const result = dispatch(allocator, method, path, body) catch {
        fba.reset();
        return write_output("{\"status\":500,\"body\":{\"error\":\"internal server error\"}}");
    };

    const envelope = std.fmt.bufPrint(
        &output_buf,
        "{{\"status\":{d},\"body\":{s}}}",
        .{ result.status, result.body },
    ) catch {
        fba.reset();
        return 0;
    };

    fba.reset();
    return envelope.len;
}

fn write_output(literal: []const u8) usize {
    @memcpy(output_buf[0..literal.len], literal);
    return literal.len;
}

const RouteResult = struct {
    status: u16,
    body: []const u8,
};

fn dispatch(
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) !RouteResult {
    if (std.mem.eql(u8, path, "/health")) {
        return .{ .status = 200, .body = "{\"status\":\"healthy\",\"runtime\":\"zig-wasm\"}" };
    }

    if (std.mem.eql(u8, path, "/events") and std.mem.eql(u8, method, "POST")) {
        return append_demo_event(allocator, body);
    }

    return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
}

/// Round-trips a single event through the ported cqrs/event_store/json
/// modules: build a DomainEvent, append it to an in-memory adapter, read
/// it back, and serialize the result. Proves the core library works
/// end-to-end inside the WASM sandbox.
fn append_demo_event(allocator: std.mem.Allocator, body: []const u8) !RouteResult {
    var store = InMemoryDemoStore.init(allocator);
    var adapter = store.to_adapter();
    defer adapter.deinit();

    const tenant_id = atomik.cqrs.generate_uuid();
    const aggregate_id = atomik.cqrs.generate_uuid();
    const event_data = if (body.len > 0) body else "{}";

    const event = atomik.cqrs.DomainEvent{
        .event_id = atomik.cqrs.generate_uuid(),
        .aggregate_id = aggregate_id,
        .aggregate_type = "DemoWidget",
        .event_type = "DemoWidgetCreated",
        .tenant_id = tenant_id,
        .version = 1,
        .timestamp = 0,
        .user_id = atomik.cqrs.generate_uuid(),
        .data = event_data,
    };

    try adapter.append_events(tenant_id, &[_]atomik.cqrs.DomainEvent{event});

    const events = try adapter.get_events(tenant_id, aggregate_id, "DemoWidget");
    if (events.len == 0) return .{ .status = 500, .body = "{\"error\":\"event not found after append\"}" };

    const serialized = try atomik.json.serialize_event(allocator, events[0]);
    return .{ .status = 200, .body = serialized };
}

/// Minimal in-memory EventStoreAdapter, scoped to a single request - there
/// is no real database reachable from this demo.
const InMemoryDemoStore = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(atomik.cqrs.DomainEvent),

    fn init(allocator: std.mem.Allocator) InMemoryDemoStore {
        return .{ .allocator = allocator, .events = .empty };
    }

    fn to_adapter(self: *InMemoryDemoStore) atomik.event_store.EventStoreAdapter {
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

    fn append_events_impl(ctx: *anyopaque, allocator: std.mem.Allocator, tenant_id: atomik.cqrs.UUID, events: []const atomik.cqrs.DomainEvent) anyerror!void {
        _ = allocator;
        _ = tenant_id;
        const self: *InMemoryDemoStore = @ptrCast(@alignCast(ctx));
        for (events) |event| try self.events.append(self.allocator, event);
    }

    fn get_events_impl(ctx: *anyopaque, allocator: std.mem.Allocator, tenant_id: atomik.cqrs.UUID, aggregate_id: atomik.cqrs.UUID, aggregate_type: []const u8) anyerror![]atomik.cqrs.DomainEvent {
        _ = tenant_id;
        _ = aggregate_type;
        const self: *InMemoryDemoStore = @ptrCast(@alignCast(ctx));
        var out: std.ArrayList(atomik.cqrs.DomainEvent) = .empty;
        for (self.events.items) |event| {
            if (std.mem.eql(u8, &event.aggregate_id, &aggregate_id)) try out.append(allocator, event);
        }
        return out.toOwnedSlice(allocator);
    }

    fn query_impl(ctx: *anyopaque, allocator: std.mem.Allocator, tenant_id: atomik.cqrs.UUID, filters: atomik.cqrs.QueryFilters) anyerror![]atomik.cqrs.DomainEvent {
        _ = ctx;
        _ = tenant_id;
        _ = filters;
        return allocator.alloc(atomik.cqrs.DomainEvent, 0);
    }

    fn find_by_idempotency_key_impl(ctx: *anyopaque, allocator: std.mem.Allocator, tenant_id: atomik.cqrs.UUID, key: []const u8) anyerror!?atomik.cqrs.IdempotencyResult {
        _ = ctx;
        _ = allocator;
        _ = tenant_id;
        _ = key;
        return null;
    }

    fn store_idempotency_impl(ctx: *anyopaque, allocator: std.mem.Allocator, tenant_id: atomik.cqrs.UUID, key: []const u8, result: atomik.cqrs.IdempotencyResult) anyerror!void {
        _ = ctx;
        _ = allocator;
        _ = tenant_id;
        _ = key;
        _ = result;
    }

    fn deinit_impl(ctx: *anyopaque) void {
        const self: *InMemoryDemoStore = @ptrCast(@alignCast(ctx));
        self.events.deinit(self.allocator);
    }
};
