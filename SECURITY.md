# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes       |

## Reporting a Vulnerability

Atomik CQRS is used in financial systems. Please treat security issues seriously and report them privately.

**Do not open a public GitHub issue for security vulnerabilities.**

Use GitHub's private vulnerability reporting:
1. Go to the [Security tab](https://github.com/op-engine/atomik-cqrs/security) of this repository.
2. Click **"Report a vulnerability"**.
3. Fill in the details: what you found, how to reproduce it, and what you think the impact is.

You'll receive a response within 72 hours. We'll work with you on a fix and coordinate a disclosure timeline before anything is made public.

## Scope

Reports are welcome for issues in the Atomik CQRS library itself, including:
- Concurrency bugs that could cause silent data corruption or event loss
- Idempotency key bypass vulnerabilities
- Memory safety issues that could be exploited across tenant boundaries

Out of scope:
- Vulnerabilities in dependencies you've added to your own application
- Issues that require physical access to the host
- Denial-of-service via crafted inputs that slow the service; report these as regular issues

**Known structural bound (not a vulnerability):** The `wasm32-freestanding` edge harness allocates a 256 KB fixed buffer per request. A request whose allocations exceed that limit causes `@trap()`; the Worker process terminates rather than returning an error. This is a documented consequence of the freestanding target having no OS allocator (see ADR-08). Production deployments with large event payloads should tune the buffer size or target a native runtime. Do not report this as a DoS vulnerability; it is a deployment sizing concern.

## Tenant Isolation Model

The library enforces **structural** tenant isolation: every read and write operation requires a `tenant_id` parameter, and all SQL queries include `WHERE tenant_id = $1`. A correctly written query cannot read another tenant's data.

**The library cannot verify that the caller is authorized to use a given `tenant_id`.** That trust boundary belongs to the consuming application; typically an authenticated session that resolves to a tenant identifier. If a caller passes a different tenant's UUID (e.g., extracted from a user-supplied request field without verification), the library will faithfully serve that tenant's data.

Treat `tenant_id` as a bearer credential: it must come from a verified authentication context, not directly from user-supplied request input.

## Database Connection String in Memory

The PostgreSQL connection pool holds the database connection string in process memory for the pool's lifetime (standard behavior for all connection pool implementations). The string is zeroed on `pool.deinit()`. Passwords are redacted from all log output. Protecting process memory from inspection is the responsibility of the hosting environment.
