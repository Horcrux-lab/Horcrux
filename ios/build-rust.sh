#!/bin/bash
# Build horcrux-core Rust library for iOS targets.
# Produces a universal XCFramework for device + simulator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$SCRIPT_DIR/Horcrux/Core/Frameworks"

# iOS SDK paths (xcrun resolves the active Xcode).
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IOS_SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
CLANG="$(xcrun --find clang)"

echo "🔨 Building horcrux-core for iOS..."

# ---- gmp-mpfr-sys cache guard ----------------------------------------------
# gmp-mpfr-sys compiles MPFR/GMP C sources during its build.rs. Cargo's
# fingerprint tracking doesn't always notice when CC/CFLAGS change between
# runs (e.g. switching macOS host build ↔ iOS cross build). We detect that
# by stashing a SHA of the CC + CFLAGS + target triples; if it's different
# from the previous run we `cargo clean -p gmp-mpfr-sys` for the affected
# targets before rebuilding. This removes the "rebuild cache bug" that used
# to surface as undefined symbols or wrong-arch object files.
FP_DIR="$PROJECT_ROOT/target/.horcrux-fp"
mkdir -p "$FP_DIR"
FP_FILE="$FP_DIR/gmp-mpfr-sys.fingerprint"
CURRENT_FP=$(printf "%s" "$CLANG|arm64-apple-ios14.0|arm64-apple-ios14.0-simulator|$IOS_SDK|$IOS_SIM_SDK" | shasum | awk '{print $1}')
PREV_FP=""
if [[ -f "$FP_FILE" ]]; then
    PREV_FP="$(cat "$FP_FILE")"
fi
if [[ "$PREV_FP" != "$CURRENT_FP" ]]; then
    if [[ -n "$PREV_FP" ]]; then
        echo "  ↻ toolchain fingerprint changed — purging gmp-mpfr-sys cross caches"
        cargo clean --manifest-path "$PROJECT_ROOT/Cargo.toml" \
            -p gmp-mpfr-sys --target aarch64-apple-ios --release 2>/dev/null || true
        cargo clean --manifest-path "$PROJECT_ROOT/Cargo.toml" \
            -p gmp-mpfr-sys --target aarch64-apple-ios-sim --release 2>/dev/null || true
    fi
    echo "$CURRENT_FP" > "$FP_FILE"
fi
# ---------------------------------------------------------------------------

# clang_rt.builtins provides `__chkstk_darwin` and other helpers that rustc's
# cdylib output needs at link time. Xcode's copy lives alongside clang.
CLANG_RT_DIR="$(dirname "$CLANG")/../lib/clang/$(ls "$(dirname "$CLANG")/../lib/clang/" | sort -V | tail -1)/lib/darwin"

# Device (arm64). GMP's C fallback is compiled by gmp-mpfr-sys's build.rs,
# which picks up CC/CFLAGS from the environment. We must target iOS so the
# produced object files link against the iOS runtime, not macOS.
echo "  → aarch64-apple-ios"
CC="$CLANG" \
CFLAGS="-target arm64-apple-ios14.0 -isysroot $IOS_SDK -arch arm64" \
AR="$(xcrun --find ar)" \
RUSTFLAGS="-C link-arg=-L$CLANG_RT_DIR -C link-arg=-lclang_rt.ios" \
cargo build --manifest-path "$PROJECT_ROOT/Cargo.toml" \
    -p horcrux-core --lib --release --target aarch64-apple-ios

# Simulator (Apple Silicon).
echo "  → aarch64-apple-ios-sim"
CC="$CLANG" \
CFLAGS="-target arm64-apple-ios14.0-simulator -isysroot $IOS_SIM_SDK -arch arm64" \
AR="$(xcrun --find ar)" \
RUSTFLAGS="-C link-arg=-L$CLANG_RT_DIR -C link-arg=-lclang_rt.iossim" \
cargo build --manifest-path "$PROJECT_ROOT/Cargo.toml" \
    -p horcrux-core --lib --release --target aarch64-apple-ios-sim

# Paths to built libraries
DEVICE_LIB="$PROJECT_ROOT/target/aarch64-apple-ios/release/libhorcrux_core.a"
SIM_LIB="$PROJECT_ROOT/target/aarch64-apple-ios-sim/release/libhorcrux_core.a"

# Generate Swift bindings
echo "📦 Generating Swift bindings..."
cargo run -p uniffi-bindgen -- generate \
    --library "$PROJECT_ROOT/target/aarch64-apple-ios/release/libhorcrux_core.a" \
    --language swift \
    --out-dir "$SCRIPT_DIR/Horcrux/Core/Generated"

# Create module map for the C header
HEADER_DIR="$OUT_DIR/Headers"
mkdir -p "$HEADER_DIR"
cp "$SCRIPT_DIR/Horcrux/Core/Generated/horcrux_coreFFI.h" "$HEADER_DIR/"
cp "$SCRIPT_DIR/Horcrux/Core/Generated/horcrux_coreFFI.modulemap" "$HEADER_DIR/module.modulemap"

# Build XCFramework
echo "📱 Creating XCFramework..."
rm -rf "$OUT_DIR/HorcruxCore.xcframework"
xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" -headers "$HEADER_DIR" \
    -library "$SIM_LIB" -headers "$HEADER_DIR" \
    -output "$OUT_DIR/HorcruxCore.xcframework"

echo "✅ XCFramework built: $OUT_DIR/HorcruxCore.xcframework"
echo "   Swift bindings: $SCRIPT_DIR/Horcrux/Core/Generated/horcrux_core.swift"

# The Xcode project currently links against a single libhorcrux_core.a via
# LIBRARY_SEARCH_PATHS + -lhorcrux_core (not the XCFramework yet). Copy the
# simulator slice in by default so `xcodebuild … -destination simulator`
# works out of the box. To produce a device build, re-run with
# `HORCRUX_ARCH=device bash ios/build-rust.sh` or switch the project over
# to the XCFramework in Horcrux/Core/Frameworks/HorcruxCore.xcframework.
HORCRUX_ARCH="${HORCRUX_ARCH:-sim}"
if [[ "$HORCRUX_ARCH" == "device" ]]; then
    echo "📎 Copying device slice to libhorcrux_core.a"
    cp "$DEVICE_LIB" "$OUT_DIR/libhorcrux_core.a"
else
    echo "📎 Copying simulator slice to libhorcrux_core.a"
    cp "$SIM_LIB" "$OUT_DIR/libhorcrux_core.a"
fi
