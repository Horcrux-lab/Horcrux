#!/usr/bin/env bash
#
# Probe every concrete RPC endpoint shipped in NetworkConfig.swift and
# report which ones are dead.
#
# Why this exists: on 2026-07-29 a manual sweep found six endpoints in the
# fallback tables were dead — five of them LlamaRPC, which had been the
# *first* fallback for Ethereum, Polygon, Arbitrum, Base and Optimism. The
# table had rotted silently for months because nothing watched it. Purging
# it once without automating the check would just reset the clock.
#
# The endpoint list is parsed out of the Swift source rather than
# duplicated here, so this script cannot drift from what the app ships.
#
# Run this from CI, not just from a laptop, before trusting a new endpoint.
# Within minutes of the first sweep it caught three freshly-added 1rpc.io
# URLs that answer residential clients but return "unknown network" to
# datacenter egress. A local check would have passed them. Many wallet
# users reach the internet through commercial VPNs, which look exactly
# like the CI runner, so a laptop is not a representative vantage point.
#
# Usage:
#   scripts/probe-rpc-endpoints.sh            # probe all, report, exit 1 on any failure
#   scripts/probe-rpc-endpoints.sh --quiet    # only print failures
#
# Exit codes: 0 = all endpoints answered, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/ios/Horcrux/Core/NetworkConfig.swift"
TIMEOUT="${PROBE_TIMEOUT:-10}"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

if [ ! -f "$CONFIG" ]; then
  echo "error: cannot find $CONFIG" >&2
  exit 2
fi

# Extract concrete endpoints. Two exclusions:
#   - `{KEY}` provider templates, which need an API key we don't have.
#   - the `deadEthereum` migration set, whose entries are dead on purpose —
#     they exist so users stored on them get reset to a working default.
extract_endpoints() {
  awk '
    /let deadEthereum: Set<String> = \[/ { skip = 1 }
    skip && /^[[:space:]]*\]/          { skip = 0; next }
    !skip                              { print }
  ' "$CONFIG" \
    | grep -o '"https://[^"]*"' \
    | tr -d '"' \
    | grep -v '{KEY}' \
    | sort -u
}

# An endpoint is healthy if it answers *any* of the API shapes we use.
# Trying all four rather than classifying by hostname keeps the script from
# reporting false failures when a URL doesn't match our naming guesses.
probe() {
  local url="$1" body

  # EVM JSON-RPC
  body=$(curl -sS --max-time "$TIMEOUT" -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "$url" 2>/dev/null)
  case "$body" in *'"result":"0x'*) return 0 ;; esac

  # Solana JSON-RPC
  body=$(curl -sS --max-time "$TIMEOUT" -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"getSlot"}' "$url" 2>/dev/null)
  case "$body" in *'"result":'[0-9]*) return 0 ;; esac

  # Esplora REST (Blockstream / mempool.space / litecoinspace)
  body=$(curl -sS --max-time "$TIMEOUT" "$url/blocks/tip/height" 2>/dev/null)
  case "$body" in ''|*[!0-9]*) ;; *) return 0 ;; esac

  # TRON REST
  body=$(curl -sS --max-time "$TIMEOUT" "$url/wallet/getnowblock" 2>/dev/null)
  case "$body" in *'block_header'*) return 0 ;; esac

  # Nothing answered — surface a fragment of the last response so the
  # failure is diagnosable from CI logs alone.
  LAST_BODY=$(printf '%s' "$body" | tr -d '\n' | cut -c1-120)
  return 1
}

failed=0
total=0
declare -a FAILURES=()

while IFS= read -r url; do
  [ -z "$url" ] && continue
  total=$((total + 1))
  LAST_BODY=""
  start=$(date +%s)
  if probe "$url"; then
    elapsed=$(( $(date +%s) - start ))
    [ "$QUIET" -eq 0 ] && printf '  OK    %2ss  %s\n' "$elapsed" "$url"
  else
    failed=$((failed + 1))
    FAILURES+=("$url")
    printf '  DEAD      %s   %s\n' "$url" "$LAST_BODY"
  fi
done < <(extract_endpoints)

echo
echo "Probed $total endpoints, $failed dead."

if [ "$failed" -gt 0 ]; then
  echo
  echo "Dead endpoints must be removed from RPCFallbacks (and added to the"
  echo "deadEthereum migration set if users could have them stored):"
  for u in "${FAILURES[@]}"; do echo "  - $u"; done
  exit 1
fi
