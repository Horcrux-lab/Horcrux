#!/usr/bin/env bash
# Reproducible-build verifier for the iOS Rust XCFramework.
#
# Rebuilds horcrux-core for iOS via ios/build-rust.sh, computes SHA-256
# hashes over every file in the resulting XCFramework + generated Swift
# bindings, and diffs them against docs/reproducible-build.manifest.
#
# Usage:
#   scripts/verify-build.sh            # verify against the committed manifest
#   scripts/verify-build.sh --update   # regenerate the manifest (maintainer)
#
# Exits 0 on a byte-identical match, 1 on any divergence, 2 on build failure.
#
# Intentional design notes:
#   * We hash the XCFramework contents, not the .xcframework bundle as a
#     whole — macOS sometimes reorders directory-entries in the bundle
#     directory, which affects a bundle-level tar/zip digest but not the
#     individual file bytes.
#   * We exclude build caches (target/, DerivedData/) from the hash set.
#   * On the same host, toolchain, and committed tree, every file should
#     hash identically across runs. Across hosts, the static libs MAY
#     differ due to Rust's historical non-determinism (see
#     docs/reproducible-build.md for the known-caveats list); the
#     UniFFI-generated bindings + headers are always deterministic.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MANIFEST="docs/reproducible-build.manifest"
MODE="verify"

for arg in "$@"; do
    case "$arg" in
        --update) MODE="update" ;;
        -h|--help)
            sed -n '2,24p' "$0"
            exit 0
            ;;
        *)
            echo "error: unknown flag '$arg'" >&2
            exit 2
            ;;
    esac
done

echo "🔨 Building horcrux-core for iOS (clean)…"
rm -rf ios/Horcrux/Core/Frameworks/HorcruxCore.xcframework
if ! ios/build-rust.sh > /tmp/horcrux-verify-build.log 2>&1; then
    echo "❌ build failed — see /tmp/horcrux-verify-build.log" >&2
    tail -40 /tmp/horcrux-verify-build.log >&2
    exit 2
fi
echo "✅ build finished"

echo "📋 Computing SHA-256 manifest…"
TMP_MANIFEST="$(mktemp)"
trap 'rm -f "$TMP_MANIFEST"' EXIT

{
    # Generated bindings — 100% deterministic from the UDL + macros.
    shasum -a 256 ios/Horcrux/Core/Generated/horcrux_core.swift \
                  ios/Horcrux/Core/Generated/horcrux_coreFFI.h \
                  ios/Horcrux/Core/Generated/horcrux_coreFFI.modulemap

    # XCFramework contents. `find | sort` normalises directory order.
    # Info.plist is intentionally excluded — xcodebuild -create-xcframework
    # emits the `AvailableLibraries` array in non-deterministic order, so
    # the plist bytes differ between runs even when every binary artefact
    # is byte-identical. Its *structure* is verified in CI by plutil -p.
    find ios/Horcrux/Core/Frameworks/HorcruxCore.xcframework -type f \
        ! -name Info.plist \
        | LC_ALL=C sort \
        | xargs shasum -a 256
} > "$TMP_MANIFEST"

case "$MODE" in
    update)
        mv "$TMP_MANIFEST" "$MANIFEST"
        trap - EXIT
        {
            echo "# Horcrux reproducible-build manifest"
            echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/verify-build.sh --update"
            echo "# Host: $(uname -sm) — rustc $(rustc --version | awk '{print $2}') — $(xcodebuild -version | head -1)"
            echo ""
            cat "$MANIFEST"
        } > "${MANIFEST}.tmp"
        mv "${MANIFEST}.tmp" "$MANIFEST"
        echo "✍️  Updated $MANIFEST"
        ;;
    verify)
        if [[ ! -f "$MANIFEST" ]]; then
            echo "❌ no committed manifest at $MANIFEST" >&2
            echo "   run: $0 --update   to create one" >&2
            exit 1
        fi
        # Strip metadata-comment lines (# …) from the committed manifest
        # before diffing so metadata drift doesn't cause false positives.
        COMMITTED="$(grep -v '^#' "$MANIFEST" | grep -v '^[[:space:]]*$' || true)"
        OBSERVED="$(cat "$TMP_MANIFEST")"
        if [[ "$COMMITTED" == "$OBSERVED" ]]; then
            echo "✅ build matches committed manifest (byte-identical)"
            exit 0
        fi
        echo "❌ build diverges from committed manifest" >&2
        diff <(echo "$COMMITTED") <(echo "$OBSERVED") >&2 || true
        exit 1
        ;;
esac
