#!/usr/bin/env bash
# Overlay for experimental-ratelimit - surface the RELEASED & WIRED plugin.
#
# As of core v0.8.0 (which pins policy v0.6.0) the ratelimit/limitador plugin and
# its host wiring are upstream and released, so the old vendoring/relabel/
# forward-port is GONE. What is now released and wired for us:
#
#   * policy v0.6.0 ships the ratelimit/limitador plugin (crates/builtins) behind
#     the `experimental-ratelimit` feature, re-exposed as ppe/experimental-ratelimit.
#   * core v0.8.0's policy filter NATIVELY invokes ratelimit.{pre,post}_identity
#     (the praxis#1478 host wiring is merged) and exposes the feature
#     praxis-filter/policy-experimental-ratelimit = ["policy-engine",
#     "ppe/experimental-ratelimit"].
#   * praxis-ai main already pins core v0.8.0 (-> policy v0.6.0) from crates.io,
#     so cargo resolves both with no [patch.crates-io] and no vendored sources.
#
# Only TWO things are still missing from praxis-ai, and this overlay adds them:
#
#   1. [profile.release] panic = "unwind".
#      The plugin's factory (policy v0.6.0, ratelimit/factory.rs) REFUSES to load
#      on an aborting build: its handler uses catch_unwind to contain Limitador
#      0.14's panic on a bad CEL condition, which panic="abort" cannot do. ai main
#      ships panic = "abort", so the gateway would refuse the policy at load time.
#
#   2. A `policy-experimental-ratelimit` passthrough feature in praxis-ai.
#      ai's `policy-engine` enables the stable builtins granularly (jwt, cedar,
#      cel, opa, ...) and DELIBERATELY omits the experimental limiter, so it must
#      be opted in. We add a thin feature at both ai layers that forwards to
#      core's praxis-filter/policy-experimental-ratelimit.
#
# This is a stable, additive edit to praxis-ai's own Cargo.toml files - no source
# surgery on core, nothing to drift against beyond two feature anchors.
#
# ENVIRONMENT VARIABLES (set by build/build-experimental.sh):
#   PRAXIS_AI_SOURCE_DIR - Path to the praxis-ai checkout (default: /src/praxis-ai)

set -euo pipefail

PRAXIS_AI_SOURCE_DIR="${PRAXIS_AI_SOURCE_DIR:-/src/praxis-ai}"

echo "========================================" >&2
echo "experimental-ratelimit overlay (released + wired: core 0.8.0 / policy 0.6.0)" >&2
echo "========================================" >&2
echo "" >&2

# ---------------------------------------------------------------------------
# 1. Reset overlaid files to pristine (so re-runs start clean).
# ---------------------------------------------------------------------------
echo "[1/4] Resetting praxis-ai overlay files to pristine..." >&2
cd "${PRAXIS_AI_SOURCE_DIR}"
git checkout -- Cargo.toml server/Cargo.toml filters/Cargo.toml 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. [#1] Flip the release profile to panic = "unwind".
# ---------------------------------------------------------------------------
echo "[2/4] Setting [profile.release] panic = \"unwind\" (root Cargo.toml)..." >&2
python3 -I - Cargo.toml <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
if 'panic = "unwind"' in s:
    print("panic: already unwind", file=sys.stderr)
else:
    # The first `panic = "abort"` is the [profile.release] setting; the later
    # `panic = "deny"` entries are clippy/rustc lints and are left untouched.
    if 'panic = "abort"' not in s:
        sys.exit('ERROR(#1): `panic = "abort"` not found; release profile shifted')
    s = s.replace('panic = "abort"', 'panic = "unwind"', 1)
    open(p, "w").write(s)
    print("panic: abort -> unwind (release profile)", file=sys.stderr)
PY

# ---------------------------------------------------------------------------
# 3. [#2a] praxis-ai-filters: forward to core's praxis-filter feature.
# ---------------------------------------------------------------------------
echo "[3/4] Adding policy-experimental-ratelimit to filters/Cargo.toml..." >&2
python3 -I - filters/Cargo.toml <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = 'experimental = ["praxis-ai-apis/experimental"]'
feature = 'policy-experimental-ratelimit = ["policy-engine", "praxis-filter/policy-experimental-ratelimit"]'
if 'policy-experimental-ratelimit =' in s:
    print("filters feature: already present", file=sys.stderr)
else:
    if anchor not in s:
        sys.exit("ERROR(#2a): filters feature anchor missing; filters/Cargo.toml shifted")
    s = s.replace(
        anchor,
        anchor + '\n'
        '# [playground overlay] Opt into the released PPE ratelimit/limitador plugin:\n'
        '# core 0.8.0 praxis-filter exposes policy-experimental-ratelimit =\n'
        '# ["policy-engine", "ppe/experimental-ratelimit"] (-> praxis-policy-builtins).\n'
        + feature, 1)
    open(p, "w").write(s)
    print("filters feature: added policy-experimental-ratelimit", file=sys.stderr)
PY

# ---------------------------------------------------------------------------
# 4. [#2b] praxis-ai server: top-level knob (kept named experimental-ratelimit
#    so build-experimental.sh and the docs do not change).
# ---------------------------------------------------------------------------
echo "[4/4] Adding experimental-ratelimit to server/Cargo.toml..." >&2
python3 -I - server/Cargo.toml <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = 'experimental = ["praxis-ai-filters/experimental"]'
feature = ('experimental-ratelimit = ["policy-engine", '
           '"praxis-ai-filters/policy-experimental-ratelimit", "experimental"]')
if 'experimental-ratelimit =' in s:
    print("server feature: already present", file=sys.stderr)
else:
    if anchor not in s:
        sys.exit("ERROR(#2b): server feature anchor missing; server/Cargo.toml shifted")
    s = s.replace(
        anchor,
        anchor + '\n'
        '# [playground overlay] Top-level knob for the PPE ratelimit/limitador\n'
        '# plugin; forwards to praxis-ai-filters -> praxis-filter -> ppe -> builtins.\n'
        + feature, 1)
    open(p, "w").write(s)
    print("server feature: added experimental-ratelimit", file=sys.stderr)
PY

echo "" >&2
echo "[done] Overlay applied. No vendored sources - core 0.8.0 / policy 0.6.0 come" >&2
echo "       from crates.io via praxis-ai's own version pins." >&2
echo "       Build with: cargo build --release --features full,experimental-ratelimit" >&2
echo "========================================" >&2
