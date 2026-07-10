// TypeScript persistence layer for the Cloudflare Workers edge deployment.
//
// atomik-cqrs's native EventStoreAdapter (src/adapters/postgres.zig) can't run here: it links
// libpq, which needs real OS sockets, and wasm32-freestanding has none. So this module
// reimplements just enough of the same contract (append with OCC, ordered read) in TypeScript,
// talking to Postgres directly. See ADR-11 (docs/adr/decisions.md) for the full rationale.
//
// Driver: `pg` (node-postgres), not postgres.js — postgres.js reproducibly failed against a real
// deployed Hyperdrive binding ("Network connection lost" / "write CONNECTION_CLOSED" on the very
// first query, every time, despite matching every documented config), even though it worked fine
// under local `wrangler dev` (which bypasses the real Hyperdrive proxy layer entirely). `pg` is
// Cloudflare's own "RECOMMENDED" driver for Hyperdrive; confirmed working end-to-end against the
// real production binding where postgres.js was not.
//
// UUID encoding: WASM hands back 36-char hyphenated UUID strings (cqrs.uuid_to_string). The
// native adapter stores UUIDs as 32-char lowercase hex with no hyphens (postgres_pool.uuid_to_hex),
// matching init.sql's VARCHAR(32) columns. This module strips hyphens before writing so both
// adapters share the exact same schema and encoding — no DDL changes needed.

import { Client } from 'pg';

export class OptimisticConcurrencyConflict extends Error {
  constructor() {
    super('OptimisticConcurrencyConflict');
    this.name = 'OptimisticConcurrencyConflict';
  }
}

// Minimal query surface — just enough to fake in tests without pulling in the real driver
// (mirrors atomik-cqrs's own libpq mock/real bridge pattern, their ADR-07, on the TS side).
// Matches pg's Client.query(text, params) shape directly.
export type SqlClient = (text: string, params: unknown[]) => Promise<{ rows: any[] }>;

export interface DomainEventInput {
  eventId: string;
  aggregateId: string;
  aggregateType: string;
  eventType: string;
  tenantId: string;
  version: number;
  timestamp: number;
  userId: string;
  /** JSON-encoded string — matches Zig's DomainEvent.data ([]const u8, a JSON payload). */
  data: string;
}

export interface StoredEvent {
  eventType: string;
  version: number;
  /** JSON-encoded string, passed through unparsed for WASM to consume. */
  data: string;
}

function stripHyphens(uuid: string): string {
  const hex = uuid.replace(/-/g, '');
  if (hex.length !== 32) {
    throw new Error(`invalid UUID (expected 36-char hyphenated or 32-char hex): ${uuid}`);
  }
  return hex;
}

function isUniqueViolation(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: string }).code === '23505';
}

export function createStore(client: string | SqlClient) {
  const ownsClient = typeof client === 'string';
  const pgClient = ownsClient ? new Client({ connectionString: client as string }) : null;

  // pg requires an explicit connect() before querying; do it lazily so `createStore` itself
  // stays synchronous, and only once even if multiple queries fire concurrently.
  let connecting: Promise<void> | null = null;
  async function ensureConnected(): Promise<void> {
    if (!pgClient) return;
    if (!connecting) connecting = pgClient.connect();
    await connecting;
  }

  const query: SqlClient = ownsClient
    ? async (text, params) => {
        await ensureConnected();
        return pgClient!.query(text, params);
      }
    : (client as SqlClient);

  /** No-op for an injected/fake client (tests own that lifecycle); closes the real connection
   *  otherwise. Call via `ctx.waitUntil(store.end())` so cleanup doesn't block the response. */
  async function end(): Promise<void> {
    if (pgClient) await pgClient.end();
  }

  async function appendEvent(tenantId: string, event: DomainEventInput): Promise<void> {
    const tenantHex = stripHyphens(tenantId);
    const idHex = stripHyphens(event.eventId);
    const aggregateHex = stripHyphens(event.aggregateId);
    const createdByHex = stripHyphens(event.userId);

    try {
      await query(
        `INSERT INTO events (id, tenant_id, aggregate_id, aggregate_type, event_type, event_data, version, timestamp, created_by)
         VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9)`,
        [
          idHex,
          tenantHex,
          aggregateHex,
          event.aggregateType,
          event.eventType,
          // pg does not auto-stringify (unlike postgres.js) — event.data is already a
          // JSON-encoded string, so it can be bound directly and cast with ::jsonb.
          event.data,
          event.version,
          event.timestamp,
          createdByHex,
        ],
      );
    } catch (err) {
      if (isUniqueViolation(err)) {
        throw new OptimisticConcurrencyConflict();
      }
      throw err;
    }
  }

  async function getEvents(tenantId: string, aggregateId: string, aggregateType: string): Promise<StoredEvent[]> {
    const tenantHex = stripHyphens(tenantId);
    const aggregateHex = stripHyphens(aggregateId);

    const result = await query(
      `SELECT event_type, version, event_data::text AS data
       FROM events
       WHERE tenant_id = $1 AND aggregate_id = $2 AND aggregate_type = $3
       ORDER BY version ASC`,
      [tenantHex, aggregateHex, aggregateType],
    );

    return result.rows.map((row) => ({
      eventType: row.event_type,
      version: row.version,
      data: row.data,
    }));
  }

  return { appendEvent, getEvents, end };
}
