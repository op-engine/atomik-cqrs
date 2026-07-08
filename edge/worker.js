import wasmBytes from '../zig-out/wasm/atomik-cqrs-edge-harness.wasm';

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
  const { instance } = await WebAssembly.instantiate(wasmBytes, wasmImports);
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

export default {
  async fetch(req) {
    if (!exports_) await initWasm();

    const url = new URL(req.url);
    const method = req.method;
    const path = url.pathname;

    let bodyBytes = new Uint8Array(0);
    if (method !== 'GET' && method !== 'HEAD') {
      const raw = await req.arrayBuffer();
      if (raw.byteLength > MAX_BODY_BYTES) {
        return new Response(
          JSON.stringify({ error: 'request body too large' }),
          { status: 413, headers: { 'Content-Type': 'application/json' } },
        );
      }
      bodyBytes = new Uint8Array(raw);
    }

    const m = writeString(method);
    const p = writeString(path);
    const b = bodyBytes.length > 0 ? writeBytes(bodyBytes) : { ptr: 0, len: 0 };

    const responseLen = exports_.handle_request(
      m.ptr, m.len,
      p.ptr, p.len,
      b.ptr, b.len,
    );

    freeString(m.ptr, m.len);
    freeString(p.ptr, p.len);
    freeString(b.ptr, b.len);

    const outputPtr = exports_.get_output_ptr();
    const raw = decoder.decode(
      new Uint8Array(exports_.memory.buffer, outputPtr, responseLen),
    );

    let status = 200;
    let responseBody = raw;
    try {
      const envelope = JSON.parse(raw);
      status = envelope.status ?? 200;
      responseBody = typeof envelope.body === 'string'
        ? envelope.body
        : JSON.stringify(envelope.body);
    } catch (_) {}

    return new Response(responseBody, {
      status,
      headers: { 'Content-Type': 'application/json' },
    });
  },
};
