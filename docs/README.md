# Atomik CQRS: Engineering Summary & Honest Assessment

## Executive Statement

Atomik CQRS is a production-ready event sourcing runtime designed for a specific deployment model that existing frameworks don't address: **CQRS at the edge, scaling from zero with no infrastructure dependencies.**

It is not a drop-in replacement for EventStoreDB or Axon. It solves a different problem for a different audience.

---

## What This Library Actually Does

### The Core Problem
Event sourcing requires:
- **Optimistic concurrency control** (detect conflicts at aggregate level, not row level)
- **Idempotency** (safe retries after network failures)
- **Event replay** (rebuild state or project into read models)
- **Multi-tenancy** (isolation guarantees)

Existing frameworks (EventStoreDB, Axon, NEventStore) solve this—but they assume **persistent infrastructure**: always-on servers, connection pooling, cluster coordination, DevOps overhead.

### The Gap Atomik Fills
Modern deployment is shifting toward **edge computing**:
- Cloudflare Workers, Deno Deploy, Lambda@Edge
- Stateless request handlers
- Auto-scaling from zero
- Pay-per-request billing

These environments need CQRS semantics, but can't run traditional event sourcing systems. Atomik is purpose-built for this model:

1. **Compile once, deploy anywhere**: Zig → native binary (servers) or WASM (edge)
2. **No persistent connections**: Each request is stateless; connect, execute, disconnect
3. **Bring your own database**: PostgreSQL, SQLite, MySQL—Atomik doesn't own your storage
4. **Minimal dependencies**: Link one system library (`libpq`); everything else is self-contained

---

## Technical Architecture Decisions

### Why Zig?

| Criterion | Zig Advantage | Trade-off |
|-----------|---------------|-----------|
| Memory management | Predictable, no GC | Language is pre-1.0, not mainstream |
| WASM support | First-class, seamless | Zig ecosystem is small |
| C interop | Clean FFI to `libpq` | Developers used to higher-level languages |
| Binary size | Minimal (WASM ~256KB harness) | Startup time matters in serverless |
| Portability | Same bytecode → server/edge/embedded | Compiler still evolving |

**Decision rationale**: For edge computing, unpredictable GC pauses are a deal-breaker. Zig's control over memory and CPU is essential. The pre-1.0 status is a constraint, not a flaw—it means the language will improve (and potentially break things).

### Optimistic Concurrency Control

Atomik enforces versioning at the database level:

```sql
UNIQUE INDEX (tenant_id, aggregate_id, version)
```

On write:
- Fetch current version of aggregate
- Apply command, emit events
- `INSERT` new events with `version + 1`
- If duplicate key error → version conflict (another request won)

**Why this approach:**
- Works on any ACID database (PostgreSQL, SQLite, MySQL)
- No distributed transactions or consensus needed
- Conflict is detected at event insert, not during state load
- Safe for edge: no persistent locks or connection state

**Trade-off**: You must handle version conflicts in your application logic (retry, merge, reject). This is intentional—Atomik doesn't decide how to resolve conflicts; your domain does.

### Single Aggregate Transactions

Commands can only write to one aggregate at a time.

**Why**: 
- Eliminates distributed transaction complexity
- Enables edge deployment (no cross-aggregate locks)
- Follows event sourcing best practice (aggregates are consistency boundaries)

**How to handle multi-aggregate changes**:
- Use the **saga pattern** (not built-in, but straightforward to implement)
- Example: `PlaceOrder` writes `Order` aggregate, publishes `OrderPlaced` event; `CustomerAggregate` subscribes via projection

### Projections: Pull-Based, Not Push-Based

The `ProjectionRunner` polls the event store for new events and maintains checkpoints (resumable cursors).

```zig
// On each invocation: load checkpoint, query events since checkpoint, apply, save new checkpoint
try runner.run(projection);
```

**Why**:
- Projections are stateless and idempotent
- WASM-compatible (no persistent subscriptions)
- Works in serverless (Cloudflare Cron Triggers)
- Simple to reason about and debug

**What it doesn't do**:
- Push events to external systems (Kafka, webhooks, etc.)
- Fan-out to multiple subscribers
- Stream large event batches efficiently

For those, Atomik is designed to pair with a **broker layer** (planned as `atomik-relay`). The event store is the source of truth; the relay fan-outs.

### Connection Pool

The `ConnectionPool` is intentionally minimal and **single-threaded**.

```zig
var pool = try postgres_pool.ConnectionPool.init(allocator, dsn, 4);
```

**Why**:
- Cloudflare Workers, Lambda, most edge runtimes are single-threaded
- One connection per request is the expected pattern
- Pooling is trivial for environments with connection reuse

**Trade-off**: If you're running a multi-threaded server, see `docs/adr/decisions.md` ADR-06 for the path to thread-safe pooling.

---

## What's Complete vs. Scaffolded

### ✅ Production-Ready

- **Core CQRS runtime**: Event append, version control, conflict detection
- **PostgreSQL adapter**: Full implementation with transaction safety
- **WASM compilation**: Tested; edge deployment working
- **Projections**: Pull-based checkpoint system, in-memory and Postgres storage
- **HTTP utilities**: Request/response envelopes, routing, JSON helpers
- **Multi-tenancy**: Tenant isolation at storage level
- **Tests**: Integration tests against live Postgres

### 🚧 Scaffolded (Template, Not Functional)

- **MySQL adapter**: `src/adapters/mysql_template.zig` provides the shape; TODOs show what to implement
- **SQLite adapter**: Same as above; templates are correct, implementations needed
- **Migration tool**: Infrastructure present; file discovery loop not wired

### 📋 Planned (Not Started)

- **Snapshots**: For aggregates with 10k+ events, replay gets slow
- **Event encryption at rest**: For sensitive domains
- **Relay**: Cross-service event fan-out (Kafka, NATS, webhooks)
- **Time-travel debugging CLI**: Query past state of any aggregate

**Note**: Scaffolded features are intentionally incomplete. They exist to show the shape; contributors can fill them in. This is honest—don't claim done what isn't.

---

## Constraints & Trade-offs (Stated Plainly)

| Constraint | Reason | Impact |
|-----------|--------|--------|
| Single aggregate per transaction | Simplicity + edge compatibility | Multi-aggregate changes need saga pattern |
| Sequential consistency only | No global ordering | Build read models for cross-aggregate queries |
| Projections are pull-based | WASM-compatible, stateless | Can't subscribe to real-time event stream |
| Connection pool is single-threaded | Designed for serverless | Multi-threaded servers need custom pool |
| Zig is pre-1.0 | Language is evolving | Risk of breaking changes; requires stability commitment |

**These are not bugs.** They are deliberate choices that keep the runtime simple and aligned with edge deployment patterns.

---

## The Deployment Model This Enables

### Before Atomik
```
User Request
    ↓
Cloud Function / Lambda
    ↓
Connect to persistent event store service (EventStoreDB cluster)
    ↓
Complex connection pool management
    ↓
Response
```

Infrastructure cost: Always-on cluster + DevOps overhead.

### With Atomik
```
User Request (anywhere: CDN edge, region, origin)
    ↓
WASM Module (Cloudflare Worker, Lambda@Edge, etc.)
    ↓
Stateless command handler
    ↓
Connect to your managed DB (Postgres RDS, Neon, Supabase)
    ↓
Append events, return response
    ↓
Module unloads; connection closes
```

Infrastructure cost: Managed Postgres + pay-per-request compute.

**Key difference**: You don't pay for idle infrastructure. Atomik handlers scale from zero.

---

## When to Use Atomik

### ✅ Good Fit

- Building **event-sourced systems for edge deployment** (Cloudflare Workers, Lambda@Edge, Deno Deploy)
- Need **financial/audit-trail semantics** (fraud detection, payment authorization, compliance)
- Want to **own your database choice** (not tied to EventStoreDB's architecture)
- Building **multi-tenant systems** where isolation matters
- Team comfortable with **Zig or willing to learn it**
- Existing PostgreSQL, SQLite, or MySQL infrastructure to leverage

### ❌ Poor Fit

- Traditional server-based CQRS systems (use EventStoreDB or Axon)
- Real-time event subscriptions required (Atomik is pull-based)
- Need a fully managed, hosted event store (bring-your-own-DB model)
- Team doesn't want to learn Zig (bootstrap cost is real)
- Require commercial support (Atomik is community-driven)

---

## What Must Be True for Adoption

### Technical Viability
1. **Zig stabilizes**: Language reaches 1.0+ and maintains backward compatibility
2. **Edge computing becomes default**: Not a niche feature, but the primary deployment model
3. **Optimistic concurrency control proves effective at scale**: Real-world workloads validate the versioning strategy

### Community Viability
1. **Demonstrable wins**: Companies publicly adopting Atomik and sharing results
2. **Contributor ecosystem**: MySQL/SQLite adapters completed, new features driven by users
3. **Documentation by example**: Tutorial applications showing order systems, payment flows, etc.

### Operational Maturity
1. **Complete the scaffolded features**: Migration tool, MySQL/SQLite adapters
2. **Performance benchmarks**: Compare WASM edge latency to traditional servers
3. **Failure mode documentation**: What happens when conflicts occur? When databases are unavailable?

---

## Honest Assessment of Current State

### Strengths
- **Solves a real, growing problem**: Edge computing + CQRS is a legitimate market
- **Well-architected**: Design decisions are principled, documented (ADRs), and aligned with constraints
- **Production code**: OpEngine uses this in SOC 2-compliant financial software; it's not research
- **No technical shortcuts**: Proper error handling, tests, multi-tenancy, transaction safety

### Weaknesses
- **Tiny audience**: Zig developers + CQRS practitioners + edge computing enthusiasts = very small intersection
- **Unproven at scale**: One company, one domain (accounting). More wins needed
- **Incomplete ecosystem**: MySQL/SQLite still templates; relay not started
- **Language risk**: Zig's stability as a dependency is a real concern for production adoption
- **Solo creator**: Community contributions are minimal; knowledge concentration

### What It's Not
- A competitor to EventStoreDB (different deployment model)
- A simplified CQRS framework (it's as complex as it needs to be)
- A framework for every event sourcing use case (it's specialized)

### What It Is
- A **purpose-built event sourcing runtime for edge computing**
- **Honest about constraints**: Single-aggregate transactions, pull-based projections, bring-your-own-database
- **Serious engineering**: Not abandoned code; actively maintained and used
- **An experiment in edge-first architecture** that could become important if the industry moves that direction

---

## Recommendations for Users

### Considering Adoption

1. **Pilot on non-critical path**: Use Atomik for a feature that benefits from edge deployment but isn't core to your system
2. **Engage with OpEngine**: They're active users; ask about their experience
3. **Plan for Zig skill-building**: Your team will need to learn the language; that's not insurmountable but is a cost
4. **Prototype the conflict handling**: Build a test scenario where two requests write to the same aggregate simultaneously; make sure your conflict resolution logic works
5. **Evaluate your database choice**: Atomik connects to Postgres/SQLite/MySQL, but you own the schema, migrations, backups, scaling

### Contributing

- **Adapt a template**: SQLite or MySQL adapter; templates show the shape, implementation is straightforward
- **Improve docs**: Real-world examples (order systems, ledgers, subscriptions) help adoption
- **Benchmark**: Performance at scale; WASM vs. native vs. traditional servers
- **Report wins**: If you build something with Atomik, share it; community needs proof points

---

## Final Word

Atomik CQRS is **not trying to be everything**. It's trying to be the right tool for a specific problem: event sourcing on the edge, with no infrastructure overhead, scaling from zero.

If that's your problem, it's worth serious consideration. If it's not, use something else—there are excellent alternatives.

The honesty is in the clarity: about what works, what's incomplete, what's intentionally constrained, and what would need to happen for broad adoption.

That's how you earn trust.

---

**Document Version**: July 2026  
**Library Version**: 0.1.0  
**Status**: Active development, production use by OpEngine
