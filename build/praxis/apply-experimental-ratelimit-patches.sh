#!/usr/bin/env bash
# Patches for experimental-ratelimit - vendor policy main + core v0.7.5, apply #1478 forward-port
#
# This script vendors both praxis-proxy/policy (main) and praxis-proxy/praxis (v0.7.5)
# and patches core to work with the 0.5.0 policy engine:
#
# WHAT IT DOES:
#   1. Vendor praxis-policy main (has merged experimental-ratelimit plugin)
#   2. Relabel policy 0.5.0 → 0.4.1 (satisfies core's ^0.4.1 requirement)
#   3. Vendor praxis-core v0.7.5
#   4. Patch core policy filter for:
#      (A) Import Credential and ratelimit hooks
#      (B) Compile fix: source_header → Credential::Header
#      (C) #1478 host wiring: invoke ratelimit.post_identity after identity.resolve
#   5. Overlay server/Cargo.toml: add experimental-ratelimit feature
#   6. Overlay root Cargo.toml: add [patch.crates-io], exclude vendored dirs, panic=unwind
#
# ENVIRONMENT VARIABLES (set by Dockerfile):
#   PRAXIS_AI_SOURCE_DIR     - Path to praxis-ai source
#   PRAXIS_POLICY_REPO       - Policy repo URL (default: https://github.com/praxis-proxy/policy)
#   PRAXIS_POLICY_REF        - Policy ref (default: main)
#   PRAXIS_CORE_REPO         - Core repo URL (default: https://github.com/praxis-proxy/praxis)
#   PRAXIS_CORE_REF          - Core ref (default: v0.7.5)

set -euo pipefail

# Defaults
PRAXIS_AI_SOURCE_DIR="${PRAXIS_AI_SOURCE_DIR:-/src/praxis-ai}"
PRAXIS_POLICY_REPO="${PRAXIS_POLICY_REPO:-https://github.com/praxis-proxy/policy}"
PRAXIS_POLICY_REF="${PRAXIS_POLICY_REF:-main}"
PRAXIS_CORE_REPO="${PRAXIS_CORE_REPO:-https://github.com/praxis-proxy/praxis}"
PRAXIS_CORE_REF="${PRAXIS_CORE_REF:-v0.7.5}"

VENDOR_POLICY="${PRAXIS_AI_SOURCE_DIR}/vendor-policy"
VENDOR_CORE="${PRAXIS_AI_SOURCE_DIR}/vendor-core"
CORE_FILTER_REL="crates/filter/src/builtins/http/security/policy/filter.rs"

echo "========================================" >&2
echo "experimental-ratelimit patches" >&2
echo "========================================" >&2
echo "" >&2

# ---------------------------------------------------------------------------
# 1. Reset overlay files to pristine state
# ---------------------------------------------------------------------------
echo "[1/6] Resetting praxis-ai overlay files to pristine..." >&2
cd "${PRAXIS_AI_SOURCE_DIR}"
git checkout -- Cargo.toml server/Cargo.toml 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Vendor the policy engine from main (merged plugin); relabel 0.5.0 -> 0.4.1
# ---------------------------------------------------------------------------
echo "[2/6] Fetching policy engine (${PRAXIS_POLICY_REPO} @ ${PRAXIS_POLICY_REF})..." >&2
rm -rf "${VENDOR_POLICY}"
git clone --depth 1 --branch "${PRAXIS_POLICY_REF}" "${PRAXIS_POLICY_REPO}" "${VENDOR_POLICY}"
rm -rf "${VENDOR_POLICY}/.git" "${VENDOR_POLICY}/target"

echo "[2/6] Relabelling vendored praxis-policy* version 0.5.0 -> 0.4.1..." >&2
python3 -I - "${VENDOR_POLICY}/Cargo.toml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
# Every 0.5.0 in the policy root Cargo.toml is a praxis-policy* version pin
# (workspace version + 7 path-dep pins); members inherit via version.workspace.
n = s.count('"0.5.0"'); open(p, "w").write(s.replace('"0.5.0"', '"0.4.1"'))
print(f"Relabelled {n} version string(s)", file=sys.stderr)
PY

# ---------------------------------------------------------------------------
# 3. Vendor core @ the pinned tag; forward-port its policy filter (A + B + C)
# ---------------------------------------------------------------------------
echo "[3/6] Fetching core (${PRAXIS_CORE_REPO} @ ${PRAXIS_CORE_REF})..." >&2
rm -rf "${VENDOR_CORE}"
git clone --depth 1 --branch "${PRAXIS_CORE_REF}" "${PRAXIS_CORE_REPO}" "${VENDOR_CORE}"
rm -rf "${VENDOR_CORE}/.git" "${VENDOR_CORE}/target"

echo "[3/6] Patching core policy filter (A imports, B source_header, C #1478)..." >&2
python3 -I - "${VENDOR_CORE}/${CORE_FILTER_REL}" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()

# (A) imports: bring Credential (for B) and the post-identity hook (for C) in scope.
old_use = '    extensions::{LLMExtension, LlmRequestDocument, MetaExtension},'
new_use = ('    extensions::{Credential, LLMExtension, LlmRequestDocument, MetaExtension},\n'
           '    ratelimit_hook::HOOK_RATELIMIT_POST_IDENTITY,')
a_done = 'ratelimit_hook::HOOK_RATELIMIT_POST_IDENTITY,' in s
if not a_done:
    if old_use not in s:
        sys.exit("ERROR(A): import anchor missing; core source shifted")
    s = s.replace(old_use, new_use, 1)

# (B) compile against 0.5.0: map the removed source_header to Credential::Header.
old_loop = '''        for inbound in raw.inbound_tokens.values() {
            let normalized = inbound.source_header.to_ascii_lowercase();
            if attached_outbound.contains(&normalized) {
                continue;
            }
            if let Ok(n) = http::header::HeaderName::try_from(inbound.source_header.as_str()) {
                ctx.request_headers_to_remove.push(n);
            } else {
                tracing::warn!(
                    target: "policy.filter",
                    header = %inbound.source_header,
                    "inbound source_header is not a valid HTTP header name; cannot strip",
                );
            }'''
new_loop = '''        for inbound in raw.inbound_tokens.values() {
            // [playground P4 overlay] 0.5.0 replaced source_header: String with
            // source: Credential; map Credential::Header{name} back, skip cookie/query.
            let Credential::Header { name: source_header } = &inbound.source else {
                continue;
            };
            let normalized = source_header.to_ascii_lowercase();
            if attached_outbound.contains(&normalized) {
                continue;
            }
            if let Ok(n) = http::header::HeaderName::try_from(source_header.as_str()) {
                ctx.request_headers_to_remove.push(n);
            } else {
                tracing::warn!(
                    target: "policy.filter",
                    header = %source_header,
                    "inbound source_header is not a valid HTTP header name; cannot strip",
                );
            }'''
b_done = 'Credential::Header { name: source_header }' in s
if not b_done:
    if old_loop not in s:
        sys.exit("ERROR(B): source_header anchor missing; core source shifted")
    s = s.replace(old_loop, new_loop, 1)

# (C) #1478 host wiring (post-identity subset): invoke ratelimit.post_identity
# after the header-phase identity.resolve, before the http.request hook.
anchor = '''        Self::attach_http_attributes(ctx, &mut extensions, headers);

        // Awaited on the worker runtime on purpose.'''
block = '''        Self::attach_http_attributes(ctx, &mut extensions, headers);

        // [playground P4 overlay] Host integration for the ratelimit/limitador
        // plugin (praxis-proxy/praxis#1478, post-identity subset): after
        // identity.resolve, invoke ratelimit.post_identity keyed on the resolved
        // identity. Gated by has_hooks_for so a policy with no rate_limits: list is
        // unaffected. A denial stops the request with the violation's HTTP status
        // (429/401/400/503) via the same mapper http.request denials use.
        if self.mgr.has_hooks_for(HOOK_RATELIMIT_POST_IDENTITY) {
            let (rl_result, _rl_bg) = self
                .mgr
                .invoke_named::<HttpHook>(HOOK_RATELIMIT_POST_IDENTITY, HttpPayload, extensions.clone(), None)
                .await;
            if !rl_result.continue_processing {
                tracing::debug!(target: "policy.filter", "ratelimit.post_identity deny (on_request)");
                return Ok(FilterAction::Reject(super::error::http_authz_rejection(
                    rl_result.violation.as_ref(),
                )));
            }
        }

        // Awaited on the worker runtime on purpose.'''
c_done = 'ratelimit.post_identity deny (on_request)' in s
if not c_done:
    if anchor not in s:
        sys.exit("ERROR(C): post_identity injection anchor missing; core source shifted")
    s = s.replace(anchor, block, 1)

open(p, "w").write(s)
print("Core patches: A=%s B=%s C=%s" % (
    "present" if a_done else "applied",
    "present" if b_done else "applied",
    "present" if c_done else "applied"), file=sys.stderr)
PY

# ---------------------------------------------------------------------------
# 4. Overlay praxis-ai server/Cargo.toml: direct praxis-policy dep + feature
# ---------------------------------------------------------------------------
echo "[4/6] Applying experimental-ratelimit overlay to server/Cargo.toml..." >&2
python3 -I - "${PRAXIS_AI_SOURCE_DIR}/server/Cargo.toml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read(); changed = False
if "experimental-ratelimit" not in s:
    s = s.replace(
        'experimental = ["praxis-ai-filters/experimental"]',
        'experimental = ["praxis-ai-filters/experimental"]\n'
        '# [playground overlay] P4: enable the PPE ratelimit/limitador plugin.\n'
        'experimental-ratelimit = ["policy-engine", "dep:praxis-policy", "praxis-policy/experimental-ratelimit"]',
        1); changed = True
if "praxis-policy = {" not in s:
    s = s.replace(
        'praxis-core = { workspace = true }',
        'praxis-core = { workspace = true }\n'
        '# [playground overlay] P4: direct praxis-policy dep; [patch] (root Cargo.toml)\n'
        '# redirects it to the vendored policy-main source so experimental-ratelimit builds.\n'
        'praxis-policy = { version = "=0.4.1", optional = true, default-features = false }',
        1); changed = True
open(p, "w").write(s)
print("Server overlay: %s" % ("applied" if changed else "already present"), file=sys.stderr)
PY

# ---------------------------------------------------------------------------
# 5. Overlay praxis-ai root Cargo.toml: exclude vendor dirs + [patch.crates-io]
# ---------------------------------------------------------------------------
echo "[5/6] Applying [patch.crates-io] overlay to root Cargo.toml..." >&2
python3 -I - "${PRAXIS_AI_SOURCE_DIR}/Cargo.toml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
if 'exclude' not in s.split('[workspace.package]')[0]:
    s = s.replace('resolver = "3"',
                  'resolver = "3"\nexclude = ["vendor-core", "vendor-policy"]', 1)
# The merged ratelimit plugin refuses to load on a panic=abort build (it must be
# able to catch Limitador's panic on a bad CEL condition). Release profile pins
# panic = "abort"; flip it to "unwind" for this build. (The only "abort" value;
# the lint `panic = "deny"` elsewhere is unaffected.)
s = s.replace('panic = "abort"', 'panic = "unwind"', 1)
if '[patch.crates-io]' not in s:
    patch = '''
# [playground overlay] P4: redirect the praxis-proxy* (core) and praxis-policy*
# (engine) families to the vendored sources. core = tag v0.7.5 with the policy
# filter forward-ported (compile shim + #1478 post-identity host wiring); engine =
# policy main (merged PR #178) relabelled to 0.4.1 so it satisfies core's ^0.4.1.
[patch.crates-io]
praxis-proxy = { path = "vendor-core/crates/server" }
praxis-proxy-core = { path = "vendor-core/crates/core" }
praxis-proxy-filter = { path = "vendor-core/crates/filter" }
praxis-proxy-protocol = { path = "vendor-core/crates/protocol" }
praxis-proxy-tls = { path = "vendor-core/crates/tls" }
praxis-policy = { path = "vendor-policy/crates/ppe" }
praxis-policy-core = { path = "vendor-policy/crates/ppe-core" }
praxis-policy-orchestration = { path = "vendor-policy/crates/ppe-orchestration" }
praxis-policy-apl-core = { path = "vendor-policy/crates/ppe-apl-core" }
praxis-policy-apl-cmf = { path = "vendor-policy/crates/ppe-apl-cmf" }
praxis-policy-apl-runtime = { path = "vendor-policy/crates/ppe-apl-runtime" }
praxis-policy-builtins = { path = "vendor-policy/crates/builtins" }
'''
    s = s.rstrip() + "\n" + patch
open(p, "w").write(s)
print("Root overlay: applied", file=sys.stderr)
PY

# ---------------------------------------------------------------------------
# 6. Done
# ---------------------------------------------------------------------------
echo "[6/6] Patches complete" >&2
echo "" >&2
echo "Vendored sources:" >&2
echo "  - Policy: ${VENDOR_POLICY}" >&2
echo "  - Core:   ${VENDOR_CORE}" >&2
echo "" >&2
echo "Next: Cargo build will use these vendored sources via [patch.crates-io]" >&2
echo "========================================" >&2
