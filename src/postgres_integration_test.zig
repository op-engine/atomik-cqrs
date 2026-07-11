//! Integration tests for the PostgreSQL adapter and checkpoint store.
//! These tests require a real Postgres instance and will skip automatically
//! when ATOMIK_DATABASE_URL is not set. Run via:
//!   bun run integration/run.ts
//! which provisions an ephemeral Neon database and sets the env var before
//! invoking `zig build test-integration`.

const std = @import("std");
const postgres_pool = @import("postgres_pool.zig");
const cqrs = @import("cqrs.zig");
const event_store = @import("event_store.zig");
const repositories = @import("repositories.zig");
const projection = @import("projection.zig");
const pg = @import("adapters/postgres.zig");

// ============================================================================
// HELPERS
// ============================================================================

// std.time.milliTimestamp / nanoTimestamp were removed in Zig 0.16.
// Use POSIX clock_gettime (available because integration_mod links libc).
fn nowMillis() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn nowNanos() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

fn open_pool() !postgres_pool.ConnectionPool {
    const url_ptr = std.c.getenv("ATOMIK_DATABASE_URL") orelse return error.SkipZigTest;
    const url = std.mem.span(url_ptr);
    return postgres_pool.ConnectionPool.init(std.testing.allocator, url, 1);
}

fn make_adapter(pool: *postgres_pool.ConnectionPool) event_store.EventStoreAdapter {
    // PostgresAdapter.to_adapter() stores &self as EventStoreAdapter.context, so the adapter
    // must outlive this function - a local/stack `impl` here returns a dangling context pointer
    // the moment make_adapter returns. This was always latent (undefined behavior reading
    // reclaimed stack memory) but silently tolerated because release_connection used to be a
    // total no-op; it surfaced once release_connection actually started dereferencing `self`.
    // Deliberately leaked via page_allocator (not std.testing.allocator, which would flag it as
    // a leak): a tiny, one-shot, process-lifetime allocation, simpler than threading a free
    // through all 18 call sites in a short-lived test binary.
    const impl = std.heap.page_allocator.create(pg.PostgresAdapter) catch @panic("OOM");
    impl.* = pg.PostgresAdapter.init(std.testing.allocator, pool);
    return impl.to_adapter();
}

fn free_events(events: []cqrs.DomainEvent) void {
    cqrs.DomainEvent.free_slice(std.testing.allocator, events);
}

fn jsonValueEql(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |av| b == .bool and av == b.bool,
        .integer => |av| switch (b) {
            .integer => |bv| av == bv,
            .float => |bv| @as(f64, @floatFromInt(av)) == bv,
            else => false,
        },
        .float => |av| switch (b) {
            .float => |bv| av == bv,
            .integer => |bv| av == @as(f64, @floatFromInt(bv)),
            else => false,
        },
        .number_string => |av| switch (b) {
            .number_string => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        .string => |av| switch (b) {
            .string => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        .array => |av| switch (b) {
            .array => |bv| blk: {
                if (av.items.len != bv.items.len) break :blk false;
                for (av.items, bv.items) |ai, bi| {
                    if (!jsonValueEql(ai, bi)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .object => |av| switch (b) {
            .object => |bv| blk: {
                if (av.count() != bv.count()) break :blk false;
                var it = av.iterator();
                while (it.next()) |entry| {
                    const bval = bv.get(entry.key_ptr.*) orelse break :blk false;
                    if (!jsonValueEql(entry.value_ptr.*, bval)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
    };
}

// Postgres's JSONB columns canonically re-serialize on write (e.g. adding a
// space after ':'), so byte-for-byte string comparison of round-tripped JSON
// is the wrong check. Compare parsed structure instead.
fn expectJsonEqualStrings(expected: []const u8, actual: []const u8) !void {
    const alloc = std.testing.allocator;
    var parsed_expected = try std.json.parseFromSlice(std.json.Value, alloc, expected, .{});
    defer parsed_expected.deinit();
    var parsed_actual = try std.json.parseFromSlice(std.json.Value, alloc, actual, .{});
    defer parsed_actual.deinit();
    if (!jsonValueEql(parsed_expected.value, parsed_actual.value)) {
        std.debug.print("JSON mismatch:\n  expected: {s}\n  actual:   {s}\n", .{ expected, actual });
        return error.TestExpectedEqual;
    }
}

fn make_event(tenant_id: cqrs.UUID, aggregate_id: cqrs.UUID, event_type: []const u8, version: u32) cqrs.DomainEvent {
    return .{
        .event_id = cqrs.generate_uuid(),
        .aggregate_id = aggregate_id,
        .aggregate_type = "Order",
        .event_type = event_type,
        .tenant_id = tenant_id,
        .version = version,
        .timestamp = @intCast(nowMillis()),
        .user_id = cqrs.generate_uuid(),
        .data = "{}",
    };
}

// ============================================================================
// SCHEMA
// ============================================================================

test "create_schema is idempotent" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();

    try adapter.create_schema();
    try adapter.create_schema(); // IF NOT EXISTS: must not fail on second call
}

// ============================================================================
// EVENTS
// ============================================================================

test "append_events and get_events round-trip" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    const tenant_id = cqrs.generate_uuid();
    const aggregate_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        make_event(tenant_id, aggregate_id, "OrderCreated", 1),
        make_event(tenant_id, aggregate_id, "OrderConfirmed", 2),
    });

    const events = try adapter.get_events(tenant_id, aggregate_id, "Order", 0);
    defer free_events(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("OrderCreated", events[0].event_type);
    try std.testing.expectEqualStrings("OrderConfirmed", events[1].event_type);
    try std.testing.expectEqual(@as(u32, 1), events[0].version);
    try std.testing.expectEqual(@as(u32, 2), events[1].version);
}

test "get_events returns events in version ascending order" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    const tenant_id = cqrs.generate_uuid();
    const aggregate_id = cqrs.generate_uuid();

    // Postgres preserves insert order, but the ORDER BY version ASC in
    // get_events_impl must hold even if rows were written in any order.
    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        make_event(tenant_id, aggregate_id, "OrderShipped", 3),
        make_event(tenant_id, aggregate_id, "OrderCreated", 1),
        make_event(tenant_id, aggregate_id, "OrderConfirmed", 2),
    });

    const events = try adapter.get_events(tenant_id, aggregate_id, "Order", 0);
    defer free_events(events);

    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(@as(u32, 1), events[0].version);
    try std.testing.expectEqual(@as(u32, 2), events[1].version);
    try std.testing.expectEqual(@as(u32, 3), events[2].version);
}

test "append_events enforces OCC via unique version constraint" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    const tenant_id = cqrs.generate_uuid();
    const aggregate_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        make_event(tenant_id, aggregate_id, "OrderCreated", 1),
    });

    // A concurrent write at the same version must fail with OCC conflict,
    // not silently overwrite. This is the core correctness guarantee.
    try std.testing.expectError(
        error.OptimisticConcurrencyConflict,
        adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
            make_event(tenant_id, aggregate_id, "OrderCreated", 1),
        }),
    );
}

test "get_events enforces tenant isolation" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    const tenant_a = cqrs.generate_uuid();
    const tenant_b = cqrs.generate_uuid();
    const agg_a = cqrs.generate_uuid();
    const agg_b = cqrs.generate_uuid();

    try adapter.append_events(tenant_a, &[_]cqrs.DomainEvent{
        make_event(tenant_a, agg_a, "OrderCreated", 1),
    });
    try adapter.append_events(tenant_b, &[_]cqrs.DomainEvent{
        make_event(tenant_b, agg_b, "OrderCreated", 1),
    });

    const a_events = try adapter.get_events(tenant_a, agg_a, "Order", 0);
    defer free_events(a_events);
    try std.testing.expectEqual(@as(usize, 1), a_events.len);

    const cross = try adapter.get_events(tenant_a, agg_b, "Order", 0);
    defer free_events(cross);
    try std.testing.expectEqual(@as(usize, 0), cross.len);
}

// ============================================================================
// QUERY FILTERS
// ============================================================================

test "query filters by aggregate_type" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    const tenant_id = cqrs.generate_uuid();
    const agg = cqrs.generate_uuid();

    const order_event = make_event(tenant_id, agg, "OrderCreated", 1);
    var invoice_event = make_event(tenant_id, cqrs.generate_uuid(), "InvoiceIssued", 1);
    invoice_event.aggregate_type = "Invoice";

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{ order_event, invoice_event });

    const results = try adapter.query(tenant_id, .{ .aggregate_type = "Invoice" });
    defer free_events(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("InvoiceIssued", results[0].event_type);
}

test "query filters by event_type" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    const tenant_id = cqrs.generate_uuid();
    const agg = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        make_event(tenant_id, agg, "OrderCreated", 1),
        make_event(tenant_id, cqrs.generate_uuid(), "OrderShipped", 1),
        make_event(tenant_id, cqrs.generate_uuid(), "OrderCreated", 1),
    });

    const results = try adapter.query(tenant_id, .{ .event_type = "OrderCreated" });
    defer free_events(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |e| try std.testing.expectEqualStrings("OrderCreated", e.event_type);
}

test "query respects limit" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    const tenant_id = cqrs.generate_uuid();
    const agg = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        make_event(tenant_id, agg, "E1", 1),
        make_event(tenant_id, cqrs.generate_uuid(), "E2", 1),
        make_event(tenant_id, cqrs.generate_uuid(), "E3", 1),
    });

    const results = try adapter.query(tenant_id, .{ .limit = 2 });
    defer free_events(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "query filters by after_seq and returns events in global_seq order" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    const tenant_id = cqrs.generate_uuid();
    const agg = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        make_event(tenant_id, agg, "E1", 1),
        make_event(tenant_id, cqrs.generate_uuid(), "E2", 1),
        make_event(tenant_id, cqrs.generate_uuid(), "E3", 1),
    });

    // Get all three to learn the first event's global_seq.
    const all = try adapter.query(tenant_id, .{});
    defer free_events(all);
    try std.testing.expectEqual(@as(usize, 3), all.len);

    const seq1 = all[0].global_seq;
    try std.testing.expect(seq1 > 0);

    const after = try adapter.query(tenant_id, .{ .after_seq = seq1 });
    defer free_events(after);

    try std.testing.expectEqual(@as(usize, 2), after.len);
    try std.testing.expectEqualStrings("E2", after[0].event_type);
    try std.testing.expectEqualStrings("E3", after[1].event_type);
}

// ============================================================================
// IDEMPOTENCY
// ============================================================================

test "idempotency store and retrieve round-trip" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    const tenant_id = cqrs.generate_uuid();
    // Use a unique key so parallel runs don't collide.
    var key_buf: [64]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "idem-{}", .{nowNanos()});

    const not_found = try adapter.find_by_idempotency_key(tenant_id, key);
    try std.testing.expectEqual(@as(?cqrs.IdempotencyResult, null), not_found);

    try adapter.store_idempotency(tenant_id, key, .{
        .command_type = "CreateOrder",
        .result = "{\"order_id\":\"abc\"}",
        .created_at = 1000,
    });

    const found = try adapter.find_by_idempotency_key(tenant_id, key);
    try std.testing.expect(found != null);
    defer {
        if (found) |r| {
            std.testing.allocator.free(r.command_type);
            std.testing.allocator.free(r.result);
        }
    }
    try std.testing.expectEqualStrings("CreateOrder", found.?.command_type);
    try expectJsonEqualStrings("{\"order_id\":\"abc\"}", found.?.result);
}

test "idempotency first write wins on duplicate key" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    const tenant_id = cqrs.generate_uuid();
    var key_buf: [64]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "idem-dup-{}", .{nowNanos()});

    try adapter.store_idempotency(tenant_id, key, .{
        .command_type = "CreateOrder",
        .result = "{\"order_id\":\"first\"}",
        .created_at = 1,
    });
    try adapter.store_idempotency(tenant_id, key, .{
        .command_type = "CreateOrder",
        .result = "{\"order_id\":\"second\"}",
        .created_at = 2,
    });

    const found = try adapter.find_by_idempotency_key(tenant_id, key);
    try std.testing.expect(found != null);
    defer {
        if (found) |r| {
            std.testing.allocator.free(r.command_type);
            std.testing.allocator.free(r.result);
        }
    }
    try expectJsonEqualStrings("{\"order_id\":\"first\"}", found.?.result);
}

// ============================================================================
// CHECKPOINTS
// ============================================================================

test "PostgresCheckpointStore saves and loads position" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    var cp_impl = pg.PostgresCheckpointStore.init(std.testing.allocator, &pool);
    var checkpoints = cp_impl.to_store();
    defer checkpoints.deinit();

    // Use a unique name to avoid collision with other test runs.
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "proj-{}", .{nowNanos()});

    const initial = try checkpoints.load(std.testing.allocator, name);
    try std.testing.expectEqual(@as(u64, 0), initial);

    try checkpoints.save(name, 42);

    const loaded = try checkpoints.load(std.testing.allocator, name);
    try std.testing.expectEqual(@as(u64, 42), loaded);

    // Update is idempotent; should overwrite, not insert a duplicate.
    try checkpoints.save(name, 99);
    const updated = try checkpoints.load(std.testing.allocator, name);
    try std.testing.expectEqual(@as(u64, 99), updated);
}

// ============================================================================
// FULL PROJECTION LOOP
// ============================================================================

test "ProjectionRunner processes events via PostgresAdapter and advances checkpoint" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    var cp_impl = pg.PostgresCheckpointStore.init(std.testing.allocator, &pool);
    const checkpoints = cp_impl.to_store();
    var runner = projection.ProjectionRunner.init(std.testing.allocator, &adapter, checkpoints);
    defer runner.deinit();

    const tenant_id = cqrs.generate_uuid();
    const agg = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        make_event(tenant_id, agg, "OrderCreated", 1),
        make_event(tenant_id, agg, "OrderShipped", 2),
    });

    var name_buf: [64]u8 = undefined;
    const proj_name = try std.fmt.bufPrint(&name_buf, "pg-proj-{}", .{nowNanos()});

    var count: usize = 0;
    const proj = projection.Projection{
        .name = proj_name,
        .tenant_id = tenant_id,
        .filters = .{},
        .apply = struct {
            fn apply(ctx: *anyopaque, _: cqrs.DomainEvent) anyerror!void {
                const c: *usize = @ptrCast(@alignCast(ctx));
                c.* += 1;
            }
        }.apply,
        .ctx = &count,
    };

    const first = try runner.run(proj);
    try std.testing.expectEqual(@as(usize, 2), first.events_processed);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(first.last_position > 0);

    // Second run: checkpoint is current, nothing new to process.
    const second = try runner.run(proj);
    try std.testing.expectEqual(@as(usize, 0), second.events_processed);
    try std.testing.expectEqual(@as(usize, 2), count);
}

// ============================================================================
// REPOSITORY HAPPY-PATH
// ============================================================================

test "EventRepository.append and get_events round-trip" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    var repo = repositories.EventRepository.init(std.testing.allocator, &pool);

    const tenant_id = cqrs.generate_uuid();
    const agg_id = cqrs.generate_uuid();

    try repo.append(tenant_id, &[_]cqrs.DomainEvent{
        make_event(tenant_id, agg_id, "OrderCreated", 1),
        make_event(tenant_id, agg_id, "OrderConfirmed", 2),
    });

    var result = try repo.get_events(tenant_id, agg_id, "Order");
    defer result.deinit();

    // get_events returns a raw ResultSet; count the rows.
    var it = result.iter();
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "EventRepository.store_idempotency first-write-wins on duplicate key" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    var repo = repositories.EventRepository.init(std.testing.allocator, &pool);
    const tenant_id = cqrs.generate_uuid();

    var key_buf: [64]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "repo-idem-{}", .{nowNanos()});

    try repo.store_idempotency(tenant_id, key, .{ .command_type = "PlaceOrder", .result = "{\"id\":\"first\"}", .created_at = 1 });
    // Second write with same key must silently succeed (ON CONFLICT DO NOTHING).
    try repo.store_idempotency(tenant_id, key, .{ .command_type = "PlaceOrder", .result = "{\"id\":\"second\"}", .created_at = 2 });

    // Verify via the adapter that first write is retained.
    const found = try adapter.find_by_idempotency_key(tenant_id, key);
    try std.testing.expect(found != null);
    defer {
        if (found) |r| {
            std.testing.allocator.free(r.command_type);
            std.testing.allocator.free(r.result);
        }
    }
    try expectJsonEqualStrings("{\"id\":\"first\"}", found.?.result);
}

// ============================================================================
// SNAPSHOT ROUND-TRIP
// ============================================================================

test "PostgresSnapshotStore save and load round-trip" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    var snap_impl = pg.PostgresSnapshotStore.init(std.testing.allocator, &pool);
    var snap_store = snap_impl.to_store();
    defer snap_store.deinit();

    const tenant_id = cqrs.generate_uuid();
    const agg_id = cqrs.generate_uuid();

    const missing = try snap_store.load(tenant_id, agg_id, "Order");
    try std.testing.expectEqual(@as(?cqrs.Snapshot, null), missing);

    try snap_store.save(tenant_id, cqrs.Snapshot{
        .aggregate_id = agg_id,
        .aggregate_type = "Order",
        .version = 7,
        .state = "{\"total\":99}",
        .created_at = 1000,
    });

    const found = try snap_store.load(tenant_id, agg_id, "Order");
    try std.testing.expect(found != null);
    defer {
        if (found) |s| {
            std.testing.allocator.free(s.aggregate_type);
            std.testing.allocator.free(s.state);
        }
    }
    try std.testing.expectEqual(@as(u32, 7), found.?.version);
    try expectJsonEqualStrings("{\"total\":99}", found.?.state);
}

test "get_events after_version skips events already captured in snapshot" {
    var pool = try open_pool();
    defer pool.deinit();
    var adapter = make_adapter(&pool);
    defer adapter.deinit();
    try adapter.create_schema();

    const tenant_id = cqrs.generate_uuid();
    const agg_id = cqrs.generate_uuid();

    try adapter.append_events(tenant_id, &[_]cqrs.DomainEvent{
        make_event(tenant_id, agg_id, "OrderCreated", 1),
        make_event(tenant_id, agg_id, "OrderConfirmed", 2),
        make_event(tenant_id, agg_id, "OrderShipped", 3),
    });

    // Simulate: snapshot was taken at version 2.
    const incremental = try adapter.get_events(tenant_id, agg_id, "Order", 2);
    defer free_events(incremental);

    try std.testing.expectEqual(@as(usize, 1), incremental.len);
    try std.testing.expectEqualStrings("OrderShipped", incremental[0].event_type);
    try std.testing.expectEqual(@as(u32, 3), incremental[0].version);
}
