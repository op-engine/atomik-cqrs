//! Migration Tool
//! ==============
//! Zig-based migration runner. Reads the target database from the
//! `ATOMIK_DATABASE_URL` environment variable (falling back to a local
//! default), and applies any pending migrations found in `./migrations`.

const std = @import("std");
const postgres_pool = @import("postgres_pool.zig");

const default_database_url = "postgres://localhost/atomik_dev";

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const database_url = if (std.c.getenv("ATOMIK_DATABASE_URL")) |env_value|
        try allocator.dupe(u8, std.mem.span(env_value))
    else
        try allocator.dupe(u8, default_database_url);
    defer allocator.free(database_url);

    const safe_url = try redact_db_url(allocator, database_url);
    defer allocator.free(safe_url);

    std.debug.print("Atomik CQRS Migration Tool\n", .{});
    std.debug.print("   Database: {s}\n\n", .{safe_url});

    var pool = try postgres_pool.ConnectionPool.init(allocator, database_url, 1);
    defer pool.deinit();

    const conn = pool.get_connection() catch |err| {
        std.debug.print("Database connection failed, skipping migrations: {}\n", .{err});
        std.debug.print("Migration tool initialized (no connection).\n", .{});
        return;
    };
    defer pool.release_connection(conn);

    try ensure_migrations_table(conn);

    // Collect all *.sql files in ./migrations in sorted filename order.
    var dir = std.fs.cwd().openDir("migrations", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("No migrations/ directory found — nothing to do.\n", .{});
            return;
        },
        else => return err,
    };
    defer dir.close();

    var filenames = std.ArrayList([]const u8).init(allocator);
    defer {
        for (filenames.items) |name| allocator.free(name);
        filenames.deinit();
    }

    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        try filenames.append(try allocator.dupe(u8, entry.name));
    }

    if (filenames.items.len == 0) {
        std.debug.print("No .sql files found in migrations/ — nothing to do.\n", .{});
        return;
    }

    std.mem.sort([]const u8, filenames.items, {}, compare_migration_names);

    var applied_count: usize = 0;
    var skipped_count: usize = 0;

    for (filenames.items) |filename| {
        if (try is_migration_applied(conn, filename)) {
            std.debug.print("  skip  {s}\n", .{filename});
            skipped_count += 1;
            continue;
        }

        std.debug.print("  apply {s} ...", .{filename});

        const sql_content = try dir.readFileAlloc(allocator, filename, 4 * 1024 * 1024);
        defer allocator.free(sql_content);

        try apply_migration(conn, sql_content);
        try record_migration(conn, filename);

        std.debug.print(" ok\n", .{});
        applied_count += 1;
    }

    std.debug.print("\nApplied {d} migration(s), skipped {d}.\n", .{ applied_count, skipped_count });
}

/// Ensure schema_migrations table exists
fn ensure_migrations_table(conn: *postgres_pool.Connection) !void {
    const sql =
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\  id BIGSERIAL PRIMARY KEY,
        \\  version VARCHAR(255) NOT NULL UNIQUE,
        \\  applied_at TIMESTAMP NOT NULL DEFAULT NOW()
        \\)
    ;

    _ = try conn.exec(sql, &[_][]const u8{});
}

/// Check if migration has been applied
fn is_migration_applied(
    conn: *postgres_pool.Connection,
    migration_file: []const u8,
) !bool {
    const sql =
        \\SELECT 1 FROM schema_migrations WHERE version = $1
    ;

    var result = try conn.query(sql, &[_][]const u8{migration_file});
    defer result.deinit();

    return result.first() != null;
}

/// Apply a migration
fn apply_migration(
    conn: *postgres_pool.Connection,
    content: []const u8,
) !void {
    var it = std.mem.splitSequence(u8, content, ";");
    while (it.next()) |stmt| {
        const trimmed = std.mem.trim(u8, stmt, " \t\n\r");
        if (trimmed.len > 0) {
            _ = try conn.exec(trimmed, &[_][]const u8{});
        }
    }
}

/// Record migration as applied
fn record_migration(
    conn: *postgres_pool.Connection,
    migration_file: []const u8,
) !void {
    const sql =
        \\INSERT INTO schema_migrations (version) VALUES ($1)
    ;

    _ = try conn.exec(sql, &[_][]const u8{migration_file});
}

/// Compare migration filenames (001-* before 002-*, etc.)
fn compare_migration_names(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Return a copy of `url` with any password component replaced by "***".
/// Handles postgres://user:password@host/db. Caller owns the returned slice.
fn redact_db_url(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, url, "@") orelse return allocator.dupe(u8, url);
    const sep = "://";
    const after_scheme = (std.mem.indexOf(u8, url, sep) orelse return allocator.dupe(u8, url)) + sep.len;
    const user_pass = url[after_scheme..at];
    const colon = std.mem.indexOf(u8, user_pass, ":") orelse return allocator.dupe(u8, url);
    // url[0 .. after_scheme + colon + 1] is "scheme://user:"
    return std.fmt.allocPrint(allocator, "{s}***{s}", .{
        url[0 .. after_scheme + colon + 1],
        url[at..],
    });
}
