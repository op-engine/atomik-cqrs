//! Generic JSON envelope helpers. Domain-specific request/response shapes
//! belong in the consuming application, not here.

const std = @import("std");
const cqrs = @import("cqrs.zig");

pub const JsonError = error{
    InvalidJson,
    MissingField,
    InvalidType,
    SerializationError,
};

/// Escape a string for safe embedding inside a JSON string literal.
/// Handles the full RFC 8259 requirement: `"`, `\`, and control characters
/// (U+0000–U+001F). `data` fields that are already valid JSON are passed
/// through unescaped; only call this on values that go between `"..."`.
pub fn escape_json_string(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x09 => try buf.appendSlice(allocator, "\\t"),
            0x0A => try buf.appendSlice(allocator, "\\n"),
            0x0C => try buf.appendSlice(allocator, "\\f"),
            0x0D => try buf.appendSlice(allocator, "\\r"),
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                var tmp: [6]u8 = undefined;
                const seq = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(allocator, seq);
            },
            else => try buf.append(allocator, c),
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Serialize a generic status envelope, optionally wrapping `data`.
/// `data`, if provided, is embedded as a raw JSON value and must already be valid JSON.
pub fn serialize_response(allocator: std.mem.Allocator, status: []const u8, data: ?[]const u8) ![]const u8 {
    const escaped_status = try escape_json_string(allocator, status);
    defer allocator.free(escaped_status);

    if (data) |d| {
        return std.fmt.allocPrint(allocator, "{{\"status\":\"{s}\",\"data\":{s}}}", .{ escaped_status, d }) catch {
            return JsonError.SerializationError;
        };
    }

    return std.fmt.allocPrint(allocator, "{{\"status\":\"{s}\"}}", .{escaped_status}) catch {
        return JsonError.SerializationError;
    };
}

/// Serialize an error envelope.
pub fn serialize_error(allocator: std.mem.Allocator, code: []const u8, message: []const u8) ![]const u8 {
    const escaped_code = try escape_json_string(allocator, code);
    defer allocator.free(escaped_code);
    const escaped_message = try escape_json_string(allocator, message);
    defer allocator.free(escaped_message);

    return std.fmt.allocPrint(allocator, "{{\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ escaped_code, escaped_message }) catch {
        return JsonError.SerializationError;
    };
}

/// Serialize a `cqrs.DomainEvent` to its JSON representation.
/// `event.data` is embedded as a raw JSON value; the caller is responsible
/// for ensuring it is valid JSON. All other string fields are escaped.
pub fn serialize_event(allocator: std.mem.Allocator, event: cqrs.DomainEvent) ![]const u8 {
    const event_id_str = try cqrs.uuid_to_string(allocator, event.event_id);
    defer allocator.free(event_id_str);
    const aggregate_id_str = try cqrs.uuid_to_string(allocator, event.aggregate_id);
    defer allocator.free(aggregate_id_str);
    const escaped_aggregate_type = try escape_json_string(allocator, event.aggregate_type);
    defer allocator.free(escaped_aggregate_type);
    const escaped_event_type = try escape_json_string(allocator, event.event_type);
    defer allocator.free(escaped_event_type);

    return std.fmt.allocPrint(
        allocator,
        "{{\"event_id\":\"{s}\",\"aggregate_id\":\"{s}\",\"aggregate_type\":\"{s}\",\"event_type\":\"{s}\",\"version\":{d},\"timestamp\":{d},\"data\":{s}}}",
        .{
            event_id_str,
            aggregate_id_str,
            escaped_aggregate_type,
            escaped_event_type,
            event.version,
            event.timestamp,
            event.data,
        },
    ) catch {
        return JsonError.SerializationError;
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "serialize_response wraps data under a status envelope" {
    const out = try serialize_response(std.testing.allocator, "ok", "{\"id\":1}");
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings("{\"status\":\"ok\",\"data\":{\"id\":1}}", out);
}

test "serialize_response omits data when none given" {
    const out = try serialize_response(std.testing.allocator, "ok", null);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", out);
}

test "serialize_error formats a code/message pair" {
    const out = try serialize_error(std.testing.allocator, "NOT_FOUND", "missing");
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings("{\"error\":{\"code\":\"NOT_FOUND\",\"message\":\"missing\"}}", out);
}

test "escape_json_string handles quotes, backslashes, and control characters" {
    const allocator = std.testing.allocator;

    const q = try escape_json_string(allocator, "say \"hello\"");
    defer allocator.free(q);
    try std.testing.expectEqualStrings("say \\\"hello\\\"", q);

    const bs = try escape_json_string(allocator, "path\\to\\file");
    defer allocator.free(bs);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", bs);

    const nl = try escape_json_string(allocator, "line1\nline2\ttabbed");
    defer allocator.free(nl);
    try std.testing.expectEqualStrings("line1\\nline2\\ttabbed", nl);

    const ctrl = try escape_json_string(allocator, "\x00\x01\x1f");
    defer allocator.free(ctrl);
    try std.testing.expectEqualStrings("\\u0000\\u0001\\u001f", ctrl);
}

test "serialize_error escapes injected quotes in code and message" {
    const out = try serialize_error(std.testing.allocator, "ERR\",\"injected\":true,\"x", "bad\\value");
    defer std.testing.allocator.free(out);
    // The output must be parseable JSON; the injection attempt should be inert.
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"injected\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bad\\\\value") != null);
}

test "serialize_event escapes aggregate_type and event_type" {
    const allocator = std.testing.allocator;
    const event = cqrs.DomainEvent{
        .event_id = cqrs.generate_uuid(),
        .aggregate_id = cqrs.generate_uuid(),
        .aggregate_type = "Widget\"evil",
        .event_type = "Created\\x",
        .tenant_id = cqrs.generate_uuid(),
        .version = 1,
        .timestamp = 0,
        .user_id = cqrs.generate_uuid(),
        .data = "{}",
    };
    const out = try serialize_event(allocator, event);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Widget\\\"evil") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Created\\\\x") != null);
}

test "serialize_event embeds the domain event's fields" {
    const event = cqrs.DomainEvent{
        .event_id = cqrs.generate_uuid(),
        .aggregate_id = cqrs.generate_uuid(),
        .aggregate_type = "Widget",
        .event_type = "WidgetCreated",
        .tenant_id = cqrs.generate_uuid(),
        .version = 1,
        .timestamp = 42,
        .user_id = cqrs.generate_uuid(),
        .data = "{}",
    };

    const out = try serialize_event(std.testing.allocator, event);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"aggregate_type\":\"Widget\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"event_type\":\"WidgetCreated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"version\":1") != null);
}
