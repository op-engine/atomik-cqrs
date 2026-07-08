# Contributing to Atomik CQRS

Contributions are genuinely welcome; thank you for taking the time. This guide covers how to get involved in a way that's smooth for everyone.

## Start With a Conversation

Before writing code, open an issue. Atomik has a deliberate scope (a portable, edge-native event sourcing runtime) and a quick discussion helps make sure your effort lands somewhere useful. We try to respond promptly and are happy to help you find the right shape for a contribution.

For bug reports, the more context the better:
- Zig version (`zig version`)
- OS and target architecture
- A minimal reproduction; a failing test is ideal, but a clear description works too

## Getting Set Up

```sh
# Requires Zig 0.16.0 or later
zig build test
zig fmt --check src/
```

Tests should pass before and after your change. If something's broken in `main` when you start, open an issue and we'll sort it out.

## What We're Looking For

**Great fits:**
- Bug fixes with a regression test
- New storage adapters (follow the interface in `src/event_store.zig`)
- Performance improvements with benchmarks
- Documentation improvements and corrections

**Outside the current scope:**
- HTTP framework integrations (Atomik is intentionally framework-agnostic; bring your own)
- Built-in projection workers
- Global consistency guarantees across aggregates
- Non-Zig language bindings

Not sure if your idea fits? Open an issue and ask. We'd rather have the conversation than have you spend time on something we can't merge.

## Code Style

- Run `zig fmt` before committing; CI checks this.
- Comments should explain *why*, not *what*. Well-named identifiers carry the what.
- Return errors from library code; don't `std.debug.panic`.
- All allocations should be paired with a `defer deinit()`, or be explicitly caller-owned and documented as such.

## Submitting a Pull Request

1. Fork the repo and create a branch from `main`.
2. Keep PRs focused; one change per PR makes review faster and easier.
3. Include or update tests for any behavior change.
4. Use a descriptive title that completes the sentence "This PR ___." (e.g., "adds SQLite adapter", "fixes version conflict on concurrent append").

We'll do our best to review promptly and give constructive feedback. If a PR needs changes, it doesn't mean it's unwelcome; it usually just needs a bit of back and forth.

## Intellectual Property

Atomik CQRS implements a novel approach to optimistic concurrency control. By submitting a contribution, you're agreeing that your changes are licensed under [Apache 2.0](LICENSE) and that you have the right to make that grant. The patent grant in Section 3 of Apache 2.0 applies to all contributions; this is intentional and protects everyone.

If your employer might own IP relevant to your contribution, it's worth getting their sign-off before submitting. When in doubt, check with them first.

## Questions and Discussion

Use [GitHub Discussions](https://github.com/op-engine/atomik-cqrs/discussions) for design questions, ideas, or anything open-ended. Reserve Issues for bugs and concrete feature proposals. We read everything.
