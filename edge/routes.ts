// Route-glue logic for the edge Worker, decoupled from the real WASM FFI boundary and the real
// Postgres client so it can be unit-tested in isolation (see worker.test.ts) — mirrors ADR-11's
// split: WASM owns domain logic, this module (running in JS) owns orchestrating I/O around it.
// worker.js is the thin Cloudflare Workers entrypoint that wires the real callWasm/store in.
//
// Domain-agnostic on purpose: aggregate_type/event_type/data all come from the caller, not
// hardcoded here. No real LMS command handlers exist yet (ADR-002 territory) — until they do,
// this stays generic plumbing rather than locked to one placeholder shape.

import { OptimisticConcurrencyConflict, type AuditEvent, type DomainEventInput, type StoredEvent } from './persistence';

export interface WasmResponse {
  status: number;
  body: any;
}

export type CallWasm = (method: string, path: string, body: string) => Promise<WasmResponse>;

export interface Store {
  appendEvent(tenantId: string, event: DomainEventInput): Promise<void>;
  getEvents(tenantId: string, aggregateId: string, aggregateType: string): Promise<StoredEvent[]>;
  listEvents(tenantId: string, limit: number): Promise<AuditEvent[]>;
}

interface CommandEventJson {
  event_id: string;
  aggregate_id: string;
  aggregate_type: string;
  event_type: string;
  version: number;
  timestamp: number;
  data: unknown;
}

export function createRoutes(deps: { callWasm: CallWasm; store: Store }) {
  const { callWasm, store } = deps;

  async function health(): Promise<WasmResponse> {
    return callWasm('GET', '/health', '');
  }

  /**
   * Create/append flow. WASM has no state of its own, so this function owns the actual I/O
   * boundary from ADR-11: read the current version, ask WASM to validate/construct the next
   * event at that version, then persist it — where the database's unique index is the real
   * arbiter under concurrent writes, not anything computed here.
   */
  async function createEvent(input: {
    tenantId: string;
    userId: string;
    aggregateId: string;
    aggregateType: string;
    eventType: string;
    data: unknown;
  }): Promise<WasmResponse> {
    const existing = await store.getEvents(input.tenantId, input.aggregateId, input.aggregateType);
    const expectedVersion = existing.length > 0 ? existing[existing.length - 1].version : 0;

    const commandBody = JSON.stringify({
      aggregate_id: input.aggregateId,
      aggregate_type: input.aggregateType,
      event_type: input.eventType,
      expected_version: expectedVersion,
      timestamp: Date.now(),
      data: input.data,
    });

    const wasmResult = await callWasm('POST', '/commands', commandBody);
    if (wasmResult.status !== 200) {
      return wasmResult;
    }

    const eventJson = wasmResult.body as CommandEventJson;
    const eventInput: DomainEventInput = {
      eventId: eventJson.event_id,
      aggregateId: eventJson.aggregate_id,
      aggregateType: eventJson.aggregate_type,
      eventType: eventJson.event_type,
      tenantId: input.tenantId,
      version: eventJson.version,
      timestamp: eventJson.timestamp,
      userId: input.userId,
      data: JSON.stringify(eventJson.data),
    };

    try {
      await store.appendEvent(input.tenantId, eventInput);
    } catch (err) {
      if (err instanceof OptimisticConcurrencyConflict) {
        return { status: 409, body: { error: 'OptimisticConcurrencyConflict' } };
      }
      throw err;
    }

    return {
      status: 200,
      body: {
        event_id: eventJson.event_id,
        aggregate_id: eventJson.aggregate_id,
        aggregate_type: eventJson.aggregate_type,
        event_type: eventJson.event_type,
        version: eventJson.version,
      },
    };
  }

  /**
   * Replay flow: fetch committed events, hand them to WASM's generic merge-fold
   * (Aggregate.load_from_history under the hood). `data` is parsed back into an object here —
   * WASM's /replay now expects a real JSON value per event (std.json.Value), not the
   * JSON-encoded string form Postgres returns it as.
   *
   * The response is enriched with the raw event history (already fetched above for WASM) so
   * callers get both the merged `state` fold and the underlying timeline from one call, without
   * a second round-trip or any Zig changes.
   */
  async function replayAggregate(input: {
    tenantId: string;
    aggregateId: string;
    aggregateType: string;
  }): Promise<WasmResponse> {
    const events = await store.getEvents(input.tenantId, input.aggregateId, input.aggregateType);
    const parsedEvents = events.map((e) => ({ event_type: e.eventType, version: e.version, data: JSON.parse(e.data) }));

    const replayBody = JSON.stringify({
      aggregate_id: input.aggregateId,
      events: parsedEvents,
    });

    const wasmResult = await callWasm('POST', '/replay', replayBody);
    if (wasmResult.status !== 200) {
      return wasmResult;
    }

    return {
      ...wasmResult,
      body: { ...wasmResult.body, events: parsedEvents },
    };
  }

  const AUDIT_LOG_LIMIT = 200;

  /**
   * Tenant-wide event log for the Audit Log view — no WASM involved, a straight read. Response
   * keys are snake_case, matching replayAggregate's WASM-originated convention (the AuditEvent
   * TS type itself is camelCase; this maps it at the boundary rather than changing the type).
   * `data` is parsed back into an object here for the same reason replayAggregate does it: callers
   * get a real JSON value, not the JSON-encoded string form Postgres returns it as.
   */
  async function listEvents(input: { tenantId: string }): Promise<WasmResponse> {
    const events = await store.listEvents(input.tenantId, AUDIT_LOG_LIMIT);
    return {
      status: 200,
      body: {
        events: events.map((e) => ({
          id: e.id,
          aggregate_id: e.aggregateId,
          aggregate_type: e.aggregateType,
          event_type: e.eventType,
          data: JSON.parse(e.data),
          version: e.version,
          timestamp: e.timestamp,
          created_by: e.createdBy,
        })),
      },
    };
  }

  return { health, createEvent, replayAggregate, listEvents };
}
