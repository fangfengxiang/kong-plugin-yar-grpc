#!/usr/bin/env bash
# run_kong_e2e.sh — Kong integration e2e total entry
#
# Runs the REAL Kong Gateway (DB-less) with the yar_grpc_bridge plugin bound to
# routes via declarative config (kong.yml). Exercises Kong's own paths:
#   - config schema validation (schema.lua called at declarative load time)
#   - DB-less declarative config load (KONG_DATABASE=off)
#   - router matching (services/routes by protocol + path)
#   - plugin binding to routes (access phase triggered)
#
# Scenario 2: Go gRPC  -> Kong (grpc2yar) -> PHP Yar
# Scenario 1: PHP Yar  -> Kong (yar2grpc) -> Go gRPC
#
# Reuses t/e2e/ proto + Go server/client + PHP server/client assets.
# Go binaries + .pb are pre-built into the Docker image (Stage 1 builder);
# when running locally (no Docker), they are built on first run.
set -euo pipefail

D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../.." && pwd)"
RUN="$D/.run"
LOG="$RUN/logs"
BIN="$RUN/bin"
mkdir -p "$RUN" "$LOG" "$BIN"

# e2e ports (container-internal; Kong proxy is fixed at 8000)
export E2E_PORT_PHP="${E2E_PORT_PHP:-8888}"
export E2E_PORT_GO_GRPC="${E2E_PORT_GO_GRPC:-50051}"
export E2E_PORT_GO_HTTP="${E2E_PORT_GO_HTTP:-50052}"
export E2E_PORT_KONG="${E2E_PORT_KONG:-8000}"
# PHP Yar client reads E2E_PORT_KONG_YAR2GRPC env to find Kong proxy
export E2E_PORT_KONG_YAR2GRPC="${E2E_PORT_KONG}"

C() { printf '\033[0;36m[kong-integration]\033[0m %s\n' "$1"; }
P() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
F() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

# ── Dependency checks (strict: missing -> FAIL, no skip) ──
C "checking deps..."
command -v kong >/dev/null || F "kong not found"
command -v php >/dev/null || F "php not found"
php -m 2>/dev/null | grep -qx "yar" \
    || F "php-yar ext missing (install: pecl install yar -- --enable-msgpack)"
php -m 2>/dev/null | grep -qx "msgpack" \
    || F "php-msgpack ext missing (required for msgpack scenario)"

# ── Dependency versions ──
C "dependency versions:"
kong version 2>&1 | head -1
php -v 2>/dev/null | head -1

# ── proto generation (skipped when pre-built in Docker image) ──
if [ ! -f "$ROOT/t/e2e/proto/calculator.pb" ]; then
    command -v protoc >/dev/null || F "protoc not found (needed for proto generation)"
    C "generating proto..."
    bash "$ROOT/t/e2e/proto/gen.sh"
fi

# ── Go compilation (skipped when pre-built in Docker image) ──
if [ ! -x "$BIN/grpc_server" ] || [ ! -x "$BIN/grpc_client" ]; then
    command -v go >/dev/null || F "go not found (needed for building grpc binaries)"
    C "building Go binaries -> $BIN/ ..."
    cd "$ROOT/t/e2e/go"
    go build -buildvcs=false -o "$BIN/grpc_server" ./grpc_server || F "server build failed"
    go build -buildvcs=false -o "$BIN/grpc_client" ./grpc_client || F "client build failed"
    cd "$ROOT"
fi

# ── Loop over both YAR packagers ──
for PACKAGER in json msgpack; do
    export YAR_PACKAGER="$PACKAGER"

    echo ""
    C "=== Scenario 2: Go gRPC -> Kong -> PHP Yar ($PACKAGER) ==="
    bash "$D/scenario_kong_grpc2yar.sh"

    echo ""
    C "=== Scenario 1: PHP Yar -> Kong -> Go gRPC ($PACKAGER) ==="
    bash "$D/scenario_kong_yar2grpc.sh"
done

echo ""
P "All Kong integration e2e tests completed."
echo "  logs:      $LOG/"
echo "  binaries:  $BIN/"
