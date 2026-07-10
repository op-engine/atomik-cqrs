import wasmBytes from '../zig-out/wasm/atomik-cqrs-edge-harness.wasm';
import { createStore } from './persistence.ts';
import { createRoutes } from './routes.ts';

let exports_ = null;

// Provided to the WASM module as `env.fill_random_bytes`. Called by
// `cqrs.generate_uuid()`; writes `len` cryptographically secure random bytes
// into WASM linear memory at `ptr` using the Workers Web Crypto API.
const wasmImports = {
  env: {
    fill_random_bytes: (ptr, len) => {
      crypto.getRandomValues(new Uint8Array(exports_.memory.buffer, ptr, len));
    },
  },
};

async function initWasm() {
  // Wrangler's `.wasm` import gives an already-compiled WebAssembly.Module (not raw bytes), so
  // WebAssembly.instantiate resolves directly to the Instance here — not the {module, instance}
  // shape you'd get by instantiating a BufferSource.
  const instance = await WebAssembly.instantiate(wasmBytes, wasmImports);
  exports_ = instance.exports;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function writeBytes(bytes) {
  const ptr = exports_.alloc(bytes.length);
  new Uint8Array(exports_.memory.buffer).set(bytes, ptr);
  return { ptr, len: bytes.length };
}

function writeString(str) {
  return writeBytes(encoder.encode(str));
}

function freeString(ptr, len) {
  if (len > 0) exports_.dealloc(ptr, len);
}

// The WASM module runs on a 256 KB fixed-buffer allocator. Reject bodies that
// would exhaust it before they reach WASM memory.
const MAX_BODY_BYTES = 64 * 1024;

// Low-level WASM FFI call: instantiate on first use, marshal method/path/body across the linear
// memory boundary, return the already-parsed {status, body} envelope. This is the one piece of
// real WASM plumbing in the file — routes.ts takes it as an injected dependency so route logic
// can be unit-tested against a fake instead (see worker.test.ts).
async function callWasm(method, path, bodyText) {
  if (!exports_) await initWasm();

  const bodyBytes = bodyText ? encoder.encode(bodyText) : new Uint8Array(0);
  if (bodyBytes.length > MAX_BODY_BYTES) {
    return { status: 413, body: { error: 'request body too large' } };
  }

  const m = writeString(method);
  const p = writeString(path);
  const b = bodyBytes.length > 0 ? writeBytes(bodyBytes) : { ptr: 0, len: 0 };

  const responseLen = exports_.handle_request(m.ptr, m.len, p.ptr, p.len, b.ptr, b.len);

  freeString(m.ptr, m.len);
  freeString(p.ptr, p.len);
  freeString(b.ptr, b.len);

  const outputPtr = exports_.get_output_ptr();
  const raw = decoder.decode(new Uint8Array(exports_.memory.buffer, outputPtr, responseLen));

  const envelope = JSON.parse(raw);
  return { status: envelope.status, body: envelope.body };
}

// Deliberately NOT cached at module scope like `exports_` above: a postgres.js client holds an
// open socket, and Cloudflare Workers forbids reusing I/O objects (sockets/streams) created in
// one request's context from a different request's context ("Cannot perform I/O on behalf of a
// different request" — confirmed by actually hitting this against a live wrangler dev). A fresh
// client per request, pointed at env.HYPERDRIVE.connectionString, is both the workaround for that
// constraint and exactly the pattern Hyperdrive itself expects — it owns the actual pooling.
// `env.HYPERDRIVE.connectionString` also works transparently under local `wrangler dev`, backed
// by CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE (set by the Makefile from
// .env.local) — no separate local/prod code path needed here.
function getStore(env) {
  return createStore(env.HYPERDRIVE.connectionString);
}

function jsonResponse(result) {
  return new Response(JSON.stringify(result.body), {
    status: result.status,
    headers: { 'Content-Type': 'application/json' },
  });
}

async function route(req, routes, url) {
  if (req.method === 'GET' && url.pathname === '/health') {
    return routes.health();
  }

  const createMatch = url.pathname.match(/^\/aggregates\/([^/]+)\/commands$/);
  if (req.method === 'POST' && createMatch) {
    const body = await req.json();
    return routes.createEvent({
      tenantId: body.tenant_id,
      userId: body.user_id,
      aggregateId: createMatch[1],
      aggregateType: body.aggregate_type,
      eventType: body.event_type,
      data: body.data,
    });
  }

  const replayMatch = url.pathname.match(/^\/aggregates\/([^/]+)\/state$/);
  if (req.method === 'GET' && replayMatch) {
    const tenantId = url.searchParams.get('tenant_id');
    const aggregateType = url.searchParams.get('aggregate_type');
    return routes.replayAggregate({ tenantId, aggregateId: replayMatch[1], aggregateType });
  }

  return { status: 404, body: { error: 'not found' } };
}

export default {
  async fetch(req, env, ctx) {
    const store = getStore(env);
    const routes = createRoutes({ callWasm, store });

    // Resolve the actual response first, THEN schedule cleanup — store.end() must not run
    // until every query this request issues has actually been submitted, or it can close the
    // connection before routes.* even gets to use it.
    const result = await route(req, routes, new URL(req.url));
    ctx.waitUntil(store.end());
    return jsonResponse(result);
  },
};
