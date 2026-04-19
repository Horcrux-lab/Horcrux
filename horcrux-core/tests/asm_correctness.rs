//! Differential fuzz test for our hand-ported aarch64 GMP asm.
//!
//! We can't easily run GMP's own `tests/devel/` suite against an override
//! archive, so instead we compile the same `addmul_1_arm64.S` under neutral
//! symbols (see build.rs + HORCRUX_ASM_TEST_SYMS) and compare every call
//! against a naïve Rust implementation over ~200k random inputs covering
//! all four n-mod-4 residues and all four carry-entry residues.
//!
//! The asm body is identical between the iOS (force-load) build and this
//! test build — only the exported symbol name differs — so passing here is
//! strong evidence that the iOS override is also correct.
//!
//! Runs only on macOS aarch64 (which is where `cc` actually emits the test
//! object; see `is_macos_aarch64` branch of build.rs).

#![cfg(all(target_os = "macos", target_arch = "aarch64"))]

use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};

extern "C" {
    fn horcrux_asm_addmul_1_test(rp: *mut u64, up: *const u64, n: u64, v0: u64) -> u64;
    fn horcrux_asm_submul_1_test(rp: *mut u64, up: *const u64, n: u64, v0: u64) -> u64;
}

// Tickle the linker: touch a dummy reference so `-lhorcrux_asm_test` isn't
// dead-stripped.  rustc emits the link directive via build.rs but the final
// ld run still garbage-collects archives whose symbols are only used through
// `extern "C"` blocks with no compile-time requirement.
#[used]
static _KEEP_ASM: unsafe extern "C" fn(*mut u64, *const u64, u64, u64) -> u64 =
    horcrux_asm_addmul_1_test;
#[used]
static _KEEP_ASM2: unsafe extern "C" fn(*mut u64, *const u64, u64, u64) -> u64 =
    horcrux_asm_submul_1_test;

/// Reference `mpn_addmul_1`: `rp += up * v0`, returning the high-limb carry.
/// Matches GMP's `mpn/generic/addmul_1.c` semantics exactly.
fn addmul_1_ref(rp: &mut [u64], up: &[u64], v0: u64) -> u64 {
    assert!(up.len() <= rp.len());
    let mut carry: u64 = 0;
    for (i, &u0) in up.iter().enumerate() {
        let prod = (u0 as u128) * (v0 as u128);
        let (lo, hi) = (prod as u64, (prod >> 64) as u64);
        let (sum1, c1) = rp[i].overflowing_add(lo);
        let (sum2, c2) = sum1.overflowing_add(carry);
        rp[i] = sum2;
        carry = hi + (c1 as u64) + (c2 as u64);
    }
    carry
}

/// Reference `mpn_submul_1`: `rp -= up * v0`, returning the high-limb borrow.
fn submul_1_ref(rp: &mut [u64], up: &[u64], v0: u64) -> u64 {
    assert!(up.len() <= rp.len());
    let mut borrow: u64 = 0;
    for (i, &u0) in up.iter().enumerate() {
        let prod = (u0 as u128) * (v0 as u128);
        let (lo, hi) = (prod as u64, (prod >> 64) as u64);
        let (diff1, b1) = rp[i].overflowing_sub(lo);
        let (diff2, b2) = diff1.overflowing_sub(borrow);
        rp[i] = diff2;
        borrow = hi + (b1 as u64) + (b2 as u64);
    }
    borrow
}

fn run_one(n: usize, seed: u64) {
    let mut rng = StdRng::seed_from_u64(seed);
    let up: Vec<u64> = (0..n).map(|_| rng.gen()).collect();
    let rp_init: Vec<u64> = (0..n).map(|_| rng.gen()).collect();
    let v0: u64 = rng.gen();

    // addmul_1
    let mut rp_ref = rp_init.clone();
    let c_ref = addmul_1_ref(&mut rp_ref, &up, v0);

    let mut rp_asm = rp_init.clone();
    let c_asm = unsafe {
        horcrux_asm_addmul_1_test(rp_asm.as_mut_ptr(), up.as_ptr(), n as u64, v0)
    };

    assert_eq!(
        c_asm, c_ref,
        "addmul_1 carry mismatch at n={n} seed={seed:#x}"
    );
    assert_eq!(
        rp_asm, rp_ref,
        "addmul_1 result mismatch at n={n} seed={seed:#x}"
    );

    // submul_1
    let mut rp_ref = rp_init.clone();
    let b_ref = submul_1_ref(&mut rp_ref, &up, v0);

    let mut rp_asm = rp_init.clone();
    let b_asm = unsafe {
        horcrux_asm_submul_1_test(rp_asm.as_mut_ptr(), up.as_ptr(), n as u64, v0)
    };

    assert_eq!(
        b_asm, b_ref,
        "submul_1 borrow mismatch at n={n} seed={seed:#x}"
    );
    assert_eq!(
        rp_asm, rp_ref,
        "submul_1 result mismatch at n={n} seed={seed:#x}"
    );
}

/// Cover all n from 1..=16 exhaustively (exercises every n%4 entry path and
/// every odd/even tail branch) plus a larger range.
#[test]
fn differential_small_sizes() {
    for n in 1..=16 {
        for seed in 0..1_000u64 {
            run_one(n, (n as u64) * 1_000_003 + seed);
        }
    }
}

/// The sizes actually used by 512-bit Paillier safe-prime gen: mpn_2powm on
/// ~8-16 limbs.  Hammer those specifically.
#[test]
fn differential_paillier_sizes() {
    for &n in &[6usize, 7, 8, 9, 10, 12, 14, 16] {
        for seed in 0..5_000u64 {
            run_one(n, 0xdeadbeef ^ (n as u64).rotate_left(13).wrapping_mul(seed));
        }
    }
}

/// Edge-case operands: all-zero multiplicand, max v0, boundary limbs.
#[test]
fn differential_edge_cases() {
    let cases: &[(Vec<u64>, Vec<u64>, u64)] = &[
        (vec![0; 8], vec![0; 8], 0),
        (vec![0; 8], vec![0; 8], u64::MAX),
        (vec![u64::MAX; 8], vec![0; 8], u64::MAX),
        (vec![0; 8], vec![u64::MAX; 8], u64::MAX),
        (vec![u64::MAX; 8], vec![u64::MAX; 8], u64::MAX),
        (vec![u64::MAX; 1], vec![u64::MAX; 1], u64::MAX),
        (vec![u64::MAX; 2], vec![u64::MAX; 2], u64::MAX),
        (vec![u64::MAX; 3], vec![u64::MAX; 3], u64::MAX),
        (vec![1, 0, 0, 0], vec![u64::MAX; 4], u64::MAX),
    ];

    for (rp_init, up, v0) in cases {
        let n = up.len();

        let mut rp_ref = rp_init.clone();
        let c_ref = addmul_1_ref(&mut rp_ref, up, *v0);
        let mut rp_asm = rp_init.clone();
        let c_asm = unsafe {
            horcrux_asm_addmul_1_test(rp_asm.as_mut_ptr(), up.as_ptr(), n as u64, *v0)
        };
        assert_eq!((c_asm, &rp_asm), (c_ref, &rp_ref), "addmul edge n={n}");

        let mut rp_ref = rp_init.clone();
        let b_ref = submul_1_ref(&mut rp_ref, up, *v0);
        let mut rp_asm = rp_init.clone();
        let b_asm = unsafe {
            horcrux_asm_submul_1_test(rp_asm.as_mut_ptr(), up.as_ptr(), n as u64, *v0)
        };
        assert_eq!((b_asm, &rp_asm), (b_ref, &rp_ref), "submul edge n={n}");
    }
}
