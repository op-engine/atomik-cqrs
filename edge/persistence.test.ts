// Hermetic unit tests for persistence.ts — no network, no real database. Mocks the
// postgres.js tagged-template client to prove OCC-conflict translation, UUID hyphen-stripping,
// and query parameter shape in isolation. Mirrors atomik-cqrs's own libpq mock/real bridge
// pattern (their ADR-07) applied to the TS side. Live-database behavior is covered separately
// in persistence.integration.test.ts.

import { describe, test, expect } from 'bun:test';
import { createStore, OptimisticConcurrencyConflict, type SqlClient, type DomainEventInput } from './persistence';

const TENANT_ID = '11111111-2222-3333-4444-555555555555';
const AGGREGATE_ID = '66666666-7777-8888-9999-aaaaaaaaaaaa';
const USER_ID = 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff';
const EVENT_ID = '01234567-89ab-cdef-0123-456789abcdef';

function baseEvent(overrides: Partial<DomainEventInput> = {}): DomainEventInput {
  return {
    eventId: EVENT_ID,
    aggregateId: AGGREGATE_ID,
    aggregateType: 'DemoWidget',
    eventType: 'DemoWidgetCreated',
    tenantId: TENANT_ID,
    version: 1,
    timestamp: 1720000000000,
    userId: USER_ID,
    data: '{"name":"Widget A"}',
    ...overrides,
  };
}

// Captures every call so assertions can inspect exact parameter values/order without a real DB.
function mockSql(handler: (values: unknown[]) => unknown) {
  const calls: unknown[][] = [];
  const sql = (async (_strings: TemplateStringsArray, ...values: unknown[]) => {
    calls.push(values);
    return handler(values);
  }) as SqlClient;
  return { sql, calls };
}

describe('appendEvent', () => {
  test('strips hyphens from all UUID fields before writing, in column order', async () => {
    const { sql, calls } = mockSql(() => []);
    const store = createStore(sql);

    await store.appendEvent(TENANT_ID, baseEvent());

    expect(calls).toHaveLength(1);
    const [idHex, tenantHex, aggregateHex, aggregateType, eventType, data, version, timestamp, createdByHex] =
      calls[0];

    expect(idHex).toBe('0123456789abcdef0123456789abcdef');
    expect(tenantHex).toBe('11111111222233334444555555555555');
    expect(aggregateHex).toBe('66666666777788889999aaaaaaaaaaaa');
    expect(createdByHex).toBe('bbbbbbbbccccddddeeeeffffffffffff');
    expect(aggregateType).toBe('DemoWidget');
    expect(eventType).toBe('DemoWidgetCreated');
    // event.data is a JSON-encoded string in; the client receives the *parsed* object, so
    // postgres.js's own ::jsonb auto-stringify only encodes it once (see persistence.ts).
    expect(data).toEqual({ name: 'Widget A' });
    expect(version).toBe(1);
    expect(timestamp).toBe(1720000000000);

    for (const hex of [idHex, tenantHex, aggregateHex, createdByHex]) {
      expect(hex).not.toContain('-');
      expect((hex as string).length).toBe(32);
    }
  });

  test('translates a Postgres 23505 unique-violation into OptimisticConcurrencyConflict', async () => {
    const { sql } = mockSql(() => {
      throw Object.assign(new Error('duplicate key value violates unique constraint'), { code: '23505' });
    });
    const store = createStore(sql);

    await expect(store.appendEvent(TENANT_ID, baseEvent())).rejects.toThrow(OptimisticConcurrencyConflict);
  });

  test('does not swallow non-conflict database errors', async () => {
    const { sql } = mockSql(() => {
      throw Object.assign(new Error('syntax error'), { code: '42601' });
    });
    const store = createStore(sql);

    await expect(store.appendEvent(TENANT_ID, baseEvent())).rejects.toThrow('syntax error');
  });

  test('rejects malformed UUIDs before ever calling the client', async () => {
    const { sql, calls } = mockSql(() => []);
    const store = createStore(sql);

    await expect(store.appendEvent(TENANT_ID, baseEvent({ aggregateId: 'not-a-uuid' }))).rejects.toThrow(
      /invalid UUID/,
    );
    expect(calls).toHaveLength(0);
  });
});

describe('getEvents', () => {
  test('maps rows and passes hyphen-stripped filters in order', async () => {
    const rows = [
      { event_type: 'DemoWidgetCreated', version: 1, data: '{"name":"Widget A"}' },
      { event_type: 'DemoWidgetRenamed', version: 2, data: '{"name":"Widget B"}' },
    ];
    const { sql, calls } = mockSql(() => rows);
    const store = createStore(sql);

    const result = await store.getEvents(TENANT_ID, AGGREGATE_ID, 'DemoWidget');

    expect(result).toEqual([
      { eventType: 'DemoWidgetCreated', version: 1, data: '{"name":"Widget A"}' },
      { eventType: 'DemoWidgetRenamed', version: 2, data: '{"name":"Widget B"}' },
    ]);

    const [tenantHex, aggregateHex, aggregateType] = calls[0];
    expect(tenantHex).toBe('11111111222233334444555555555555');
    expect(aggregateHex).toBe('66666666777788889999aaaaaaaaaaaa');
    expect(aggregateType).toBe('DemoWidget');
  });

  test('returns an empty array when nothing matches', async () => {
    const { sql } = mockSql(() => []);
    const store = createStore(sql);

    const result = await store.getEvents(TENANT_ID, AGGREGATE_ID, 'DemoWidget');
    expect(result).toEqual([]);
  });
});
