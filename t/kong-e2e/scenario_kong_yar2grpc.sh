#!/usr/bin/env bash
# scenario_kong_yar2grpc.sh — Kong integration: PHP Yar -> Kong -> Go gRPC
#
# Starts Go gRPC server + Kong (DB-less, yar2grpc route bound), runs PHP Yar
# client. Also checks the 404 path (unregistered service -> router matches /api,
# plugin returns 404 + "service not registered").
#
# Pattern follows apisix scenario1_yar2grpc.sh + bridge scenario1_yar2grpc.sh:
#   - `kong start` synchronous + exit code check (no 30x1s polling).
#   - readiness probe: 30x0.5s ceiling.
#   - PHP client output captured -> grep "Scenario 1.*PASS" asserts.
#   - 404 path: curl HTTP code + body grep asserts.
set -euo pipefail

D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../.." && pwd)"
RUN="$D/.run"
LOG="$RUN/logs"
BIN="$RUN/bin"
PACKAGER="${YAR_PACKAGER:-json}"

C() { printf '\033[0;36m[kong-yar2grpc/%s]\033[0m %s\n' "$PACKAGER" "$1"; }
P() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
F() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

cleanup() {
    C "cleaning up..."
    kong stop 2>/dev/null || true
    [ -f "$RUN/go_kong_s1_${PACKAGER}.pid" ] && kill "$(cat "$RUN/go_kong_s1_${PACKAGER}.pid")" 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT

# ── Generate kong.yml (replace placeholders) ──
C "preparing kong.yml (packager=$PACKAGER)..."
sed -e "s|@PACKAGER@|$PACKAGER|g" \
    -e "s|@PORT_PHP@|${E2E_PORT_PHP}|g" \
    -e "s|@PORT_GO_HTTP@|${E2E_PORT_GO_HTTP}|g" \
    "$D/kong.yml" > "$RUN/kong_yar2grpc_${PACKAGER}.yml"

# ── Start Go gRPC server (gRPC + HTTP bridge) ──
C "starting Go gRPC server (gRPC :${E2E_PORT_GO_GRPC}, HTTP :${E2E_PORT_GO_HTTP})..."
"$BIN/grpc_server" -addr 127.0.0.1:${E2E_PORT_GO_GRPC} \
    -http-addr 127.0.0.1:${E2E_PORT_GO_HTTP} >"$LOG/go_kong_s1_${PACKAGER}.log" 2>&1 &
echo $! > "$RUN/go_kong_s1_${PACKAGER}.pid"

# ── Start Kong (DB-less) ──
# Launched in the BACKGROUND (same reason as scenario_kong_grpc2yar.sh: the
# resty wrapper process may not exit cleanly inside Docker, so a synchronous
# `kong start` can block forever. The admin API readiness probe below detects
# actual readiness; a malformed config -> workers never start -> probe times
# out -> FAIL with the log path).
C "starting Kong (proxy :${E2E_PORT_KONG}, DB-less)..."
export KONG_DATABASE=off
export KONG_PLUGINS=bundled,yar_grpc_bridge
export KONG_DECLARATIVE_CONFIG="$RUN/kong_yar2grpc_${PACKAGER}.yml"
export KONG_PROXY_LISTEN="0.0.0.0:${E2E_PORT_KONG} http2"
export KONG_ADMIN_LISTEN="127.0.0.1:8001"
kong start >>"$LOG/kong_s1_${PACKAGER}.log" 2>&1 &

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
[ "$ready" = "yes" ] || F "Kong admin API not responding within 15s (see $LOG/kong_s1_${PACKAGER}.log)"
C "Kong is ready"

# ── Run PHP Yar client -> Kong ──
C "running PHP Yar client (packager=$PACKAGER)..."
OUT="$LOG/kong_s1_${PACKAGER}_result.log"
if php -d yar.packager="$PACKAGER" -d zend.assertions=1 -d assert.exception=1 \
    "$ROOT/t/e2e/php/yar_client/client.php" 2>&1 | tee "$OUT"; then
    if grep -q "Scenario 1.*PASS" "$OUT"; then
        P "Kong yar2grpc ($PACKAGER): PASS"
    else
        F "Kong yar2grpc ($PACKAGER): FAIL (assertion markers not found in output)"
    fi
else
    F "Kong yar2grpc ($PACKAGER): FAIL (client exited non-zero; see $OUT)"
fi

# ── 404 path: unregistered service (router matches /api, plugin returns 404) ──
C "checking 404 path (unregistered service)..."
ERR_FILE="$LOG/kong_s1_${PACKAGER}_404_body.txt"
HTTP_CODE=$(curl -s -o "$ERR_FILE" -w "%{http_code}" -X POST \
    http://127.0.0.1:${E2E_PORT_KONG}/api/nonexistent.Service)
ERR_BODY="$(cat "$ERR_FILE")"
if [ "$HTTP_CODE" = "404" ] && echo "$ERR_BODY" | grep -q "service not registered"; then
    P "404 path: PASS (router matched /api, plugin returned 404 + correct message)"
else
    F "404 path: FAIL (expected 404 + 'service not registered', got $HTTP_CODE: $ERR_BODY)"
fi
