// End-to-end POC runner for ADR-003 Option D / ADR-11. Spawns `wrangler dev` against the edge
// Worker, drives it over HTTP, and asserts the two claims that architecture actually rests on:
// optimistic concurrency control under real concurrent writes, and correct replay. Run via
// `make edge-poc` (from the submodule root) or `bun run edge/poc/run.ts` directly.

import { createStore } from '../persistence';

const PORT = 18787; // distinct from wrangler's 8787 default, to avoid clashing with other dev servers
const BASE_URL = `http://localhost:${PORT}`;

const databaseUrl = process.env.ATOMIK_DATABASE_URL;
if (!databaseUrl) {
  throw new Error("ATOMIK_DATABASE_URL is not set. Run 'make db-provision' first.");
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(`Assertion failed: ${message}`);
}

async function waitForHealth(timeoutMs: number): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(`${BASE_URL}/health`);
      if (res.ok) return;
    } catch {
      // wrangler dev not listening yet
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`wrangler dev did not become healthy within ${timeoutMs}ms`);
}

// DemoWidget/DemoWidgetCreated is just this POC's own placeholder for exercising the mechanism —
// aggregate_type/event_type are caller-supplied now, not hardcoded in the Worker (see routes.ts).
async function createCommand(aggregateId: string, tenantId: string, userId: string, name: string) {
  const res = await fetch(`${BASE_URL}/aggregates/${aggregateId}/commands`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      tenant_id: tenantId,
      user_id: userId,
      aggregate_type: 'DemoWidget',
      event_type: 'DemoWidgetCreated',
      data: { name },
    }),
  });
  return { status: res.status, body: await res.json() };
}

async function replay(aggregateId: string, tenantId: string) {
  const res = await fetch(
    `${BASE_URL}/aggregates/${aggregateId}/state?tenant_id=${tenantId}&aggregate_type=DemoWidget`,
  );
  return { status: res.status, body: await res.json() };
}

async function runAssertions(): Promise<void> {
  const store = createStore(databaseUrl!);
  const tenantId = crypto.randomUUID();
  const aggregateId = crypto.randomUUID();
  const userId = crypto.randomUUID();

  // 1. Create v1, confirm exactly one row lands in Postgres at version 1.
  const first = await createCommand(aggregateId, tenantId, userId, 'Widget v1');
  assert(first.status === 200, `expected 200 creating v1, got ${first.status}: ${JSON.stringify(first.body)}`);
  assert((first.body as any).version === 1, `expected version 1, got ${JSON.stringify(first.body)}`);

  const rowsAfterFirst = await store.getEvents(tenantId, aggregateId, 'DemoWidget');
  assert(rowsAfterFirst.length === 1, `expected exactly 1 row after first create, found ${rowsAfterFirst.length}`);
  assert(rowsAfterFirst[0].version === 1, `expected the row to be version 1, got ${rowsAfterFirst[0].version}`);
  console.log('[1/3] create v1 committed, exactly one row in Postgres — pass');

  // 2. Fire two concurrent commands against the same aggregate. Both read the same "current"
  // state (1 event) before either write lands, so both attempt to commit version 2 — Postgres's
  // unique index is the only thing that can make exactly one of them win.
  const [a, b] = await Promise.allSettled([
    createCommand(aggregateId, tenantId, userId, 'Widget v2a'),
    createCommand(aggregateId, tenantId, userId, 'Widget v2b'),
  ]);

  assert(a.status === 'fulfilled' && b.status === 'fulfilled', 'both concurrent requests should resolve (not reject)');
  const statuses = [
    (a as PromiseFulfilledResult<Awaited<ReturnType<typeof createCommand>>>).value.status,
    (b as PromiseFulfilledResult<Awaited<ReturnType<typeof createCommand>>>).value.status,
  ].sort();
  assert(
    statuses[0] === 200 && statuses[1] === 409,
    `expected exactly one 200 and one 409 under concurrent writes, got statuses ${JSON.stringify(statuses)}`,
  );
  console.log('[2/3] concurrent writes at the same version: exactly one 200, one 409 — pass');

  // 3. Replay must reflect only the two committed events (v1 + whichever v2 attempt won) —
  // never three, regardless of which concurrent attempt succeeded.
  const replayed = await replay(aggregateId, tenantId);
  assert(replayed.status === 200, `expected 200 from replay, got ${replayed.status}: ${JSON.stringify(replayed.body)}`);
  const body = replayed.body as { version: number; event_count: number; state: { name?: string } };
  assert(body.version === 2, `expected replayed version 2, got ${body.version}`);
  assert(body.event_count === 2, `expected exactly 2 events replayed, got ${body.event_count}`);
  assert(
    body.state.name === 'Widget v2a' || body.state.name === 'Widget v2b',
    `unexpected replayed state: ${JSON.stringify(body.state)}`,
  );
  console.log(`[3/3] replay reflects exactly the 2 committed events (state.name="${body.state.name}") — pass`);
}

async function main() {
  const proc = Bun.spawn(
    ['bunx', 'wrangler', 'dev', '--config', 'edge/wrangler.jsonc', '--port', String(PORT)],
    {
      cwd: new URL('../..', import.meta.url).pathname,
      stdout: 'pipe',
      stderr: 'pipe',
    },
  );

  try {
    await waitForHealth(30_000);
    await runAssertions();
    console.log('\nPOC PASSED: WASM + TypeScript/Hyperdrive persistence split works as designed.');
  } catch (err) {
    console.error('\nPOC FAILED:', err instanceof Error ? err.message : err);
    process.exitCode = 1;
  } finally {
    proc.kill();
    await proc.exited;
  }
}

await main();
