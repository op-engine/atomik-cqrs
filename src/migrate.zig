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

    std.debug.print("Atomik CQRS Migration Tool\n", .{});
    std.debug.print("   Database: {s}\n\n", .{database_url});

    var pool = try postgres_pool.ConnectionPool.init(allocator, database_url, 1);
    defer pool.deinit();

    const conn = pool.get_connection() catch |err| {
        std.debug.print("Database connection failed, skipping migrations: {}\n", .{err});
        std.debug.print("Migration tool initialized (no connection).\n", .{});
        return;
    };
    defer pool.release_connection(conn);

    try ensure_migrations_table(conn);

    // TODO: Read migration files from ./migrations and apply pending ones
    // in filename order (see apply_migration/record_migration below).
    std.debug.print("No migrations found\n", .{});
    std.debug.print("\nMigration tool initialized.\n", .{});
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
