# Praxis Playground - Developer Guide

This is a **Docker Compose-based playground** for testing Praxis AI gateway rate-limiting features. It replaces a heavier Kubernetes setup with a simpler, faster development environment.

## Project Purpose

Validates Praxis token rate-limiting features against **M1-M7 acceptance criteria**:
- **M1**: Applicability (tiered budgets, exemptions, defaults)
- **M2**: Reserve→reconcile (reserve at admission, reconcile against actual usage)
- **M3**: Estimation (derive reserved amount from request body `max_tokens`)
- **M4**: Token-type weighting (cached_input discounted)
- **M5**: Multiple budgets (per-tier, per-model independence)
- **M6**: Denial semantics (HTTP 429 with `X-RateLimit-*` headers)
- **M7**: Observability (metrics, accounting logs)

## Architecture

**Single configurable gateway** with swappable runtime configs:
- **token-rate-limit.yaml** ✅ (default, M1-M7 verified, native filter)
- **ratelimit-limitador.yaml** ✅ (PPE plugin, embedded Limitador, M1+M5 verified, requires patches)

**Upstream services:**
- `inference-sim` (8000) - llm-d-inference-sim, returns real token usage
- `mock-llm` (1080) - MockServer with multi-provider LLM mocking
- `jwt-issuer` (8888) - Static JWKS server for RS256 JWT tokens

**No health checks** - Services start immediately (matches K8s setup)

## Build System

### Multi-Stage Dockerfile

**Stage 1**: Source fetcher
- Clones `praxis-proxy/ai` from GitHub (or uses local path)
- Controlled by `PRAXIS_AI_SOURCE` (git:main, git:v0.1.0, path:/workspace/ai)

**Stage 2**: Ratelimit patches (optional)
- When `APPLY_RATELIMIT_PATCHES=true`
- Vendors `praxis-proxy/policy` main + `praxis-proxy/praxis` v0.7.5
- Forward-ports core to policy 0.5.0 API
- Adds #1478 host wiring for `ratelimit.post_identity` hook
- **Implemented**: `build/praxis/apply-experimental-ratelimit-patches.sh` (ported from K8s 265-line script)

**Stage 3**: Builder
- Rust compilation with `PRAXIS_FEATURES`
- Common: `full,token-rate-limit-filter`
- Experimental: `full,experimental-ratelimit` (requires patches)

**Stage 4**: Runtime
- Debian bookworm-slim
- Binary + CA certs
- **Runs as root** (requires `allow_root: true` in config)

### Experimental-Ratelimit Build Process

When `APPLY_RATELIMIT_PATCHES=true`, the build:

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

### Source Specifications

**Format**: `<type>:<value>`
- `crate:0.7.5` - Published crate version
- `git:main` - GitHub branch/tag/commit
- `path:/workspace/ai` - Local checkout (dev mode)

## Configuration

### Config 1: token-rate-limit.yaml (Default)

**Filter chain**: 
```
router → model_to_header → token_rate_limit → token_count → access_log → load_balancer
```

**Key settings:**
- `allow_root: true` - Docker runs as root by default
- `allow_private_upstreams: true` - Cluster Service IPs are private
- `x-tier` header - Tier selection (gold/silver/enterprise/basic)
- `x-model` header - Promoted from request body by `model_to_header`

**Tiered budgets:**
- Enterprise: 1B tok/hr (bypass)
- Gold + gpt-4o: 20k tok/min (500 reserved)
- Gold + other: 12k tok/min
- Silver: 3k tok/min
- Default: 1M tok/min (max_tokens estimation, fallback=50)

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
- `APPLY_RATELIMIT_PATCHES=true` - Vendors policy main + core v0.7.5, adds #1478 wiring
- `PRAXIS_FEATURES=full,experimental-ratelimit`

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
- `post_chat <tier> [model] [max_tokens]` - Send chat completion with tier header
- `post_chat_code <tier> [model] [max_tokens]` - Just return HTTP code
- `hammer <tier> <count> [model]` - Burst N requests, return "200s 429s others"
- `get_metrics` / `get_metric <name>` - Scrape Prometheus metrics

**Important**: All functions add **`x-tier` header** automatically - config uses headers, not JWT claims for tier selection.

### Running Tests

```bash
make test           # Run tests for current config
make gateway        # Rebuild gateway
make deploy-gateway # Restart gateway
make logs           # Tail gateway logs
```

**Test scripts:**
- `test/test-token-rate-limit.sh` - M1-M7 validation for token-rate-limit.yaml
- `test/test-ratelimit-limitador.sh` - M1+M5 validation for ratelimit-limitador.yaml

**Test output**: Uses color codes (`log_info`, `log_success`, `log_error`) - functions that parse output send logs to stderr.

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
**Fix**: Ensure test functions send `x-tier` header (config keys on header, not JWT claim)

### Health checks fail
**Symptom**: Services stuck in "health: starting"  
**Fix**: Remove health checks - not needed, K8s setup doesn't use them

### No metrics visible
**Symptom**: `/metrics` returns 404 or empty  
**Fix**: Set `admin.metrics_address: "0.0.0.0:9901"` in config

## Development Workflow

### Switching Configurations

**Quick switch to experimental-ratelimit**:
```bash
cp .env.ratelimit-limitador .env
make gateway        # Build with patches
make deploy-gateway # Deploy
./test/test-ratelimit-limitador.sh
```

**Quick switch back to token-rate-limit (default)**:
```bash
cp .env.example .env
make gateway
make deploy-gateway
make test
```

### Changing Configuration

1. Edit config file: `config/praxis/token-rate-limit.yaml`
2. Restart gateway: `docker compose restart praxis-gateway`
3. Test: `make test`

### Changing Features

1. Edit `.env`: `PRAXIS_FEATURES=full,experimental-ratelimit`
2. Rebuild: `make gateway`
3. Restart: `make deploy-gateway`

### Testing with Different Sources

```bash
# Use local checkout
PRAXIS_AI_SOURCE=path:/workspace/praxis-ai make gateway

# Use specific commit
PRAXIS_AI_SOURCE=git:abc123 make gateway

# Use published crate
PRAXIS_CORE_SOURCE=crate:0.7.5 make gateway
```

### Debugging

```bash
# Gateway logs
docker compose logs praxis-gateway

# Accounting logs (token rate limit)
docker compose logs praxis-gateway | grep accounting

# Metrics
curl http://localhost:9901/metrics | grep praxis_trl

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
├── docker-compose.yml       # Services (no health checks)
├── .env.example             # Config template
├── Makefile                 # Targets: setup, gateway, deploy-gateway, test
├── build/praxis/
│   ├── Dockerfile           # Multi-stage build
│   └── apply-experimental-ratelimit-patches.sh
├── config/praxis/
│   └── token-rate-limit.yaml  # M1-M7 verified
├── jwt/
│   ├── generate.sh          # RS256 token generation
│   └── tokens/              # Generated JWTs (gitignored)
└── test/
    ├── lib.sh               # Test helpers
    ├── test-token-rate-limit.sh  # M1-M7 validation
    └── run-all.sh           # Test runner
```

## Key Differences from K8s Setup

**Simpler:**
- ✅ No kind cluster, kubectl, helm, Istio
- ✅ No port-forwarding (direct localhost access)
- ✅ Faster iteration (~30s rebuild vs 5min cluster setup)
- ✅ 4 containers vs 20+ pods

**Same capabilities:**
- ✅ All experimental features buildable
- ✅ Same upstream mocks
- ✅ Same JWT system
- ✅ Same acceptance tests (M1-M7)

**Removed:**
- ❌ Standalone Limitador (only embedded, via ratelimit plugin)
- ❌ Quota plugin (only ratelimit plugin supported)
- ❌ Kuadrant TokenRateLimitPolicy comparison
- ❌ Health checks (not needed)

## Docker Compose v2

**This project uses `docker compose` (v2 syntax)**, not `docker-compose` (v1).

All Makefile targets and documentation use the v2 command.

## TODO

- [ ] Create `rate-limit.yaml` (simple request-count) - **SKIPPED** (not needed, token-rate-limit + ratelimit-limitador cover use cases)
- [x] Create `ratelimit-limitador.yaml` + `ratelimit-policy.yaml` - **DONE**
- [x] Port full ratelimit patches (265-line script) - **DONE** (see `build/praxis/apply-experimental-ratelimit-patches.sh`)
- [x] Add test scripts for other configs - **DONE** (`test/test-ratelimit-limitador.sh`)
- [ ] Document MockServer expectations format
- [ ] Test full build with `APPLY_RATELIMIT_PATCHES=true`
