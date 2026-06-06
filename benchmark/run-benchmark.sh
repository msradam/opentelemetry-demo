#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Clean-room memory benchmark: k6 vs Locust load generator.
#
# Brings up a fresh target (the demo frontend) and an OTel collector, then runs
# each load generator configuration in its own fresh container under an
# identical workload (same user count, same task mix, same wait times), and
# samples steady-state memory (RSS) and throughput. Tears everything down at the
# end. Designed to be run by anyone to independently confirm the numbers.
#
# Usage:
#   ./benchmark/run-benchmark.sh
#
# Override defaults via env, e.g. USERS=10 WARMUP=120 ./benchmark/run-benchmark.sh
set -euo pipefail

cd "$(dirname "$0")/.."

USERS="${USERS:-5}"
# 120s so browser scenarios fully ramp Chromium; shorter warmups badly
# under-measure Locust's browser memory (it spawns Chromium lazily per user).
WARMUP="${WARMUP:-120}"        # seconds to reach steady state before sampling
SAMPLES="${SAMPLES:-6}"        # number of memory samples
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-10}"  # seconds between samples
NETWORK="${NETWORK:-opentelemetry-demo}"
TARGET_URL="${TARGET_URL:-http://frontend:8080}"
COLLECTOR="${COLLECTOR:-otel-collector:4317}"
COMPOSE="docker compose -f compose.yaml -f compose.observability.yaml"
RESULTS="benchmark/results.md"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

# Convert a docker-stats memory field (e.g. "34.12MiB" or "1.031GiB") to MiB.
to_mib() {
  local v="$1" num unit
  num="$(printf '%s' "$v" | grep -oE '^[0-9.]+')"
  unit="$(printf '%s' "$v" | grep -oE '[A-Za-z]+$')"
  case "$unit" in
    GiB) awk "BEGIN{printf \"%.0f\", $num*1024}" ;;
    MiB) awk "BEGIN{printf \"%.0f\", $num}" ;;
    KiB) awk "BEGIN{printf \"%.1f\", $num/1024}" ;;
    B)   awk "BEGIN{printf \"%.2f\", $num/1048576}" ;;
    *)   printf '%s' "$num" ;;
  esac
}

# measure <label> <image> <env-args...>
# Runs a load generator, warms up, samples memory, records the average.
measure() {
  local label="$1" image="$2"; shift 2
  local cname="bench-runner"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  log "[$label] starting ($image), warming up ${WARMUP}s"
  docker run -d --name "$cname" --network "$NETWORK" "$@" "$image" >/dev/null
  sleep "$WARMUP"
  if ! docker ps --filter "name=$cname" --format '{{.Names}}' | grep -q "$cname"; then
    echo "  ERROR: $label container exited early; logs:"; docker logs "$cname" 2>&1 | tail -15
    docker rm -f "$cname" >/dev/null 2>&1 || true
    printf '| %-26s | %10s | %12s |\n' "$label" "FAILED" "-" >> "$RESULTS"
    return
  fi
  local total=0 n=0
  for _ in $(seq 1 "$SAMPLES"); do
    local mem; mem="$(docker stats --no-stream --format '{{.MemUsage}}' "$cname" | awk '{print $1}')"
    mem="$(to_mib "$mem")"
    total="$(awk "BEGIN{print $total + $mem}")"; n=$((n+1))
    sleep "$SAMPLE_INTERVAL"
  done
  local avg; avg="$(awk "BEGIN{printf \"%.0f\", $total/$n}")"
  # Throughput: k6 prints "<n> complete" iterations; Locust we report n/a here
  # (workload is identical by construction: same users, task weights, waits).
  local thru="see note"
  local k6iters; k6iters="$(docker logs "$cname" 2>&1 | grep -oE '[0-9]+ complete' | tail -1 | grep -oE '[0-9]+' || true)"
  [ -n "${k6iters:-}" ] && thru="${k6iters} iters"
  log "[$label] avg memory: ${avg} MiB"
  printf '| %-26s | %8s MiB | %12s |\n' "$label" "$avg" "$thru" >> "$RESULTS"
  docker rm -f "$cname" >/dev/null 2>&1 || true
}

# --- Build images -----------------------------------------------------------
log "Building k6 load generator (slim, from src/load-generator/Dockerfile)"
docker build -q -f src/load-generator/Dockerfile -t bench-k6:slim . >/dev/null
log "Building k6 load generator (with embedded Chromium, benchmark only)"
docker build -q -f benchmark/Dockerfile.k6-browser \
  --build-arg K6_IMAGE=bench-k6:slim -t bench-k6:browser benchmark/ >/dev/null

# Locust comparator: build the current main load generator from a worktree so
# the comparison is reproducible from this repo alone. Override with LOCUST_IMAGE.
LOCUST_IMAGE="${LOCUST_IMAGE:-bench-locust:main}"
if [ "$LOCUST_IMAGE" = "bench-locust:main" ]; then
  WT="$(mktemp -d)/main"
  log "Building Locust comparator from 'main' worktree"
  git worktree add -q -f "$WT" main
  ( cd "$WT" && docker build -q -f src/load-generator/Dockerfile -t bench-locust:main . >/dev/null )
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
fi

# --- Fresh target -----------------------------------------------------------
log "Bringing up a fresh target (frontend) and collector"
$COMPOSE up -d --force-recreate --no-deps otel-collector frontend >/dev/null
sleep 10

# --- Results header ---------------------------------------------------------
{
  echo "# Load generator memory benchmark"
  echo
  echo "Users/VUs: ${USERS} | warmup: ${WARMUP}s | samples: ${SAMPLES} x ${SAMPLE_INTERVAL}s | target: ${TARGET_URL}"
  echo
  echo "| Configuration | Avg memory | Throughput |"
  echo "| --- | ---: | --- |"
} > "$RESULTS"

# --- Scenarios --------------------------------------------------------------
# k6 HTTP-only (the proposed default)
measure "k6 (HTTP)" bench-k6:slim \
  -e LOADGEN_HOST="$TARGET_URL" -e LOADGEN_VUS="$USERS" \
  -e LOADGEN_TRACING_ENDPOINT="$COLLECTOR" \
  -e K6_OTEL_GRPC_EXPORTER_ENDPOINT="$COLLECTOR" -e K6_OTEL_GRPC_EXPORTER_INSECURE=true \
  -e K6_OTEL_SERVICE_NAME=load-generator -e K6_OUT=opentelemetry

# Locust HTTP-only
measure "Locust (HTTP)" "$LOCUST_IMAGE" \
  -e LOCUST_HOST="$TARGET_URL" -e LOCUST_USERS="$USERS" -e LOCUST_SPAWN_RATE="$USERS" \
  -e LOCUST_HEADLESS=true -e LOCUST_AUTOSTART=true -e LOCUST_BROWSER_TRAFFIC_ENABLED=false \
  -e OTEL_EXPORTER_OTLP_ENDPOINT="http://$COLLECTOR" -e OTEL_SERVICE_NAME=load-generator \
  -e PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

# Locust browser-on (the demo's current default)
measure "Locust (browser, default)" "$LOCUST_IMAGE" \
  -e LOCUST_HOST="$TARGET_URL" -e LOCUST_USERS="$USERS" -e LOCUST_SPAWN_RATE="$USERS" \
  -e LOCUST_HEADLESS=true -e LOCUST_AUTOSTART=true -e LOCUST_BROWSER_TRAFFIC_ENABLED=true \
  -e OTEL_EXPORTER_OTLP_ENDPOINT="http://$COLLECTOR" -e OTEL_SERVICE_NAME=load-generator \
  -e PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

# k6 browser-on (embedded Chromium; full functionality parity)
# K6_BROWSER_ARGS=no-sandbox because the image runs as root.
measure "k6 (browser, embedded)" bench-k6:browser \
  -e LOADGEN_HOST="$TARGET_URL" -e LOADGEN_VUS="$USERS" \
  -e LOADGEN_BROWSER_TRAFFIC_ENABLED=true -e LOADGEN_BROWSER_VUS=1 \
  -e K6_BROWSER_HEADLESS=true -e K6_BROWSER_ARGS=no-sandbox \
  -e LOADGEN_TRACING_ENDPOINT="$COLLECTOR" \
  -e K6_OTEL_GRPC_EXPORTER_ENDPOINT="$COLLECTOR" -e K6_OTEL_GRPC_EXPORTER_INSECURE=true \
  -e K6_OTEL_SERVICE_NAME=load-generator -e K6_OUT=opentelemetry

# --- Image sizes ------------------------------------------------------------
{
  echo
  echo "Image sizes:"
  echo '```'
  docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E "bench-k6:slim|bench-k6:browser|$LOCUST_IMAGE" || true
  echo '```'
  echo
  echo "Note: throughput is reported where the engine prints it; the offered load"
  echo "is identical by construction (same user count, task weights, and wait"
  echo "times). Production browser traffic should offload Chromium to a separate"
  echo "capped container via crocochrome + K6_BROWSER_WS_URL rather than embedding"
  echo "it; the embedded-Chromium k6 row exists only for an equal-footing compare."
} >> "$RESULTS"

log "Done. Results written to $RESULTS:"
echo
cat "$RESULTS"

# --- Teardown ---------------------------------------------------------------
if [ "${KEEP_TARGET:-0}" != "1" ]; then
  log "Tearing down target"
  $COMPOSE rm -sf otel-collector frontend >/dev/null 2>&1 || true
fi
