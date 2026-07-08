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
3. Fill in the details — what you found, how to reproduce it, and what you think the impact is.

You'll receive a response within 72 hours. We'll work with you on a fix and coordinate a disclosure timeline before anything is made public.

## Scope

Reports are welcome for issues in the Atomik CQRS library itself, including:
- Concurrency bugs that could cause silent data corruption or event loss
- Idempotency key bypass vulnerabilities
- Memory safety issues that could be exploited across tenant boundaries

Out of scope:
- Vulnerabilities in dependencies you've added to your own application
- Issues that require physical access to the host
- Denial-of-service via crafted inputs (please report these as regular issues)
