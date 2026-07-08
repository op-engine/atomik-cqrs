# Atomik CQRS — Release 0.0.1

**Released:** July 6, 2026  
**Repository:** [op-engine/atomik-cqrs](https://github.com/op-engine/atomik-cqrs)  
**License:** Apache 2.0

---

## Overview

This is the first public release of Atomik CQRS: a portable, edge-native event sourcing runtime written in Zig. It ships the foundational primitives that any event-sourced system needs — aggregate lifecycle, domain events, idempotency, multi-tenancy, and pluggable storage — compiled to a single dependency-free library.

Atomik was extracted from [OpEngine](https://opengine.org), a SOC 2-compliant multi-tenant financial accounting platform. The patterns here have been tested against real concurrent financial workloads. This release makes those patterns available as a standalone library.

---

## Why We Built This

Financial systems face a specific problem: concurrent writes to the same aggregate (an order, an invoice, a ledger line) that must not lose updates or violate invariants. The standard solutions — pessimistic locking or distributed transactions — are slow and couple domain logic to database internals.

Event sourcing solves this by changing what you store. Instead of current state, you store the ordered sequence of state changes. Conflicts become detectable at the aggregate level via a version number, without holding a lock across the network. Idempotent retries become safe because you check a key before writing, not a row state.

Implementing this correctly from scratch is dangerous. You need optimistic concurrency control that actually works, idempotency that survives network retries, event replay that rebuilds aggregate state deterministically, and multi-tenancy that never mixes tenant data. These are the primitives Atomik provides.

---

## Why Zig

We chose Zig 0.16.0 for four concrete reasons:

**Predictable memory.** No garbage collector, no runtime overhead, no hidden allocations. Every allocation in Atomik is explicit and paired with a corresponding `defer deinit()`. This matters for latency-sensitive financial workloads and for edge deployments where heap pressure is visible.

**First-class WASM.** Zig targets `wasm32-freestanding` without a third-party toolchain. The same library source that runs against PostgreSQL on a server compiles to a WASM module that runs inside a Cloudflare Worker — same types, same logic, different allocator.

**Zero link-time dependencies.** The library itself has no package dependencies. The PostgreSQL adapter links against libpq, but that's a deliberate opt-in: you swap `libpq_mock.zig` for `libpq.zig` and link the system library. Nothing else is required.

**Clean C interoperability.** libpq is a C library. Zig's C FFI requires no wrapper layer, no `extern` blocks, no binding generator. The function signatures in `libpq.zig` map directly to the libpq header.

### Zig 0.16.0 API surface

This release targets Zig 0.16.0 specifically, which introduced several breaking changes from earlier versions that are worth documenting:

- `std.ArrayList` no longer stores its allocator internally. All `append`, `deinit`, and similar calls take an explicit `allocator` argument. Code written for 0.13 will fail to compile here; the fix is mechanical.
- `std.crypto.random` no longer exists as a namespace. UUID generation on the WASM target (where there is no OS entropy source) uses `std.Random.DefaultPrng` seeded with a fixed constant. This is intentional and documented — these UUIDs are aggregate identifiers, not cryptographic tokens.
- Environment variables require `std.c.getenv` rather than `std.process.getEnvVarOwned` on targets that link libc (such as the migration tool). The migration tool reads `ATOMIK_DATABASE_URL` this way.

---

## What Shipped

### Core types (`src/cqrs.zig`)

The `Command`, `DomainEvent`, and `AuditEvent` envelopes are the vocabulary of the runtime. They carry `tenant_id`, `user_id`, and `timestamp` on every record — not as optional fields, but as required structural members. Multi-tenancy is not an afterthought here; it is load-bearing.

`aggregate_type` and `event_type` are open `[]const u8` strings, not closed enums. A consuming application defines its own vocabulary ("Account", "AccountCreated") without modifying this library. The library has no opinion on what your domain looks like.

The `Aggregate` base struct handles the two operations all aggregates need: recording uncommitted events (accumulating them for a batch write) and replaying history (calling an `apply_event` function pointer for each past event to reconstruct current state). Concrete aggregates embed this as `base` and supply their own `apply_event`.

UUIDs are `[16]u8` internally — compact, no heap allocation for the value itself. `uuid_to_string` and `string_to_uuid` convert to and from the canonical hyphenated hex format (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`) for API boundaries. Storage adapters use an undelimited 32-character hex encoding for SQL columns.

### Event store adapter interface (`src/event_store.zig`)

The `EventStoreAdapter` is a vtable — a struct holding a `*anyopaque` context pointer and a set of function pointers. This is Zig's idiomatic approach to runtime polymorphism without comptime generics in the public interface.

Why vtable over comptime generic? Because the consuming application may not know at compile time which adapter it will use, and because the interface needs to be storable in a plain struct field without carrying a type parameter. Comptime generics would make this awkward to compose. The vtable costs one indirection per call — acceptable for storage operations.

The interface covers six operations: `create_schema`, `append_events`, `get_events`, `query`, `find_by_idempotency_key`, and `store_idempotency`. Every concrete adapter implements these six and exposes a `to_adapter()` method that wires up the function pointers. An in-memory adapter in the test section of `event_store.zig` exercises the interface shape without touching a database.

### PostgreSQL adapter (`src/adapters/postgres.zig`)

The PostgreSQL adapter is the only fully implemented adapter in this release. It wraps the connection pool, converts UUIDs to 32-character hex for `VARCHAR(32)` columns, and drives the six interface functions.

Event appends run inside an explicit transaction. Each batch of events goes to the database atomically or not at all. The schema includes two indexes per table: one on `(tenant_id, aggregate_id, version ASC)` for event replay (which reads events in version order) and one on `(tenant_id, aggregate_type, event_type, timestamp DESC)` for cross-aggregate queries.

Idempotency storage uses `ON CONFLICT (tenant_id, idempotency_key) DO NOTHING`. This is intentional. The first write wins; retries with the same key are silently ignored at the database level, which means the idempotency guarantee survives network-level retries without application-level coordination.

The schema also includes an `audit_logs` table for compliance events, separate from the domain event store. Audit events carry IP address and user agent alongside the standard tenant, user, and timestamp fields.

### PostgreSQL connection pool (`src/postgres_pool.zig`)

The connection pool wraps libpq through a swappable import. In test and CI builds, `libpq_mock.zig` is imported; it returns `null` from `PQconnectdb` and `CONNECTION_BAD` from `PQstatus`, causing every connection attempt to fail predictably. Tests verify that this failure propagates correctly up through the adapter and repository layers.

For production, swap the import to `libpq.zig` and link libpq in your `build.zig`. The real `libpq.zig` calls the actual C library with the same function signatures.

This approach lets CI remain hermetic — no database process required — while keeping the test surface meaningful. The tests confirm error propagation, not SQL correctness. SQL correctness requires an actual database, which belongs in integration tests the consuming application writes.

`Transaction` is a RAII wrapper: `init` calls `BEGIN`, `commit` calls `COMMIT`, and `deinit` rolls back if `commit` was never called. This prevents the common bug where an error path forgets to close a transaction.

### Repositories (`src/repositories.zig`)

`EventRepository` and `AuditLogRepository` provide a second access path alongside the vtable adapter. Where the adapter is polymorphic (swap the backend at runtime), the repositories are direct: they take a `*ConnectionPool` and issue SQL via the pool. Callers who know they are on PostgreSQL and want to drive the connection pool directly use these. Callers who want to swap backends without changing call sites use the adapter.

Both are append-only on writes. `EventRepository.append` wraps its batch in a transaction. `AuditLogRepository.log_event` inserts one audit record per call.

### HTTP and JSON utilities (`src/http.zig`, `src/router.zig`, `src/json.zig`)

These modules are transport utilities, not a framework. `http.zig` formats HTTP/1.1 response envelopes — `success_response`, `error_response`, and `json_response` — without knowing anything about sockets or Workers fetch handlers. `json.zig` serializes domain events and status envelopes to JSON strings. `router.zig` matches request paths against patterns with `:param` placeholders and extracts named parameters.

Atomik has no opinions on your HTTP framework. You supply the handler function; these utilities help you format what it returns. The deliberate scope keeps the library usable in any server runtime or WASM host.

### Migration tool (`src/migrate.zig`)

The migration tool is a standalone executable (`atomik-migrate`) built alongside the library. It reads the target database URL from the `ATOMIK_DATABASE_URL` environment variable (defaulting to `postgres://localhost/atomik_dev`), creates a `schema_migrations` table if it does not exist, and applies pending migrations in filename order.

The file-reading and application loop is scaffolded but not fully wired — the infrastructure for discovering and applying `.sql` files is present as functions; the `main` function calls `ensure_migrations_table` and then reports "no migrations found." Completing this loop is on the roadmap.

### WASM edge harness (`edge/worker_main.zig`)

The edge harness proves that the library builds and runs on Cloudflare Workers. It is not shipped application code; it is a proof of concept that validates the WASM compilation path end-to-end.

The harness targets `wasm32-freestanding` with no OS layer. There is no system allocator, so it uses a `FixedBufferAllocator` over a 256KB static buffer for per-request allocations, reset after each request completes. The JS bridge exports four functions:

- `alloc(len)` — allocates a slice for JS to write request data into
- `dealloc(ptr, len)` — frees a previously allocated slice
- `get_output_ptr()` — returns the address of a static 64KB output buffer
- `handle_request(method, path, body)` — dispatches a request and writes the JSON response to the output buffer, returning its length

The companion `worker.js` handles the Workers fetch event, marshals the request into WASM memory via `alloc`, calls `handle_request`, reads the response out of `output_buf`, and returns a `Response` to the Workers runtime.

The harness exercises two routes: `GET /health` returns a static health envelope, and `POST /events` round-trips a domain event through the library's in-memory adapter — `append_events`, `get_events`, `serialize_event` — and returns the serialized result. This confirms that `cqrs`, `event_store`, and `json` all function correctly inside the WASM sandbox.

---

## Key Design Decisions

### Tenant isolation is structural, not optional

Every event, audit record, and idempotency key carries a `tenant_id` UUID. Every query parameter set that touches tenant data requires a `tenant_id`. It is not possible to query across tenants through the library's provided interface — the WHERE clause always includes `tenant_id = $1`.

This was a deliberate choice driven by OpEngine's requirements as a SOC 2-compliant multi-tenant platform. Tenant isolation that depends on application-level discipline fails eventually. Isolation that is structural in the storage layer is much harder to break accidentally.

### Open string discriminators

`aggregate_type` and `event_type` are `[]const u8`, not enums. This is the most important type-system decision in the library. A closed enum would require modifying `cqrs.zig` every time a consuming application added a new aggregate or event. Open strings mean the library is genuinely domain-agnostic: it stores events of any type without knowing what those types mean.

The tradeoff is that the library cannot validate event types at compile time. That responsibility belongs to the consuming application, which knows its domain vocabulary and can enforce it at the handler level.

### Two access patterns at parity

The vtable adapter and the direct repositories solve the same problem differently. We kept both because different callsites have different needs: code that needs to swap backends (e.g., PostgreSQL in production, in-memory in tests) benefits from the adapter's runtime polymorphism; code that is permanently on PostgreSQL and wants to minimize indirection benefits from the repository's direct pool access.

### CI without a database

The mock libpq backend makes the test suite hermetic. `zig build test` passes on a clean machine with no PostgreSQL installed, no Docker, no environment setup. This was a deliberate tradeoff: the tests verify error propagation and interface wiring, not SQL correctness. Integration tests against a real database are the consuming application's responsibility, because only the consuming application knows its schema and its data.

### Apache 2.0 with explicit patent grant language

The `CONTRIBUTING.md` notes that the Apache 2.0 patent grant (Section 3) applies to all contributions and that this is intentional. Event sourcing with optimistic concurrency control sits close to several active patent landscapes. Making the patent grant explicit in the contribution guide protects both users of the library and contributors to it.

---

## Limitations in This Release

- **Single-aggregate transactions only.** Commands that must update two aggregates atomically require a saga pattern. Atomik does not include saga support; it is on the roadmap.
- **No built-in projections.** Read models are the consuming application's responsibility. The `query` adapter method provides the event stream; what you do with it is up to you.
- **Sequential consistency per aggregate only.** Events are globally ordered per aggregate stream. Cross-aggregate consistency requires a read model built from those streams.
- **Migration tool is scaffolded, not complete.** The infrastructure is present; the file discovery loop is not wired.
- **Connection pool is minimal.** The pool pre-allocates a slot array and always returns slot 0 when all slots are active. A production deployment will want a proper connection pool with blocking acquisition and health checking.

These are known limitations, not bugs. They reflect where the library is in its development, and the roadmap addresses each of them.

---

## What's Next

- Snapshot support for aggregates with large event histories (>10k events)
- Event subscriptions for building projections reactively
- Projection worker helpers
- Kafka/NATS integration for cross-service event delivery
- Time-travel debugging CLI (`atomik replay --aggregate-id <uuid> --at <timestamp>`)
- Event encryption at rest
- Complete the migration tool's file discovery and application loop

Priorities are driven by OpEngine's production needs and issues opened by the community.

---

## Getting Started

Add to `build.zig.zon`:

```zig
.dependencies = .{
    .atomik = .{
        .url = "https://github.com/op-engine/atomik-cqrs/archive/refs/tags/v0.0.1.tar.gz",
        .hash = "...",
    },
},
```

Run the tests:

```sh
zig build test
```

Build the WASM edge harness:

```sh
zig build wasm
```

Build the migration tool:

```sh
zig build migrate
```

Questions? Open an issue or a discussion. We read everything.
