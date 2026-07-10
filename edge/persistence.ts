// TypeScript persistence layer for the Cloudflare Workers edge deployment.
//
// atomik-cqrs's native EventStoreAdapter (src/adapters/postgres.zig) can't run here: it links
// libpq, which needs real OS sockets, and wasm32-freestanding has none. So this module
// reimplements just enough of the same contract (append with OCC, ordered read) in TypeScript,
// talking to Postgres directly. See ADR-11 (docs/adr/decisions.md) for the full rationale.
//
// UUID encoding: WASM hands back 36-char hyphenated UUID strings (cqrs.uuid_to_string). The
// native adapter stores UUIDs as 32-char lowercase hex with no hyphens (postgres_pool.uuid_to_hex),
// matching init.sql's VARCHAR(32) columns. This module strips hyphens before writing so both
// adapters share the exact same schema and encoding — no DDL changes needed.

import postgres from 'postgres';

export class OptimisticConcurrencyConflict extends Error {
  constructor() {
    super('OptimisticConcurrencyConflict');
    this.name = 'OptimisticConcurrencyConflict';
  }
}

// Minimal shape of postgres.js's tagged-template client — just enough surface for this module,
// and small enough to fake in tests without pulling in the real driver (mirrors atomik-cqrs's
// own libpq mock/real bridge pattern, their ADR-07, on the TS side).
export type SqlClient = <T = unknown>(strings: TemplateStringsArray, ...values: unknown[]) => Promise<T>;

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
  const sql: SqlClient = typeof client === 'string' ? (postgres(client) as unknown as SqlClient) : client;

  async function appendEvent(tenantId: string, event: DomainEventInput): Promise<void> {
    const tenantHex = stripHyphens(tenantId);
    const idHex = stripHyphens(event.eventId);
    const aggregateHex = stripHyphens(event.aggregateId);
    const createdByHex = stripHyphens(event.userId);

    // postgres.js auto-JSON.stringifies a parameter that's cast to ::jsonb, so we must hand it a
    // parsed object here — event.data is already a JSON-encoded string (matches Zig's
    // DomainEvent.data), and passing it through unparsed would double-encode it (the column ends
    // up holding a jsonb *string of a string* instead of the object).
    const parsedData: unknown = JSON.parse(event.data);

    try {
      await sql`
        INSERT INTO events (id, tenant_id, aggregate_id, aggregate_type, event_type, event_data, version, timestamp, created_by)
        VALUES (${idHex}, ${tenantHex}, ${aggregateHex}, ${event.aggregateType}, ${event.eventType}, ${parsedData}::jsonb, ${event.version}, ${event.timestamp}, ${createdByHex})
      `;
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

    const rows = await sql<{ event_type: string; version: number; data: string }[]>`
      SELECT event_type, version, event_data::text AS data
      FROM events
      WHERE tenant_id = ${tenantHex}
        AND aggregate_id = ${aggregateHex}
        AND aggregate_type = ${aggregateType}
      ORDER BY version ASC
    `;

    return rows.map((row) => ({
      eventType: row.event_type,
      version: row.version,
      data: row.data,
    }));
  }

  return { appendEvent, getEvents };
}
