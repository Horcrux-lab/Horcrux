// GMP mpn_addmul_1 / mpn_submul_1 for aarch64, Mach-O (iOS/macOS) syntax.
//
// Ported from gmp-6.3.0 mpn/arm64/aorsmul_1.asm, originally authored by
// Torbjörn Granlund for the GNU MP project, licensed LGPL-3.0-or-later.
//
// Runtime override — linked with -force_load so these symbols win over the
// generic C implementations compiled by gmp-mpfr-sys when assembly is
// disabled.  ABI matches AAPCS64 / GMP's __gmpn_ prefix:
//     x0 = rp   (mp_limb_t *)
//     x1 = up   (const mp_limb_t *)
//     x2 = n    (mp_size_t, n >= 1)
//     x3 = v0   (mp_limb_t)
//   returns carry in x0.

#if defined(__APPLE__) && defined(__aarch64__)

    .text

#ifdef HORCRUX_ASM_TEST_SYMS
    // Host-test build: expose our implementation under neutral symbols so
    // tests on macOS can compare against a Rust reference without colliding
    // with libgmp.a's own ___gmpn_* on the same link line.
    #define ADDMUL_1_SYM _horcrux_asm_addmul_1_test
    #define SUBMUL_1_SYM _horcrux_asm_submul_1_test
#else
    #define ADDMUL_1_SYM ___gmpn_addmul_1
    #define SUBMUL_1_SYM ___gmpn_submul_1
#endif

    .globl ADDMUL_1_SYM
    .p2align 4
ADDMUL_1_SYM:
    adds    x15, xzr, xzr

    tbz     x2, #0, Laddmul_1
    ldr     x4, [x1], #8
    mul     x8, x4, x3
    umulh   x12, x4, x3
    ldr     x4, [x0]
    adds    x8, x4, x8
    csinc   x15, x12, x12, cc
    str     x8, [x0], #8

Laddmul_1:
    tbz     x2, #1, Laddmul_2
    ldp     x4, x5, [x1], #16
    mul     x8, x4, x3
    umulh   x12, x4, x3
    mul     x9, x5, x3
    umulh   x13, x5, x3
    adds    x8, x8, x15
    adcs    x9, x9, x12
    ldp     x4, x5, [x0]
    adc     x15, x13, xzr
    adds    x8, x4, x8
    adcs    x9, x5, x9
    csinc   x15, x15, x15, cc
    stp     x8, x9, [x0], #16

Laddmul_2:
    lsr     x2, x2, #2
    cbz     x2, Laddmul_le3
    ldp     x4, x5, [x1], #32
    ldp     x6, x7, [x1, #-16]
    b       Laddmul_mid

Laddmul_le3:
    mov     x0, x15
    ret

    .p2align 4
Laddmul_top:
    ldp     x4, x5, [x1], #32
    ldp     x6, x7, [x1, #-16]
    adds    x8, x16, x8
    adcs    x9, x17, x9
    stp     x8, x9, [x0], #32
    adcs    x10, x12, x10
    adcs    x11, x13, x11
    stp     x10, x11, [x0, #-16]
    csinc   x15, x15, x15, cc
Laddmul_mid:
    sub     x2, x2, #1
    mul     x8, x4, x3
    umulh   x12, x4, x3
    mul     x9, x5, x3
    umulh   x13, x5, x3
    adds    x8, x8, x15
    mul     x10, x6, x3
    umulh   x14, x6, x3
    adcs    x9, x9, x12
    mul     x11, x7, x3
    umulh   x15, x7, x3
    adcs    x10, x10, x13
    ldp     x16, x17, [x0]
    adcs    x11, x11, x14
    ldp     x12, x13, [x0, #16]
    adc     x15, x15, xzr
    cbnz    x2, Laddmul_top

    adds    x8, x16, x8
    adcs    x9, x17, x9
    adcs    x10, x12, x10
    adcs    x11, x13, x11
    stp     x8, x9, [x0]
    stp     x10, x11, [x0, #16]
    csinc   x0, x15, x15, cc
    ret


    .globl SUBMUL_1_SYM
    .p2align 4
SUBMUL_1_SYM:
    adds    x15, xzr, xzr

    tbz     x2, #0, Lsubmul_1
    ldr     x4, [x1], #8
    mul     x8, x4, x3
    umulh   x12, x4, x3
    ldr     x4, [x0]
    subs    x8, x4, x8
    csinc   x15, x12, x12, cs
    str     x8, [x0], #8

Lsubmul_1:
    tbz     x2, #1, Lsubmul_2
    ldp     x4, x5, [x1], #16
    mul     x8, x4, x3
    umulh   x12, x4, x3
    mul     x9, x5, x3
    umulh   x13, x5, x3
    adds    x8, x8, x15
    adcs    x9, x9, x12
    ldp     x4, x5, [x0]
    adc     x15, x13, xzr
    subs    x8, x4, x8
    sbcs    x9, x5, x9
    csinc   x15, x15, x15, cs
    stp     x8, x9, [x0], #16

Lsubmul_2:
    lsr     x2, x2, #2
    cbz     x2, Lsubmul_le3
    ldp     x4, x5, [x1], #32
    ldp     x6, x7, [x1, #-16]
    b       Lsubmul_mid

Lsubmul_le3:
    mov     x0, x15
    ret

    .p2align 4
Lsubmul_top:
    ldp     x4, x5, [x1], #32
    ldp     x6, x7, [x1, #-16]
    subs    x8, x16, x8
    sbcs    x9, x17, x9
    stp     x8, x9, [x0], #32
    sbcs    x10, x12, x10
    sbcs    x11, x13, x11
    stp     x10, x11, [x0, #-16]
    csinc   x15, x15, x15, cs
Lsubmul_mid:
    sub     x2, x2, #1
    mul     x8, x4, x3
    umulh   x12, x4, x3
    mul     x9, x5, x3
    umulh   x13, x5, x3
    adds    x8, x8, x15
    mul     x10, x6, x3
    umulh   x14, x6, x3
    adcs    x9, x9, x12
    mul     x11, x7, x3
    umulh   x15, x7, x3
    adcs    x10, x10, x13
    ldp     x16, x17, [x0]
    adcs    x11, x11, x14
    ldp     x12, x13, [x0, #16]
    adc     x15, x15, xzr
    cbnz    x2, Lsubmul_top

    subs    x8, x16, x8
    sbcs    x9, x17, x9
    sbcs    x10, x12, x10
    sbcs    x11, x13, x11
    stp     x8, x9, [x0]
    stp     x10, x11, [x0, #16]
    csinc   x0, x15, x15, cs
    ret

#endif
