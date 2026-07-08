//! CQRS Framework: Command Query Responsibility Segregation on top of
//! event sourcing. Domain-agnostic: aggregate/event/command "type" fields
//! are open string discriminators, not closed enums, so a consuming
//! application defines its own vocabulary without modifying this module.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// CORE TYPES
// ============================================================================

/// Unique identifier (UUID)
pub const UUID = [16]u8;

// ============================================================================
// COMMAND INTERFACE
// ============================================================================

/// Base command envelope. `command_type` is application-defined (e.g. "CreateAccount").
pub const Command = struct {
    command_type: []const u8,
    tenant_id: UUID,
    user_id: UUID,
    timestamp: i64, // Unix timestamp
    idempotency_key: ?[]const u8 = null,
};

// ============================================================================
// EVENT INTERFACE
// ============================================================================

/// Base domain event envelope. `aggregate_type` and `event_type` are
/// application-defined strings (e.g. "Account", "AccountCreated").
pub const DomainEvent = struct {
    event_id: UUID,
    aggregate_id: UUID,
    aggregate_type: []const u8,
    event_type: []const u8,
    tenant_id: UUID,
    version: u32,
    timestamp: i64,
    user_id: UUID,
    data: []const u8, // JSON payload
    /// Monotonically increasing position assigned by the store at write time.
    /// Used as the projection cursor. 0 when not backed by a sequenced store
    /// (in-memory stores assign 1-based values; WASM resets on restart).
    global_seq: u64 = 0,
};

/// Audit event envelope. `event_type` is application-defined (e.g. "DATA_EXPORTED").
pub const AuditEvent = struct {
    audit_event_id: UUID,
    tenant_id: UUID,
    event_type: []const u8,
    user_id: UUID,
    ip_address: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    timestamp: i64,
};

// ============================================================================
// EVENT STORE QUERY TYPES
// ============================================================================

pub const QueryFilters = struct {
    aggregate_type: ?[]const u8 = null,
    event_type: ?[]const u8 = null,
    start_time: ?i64 = null,
    end_time: ?i64 = null,
    limit: ?u32 = null,
    /// Projection cursor: return only events whose global_seq is strictly
    /// greater than this value, ordered by global_seq ASC. Set automatically
    /// by ProjectionRunner; leave null for non-projection queries.
    after_seq: ?u64 = null,
};

pub const IdempotencyResult = struct {
    command_type: []const u8,
    result: []const u8, // JSON
    created_at: i64,
};

/// A point-in-time capture of an aggregate's state at a given version.
/// Used by SnapshotStore to skip replaying events that are already reflected
/// in the snapshot. `state` is application-serialized (typically JSON).
pub const Snapshot = struct {
    aggregate_id: UUID,
    aggregate_type: []const u8,
    version: u32,
    state: []const u8,
    created_at: i64,
};

// ============================================================================
// AGGREGATE INTERFACE
// ============================================================================

/// Base aggregate pattern: accumulates uncommitted events, replays history.
/// Concrete aggregates embed this as `base` and override `apply_event`.
pub const Aggregate = struct {
    allocator: Allocator,
    aggregate_id: UUID,
    version: u32,
    uncommitted_events: std.ArrayList(DomainEvent),

    pub fn init(allocator: Allocator, aggregate_id: UUID) Aggregate {
        return .{
            .allocator = allocator,
            .aggregate_id = aggregate_id,
            .version = 0,
            .uncommitted_events = .empty,
        };
    }

    pub fn deinit(self: *Aggregate) void {
        self.uncommitted_events.deinit(self.allocator);
    }

    pub fn record(self: *Aggregate, event: DomainEvent) !void {
        try self.uncommitted_events.append(self.allocator, event);
        self.version = event.version;
    }

    pub fn load_from_history(
        self: *Aggregate,
        events: []const DomainEvent,
        apply_event: *const fn (self: *Aggregate, event: DomainEvent) anyerror!void,
    ) !void {
        for (events) |event| {
            try apply_event(self, event);
            self.version = event.version;
        }
    }

    /// Hydrate from a snapshot (if any) then replay incremental events.
    /// Caller should fetch events via `adapter.get_events(..., after_version =
    /// snapshot.version)` so only the events AFTER the snapshot are replayed.
    /// `apply_snapshot_fn` deserializes the snapshot's `state` bytes into self;
    /// pass null to skip snapshot restoration (treats snapshot as a version hint only).
    pub fn load_from_history_with_snapshot(
        self: *Aggregate,
        snapshot: ?Snapshot,
        events: []const DomainEvent,
        apply_snapshot_fn: ?*const fn (self: *Aggregate, state: []const u8) anyerror!void,
        apply_event_fn: *const fn (self: *Aggregate, event: DomainEvent) anyerror!void,
    ) !void {
        if (snapshot) |snap| {
            if (apply_snapshot_fn) |f| try f(self, snap.state);
            self.version = snap.version;
        }
        for (events) |event| {
            try apply_event_fn(self, event);
            self.version = event.version;
        }
    }
};

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

// On WASM/freestanding targets (Cloudflare Workers) there is no OS entropy
// source. JS provides it via a WASM import backed by `crypto.getRandomValues`.
// On native targets we call the OS directly via `std.posix.getrandom`.
const is_wasm = @import("builtin").target.cpu.arch == .wasm32;

const wasm_js = if (is_wasm) struct {
    // Implemented in edge/worker.js; writes `len` cryptographically secure
    // random bytes into the WASM linear memory starting at `ptr`.
    pub extern fn fill_random_bytes(ptr: [*]u8, len: usize) void;
} else struct {};

/// Generate a UUID v4 (random) identifier backed by a CSPRNG on every target.
pub fn generate_uuid() UUID {
    var uuid: UUID = undefined;
    if (comptime is_wasm) {
        wasm_js.fill_random_bytes(&uuid, uuid.len);
    } else {
        fill_os_entropy(&uuid);
    }
    // Set version (4) and variant bits per RFC 4122.
    uuid[6] = (uuid[6] & 0x0f) | 0x40;
    uuid[8] = (uuid[8] & 0x3f) | 0x80;
    return uuid;
}

fn fill_os_entropy(buf: []u8) void {
    const os = @import("builtin").os.tag;
    if (comptime os == .linux) {
        const rc = std.os.linux.getrandom(buf.ptr, buf.len, 0);
        std.debug.assert(std.os.linux.getErrno(rc) == .SUCCESS);
    } else {
        // macOS, iOS, BSDs: arc4random_buf is always available and never fails.
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

/// Convert UUID to its canonical hyphenated hex string.
pub fn uuid_to_string(allocator: Allocator, uuid: UUID) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

/// Parse a canonical hyphenated hex UUID string back into bytes.
pub fn string_to_uuid(str: []const u8) !UUID {
    if (str.len != 36) return error.InvalidUUID;
    // Validate that hyphen positions match "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".
    if (str[8] != '-' or str[13] != '-' or str[18] != '-' or str[23] != '-') {
        return error.InvalidUUID;
    }
    var uuid: UUID = undefined;

    for (0..16) |i| {
        // Cumulative count of hyphens preceding byte `i` in "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".
        const hyphens_before: usize = if (i < 4) 0 else if (i < 6) 1 else if (i < 8) 2 else if (i < 10) 3 else 4;
        const hex_pos = i * 2 + hyphens_before;

        const high = try std.fmt.charToDigit(str[hex_pos], 16);
        const low = try std.fmt.charToDigit(str[hex_pos + 1], 16);
        uuid[i] = (high << 4) | low;
    }

    return uuid;
}

// ============================================================================
// ERRORS
// ============================================================================

pub const Error = error{
    InvalidUUID,
    NotImplemented,
};

// ============================================================================
// TESTS
// ============================================================================

test "uuid round-trips through string form" {
    const original = generate_uuid();
    const str = try uuid_to_string(std.testing.allocator, original);
    defer std.testing.allocator.free(str);

    try std.testing.expectEqual(@as(usize, 36), str.len);

    const parsed = try string_to_uuid(str);
    try std.testing.expectEqualSlices(u8, &original, &parsed);
}

test "string_to_uuid rejects wrong length" {
    try std.testing.expectError(error.InvalidUUID, string_to_uuid("not-a-uuid"));
}

test "string_to_uuid rejects missing hyphens at correct positions" {
    // 36 chars, valid hex throughout, but hyphens replaced with '0'
    try std.testing.expectError(error.InvalidUUID, string_to_uuid("000000000000000000000000000000000000"));
}

test "string_to_uuid rejects wrong hyphen positions" {
    try std.testing.expectError(error.InvalidUUID, string_to_uuid("0000000-00000-0000-0000-000000000000"));
}

test "aggregate records uncommitted events and tracks version" {
    var agg = Aggregate.init(std.testing.allocator, generate_uuid());
    defer agg.deinit();

    try agg.record(DomainEvent{
        .event_id = generate_uuid(),
        .aggregate_id = agg.aggregate_id,
        .aggregate_type = "Widget",
        .event_type = "WidgetCreated",
        .tenant_id = generate_uuid(),
        .version = 1,
        .timestamp = 0,
        .user_id = generate_uuid(),
        .data = "{}",
    });

    try std.testing.expectEqual(@as(u32, 1), agg.version);
    try std.testing.expectEqual(@as(usize, 1), agg.uncommitted_events.items.len);
}

test "aggregate load_from_history advances version to last event" {
    var agg = Aggregate.init(std.testing.allocator, generate_uuid());
    defer agg.deinit();

    const history = [_]DomainEvent{
        .{ .event_id = generate_uuid(), .aggregate_id = agg.aggregate_id, .aggregate_type = "Widget", .event_type = "WidgetCreated", .tenant_id = generate_uuid(), .version = 1, .timestamp = 0, .user_id = generate_uuid(), .data = "{}" },
        .{ .event_id = generate_uuid(), .aggregate_id = agg.aggregate_id, .aggregate_type = "Widget", .event_type = "WidgetUpdated", .tenant_id = generate_uuid(), .version = 2, .timestamp = 0, .user_id = generate_uuid(), .data = "{}" },
        .{ .event_id = generate_uuid(), .aggregate_id = agg.aggregate_id, .aggregate_type = "Widget", .event_type = "WidgetArchived", .tenant_id = generate_uuid(), .version = 3, .timestamp = 0, .user_id = generate_uuid(), .data = "{}" },
    };

    try agg.load_from_history(&history, struct {
        fn apply(_: *Aggregate, _: DomainEvent) anyerror!void {}
    }.apply);

    try std.testing.expectEqual(@as(u32, 3), agg.version);
    // load_from_history must not populate uncommitted_events.
    try std.testing.expectEqual(@as(usize, 0), agg.uncommitted_events.items.len);
}

test "aggregate load_from_history calls apply_event for each event in order" {
    // Concrete aggregate that records the sequence of event types it receives.
    const WidgetAggregate = struct {
        base: Aggregate,
        seen: [8][]const u8 = undefined,
        count: usize = 0,

        fn apply(base: *Aggregate, event: DomainEvent) anyerror!void {
            const self: *@This() = @fieldParentPtr("base", base);
            self.seen[self.count] = event.event_type;
            self.count += 1;
        }
    };

    var agg = WidgetAggregate{ .base = Aggregate.init(std.testing.allocator, generate_uuid()) };
    defer agg.base.deinit();

    const history = [_]DomainEvent{
        .{ .event_id = generate_uuid(), .aggregate_id = agg.base.aggregate_id, .aggregate_type = "Widget", .event_type = "WidgetCreated", .tenant_id = generate_uuid(), .version = 1, .timestamp = 0, .user_id = generate_uuid(), .data = "{}" },
        .{ .event_id = generate_uuid(), .aggregate_id = agg.base.aggregate_id, .aggregate_type = "Widget", .event_type = "WidgetUpdated", .tenant_id = generate_uuid(), .version = 2, .timestamp = 0, .user_id = generate_uuid(), .data = "{}" },
    };

    try agg.base.load_from_history(&history, WidgetAggregate.apply);

    try std.testing.expectEqual(@as(usize, 2), agg.count);
    try std.testing.expectEqualStrings("WidgetCreated", agg.seen[0]);
    try std.testing.expectEqualStrings("WidgetUpdated", agg.seen[1]);
}

test "aggregate load_from_history_with_snapshot restores state and replays only incremental events" {
    const OrderAggregate = struct {
        base: Aggregate,
        // Simulated state fields populated by apply_snapshot.
        total: u32 = 0,
        shipped: bool = false,

        fn apply_snapshot(base: *Aggregate, state: []const u8) anyerror!void {
            const self: *@This() = @fieldParentPtr("base", base);
            // Minimal parse: state is "{\"total\":N}" for this test.
            if (std.mem.startsWith(u8, state, "{\"total\":")) {
                const n_str = state[9 .. state.len - 1];
                self.total = try std.fmt.parseInt(u32, n_str, 10);
            }
        }

        fn apply_event(base: *Aggregate, event: DomainEvent) anyerror!void {
            const self: *@This() = @fieldParentPtr("base", base);
            if (std.mem.eql(u8, event.event_type, "OrderShipped")) self.shipped = true;
        }
    };

    var agg = OrderAggregate{ .base = Aggregate.init(std.testing.allocator, generate_uuid()) };
    defer agg.base.deinit();

    // Snapshot captures state at version 5 — only version 6 needs to be replayed.
    const snapshot = Snapshot{
        .aggregate_id = agg.base.aggregate_id,
        .aggregate_type = "Order",
        .version = 5,
        .state = "{\"total\":42}",
        .created_at = 0,
    };

    const incremental = [_]DomainEvent{
        .{ .event_id = generate_uuid(), .aggregate_id = agg.base.aggregate_id, .aggregate_type = "Order", .event_type = "OrderShipped", .tenant_id = generate_uuid(), .version = 6, .timestamp = 0, .user_id = generate_uuid(), .data = "{}" },
    };

    try agg.base.load_from_history_with_snapshot(snapshot, &incremental, OrderAggregate.apply_snapshot, OrderAggregate.apply_event);

    try std.testing.expectEqual(@as(u32, 6), agg.base.version);
    try std.testing.expectEqual(@as(u32, 42), agg.total);
    try std.testing.expect(agg.shipped);
}
