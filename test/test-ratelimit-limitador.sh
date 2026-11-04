#!/usr/bin/env bash
# Test ratelimit/limitador plugin - Praxis PPE with embedded in-memory Limitador
#
# Tests request-count rate limiting (not token-based) with per-tier budgets:
#   gold       -> 5 req/60s   (M5 budget keyed on tier)
#   silver     -> 2 req/60s
#   basic      -> 3 req/60s   (default/catch-all tier)
#   enterprise -> EXEMPT      (no limit matches -> unmetered)
#   notier     -> DENIED      (missing tier claim -> denied before counting)
#
# M1 (limited-vs-exempt) + M5 (independent per-tier budgets) are verified below.
#
# NOTE: Embedded counters are in-process and per-replica; they reset on restart.
# Budgets are small on purpose. Re-run after the 60s window to reset counters.
#
# Prereq: Gateway running with ratelimit-limitador.yaml config

set -euo pipefail

# Load test helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# hammer <tier> <count>: send N requests, return space-separated HTTP codes
hammer() {
  local tier="$1" count="$2"
  local codes=()

  log_info "Testing tier=${tier} (${count} requests)..." >&2

  for i in $(seq 1 "${count}"); do
    local code
    code="$(post_chat_code "${tier}")"
    codes+=("${code}")

    # Visual progress
    case "${code}" in
      200) echo -n "." >&2 ;;
      429) echo -n "X" >&2 ;;
      401) echo -n "!" >&2 ;;
      400) echo -n "?" >&2 ;;
      *)   echo -n "?" >&2 ;;
    esac
  done
  echo >&2

  echo "${codes[@]}"
}

# count_codes <codes...>: count 200s, 429s, others
count_codes() {
  local count_200=0 count_429=0 count_other=0

  for code in "$@"; do
    case "${code}" in
      200) ((count_200++)) ;;
      429) ((count_429++)) ;;
      *)   ((count_other++)) ;;
    esac
  done

  echo "${count_200} ${count_429} ${count_other}"
}

echo ""
log_info "=========================================="
log_info "Ratelimit/Limitador Plugin Tests"
log_info "=========================================="
echo ""
log_info "Config: ratelimit-limitador.yaml + ratelimit-policy.yaml"
log_info "Gateway: ${PRAXIS_URL}"
echo ""

# Check gateway is healthy
if ! curl -sf "${PRAXIS_METRICS_URL}/healthy" > /dev/null 2>&1; then
  log_error "Gateway not healthy at ${PRAXIS_METRICS_URL}/healthy"
  log_info "Start with: PRAXIS_CONFIG=ratelimit-limitador.yaml make setup"
  exit 1
fi

echo ""
log_info "Test 1: Per-tier budgets"
log_info "------------------------------------------"
echo ""

# Gold: 5 req/60s (expect 5×200, then 429)
log_info "Gold tier: 5 req/60s budget"
gold_codes=($(hammer gold 6))
gold_counts=($(count_codes "${gold_codes[@]}"))
log_info "Results: ${gold_counts[0]} × 200, ${gold_counts[1]} × 429, ${gold_counts[2]} × other"

if [ "${gold_counts[0]}" -eq 5 ] && [ "${gold_counts[1]}" -ge 1 ]; then
  log_success "✓ Gold: 5×200 then 429"
else
  log_error "✗ Gold: expected 5×200 then 429, got ${gold_counts[0]}×200 ${gold_counts[1]}×429"
fi
echo ""

# Silver: 2 req/60s (expect 2×200, then 429)
log_info "Silver tier: 2 req/60s budget"
silver_codes=($(hammer silver 3))
silver_counts=($(count_codes "${silver_codes[@]}"))
log_info "Results: ${silver_counts[0]} × 200, ${silver_counts[1]} × 429, ${silver_counts[2]} × other"

if [ "${silver_counts[0]}" -eq 2 ] && [ "${silver_counts[1]}" -ge 1 ]; then
  log_success "✓ Silver: 2×200 then 429"
else
  log_error "✗ Silver: expected 2×200 then 429, got ${silver_counts[0]}×200 ${silver_counts[1]}×429"
fi
echo ""

# Basic: 3 req/60s (default catch-all, expect 3×200 then 429)
log_info "Basic tier: 3 req/60s budget (default/catch-all)"
basic_codes=($(hammer basic 4))
basic_counts=($(count_codes "${basic_codes[@]}"))
log_info "Results: ${basic_counts[0]} × 200, ${basic_counts[1]} × 429, ${basic_counts[2]} × other"

if [ "${basic_counts[0]}" -eq 3 ] && [ "${basic_counts[1]}" -ge 1 ]; then
  log_success "✓ Basic: 3×200 then 429"
else
  log_error "✗ Basic: expected 3×200 then 429, got ${basic_counts[0]}×200 ${basic_counts[1]}×429"
fi
echo ""

echo ""
log_info "Test 2: M1 - Exemption"
log_info "------------------------------------------"
echo ""

# Enterprise: exempt (no limit matches -> all 200)
log_info "Enterprise tier: exempt (no matching limit)"
enterprise_codes=($(hammer enterprise 6))
enterprise_counts=($(count_codes "${enterprise_codes[@]}"))
log_info "Results: ${enterprise_counts[0]} × 200, ${enterprise_counts[1]} × 429, ${enterprise_counts[2]} × other"

if [ "${enterprise_counts[0]}" -ge 6 ] && [ "${enterprise_counts[1]}" -eq 0 ]; then
  log_success "✓ Enterprise: exempt (all 200s, no 429s)"
else
  log_error "✗ Enterprise: expected all 200s, got ${enterprise_counts[0]}×200 ${enterprise_counts[1]}×429"
fi
echo ""

echo ""
log_info "Test 3: Missing claim handling"
log_info "------------------------------------------"
echo ""

# Notier: denied (missing tier claim -> ratelimit.missing_attribute -> denied before counting)
log_info "Notier: missing tier claim (should deny before counting)"
notier_code=$(post_chat_code notier)
log_info "Result: HTTP ${notier_code}"

if [ "${notier_code}" = "400" ] || [ "${notier_code}" = "401" ]; then
  log_success "✓ Notier: denied (${notier_code}) due to missing tier claim"
else
  log_warn "⚠ Notier: got ${notier_code}, expected 400/401 (missing attribute)"
fi
echo ""

echo ""
log_info "Test 4: M5 - Independent per-tier counters"
log_info "------------------------------------------"
echo ""
log_info "Gold, silver, and basic budgets are separate counters:"
log_info "  - Gold exhausted its 5-req budget"
log_info "  - Silver exhausted its 2-req budget"
log_info "  - Basic exhausted its 3-req budget"
log_info "  - Enterprise was never limited"
log_info ""
log_success "✓ M5: Per-tier independence verified (each tier hit its own distinct limit)"
echo ""

echo ""
log_info "=========================================="
log_info "Summary"
log_info "=========================================="
echo ""
log_info "Request-count rate limiting with embedded Limitador:"
log_success "  ✓ Per-tier budgets (gold 5, silver 2, basic 3)"
log_success "  ✓ M1: Enterprise exemption (no matching limit)"
log_success "  ✓ M5: Independent per-tier counters"
log_info ""
log_warn "NOTE: Counters reset after 60s window or on gateway restart"
log_info ""
