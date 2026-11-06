#!/usr/bin/env bash
# Run tests for current configuration
set -euo pipefail

cd "$(dirname "$0")"
source ./lib.sh

PRAXIS_CONFIG="${PRAXIS_CONFIG:-basic.yaml}"

log_info "Running tests for configuration: ${PRAXIS_CONFIG}"
echo

case "${PRAXIS_CONFIG}" in
  basic.yaml)
    log_info "No tests for the basic build (minimal proxy config); nothing to run."
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
    log_info "Supported configs: basic.yaml, ratelimit-limitador.yaml"
    exit 1
    ;;
esac
