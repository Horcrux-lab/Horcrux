#!/bin/bash
# Build the simulator stub library for horcrux_core FFI
# Required because GMP (used by cggmp21) cannot cross-compile for iOS simulator.
# These stubs provide valid UniFFI-compatible responses so the app can run
# on the simulator for UI development and testing (MPC operations will throw errors).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STUBS_C="$SCRIPT_DIR/horcrux_core_stubs.c"
OUTPUT_DIR="$SCRIPT_DIR/.."
OUTPUT="$OUTPUT_DIR/libhorcrux_core.a"

SDK="iphonesimulator"
TARGET="arm64-apple-ios17.0-simulator"
MIN_IOS="17.0"

echo "Building simulator stubs..."
TMPOBJ=$(mktemp /tmp/horcrux_stubs.XXXXXX.o)
trap 'rm -f "$TMPOBJ"' EXIT

xcrun --sdk "$SDK" clang -c \
  -target "$TARGET" \
  -mios-simulator-version-min="$MIN_IOS" \
  -o "$TMPOBJ" \
  "$STUBS_C"

xcrun --sdk "$SDK" ar rcs "$OUTPUT" "$TMPOBJ"

echo "Built: $OUTPUT"
file "$OUTPUT"
