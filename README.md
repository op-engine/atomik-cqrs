# Atomik CQRS

[![CI](https://github.com/op-engine/atomik-cqrs/actions/workflows/ci.yml/badge.svg)](https://github.com/op-engine/atomik-cqrs/actions/workflows/ci.yml)

A portable, edge-native event sourcing runtime written in Zig. Bring your own database, your own domain types, your own deployment target.

## The Problem It Solves

Building financial systems requires handling concurrent writes to the same aggregate (an order, an invoice, a ledger line) without losing updates or violating invariants.

The typical solution: pessimistic locking or distributed transactions. Both are slow. Both couple your domain logic to database transactions.

Event sourcing solves this. Instead of storing state, you store the sequence of state-changing events. Concurrent writes become a natural problem: you detect conflicts at the aggregate level, not the row level.

But implementing event sourcing from scratch is dangerous. You need:

- **Optimistic concurrency control** that actually works
- **Idempotency** for safe retries
- **Event replay** so you can rebuild state
- **Multi-tenancy** without cross-contamination
- **A way to deploy this** without reinventing the wheel

Atomik CQRS is the runtime you'd build if you had six months and no features to ship.

## How It Works

```
       User Command
            │
            ▼
    ┌──────────────────┐
    │ Command Handler  │ (Your domain logic)
    └────────┬─────────┘
             │
             ▼
    ┌──────────────────┐
    │ Aggregate Logic  │ (Validate, emit events)
    └────────┬─────────┘
             │
             ▼
    ┌──────────────────┐
    │  Domain Events   │ (Immutable, versioned)
    └────────┬─────────┘
             │
             ▼
    ┌──────────────────┐
    │  EventStore      │ (Pluggable adapter)
    │   (Optimistic    │
    │   Concurrency)   │
    └─┬────────────┬───┘
      │            │
      ▼            ▼
  PostgreSQL    SQLite
      │            │
      └────┬───────┘
           ▼
    Event Stream
           │
      ┌────┴──────────┐
      ▼               ▼
  Event Replay   Audit Trail
```

1. **You define your domain**: aggregates, commands, events, validation rules.
2. **You write handlers**: functions that process commands and produce events.
3. **Atomik stores events**: with built-in version control and conflict detection.
4. **You replay events**: to rebuild state or project into read models.

That's it. No locking. No transactions. No magic.

## Why Zig?

Atomik is written in Zig because it offers:

- **Predictable memory management:** No garbage collector, no runtime overhead
- **Minimal dependencies:** No Zig package dependencies; the PostgreSQL adapter links `libpq` as a system library. Everything else is self-contained.
- **Native cross-compilation:** Build once, deploy to servers, embedded systems, or edge
- **First-class WASM support:** Seamless compilation to WebAssembly
- **Straightforward C interoperability:** Clean database driver integration

The result is a CQRS runtime that compiles to the same bytecode whether you're targeting servers, embedded systems, or edge platforms.

## Why Atomik?

| Feature | Atomik | Typical Homegrown |
|---------|--------|-------------------|
| Optimistic concurrency control | ✓ | Usually custom |
| Built-in idempotency primitives | ✓ | Often forgotten |
| Event replay | ✓ | Manual |
| Multi-tenancy | ✓ | Application-level hack |
| WASM support | ✓ | Rare |
| Pluggable storage backends | ✓ | PostgreSQL only |
| Type-safe aggregates | ✓ | Stringly-typed |

## Quick Start

### Installation

Add Atomik to your `build.zig.zon`:

```zig
.dependencies = .{
    .atomik = .{
        .url = "https://github.com/op-engine/atomik-cqrs/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "1220...",
    },
},
```

### Define Your Domain

Domain types are plain Zig structs. Atomik places no constraints on them. Identifiers are `cqrs.UUID` (`[16]u8`); `generate_uuid()` produces a CSPRNG-backed UUID v4.

```zig
const atomik = @import("atomik-cqrs");
const cqrs = atomik.cqrs;

// Your domain types: plain structs, no Atomik inheritance required.
pub const Order = struct {
    id: cqrs.UUID,
    customer_id: []const u8,
    total: u64,
    status: enum { pending, confirmed, shipped, cancelled },
};

// Commands carry intent; they are your application types.
pub const CreateOrderCommand = struct {
    customer_id: []const u8,
    total: u64,
};

// Events are serialized as JSON in DomainEvent.data.
// Define a struct for the payload you'll serialize.
pub const OrderCreatedPayload = struct {
    customer_id: []const u8,
    total: u64,
};
```

### Implement Handlers

A command handler validates intent and produces one or more `cqrs.DomainEvent` values. The `DomainEvent.data` field carries the event payload serialized as JSON; use whatever JSON library fits your project.

```zig
pub fn createOrder(
    tenant_id: cqrs.UUID,
    user_id: cqrs.UUID,
    cmd: CreateOrderCommand,
    allocator: std.mem.Allocator,
) !cqrs.DomainEvent {
    const aggregate_id = cqrs.generate_uuid();

    // Serialize your payload into DomainEvent.data.
    const data = try std.fmt.allocPrint(
        allocator,
        "{{\"customer_id\":\"{s}\",\"total\":{d}}}",
        .{ cmd.customer_id, cmd.total },
    );

    return cqrs.DomainEvent{
        .event_id      = cqrs.generate_uuid(),
        .aggregate_id  = aggregate_id,
        .aggregate_type = "Order",
        .event_type    = "OrderCreated",
        .tenant_id     = tenant_id,
        .version       = 1,
        .timestamp     = std.time.milliTimestamp(),
        .user_id       = user_id,
        .data          = data,
    };
}
```

### Replay Aggregate State

`cqrs.Aggregate` handles the replay loop. Supply an `apply_event` function that knows how to fold each event into your domain type.

```zig
// Cast the base Aggregate pointer to your concrete type, then apply the event.
fn applyEvent(base: *cqrs.Aggregate, event: cqrs.DomainEvent) anyerror!void {
    _ = base;
    _ = event;
    // Parse event.event_type to dispatch, then mutate your state.
}

var agg = cqrs.Aggregate.init(allocator, aggregate_id);
defer agg.deinit();

try agg.load_from_history(past_events, applyEvent);
// agg.version now reflects the latest committed version.
```

### Store and Retrieve

```zig
// 1. Create a connection pool (swap in your real DSN).
var pool = try atomik.postgres_pool.ConnectionPool.init(
    allocator,
    "postgres://localhost/orders",
    4,
);
defer pool.deinit();

// 2. Create the PostgreSQL adapter and obtain the generic interface.
var pg = atomik.adapters.postgres.PostgresAdapter.init(allocator, &pool);
var store = pg.to_adapter();
defer store.deinit();

// 3. Initialize the schema (idempotent; safe to call on every startup).
try store.create_schema();

// 4. Append events.
const tenant_id = cqrs.generate_uuid();
const event = try createOrder(tenant_id, user_id, cmd, allocator);

try store.append_events(tenant_id, &[_]cqrs.DomainEvent{event});

// 5. Replay aggregate state.
const events = try store.get_events(tenant_id, event.aggregate_id, "Order");
defer allocator.free(events);

var agg = cqrs.Aggregate.init(allocator, event.aggregate_id);
defer agg.deinit();
try agg.load_from_history(events, applyEvent);

// 6. Idempotent append: check before writing, store the key after.
const key = "create-order:request-abc-123";
if (try store.find_by_idempotency_key(tenant_id, key)) |prior| {
    // Key already exists: this is a retry. Return the original response
    // body stored in prior.result; the library does not replay it for you.
    _ = prior;
} else {
    try store.append_events(tenant_id, &[_]cqrs.DomainEvent{event});
    try store.store_idempotency(tenant_id, key, .{
        .command_type = "CreateOrder",
        .result       = "{}",  // serialize and store the response you will return
        .created_at   = std.time.milliTimestamp(),
    });
}
// Note: store_idempotency uses ON CONFLICT DO NOTHING (first write wins).
// If two concurrent requests race past find_by_idempotency_key with the same
// key, the database uniqueness constraint ensures only one write succeeds.
// The loser receives error.IdempotencyConflict and should retry the check.
```

## API Reference

### EventStoreAdapter

All storage backends expose this interface. Obtain one by calling `to_adapter()` on a concrete adapter (e.g. `PostgresAdapter`).

```zig
// Initialize the schema. Idempotent; uses CREATE TABLE IF NOT EXISTS.
pub fn create_schema(self: *EventStoreAdapter) !void

// Append one or more events atomically. Concurrent writes at the same
// version fail with error.OptimisticConcurrencyConflict.
pub fn append_events(
    self: *EventStoreAdapter,
    tenant_id: cqrs.UUID,
    events: []const cqrs.DomainEvent,
) !void

// Retrieve all events for one aggregate, ordered by version ASC.
pub fn get_events(
    self: *EventStoreAdapter,
    tenant_id: cqrs.UUID,
    aggregate_id: cqrs.UUID,
    aggregate_type: []const u8,
) ![]cqrs.DomainEvent

// Cross-aggregate query with optional filters.
pub fn query(
    self: *EventStoreAdapter,
    tenant_id: cqrs.UUID,
    filters: cqrs.QueryFilters, // aggregate_type, event_type, start_time, end_time, limit
) ![]cqrs.DomainEvent

// Look up a previously stored idempotency result, or null if not found.
pub fn find_by_idempotency_key(
    self: *EventStoreAdapter,
    tenant_id: cqrs.UUID,
    key: []const u8,
) !?cqrs.IdempotencyResult

// Persist an idempotency result. ON CONFLICT DO NOTHING; first write wins.
pub fn store_idempotency(
    self: *EventStoreAdapter,
    tenant_id: cqrs.UUID,
    key: []const u8,
    result: cqrs.IdempotencyResult,
) !void

pub fn deinit(self: *EventStoreAdapter) void
```

### Aggregate

```zig
pub fn init(allocator: Allocator, aggregate_id: UUID) Aggregate
pub fn deinit(self: *Aggregate) void

// Accumulate an event into uncommitted_events and advance self.version.
pub fn record(self: *Aggregate, event: DomainEvent) !void

// Replay history by calling apply_event for each past event.
pub fn load_from_history(
    self: *Aggregate,
    events: []const DomainEvent,
    apply_event: *const fn (self: *Aggregate, event: DomainEvent) anyerror!void,
) !void
```

### Storage Adapters

**PostgreSQL** (fully implemented)

```zig
var pg = atomik.adapters.postgres.PostgresAdapter.init(allocator, &pool);
var store = pg.to_adapter();
```

Requires a `ConnectionPool`. The schema is created via `store.create_schema()`; there is no separate `.sql` file to run. Optimistic concurrency is enforced by a `UNIQUE INDEX` on `(tenant_id, aggregate_id, version)`.

**Build requirement:** Link `libpq` when building against this adapter. The provided `build.zig` does this automatically; if you integrate Atomik into your own build script, add `-lc -lpq` to your linker flags. The `ConnectionPool` is safe for single-threaded callers only; see ADR-06 in `docs/adr/decisions.md` if your target is a multi-threaded server.

**MySQL** (scaffold, not production-ready)

`src/adapters/mysql_template.zig` provides the correct struct shape, `to_adapter()` wiring, and stub implementations with SQL comments. Fill in the TODOs to produce a working adapter.

**SQLite** (scaffold, not production-ready)

`src/adapters/sqlite_template.zig` follows the same template approach as the MySQL file.

### HTTP and Routing Utilities

```zig
// Format response envelopes (transport-agnostic).
atomik.http.success_response(allocator, status_code, json_data) !HttpResponse
atomik.http.error_response(allocator, status_code, error_type, message) !HttpResponse
atomik.http.json_response(allocator, status_code, json_body) !HttpResponse

// Route matching and path parameter extraction.
atomik.router.Router          // register / match routes
atomik.router.extract_params  // pull :param values from a path
atomik.router.parse_method    // "GET" -> HttpMethod.GET

// JSON serialization helpers.
atomik.json.serialize_event(allocator, event) ![]const u8
atomik.json.serialize_response(allocator, status, data) ![]const u8
atomik.json.serialize_error(allocator, code, message) ![]const u8
atomik.json.escape_json_string(allocator, input) ![]const u8
```

### UUID Utilities

```zig
// Generate a UUID v4 backed by a CSPRNG on every supported target.
cqrs.generate_uuid() UUID

// Convert between [16]u8 and "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".
cqrs.uuid_to_string(allocator, uuid) ![]const u8
cqrs.string_to_uuid(str) !UUID
```

### WASM Compilation

Atomik targets `wasm32-freestanding` (not `wasm32-wasi`):

```sh
zig build wasm
```

This produces `zig-out/wasm/atomik-cqrs-edge-harness.wasm`. The companion `edge/worker.js` bridges the Cloudflare Workers fetch event into the WASM module. A 256 KB static `FixedBufferAllocator` serves all per-request allocations; `fba.reset()` reclaims memory after each response is written.

## Projections

A projection is a named, resumable read-model that processes events from the event stream and maintains its own cursor. `ProjectionRunner` handles the checkpoint lifecycle: load position, query new events, call your handler, save position.

```zig
const atomik = @import("atomik-cqrs");
const projection = atomik.projection;

// 1. Choose a checkpoint store.
//    InMemoryCheckpointStore for tests or WASM (resets on restart).
//    PostgresCheckpointStore for production (persists in projection_checkpoints table).
var cp_store = projection.InMemoryCheckpointStore.init(allocator);
const checkpoints = cp_store.to_store();

// 2. Create a runner wired to your event store adapter.
var runner = projection.ProjectionRunner.init(allocator, &store, checkpoints);
defer runner.deinit();

// 3. Define a projection. `apply` is called once per event in global_seq order.
//    It must be idempotent; on checkpoint-save failure the batch replays.
fn updateOrderSummary(ctx: *anyopaque, event: atomik.cqrs.DomainEvent) anyerror!void {
    const summary: *OrderSummary = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, event.event_type, "OrderCreated")) {
        summary.total_orders += 1;
    }
}

// 4. Run: processes all events since the last checkpoint, then saves position.
const result = try runner.run(projection.Projection{
    .name       = "order-summary",     // unique checkpoint key
    .tenant_id  = tenant_id,
    .filters    = .{ .aggregate_type = "Order" },
    .apply      = updateOrderSummary,
    .ctx        = &my_order_summary,
});
// result.events_processed, result.last_position

// 5. Drive from a scheduled task or Cloudflare Workers Cron Trigger.
//    Subsequent runs pick up from where the last one finished.
```

**For production** (PostgreSQL checkpoint persistence):

```zig
var pg_cp = atomik.adapters.postgres.PostgresCheckpointStore.init(allocator, &pool);
const checkpoints = pg_cp.to_store();
// checkpoints table is created by store.create_schema()
```

**Delivery model:** `ProjectionRunner` is pull-based; it polls for new events on each call rather than receiving pushed notifications. This keeps projections simple and WASM-compatible. For push-based fan-out to external systems (Kafka, NATS, Redis Streams, webhooks), that belongs in a broker layer. A future `atomik-relay` package will bridge the event store to configurable sinks using this same polling model internally.

## Roadmap

**✓ Shipped**
- Core runtime with optimistic concurrency control
- PostgreSQL adapter with transaction safety
- WASM compilation support
- HTTP request/response utilities
- Multi-tenant event isolation
- Projections with resumable checkpoints (`ProjectionRunner`, `CheckpointStore`)

**Upcoming**
- [ ] Snapshot support for large aggregates (>10k events)
- [ ] Kafka/NATS integration for cross-service events (`atomik-relay`)
- [ ] Time-travel debugging CLI
- [ ] Event encryption at rest
- [ ] Complete the migration tool's file discovery loop

Priorities are driven by OpEngine's needs and community feedback. [Open an issue](https://github.com/op-engine/atomik-cqrs/issues) to discuss.

## Deployment

### Local Development

```sh
# Start PostgreSQL
docker run -d -e POSTGRES_DB=atomik -p 5432:5432 postgres:15

# Run tests
zig build test

# Build the WASM edge harness
zig build wasm

# Build the migration tool (scaffolded, file discovery not yet implemented)
zig build migrate
```

**Migration tool status:** `zig build migrate` compiles and connects to the database (reads `ATOMIK_DATABASE_URL` or falls back to `postgres://localhost/atomik_dev`), creates the `schema_migrations` tracking table, and exits cleanly but does not yet read or apply migration files. When implemented, files in `./migrations/` will be applied in lexicographic order (e.g. `001-create-orders.sql`, `002-add-index.sql`). See the Roadmap.

### Production

Atomik is designed to compile as a library. You own the HTTP handler. Here is a minimal pattern using the provided utilities:

```zig
pub fn handleCommand(req: atomik.router.Request, allocator: std.mem.Allocator) !atomik.http.HttpResponse {
    const body = req.body orelse return atomik.http.error_response(allocator, 400, "BAD_REQUEST", "missing body");

    // Parse your command from body, run your handler, produce events.
    const event = try createOrder(tenant_id, user_id, cmd, allocator);
    try store.append_events(tenant_id, &[_]atomik.cqrs.DomainEvent{event});

    const serialized = try atomik.json.serialize_event(allocator, event);
    return atomik.http.success_response(allocator, 201, serialized);
}
```

Deploy this as:
- A containerized service (Docker, Kubernetes)
- A serverless function (AWS Lambda, Google Cloud Functions)
- A WASM module (Cloudflare Workers via `zig build wasm`)

Atomik has no opinions on HTTP frameworks. Use what fits your infrastructure.

## Developed Alongside

Atomik CQRS is actively used by [OpEngine](https://opengine.org), a SOC 2-compliant, multi-tenant financial accounting platform. Real-world feedback drives the roadmap.

## Limitations

- **Single-aggregate transactions only**: If a command must update two aggregates atomically, you need a saga pattern (not included, but straightforward to implement).
- **No built-in projections**: Read models are your responsibility. `EventStoreAdapter.query` gives you the event stream; what you do with it is up to you.
- **Sequential consistency only**: Events are consistent per aggregate, not globally. For cross-aggregate queries, build a read model.
- **Connection pool is minimal**: Safe for single-threaded callers only (the primary target is `wasm32-freestanding` Workers, which handle one request at a time). See `docs/adr/decisions.md` ADR-06 for the path to multi-threaded support.
- **Migration tool is scaffolded**: The infrastructure is present; the file discovery loop is not yet wired.

These are deliberate constraints, not bugs. They keep the runtime simple and let you choose your consistency model.

## Contributing

Contributions are welcome. Please:

1. Open an issue first to discuss the change.
2. Ensure tests pass: `zig build test`
3. Follow the code style: `zig fmt`
4. Add tests for new functionality.

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

Apache 2.0. See [LICENSE](LICENSE) for details.

## More Information

- **Architecture decisions**: See [docs/adr/decisions.md](docs/adr/decisions.md)
- **Design patterns**: See [DESIGN_PATTERNS.md](DESIGN_PATTERNS.md)

---

Questions? Open an issue or start a discussion. We read everything.
