//! HTTP Router — request routing and path parsing. Domain-agnostic:
//! reusable by any application built on this library.

const std = @import("std");

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,
};

pub const Route = struct {
    method: HttpMethod,
    path_pattern: []const u8,
    handler: ?*const fn ([]const u8) void = null,
};

pub const Request = struct {
    method: HttpMethod,
    path: []const u8,
    query: ?[]const u8,
    body: ?[]const u8,
    headers: ?std.StringHashMap([]const u8),
};

pub const Response = struct {
    status_code: u16,
    content_type: []const u8 = "application/json",
    body: []const u8,
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(Route),

    pub fn init(allocator: std.mem.Allocator) Router {
        return Router{
            .allocator = allocator,
            .routes = .{
                .items = &[_]Route{},
                .capacity = 0,
            },
        };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.allocator);
    }

    /// Register a route
    pub fn register(
        self: *Router,
        method: HttpMethod,
        path_pattern: []const u8,
        handler: ?*const fn ([]const u8) void,
    ) !void {
        try self.routes.append(self.allocator, Route{
            .method = method,
            .path_pattern = path_pattern,
            .handler = handler,
        });
    }

    /// Find matching route
    pub fn match(self: Router, req: Request) ?Route {
        for (self.routes.items) |route| {
            if (route.method != req.method) continue;

            if (path_matches(route.path_pattern, req.path)) {
                return route;
            }
        }
        return null;
    }
};

/// Check if path matches pattern
/// Pattern can contain :param placeholders
fn path_matches(pattern: []const u8, path: []const u8) bool {
    var pattern_iter = std.mem.splitSequence(u8, pattern, "/");
    var path_iter = std.mem.splitSequence(u8, path, "/");

    while (pattern_iter.next()) |pattern_part| {
        if (path_iter.next()) |path_part| {
            // Check if pattern part is a parameter
            if (std.mem.startsWith(u8, pattern_part, ":")) {
                // Parameter matches anything
                continue;
            }

            // Literal must match exactly
            if (!std.mem.eql(u8, pattern_part, path_part)) {
                return false;
            }
        } else {
            // Pattern has more parts than path
            return false;
        }
    }

    // Check if path has more parts than pattern
    return path_iter.next() == null;
}

/// Extract path parameters
pub fn extract_params(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    path: []const u8,
) !std.StringHashMap([]const u8) {
    var params = std.StringHashMap([]const u8).init(allocator);

    var pattern_iter = std.mem.splitSequence(u8, pattern, "/");
    var path_iter = std.mem.splitSequence(u8, path, "/");

    while (pattern_iter.next()) |pattern_part| {
        if (path_iter.next()) |path_part| {
            if (std.mem.startsWith(u8, pattern_part, ":")) {
                const param_name = pattern_part[1..]; // Remove ':'
                try params.put(param_name, path_part);
            }
        }
    }

    return params;
}

/// Parse HTTP method from string
pub fn parse_method(method_str: []const u8) ?HttpMethod {
    if (std.mem.eql(u8, method_str, "GET")) return .GET;
    if (std.mem.eql(u8, method_str, "POST")) return .POST;
    if (std.mem.eql(u8, method_str, "PUT")) return .PUT;
    if (std.mem.eql(u8, method_str, "PATCH")) return .PATCH;
    if (std.mem.eql(u8, method_str, "DELETE")) return .DELETE;
    if (std.mem.eql(u8, method_str, "HEAD")) return .HEAD;
    if (std.mem.eql(u8, method_str, "OPTIONS")) return .OPTIONS;
    return null;
}

/// Build HTTP response
pub fn build_response(
    allocator: std.mem.Allocator,
    status_code: u16,
    body: []const u8,
) ![]const u8 {
    const status_text = switch (status_code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        422 => "Unprocessable Entity",
        500 => "Internal Server Error",
        else => "Unknown",
    };

    return try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{
            status_code,
            status_text,
            body.len,
            body,
        },
    );
}

/// Parse query string into map
pub fn parse_query_string(
    allocator: std.mem.Allocator,
    query: []const u8,
) !std.StringHashMap([]const u8) {
    var params = std.StringHashMap([]const u8).init(allocator);

    var iter = std.mem.splitSequence(u8, query, "&");
    while (iter.next()) |pair| {
        if (std.mem.indexOf(u8, pair, "=")) |eq_idx| {
            const key = pair[0..eq_idx];
            const value = pair[eq_idx + 1 ..];
            try params.put(key, value);
        }
    }

    return params;
}

// ============================================================================
// HTTP STATUS CODES
// ============================================================================

pub const StatusCode = struct {
    pub const OK = 200;
    pub const CREATED = 201;
    pub const ACCEPTED = 202;
    pub const NO_CONTENT = 204;
    pub const BAD_REQUEST = 400;
    pub const UNAUTHORIZED = 401;
    pub const FORBIDDEN = 403;
    pub const NOT_FOUND = 404;
    pub const CONFLICT = 409;
    pub const UNPROCESSABLE_ENTITY = 422;
    pub const INTERNAL_SERVER_ERROR = 500;
    pub const SERVICE_UNAVAILABLE = 503;
};

// ============================================================================
// TESTS
// ============================================================================

test "router matches literal and parameterized routes" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try router.register(.GET, "/health", null);
    try router.register(.GET, "/accounts/:id", null);

    try std.testing.expect(router.match(.{ .method = .GET, .path = "/health", .query = null, .body = null, .headers = null }) != null);
    try std.testing.expect(router.match(.{ .method = .GET, .path = "/accounts/abc123", .query = null, .body = null, .headers = null }) != null);
    try std.testing.expect(router.match(.{ .method = .POST, .path = "/health", .query = null, .body = null, .headers = null }) == null);
    try std.testing.expect(router.match(.{ .method = .GET, .path = "/accounts/abc123/extra", .query = null, .body = null, .headers = null }) == null);
}

test "extract_params pulls named parameters out of the path" {
    var params = try extract_params(std.testing.allocator, "/accounts/:id/entries/:entry_id", "/accounts/42/entries/99");
    defer params.deinit();

    try std.testing.expectEqualStrings("42", params.get("id").?);
    try std.testing.expectEqualStrings("99", params.get("entry_id").?);
}

test "parse_method covers all supported verbs and rejects unknown ones" {
    try std.testing.expectEqual(HttpMethod.GET, parse_method("GET").?);
    try std.testing.expectEqual(HttpMethod.DELETE, parse_method("DELETE").?);
    try std.testing.expect(parse_method("TRACE") == null);
}

test "parse_query_string splits key=value pairs" {
    var params = try parse_query_string(std.testing.allocator, "a=1&b=2");
    defer params.deinit();

    try std.testing.expectEqualStrings("1", params.get("a").?);
    try std.testing.expectEqualStrings("2", params.get("b").?);
}

test "build_response formats a well-known status line" {
    const resp = try build_response(std.testing.allocator, 404, "{}");
    defer std.testing.allocator.free(resp);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404 Not Found"));
}
