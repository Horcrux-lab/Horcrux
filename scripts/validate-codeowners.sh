#!/usr/bin/env bash
# scripts/validate-codeowners.sh
#
# Validate .github/CODEOWNERS:
#   - every path-style rule (one that starts with '/') matches at
#     least one existing path on disk
#   - every owner handle is non-empty and starts with '@'
#
# Catches the common drift failure mode: a directory is renamed or
# deleted, but the CODEOWNERS rule stays behind — GitHub then
# silently ignores it and the paths end up with no explicit owner.
#
# Exit codes:
#   0  — all rules valid
#   1  — one or more rules point at a missing path, or an owner is
#         malformed
set -euo pipefail

FILE="${1:-.github/CODEOWNERS}"

if [[ ! -f "$FILE" ]]; then
  echo "error: $FILE not found" >&2
  exit 1
fi

# Ensure we run from the repo root even if invoked from elsewhere.
cd "$(git rev-parse --show-toplevel)"

fail=0
lineno=0

while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))

  # Strip comments + trim whitespace.
  trimmed="${line%%#*}"
  trimmed="$(echo -n "$trimmed" | awk '{$1=$1;print}')"
  [[ -z "$trimmed" ]] && continue

  # Split into pattern + owners.
  pattern="$(echo "$trimmed" | awk '{print $1}')"
  owners="$(echo "$trimmed" | awk '{for(i=2;i<=NF;i++)printf "%s ",$i}')"
  owners="$(echo -n "$owners" | awk '{$1=$1;print}')"

  # Validate owners: non-empty, each starts with '@'.
  if [[ -z "$owners" ]]; then
    echo "FAIL L${lineno}: no owner for pattern '$pattern'" >&2
    fail=1
    continue
  fi
  for o in $owners; do
    if [[ "${o:0:1}" != "@" ]]; then
      echo "FAIL L${lineno}: owner '$o' must start with '@'" >&2
      fail=1
    fi
  done

  # Only check path-anchored rules (start with '/').
  # Non-anchored patterns (*, *.ext) are glob-style and always match.
  if [[ "${pattern:0:1}" != "/" ]]; then
    continue
  fi

  # Strip trailing slash for directory lookup.
  probe="${pattern#/}"
  probe="${probe%/}"

  if [[ -e "$probe" ]]; then
    continue
  fi

  # Also accept path prefixes: '/foo/' matches if any file starts
  # with 'foo/'. (GitHub treats '/foo/' as "all files under foo/".)
  if compgen -G "${probe}*" > /dev/null; then
    continue
  fi

  echo "FAIL L${lineno}: pattern '$pattern' matches no path on disk" >&2
  fail=1
done < "$FILE"

if [[ $fail -ne 0 ]]; then
  echo "" >&2
  echo "CODEOWNERS validation failed. Fix the paths above or remove stale rules." >&2
  exit 1
fi

echo "CODEOWNERS validation passed."
