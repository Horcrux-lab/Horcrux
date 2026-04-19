//! End-to-end DKG performance harness.
//!
//! Drives a full t-of-n distributed key generation between N
//! in-process `SessionManager` instances and reports the wall-clock
//! time for every round plus the overall ceremony.
//!
//! Two protocols are exercised:
//! - **secp256k1 / CGGMP21 ECDSA** (2-of-2) — heavy Paillier aux-info,
//!   sensitive to the aarch64 asm override.
//! - **ed25519 / FROST** (2-of-3) — elliptic-curve only, no Paillier,
//!   so timings are a lower bound from the rest of the stack
//!   (serialization, message routing, EC scalar ops).
//!
//! The interesting measurement is the aux-info phase for CGGMP21 —
//! Paillier safe-prime generation dominates. On a macOS aarch64 host,
//! GMP uses its own asm (unrelated to our override). When this test
//! runs under the `aarch64-apple-ios-sim` target, `gmp-mpfr-sys`
//! compiles GMP with `--disable-assembly` and the only asm active is
//! the one we force-load via `build.rs` — so the timing on sim is a
//! direct measurement of the override's impact.
//!
//! Run on host:
//!   cargo test -p horcrux-core --release --test dkg_perf -- --nocapture
//!
//! Run on iOS simulator: see commit message / prior instructions.

use horcrux_core::mpc::session::SessionManager;
use horcrux_core::mpc::types::MpcMessage;
use horcrux_core::mpc::{CurveType, HorcruxConfig};
use std::collections::VecDeque;
use std::time::Instant;

/// Drive an N-party DKG entirely in-process. Every `handle_message`
/// call is timed individually; a per-ceremony summary is printed on
/// completion. Returns the per-party group public keys (one per
/// participant, must all match).
fn run_dkg(
    tag: &'static str,
    session_id: &str,
    threshold: u16,
    total: u16,
    curve: CurveType,
) -> Vec<Vec<u8>> {
    assert!(
        total >= 2 && threshold >= 1 && threshold <= total,
        "invalid threshold/total"
    );

    let mut sessions: Vec<SessionManager> = (0..total).map(|_| SessionManager::new()).collect();

    // Per-party outgoing mailbox: queues[i] holds messages destined for
    // party (i+1). Using VecDeque + pop_front / push_back preserves the
    // FIFO ordering the real app uses — LIFO deadlocks the CGGMP21
    // state machine at the end of aux-info.
    let mut queues: Vec<VecDeque<MpcMessage>> = (0..total).map(|_| VecDeque::new()).collect();

    eprintln!(
        "[{tag}] ceremony start curve={:?} {}-of-{} session={session_id}",
        curve, threshold, total
    );
    let ceremony_start = Instant::now();

    // Kick off every party. Each returns its initial broadcast /
    // unicast batch; we dispatch them into per-recipient FIFOs.
    let t0 = Instant::now();
    for (idx, session) in sessions.iter_mut().enumerate() {
        let party_id = idx as u16 + 1;
        let cfg = HorcruxConfig::new(threshold, total, party_id, curve).expect("config");
        let initial = session
            .create_keygen(session_id.to_string(), cfg)
            .unwrap_or_else(|e| panic!("p{party_id} create_keygen: {e}"));
        for msg in initial {
            let to = msg.to as usize;
            assert!(to >= 1 && to <= total as usize, "bad recipient {to}");
            // Don't loop a message back to the sender.
            if to as u16 == party_id {
                continue;
            }
            queues[to - 1].push_back(msg);
        }
    }
    eprintln!(
        "[{tag}] create_keygen elapsed={:.2}s (all parties started)",
        t0.elapsed().as_secs_f64()
    );

    let mut round_log: Vec<(u32, u16, f64, usize)> = Vec::new();
    let mut iter = 0u32;
    let iter_limit = 500u32;

    loop {
        iter += 1;
        if iter > iter_limit {
            panic!("DKG did not complete within {iter_limit} iterations");
        }

        let mut progressed = false;

        // Drain every party's inbox once in round-robin order. We
        // snapshot the current queue so messages emitted *this iter*
        // go into the next pass, not the current one — matching real
        // network ordering.
        for idx in 0..total as usize {
            let party_id = idx as u16 + 1;
            let batch: Vec<MpcMessage> = queues[idx].drain(..).collect();
            for msg in batch {
                let t = Instant::now();
                let out = sessions[idx]
                    .handle_message(msg)
                    .unwrap_or_else(|e| panic!("p{party_id} handle_message: {e}"));
                let el = t.elapsed().as_secs_f64();
                // Only log slow rounds to keep output readable; cheap
                // ones still accumulate into the summary via round_log.
                if el > 0.05 {
                    eprintln!(
                        "[{tag}] iter={iter} p{party_id} handle elapsed={:.2}s outbox={}",
                        el,
                        out.len()
                    );
                }
                round_log.push((iter, party_id, el, out.len()));
                for m in out {
                    let to = m.to as usize;
                    if to >= 1 && to <= total as usize && to as u16 != party_id {
                        queues[to - 1].push_back(m);
                    } else {
                        eprintln!(
                            "[{tag}]   p{party_id} emitted msg to={} (dropped)",
                            m.to
                        );
                    }
                }
                progressed = true;
            }
        }

        let complete = sessions
            .iter_mut()
            .all(|s| s.keygen_result(session_id).is_some());
        if complete {
            break;
        }
        if !progressed {
            panic!(
                "DKG deadlock at iter {iter}: all queues empty but not all parties complete"
            );
        }
    }

    let total_time = ceremony_start.elapsed().as_secs_f64();
    let sum: f64 = round_log.iter().map(|e| e.2).sum();
    let slowest = round_log
        .iter()
        .max_by(|a, b| a.2.partial_cmp(&b.2).unwrap());
    eprintln!("[{tag}] ===== SUMMARY =====");
    eprintln!(
        "[{tag}] total ceremony: {:.2}s ({} handle calls, sum {:.2}s)",
        total_time,
        round_log.len(),
        sum
    );
    if let Some((it, who, el, _)) = slowest {
        eprintln!("[{tag}] slowest: iter={it} p{who} elapsed={el:.2}s");
    }
    for pid in 1..=total {
        let party_sum: f64 = round_log
            .iter()
            .filter(|e| e.1 == pid)
            .map(|e| e.2)
            .sum();
        eprintln!("[{tag}] p{pid} handle sum: {:.2}s", party_sum);
    }

    // Pull results.
    let mut pks: Vec<Vec<u8>> = Vec::with_capacity(total as usize);
    for (idx, session) in sessions.iter_mut().enumerate() {
        let r = session
            .keygen_result(session_id)
            .unwrap_or_else(|| panic!("p{} missing keygen_result", idx + 1));
        pks.push(r.public_key);
    }
    for pk in &pks[1..] {
        assert_eq!(pk, &pks[0], "group public key mismatch across parties");
    }
    eprintln!(
        "[{tag}] group pubkey={} ({} bytes)",
        hex::encode(&pks[0]),
        pks[0].len()
    );
    pks
}

/// 2-of-2 CGGMP21 DKG on secp256k1. Exercises the heavy Paillier
/// aux-info round — primary measurement for the aarch64 asm override.
#[test]
fn dkg_perf_cggmp21_secp256k1_2_of_2() {
    let pks = run_dkg(
        "E2E-ECDSA-2of2",
        "dkg-perf-ecdsa-2of2",
        2,
        2,
        CurveType::Secp256k1,
    );
    // secp256k1 pubkey is 33 (compressed) or 65 (uncompressed).
    assert!(
        pks[0].len() == 33 || pks[0].len() == 65,
        "unexpected secp256k1 pubkey size: {}",
        pks[0].len()
    );
}

/// 2-of-3 FROST DKG on ed25519. No Paillier → lower-bound measurement
/// from the rest of the stack (serialization, routing, EC ops).
#[test]
fn dkg_perf_frost_ed25519_2_of_3() {
    let pks = run_dkg(
        "E2E-FROST-2of3",
        "dkg-perf-frost-2of3",
        2,
        3,
        CurveType::Ed25519,
    );
    assert_eq!(
        pks[0].len(),
        32,
        "ed25519 pubkey must be 32 bytes, got {}",
        pks[0].len()
    );
}
