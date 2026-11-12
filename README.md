# Praxis Playground

A playground for building and testing the **Praxis AI gateway**. Supporting
services run in Docker Compose; the gateway runs either as a released image in
compose (**basic** build) or as a **host-compiled binary** (**experimental**
build with `experimental-ratelimit`).

## Overview

This playground lets you:

- **Run the released gateway** (basic build, in compose) or **compile and run the
  experimental one on the host** (`experimental-ratelimit`)
- **Test the experimental request-count rate limiting** (PPE `ratelimit/limitador` plugin)

### What's Here

- **Two builds**: a basic (released prebuilt image, run in compose) and an
  experimental (host-compiled `experimental-ratelimit` binary, run on the host)
- **Upstream mocks**: llm-d-inference-sim + MockServer (multi-provider LLM mocking)
- **JWT test issuer**: Static RS256 tokens for tier-based testing
- **Acceptance tests**: M1 + M5 validation for the experimental ratelimit plugin

## Quick Start

```bash
# 1. Full setup (generates tokens, pulls the basic gateway image, starts it)
make setup

# 2. Wait for the gateway to be healthy
# Check: curl http://localhost:9901/healthy

# 3. Send a test request
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mock","messages":[{"role":"user","content":"test"}]}'
```

The basic build is a minimal proxy with no rate limiting, so it has no test
suite. For the rate-limiting builds and their tests, see
[Building the Gateway](#building-the-gateway) and [Testing](#testing).

**Default**: `make setup` runs the **basic build** — pulls the released image (`ghcr.io/praxis-proxy/ai:0.9`) and runs a minimal proxy config (`basic.yaml`). For the experimental build, see [Building the Gateway](#building-the-gateway).

**Requirements**: Docker Compose v2 (`docker compose`, not `docker-compose`)

## Architecture

```
           ┌───────────────────────┐
           │    Praxis Gateway     │   :8080 (data) · :9901 (metrics)
           │ basic: compose image  │
           │ experimental: host bin│
           └───────────┬───────────┘
                       │
      ┌────────────────┼────────────────┐
      │                │                │
      ▼                ▼                ▼
┌────────────┐   ┌────────────┐   ┌────────────┐
│  mock-llm  │   │ inference  │   │ jwt-issuer │
└────────────┘   └────────────┘   └────────────┘
    :1080            :8000            :8888
 multi-provider   OpenAI echo         JWKS
```

The **basic** gateway runs as a compose service; the **experimental** gateway is a
host binary (built by `build/build-experimental.sh`, run by
`build/run-experimental.sh`). The three supporting services always run in compose
and are reachable from the host on the ports shown.

### Services

| Service | Port | Purpose |
| --------- | ------ | --------- |
| `praxis-gateway` | 8080, 9901 | Basic gateway (compose). Experimental runs as a host binary on the same ports. |
| `mock-llm` | 1080 | MockServer (OpenAI, Anthropic, Gemini mocking) |
| `inference-sim` | 8000 | llm-d-inference-sim (real token usage) |
| `jwt-issuer` | 8888 | Static JWKS server |

## Building the Gateway

There are exactly **two builds**. Each has its own standalone build script that
writes the matching runtime config into `.env`. Pick one, then run and test.

| Build | Script | How it's built | Runs as | Runtime config |
|-------|--------|----------------|---------|----------------|
| **Basic** (default) | `./build/build-basic.sh` | Pulls the **released, prebuilt image** at a pinned tag — no local compile | Compose service (`make deploy-gateway`) | `basic.yaml` (minimal proxy, only filters in the release) |
| **Experimental** | `./build/build-experimental.sh` | **Compiles from source on the host** with `experimental-ratelimit` | Host binary (`make run-experimental`) | `ratelimit-limitador.yaml` + `ratelimit-policy.yaml` |

### Basic build (released gateway)

Pulls the released image and runs the minimal `basic.yaml` config:

```bash
./build/build-basic.sh      # or: make gateway-basic
make deploy-gateway
```

The pinned release tag lives at the top of `build/build-basic.sh`
(`AI_IMAGE=ghcr.io/praxis-proxy/ai:0.9`). Bump that tag to move to a newer
release, or override per-run:

```bash
AI_IMAGE=ghcr.io/praxis-proxy/ai:0.9 ./build/build-basic.sh
```

### Experimental build (experimental-ratelimit)

Compiles the gateway **on the host** with the PPE `ratelimit/limitador` plugin,
then runs it on the host against the supporting compose services:

```bash
./build/build-experimental.sh      # or: make gateway-experimental  (~5-10 min first time)
make jwt-tokens                    # mint the RS256 test tokens (once)
make run-experimental              # bring up deps in compose + start the host gateway
make test                          # run the ratelimit acceptance tests
make stop-experimental             # stop the gateway + the deps
```

**What the build does**: builds `praxis-ai` from source (it pins core v0.8.0 ->
policy v0.6.0 from crates.io, which ship the ratelimit/limitador plugin and its
host wiring) and applies a thin overlay — `panic="unwind"` plus a
`policy-experimental-ratelimit` feature passthrough. No vendoring. It writes
`.env` with `GATEWAY_BIN` (the compiled binary path), then `run-experimental.sh`
runs that binary on the host.

**Prerequisites (host)**: `git`, a Rust toolchain **>= 1.92** (policy 0.6.0 MSRV),
and `protobuf-compiler`, `cmake`, `pkg-config`, `libssl-dev` (Limitador's
tonic/prost graph). The build warns if any are missing.

Pin a specific `praxis-ai` revision for a reproducible build, or reuse a checkout:

```bash
PRAXIS_AI_REF=<sha|branch> ./build/build-experimental.sh    # pin a praxis-ai rev
PRAXIS_AI_DIR=/path/to/ai  ./build/build-experimental.sh    # reuse an existing checkout
```

### Switching between builds

The two builds run differently: **basic** is a compose service, **experimental**
is a host binary. Re-run the matching build script (it rewrites `.env`), then use
the matching run command:

```bash
./build/build-experimental.sh && make run-experimental    # experimental (host)
make stop-experimental                                    # ...then stop it

./build/build-basic.sh && make deploy-gateway             # basic (compose)
```

> `.env` is generated by the build scripts — don't edit it by hand; see
> `.env.example` for a description of the variables it contains.

## Runtime Configurations

### Basic (released image)

**File**: `config/praxis/basic.yaml`

**Filter chain**: `router → access_log → load_balancer`

A minimal proxy using only filters compiled into the released image — no rate
limiting. (`token_rate_limit` is not available in any build; it's gated behind the
`token-rate-limit-filter` cargo feature, which neither the released image nor the
experimental build enables.)

### Ratelimit Plugin (Embedded Limitador)

**Files**: `config/praxis/ratelimit-limitador.yaml` + `ratelimit-policy.yaml`

## JWT Tokens

### Available Tokens

Budgets below are for the experimental ratelimit plugin (`ratelimit-limitador.yaml`),
which is request-count based:

| Token | Subject | Tier | Budget |
| ------- | --------- | ------ | -------- |
| `gold.jwt` | `user-gold` | `gold` | 5 req/60s |
| `silver.jwt` | `user-silver` | `silver` | 2 req/60s |
| `enterprise.jwt` | `user-enterprise` | `enterprise` | Exempt (no matching limit) |
| `basic.jwt` | `user-basic` | `basic` | 3 req/60s (default/catch-all) |
| `notier.jwt` | `user-notier` | *(absent)* | Denied before counting (tests missing claim) |

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

`make test` dispatches on the active `PRAXIS_CONFIG` (set by the build scripts):

| Config | What `make test` runs |
| -------- | ----------------------- |
| `basic.yaml` | Nothing — the basic build has no tests |
| `ratelimit-limitador.yaml` | `test-ratelimit-limitador.sh` |

### Manual Testing

```bash
# Check gateway health
curl http://localhost:9901/healthy

# Send test request (no auth)
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mock","messages":[{"role":"user","content":"test"}]}' | jq

# Check logs
docker compose logs praxis-gateway   # basic (compose) gateway
tail -f gateway-local.log            # experimental (host) gateway, or: make logs-experimental
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

**Basic build - image pull fails**:

- Check the pinned tag exists: `docker manifest inspect ghcr.io/praxis-proxy/ai:0.9`
- If the registry needs auth: `docker login ghcr.io`
- Override the tag: `AI_IMAGE=ghcr.io/praxis-proxy/ai:<tag> ./build/build-basic.sh`

**Experimental build - compile error or overlay anchor missing**:

- The overlay applies anchored edits to a specific `praxis-ai` ref; if upstream shifted, pin a known-good rev: `PRAXIS_AI_REF=<sha> ./build/build-experimental.sh`
- Toolchain too old: policy 0.6.0 needs Rust **>= 1.92** — `rustup update`
- Missing native deps: install `protobuf-compiler cmake pkg-config libssl-dev`
- See `build/praxis/apply-experimental-ratelimit-patches.sh` for the overlay detail (panic=unwind + feature passthrough)

### Runtime Issues

**502 Bad Gateway**:

- Check upstreams are healthy: `docker compose ps`
- Verify `allow_private_upstreams: true` in config
- Check logs: `docker compose logs praxis-gateway` (basic) or `gateway-local.log` (experimental)

**No rate limiting (all 200s)** (experimental build):

- Confirm the host gateway is the experimental binary and is running: `./build/run-experimental.sh status`
- Confirm `.env` has `GATEWAY_BIN` set (re-run `./build/build-experimental.sh` if not)
- Verify the JWT carries a `tier` claim the policy keys on
- Check logs: `tail gateway-local.log`

**Gateway won't start / "plugin refuses to load on an aborting build"** (experimental):

- The binary must be built with `panic = "unwind"` — the overlay sets this. Rebuild with `./build/build-experimental.sh` (don't build praxis-ai directly without the overlay).

**Metrics missing**:

- Verify `admin.metrics_address: "0.0.0.0:9901"` in config
- Check `/metrics` endpoint: `curl localhost:9901/metrics`

**JWT verification fails**:

- Regenerate tokens: `rm -rf jwt/private.pem jwt/tokens && make jwt-tokens`
- Restart jwt-issuer: `docker compose restart jwt-issuer`
- Check JWKS: `curl localhost:8888/jwks.json | jq`

## Advanced Usage

### Custom Configuration

Config edits don't require a rebuild — just restart the gateway:

- **Basic (compose)**: the config is mounted from `config/praxis/`. Edit
  `config/praxis/basic.yaml` (or point `.env`'s `PRAXIS_CONFIG` at a new file),
  then `make deploy-gateway`.
- **Experimental (host)**: edit `config/praxis/ratelimit-limitador.yaml` /
  `ratelimit-policy.yaml`, then `make stop-experimental && make run-experimental`.
  No recompile is needed — only the Rust feature/overlay affects the binary.

> `.env` is normally generated by the build scripts; re-running a build script
> overwrites it.

## Related Resources

- **Praxis AI**: <https://github.com/praxis-proxy/ai>
- **Praxis Core**: <https://github.com/praxis-proxy/praxis>
- **Praxis Policy**: <https://github.com/praxis-proxy/policy>
- **llm-d-inference-sim**: <https://github.com/llm-d/llm-d-inference-sim>
- **MockServer**: <https://www.mock-server.com/>

## License

This playground is for testing purposes. See individual component repositories for their licenses.
