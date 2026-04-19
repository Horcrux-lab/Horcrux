#!/usr/bin/env bash
#
# Run GMP's own tests/devel/try harness against our hand-ported aarch64
# asm (src/mpc/asm/addmul_1_arm64.S).  This is the strongest correctness
# check we have for the override — the harness tests thousands of sizes
# with every alignment, source/destination overlap permutation, redzone
# overrun detection, and mprotect-guarded sources against refmpn.c.
#
# Usage:  bash horcrux-core/tests/gmp_try_test.sh           # sizes 1-20
#         bash horcrux-core/tests/gmp_try_test.sh -s 1-64   # full run
#
# Requires: autoconf, automake, libtool, m4, clang (all come with Xcode +
# `brew install autoconf automake libtool`).  Must be run on macOS
# aarch64 host; the harness is a native binary.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GMP_SRC="$REPO_ROOT/third_party/gmp-mpfr-sys/gmp-6.3.0-c"
OVERRIDE_S="$REPO_ROOT/horcrux-core/src/mpc/asm/addmul_1_arm64.S"
WORK_DIR="${HORCRUX_GMP_TRY_DIR:-$(mktemp -d -t horcrux-gmp-try)}"
SIZES="${1:--s}"
RANGE="${2:-1-20}"

echo "==> GMP source: $GMP_SRC"
echo "==> Build dir:  $WORK_DIR"
echo "==> Override:   $OVERRIDE_S"
echo "==> Sizes:      $RANGE"
echo

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ ! -f Makefile ]; then
    echo "==> Configuring GMP..."
    "$GMP_SRC/configure" --disable-shared --with-pic >/dev/null
fi

if [ ! -f .libs/libgmp.a ]; then
    echo "==> Building libgmp..."
    make -j8 >/dev/null
fi

echo "==> Building libtests..."
make -C tests libtests.la >/dev/null 2>&1

echo "==> Building try..."
(cd tests/devel && make try >/dev/null 2>&1)

echo "==> Compiling our override .S..."
clang -c -x assembler-with-cpp "$OVERRIDE_S" -o "$WORK_DIR/horcrux_override.o"

echo "==> Relinking try with -force_load,horcrux_override.o..."
cd tests/devel
gcc -O2 -march=armv8-a \
    -Wl,-force_load,"$WORK_DIR/horcrux_override.o" \
    -o try.override try.o \
    ../../tests/.libs/libtests.a \
    "$WORK_DIR/.libs/libgmp.a" 2>/dev/null

# Confirm our code is actually at the addmul_1 entry: first insn is
# 'adds x15, xzr, xzr' (our override starts this way; GMP's own asm
# starts with a different mov/ldr pattern).
FIRST_DISASM=$(otool -tV try.override 2>/dev/null | awk '/^___gmpn_addmul_1:/{getline; $1=""; print}' | head -1)
case "$FIRST_DISASM" in
    *adds*x15*xzr*xzr*) ;;
    *)
        echo "!! force_load failed: ___gmpn_addmul_1 first insn is '$FIRST_DISASM', expected 'adds x15, xzr, xzr'"
        exit 1 ;;
esac
echo "==> Confirmed: ___gmpn_addmul_1 resolves to our override"
echo

echo "==> Running try $SIZES $RANGE -W mpn_addmul_1..."
./try.override "$SIZES" "$RANGE" -W mpn_addmul_1 2>&1 | grep -E "^mpn_" || {
    echo "!! try reported no result line for mpn_addmul_1"
    exit 1
}
echo "==> Running try $SIZES $RANGE -W mpn_submul_1..."
./try.override "$SIZES" "$RANGE" -W mpn_submul_1 2>&1 | grep -E "^mpn_" || {
    echo "!! try reported no result line for mpn_submul_1"
    exit 1
}
echo
echo "PASS"
