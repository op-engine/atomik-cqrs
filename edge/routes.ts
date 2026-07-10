// Route-glue logic for the edge Worker, decoupled from the real WASM FFI boundary and the real
// Postgres client so it can be unit-tested in isolation (see worker.test.ts) — mirrors ADR-11's
// split: WASM owns domain logic, this module (running in JS) owns orchestrating I/O around it.
// worker.js is the thin Cloudflare Workers entrypoint that wires the real callWasm/store in.

import { OptimisticConcurrencyConflict, type DomainEventInput, type StoredEvent } from './persistence';

export interface WasmResponse {
  status: number;
  body: any;
}

export type CallWasm = (method: string, path: string, body: string) => Promise<WasmResponse>;

export interface Store {
  appendEvent(tenantId: string, event: DomainEventInput): Promise<void>;
  getEvents(tenantId: string, aggregateId: string, aggregateType: string): Promise<StoredEvent[]>;
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

const AGGREGATE_TYPE = 'DemoWidget';

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
  async function createWidget(input: {
    tenantId: string;
    userId: string;
    aggregateId: string;
    name: string;
  }): Promise<WasmResponse> {
    const existing = await store.getEvents(input.tenantId, input.aggregateId, AGGREGATE_TYPE);
    const expectedVersion = existing.length > 0 ? existing[existing.length - 1].version : 0;

    const commandBody = JSON.stringify({
      aggregate_id: input.aggregateId,
      expected_version: expectedVersion,
      timestamp: Date.now(),
      name: input.name,
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
      body: { event_id: eventJson.event_id, aggregate_id: eventJson.aggregate_id, version: eventJson.version },
    };
  }

  /** Replay flow: fetch committed events, hand them to WASM's Aggregate.load_from_history. */
  async function replayWidget(input: { tenantId: string; aggregateId: string }): Promise<WasmResponse> {
    const events = await store.getEvents(input.tenantId, input.aggregateId, AGGREGATE_TYPE);

    const replayBody = JSON.stringify({
      aggregate_id: input.aggregateId,
      // event.data is already a JSON-encoded string (matches Zig's DomainEvent.data) — pass it
      // through as-is, do NOT JSON.parse it here, or it'd be embedded as a nested object instead
      // of the string worker_main.zig's std.json.parseFromSlice(ReplayEventInput, ...) expects.
      events: events.map((e) => ({ event_type: e.eventType, version: e.version, data: e.data })),
    });

    return callWasm('POST', '/replay', replayBody);
  }

  return { health, createWidget, replayWidget };
}
