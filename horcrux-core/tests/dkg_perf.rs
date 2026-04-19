//! End-to-end DKG performance test.
//!
//! Runs a full 2-of-2 secp256k1 CGGMP21 distributed key generation between
//! two in-process `SessionManager` instances and reports the wall-clock time
//! for every round plus the overall ceremony.
//!
//! The interesting measurement is the aux-info phase — for which Paillier
//! safe-prime generation dominates. On a macOS aarch64 host, GMP uses its
//! own asm (unrelated to our override). When this test runs under the
//! `aarch64-apple-ios-sim` target, `gmp-mpfr-sys` compiles GMP with
//! `--disable-assembly` and the only asm active is the one we force-load
//! via `build.rs` — so the timing on sim directly measures the override's
//! impact at runtime.
//!
//! Run on host:
//!   cargo test -p horcrux-core --release --test dkg_perf -- --nocapture
//!
//! Run on iOS simulator (manual; see comments at bottom of file).

use horcrux_core::mpc::session::SessionManager;
use horcrux_core::mpc::types::MpcMessage;
use horcrux_core::mpc::{CurveType, HorcruxConfig};
use std::collections::VecDeque;
use std::time::Instant;

/// Drive a 2-party DKG entirely in-process, printing every
/// `handle_message` duration and the overall total.
#[test]
fn dkg_perf_two_party_secp256k1() {
    let sid = "dkg-perf-e2e".to_string();
    let mut p1 = SessionManager::new();
    let mut p2 = SessionManager::new();

    let cfg1 = HorcruxConfig::new(2, 2, 1, CurveType::Secp256k1).unwrap();
    let cfg2 = HorcruxConfig::new(2, 2, 2, CurveType::Secp256k1).unwrap();

    eprintln!("[E2E-DKG] ceremony start curve=secp256k1 2-of-2 session={sid}");
    let ceremony_start = Instant::now();

    let t0 = Instant::now();
    let initial1 = p1.create_keygen(sid.clone(), cfg1).expect("p1 create_keygen");
    let initial2 = p2.create_keygen(sid.clone(), cfg2).expect("p2 create_keygen");
    eprintln!(
        "[E2E-DKG] create_keygen elapsed={:.2}s p1_out={} p2_out={}",
        t0.elapsed().as_secs_f64(),
        initial1.len(),
        initial2.len()
    );

    let mut to_p1: VecDeque<MpcMessage> = initial2.into_iter().filter(|m| m.to == 1).collect();
    let mut to_p2: VecDeque<MpcMessage> = initial1.into_iter().filter(|m| m.to == 2).collect();

    let mut iter = 0;
    let iter_limit = 200;
    let mut round_log: Vec<(u32, String, f64, usize)> = Vec::new();

    while iter < iter_limit {
        iter += 1;
        let mut progressed = false;

        while let Some(msg) = to_p1.pop_front() {
            let t = Instant::now();
            let out = p1.handle_message(msg).expect("p1 handle_message");
            let el = t.elapsed().as_secs_f64();
            eprintln!(
                "[E2E-DKG] iter={iter} p1 handle elapsed={:.2}s outbox={} (to_p1_left={}, to_p2={})",
                el,
                out.len(),
                to_p1.len(),
                to_p2.len()
            );
            round_log.push((iter, "p1".into(), el, out.len()));
            for m in out {
                if m.to == 2 {
                    to_p2.push_back(m);
                } else {
                    eprintln!("[E2E-DKG]   p1 emitted msg to={} (dropped)", m.to);
                }
            }
            progressed = true;
        }

        while let Some(msg) = to_p2.pop_front() {
            let t = Instant::now();
            let out = p2.handle_message(msg).expect("p2 handle_message");
            let el = t.elapsed().as_secs_f64();
            eprintln!(
                "[E2E-DKG] iter={iter} p2 handle elapsed={:.2}s outbox={} (to_p2_left={}, to_p1={})",
                el,
                out.len(),
                to_p2.len(),
                to_p1.len()
            );
            round_log.push((iter, "p2".into(), el, out.len()));
            for m in out {
                if m.to == 1 {
                    to_p1.push_back(m);
                } else {
                    eprintln!("[E2E-DKG]   p2 emitted msg to={} (dropped)", m.to);
                }
            }
            progressed = true;
        }

        let r1 = p1.keygen_result(&sid);
        let r2 = p2.keygen_result(&sid);
        eprintln!(
            "[E2E-DKG] iter={iter} end: r1={} r2={} to_p1={} to_p2={}",
            r1.is_some(),
            r2.is_some(),
            to_p1.len(),
            to_p2.len()
        );
        if r1.is_some() && r2.is_some() {
            break;
        }

        if !progressed {
            panic!("DKG deadlock at iter {iter}: no queued messages but no keygen result");
        }
    }

    let total = ceremony_start.elapsed().as_secs_f64();
    let p1_sum: f64 = round_log.iter().filter(|e| e.1 == "p1").map(|e| e.2).sum();
    let p2_sum: f64 = round_log.iter().filter(|e| e.1 == "p2").map(|e| e.2).sum();
    let slowest = round_log
        .iter()
        .max_by(|a, b| a.2.partial_cmp(&b.2).unwrap());

    eprintln!("[E2E-DKG] ===== SUMMARY =====");
    eprintln!("[E2E-DKG] total ceremony: {:.2}s ({} handle calls)", total, round_log.len());
    eprintln!("[E2E-DKG] p1 handle sum: {:.2}s", p1_sum);
    eprintln!("[E2E-DKG] p2 handle sum: {:.2}s", p2_sum);
    if let Some((it, who, el, _)) = slowest {
        eprintln!("[E2E-DKG] slowest: iter={it} party={who} elapsed={el:.2}s");
    }

    let r1 = p1.keygen_result(&sid).expect("p1 keygen result");
    let r2 = p2.keygen_result(&sid).expect("p2 keygen result");
    assert_eq!(r1.public_key, r2.public_key, "group pubkey mismatch");
    assert!(
        r1.public_key.len() == 33 || r1.public_key.len() == 65,
        "secp256k1 pubkey = 33 or 65 bytes, got {}",
        r1.public_key.len()
    );
    eprintln!(
        "[E2E-DKG] pubkey={} ({} bytes)",
        hex::encode(&r1.public_key[..]),
        r1.public_key.len()
    );
}
