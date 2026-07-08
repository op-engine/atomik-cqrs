# Design Patterns in Atomik CQRS

This document maps the classical design patterns at work in the codebase to their exact location and explains the reasoning behind each choice.

---

## 1. Command Query Responsibility Segregation (CQRS)

**Where:** The architecture as a whole, most visibly in `src/cqrs.zig`.

**What it is:** CQRS separates the write side (commands that change state) from the read side (queries that return state). They use different models: commands emit events; queries read projections or replay events.

**How it appears here:**  
- `Command` is the write-side envelope. It carries `command_type`, `tenant_id`, `user_id`, `timestamp`, and an optional `idempotency_key`. It represents intent — something the user wants to do.  
- `DomainEvent` is the result of a command being accepted. It is immutable and versioned. Once written, it never changes.  
- `QueryFilters` in `cqrs.zig` and `query` in `EventStoreAdapter` represent the read side — filtering the event stream without going through the command pipeline.

**Why:** The separation means writes (appending events) and reads (querying/replaying events) can scale and evolve independently. Reads never block on writes. You can add a new read model without touching the command handlers.

---

## 2. Event Sourcing

**Where:** `src/cqrs.zig` (`DomainEvent`, `Aggregate`), `src/event_store.zig`, `src/adapters/postgres.zig`.

**What it is:** Instead of storing the current state of an aggregate, you store the ordered sequence of events that produced that state. Current state is derived by replaying those events in order.

**How it appears here:**  
`Aggregate.load_from_history` iterates over a slice of `DomainEvent`s and calls an `apply_event` function pointer for each one, advancing the version counter. `Aggregate.record` accumulates new events into `uncommitted_events` — they exist in memory until the caller flushes them to the adapter with `append_events`. Nothing is stored until you explicitly write.

The PostgreSQL schema reflects this: the `events` table is append-only. There is no UPDATE path in any adapter. `version ASC` ordering on the index mirrors the replay direction.

**Why:** For financial systems, the event log is the source of truth. You can always reconstruct state from it, audit every change, and replay history to debug production incidents or build new read models retroactively. Storing only current state discards this.

---

## 3. Repository Pattern

**Where:** `src/repositories.zig` (`EventRepository`, `AuditLogRepository`).

**What it is:** A repository encapsulates the data access logic for a domain entity behind a domain-language interface. Callers ask for domain objects; the repository handles SQL.

**How it appears here:**  
`EventRepository.append` takes a `tenant_id` and a slice of `DomainEvent`s and issues parameterized SQL inside a transaction. `EventRepository.get_events` takes a `tenant_id`, `aggregate_id`, and `aggregate_type` and returns a `ResultSet`. The caller never writes SQL.

`AuditLogRepository.log_event` does the same for compliance events — it converts UUIDs to hex, formats timestamps, and inserts a row.

**Why:** The repository isolates SQL from the rest of the application. If the schema changes, only the repository changes. The domain logic that calls `repo.append(tenant_id, events)` is unaffected.

---

## 4. Adapter Pattern (via vtable)

**Where:** `src/event_store.zig` (`EventStoreAdapter`), `src/adapters/postgres.zig` (`PostgresAdapter`), `src/adapters/sqlite_template.zig` (`SQLiteAdapter`), `edge/worker_main.zig` (`InMemoryDemoStore`), `src/event_store.zig` (`InMemoryStore`).

**What it is:** The Adapter pattern wraps an incompatible interface so it fits an expected one. Here, each concrete storage backend (PostgreSQL, SQLite, in-memory) has a different internal structure, but all of them expose the same `EventStoreAdapter` interface to callers.

**How it appears here:**  
`EventStoreAdapter` is a struct holding a `*anyopaque` context pointer and six function pointers. Each concrete adapter implements those six functions and exposes a `to_adapter()` method that populates the vtable. Callers hold an `EventStoreAdapter` and call `adapter.append_events(...)` without knowing whether they are talking to PostgreSQL or an in-memory store.

This is Zig's idiomatic approach to interface polymorphism: there is no `interface` keyword, so runtime polymorphism is expressed as a vtable struct. The `*anyopaque` context pointer is the equivalent of a `this` pointer; `@ptrCast(@alignCast(ctx))` recovers the concrete type inside each function.

**Why vtable instead of comptime generics?** A comptime generic adapter (`fn doSomething(adapter: anytype)`) embeds the concrete type in the call signature. That means the consuming application cannot store an adapter in a plain struct field without parameterizing that struct. A vtable has no type parameter — you can store it, pass it, and swap it at runtime. For a library that expects to be used with different backends in different test/production contexts, this is the right tradeoff.

---

## 5. Template Method Pattern

**Where:** `src/adapters/sqlite_template.zig`, `src/adapters/mysql_template.zig`.

**What it is:** The Template Method pattern defines the skeleton of an algorithm in a base class (or in this case, a template file), leaving specific steps to be filled in by subclasses (or implementors).

**How it appears here:**  
The SQLite and MySQL adapter files are scaffolded: the struct, the `to_adapter()` method, and all six function stubs are present with the correct signatures. Each stub contains a comment describing exactly what SQL to execute. A developer implementing the adapter fills in the TODOs without having to understand the adapter contract from scratch.

**Why:** The vtable contract (six specific function signatures) is easy to get wrong. Providing a template with the correct signatures already in place reduces the chance of a type mismatch and communicates the expected behavior at each call site.

---

## 6. Object Pool Pattern

**Where:** `src/postgres_pool.zig` (`ConnectionPool`).

**What it is:** A pool pre-allocates a fixed number of expensive resources (database connections) and lends them out to callers, returning them to the pool when done.

**How it appears here:**  
`ConnectionPool` pre-allocates a `[]Connection` slice up to `max_connections`. `get_connection` either initializes a new slot (if capacity remains) or returns slot 0 (if the pool is full). `release_connection` is a no-op in this release — connection lifecycle management is minimal and documented as such.

**Why:** Opening a PostgreSQL connection is expensive: a TCP handshake, TLS negotiation, and authentication round-trip. Amortizing that cost across requests is the baseline requirement for any production database client.

---

## 7. RAII (Resource Acquisition Is Initialization)

**Where:** `src/postgres_pool.zig` (`Transaction`), every `deinit` method across all structs.

**What it is:** Resources are tied to object lifetime. Acquisition happens in `init`; release happens in `deinit`, typically via `defer`. If the scope exits for any reason — including an error — the resource is released.

**How it appears here:**  
`Transaction.init` calls `BEGIN`. `Transaction.deinit` calls `ROLLBACK` if `commit` was never called. Callers write:

```zig
var txn = try Transaction.init(conn);
defer txn.deinit();
// ... do work ...
try txn.commit();
```

If any step between `init` and `commit` returns an error, the `defer` fires, rolling back. Forgetting the `defer` is the bug; the RAII wrapper makes the forgetting hard.

Similarly, every struct that allocates — `Aggregate`, `ConnectionPool`, `ResultSet`, `Router` — has a `deinit` method, and every call site pairs it with `defer`.

**Why:** Zig has no destructors or garbage collector. `defer deinit()` is the language's idiomatic substitute. Enforcing this pattern consistently means memory and connection leaks are visible at review time (the call site has no `defer`) rather than at runtime.

---

## 8. Strategy Pattern

**Where:** `src/cqrs.zig` (`Aggregate.load_from_history`).

**What it is:** The Strategy pattern defines a family of algorithms, encapsulates each one, and makes them interchangeable. The caller selects the algorithm at runtime.

**How it appears here:**  
`load_from_history` takes an `apply_event` function pointer:

```zig
pub fn load_from_history(
    self: *Aggregate,
    events: []const DomainEvent,
    apply_event: *const fn (self: *Aggregate, event: DomainEvent) anyerror!void,
) !void
```

The consuming application supplies the `apply_event` function that knows how to mutate its concrete aggregate type for each event type. The base `Aggregate` struct knows the loop (iterate events in order, call the function, advance version); the consuming application knows the domain logic inside that function.

**Why:** The library cannot know the consuming application's aggregate types. Passing the application function as a function pointer lets the library own the replay loop while the application owns the domain logic. This is a clean inversion of control without requiring the library to be aware of any application types.

---

## 9. Facade Pattern

**Where:** `src/root.zig`.

**What it is:** A Facade provides a simplified interface to a subsystem, hiding its internal complexity.

**How it appears here:**  
`root.zig` is twelve lines. It re-exports `cqrs`, `event_store`, `postgres_pool`, `repositories`, `router`, `http`, `json`, and `adapters` under a single `atomik-cqrs` import. A consuming application writes:

```zig
const atomik = @import("atomik-cqrs");
// Then uses atomik.cqrs.DomainEvent, atomik.event_store.EventStoreAdapter, etc.
```

The internal module structure (`src/cqrs.zig`, `src/event_store.zig`, and so on) is an implementation detail. The facade is the public surface.

**Why:** It lets the library reorganize its internals without breaking consuming code. It also makes the import story simple: one name, one import, access to everything.

---

## 10. Bridge Pattern

**Where:** `src/postgres_pool.zig` and `src/libpq_mock.zig` / `src/libpq.zig`.

**What it is:** The Bridge pattern decouples an abstraction from its implementation so the two can vary independently.

**How it appears here:**  
`postgres_pool.zig` imports its libpq backend via a compile-time constant:

```zig
const libpq = @import("libpq_mock.zig");
```

Swapping to a real connection requires changing this one import to `@import("libpq.zig")` and linking libpq in `build.zig`. The `Connection`, `ConnectionPool`, and `Transaction` code is identical in both cases — it calls `libpq.PQconnectdb(...)`, `libpq.PQexecParams(...)`, and so on, without knowing which implementation is behind the module name.

**Why:** This is how CI stays hermetic. The mock always returns `null` from `PQconnectdb` and `CONNECTION_BAD` from `PQstatus`, which makes every connection attempt fail predictably. Tests exercise error propagation through the pool and adapter layers without needing a running PostgreSQL instance. The swap to the real backend is mechanical and auditable — one line changed, one linker flag added.

---

## 11. Null Object Pattern

**Where:** `src/libpq_mock.zig`.

**What it is:** The Null Object pattern provides a default implementation of an interface that does nothing (or returns safe defaults), allowing code to avoid explicit null checks.

**How it appears here:**  
`libpq_mock.zig` implements every libpq function with safe-but-failing behavior: `PQconnectdb` returns `null`, `PQstatus` returns `CONNECTION_BAD`, `PQresultStatus` returns `PGRES_FATAL_ERROR`, `PQclear` is a no-op. The calling code in `postgres_pool.zig` never needs to check "is this the mock or the real library?" It just calls the functions and handles the errors they return.

**Why:** The alternative — conditional compilation or `if (is_test)` branches — pollutes the production code path with test concerns. The Null Object keeps the production code clean and lets tests verify that errors propagate correctly.

---

## 12. Fixed-Buffer Allocator (edge-specific)

**Where:** `edge/worker_main.zig`.

**What it is:** A fixed-buffer allocator serves all allocation requests from a pre-allocated static region. When the region is exhausted, it returns an error rather than calling the OS for more memory.

**How it appears here:**  
```zig
var heap: [256 * 1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&heap);
```

All per-request allocations (parsing the request, building the event, serializing the response) come from this 256KB region. After the response is written to the static `output_buf`, `fba.reset()` returns all memory to the pool for the next request.

**Why:** The `wasm32-freestanding` target has no OS allocator. There is no `malloc`, no `mmap`, no heap growth. The fixed-buffer allocator is the only allocator available in this environment. The reset-per-request pattern means the allocator is effectively an arena: fast allocation (pointer bump), free everything at once at the end of the request.

---

## Pattern Interaction Map

```
CQRS ──────────────────────────────────────────┐
│                                               │
│  Command ──► Event Sourcing                   │
│               │                               │
│               ├─► Aggregate (Strategy)        │
│               │   └─► apply_event fn ptr      │
│               │                               │
│               └─► EventStoreAdapter (Adapter) │
│                   │                           │
│                   ├─► PostgresAdapter         │
│                   │   └─► ConnectionPool (Pool)
│                   │       └─► libpq (Bridge)  │
│                   │           ├─► mock (Null Object, CI)
│                   │           └─► real (production)
│                   │                           │
│                   ├─► InMemoryStore (tests)   │
│                   └─► SQLiteAdapter (template)│
│                                               │
│  Query ──────────────────────────────────────►│
│               Repository (direct SQL)         │
│                                               │
│  root.zig (Facade) ──► all of the above       │
│                                               │
│  WASM edge                                    │
│  └─► FixedBufferAllocator + Bridge (mock libpq excluded)
└───────────────────────────────────────────────┘
```

Every pattern here serves one of two goals: **keeping the library domain-agnostic** (open strings, strategy function pointers, adapter interface) or **making tests hermetic without compromising production correctness** (bridge with null object mock, RAII, fixed-buffer allocator on WASM). The rest is infrastructure for the event sourcing model itself.
