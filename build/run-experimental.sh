#!/usr/bin/env bash
#
# Run the HOST-built experimental gateway (build/build-experimental.sh) against
# the supporting services from docker compose. The gateway binary runs on the
# host; only mock-llm, inference-sim and jwt-issuer run in compose.
#
# Usage:
#   ./build/run-experimental.sh start   # bring up deps + start the gateway
#   ./build/run-experimental.sh stop    # stop the gateway + the deps
#   ./build/run-experimental.sh status
#
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root
REPO_ROOT="$PWD"

ENV_FILE="$REPO_ROOT/.env"
CONFIG_DIR="$REPO_ROOT/config/praxis"
CONFIG="ratelimit-limitador.yaml"   # bare name; the gateway is run from CONFIG_DIR
PIDFILE="$REPO_ROOT/.gateway-local.pid"
LOGFILE="$REPO_ROOT/gateway-local.log"
DEPS=(inference-sim mock-llm jwt-issuer)   # supporting compose services (NOT the gateway)
METRICS_URL="http://localhost:9901/healthy"

die() { printf "\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }
step() { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }

wait_http() { local url="$1" n="${2:-60}" i=0; until curl -sf "$url" >/dev/null 2>&1; do i=$((i+1)); [ "$i" -ge "$n" ] && return 1; sleep 1; done; }
wait_port() { local h="$1" p="$2" n="${3:-30}" i=0; until (exec 3<>"/dev/tcp/$h/$p") 2>/dev/null; do i=$((i+1)); [ "$i" -ge "$n" ] && return 1; sleep 1; done; exec 3>&- 2>/dev/null || true; }

start() {
  [ -f "$ENV_FILE" ] || die "no .env - run ./build/build-experimental.sh first"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  [ -n "${GATEWAY_BIN:-}" ] && [ -x "$GATEWAY_BIN" ] || die "GATEWAY_BIN not set/executable in .env - re-run build-experimental.sh"

  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    die "gateway already running (pid $(cat "$PIDFILE")); stop it first"
  fi

  step "Starting supporting services (compose): ${DEPS[*]}"
  docker compose up -d "${DEPS[@]}"
  printf "  waiting for jwt-issuer (:8888) and mock-llm (:1080)..."
  wait_http "http://localhost:8888/health" 60 || die "jwt-issuer not healthy on :8888"
  wait_port 127.0.0.1 1080 60 || die "mock-llm not reachable on :1080"
  printf " ok\n"

  step "Starting gateway on the host (from $CONFIG_DIR, so config_path resolves)"
  # nohup exec-replaces itself with the gateway, so $! is the gateway's own pid.
  cd "$CONFIG_DIR"
  nohup "$GATEWAY_BIN" -c "$CONFIG" > "$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  cd "$REPO_ROOT"
  printf "  waiting for gateway health (%s)..." "$METRICS_URL"
  if ! wait_http "$METRICS_URL" 30; then
    printf " FAILED\n"; tail -n 30 "$LOGFILE" >&2 || true
    die "gateway did not become healthy (see $LOGFILE)"
  fi
  printf " ok (pid %s, log %s)\n" "$(cat "$PIDFILE")" "$LOGFILE"
  printf "\n  Gateway: http://localhost:8080   Metrics: http://localhost:9901/metrics\n"
  printf "  Test:    make test   Stop: ./build/run-experimental.sh stop\n"
}

stop() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
    printf "gateway stopped\n"
  else
    printf "no gateway pidfile; nothing to stop\n"
  fi
  step "Stopping supporting services"
  docker compose stop "${DEPS[@]}" 2>/dev/null || true
}

status() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    printf "gateway: running (pid %s)\n" "$(cat "$PIDFILE")"
  else
    printf "gateway: not running\n"
  fi
  docker compose ps "${DEPS[@]}" 2>/dev/null || true
}

case "${1:-}" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  *) die "usage: $0 {start|stop|status}" ;;
esac
