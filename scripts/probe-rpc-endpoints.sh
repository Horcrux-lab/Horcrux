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
# Environment:
#   PROBE_TIMEOUT   per-request timeout in seconds (default 10)
#   PROBE_ATTEMPTS  attempts before an endpoint is called dead (default 3)
#
# Exit codes: 0 = all endpoints answered, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/ios/Horcrux/Core/NetworkConfig.swift"
TIMEOUT="${PROBE_TIMEOUT:-10}"
ATTEMPTS="${PROBE_ATTEMPTS:-3}"
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

# One unanswered request does not mean an endpoint is gone.
#
# This script exists to catch endpoints that have been *decommissioned* —
# LlamaRPC going dark, a Blast API host retired. It was reporting a second,
# different condition under the same name: alive but intermittently
# unreachable. blockstream.info answered 2 of 3 requests from a laptop and
# 0 of 2 from a CI runner within the same fifteen minutes on 2026-07-31,
# and failed the job twice on a PR that had not touched it.
#
# Retrying does not weaken the check it was written for. A decommissioned
# host fails every attempt no matter how many are made, so detection of the
# thing this script is named after is unchanged; only the false positives
# go away. For a host failing a fraction p of requests, the workflow's two
# passes alone leave a p^2 chance of a spurious red — about 11% at p=1/3.
# Three attempts per pass takes that to p^6, roughly 0.1%.
#
# Flakiness is still real information, so it is reported rather than
# swallowed: an endpoint that needed retries is named in the output and in
# the summary. It just doesn't fail the build, because "this host is having
# a bad minute" is not a fact about the shipped table.
probe_with_retries() {
  local url="$1" attempt=1
  while :; do
    if probe "$url"; then
      RETRIES_USED=$((attempt - 1))
      return 0
    fi
    [ "$attempt" -ge "$ATTEMPTS" ] && return 1
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

failed=0
total=0
flaky=0
declare -a FAILURES=()
declare -a FLAKY=()

while IFS= read -r url; do
  [ -z "$url" ] && continue
  total=$((total + 1))
  LAST_BODY=""
  RETRIES_USED=0
  start=$(date +%s)
  if probe_with_retries "$url"; then
    elapsed=$(( $(date +%s) - start ))
    if [ "$RETRIES_USED" -gt 0 ]; then
      flaky=$((flaky + 1))
      FLAKY+=("$url (answered on attempt $((RETRIES_USED + 1)))")
      printf '  FLAKY %2ss  %s   answered on attempt %s\n' \
        "$elapsed" "$url" "$((RETRIES_USED + 1))"
    else
      [ "$QUIET" -eq 0 ] && printf '  OK    %2ss  %s\n' "$elapsed" "$url"
    fi
  else
    failed=$((failed + 1))
    FAILURES+=("$url")
    printf '  DEAD      %s   %s\n' "$url" "$LAST_BODY"
  fi
done < <(extract_endpoints)

echo
echo "Probed $total endpoints, $failed dead, $flaky flaky."

if [ "$flaky" -gt 0 ]; then
  echo
  echo "Flaky endpoints answered, but not on the first try. Not a build"
  echo "failure; worth watching if one keeps appearing:"
  for u in "${FLAKY[@]}"; do echo "  - $u"; done
fi

if [ "$failed" -gt 0 ]; then
  echo
  echo "Dead endpoints must be removed from RPCFallbacks (and added to the"
  echo "deadEthereum migration set if users could have them stored):"
  for u in "${FAILURES[@]}"; do echo "  - $u"; done
  exit 1
fi
