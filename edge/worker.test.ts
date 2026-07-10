// Hermetic unit tests for the route-glue logic in routes.ts — the JS-side orchestration that
// ADR-11 puts around the WASM domain logic. Mocks both the WASM FFI boundary (callWasm) and the
// persistence layer (Store), so this never touches a real database or the compiled .wasm binary.
// (worker.js itself isn't imported here: it does a top-level `import ... from
// '../zig-out/wasm/...wasm'`, a Cloudflare-Workers-specific module type Bun's test runner can't
// resolve — routes.ts exists specifically so the testable logic doesn't carry that dependency.)

import { describe, test, expect, mock } from 'bun:test';
import { createRoutes, type CallWasm, type Store, type WasmResponse } from './routes';
import { OptimisticConcurrencyConflict, type DomainEventInput, type StoredEvent } from './persistence';

function mockCallWasm(handler: (method: string, path: string, body: string) => WasmResponse) {
  const calls: { method: string; path: string; body: string }[] = [];
  const callWasm: CallWasm = async (method, path, body) => {
    calls.push({ method, path, body });
    return handler(method, path, body);
  };
  return { callWasm, calls };
}

function mockStore(opts: { events?: StoredEvent[]; appendEvent?: (tenantId: string, event: DomainEventInput) => Promise<void> } = {}) {
  const appendCalls: { tenantId: string; event: DomainEventInput }[] = [];
  const store: Store = {
    async getEvents() {
      return opts.events ?? [];
    },
    async appendEvent(tenantId, event) {
      appendCalls.push({ tenantId, event });
      if (opts.appendEvent) await opts.appendEvent(tenantId, event);
    },
  };
  return { store, appendCalls };
}

describe('health', () => {
  test('passes through callWasm\'s response verbatim', async () => {
    const { callWasm } = mockCallWasm(() => ({ status: 200, body: { status: 'healthy', runtime: 'zig-wasm' } }));
    const { store } = mockStore();
    const routes = createRoutes({ callWasm, store });

    const result = await routes.health();

    expect(result).toEqual({ status: 200, body: { status: 'healthy', runtime: 'zig-wasm' } });
  });
});

describe('createWidget', () => {
  test('computes expected_version 0 for a fresh aggregate and appends the resulting event', async () => {
    const { callWasm, calls } = mockCallWasm((_method, _path, body) => {
      const cmd = JSON.parse(body);
      return {
        status: 200,
        body: {
          event_id: 'event-1',
          aggregate_id: cmd.aggregate_id,
          aggregate_type: 'DemoWidget',
          event_type: 'DemoWidgetCreated',
          version: cmd.expected_version + 1,
          timestamp: cmd.timestamp,
          data: { name: cmd.name },
        },
      };
    });
    const { store, appendCalls } = mockStore({ events: [] });
    const routes = createRoutes({ callWasm, store });

    const result = await routes.createWidget({
      tenantId: 'tenant-1',
      userId: 'user-1',
      aggregateId: 'agg-1',
      name: 'Widget A',
    });

    expect(calls).toHaveLength(1);
    expect(calls[0].path).toBe('/commands');
    expect(JSON.parse(calls[0].body).expected_version).toBe(0);

    expect(appendCalls).toHaveLength(1);
    expect(appendCalls[0].tenantId).toBe('tenant-1');
    expect(appendCalls[0].event).toEqual({
      eventId: 'event-1',
      aggregateId: 'agg-1',
      aggregateType: 'DemoWidget',
      eventType: 'DemoWidgetCreated',
      tenantId: 'tenant-1',
      version: 1,
      timestamp: appendCalls[0].event.timestamp,
      userId: 'user-1',
      data: JSON.stringify({ name: 'Widget A' }),
    });

    expect(result).toEqual({ status: 200, body: { event_id: 'event-1', aggregate_id: 'agg-1', version: 1 } });
  });

  test('computes expected_version from the last existing event', async () => {
    const { callWasm, calls } = mockCallWasm((_m, _p, body) => {
      const cmd = JSON.parse(body);
      return {
        status: 200,
        body: {
          event_id: 'event-3',
          aggregate_id: cmd.aggregate_id,
          aggregate_type: 'DemoWidget',
          event_type: 'DemoWidgetCreated',
          version: cmd.expected_version + 1,
          timestamp: cmd.timestamp,
          data: { name: cmd.name },
        },
      };
    });
    const { store } = mockStore({
      events: [
        { eventType: 'DemoWidgetCreated', version: 1, data: '{}' },
        { eventType: 'DemoWidgetCreated', version: 2, data: '{}' },
      ],
    });
    const routes = createRoutes({ callWasm, store });

    await routes.createWidget({ tenantId: 't', userId: 'u', aggregateId: 'a', name: 'x' });

    expect(JSON.parse(calls[0].body).expected_version).toBe(2);
  });

  test('short-circuits without appending when WASM rejects the command', async () => {
    const { callWasm } = mockCallWasm(() => ({ status: 400, body: { error: 'invalid aggregate_id' } }));
    const { store, appendCalls } = mockStore();
    const routes = createRoutes({ callWasm, store });

    const result = await routes.createWidget({ tenantId: 't', userId: 'u', aggregateId: 'bad', name: 'x' });

    expect(result).toEqual({ status: 400, body: { error: 'invalid aggregate_id' } });
    expect(appendCalls).toHaveLength(0);
  });

  test('surfaces an OCC conflict from the store as HTTP 409', async () => {
    const { callWasm } = mockCallWasm(() => ({
      status: 200,
      body: {
        event_id: 'e', aggregate_id: 'a', aggregate_type: 'DemoWidget', event_type: 'DemoWidgetCreated',
        version: 1, timestamp: 0, data: {},
      },
    }));
    const { store } = mockStore({
      appendEvent: async () => {
        throw new OptimisticConcurrencyConflict();
      },
    });
    const routes = createRoutes({ callWasm, store });

    const result = await routes.createWidget({ tenantId: 't', userId: 'u', aggregateId: 'a', name: 'x' });

    expect(result).toEqual({ status: 409, body: { error: 'OptimisticConcurrencyConflict' } });
  });

  test('does not swallow non-conflict errors from the store', async () => {
    const { callWasm } = mockCallWasm(() => ({
      status: 200,
      body: {
        event_id: 'e', aggregate_id: 'a', aggregate_type: 'DemoWidget', event_type: 'DemoWidgetCreated',
        version: 1, timestamp: 0, data: {},
      },
    }));
    const { store } = mockStore({
      appendEvent: async () => {
        throw new Error('connection reset');
      },
    });
    const routes = createRoutes({ callWasm, store });

    await expect(routes.createWidget({ tenantId: 't', userId: 'u', aggregateId: 'a', name: 'x' })).rejects.toThrow(
      'connection reset',
    );
  });
});

describe('replayWidget', () => {
  test('passes fetched events through to WASM as event_type/version/data, unparsed', async () => {
    const { callWasm, calls } = mockCallWasm(() => ({
      status: 200,
      body: { aggregate_id: 'a', version: 2, name: 'Widget B', event_count: 2 },
    }));
    const { store } = mockStore({
      events: [
        { eventType: 'DemoWidgetCreated', version: 1, data: '{"name":"Widget A"}' },
        { eventType: 'DemoWidgetCreated', version: 2, data: '{"name":"Widget B"}' },
      ],
    });
    const routes = createRoutes({ callWasm, store });

    const result = await routes.replayWidget({ tenantId: 't', aggregateId: 'a' });

    expect(calls).toHaveLength(1);
    expect(calls[0].path).toBe('/replay');
    const sentBody = JSON.parse(calls[0].body);
    expect(sentBody.aggregate_id).toBe('a');
    expect(sentBody.events).toEqual([
      { event_type: 'DemoWidgetCreated', version: 1, data: '{"name":"Widget A"}' },
      { event_type: 'DemoWidgetCreated', version: 2, data: '{"name":"Widget B"}' },
    ]);

    expect(result).toEqual({ status: 200, body: { aggregate_id: 'a', version: 2, name: 'Widget B', event_count: 2 } });
  });
});
