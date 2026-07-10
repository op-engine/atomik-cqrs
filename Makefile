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
        edge-install edge-dev edge-test-unit edge-test-integration edge-poc edge-deploy edge-deploy-prd \
        seed-adhoc seed-prd \
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
# EDGE / POC (ADR-003 Option D — see docs/adr/decisions.md, ADR-11)
# ============================================================================
#
# Two Hyperdrive configs, mirrored in edge/wrangler.jsonc's default env (adhoc) and
# env.production (prd). Both get repointed at deploy time rather than treated as fixed:
# adhoc is deliberately throwaway (a fresh neon-new branch every deploy), prd tracks
# NEON_DB_KEY (betty root .env) so a credential rotation there doesn't require a manual step
# here. Local `wrangler dev`/the POC script ignore both IDs entirely and use
# CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE instead.
ADHOC_HYPERDRIVE_ID := 45302acea9ae496a8fd2361be219d94c
PRD_HYPERDRIVE_ID := 556c641f4f8443649fd8f99e15f69b7c

edge-install: ## Install edge/ JS dependencies (bun install, submodule root)
	bun install

edge-dev: edge-install wasm ## Run the edge Worker locally via wrangler dev
	@test -f .env.local || { echo "Run 'make db-provision' first."; exit 1; }
	CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE="$$(grep ATOMIK_DATABASE_URL .env.local | cut -d= -f2-)" \
		bunx wrangler dev --config edge/wrangler.jsonc

edge-test-unit: edge-install ## Hermetic TS unit tests (mocked Postgres + mocked WASM, no network)
	bun test edge/persistence.test.ts edge/worker.test.ts

edge-test-integration: edge-install db-provision ## TS persistence tests against a real (ephemeral Neon) Postgres
	bun test --env-file=.env.local edge/persistence.integration.test.ts

edge-poc: edge-install wasm ## Run the full end-to-end POC (spawns wrangler dev, runs script, reports pass/fail)
	@test -f .env.local || { echo "Run 'make db-provision' first."; exit 1; }
	CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE="$$(grep ATOMIK_DATABASE_URL .env.local | cut -d= -f2-)" \
		bun run edge/poc/run.ts

edge-deploy: edge-install wasm db-provision ## Deploy edge Worker to adhoc, repointing Hyperdrive at a fresh neon-new branch
	bunx wrangler hyperdrive update $(ADHOC_HYPERDRIVE_ID) --connection-string="$$(grep ATOMIK_DATABASE_URL .env.local | cut -d= -f2-)"
	bunx wrangler deploy --config edge/wrangler.jsonc

edge-deploy-prd: edge-install wasm ## Deploy edge Worker to production, repointing Hyperdrive at NEON_DB_KEY
	@test -f ../../.env || { echo "No .env at betty root — NEON_DB_KEY not found."; exit 1; }
	bunx wrangler hyperdrive update $(PRD_HYPERDRIVE_ID) --connection-string="$$(grep NEON_DB_KEY ../../.env | cut -d= -f2-)"
	bunx wrangler deploy --config edge/wrangler.jsonc --env production

seed-adhoc: ## Apply illustrative seed events (packages/schema-etl) to the adhoc database
	@test -f .env.local || { echo "Run 'make db-provision' first."; exit 1; }
	cd ../schema-etl && bun install && bun run seed -- \
		--database-url="$$(grep ATOMIK_DATABASE_URL ../atomik-cqrs/.env.local | cut -d= -f2-)" \
		--file=seeds/atomik-cqrs/events.yaml

seed-prd: ## Apply illustrative seed events (packages/schema-etl) to the production database
	@test -f ../../.env || { echo "No .env at betty root — NEON_DB_KEY not found."; exit 1; }
	cd ../schema-etl && bun install && bun run seed -- \
		--database-url="$$(grep NEON_DB_KEY ../../.env | cut -d= -f2- | sed -E 's/(ep-[a-z0-9-]+)-pooler/\1/')" \
		--file=seeds/atomik-cqrs/events.yaml

# ============================================================================
# CLEAN
# ============================================================================

clean: ## Remove Zig build artifacts (zig-out, .zig-cache)
	rm -rf zig-out .zig-cache

clean-all: clean ## Remove all generated artifacts including node_modules
	rm -rf integration/node_modules node_modules

# ============================================================================
# CI
# ============================================================================

ci: fmt-check build-all test ## Hermetic CI gate — mirrors .github/workflows/ci.yml exactly
	@echo "CI gate passed."

ci-full: ci test-integration ## Full CI gate: hermetic checks + live Postgres integration tests

release: fmt-check test-all build-release ## Full release gate: all tests + release builds
	@echo "Release gate passed."
