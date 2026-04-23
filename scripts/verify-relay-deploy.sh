#!/usr/bin/env bash
# verify-relay-deploy.sh — Pre/post-deploy smoke check for the
# Horcrux WebSocket relay.
#
# Exercises every public HTTP surface the relay exposes and prints a
# PASS/FAIL summary so an operator can gate a production deploy on
# a single exit code. Covers:
#
#   1. GET /health — 200, status=ok, version matches local crate
#      (when --expect-version is passed or running inside the repo).
#   2. GET /metrics — rejects an unauthenticated request (admin-
#      only), accepts a request carrying the expected admin token
#      when --admin-token is provided, and the returned body is
#      valid Prometheus text-exposition format.
#   3. GET /admin/rooms — same admin-token enforcement.
#   4. GET /ws/smoke-$RANDOM — WebSocket upgrade (101 Switching
#      Protocols) with a correctly computed Sec-WebSocket-Accept.
#   5. TLS negotiation (https:// URLs only) — rejects expired /
#      name-mismatched / self-signed certificates AND rejects TLS
#      versions below 1.2 (TLS 1.0 / 1.1 / SSLv3 must be disabled
#      server-side).
#   6. HSTS header (https:// URLs only) — Strict-Transport-Security
#      is present with a max-age of at least 6 months.
#
# Usage:
#   scripts/verify-relay-deploy.sh <base-url> [--admin-token TOKEN]
#                                             [--expect-version V]
#                                             [--skip-admin]
#
# Examples:
#   scripts/verify-relay-deploy.sh https://relay.horcrux.app
#   scripts/verify-relay-deploy.sh http://localhost:3000 --admin-token devtoken
#
# Exit codes:
#   0 — all checks pass
#   1 — at least one check failed
#   2 — usage error (bad args / missing dependency)

set -u -o pipefail

# ---------- arg parsing ----------
BASE_URL=""
ADMIN_TOKEN=""
EXPECT_VERSION=""
SKIP_ADMIN=0

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --admin-token)    ADMIN_TOKEN="${2:-}"; shift 2 ;;
        --admin-token=*)  ADMIN_TOKEN="${1#*=}"; shift ;;
        --expect-version) EXPECT_VERSION="${2:-}"; shift 2 ;;
        --expect-version=*) EXPECT_VERSION="${1#*=}"; shift ;;
        --skip-admin)     SKIP_ADMIN=1; shift ;;
        -h|--help)        usage ;;
        http://*|https://*) BASE_URL="$1"; shift ;;
        *) echo "error: unrecognised argument: $1" >&2; usage ;;
    esac
done

[[ -n "$BASE_URL" ]] || { echo "error: base URL required" >&2; usage; }
BASE_URL="${BASE_URL%/}"

for cmd in curl awk sed; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "error: required command '$cmd' not found on PATH" >&2
        exit 2
    }
done

# openssl is optional — only used for WS handshake and TLS check.
HAS_OPENSSL=0
command -v openssl >/dev/null 2>&1 && HAS_OPENSSL=1

# If --expect-version is not explicitly set, try to infer it from
# the relay crate Cargo.toml so running this script from the repo
# root catches version drift automatically.
if [[ -z "$EXPECT_VERSION" && -f "$(dirname "$0")/../horcrux-relay/Cargo.toml" ]]; then
    EXPECT_VERSION=$(awk -F '"' '/^version/ { print $2; exit }' \
        "$(dirname "$0")/../horcrux-relay/Cargo.toml" 2>/dev/null || true)
fi

# ---------- helpers ----------
PASS=0
FAIL=0

ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '\033[31m  ✗ %s\033[0m\n' "$*"; FAIL=$((FAIL + 1)); }
step() { printf '\n\033[1m→ %s\033[0m\n' "$*"; }

# ---------- 1. /health ----------
step "GET /health"
HEALTH_BODY=$(curl --silent --show-error --max-time 10 --fail \
    "$BASE_URL/health" 2>/dev/null || true)
if [[ -z "$HEALTH_BODY" ]]; then
    bad "request failed or returned non-2xx"
else
    if echo "$HEALTH_BODY" | grep -q '"status":"ok"'; then
        ok "status=ok"
    else
        bad "status field missing or not 'ok'"
    fi
    REPORTED_VERSION=$(echo "$HEALTH_BODY" \
        | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
    if [[ -n "$REPORTED_VERSION" ]]; then
        ok "reports version $REPORTED_VERSION"
        if [[ -n "$EXPECT_VERSION" && "$REPORTED_VERSION" != "$EXPECT_VERSION" ]]; then
            bad "version mismatch — deployed: $REPORTED_VERSION, expected: $EXPECT_VERSION"
        elif [[ -n "$EXPECT_VERSION" ]]; then
            ok "version matches expected ($EXPECT_VERSION)"
        fi
    else
        bad "no version field in /health payload"
    fi
fi

# ---------- 2. /metrics admin enforcement ----------
if [[ $SKIP_ADMIN -eq 0 ]]; then
    step "GET /metrics (without admin token)"
    STATUS=$(curl --silent --max-time 10 -o /dev/null -w '%{http_code}' \
        "$BASE_URL/metrics" 2>/dev/null || echo 000)
    case "$STATUS" in
        401|403) ok "rejects anonymous request ($STATUS)" ;;
        200)
            # Relay only enforces admin-token when the token env var
            # is set. A 200 here is only acceptable in dev/test,
            # never in production — flag as FAIL so prod deploys
            # cannot land a relay with metrics exposed.
            bad "metrics endpoint is reachable without admin token (HTTP 200) — production relay must set HORCRUX_RELAY_ADMIN_TOKEN" ;;
        *) bad "unexpected status: $STATUS (expected 401/403)" ;;
    esac

    if [[ -n "$ADMIN_TOKEN" ]]; then
        step "GET /metrics (with admin token)"
        METRICS_TMP=$(mktemp 2>/dev/null || mktemp -t metrics)
        STATUS=$(curl --silent --max-time 10 -o "$METRICS_TMP" -w '%{http_code}' \
            -H "X-Admin-Token: $ADMIN_TOKEN" \
            "$BASE_URL/metrics" 2>/dev/null || echo 000)
        if [[ "$STATUS" == "200" ]]; then
            ok "admin-token accepted"
            # Prometheus text-exposition format sanity check:
            #   - at least one '# HELP <name> <text>' line
            #   - at least one '# TYPE <name> (counter|gauge|histogram|summary|untyped)' line
            #   - at least one non-comment sample line of shape
            #     '<name>{...} <float>' or '<name> <float>'.
            HELP_LINES=$(grep -c '^# HELP ' "$METRICS_TMP" 2>/dev/null || echo 0)
            TYPE_LINES=$(grep -c '^# TYPE ' "$METRICS_TMP" 2>/dev/null || echo 0)
            # Sample lines: start with [a-zA-Z_:], end with a number
            # (possibly with fractional/scientific parts or timestamps).
            SAMPLE_LINES=$(grep -cE '^[a-zA-Z_:][a-zA-Z0-9_:]*(\{[^}]*\})?[[:space:]]+[-+0-9eE.NaIinf]+([[:space:]]+[0-9]+)?[[:space:]]*$' \
                "$METRICS_TMP" 2>/dev/null || echo 0)
            if [[ "$HELP_LINES" -ge 1 && "$TYPE_LINES" -ge 1 && "$SAMPLE_LINES" -ge 1 ]]; then
                ok "Prometheus exposition format valid (HELP=$HELP_LINES TYPE=$TYPE_LINES samples=$SAMPLE_LINES)"
            else
                bad "not valid Prometheus exposition (HELP=$HELP_LINES TYPE=$TYPE_LINES samples=$SAMPLE_LINES)"
            fi
            # Spot-check for a handful of metrics we expect the
            # relay to always export. Missing any of these usually
            # means the relay was built with a feature flag off.
            for expected in \
                horcrux_relay_active_rooms \
                horcrux_relay_active_connections \
                horcrux_relay_messages_total
            do
                if grep -q "^# TYPE $expected " "$METRICS_TMP"; then
                    ok "exports metric: $expected"
                else
                    bad "missing expected metric: $expected"
                fi
            done
        else
            bad "admin-token rejected (HTTP $STATUS) — token wrong or relay mis-configured"
        fi
        rm -f "$METRICS_TMP"
    fi

    step "GET /admin/rooms (without admin token)"
    STATUS=$(curl --silent --max-time 10 -o /dev/null -w '%{http_code}' \
        "$BASE_URL/admin/rooms" 2>/dev/null || echo 000)
    case "$STATUS" in
        401|403) ok "rejects anonymous request ($STATUS)" ;;
        200)    bad "admin/rooms reachable without admin token — set HORCRUX_RELAY_ADMIN_TOKEN" ;;
        *)      bad "unexpected status: $STATUS (expected 401/403)" ;;
    esac
fi

# ---------- 3. WebSocket upgrade ----------
step "GET /ws/:room_id (WebSocket upgrade)"
WS_ROOM="smoke-$RANDOM-$$"
WS_DEVICE="smoke-device-$$"
WS_PATH="/ws/$WS_ROOM?device_id=$WS_DEVICE"
if [[ $HAS_OPENSSL -eq 1 ]]; then
    WS_KEY=$(openssl rand -base64 16)
    HEADERS=$(curl --silent --max-time 10 --include \
        -H "Connection: Upgrade" \
        -H "Upgrade: websocket" \
        -H "Sec-WebSocket-Version: 13" \
        -H "Sec-WebSocket-Key: $WS_KEY" \
        "$BASE_URL$WS_PATH" 2>/dev/null || true)
    if echo "$HEADERS" | head -1 | grep -q '101'; then
        ok "server returned 101 Switching Protocols"
        # Verify Sec-WebSocket-Accept matches RFC 6455 derivation.
        EXPECTED=$(printf '%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11' "$WS_KEY" \
            | openssl dgst -sha1 -binary | openssl base64)
        ACTUAL=$(echo "$HEADERS" \
            | awk -F': ' 'tolower($1)=="sec-websocket-accept"{gsub(/\r/,"",$2);print $2}')
        if [[ "$ACTUAL" == "$EXPECTED" ]]; then
            ok "Sec-WebSocket-Accept is RFC-6455 correct"
        else
            bad "Sec-WebSocket-Accept mismatch (got '$ACTUAL', expected '$EXPECTED')"
        fi
    else
        FIRST_LINE=$(echo "$HEADERS" | head -1 | tr -d '\r')
        bad "WebSocket upgrade failed — first response line: ${FIRST_LINE:-<empty>}"
    fi
else
    echo "  (openssl missing — skipping Sec-WebSocket-Accept verification)"
    STATUS=$(curl --silent --max-time 10 -o /dev/null -w '%{http_code}' \
        -H "Connection: Upgrade" \
        -H "Upgrade: websocket" \
        -H "Sec-WebSocket-Version: 13" \
        -H "Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==" \
        "$BASE_URL$WS_PATH" 2>/dev/null || echo 000)
    if [[ "$STATUS" == "101" ]]; then
        ok "server returned 101 Switching Protocols"
    else
        bad "WebSocket upgrade failed — HTTP $STATUS"
    fi
fi

# ---------- 4. TLS certificate check (https only) ----------
if [[ "$BASE_URL" == https://* ]]; then
    step "TLS certificate validity"
    STATUS=$(curl --silent --max-time 10 -o /dev/null -w '%{http_code}' \
        "$BASE_URL/health" 2>/dev/null || echo 000)
    if [[ "$STATUS" == "200" ]]; then
        ok "certificate is trusted by system CA store"
    else
        # Retry with -k to distinguish "cert invalid" from "server down".
        STATUS_INSECURE=$(curl --silent --max-time 10 --insecure \
            -o /dev/null -w '%{http_code}' \
            "$BASE_URL/health" 2>/dev/null || echo 000)
        if [[ "$STATUS_INSECURE" == "200" ]]; then
            bad "TLS handshake failed — certificate is untrusted, expired, or name-mismatched"
        else
            bad "TLS handshake failed and server did not respond on -k retry (HTTP $STATUS_INSECURE)"
        fi
    fi

    # ---------- 4a. Minimum TLS version ----------
    step "TLS minimum version (reject <1.2)"
    # Probe with --tls-max 1.1 — a properly configured server MUST
    # refuse the handshake, so curl exits non-zero.
    if curl --silent --max-time 10 --tls-max 1.1 -o /dev/null \
        "$BASE_URL/health" 2>/dev/null; then
        bad "server accepted TLS 1.1 or lower (TLS 1.2+ must be enforced)"
    else
        ok "server refuses TLS 1.1 and below"
    fi
    # Positive check that TLS 1.2 or 1.3 is the actual negotiated
    # version.
    if command -v openssl >/dev/null 2>&1; then
        HOST_PORT=$(echo "$BASE_URL" | sed -E 's|^https?://||; s|/.*$||')
        case "$HOST_PORT" in *:*) : ;; *) HOST_PORT="$HOST_PORT:443" ;; esac
        TLS_INFO=$(echo | openssl s_client -connect "$HOST_PORT" \
            -servername "${HOST_PORT%%:*}" -brief 2>&1 | head -20 || true)
        TLS_VER=$(echo "$TLS_INFO" \
            | awk -F': ' '/^Protocol[[:space:]]*:/{print $2; exit} /Protocol version:/{print $2; exit}' \
            | tr -d ' \r\n')
        case "$TLS_VER" in
            TLSv1.2|TLSv1.3) ok "negotiated $TLS_VER" ;;
            "") echo "  (openssl probe returned no Protocol line — skipping)" ;;
            *) bad "server negotiated $TLS_VER (expected TLSv1.2 or TLSv1.3)" ;;
        esac
    fi

    # ---------- 4b. HSTS header ----------
    step "Strict-Transport-Security header"
    HSTS=$(curl --silent --max-time 10 --include -o - \
        "$BASE_URL/health" 2>/dev/null \
        | awk -F': ' 'tolower($1)=="strict-transport-security"{gsub(/\r/,"",$2);print $2; exit}')
    if [[ -z "$HSTS" ]]; then
        bad "Strict-Transport-Security header missing on /health response"
    else
        MAX_AGE=$(echo "$HSTS" | sed -n 's/.*max-age=\([0-9][0-9]*\).*/\1/p')
        # Six months in seconds.
        MIN_MAX_AGE=15552000
        if [[ -z "$MAX_AGE" ]]; then
            bad "HSTS header present but missing max-age directive: '$HSTS'"
        elif (( MAX_AGE < MIN_MAX_AGE )); then
            bad "HSTS max-age=$MAX_AGE is below 6-month floor ($MIN_MAX_AGE)"
        else
            ok "HSTS present with max-age=$MAX_AGE ($(( MAX_AGE / 86400 )) days)"
        fi
    fi
fi

# ---------- summary ----------
echo
echo "─────────────────────────────────────────"
printf "Results: \033[32m%d passed\033[0m, " "$PASS"
if [[ $FAIL -gt 0 ]]; then
    printf "\033[31m%d failed\033[0m\n" "$FAIL"
    echo "─────────────────────────────────────────"
    exit 1
fi
printf "\033[32m0 failed\033[0m\n"
echo "─────────────────────────────────────────"
exit 0
