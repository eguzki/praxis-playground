#!/usr/bin/env bash
# Run tests for current configuration
set -euo pipefail

cd "$(dirname "$0")"
source ./lib.sh

PRAXIS_CONFIG="${PRAXIS_CONFIG:-token-rate-limit.yaml}"

log_info "Running tests for configuration: ${PRAXIS_CONFIG}"
echo

case "${PRAXIS_CONFIG}" in
  token-rate-limit.yaml)
    log_info "Running token rate limiting tests (M1-M7)..."
    ./test-token-rate-limit.sh
    ;;
  rate-limit.yaml)
    log_info "Running request-count rate limiting tests..."
    log_warn "Test script not yet implemented: test-rate-limit.sh"
    ;;
  ratelimit-limitador.yaml)
    log_info "Running ratelimit plugin tests..."
    if [ -f ./test-ratelimit-limitador.sh ]; then
      ./test-ratelimit-limitador.sh
    else
      log_warn "Test script not yet implemented: test-ratelimit-limitador.sh"
    fi
    ;;
  *)
    log_error "Unknown configuration: ${PRAXIS_CONFIG}"
    log_info "Supported configs: token-rate-limit.yaml, rate-limit.yaml, ratelimit-limitador.yaml"
    exit 1
    ;;
esac
