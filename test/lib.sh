#!/usr/bin/env bash
# Shared test helpers for Praxis playground acceptance tests

# Service URLs
PRAXIS_URL="${PRAXIS_URL:-http://localhost:8080}"
PRAXIS_METRICS_URL="${PRAXIS_METRICS_URL:-http://localhost:9901}"
JWT_DIR="${JWT_DIR:-./jwt/tokens}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging helpers
log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[✓]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[!]${NC} $*"
}

log_error() {
  echo -e "${RED}[✗]${NC} $*"
}

# Token loading
get_token() {
  local tier="$1"
  if [ ! -f "${JWT_DIR}/${tier}.jwt" ]; then
    log_error "Token not found: ${JWT_DIR}/${tier}.jwt"
    log_info "Run 'make jwt-tokens' to generate tokens"
    exit 1
  fi
  cat "${JWT_DIR}/${tier}.jwt"
}

# HTTP helpers

# post_chat <tier> [model] [max_tokens] [extra_headers]
# Sends a POST to /v1/chat/completions with the specified tier's JWT
# Returns: JSON response + HTTP status code on last line
post_chat() {
  local tier="$1"
  local model="${2:-mock}"
  local max_tokens="${3:-}"
  local extra_headers="${4:-}"

  local body='{"model":"'"${model}"'","messages":[{"role":"user","content":"Tell me a three sentence bedtime story about a unicorn."}]'
  if [ -n "${max_tokens}" ]; then
    body="${body%\}},\"max_tokens\":${max_tokens}}"
  fi

  local token
  token="$(get_token "${tier}")"

  local temp_headers temp_body
  temp_headers="$(mktemp)"
  temp_body="$(mktemp)"
  trap "rm -f '${temp_headers}' '${temp_body}'" RETURN

  local http_code
  http_code=$(curl -s -D "${temp_headers}" -o "${temp_body}" -w '%{http_code}' \
    "${PRAXIS_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "x-tier: ${tier}" \
    ${extra_headers} \
    -d "${body}" || echo "000")

  # Output body + headers, then status code on last line
  cat "${temp_body}"
  echo
  echo "HTTP_CODE:${http_code}"
  if [ -f "${temp_headers}" ]; then
    grep -i 'x-ratelimit' "${temp_headers}" | tr -d '\r' || true
  fi
}

# post_chat_simple <tier> [model] [max_tokens]
# Simpler version that just returns HTTP status code
post_chat_code() {
  local tier="$1"
  local model="${2:-mock}"
  local max_tokens="${3:-}"

  local token
  token="$(get_token "${tier}")"

  local body='{"model":"'"${model}"'","messages":[{"role":"user","content":"test"}]'
  if [ -n "${max_tokens}" ]; then
    body="${body%\}},\"max_tokens\":${max_tokens}}"
  fi

  curl -s -w '%{http_code}' -o /dev/null \
    "${PRAXIS_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "x-tier: ${tier}" \
    -d "${body}" || echo "000"
}

# Metrics scraping
get_metrics() {
  curl -s "${PRAXIS_METRICS_URL}/metrics" || echo ""
}

# Get specific metric value
get_metric() {
  local metric_name="$1"
  get_metrics | grep "^${metric_name}" | grep -v '^#' | awk '{print $2}' | head -1
}

# Hammer endpoint with N requests
# hammer <tier> <count> [model] [max_tokens]
# Returns: count of 200s, count of 429s
hammer() {
  local tier="$1"
  local count="$2"
  local model="${3:-mock}"
  local max_tokens="${4:-}"

  local count_200=0
  local count_429=0
  local count_other=0

  log_info "Sending ${count} requests (tier=${tier}, model=${model})..." >&2

  for i in $(seq 1 "${count}"); do
    local code
    code="$(post_chat_code "${tier}" "${model}" "${max_tokens}")"

    case "${code}" in
      200)
        ((count_200++))
        echo -n "." >&2
        ;;
      429)
        ((count_429++))
        echo -n "X" >&2
        ;;
      *)
        ((count_other++))
        echo -n "?" >&2
        ;;
    esac
  done
  echo >&2

  log_info "Results: 200=${count_200}, 429=${count_429}, other=${count_other}" >&2
  echo "${count_200} ${count_429} ${count_other}"
}

# Wait for service to be healthy
wait_for_service() {
  local url="$1"
  local max_wait="${2:-30}"
  local waited=0

  log_info "Waiting for ${url} to be healthy..."

  while [ ${waited} -lt ${max_wait} ]; do
    if curl -sf "${url}" > /dev/null 2>&1; then
      log_success "Service is healthy"
      return 0
    fi
    sleep 1
    ((waited++))
  done

  log_error "Service did not become healthy within ${max_wait}s"
  return 1
}

# Check if Praxis gateway is ready
check_gateway() {
  wait_for_service "${PRAXIS_METRICS_URL}/healthy" 30
}
