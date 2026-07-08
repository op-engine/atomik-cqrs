//! HTTP response formatting: status-coded response envelopes, independent of
//! any transport (native socket server or the WASM edge harness).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");

pub const HttpResponse = struct {
    status_code: u16,
    content_type: []const u8 = "application/json",
    body: []const u8,

    /// Serialize response to a raw HTTP/1.1 response string.
    pub fn to_string(self: HttpResponse, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "HTTP/1.1 {d}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ self.status_code, self.content_type, self.body.len, self.body },
        );
    }
};

pub const HttpStatusCode = enum(u16) {
    ok = 200,
    created = 201,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    internal_server_error = 500,
};

pub fn success_response(allocator: Allocator, status_code: u16, data: []const u8) !HttpResponse {
    return HttpResponse{
        .status_code = status_code,
        .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"success\",\"data\":{s}}}", .{data}),
    };
}

pub fn error_response(allocator: Allocator, status_code: u16, error_type: []const u8, message: []const u8) !HttpResponse {
    const escaped_type = try json.escape_json_string(allocator, error_type);
    defer allocator.free(escaped_type);
    const escaped_message = try json.escape_json_string(allocator, message);
    defer allocator.free(escaped_message);
    return HttpResponse{
        .status_code = status_code,
        .body = try std.fmt.allocPrint(allocator, "{{\"error\":{{\"type\":\"{s}\",\"message\":\"{s}\"}}}}", .{ escaped_type, escaped_message }),
    };
}

pub fn json_response(allocator: Allocator, status_code: u16, json_body: []const u8) !HttpResponse {
    return HttpResponse{
        .status_code = status_code,
        .body = try allocator.dupe(u8, json_body),
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "error_response formats a typed error envelope" {
    const allocator = std.testing.allocator;
    const response = try error_response(allocator, 401, "AUTH_ERROR", "Invalid token");
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 401), response.status_code);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "AUTH_ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "Invalid token") != null);
}

test "error_response escapes quotes in error_type and message" {
    const allocator = std.testing.allocator;
    const response = try error_response(allocator, 400, "ERR\",\"pwned\":true,\"x", "bad\\path");
    defer allocator.free(response.body);

    try std.testing.expect(std.mem.indexOf(u8, response.body, "\\\"pwned\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "bad\\\\path") != null);
}

test "success_response wraps data in a success envelope" {
    const allocator = std.testing.allocator;
    const response = try success_response(allocator, 200, "{\"key\":\"value\"}");
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "success") != null);
}

test "json_response passes the body through unwrapped" {
    const allocator = std.testing.allocator;
    const response = try json_response(allocator, 200, "{\"raw\":true}");
    defer allocator.free(response.body);

    try std.testing.expectEqualStrings("{\"raw\":true}", response.body);
}

test "HttpResponse to_string formats a valid HTTP/1.1 wire response" {
    const allocator = std.testing.allocator;
    const response = HttpResponse{
        .status_code = 404,
        .content_type = "application/json",
        .body = "not found",
    };

    const wire = try response.to_string(allocator);
    defer allocator.free(wire);

    // "not found" is 9 bytes; Content-Length must match exactly.
    const expected = "HTTP/1.1 404\r\nContent-Type: application/json\r\nContent-Length: 9\r\n\r\nnot found";
    try std.testing.expectEqualStrings(expected, wire);
}
