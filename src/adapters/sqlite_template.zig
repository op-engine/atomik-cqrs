//! DATABASE ADAPTER TEMPLATE: SQLite
//! ===================================
//! Template for implementing the EventStoreAdapter interface against
//! SQLite. Useful for embedded deployments, local development, and
//! single-user scenarios.

const std = @import("std");
const Allocator = std.mem.Allocator;
const event_store = @import("../event_store.zig");
const cqrs = @import("../cqrs.zig");

pub const SQLiteAdapter = struct {
    allocator: Allocator,
    // TODO: Add your SQLite client type here
    // Example: client: *sqlite.Connection,

    pub fn init(allocator: Allocator) !SQLiteAdapter {
        // TODO: Open SQLite database
        // Example: const db = try sqlite.Connection.open(allocator, "atomik.db");
        return SQLiteAdapter{
            .allocator = allocator,
            // .client = db,
        };
    }

    /// Convert to the generic EventStoreAdapter interface.
    pub fn to_adapter(self: *SQLiteAdapter) event_store.EventStoreAdapter {
        return .{
            .allocator = self.allocator,
            .context = self,
            .create_schema_fn = &create_schema_impl,
            .append_events_fn = &append_events_impl,
            .get_events_fn = &get_events_impl,
            .query_fn = &query_impl,
            .free_events_fn = &free_events_impl,
            .find_by_idempotency_key_fn = &find_by_idempotency_key_impl,
            .store_idempotency_fn = &store_idempotency_impl,
            .deinit_fn = &deinit_impl,
        };
    }

    // ========================================================================
    // IMPLEMENTATION FUNCTIONS
    // Replace TODO sections with SQLite-specific calls.
    // ========================================================================

    fn create_schema_impl(ctx: *anyopaque) anyerror!void {
        _ = ctx;
        // TODO: Execute SQLite DDL for the generic event-sourcing schema.
        // CREATE TABLE IF NOT EXISTS events (
        //   id BLOB PRIMARY KEY,
        //   tenant_id BLOB NOT NULL,
        //   aggregate_id BLOB NOT NULL,
        //   aggregate_type TEXT NOT NULL,
        //   event_type TEXT NOT NULL,
        //   event_data TEXT NOT NULL,
        //   event_metadata TEXT,
        //   version INTEGER NOT NULL,
        //   timestamp INTEGER NOT NULL,
        //   created_by BLOB NOT NULL
        // );
        // CREATE INDEX IF NOT EXISTS idx_aggregate ON events(tenant_id, aggregate_id, version ASC);
        // CREATE INDEX IF NOT EXISTS idx_type ON events(tenant_id, aggregate_type, event_type, timestamp DESC);
        //
        // CREATE TABLE IF NOT EXISTS idempotency_keys (
        //   tenant_id BLOB NOT NULL,
        //   idempotency_key TEXT NOT NULL,
        //   command_type TEXT NOT NULL,
        //   result TEXT NOT NULL,
        //   created_at INTEGER NOT NULL,
        //   PRIMARY KEY (tenant_id, idempotency_key)
        // );
        //
        // CREATE TABLE IF NOT EXISTS audit_logs (
        //   id BLOB PRIMARY KEY,
        //   tenant_id BLOB NOT NULL,
        //   event_type TEXT NOT NULL,
        //   user_id BLOB NOT NULL,
        //   ip_address TEXT,
        //   user_agent TEXT,
        //   timestamp INTEGER NOT NULL
        // );
        // CREATE INDEX IF NOT EXISTS idx_audit_tenant ON audit_logs(tenant_id, timestamp DESC);
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
        // Use parameterized queries to prevent SQL injection.
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

    fn free_events_impl(ctx: *anyopaque, allocator: Allocator, events: []const cqrs.DomainEvent) void {
        _ = ctx;
        // TODO: once get_events_impl/query_impl allocate real per-event string
        // fields (aggregate_type/event_type/data) from a row, free those here
        // too via cqrs.DomainEvent.free_slice instead of a plain slice free -
        // see adapters/postgres.zig's free_events_impl for the pattern.
        allocator.free(events);
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

        // TODO: INSERT OR IGNORE INTO idempotency_keys (...) VALUES (...)
    }

    fn deinit_impl(ctx: *anyopaque) void {
        _ = ctx;
        // TODO: Close SQLite database
    }
};

// ============================================================================
// USAGE EXAMPLE
// ============================================================================
// var sqlite_adapter_instance = try SQLiteAdapter.init(allocator);
// var db_adapter = sqlite_adapter_instance.to_adapter();
