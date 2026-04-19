//! Paillier safe-prime generation microbenchmark.
//!
//! This is the tightest possible signal for how much our aarch64 GMP
//! asm override helps. The CGGMP21 aux-info round consumes one
//! `PregeneratedPrimes` pair per participant; pair generation is
//! dominated by GMP's `mpn_{add,sub}mul_1` inside safe-prime primality
//! testing, which is precisely the code path our override targets.
//!
//! On macOS host, GMP uses its own assembly (unrelated to our override).
//! On `aarch64-apple-ios-sim`, `gmp-mpfr-sys` builds GMP with
//! `--disable-assembly` and the only asm active is what `build.rs`
//! force-loads — so the sim timing is a direct measurement of the
//! override's impact.
//!
//! Run:
//!   cargo test -p horcrux-core --release --test prime_pool_perf -- --nocapture
//!
//! On iOS sim (see `horcrux-core/tests/dkg_perf.rs` for the full env
//! setup), run the produced binary via `xcrun simctl spawn <UDID>`.

use std::time::Instant;
use tempfile::tempdir;

#[test]
fn prime_pool_generate_one_benchmark() {
    let dir = tempdir().expect("tempdir");
    horcrux_core::mpc::prime_pool::init(dir.path()).expect("init pool");

    // Warm-up pair — the first Paillier pair pays a one-time allocator /
    // RNG-reseed cost we don't want to attribute to the steady-state
    // measurement.
    eprintln!("[PRIME-PERF] warm-up (discarded)...");
    let t_warm = Instant::now();
    horcrux_core::mpc::prime_pool::generate_one().expect("warm-up");
    eprintln!(
        "[PRIME-PERF] warm-up elapsed={:.2}s",
        t_warm.elapsed().as_secs_f64()
    );
    let _ = horcrux_core::mpc::prime_pool::try_take();

    // Measurement pairs. We keep this small (3) because each can take
    // tens of seconds on a simulator; the mean is the usable number.
    const SAMPLES: usize = 3;
    let mut samples = Vec::with_capacity(SAMPLES);
    for i in 0..SAMPLES {
        let t = Instant::now();
        horcrux_core::mpc::prime_pool::generate_one().expect("generate");
        let el = t.elapsed().as_secs_f64();
        samples.push(el);
        eprintln!("[PRIME-PERF] sample {}/{SAMPLES} elapsed={:.2}s", i + 1, el);
        let _ = horcrux_core::mpc::prime_pool::try_take();
    }

    let mean = samples.iter().sum::<f64>() / samples.len() as f64;
    let min = samples.iter().cloned().fold(f64::INFINITY, f64::min);
    let max = samples.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    eprintln!("[PRIME-PERF] ===== SUMMARY =====");
    eprintln!(
        "[PRIME-PERF] n={} mean={:.2}s min={:.2}s max={:.2}s",
        samples.len(),
        mean,
        min,
        max
    );

    assert!(mean > 0.0);
    assert!(mean < 600.0, "pair generation unexpectedly slow: {mean:.2}s");
}
