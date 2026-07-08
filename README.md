# Atomik CQRS

[![CI](https://github.com/op-engine/atomik-cqrs/actions/workflows/ci.yml/badge.svg)](https://github.com/op-engine/atomik-cqrs/actions/workflows/ci.yml)

A portable, edge-native event sourcing runtime written in Zig. Bring your own database, your own domain types, your own deployment target.

## The Problem It Solves

Building financial systems requires handling concurrent writes to the same aggregate—an order, an invoice, a ledger line—without losing updates or violating invariants.

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

- **Predictable memory management** — No garbage collector, no runtime overhead
- **Zero dependencies** — Self-contained binary, minimal attack surface  
- **Native cross-compilation** — Build once, deploy to servers, embedded systems, or edge
- **First-class WASM support** — Seamless compilation to WebAssembly
- **Straightforward C interoperability** — Clean database driver integration

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

```zig
const atomik = @import("atomik");

// Your domain types
pub const OrderId = atomik.Id(Order);

pub const Order = struct {
    id: OrderId,
    customer_id: []const u8,
    items: []Item,
    total: u64,
    status: enum { pending, confirmed, shipped, cancelled },
};

pub const Item = struct {
    product_id: []const u8,
    quantity: u32,
    price: u64,
};

// Your commands
pub const CreateOrderCommand = struct {
    customer_id: []const u8,
    items: []Item,
};

pub const ConfirmOrderCommand = struct {
    order_id: OrderId,
};

// Your events
pub const OrderCreated = struct {
    order_id: OrderId,
    customer_id: []const u8,
    items: []Item,
    total: u64,
};

pub const OrderConfirmed = struct {
    order_id: OrderId,
    confirmed_at: i64,
};
```

### Implement Handlers

```zig
pub fn createOrder(
    aggregate: ?Order,
    cmd: CreateOrderCommand,
    allocator: std.mem.Allocator,
) ![]const u8 {
    // Validate: customer can only have one pending order
    if (aggregate) |agg| {
        if (agg.status == .pending) {
            return error.OrderAlreadyPending;
        }
    }

    // Calculate total
    var total: u64 = 0;
    for (cmd.items) |item| {
        total += item.price * item.quantity;
    }

    // Emit event
    const event = OrderCreated{
        .order_id = try OrderId.generate(),
        .customer_id = cmd.customer_id,
        .items = cmd.items,
        .total = total,
    };

    return try atomik.serialize(event, allocator);
}

pub fn confirmOrder(
    aggregate: Order,
    cmd: ConfirmOrderCommand,
    allocator: std.mem.Allocator,
) ![]const u8 {
    // Validate: only pending orders can be confirmed
    if (aggregate.status != .pending) {
        return error.OrderNotPending;
    }

    const event = OrderConfirmed{
        .order_id = cmd.order_id,
        .confirmed_at = std.time.milliTimestamp(),
    };

    return try atomik.serialize(event, allocator);
}
```

### Apply Events to Aggregate

```zig
pub fn applyOrderCreated(aggregate: ?Order, event: OrderCreated) Order {
    return Order{
        .id = event.order_id,
        .customer_id = event.customer_id,
        .items = event.items,
        .total = event.total,
        .status = .pending,
    };
}

pub fn applyOrderConfirmed(aggregate: Order, event: OrderConfirmed) Order {
    var result = aggregate;
    result.status = .confirmed;
    return result;
}
```

### Store and Retrieve

```zig
const store = try atomik.PostgresEventStore.init(
    allocator,
    "postgresql://localhost/orders",
);
defer store.deinit();

// Store events
const stream_id = try atomik.StreamId.fromString("order:12345");
const version = try store.append(stream_id, events);

// Replay aggregate
const order = try store.replay(
    stream_id,
    Order,
    &.{
        .{ "OrderCreated", applyOrderCreated },
        .{ "OrderConfirmed", applyOrderConfirmed },
    },
);

// Safe retry: idempotent key prevents duplicate events
const idempotent_key = "create-order:request-123";
try store.appendIdempotent(stream_id, events, idempotent_key);
```

## API Reference

### EventStore Interface

All adapters implement this interface:

```zig
pub fn append(
    self: *Self,
    stream_id: StreamId,
    events: []const u8,
) !u64
```

Store one or more events. Returns the new version of the aggregate.

```zig
pub fn appendIdempotent(
    self: *Self,
    stream_id: StreamId,
    events: []const u8,
    idempotent_key: []const u8,
) !u64
```

Store events with idempotency. If the same `idempotent_key` is seen twice, the second call returns success without storing duplicates.

```zig
pub fn replay(
    self: *Self,
    stream_id: StreamId,
    AggregateType: type,
    handlers: []const EventHandler(AggregateType),
) !AggregateType
```

Rebuild an aggregate by replaying all events in order. Returns the final state or an error if any handler fails.

```zig
pub fn getEvents(
    self: *Self,
    stream_id: StreamId,
    from_version: u64,
    to_version: u64,
) ![]Event
```

Retrieve a range of events for inspection, auditing, or projection.

### Storage Adapters

**PostgreSQL** (included)

```zig
const store = try atomik.PostgresEventStore.init(allocator, connection_string);
```

Requires a schema (provided in `schema/postgres.sql`). Handles optimistic concurrency via version columns.

**MySQL** (template provided)

```zig
const store = try atomik.MysqlEventStore.init(allocator, connection_string);
```

See `adapters/mysql` for implementation details.

**SQLite** (template provided)

```zig
const store = try atomik.SqliteEventStore.init(allocator, path);
```

Good for testing, edge workers, or single-machine deployments.

### WASM Compilation

Atomik compiles cleanly to WASM:

```sh
zig build -Dtarget=wasm32-wasi
```

This is how you deploy to Cloudflare Workers or Fastly Compute.

## Roadmap

**✓ Shipped**
- Core runtime with optimistic concurrency control
- PostgreSQL adapter with transaction safety
- WASM compilation support
- HTTP request/response utilities
- Multi-tenant event isolation

**Upcoming**
- [ ] Snapshot support for large aggregates (>10k events)
- [ ] Event subscriptions for projections
- [ ] Projection worker helpers
- [ ] Kafka/NATS integration for cross-service events
- [ ] Time-travel debugging CLI
- [ ] Event encryption at rest

Priorities are driven by OpEngine's needs and community feedback. [Open an issue](https://github.com/op-engine/atomik-cqrs/issues) to discuss.

## Deployment

### Local Development

```sh
# Start PostgreSQL
docker run -d -e POSTGRES_DB=atomik -p 5432:5432 postgres:15

# Run tests
zig build test

# Build examples
zig build -Dexamples
```

### Production

Atomik is designed to compile as a library. You own the HTTP handler:

```zig
pub fn handleCommand(req: *http.Request, res: *http.Response) !void {
    var body = try req.body();
    defer body.deinit();

    const cmd = try json.parse(CreateOrderCommand, body, allocator);
    const events = try createOrder(null, cmd, allocator);
    const version = try event_store.append(stream_id, events);

    try res.writeJson(.{ .version = version });
}
```

Deploy this as:
- A containerized service (Docker, Kubernetes)
- A serverless function (AWS Lambda, Google Cloud Functions)
- A WASM module (Cloudflare Workers, Fastly Compute)

Atomik has no opinions on HTTP frameworks. Use what fits your infrastructure.

## Developed Alongside

Atomik CQRS is actively used by [OpEngine](https://opengine.org), a SOC 2-compliant, multi-tenant financial accounting platform. Real-world feedback drives the roadmap.

## Limitations

- **Single-aggregate transactions only**: If a command must update two aggregates atomically, you need a saga pattern (not included, but straightforward to implement).
- **No built-in projections**: Read models are your responsibility. See `examples/projections` for patterns.
- **Sequential consistency only**: Events are consistent per aggregate, not globally. For cross-aggregate queries, build a read model.

These are deliberate constraints, not bugs. They keep the runtime simple and let you choose your consistency model.

## Contributing

Contributions are welcome. Please:

1. Open an issue first to discuss the change.
2. Ensure tests pass: `zig build test`
3. Follow the code style: `zig fmt`
4. Add tests for new functionality.

## License

Apache 2.0. See [LICENSE](LICENSE) for details.

## Blog

- [Why Event Sourcing for Financial Systems](blog/why-event-sourcing-for-financial-systems.md) — The tradeoffs that led OpEngine to build on event sourcing instead of a traditional CRUD stack.

## More Information

- **Example: Building a ledger**: See `examples/ledger`
- **Debate: CQRS vs. transactions**: See [design decisions](docs/decisions.md)

---

Questions? Open an issue or start a discussion. We read everything.
