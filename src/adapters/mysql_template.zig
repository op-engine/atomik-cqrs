//! DATABASE ADAPTER TEMPLATE: MySQL/MariaDB
//! ==========================================
//! Template for implementing the EventStoreAdapter interface against
//! MySQL. Copy this file and replace the TODO sections with a real
//! MySQL client implementation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const event_store = @import("../event_store.zig");
const cqrs = @import("../cqrs.zig");

pub const MySQLAdapter = struct {
    allocator: Allocator,
    // TODO: Add your MySQL connection pool type here
    // Example: client: *mysql.ConnectionPool,

    pub fn init(allocator: Allocator) !MySQLAdapter {
        // TODO: Initialize MySQL connection pool
        // Example: const pool = try mysql.ConnectionPool.init(allocator, connection_string);
        return MySQLAdapter{
            .allocator = allocator,
            // .client = pool,
        };
    }

    /// Convert to the generic EventStoreAdapter interface.
    pub fn to_adapter(self: *MySQLAdapter) event_store.EventStoreAdapter {
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
    // IMPLEMENTATION FUNCTIONS
    // Replace TODO sections with MySQL-specific calls.
    // ========================================================================

    fn create_schema_impl(ctx: *anyopaque) anyerror!void {
        _ = ctx;
        // TODO: Execute MySQL DDL to create the generic event-sourcing schema.
        // CREATE TABLE IF NOT EXISTS events (
        //   id BINARY(16) PRIMARY KEY,
        //   tenant_id BINARY(16) NOT NULL,
        //   aggregate_id BINARY(16) NOT NULL,
        //   aggregate_type VARCHAR(128) NOT NULL,
        //   event_type VARCHAR(128) NOT NULL,
        //   event_data JSON NOT NULL,
        //   event_metadata JSON,
        //   version INT NOT NULL,
        //   timestamp BIGINT NOT NULL,
        //   created_by BINARY(16) NOT NULL,
        //   INDEX idx_aggregate (tenant_id, aggregate_id, version ASC),
        //   INDEX idx_type (tenant_id, aggregate_type, event_type, timestamp DESC)
        // );
        //
        // CREATE TABLE IF NOT EXISTS idempotency_keys (
        //   tenant_id BINARY(16) NOT NULL,
        //   idempotency_key VARCHAR(256) NOT NULL,
        //   command_type VARCHAR(128) NOT NULL,
        //   result JSON NOT NULL,
        //   created_at BIGINT NOT NULL,
        //   PRIMARY KEY (tenant_id, idempotency_key)
        // );
        //
        // CREATE TABLE IF NOT EXISTS audit_logs (
        //   id BINARY(16) PRIMARY KEY,
        //   tenant_id BINARY(16) NOT NULL,
        //   event_type VARCHAR(128) NOT NULL,
        //   user_id BINARY(16) NOT NULL,
        //   ip_address VARCHAR(64),
        //   user_agent VARCHAR(256),
        //   timestamp BIGINT NOT NULL,
        //   INDEX idx_tenant (tenant_id, timestamp DESC)
        // );
    }

    fn append_events_impl(
        ctx: *anyopaque,
        allocator: Allocator,
        tenant_id: cqrs.UUID,
        events: []const cqrs.DomainEvent,
    ) anyerror!void {
        _ = ctx;
        _ = allocator;
        _ = tenant_id;
        _ = events;

        // TODO: INSERT each event into `events` within a transaction.
    }

    fn get_events_impl(
        ctx: *anyopaque,
        allocator: Allocator,
        tenant_id: cqrs.UUID,
        aggregate_id: cqrs.UUID,
        aggregate_type: []const u8,
    ) anyerror![]cqrs.DomainEvent {
        _ = ctx;
        _ = tenant_id;
        _ = aggregate_id;
        _ = aggregate_type;

        // TODO: SELECT * FROM events
        //       WHERE tenant_id = ? AND aggregate_id = ? AND aggregate_type = ?
        //       ORDER BY version ASC
        return allocator.alloc(cqrs.DomainEvent, 0);
    }

    fn query_impl(
        ctx: *anyopaque,
        allocator: Allocator,
        tenant_id: cqrs.UUID,
        filters: cqrs.QueryFilters,
    ) anyerror![]cqrs.DomainEvent {
        _ = ctx;
        _ = tenant_id;
        _ = filters;

        // TODO: SELECT * FROM events WHERE tenant_id = ? [AND aggregate_type = ?]
        //       [AND event_type = ?] [AND timestamp BETWEEN ? AND ?] [LIMIT ?]
        return allocator.alloc(cqrs.DomainEvent, 0);
    }

    fn find_by_idempotency_key_impl(
        ctx: *anyopaque,
        allocator: Allocator,
        tenant_id: cqrs.UUID,
        key: []const u8,
    ) anyerror!?cqrs.IdempotencyResult {
        _ = ctx;
        _ = allocator;
        _ = tenant_id;
        _ = key;

        // TODO: SELECT command_type, result, created_at FROM idempotency_keys
        //       WHERE tenant_id = ? AND idempotency_key = ?
        return null;
    }

    fn store_idempotency_impl(
        ctx: *anyopaque,
        allocator: Allocator,
        tenant_id: cqrs.UUID,
        key: []const u8,
        result: cqrs.IdempotencyResult,
    ) anyerror!void {
        _ = ctx;
        _ = allocator;
        _ = tenant_id;
        _ = key;
        _ = result;

        // TODO: INSERT INTO idempotency_keys (...) VALUES (...)
        //       ON DUPLICATE KEY UPDATE idempotency_key = idempotency_key
    }

    fn deinit_impl(ctx: *anyopaque) void {
        _ = ctx;
        // TODO: Cleanup MySQL connection pool
    }
};

// ============================================================================
// USAGE EXAMPLE
// ============================================================================
// var mysql_adapter_instance = try MySQLAdapter.init(allocator);
// var db_adapter = mysql_adapter_instance.to_adapter();
