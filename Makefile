# Run `make help` to list all targets.
#
# On macOS, libpq is keg-only (Homebrew does not symlink it into default paths).
# The Makefile detects the prefix via `brew --prefix libpq` and passes it to
# `zig build` automatically. On Linux, libpq-dev lands in the standard search
# path and no flag is needed.
LIBPQ_PREFIX := $(shell brew --prefix libpq 2>/dev/null)
LIBPQ_FLAG   := $(if $(LIBPQ_PREFIX),-Dlibpq-prefix=$(LIBPQ_PREFIX))

# DATABASE SETUP
# Two paths for integration tests:
#
#   Fresh ephemeral DB (CI / first run):
#     make test-integration        — provisions a Neon DB, runs tests, done
#
#   Persistent local DB (faster iteration):
#     make db-provision            — provisions once, writes URL to .env.local
#     make test-integration-local  — reads .env.local, skips provisioning
#
# Set ATOMIK_DATABASE_URL in .env.local manually to use your own Postgres.
# See .env.local.example for supported formats.

.PHONY: help \
        build build-release build-all \
        test test-integration test-integration-local test-all \
        wasm \
        migrate \
        fmt fmt-check check \
        install db-provision \
        clean clean-all \
        ci ci-full \
        release

# ============================================================================
# HELP
# ============================================================================

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}' | sort

# ============================================================================
# BUILD
# ============================================================================

build: ## Debug build (fast; used during development)
	zig build

build-release: ## Build all targets in ReleaseSafe / ReleaseSmall mode
	zig build -Doptimize=ReleaseSafe
	zig build migrate -Doptimize=ReleaseSafe
	zig build wasm

build-all: ## Build every artifact in debug mode (library + WASM + migration tool)
	zig build
	zig build wasm
	zig build migrate

wasm: ## Compile the WASM edge harness (wasm32-freestanding, ReleaseSmall)
	zig build wasm

migrate: ## Build and run the migration tool against ATOMIK_DATABASE_URL
	zig build migrate
	./zig-out/bin/atomik-migrate

# ============================================================================
# TEST
# ============================================================================

test: ## Run unit tests (hermetic — no database or network required)
	zig build test --summary all

test-integration: install ## Provision a fresh Neon DB via neon-new and run integration tests
	cd integration && bun run run.ts

test-integration-local: ## Run integration tests against the DB in .env.local (no re-provision)
	@test -f .env.local || { \
		echo ""; \
		echo "  No .env.local found."; \
		echo "  Run 'make db-provision' to provision a Neon DB automatically,"; \
		echo "  or copy .env.local.example and fill in ATOMIK_DATABASE_URL."; \
		echo ""; \
		exit 1; \
	}
	sh -c 'set -a; . ./.env.local; set +a; zig build test-integration $(LIBPQ_FLAG) --summary all'

test-all: test test-integration ## Run unit tests then integration tests (provisions fresh Neon DB)

# ============================================================================
# CODE QUALITY
# ============================================================================

fmt: ## Format all Zig source in place
	zig fmt src/ edge/ build.zig

fmt-check: ## Check formatting without modifying files (CI gate)
	zig fmt --check src/ edge/ build.zig

check: fmt-check build ## Fast pre-commit check: format + debug build, no tests

# ============================================================================
# JS / BUN + DATABASE PROVISIONING
# ============================================================================

install: ## Install integration test JS dependencies (bun install in integration/)
	cd integration && bun install

db-provision: install ## Provision a Neon DB via neon-new and write URL to .env.local
	cd integration && bun run provision.ts

# ============================================================================
# CLEAN
# ============================================================================

clean: ## Remove Zig build artifacts (zig-out, .zig-cache)
	rm -rf zig-out .zig-cache

clean-all: clean ## Remove all generated artifacts including node_modules
	rm -rf integration/node_modules

# ============================================================================
# CI
# ============================================================================

ci: fmt-check build-all test ## Hermetic CI gate — mirrors .github/workflows/ci.yml exactly
	@echo "CI gate passed."

ci-full: ci test-integration ## Full CI gate: hermetic checks + live Postgres integration tests

release: fmt-check test-all build-release ## Full release gate: all tests + release builds
	@echo "Release gate passed."
