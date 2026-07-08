//! CQRS Framework — Command Query Responsibility Segregation on top of
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
};

pub const IdempotencyResult = struct {
    command_type: []const u8,
    result: []const u8, // JSON
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
};

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

// On WASM/freestanding targets (Cloudflare Workers) there is no OS entropy
// source. JS provides it via a WASM import backed by `crypto.getRandomValues`.
// On native targets we call the OS directly via `std.posix.getrandom`.
const is_wasm = @import("builtin").target.cpu.arch == .wasm32;

const wasm_js = if (is_wasm) struct {
    // Implemented in edge/worker.js — writes `len` cryptographically secure
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
        // macOS, iOS, BSDs — arc4random_buf is always available and never fails.
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
