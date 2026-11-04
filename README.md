# Praxis Playground

A Docker Compose environment for building and testing **Praxis AI gateway** with configurable features and rate-limiting strategies.

## Overview

This playground lets you:
- **Build Praxis from source** with experimental features enabled
- **Configure layer sources** (praxis-proxy/ai, praxis, policy) by version, commit, or local path
- **Test rate-limiting strategies**: token-based, request-count, PPE plugins
- **Validate M1-M7 acceptance criteria** for token rate limiting

### What's Here

- **Single configurable gateway**: One Praxis AI build, multiple runtime configurations
- **Upstream mocks**: llm-d-inference-sim + MockServer (multi-provider LLM mocking)
- **JWT test issuer**: Static RS256 tokens for tier-based testing
- **Acceptance tests**: M1-M7 validation for token rate limiting features

## Quick Start

```bash
# 1. Full setup (generates tokens, builds, starts gateway)
make setup

# 2. Wait for gateway to be healthy (~2-5 min for first build)
# Check: curl http://localhost:9901/healthy

# 3. Send a test request
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mock","messages":[{"role":"user","content":"test"}]}'

# 4. Run acceptance tests
make test
```

**Defaults**: Token rate limiting, builds from `git:main`, features `full,token-rate-limit-filter`

**Requirements**: Docker Compose v2 (`docker compose`, not `docker-compose`)

## Architecture

```
┌─────────────────┐
│ Praxis Gateway  │  :8080 (data), :9901 (metrics)
│  Configurable   │  
└────────┬────────┘
         │
    ┌────┴────┬───────────┬──────────────┐
    │         │           │              │
┌───▼───┐ ┌──▼───┐ ┌─────▼──────┐
│ mock  │ │ inf  │ │ jwt-issuer │
│ -llm  │ │ -sim │ │  (nginx)   │
└───────┘ └──────┘ └────────────┘
  :1080     :8000       :8888
  Multi-    OpenAI      JWKS
  provider  echo
```

### Services

| Service | Port | Purpose |
|---------|------|---------|
| `praxis-gateway` | 8080, 9901 | Configurable AI gateway (data + metrics) |
| `mock-llm` | 1080 | MockServer (OpenAI, Anthropic, Gemini mocking) |
| `inference-sim` | 8000 | llm-d-inference-sim (real token usage) |
| `jwt-issuer` | 8888 | Static JWKS server |

## Building the Gateway

### Build Configuration

Configure via `.env` file or environment variables:

```bash
# Features to enable
PRAXIS_FEATURES=full,token-rate-limit-filter

# Layer sources (crate:VERSION | git:REF | path:PATH)
PRAXIS_AI_SOURCE=git:main
PRAXIS_CORE_SOURCE=crate:0.7.5
PRAXIS_POLICY_SOURCE=crate:0.4.1

# Apply experimental overlays/patches
APPLY_RATELIMIT_PATCHES=false      # experimental-ratelimit
```

### Source Specifications

**Crate version** (published crate):
```bash
PRAXIS_CORE_SOURCE=crate:0.7.5
```

**Git reference** (branch, tag, or commit):
```bash
PRAXIS_AI_SOURCE=git:main
PRAXIS_AI_SOURCE=git:v0.1.0
PRAXIS_AI_SOURCE=git:abc123
```

**Local path** (for development):
```bash
PRAXIS_AI_SOURCE=path:/workspace/praxis-ai
# Requires bind-mount in docker-compose.yml
```

### Feature Flags

| Feature | Description | When to use |
|---------|-------------|-------------|
| `full` | Base Praxis AI features | Always |
| `token-rate-limit-filter` | Native token rate limiting | Token-based rate limiting |
| `experimental-ratelimit` | PPE ratelimit/embedded Limitador plugin | Request-count with embedded Limitador |

### Build Commands

```bash
# Build gateway with current configuration
make gateway

# Deploy (restart) gateway
make deploy-gateway

# Full workflow (first time or after config changes)
make setup  # jwt-tokens → gateway → deploy-gateway
```

### Building with Experimental-Ratelimit

To enable the `experimental-ratelimit` feature (PPE ratelimit plugin with embedded Limitador):

```bash
# Use the pre-configured .env file
cp .env.ratelimit-limitador .env

# Build (5-10 min for vendoring + patching)
make gateway

# Deploy
make deploy-gateway

# Test
./test/test-ratelimit-limitador.sh
```

**Alternative - Manual configuration**:
```bash
# Edit .env and set:
PRAXIS_FEATURES=full,experimental-ratelimit
PRAXIS_CONFIG=ratelimit-limitador.yaml
PRAXIS_POLICY_CONFIG=ratelimit-policy.yaml
APPLY_RATELIMIT_PATCHES=true

# Then build
make gateway
```

**What happens**: The build vendors `praxis-proxy/policy` main and `praxis-proxy/praxis` v0.7.5, patches core to work with the 0.5.0 policy API, and adds #1478 host wiring for `ratelimit.post_identity`. Adds ~5-10 minutes to build time (vendoring + patching).

## Runtime Configurations

The gateway uses the same build; only the **config file** changes:

| Config | Filter Chain | Description | Status |
|--------|--------------|-------------|--------|
| `token-rate-limit.yaml` | router → model_to_header → **token_rate_limit** → token_count → lb | Native token RL, reserve→reconcile, weighted tokens (M1-M7 ✅) | **✅ Ready** |
| `ratelimit-limitador.yaml` | **policy** → router → lb | PPE ratelimit plugin, embedded Limitador (request-count, M1+M5 ✅) | **✅ Ready** (needs patches) |

### Switching Configurations

**Method 1: Environment variable**
```bash
PRAXIS_CONFIG=ratelimit-limitador.yaml make gateway deploy-gateway
```

**Method 2: Edit `.env` file** (recommended)
```bash
# Edit .env to change PRAXIS_CONFIG
vim .env

# Rebuild and restart
make gateway deploy-gateway
```

**Method 3: One-liner with all settings**
```bash
PRAXIS_CONFIG=token-rate-limit.yaml \
PRAXIS_FEATURES=full,token-rate-limit-filter \
PRAXIS_AI_SOURCE=git:main \
  make gateway deploy-gateway
```

## Rate Limiting Configurations

### Token Rate Limiting (Default)

**File**: `config/praxis/token-rate-limit.yaml`

**Features**:
- Reserve→reconcile (M2): Reserve tokens at admission, reconcile against actual usage
- Estimation (M3): Derive reserved amount from request body `max_tokens`
- Weighted tokens (M4): `cached_input: 0.1`, `cache_write: 1.25`, `reasoning: 0.9`
- Multi-dimensional keys (M5): `(model, tier)` → independent budgets
- Tiered budgets (M1):
  - **Enterprise**: 1B tokens/hr (bypass, unlimited)
  - **Gold + gpt-4o**: 20k tokens/min (premium, 500 reserved)
  - **Gold + other**: 12k tokens/min (gold-basic)
  - **Silver**: 3k tokens/min
  - **Default**: 1M tokens/min (max_tokens estimation, fallback=50)

**Denial**: HTTP 429 with `X-RateLimit-*-Tokens` headers (M6)

**Observability**: `praxis_trl_*` metrics + accounting logs (M7)

### Request-Count Rate Limiting

**File**: `config/praxis/rate-limit.yaml` *(TODO)*

**Features**:
- Simple request-count limiting
- No token awareness
- Example: 1 req/s, burst 5

**Status**: Not yet created (straightforward to add - no patches needed)

### Ratelimit Plugin (Embedded Limitador)

**Files**: `config/praxis/ratelimit-limitador.yaml` + `ratelimit-policy.yaml`

**Features**:
- PPE `ratelimit/limitador` plugin
- **Embedded** in-memory Limitador (no external service)
- Request-count budgets keyed on JWT `tier` claim
- Runs at `ratelimit.post_identity` hook
- Enterprise exemption via limit conditions
- Per-tier budgets: gold (5 req/60s), silver (2 req/60s), basic (3 req/60s)
- Over-budget: HTTP 429

**Build**: Requires `APPLY_RATELIMIT_PATCHES=true` + `PRAXIS_FEATURES=full,experimental-ratelimit`. The 265-line vendoring/patching script from K8s has been ported.

**Test**: `./test/test-ratelimit-limitador.sh` - validates M1 (exemption) + M5 (independent per-tier counters)

**Note**: This playground intentionally **excludes** standalone Limitador and the quota plugin (simpler than K8s setup).


## JWT Tokens

### Available Tokens

| Token | Subject | Tier | Budget |
|-------|---------|------|--------|
| `gold.jwt` | `user-gold` | `gold` | Premium (20k tok/min for gpt-4o, 12k for others) |
| `silver.jwt` | `user-silver` | `silver` | Mid (3k tok/min) |
| `enterprise.jwt` | `user-enterprise` | `enterprise` | Unlimited (exempt) |
| `basic.jwt` | `user-basic` | `basic` | Default (1M tok/min, effectively unlimited) |
| `notier.jwt` | `user-notier` | *(absent)* | Default (tests missing claim) |

### Generate Tokens

```bash
make jwt-tokens
# Or directly:
./jwt/generate.sh
```

### Use Tokens in Requests

```bash
TOKEN=$(cat jwt/tokens/gold.jwt)

curl http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o",
    "messages": [{"role": "user", "content": "test"}],
    "max_tokens": 100
  }'
```

## Testing

### Token Rate Limiting (M1-M7)

```bash
# Start gateway (if not already running)
make setup

# Run comprehensive tests
make test
```

**Tests**:
- **M1**: Tiered budgets (gold/silver/enterprise/basic/notier)
- **M2**: Reserve→reconcile (metrics validation)
- **M3**: Estimation (max_tokens → reserved amount)
- **M4**: Weighted tokens (cached_input discounted)
- **M5**: Multiple budgets (per-tier, per-model independence)
- **M6**: Denial semantics (HTTP 429 + `X-RateLimit-*` headers)
- **M7**: Observability (metrics + logs)

### Manual Testing

```bash
# Check gateway health
curl http://localhost:9901/healthy

# Send test request (no auth, default tier)
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mock","messages":[{"role":"user","content":"test"}]}' | jq

# Scrape metrics
curl -s http://localhost:9901/metrics | grep praxis_trl

# Check logs
docker compose logs praxis-gateway | grep accounting
```

## Upstream Services

### MockServer

**Port**: 1080

**Expectations**: `config/mockserver/expectations.json`

**Mocked models**:
- **gpt-4o**: 3500 total tokens (3000 prompt, 500 completion, 2000 cached)
- **gpt-4o-mini**: 70 total tokens
- **mock**: 20 total tokens (default)
- **Anthropic**: 18 total tokens (10 input, 8 output)
- **Gemini**: 18 total tokens

### Inference Sim

**Port**: 8000

**Purpose**: OpenAI-compatible echo backend with **real token usage** (not mocked)

**Endpoints**:
- `GET /v1/models`
- `POST /v1/chat/completions`

**Usage**: Returns `usage.total_tokens` in response (~20 tokens for test prompts)

## Troubleshooting

### Build Failures

**Rust compile error**:
- Check `PRAXIS_FEATURES` match the source version
- Try `PRAXIS_AI_SOURCE=git:main` (latest)

**Experimental feature not found**:
- For `experimental-ratelimit`: Set `APPLY_RATELIMIT_PATCHES=true` to enable vendoring/patching (see `build/praxis/apply-experimental-ratelimit-patches.sh`)

### Runtime Issues

**502 Bad Gateway**:
- Check upstreams are healthy: `docker compose ps`
- Verify `allow_private_upstreams: true` in config
- Check logs: `docker compose logs praxis-gateway`

**No rate limiting (all 200s)**:
- Check config is mounted: `docker exec praxis-playground-praxis-gateway-1 cat /etc/praxis/praxis-ai.yaml`
- Verify tier header/JWT: `curl -v ... | grep x-tier`
- Check metrics: `curl localhost:9901/metrics | grep praxis_trl`

**Metrics missing**:
- Verify `admin.metrics_address: "0.0.0.0:9901"` in config
- Check `/metrics` endpoint: `curl localhost:9901/metrics`

**JWT verification fails**:
- Regenerate tokens: `rm -rf jwt/private.pem jwt/tokens && make jwt-tokens`
- Restart jwt-issuer: `docker compose restart jwt-issuer`
- Check JWKS: `curl localhost:8888/jwks.json | jq`

## Advanced Usage

### Local Source Development

1. Clone Praxis AI locally:
   ```bash
   git clone https://github.com/praxis-proxy/ai.git /workspace/praxis-ai
   ```

2. Edit `docker-compose.yml` to bind-mount:
   ```yaml
   praxis-gateway:
     build:
       args:
         PRAXIS_AI_SOURCE: path:/workspace/praxis-ai
     volumes:
       - /workspace/praxis-ai:/workspace/praxis-ai:ro
   ```

3. Edit source, rebuild:
   ```bash
   make build
   ```

### Custom Configuration

1. Create new config:
   ```bash
   cp config/praxis/token-rate-limit.yaml config/praxis/my-custom.yaml
   # Edit budgets, rules, etc.
   ```

2. Run with custom config:
   ```bash
   PRAXIS_CONFIG=my-custom.yaml make build up
   ```

### Multi-Tier Budgets

Edit `config/praxis/token-rate-limit.yaml`:

```yaml
rules:
  - name: platinum
    match:
      headers:
        x-tier: platinum
    algorithm: sliding_window
    window: 1m
    capacity: 50000        # 50k tokens/min
    reserved_tokens: 1000  # Reserve 1k at admission
```

## Repository Structure

```
praxis-playground/
├── docker-compose.yml          # Service definitions
├── .env.example                # Configuration template (default: token-rate-limit)
├── .env.ratelimit-limitador    # Pre-configured for experimental-ratelimit feature
├── Makefile                    # Convenience targets
├── README.md                   # This file
├── build/
│   ├── praxis/
│   │   ├── Dockerfile          # Multi-stage configurable build
│   │   └── apply-experimental-ratelimit-patches.sh # Patches for experimental-ratelimit (✓ ported)
│   └── jwt-issuer/
│       ├── Dockerfile          # Nginx serving JWKS
│       └── nginx.conf
├── config/
│   ├── praxis/
│   │   ├── token-rate-limit.yaml       # Token RL (default, M1-M7 ✅)
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
    ├── test-token-rate-limit.sh        # Token RL M1-M7 tests
    └── test-ratelimit-limitador.sh     # Ratelimit plugin M1+M5 tests
```

## Makefile Targets

```
make help            # Show all targets
make setup           # Full setup (jwt-tokens + gateway + deploy-gateway)
make jwt-tokens      # Generate JWT tokens and JWKS
make gateway         # Build gateway with current configuration
make deploy-gateway  # Stop and start gateway (restart)
make up              # Start all services
make down            # Stop all services
make logs            # Tail gateway logs
make clean           # Stop and remove all (including volumes)
make test            # Run tests for current configuration
```

## Related Resources

- **Praxis AI**: <https://github.com/praxis-proxy/ai>
- **Praxis Core**: <https://github.com/praxis-proxy/praxis>
- **Praxis Policy**: <https://github.com/praxis-proxy/policy>
- **llm-d-inference-sim**: <https://github.com/llm-d/llm-d-inference-sim>
- **MockServer**: <https://www.mock-server.com/>

## License

This playground is for testing purposes. See individual component repositories for their licenses.
