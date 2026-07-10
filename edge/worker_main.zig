//! WASM entry point for Cloudflare Workers (wasm32-freestanding).
//!
//! Persistence is handled entirely on the JavaScript side (edge/persistence.ts, via Hyperdrive)
//! — this module owns domain logic only: validating a command into a DomainEvent, and replaying
//! a history of events into aggregate state. It never touches EventStoreAdapter or any storage
//! backend, because wasm32-freestanding cannot make the native OS socket calls atomik-cqrs's
//! libpq-based adapter needs. See docs/adr/decisions.md, ADR-11, for the full rationale.

const std = @import("std");
const atomik = @import("atomik-cqrs");

// Fixed-size heap; no OS allocator available in freestanding WASM.
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

    if (std.mem.eql(u8, path, "/commands") and std.mem.eql(u8, method, "POST")) {
        return handle_command(allocator, body);
    }

    if (std.mem.eql(u8, path, "/replay") and std.mem.eql(u8, method, "POST")) {
        return handle_replay(allocator, body);
    }

    return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
}

// ============================================================================
// POST /commands — pure command -> event construction, no I/O
// ============================================================================
//
// Domain-agnostic on purpose: aggregate_type/event_type/data are all
// caller-supplied, not hardcoded. No real LMS command handlers exist yet
// (ADR-002 territory) — until they do, this stays mechanical construction +
// version-stamping only, so it isn't locked to one placeholder shape
// (originally "DemoWidget", which blocked anything else from flowing through).
//
// TS supplies `aggregate_id` (it owns identity/addressing across calls) and
// `expected_version` (it owns all persistence, so it's the only side that knows
// the current version). This is the actual I/O boundary from ADR-11: WASM never
// reads or writes storage, it only builds and validates the next event.
// tenant_id/user_id are zeroed here — they're not part of serialize_event's
// output, and TS already has the real values from the original request, so it
// reattaches them itself before calling persistence.appendEvent.

const CommandBody = struct {
    aggregate_id: []const u8,
    aggregate_type: []const u8,
    event_type: []const u8,
    expected_version: u32,
    timestamp: i64,
    data: std.json.Value,
};

fn handle_command(allocator: std.mem.Allocator, body: []const u8) !RouteResult {
    const parsed = std.json.parseFromSlice(CommandBody, allocator, body, .{}) catch {
        return .{ .status = 400, .body = "{\"error\":\"invalid command body\"}" };
    };
    const cmd = parsed.value;

    const aggregate_id = atomik.cqrs.string_to_uuid(cmd.aggregate_id) catch {
        return .{ .status = 400, .body = "{\"error\":\"invalid aggregate_id\"}" };
    };

    const event_data = try std.json.Stringify.valueAlloc(allocator, cmd.data, .{});

    const event = atomik.cqrs.DomainEvent{
        .event_id = atomik.cqrs.generate_uuid(),
        .aggregate_id = aggregate_id,
        .aggregate_type = cmd.aggregate_type,
        .event_type = cmd.event_type,
        .tenant_id = std.mem.zeroes(atomik.cqrs.UUID),
        .version = cmd.expected_version + 1,
        .timestamp = cmd.timestamp,
        .user_id = std.mem.zeroes(atomik.cqrs.UUID),
        .data = event_data,
    };

    const serialized = try atomik.json.serialize_event(allocator, event);
    return .{ .status = 200, .body = serialized };
}

// ============================================================================
// POST /replay — drives cqrs.Aggregate.load_from_history for real
// ============================================================================
//
// TS has already fetched the aggregate's committed events (persistence.getEvents)
// and hands them here as-is; WASM never queries storage itself.
//
// Replay is a generic shallow JSON merge, not domain-specific extraction: each
// event's `data` object is merged key-by-key into an accumulated `state`
// object (later events win on key collisions). This is the only replay
// strategy that makes sense without real per-event-type apply logic (ADR-002
// territory) — it works for any aggregate/event type the caller sends, not
// just one hardcoded shape.

const ReplayEventInput = struct {
    event_type: []const u8,
    version: u32,
    data: std.json.Value,
};

const ReplayRequestBody = struct {
    aggregate_id: []const u8,
    events: []ReplayEventInput,
};

/// Generic aggregate: folds every event's `data` object into `state` via
/// shallow merge, and tracks event_count. No knowledge of any specific
/// event_type. Mirrors the base/apply_event embedding pattern used in
/// src/cqrs.zig's own tests (WidgetAggregate), but domain-agnostic.
const GenericAggregate = struct {
    base: atomik.cqrs.Aggregate,
    state: std.json.ObjectMap,
    event_count: usize = 0,

    fn apply(base: *atomik.cqrs.Aggregate, event: atomik.cqrs.DomainEvent) anyerror!void {
        const self: *GenericAggregate = @fieldParentPtr("base", base);
        // Not calling parsed.deinit(): this runs inside a single request's
        // FixedBufferAllocator arena (see handle_request), reclaimed in one
        // shot via fba.reset() once the response is written.
        const parsed = std.json.parseFromSlice(std.json.Value, self.base.allocator, event.data, .{}) catch return;
        if (parsed.value == .object) {
            var it = parsed.value.object.iterator();
            while (it.next()) |entry| {
                try self.state.put(self.base.allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        self.event_count += 1;
    }
};

fn handle_replay(allocator: std.mem.Allocator, body: []const u8) !RouteResult {
    const parsed = std.json.parseFromSlice(ReplayRequestBody, allocator, body, .{}) catch {
        return .{ .status = 400, .body = "{\"error\":\"invalid replay body\"}" };
    };

    const aggregate_id = atomik.cqrs.string_to_uuid(parsed.value.aggregate_id) catch {
        return .{ .status = 400, .body = "{\"error\":\"invalid aggregate_id\"}" };
    };

    var aggregate = GenericAggregate{
        .base = atomik.cqrs.Aggregate.init(allocator, aggregate_id),
        .state = try std.json.ObjectMap.init(allocator, &.{}, &.{}),
    };

    const events = try allocator.alloc(atomik.cqrs.DomainEvent, parsed.value.events.len);
    for (parsed.value.events, 0..) |input, i| {
        const data_json = try std.json.Stringify.valueAlloc(allocator, input.data, .{});
        events[i] = .{
            .event_id = std.mem.zeroes(atomik.cqrs.UUID),
            .aggregate_id = aggregate_id,
            .aggregate_type = "",
            .event_type = input.event_type,
            .tenant_id = std.mem.zeroes(atomik.cqrs.UUID),
            .version = input.version,
            .timestamp = 0,
            .user_id = std.mem.zeroes(atomik.cqrs.UUID),
            .data = data_json,
        };
    }

    try aggregate.base.load_from_history(events, GenericAggregate.apply);

    const state_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = aggregate.state }, .{});
    const response = try std.fmt.allocPrint(
        allocator,
        "{{\"aggregate_id\":\"{s}\",\"version\":{d},\"state\":{s},\"event_count\":{d}}}",
        .{ parsed.value.aggregate_id, aggregate.base.version, state_json, aggregate.event_count },
    );
    return .{ .status = 200, .body = response };
}
