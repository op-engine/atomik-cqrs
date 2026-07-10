//! DATABASE ADAPTER: PostgreSQL
//! =============================
//! Concrete EventStoreAdapter implementation for PostgreSQL, storing
//! `cqrs.DomainEvent`s in a generic `events` table (no domain-specific
//! columns). Persists idempotency results and audit log entries alongside.

const std = @import("std");
const Allocator = std.mem.Allocator;
const event_store = @import("../event_store.zig");
const cqrs = @import("../cqrs.zig");
const postgres_pool = @import("../postgres_pool.zig");
const projection = @import("../projection.zig");

// std.time.milliTimestamp was removed in Zig 0.16; use POSIX clock_gettime.
fn nowMillis() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

pub const PostgresAdapter = struct {
    allocator: Allocator,
    pool: *postgres_pool.ConnectionPool,

    pub fn init(allocator: Allocator, pool: *postgres_pool.ConnectionPool) PostgresAdapter {
        return .{ .allocator = allocator, .pool = pool };
    }

    /// Convert to the generic EventStoreAdapter interface.
    pub fn to_adapter(self: *PostgresAdapter) event_store.EventStoreAdapter {
        return .{
            .allocator = self.allocator,
            .context = self,
            .create_schema_fn = &create_schema_impl,
            .append_events_fn = &append_events_impl,
            .get_events_fn = &get_events_impl,
            .query_fn = &query_impl,
            .find_by_idempotency_key_fn = &find_by_idempotency_key_impl,
            .store_idempotency_fn = &store_idempotency_impl,
            .deinit_fn = &deinit_impl,
        };
    }

    // ========================================================================
    // SCHEMA
    // ========================================================================

    fn create_schema_impl(ctx: *anyopaque) anyerror!void {
        const self: *PostgresAdapter = @ptrCast(@alignCast(ctx));
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        const sql =
            \\CREATE TABLE IF NOT EXISTS events (
            \\  global_seq BIGSERIAL NOT NULL,
            \\  id VARCHAR(32) PRIMARY KEY,
            \\  tenant_id VARCHAR(32) NOT NULL,
            \\  aggregate_id VARCHAR(32) NOT NULL,
            \\  aggregate_type VARCHAR(128) NOT NULL,
            \\  event_type VARCHAR(128) NOT NULL,
            \\  event_data JSONB NOT NULL,
            \\  event_metadata JSONB,
            \\  version INT NOT NULL,
            \\  timestamp BIGINT NOT NULL,
            \\  created_by VARCHAR(32) NOT NULL
            \\);
            \\CREATE UNIQUE INDEX IF NOT EXISTS idx_events_aggregate ON events(tenant_id, aggregate_id, version ASC);
            \\CREATE INDEX IF NOT EXISTS idx_events_type ON events(tenant_id, aggregate_type, event_type, timestamp DESC);
            \\CREATE INDEX IF NOT EXISTS idx_events_global_seq ON events(global_seq ASC);
            \\
            \\CREATE TABLE IF NOT EXISTS idempotency_keys (
            \\  tenant_id VARCHAR(32) NOT NULL,
            \\  idempotency_key VARCHAR(256) NOT NULL,
            \\  command_type VARCHAR(128) NOT NULL,
            \\  result JSONB NOT NULL,
            \\  created_at BIGINT NOT NULL,
            \\  PRIMARY KEY (tenant_id, idempotency_key)
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS audit_logs (
            \\  id VARCHAR(32) PRIMARY KEY,
            \\  tenant_id VARCHAR(32) NOT NULL,
            \\  event_type VARCHAR(128) NOT NULL,
            \\  user_id VARCHAR(32) NOT NULL,
            \\  ip_address VARCHAR(64),
            \\  user_agent VARCHAR(256),
            \\  timestamp BIGINT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_audit_tenant ON audit_logs(tenant_id, timestamp DESC);
            \\
            \\CREATE TABLE IF NOT EXISTS projection_checkpoints (
            \\  name VARCHAR(256) PRIMARY KEY,
            \\  position BIGINT NOT NULL DEFAULT 0,
            \\  updated_at BIGINT NOT NULL DEFAULT 0
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS snapshots (
            \\  id BIGSERIAL PRIMARY KEY,
            \\  tenant_id VARCHAR(32) NOT NULL,
            \\  aggregate_id VARCHAR(32) NOT NULL,
            \\  aggregate_type VARCHAR(128) NOT NULL,
            \\  version INT NOT NULL,
            \\  state JSONB NOT NULL,
            \\  created_at BIGINT NOT NULL,
            \\  UNIQUE (tenant_id, aggregate_id)
            \\);
        ;

        // PQexecParams (which conn.exec always uses, per ADR-03's parameterized-query-only
        // policy) rejects multi-statement strings outright ("cannot insert multiple commands
        // into a prepared statement") — unlike PQexec's simple query protocol, it can only ever
        // run one statement per call. Split and exec individually, matching the same technique
        // migrate.zig's apply_migration already uses for the same reason.
        var it = std.mem.splitScalar(u8, sql, ';');
        while (it.next()) |stmt| {
            const trimmed = std.mem.trim(u8, stmt, " \t\n\r");
            if (trimmed.len > 0) {
                _ = try conn.exec(trimmed, &[_][]const u8{});
            }
        }
    }

    // ========================================================================
    // EVENTS
    // ========================================================================

    fn append_events_impl(
        ctx: *anyopaque,
        allocator: Allocator,
        tenant_id: cqrs.UUID,
        events: []const cqrs.DomainEvent,
    ) anyerror!void {
        const self: *PostgresAdapter = @ptrCast(@alignCast(ctx));
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        var txn = try postgres_pool.Transaction.init(conn);
        defer txn.deinit();

        const tenant_hex = try postgres_pool.uuid_to_hex(allocator, tenant_id);
        defer allocator.free(tenant_hex);

        const sql =
            \\INSERT INTO events (
            \\  id, tenant_id, aggregate_id, aggregate_type,
            \\  event_type, event_data, event_metadata, version,
            \\  timestamp, created_by
            \\) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ;

        for (events) |event| {
            const id_hex = try postgres_pool.uuid_to_hex(allocator, event.event_id);
            defer allocator.free(id_hex);
            const aggregate_id_hex = try postgres_pool.uuid_to_hex(allocator, event.aggregate_id);
            defer allocator.free(aggregate_id_hex);
            const user_id_hex = try postgres_pool.uuid_to_hex(allocator, event.user_id);
            defer allocator.free(user_id_hex);

            const version_str = try std.fmt.allocPrint(allocator, "{d}", .{event.version});
            defer allocator.free(version_str);
            const timestamp_str = try std.fmt.allocPrint(allocator, "{d}", .{event.timestamp});
            defer allocator.free(timestamp_str);

            _ = conn.exec(sql, &[_][]const u8{
                id_hex,
                tenant_hex,
                aggregate_id_hex,
                event.aggregate_type,
                event.event_type,
                event.data,
                "{}",
                version_str,
                timestamp_str,
                user_id_hex,
            }) catch |err| switch (err) {
                postgres_pool.PgError.UniqueViolation => return error.OptimisticConcurrencyConflict,
                else => return err,
            };
        }

        try txn.commit();
    }

    fn row_to_event(allocator: Allocator, row: postgres_pool.Row) !cqrs.DomainEvent {
        // Column order: id, tenant_id, aggregate_id, aggregate_type, event_type,
        //               event_data, version, timestamp, created_by, global_seq
        return cqrs.DomainEvent{
            .event_id = try postgres_pool.hex_to_uuid(row.values[0] orelse return error.MissingColumn),
            .tenant_id = try postgres_pool.hex_to_uuid(row.values[1] orelse return error.MissingColumn),
            .aggregate_id = try postgres_pool.hex_to_uuid(row.values[2] orelse return error.MissingColumn),
            .aggregate_type = try allocator.dupe(u8, row.values[3] orelse return error.MissingColumn),
            .event_type = try allocator.dupe(u8, row.values[4] orelse return error.MissingColumn),
            .data = try allocator.dupe(u8, row.values[5] orelse return error.MissingColumn),
            .version = try std.fmt.parseInt(u32, row.values[6] orelse return error.MissingColumn, 10),
            .timestamp = try std.fmt.parseInt(i64, row.values[7] orelse return error.MissingColumn, 10),
            .user_id = try postgres_pool.hex_to_uuid(row.values[8] orelse return error.MissingColumn),
            .global_seq = try std.fmt.parseInt(u64, row.values[9] orelse return error.MissingColumn, 10),
        };
    }

    fn get_events_impl(
        ctx: *anyopaque,
        allocator: Allocator,
        tenant_id: cqrs.UUID,
        aggregate_id: cqrs.UUID,
        aggregate_type: []const u8,
        after_version: u32,
    ) anyerror![]cqrs.DomainEvent {
        const self: *PostgresAdapter = @ptrCast(@alignCast(ctx));
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        const sql =
            \\SELECT id, tenant_id, aggregate_id, aggregate_type, event_type, event_data, version, timestamp, created_by, global_seq
            \\FROM events
            \\WHERE tenant_id = $1 AND aggregate_id = $2 AND aggregate_type = $3 AND version > $4
            \\ORDER BY version ASC
        ;

        const tenant_hex = try postgres_pool.uuid_to_hex(allocator, tenant_id);
        defer allocator.free(tenant_hex);
        const aggregate_id_hex = try postgres_pool.uuid_to_hex(allocator, aggregate_id);
        defer allocator.free(aggregate_id_hex);
        const after_version_str = try std.fmt.allocPrint(allocator, "{d}", .{after_version});
        defer allocator.free(after_version_str);

        var result = try conn.query(sql, &[_][]const u8{ tenant_hex, aggregate_id_hex, aggregate_type, after_version_str });
        defer result.deinit();

        var out: std.ArrayList(cqrs.DomainEvent) = .empty;
        for (result.rows.items) |row| {
            try out.append(allocator, try row_to_event(allocator, row));
        }
        return out.toOwnedSlice(allocator);
    }

    fn query_impl(
        ctx: *anyopaque,
        allocator: Allocator,
        tenant_id: cqrs.UUID,
        filters: cqrs.QueryFilters,
    ) anyerror![]cqrs.DomainEvent {
        const self: *PostgresAdapter = @ptrCast(@alignCast(ctx));
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        const tenant_hex = try postgres_pool.uuid_to_hex(allocator, tenant_id);
        defer allocator.free(tenant_hex);

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        try sql_buf.appendSlice(
            allocator,
            "SELECT id, tenant_id, aggregate_id, aggregate_type, event_type, event_data, version, timestamp, created_by, global_seq " ++
                "FROM events WHERE tenant_id = $1",
        );

        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(allocator);
        try args.append(allocator, tenant_hex);

        var after_seq_buf: [24]u8 = undefined;
        if (filters.after_seq) |seq| {
            const s = try std.fmt.bufPrint(&after_seq_buf, "{d}", .{seq});
            try args.append(allocator, s);
            try sql_buf.print(allocator, " AND global_seq > ${d}", .{args.items.len});
        }
        if (filters.aggregate_type) |at| {
            try args.append(allocator, at);
            try sql_buf.print(allocator, " AND aggregate_type = ${d}", .{args.items.len});
        }
        if (filters.event_type) |et| {
            try args.append(allocator, et);
            try sql_buf.print(allocator, " AND event_type = ${d}", .{args.items.len});
        }

        var start_buf: [32]u8 = undefined;
        if (filters.start_time) |st| {
            const s = try std.fmt.bufPrint(&start_buf, "{d}", .{st});
            try args.append(allocator, s);
            try sql_buf.print(allocator, " AND timestamp >= ${d}", .{args.items.len});
        }
        var end_buf: [32]u8 = undefined;
        if (filters.end_time) |et| {
            const s = try std.fmt.bufPrint(&end_buf, "{d}", .{et});
            try args.append(allocator, s);
            try sql_buf.print(allocator, " AND timestamp <= ${d}", .{args.items.len});
        }

        try sql_buf.appendSlice(allocator, " ORDER BY global_seq ASC");

        var limit_buf: [16]u8 = undefined;
        if (filters.limit) |limit| {
            const s = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
            try args.append(allocator, s);
            try sql_buf.print(allocator, " LIMIT ${d}", .{args.items.len});
        }

        var result = try conn.query(sql_buf.items, args.items);
        defer result.deinit();

        var out: std.ArrayList(cqrs.DomainEvent) = .empty;
        for (result.rows.items) |row| {
            try out.append(allocator, try row_to_event(allocator, row));
        }
        return out.toOwnedSlice(allocator);
    }

    // ========================================================================
    // IDEMPOTENCY
    // ========================================================================

    fn find_by_idempotency_key_impl(
        ctx: *anyopaque,
        allocator: Allocator,
        tenant_id: cqrs.UUID,
        key: []const u8,
    ) anyerror!?cqrs.IdempotencyResult {
        const self: *PostgresAdapter = @ptrCast(@alignCast(ctx));
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        const tenant_hex = try postgres_pool.uuid_to_hex(allocator, tenant_id);
        defer allocator.free(tenant_hex);

        const sql =
            \\SELECT command_type, result, created_at FROM idempotency_keys
            \\WHERE tenant_id = $1 AND idempotency_key = $2
        ;

        var result = try conn.query(sql, &[_][]const u8{ tenant_hex, key });
        defer result.deinit();

        const row = result.first() orelse return null;
        return cqrs.IdempotencyResult{
            .command_type = try allocator.dupe(u8, row.values[0] orelse return error.MissingColumn),
            .result = try allocator.dupe(u8, row.values[1] orelse return error.MissingColumn),
            .created_at = try std.fmt.parseInt(i64, row.values[2] orelse return error.MissingColumn, 10),
        };
    }

    fn store_idempotency_impl(
        ctx: *anyopaque,
        allocator: Allocator,
        tenant_id: cqrs.UUID,
        key: []const u8,
        result: cqrs.IdempotencyResult,
    ) anyerror!void {
        const self: *PostgresAdapter = @ptrCast(@alignCast(ctx));
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        const tenant_hex = try postgres_pool.uuid_to_hex(allocator, tenant_id);
        defer allocator.free(tenant_hex);

        const created_at_str = try std.fmt.allocPrint(allocator, "{d}", .{result.created_at});
        defer allocator.free(created_at_str);

        const sql =
            \\INSERT INTO idempotency_keys (tenant_id, idempotency_key, command_type, result, created_at)
            \\VALUES ($1, $2, $3, $4, $5)
            \\ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
        ;

        _ = try conn.exec(sql, &[_][]const u8{
            tenant_hex,
            key,
            result.command_type,
            result.result,
            created_at_str,
        });
    }

    fn deinit_impl(ctx: *anyopaque) void {
        _ = ctx;
    }
};

// ============================================================================
// POSTGRES CHECKPOINT STORE
// ============================================================================

/// PostgreSQL-backed CheckpointStore for production projection deployments.
/// Persists checkpoints in the `projection_checkpoints` table (created by
/// `PostgresAdapter.create_schema`). Obtain one with `to_store()`.
pub const PostgresCheckpointStore = struct {
    allocator: Allocator,
    pool: *postgres_pool.ConnectionPool,

    pub fn init(allocator: Allocator, pool: *postgres_pool.ConnectionPool) PostgresCheckpointStore {
        return .{ .allocator = allocator, .pool = pool };
    }

    pub fn to_store(self: *PostgresCheckpointStore) projection.CheckpointStore {
        return .{
            .ctx = self,
            .load_fn = load_impl,
            .save_fn = save_impl,
            .deinit_fn = deinit_impl,
        };
    }

    fn load_impl(ctx: *anyopaque, allocator: Allocator, name: []const u8) anyerror!u64 {
        _ = allocator;
        const self: *PostgresCheckpointStore = @ptrCast(@alignCast(ctx));
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        var result = try conn.query(
            "SELECT position FROM projection_checkpoints WHERE name = $1",
            &[_][]const u8{name},
        );
        defer result.deinit();

        const row = result.first() orelse return 0;
        return std.fmt.parseInt(u64, row.values[0] orelse return 0, 10) catch 0;
    }

    fn save_impl(ctx: *anyopaque, name: []const u8, position: u64) anyerror!void {
        const self: *PostgresCheckpointStore = @ptrCast(@alignCast(ctx));
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        const pos_str = try std.fmt.allocPrint(self.allocator, "{d}", .{position});
        defer self.allocator.free(pos_str);
        const now_str = try std.fmt.allocPrint(self.allocator, "{d}", .{nowMillis()});
        defer self.allocator.free(now_str);

        _ = try conn.exec(
            \\INSERT INTO projection_checkpoints (name, position, updated_at)
            \\VALUES ($1, $2, $3)
            \\ON CONFLICT (name) DO UPDATE SET position = EXCLUDED.position, updated_at = EXCLUDED.updated_at
        ,
            &[_][]const u8{ name, pos_str, now_str },
        );
    }

    fn deinit_impl(ctx: *anyopaque) void {
        _ = ctx;
    }
};

// ============================================================================
// SNAPSHOT STORE
// ============================================================================

/// PostgreSQL-backed SnapshotStore. One row per (tenant_id, aggregate_id);
/// saving a newer snapshot replaces the old one via ON CONFLICT DO UPDATE.
pub const PostgresSnapshotStore = struct {
    allocator: Allocator,
    pool: *postgres_pool.ConnectionPool,

    pub fn init(allocator: Allocator, pool: *postgres_pool.ConnectionPool) PostgresSnapshotStore {
        return .{ .allocator = allocator, .pool = pool };
    }

    pub fn to_store(self: *PostgresSnapshotStore) event_store.SnapshotStore {
        return .{
            .allocator = self.allocator,
            .context = self,
            .load_fn = load_impl,
            .save_fn = save_impl,
            .deinit_fn = deinit_impl,
        };
    }

    fn load_impl(ctx: *anyopaque, allocator: Allocator, tenant_id: cqrs.UUID, aggregate_id: cqrs.UUID, aggregate_type: []const u8) anyerror!?cqrs.Snapshot {
        const self: *PostgresSnapshotStore = @ptrCast(@alignCast(ctx));
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        const tenant_hex = try postgres_pool.uuid_to_hex(allocator, tenant_id);
        defer allocator.free(tenant_hex);
        const agg_hex = try postgres_pool.uuid_to_hex(allocator, aggregate_id);
        defer allocator.free(agg_hex);

        var result = try conn.query(
            \\SELECT aggregate_type, version, state, created_at
            \\FROM snapshots
            \\WHERE tenant_id = $1 AND aggregate_id = $2
        ,
            &[_][]const u8{ tenant_hex, agg_hex },
        );
        defer result.deinit();

        const row = result.first() orelse return null;
        _ = aggregate_type; // the caller provides this for type-safety; DB is the source of truth
        return cqrs.Snapshot{
            .aggregate_id = aggregate_id,
            .aggregate_type = try allocator.dupe(u8, row.values[0] orelse return error.MissingColumn),
            .version = try std.fmt.parseInt(u32, row.values[1] orelse return error.MissingColumn, 10),
            .state = try allocator.dupe(u8, row.values[2] orelse return error.MissingColumn),
            .created_at = try std.fmt.parseInt(i64, row.values[3] orelse return error.MissingColumn, 10),
        };
    }

    fn save_impl(ctx: *anyopaque, tenant_id: cqrs.UUID, snapshot: cqrs.Snapshot) anyerror!void {
        const self: *PostgresSnapshotStore = @ptrCast(@alignCast(ctx));
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        const tenant_hex = try postgres_pool.uuid_to_hex(self.allocator, tenant_id);
        defer self.allocator.free(tenant_hex);
        const agg_hex = try postgres_pool.uuid_to_hex(self.allocator, snapshot.aggregate_id);
        defer self.allocator.free(agg_hex);
        const version_str = try std.fmt.allocPrint(self.allocator, "{d}", .{snapshot.version});
        defer self.allocator.free(version_str);
        const created_at_str = try std.fmt.allocPrint(self.allocator, "{d}", .{snapshot.created_at});
        defer self.allocator.free(created_at_str);

        _ = try conn.exec(
            \\INSERT INTO snapshots (tenant_id, aggregate_id, aggregate_type, version, state, created_at)
            \\VALUES ($1, $2, $3, $4, $5, $6)
            \\ON CONFLICT (tenant_id, aggregate_id)
            \\DO UPDATE SET aggregate_type = EXCLUDED.aggregate_type,
            \\              version = EXCLUDED.version,
            \\              state = EXCLUDED.state,
            \\              created_at = EXCLUDED.created_at
        ,
            &[_][]const u8{ tenant_hex, agg_hex, snapshot.aggregate_type, version_str, snapshot.state, created_at_str },
        );
    }

    fn deinit_impl(ctx: *anyopaque) void {
        _ = ctx;
    }
};

// ============================================================================
// TESTS
// ============================================================================
// libpq_mock always refuses to connect, so these confirm the adapter wires
// up to the pool correctly and surfaces the connection error rather than
// exercising real SQL (that requires an actual Postgres instance).

const std_testing = std.testing;

test "PostgresAdapter.to_adapter satisfies the EventStoreAdapter shape" {
    // This test exercises the mock libpq path (connection always fails).
    // Skip when a real database URL is present so it doesn't interfere
    // with the integration test suite which uses actual libpq.
    if (std.c.getenv("ATOMIK_DATABASE_URL") != null) return error.SkipZigTest;

    var pool = try postgres_pool.ConnectionPool.init(std_testing.allocator, "postgres://localhost/db", 1);
    defer pool.deinit();

    var pg_adapter = PostgresAdapter.init(std_testing.allocator, &pool);
    var adapter = pg_adapter.to_adapter();
    defer adapter.deinit();

    try std_testing.expectError(postgres_pool.PgError.ConnectionFailed, adapter.create_schema());
}
