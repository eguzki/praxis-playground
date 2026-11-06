# Praxis Playground - Developer Guide

A **Docker Compose-based playground** for building and testing the Praxis AI gateway's rate-limiting features.

## Project Purpose

Playground for building and running the Praxis AI gateway in two forms (released
image vs. source-compiled `experimental-ratelimit`) and exercising the experimental
request-count rate limiting plugin.

> **Note**: token-based rate limiting (`token_rate_limit`, the M1-M7 criteria) is
> **not available in any build here** — the filter is gated behind the
> `token-rate-limit-filter` cargo feature, which neither the released image nor the
> experimental build enables. The remaining acceptance coverage is M1 (exemption)
> + M5 (independent per-tier counters) via the ratelimit plugin.

## Architecture

**Two builds**, each with its own standalone build script (the single source of
truth for versions/features — there are no generic feature/source knobs):
- **Basic** — `./build/build-basic.sh` pulls the released prebuilt image
  (`ghcr.io/praxis-proxy/ai:0.9`, pinned in the script), runs `basic.yaml` (a
  minimal `router → access_log → load_balancer` proxy). No local compile.
  **The released image does NOT include `token_rate_limit` or `model_to_header`**
  (both gated behind the `token-rate-limit-filter` feature).
- **Experimental** — `./build/build-experimental.sh` compiles from source with
  only `experimental-ratelimit` (PPE plugin, embedded Limitador, M1+M5), runs
  `ratelimit-limitador.yaml` + `ratelimit-policy.yaml`. Vendors policy + core and
  applies patches (~5-10 min).

Each script produces a tagged image (`praxis-gateway:basic` /
`praxis-gateway:experimental`) and writes `.env` (`GATEWAY_IMAGE`, `PRAXIS_CONFIG`,
`PRAXIS_POLICY_CONFIG_PATH`). `docker-compose.yml` just runs `${GATEWAY_IMAGE}`
with `command: ["-c", "/etc/praxis/praxis-ai.yaml"]`.

**Upstream services:**
- `inference-sim` (8000) - llm-d-inference-sim, returns real token usage
- `mock-llm` (1080) - MockServer with multi-provider LLM mocking
- `jwt-issuer` (8888) - Static JWKS server for RS256 JWT tokens

**No health checks** defined in compose — services start immediately.

## Build System

### Basic build — `build/build-basic.sh`

- Pulls the released prebuilt image at a pinned tag (`AI_IMAGE`, default
  `ghcr.io/praxis-proxy/ai:0.9`), retags it `praxis-gateway:basic`. No compile.
- The released image runs as **non-root** (`praxis:praxis`) and ships
  `ENTRYPOINT=["praxis-ai"]` with **no default CMD** — compose supplies
  `command: ["-c", "/etc/praxis/praxis-ai.yaml"]`.
- Writes `.env` selecting `basic.yaml`.

### Experimental build — `build/build-experimental.sh`

- Runs `docker build ./build/praxis` with `PRAXIS_FEATURES=full,experimental-ratelimit`,
  `APPLY_RATELIMIT_PATCHES=true`, `PRAXIS_AI_SOURCE` (default `git:main`),
  tags `praxis-gateway:experimental`. Writes `.env` selecting
  `ratelimit-limitador.yaml` + `ratelimit-policy.yaml`.

The multi-stage Dockerfile (`build/praxis/Dockerfile`) is used only by the
experimental build:

**Stage 1 (source-fetcher)**: clones `praxis-proxy/ai` per `PRAXIS_AI_SOURCE`.
**Stage 2 (ratelimit-patches-prep)**: runs `apply-experimental-ratelimit-patches.sh`
(vendors policy main + core v0.7.5, forward-ports core to the 0.5.0 API, adds #1478
host wiring for `ratelimit.post_identity`).
**Stage 3 (builder)**: `cargo build --release --features="${PRAXIS_FEATURES}"`.
**Stage 4 (runtime)**: Debian bookworm-slim, binary + CA certs, **runs as root**
(config sets `allow_root: true`).

### Experimental-Ratelimit Build Process

The experimental build runs `apply-experimental-ratelimit-patches.sh`, which:

1. **Vendors praxis-policy main** (merged PR #178 with ratelimit plugin)
2. **Relabels 0.5.0 → 0.4.1** (satisfies core's ^0.4.1 dependency)
3. **Vendors praxis-core v0.7.5**
4. **Patches core's policy filter** (three changes):
   - **(A)** Import `Credential` + `HOOK_RATELIMIT_POST_IDENTITY`
   - **(B)** Compile fix: `source_header` → `Credential::Header`
   - **(C)** #1478 host wiring: invoke `ratelimit.post_identity` after identity resolution
5. **Overlays server/Cargo.toml**: adds `experimental-ratelimit` feature
6. **Overlays root Cargo.toml**: adds `[patch.crates-io]` redirects, sets `panic = "unwind"`

**Why needed**: The `ratelimit/limitador` plugin lives on policy engine 0.5.0 (merged to main), which has API changes incompatible with core v0.7.5. The patches forward-port core to work with 0.5.0 and add the minimal #1478 host integration (post-identity hook invocation).

### Source Specification (experimental build only)

`PRAXIS_AI_SOURCE` controls the `praxis-ai` ref the experimental build clones
(`git:main`, `git:<tag>`, `git:<commit>`). Core (v0.7.5) and policy (main) refs are
pinned inside the Dockerfile / patch script. The basic build has no source spec —
it pulls a prebuilt image by tag (`AI_IMAGE`).

## Configuration

### Config 1: basic.yaml (Basic build / default runtime)

**Filter chain**: `router → access_log → load_balancer`

Minimal proxy using only filters present in the released image. No rate limiting;
a tunable baseline. Used by `./build/build-basic.sh`.

### Config 2: ratelimit-limitador.yaml (Experimental)

**Filter chain**: 
```
policy → router → access_log → load_balancer
```

**Key settings:**
- `allow_root: true` - Docker runs as root by default
- `allow_private_upstreams: true` - Cluster Service IPs are private
- `allow_private_idp: true` - JWKS fetch from Docker service
- Policy document: `ratelimit-policy.yaml` (mounted at `/etc/praxis/policy.yaml`)

**Policy plugins:**
- **identity/jwt**: RS256 verification via JWKS at `http://jwt-issuer/jwks.json`
  - Exposes `tier` claim to ratelimit plugin
  - Unauthenticated requests: 401
- **ratelimit/limitador**: Embedded in-memory Limitador
  - Runs at `ratelimit.post_identity` hook (after JWT verification)
  - Request-count budgets (not token-based)
  - Keys on `tier` claim from JWT

**Per-tier budgets:**
- Gold: 5 req/60s
- Silver: 2 req/60s
- Basic: 3 req/60s (default/catch-all)
- Enterprise: exempt (no matching limit)

**Build requirements:**
- Built via `./build/build-experimental.sh` (sets `PRAXIS_FEATURES=full,experimental-ratelimit`
  and `APPLY_RATELIMIT_PATCHES=true`; vendors policy main + core v0.7.5, adds #1478 wiring)

**Caveats:**
- **Request-count only** (not token-denominated) - runs pre-body
- **Cannot key on request-body `model`** - only on tier/subject/headers
- Over-budget: HTTP 429 (no `X-RateLimit-*` headers by default)
- Missing `tier` claim: denied before counting (400/401)
- Counters: in-memory, per-replica, reset on restart

## Testing

### Test Library (`test/lib.sh`)

**Key helpers:**
- `get_token <tier>` - Load JWT from `jwt/tokens/<tier>.jwt`
- `post_chat <tier> [model] [max_tokens]` - Send chat completion with the tier's JWT
- `post_chat_code <tier> [model] [max_tokens]` - Just return HTTP code
- `hammer <tier> <count> [model]` - Burst N requests, return "200s 429s others"
- `get_metrics` / `get_metric <name>` - Scrape Prometheus metrics

**Tier selection**: the `ratelimit-limitador.yaml` config keys on the **JWT `tier`
claim** (resolved post-identity), not a request header. The helpers send the JWT
via `Authorization: Bearer`; they also set an `x-tier` header, which this config
ignores.

### Running Tests

`make test` dispatches on the active `PRAXIS_CONFIG`:
- `basic.yaml` → no tests (minimal proxy)
- `ratelimit-limitador.yaml` → `test/test-ratelimit-limitador.sh` (M1 + M5)

**Test output**: color codes (`log_info`, `log_success`, `log_error`); functions that parse output send logs to stderr.

## JWT System

**Static tokens** (not runtime issuance):
- Generated once via `make jwt-tokens` (or `./jwt/generate.sh`)
- RS256 algorithm, 10-year validity
- Issuer: `https://jwt-issuer.praxis.local`
- Audience: `praxis-playground`

**Claims**:
- `sub`: user-{tier}
- `tier`: gold/silver/enterprise/basic (absent in `notier.jwt`)

**JWKS endpoint**: `http://jwt-issuer/jwks.json` (served by nginx)

## Common Issues

### Gateway refuses to start
**Symptom**: "Praxis refuses to run as root (UID 0)"  
**Fix**: Add `allow_root: true` to config's `insecure_options`

### 502 Bad Gateway
**Symptom**: All requests fail with 502  
**Fix**: Add `allow_private_upstreams: true` to config (Docker network IPs are private)

### Tests return all "other" (not 200/429)
**Symptom**: `hammer()` shows `??????????`  
**Fix**: Gateway not reachable or tokens missing — check it's deployed (`docker compose ps`) and run `make jwt-tokens`.

### Ratelimit requests all 401 / denied
**Symptom**: Every request to the experimental build is rejected  
**Fix**: The JWT must carry a `tier` claim the policy keys on (`notier.jwt` is denied by design); verify JWKS is reachable at `http://jwt-issuer/jwks.json`.

### No metrics visible
**Symptom**: `/metrics` returns 404 or empty  
**Fix**: Set `admin.metrics_address: "0.0.0.0:9901"` in config

## Development Workflow

### Switching Between Builds

Re-run the other build script; it retags the image and rewrites `.env`, then redeploy:

```bash
# Switch to experimental-ratelimit
./build/build-experimental.sh   # or: make gateway-experimental
make deploy-gateway
./test/test-ratelimit-limitador.sh

# Switch back to basic (released image, minimal proxy)
./build/build-basic.sh          # or: make gateway-basic
make deploy-gateway
```

### Changing the runtime config (no rebuild)

The config is bind-mounted, so edits apply on restart:

1. Edit config file (e.g. `config/praxis/basic.yaml`)
2. Restart gateway: `docker compose restart praxis-gateway`
3. Test: `make test`

### Pinning different sources

- Basic: bump the tag — `AI_IMAGE=ghcr.io/praxis-proxy/ai:<tag> ./build/build-basic.sh`
- Experimental: pin the `praxis-ai` ref — `PRAXIS_AI_SOURCE=git:<ref> ./build/build-experimental.sh`
  (core/policy refs are pinned in the Dockerfile / patch script)

### Debugging

```bash
# Gateway logs
docker compose logs praxis-gateway

# Metrics
curl http://localhost:9901/metrics

# Test request with details
TOKEN=$(cat jwt/tokens/gold.jwt)
curl -v http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-tier: gold" \
  -H "Content-Type: application/json" \
  -d '{"model":"mock","messages":[{"role":"user","content":"test"}]}'
```

## File Structure

```
praxis-playground/
├── docker-compose.yml          # Service definitions (gateway runs ${GATEWAY_IMAGE})
├── .env.example                # Reference for the .env the build scripts generate
├── Makefile                    # Convenience targets
├── README.md                   # User-facing overview
├── build/
│   ├── build-basic.sh          # BASIC build: pull released image
│   ├── build-experimental.sh   # EXPERIMENTAL build: compile experimental-ratelimit
│   ├── praxis/
│   │   ├── Dockerfile          # Multi-stage build (used by build-experimental.sh)
│   │   └── apply-experimental-ratelimit-patches.sh # Patches for experimental-ratelimit (✓ ported)
│   └── jwt-issuer/
│       ├── Dockerfile          # Nginx serving JWKS
│       └── nginx.conf
├── config/
│   ├── praxis/
│   │   ├── basic.yaml                  # Basic build config (minimal proxy, released image)
│   │   ├── ratelimit-limitador.yaml    # Ratelimit plugin config (M1+M5 ✅)
│   │   └── ratelimit-policy.yaml       # Ratelimit policy doc
│   └── mockserver/
│       └── expectations.json           # LLM response mocking
├── jwt/
│   ├── generate.sh             # Token + JWKS generation
│   ├── README.md               # JWT documentation
│   └── .gitignore              # Ignore generated keys/tokens
└── test/
    ├── lib.sh                          # Shared test helpers
    ├── run-all.sh                      # Test runner (dispatches on PRAXIS_CONFIG)
    └── test-ratelimit-limitador.sh     # Ratelimit plugin M1+M5 tests
```

## Makefile Targets

```
make help                  # Show all targets
make setup                 # Full setup (jwt-tokens + basic gateway + deploy)
make jwt-tokens            # Generate JWT tokens and JWKS
make gateway-basic         # Build BASIC gateway (pull released image)
make gateway-experimental  # Build EXPERIMENTAL gateway (compile experimental-ratelimit)
make gateway               # Alias for gateway-basic
make deploy-gateway        # Stop and start gateway (restart)
make up                    # Start all services
make down                  # Stop all services
make logs                  # Tail gateway logs
make clean                 # Stop and remove all (including volumes)
make test                  # Run tests for current configuration
```

## Scope

Not included: token rate limiting (`token_rate_limit`, gated out of every build
here), standalone Limitador (only the embedded in-process Limitador via the
ratelimit plugin), and the quota plugin.

## Docker Compose v2

Uses `docker compose` (v2), not `docker-compose` (v1).

## TODO

- [ ] Document MockServer expectations format
- [ ] Verify the experimental build end-to-end (`./build/build-experimental.sh`)
