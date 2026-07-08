//! Repository pattern: thin, direct-SQL access to the event store and audit
//! log, as an alternative to the vtable-based EventStoreAdapter for callers
//! who want to drive a `postgres_pool.ConnectionPool` directly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cqrs = @import("cqrs.zig");
const postgres_pool = @import("postgres_pool.zig");

fn uuid_to_hex(allocator: Allocator, uuid: cqrs.UUID) ![]const u8 {
    const hex_chars = "0123456789abcdef";
    const hex = try allocator.alloc(u8, 32);
    for (uuid, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return hex;
}

/// Event Repository — Append-only event store access
pub const EventRepository = struct {
    allocator: Allocator,
    pool: *postgres_pool.ConnectionPool,

    pub fn init(allocator: Allocator, pool: *postgres_pool.ConnectionPool) EventRepository {
        return EventRepository{
            .allocator = allocator,
            .pool = pool,
        };
    }

    /// Append events atomically to the event store
    pub fn append(
        self: *EventRepository,
        tenant_id: cqrs.UUID,
        events: []const cqrs.DomainEvent,
    ) !void {
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        var txn = try postgres_pool.Transaction.init(conn);
        defer txn.deinit();

        const tenant_hex = try uuid_to_hex(self.allocator, tenant_id);
        defer self.allocator.free(tenant_hex);

        const sql =
            \\INSERT INTO events (
            \\  id, tenant_id, aggregate_id, aggregate_type,
            \\  event_type, event_data, event_metadata, version,
            \\  timestamp, created_by
            \\) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ;

        for (events) |event| {
            const id_hex = try uuid_to_hex(self.allocator, event.event_id);
            defer self.allocator.free(id_hex);
            const aggregate_id_hex = try uuid_to_hex(self.allocator, event.aggregate_id);
            defer self.allocator.free(aggregate_id_hex);
            const user_id_hex = try uuid_to_hex(self.allocator, event.user_id);
            defer self.allocator.free(user_id_hex);

            const version_str = try std.fmt.allocPrint(self.allocator, "{d}", .{event.version});
            defer self.allocator.free(version_str);
            const timestamp_str = try std.fmt.allocPrint(self.allocator, "{d}", .{event.timestamp});
            defer self.allocator.free(timestamp_str);

            _ = try conn.exec(sql, &[_][]const u8{
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
            });
        }

        try txn.commit();
    }

    /// Get events for an aggregate, in version order
    pub fn get_events(
        self: *EventRepository,
        tenant_id: cqrs.UUID,
        aggregate_id: cqrs.UUID,
        aggregate_type: []const u8,
    ) !postgres_pool.ResultSet {
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        const tenant_hex = try uuid_to_hex(self.allocator, tenant_id);
        defer self.allocator.free(tenant_hex);
        const aggregate_id_hex = try uuid_to_hex(self.allocator, aggregate_id);
        defer self.allocator.free(aggregate_id_hex);

        const sql =
            \\SELECT id, tenant_id, aggregate_id, aggregate_type, event_type, event_data, version, timestamp, created_by
            \\FROM events
            \\WHERE tenant_id = $1 AND aggregate_id = $2 AND aggregate_type = $3
            \\ORDER BY version ASC
        ;

        return conn.query(sql, &[_][]const u8{ tenant_hex, aggregate_id_hex, aggregate_type });
    }

    /// Check idempotency key
    pub fn get_idempotency_result(
        self: *EventRepository,
        tenant_id: cqrs.UUID,
        key: []const u8,
    ) !?postgres_pool.Row {
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        const tenant_hex = try uuid_to_hex(self.allocator, tenant_id);
        defer self.allocator.free(tenant_hex);

        const sql =
            \\SELECT command_type, result, created_at FROM idempotency_keys
            \\WHERE tenant_id = $1 AND idempotency_key = $2
        ;

        var result = try conn.query(sql, &[_][]const u8{ tenant_hex, key });
        defer result.deinit();

        return result.first();
    }

    /// Store idempotency result
    pub fn store_idempotency(
        self: *EventRepository,
        tenant_id: cqrs.UUID,
        key: []const u8,
        result: cqrs.IdempotencyResult,
    ) !void {
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        const tenant_hex = try uuid_to_hex(self.allocator, tenant_id);
        defer self.allocator.free(tenant_hex);

        const created_at_str = try std.fmt.allocPrint(self.allocator, "{d}", .{result.created_at});
        defer self.allocator.free(created_at_str);

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
};

/// Audit Log Repository — Compliance logging
pub const AuditLogRepository = struct {
    allocator: Allocator,
    pool: *postgres_pool.ConnectionPool,

    pub fn init(allocator: Allocator, pool: *postgres_pool.ConnectionPool) AuditLogRepository {
        return AuditLogRepository{
            .allocator = allocator,
            .pool = pool,
        };
    }

    /// Log an audit event
    pub fn log_event(
        self: *AuditLogRepository,
        event: cqrs.AuditEvent,
    ) !void {
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        const id_hex = try uuid_to_hex(self.allocator, event.audit_event_id);
        defer self.allocator.free(id_hex);
        const tenant_hex = try uuid_to_hex(self.allocator, event.tenant_id);
        defer self.allocator.free(tenant_hex);
        const user_hex = try uuid_to_hex(self.allocator, event.user_id);
        defer self.allocator.free(user_hex);

        const sql =
            \\INSERT INTO audit_logs (
            \\  id, tenant_id, event_type, user_id,
            \\  ip_address, user_agent, timestamp
            \\) VALUES ($1, $2, $3, $4, $5, $6, $7)
        ;

        const timestamp_str = try std.fmt.allocPrint(self.allocator, "{d}", .{event.timestamp});
        defer self.allocator.free(timestamp_str);

        _ = try conn.exec(sql, &[_][]const u8{
            id_hex,
            tenant_hex,
            event.event_type,
            user_hex,
            event.ip_address orelse "",
            event.user_agent orelse "",
            timestamp_str,
        });
    }

    /// Query audit log
    pub fn query_audit_log(
        self: *AuditLogRepository,
        tenant_id: cqrs.UUID,
        limit: u32,
        offset: u32,
    ) !postgres_pool.ResultSet {
        const conn = try self.pool.get_connection();
        defer self.pool.release_connection(conn);

        const tenant_hex = try uuid_to_hex(self.allocator, tenant_id);
        defer self.allocator.free(tenant_hex);

        const sql =
            \\SELECT * FROM audit_logs
            \\WHERE tenant_id = $1
            \\ORDER BY timestamp DESC
            \\LIMIT $2 OFFSET $3
        ;

        const limit_str = try std.fmt.allocPrint(self.allocator, "{d}", .{limit});
        defer self.allocator.free(limit_str);

        const offset_str = try std.fmt.allocPrint(self.allocator, "{d}", .{offset});
        defer self.allocator.free(offset_str);

        return conn.query(sql, &[_][]const u8{
            tenant_hex,
            limit_str,
            offset_str,
        });
    }
};

// ============================================================================
// TESTS
// ============================================================================
// libpq_mock always refuses to connect, so these confirm the repositories
// propagate the pool's connection error rather than exercising real SQL.

test "EventRepository.append surfaces connection failure from the mock backend" {
    var pool = try postgres_pool.ConnectionPool.init(std.testing.allocator, "postgres://localhost/db", 1);
    defer pool.deinit();

    var repo = EventRepository.init(std.testing.allocator, &pool);
    const tenant_id = cqrs.generate_uuid();

    try std.testing.expectError(
        postgres_pool.PgError.ConnectionFailed,
        repo.append(tenant_id, &[_]cqrs.DomainEvent{}),
    );
}

test "AuditLogRepository.log_event surfaces connection failure from the mock backend" {
    var pool = try postgres_pool.ConnectionPool.init(std.testing.allocator, "postgres://localhost/db", 1);
    defer pool.deinit();

    var repo = AuditLogRepository.init(std.testing.allocator, &pool);

    try std.testing.expectError(postgres_pool.PgError.ConnectionFailed, repo.log_event(.{
        .audit_event_id = cqrs.generate_uuid(),
        .tenant_id = cqrs.generate_uuid(),
        .event_type = "DATA_EXPORTED",
        .user_id = cqrs.generate_uuid(),
        .timestamp = 0,
    }));
}
