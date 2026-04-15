#!/bin/bash
# Build horcrux-core Rust library for iOS targets.
# Produces a universal XCFramework for device + simulator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$SCRIPT_DIR/Horcrux/Core/Frameworks"

TARGETS=(
    "aarch64-apple-ios"           # Device (arm64)
    "aarch64-apple-ios-sim"       # Simulator (Apple Silicon)
)

echo "🔨 Building horcrux-core for iOS..."
for TARGET in "${TARGETS[@]}"; do
    echo "  → $TARGET"
    cargo build --manifest-path "$PROJECT_ROOT/Cargo.toml" \
        -p horcrux-core --lib --release --target "$TARGET"
done

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
