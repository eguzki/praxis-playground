# Praxis Playground - Developer Guide

A playground for building and testing the Praxis AI gateway's rate-limiting
features. Supporting services run in Docker Compose. The gateway runs either as a
released image **in compose** (basic build) or as a **host-compiled binary**
(experimental build).

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
- **Experimental** — `./build/build-experimental.sh` compiles **on the host** with
  only `experimental-ratelimit` (PPE plugin, embedded Limitador, M1+M5), and
  `./build/run-experimental.sh` runs the binary on the host against
  `ratelimit-limitador.yaml` + `ratelimit-policy.yaml`. Builds praxis-ai main,
  which pins core v0.8.0 (-> policy v0.6.0) from crates.io — no vendoring. A thin
  overlay only adds `panic="unwind"` + a feature passthrough (~5-10 min).

The **basic** build retags the released image (`praxis-gateway:basic`) and writes
`.env` with `GATEWAY_IMAGE` / `PRAXIS_CONFIG` / `PRAXIS_POLICY_CONFIG_PATH`;
`docker-compose.yml` runs `${GATEWAY_IMAGE}` as the `praxis-gateway` service. The
**experimental** build writes `.env` with `GATEWAY_BIN` (the compiled binary path)
and `PRAXIS_CONFIG`, and does NOT use the compose `praxis-gateway` service — the
host binary is launched by `run-experimental.sh`, which only brings up the
supporting services in compose.

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

### Experimental build — `build/build-experimental.sh` (HOST build)

A plain host build — no Docker image for the gateway. Steps:

1. Resolve a `praxis-ai` checkout: clone `PRAXIS_AI_REPO`@`PRAXIS_AI_REF` (default
   `main`) into `build/.praxis-ai` (gitignored), or reuse `PRAXIS_AI_DIR`. Core and
   policy are NOT cloned — praxis-ai pins them as crates.io versions (core v0.8.0 ->
   policy v0.6.0).
2. Sanity-check the host toolchain (warns if `rustc < 1.92`, policy 0.6.0's MSRV, or
   if `protoc`/`cmake`/`pkg-config` are missing).
3. Apply the overlay (`apply-experimental-ratelimit-patches.sh`): `panic="unwind"` +
   a `policy-experimental-ratelimit` feature passthrough — no vendoring.
4. `cargo build --release --features full,experimental-ratelimit --bin praxis-ai`.
5. Write `.env` with `GATEWAY_BIN` (path to the compiled binary) and
   `PRAXIS_CONFIG=ratelimit-limitador.yaml`.

### Running it — `build/run-experimental.sh {start|stop|status}`

- `start`: `docker compose up -d inference-sim mock-llm jwt-issuer` (supporting
  services only), health-checks them, then runs `$GATEWAY_BIN` on the host **from
  `config/praxis/`** (so the policy `config_path` resolves), backgrounded with
  `.gateway-local.pid` + `gateway-local.log`, and waits on `:9901/healthy`.
- `stop`: kills the pidfile process and `docker compose stop`s the supporting services.

### Experimental-Ratelimit Build Process

As of core **v0.8.0** (which pins policy **v0.6.0**) the plugin and its host wiring
are released, so the old vendoring/relabel/forward-port is gone. What is now
released and wired for us:

- policy v0.6.0 ships the `ratelimit/limitador` plugin behind `experimental-ratelimit`,
  re-exposed as `ppe/experimental-ratelimit`.
- core v0.8.0's policy filter natively invokes `ratelimit.{pre,post}_identity`
  (praxis#1478 is merged) and exposes `praxis-filter/policy-experimental-ratelimit`.
- praxis-ai main already pins core v0.8.0 (-> policy v0.6.0) from crates.io.

So `apply-experimental-ratelimit-patches.sh` now only overlays praxis-ai's own
Cargo.toml with the two things still missing there:

1. **`[profile.release] panic = "unwind"`** — the plugin's factory refuses to load
   on a `panic="abort"` build (its handler uses `catch_unwind` to contain Limitador's
   panic on a bad CEL condition). ai main ships `panic="abort"`.
2. **A `policy-experimental-ratelimit` feature passthrough** — ai's `policy-engine`
   enables the stable builtins granularly and deliberately omits the experimental
   limiter, so it must be opted in. Added at both ai layers (filters + server),
   forwarding to `praxis-filter/policy-experimental-ratelimit`.

### Source Specification (experimental build only)

`PRAXIS_AI_REF` controls the `praxis-ai` ref the experimental build checks out
(default `main`; a branch or commit SHA); it pins core v0.8.0 / policy v0.6.0
transitively via its own crates.io version deps. `PRAXIS_AI_DIR` reuses an existing
checkout instead of cloning. For a reproducible demo build, pin `PRAXIS_AI_REF` to a
specific commit. The basic build has no source spec — it pulls a prebuilt image by
tag (`AI_IMAGE`).

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

**Key settings (host-run):**
- `allow_private_upstreams` / `allow_private_endpoints: true` - loopback upstreams
- `allow_private_idp: true` - JWKS fetched over loopback
- No `allow_root` - the host binary runs as your user
- Policy document: `config_path: ratelimit-policy.yaml` (bare sibling name; the
  gateway is run from `config/praxis/`)
- Upstreams point at `127.0.0.1:1080` (mock-llm's compose port map)

**Policy plugins:**
- **identity/jwt**: RS256 verification via JWKS at `http://localhost:8888/jwks.json`
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
- Built via `./build/build-experimental.sh` on the host (`cargo build --release
  --features full,experimental-ratelimit`; praxis-ai main pins core v0.8.0 / policy
  v0.6.0 from crates.io; applies the panic=unwind + feature overlay). Needs Rust
  >= 1.92 and `protobuf-compiler`/`cmake`/`pkg-config`/`libssl-dev` on the host.

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

**JWKS endpoint**: `http://localhost:8888/jwks.json` (nginx in compose; `jwt-issuer`
is the internal service name, reached from the host via the 8888:80 port map)

## Common Issues

### Gateway refuses to start ("plugin refuses to load on an aborting build")
**Symptom**: the experimental gateway exits at startup citing `panic = "unwind"`
**Fix**: rebuild via `./build/build-experimental.sh` — the overlay sets
`[profile.release] panic = "unwind"`, required by the ratelimit plugin's factory.

### 502 Bad Gateway
**Symptom**: All requests fail with 502
**Fix**: ensure `allow_private_upstreams: true` (loopback upstreams) and that the
supporting services are up (`./build/run-experimental.sh status`).

### Tests return all "other" (not 200/429)
**Symptom**: `hammer()` shows `??????????`
**Fix**: Gateway not reachable or tokens missing — check `./build/run-experimental.sh status` and run `make jwt-tokens`.

### Ratelimit requests all 401 / denied
**Symptom**: Every request to the experimental build is rejected
**Fix**: The JWT must carry a `tier` claim the policy keys on (`notier.jwt` is denied by design); verify JWKS is reachable at `http://localhost:8888/jwks.json`.

### No metrics visible
**Symptom**: `/metrics` returns 404 or empty  
**Fix**: Set `admin.metrics_address: "0.0.0.0:9901"` in config

## Development Workflow

### Switching Between Builds

The two builds run differently — basic is a compose service, experimental is a host
binary:

```bash
# Experimental-ratelimit (host binary)
./build/build-experimental.sh   # or: make gateway-experimental
make run-experimental           # start deps (compose) + the host gateway
make test
make stop-experimental

# Basic (released image, minimal proxy, in compose)
./build/build-basic.sh          # or: make gateway-basic
make deploy-gateway
```

### Changing the runtime config (no rebuild)

- **Basic (compose)**: config is bind-mounted — edit `config/praxis/basic.yaml`,
  then `docker compose restart praxis-gateway`.
- **Experimental (host)**: edit `config/praxis/ratelimit-limitador.yaml` /
  `ratelimit-policy.yaml`, then `make stop-experimental && make run-experimental`
  (no recompile needed).

### Pinning different sources

- Basic: bump the tag — `AI_IMAGE=ghcr.io/praxis-proxy/ai:<tag> ./build/build-basic.sh`
- Experimental: pin the `praxis-ai` ref — `PRAXIS_AI_REF=<sha> ./build/build-experimental.sh`
  (core v0.8.0 / policy v0.6.0 are pinned transitively by praxis-ai's crates.io deps)

### Debugging

```bash
# Gateway logs
docker compose logs praxis-gateway   # basic (compose)
tail -f gateway-local.log            # experimental (host)  (make logs-experimental)

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
├── docker-compose.yml          # Supporting services + basic gateway (${GATEWAY_IMAGE})
├── .env.example                # Reference for the .env the build scripts generate
├── Makefile                    # Convenience targets
├── README.md                   # User-facing overview
├── build/
│   ├── build-basic.sh          # BASIC build: pull released image (compose)
│   ├── build-experimental.sh   # EXPERIMENTAL build: host cargo build
│   ├── run-experimental.sh     # start|stop|status the host experimental gateway
│   ├── praxis/
│   │   └── apply-experimental-ratelimit-patches.sh # Thin overlay (panic=unwind + feature)
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
make gateway-experimental  # Build EXPERIMENTAL gateway on the HOST (cargo build)
make run-experimental      # Start host experimental gateway + supporting services
make stop-experimental     # Stop host experimental gateway + supporting services
make gateway               # Alias for gateway-basic
make deploy-gateway        # Restart the BASIC (compose) gateway
make up                    # Start all compose services
make down                  # Stop all compose services
make logs                  # Tail basic (compose) gateway logs
make logs-experimental     # Tail host experimental gateway log
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
