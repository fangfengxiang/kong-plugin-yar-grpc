#!/usr/bin/env bash
# scenario_kong_grpc2yar.sh — Kong integration: Go gRPC -> Kong -> PHP Yar
#
# Starts PHP Yar server + Kong (DB-less, grpc2yar route bound), runs Go gRPC
# client. Exercises: Kong declarative config load, router matching (grpc
# protocol, path /), plugin binding (access phase -> handler:access).
#
# Pattern follows apisix scenario2_grpc2yar.sh:
#   - `kong start` runs synchronously (daemon mode: starts nginx, exits 0).
#     Failure -> immediate FAIL with log path. No 30x1s polling loop.
#   - readiness probe: curl admin /status, 30x0.5s = 15s ceiling (apisix pattern).
#   - Go client output captured -> grep "Add: PASS" + "Subtract: PASS" asserts.
set -euo pipefail

D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../.." && pwd)"
RUN="$D/.run"
LOG="$RUN/logs"
BIN="$RUN/bin"
PACKAGER="${YAR_PACKAGER:-json}"

C() { printf '\033[0;36m[kong-grpc2yar/%s]\033[0m %s\n' "$PACKAGER" "$1"; }
P() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
F() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

cleanup() {
    C "cleaning up..."
    kong stop 2>/dev/null || true
    [ -f "$RUN/php_kong_s2_${PACKAGER}.pid" ] && kill "$(cat "$RUN/php_kong_s2_${PACKAGER}.pid")" 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT

# ── Generate kong.yml (replace placeholders) ──
C "preparing kong.yml (packager=$PACKAGER)..."
sed -e "s|@PACKAGER@|$PACKAGER|g" \
    -e "s|@PORT_PHP@|${E2E_PORT_PHP}|g" \
    -e "s|@PORT_GO_HTTP@|${E2E_PORT_GO_HTTP}|g" \
    "$D/kong.yml" > "$RUN/kong_grpc2yar_${PACKAGER}.yml"

# ── Start PHP Yar server (backend for grpc2yar) ──
C "starting PHP Yar server (port ${E2E_PORT_PHP}, packager=$PACKAGER)..."
php -d yar.packager="$PACKAGER" -S 127.0.0.1:${E2E_PORT_PHP} \
    -t "$ROOT/t/e2e/php/yar_server" >"$LOG/php_kong_s2_${PACKAGER}.log" 2>&1 &
echo $! > "$RUN/php_kong_s2_${PACKAGER}.pid"

# ── Start Kong (DB-less, loads kong.yml -> schema validation happens here) ──
# `kong start` is launched in the BACKGROUND. On bare metal, daemon mode starts
# nginx workers then the `kong start` process exits 0. Inside Docker the resty
# wrapper process frequently does NOT exit cleanly (nginx workers launch fine,
# declarative config loads, but the perl/resty wrapper hangs), so a synchronous
# `kong start` would block forever. Starting it in the background and relying on
# the admin API readiness probe below to determine success avoids that hang. If
# the config is malformed (schema violation) the workers never start, the admin
# API never binds, and the probe times out -> FAIL with the log path, so the
# failure is still surfaced at first occurrence.
C "starting Kong (proxy :${E2E_PORT_KONG}, DB-less)..."
export KONG_DATABASE=off
export KONG_PLUGINS=bundled,yar_grpc_bridge
export KONG_DECLARATIVE_CONFIG="$RUN/kong_grpc2yar_${PACKAGER}.yml"
export KONG_PROXY_LISTEN="0.0.0.0:${E2E_PORT_KONG} http2"
export KONG_ADMIN_LISTEN="127.0.0.1:8001"
kong start >>"$LOG/kong_s2_${PACKAGER}.log" 2>&1 &

# ── Readiness probe (apisix pattern: 30 x 0.5s = 15s ceiling) ──
C "waiting for Kong admin API..."
ready=no
for _ in $(seq 1 30); do
    if curl -sf -o /dev/null http://127.0.0.1:8001/status 2>/dev/null; then
        ready=yes
        break
    fi
    sleep 0.5
done
[ "$ready" = "yes" ] || F "Kong admin API not responding within 15s (see $LOG/kong_s2_${PACKAGER}.log)"
C "Kong is ready"

# ── Run Go gRPC client -> Kong ──
C "running Go gRPC client -> Kong:${E2E_PORT_KONG}..."
OUT="$LOG/kong_s2_${PACKAGER}_result.log"
if "$BIN/grpc_client" -addr 127.0.0.1:${E2E_PORT_KONG} 2>&1 | tee "$OUT"; then
    if grep -q "Add: PASS" "$OUT" && grep -q "Subtract: PASS" "$OUT"; then
        P "Kong grpc2yar ($PACKAGER): PASS"
    else
        F "Kong grpc2yar ($PACKAGER): FAIL (assertion markers not found in output)"
    fi
else
    F "Kong grpc2yar ($PACKAGER): FAIL (client exited non-zero; see $OUT)"
fi
