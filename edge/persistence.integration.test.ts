// Live-database tests for persistence.ts, run against the ephemeral Neon branch provisioned by
// `make db-provision` (packages/atomik-cqrs/.env.local -> ATOMIK_DATABASE_URL). Bun loads
// .env.local automatically. Mirrors atomik-cqrs's own test-integration/test-integration-local
// split (their Makefile) — this file is the TS-side equivalent.
//
// Never point this at the production NEON_DB_KEY value from betty's root .env — this test
// performs concurrent writes and deliberately triggers constraint violations.

import { describe, test, expect, beforeAll } from 'bun:test';
import { createStore, OptimisticConcurrencyConflict, type DomainEventInput } from './persistence';

const databaseUrl = process.env.ATOMIK_DATABASE_URL;

if (!databaseUrl) {
  throw new Error(
    "ATOMIK_DATABASE_URL is not set. Run 'make db-provision' first (writes packages/atomik-cqrs/.env.local).",
  );
}

const store = createStore(databaseUrl);

// Fresh per test-run so repeated runs against the same branch never collide.
const tenantId = crypto.randomUUID();
const aggregateId = crypto.randomUUID();
const userId = crypto.randomUUID();

function eventAt(version: number, name: string): DomainEventInput {
  return {
    eventId: crypto.randomUUID(),
    aggregateId,
    aggregateType: 'DemoWidget',
    eventType: 'DemoWidgetCreated',
    tenantId,
    version,
    timestamp: Date.now(),
    userId,
    data: JSON.stringify({ name }),
  };
}

describe('persistence.ts against a real Postgres database', () => {
  test('appends event v1 for a fresh aggregate', async () => {
    await store.appendEvent(tenantId, eventAt(1, 'Widget v1'));
  });

  test('appends event v2 for the same aggregate', async () => {
    await store.appendEvent(tenantId, eventAt(2, 'Widget v2'));
  });

  test('rejects a second write at an already-committed version', async () => {
    await expect(store.appendEvent(tenantId, eventAt(2, 'Widget v2 duplicate'))).rejects.toThrow(
      OptimisticConcurrencyConflict,
    );
  });

  test('under concurrent writes at the same version, exactly one wins', async () => {
    const results = await Promise.allSettled([
      store.appendEvent(tenantId, eventAt(3, 'Widget v3a')),
      store.appendEvent(tenantId, eventAt(3, 'Widget v3b')),
    ]);

    const fulfilled = results.filter((r) => r.status === 'fulfilled');
    const rejected = results.filter((r) => r.status === 'rejected');

    expect(fulfilled).toHaveLength(1);
    expect(rejected).toHaveLength(1);
    expect((rejected[0] as PromiseRejectedResult).reason).toBeInstanceOf(OptimisticConcurrencyConflict);
  });

  test('getEvents returns only committed rows, in version order', async () => {
    const events = await store.getEvents(tenantId, aggregateId, 'DemoWidget');

    expect(events.map((e) => e.version)).toEqual([1, 2, 3]);
    expect(events.every((e) => e.eventType === 'DemoWidgetCreated')).toBe(true);
    expect(JSON.parse(events[2].data)).toHaveProperty('name');
  });
});
