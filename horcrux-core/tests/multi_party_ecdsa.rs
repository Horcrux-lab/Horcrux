//! Multi-party CGGMP21 end-to-end communication tests.
//!
//! Verifies that DKG, signing, and proactive refresh all work correctly
//! with more than two parties. The ceremony routing code (broadcast vs
//! unicast, per-party mailbox, completion detection) is shared between
//! 2-of-2 and n-of-n, but 2 is a degenerate case (every broadcast has a
//! single recipient) — so bugs in the fan-out path can hide until n ≥ 3.
//!
//! We cover:
//! - 3-of-3 DKG → sign → refresh → sign (verifies same pubkey after refresh)
//! - 5-of-5 DKG → sign
//!
//! All scenarios use `t == n` (non-VSS keygen) so refresh is valid per the
//! cggmp21 0.6 invariant. Threshold (t < n) signing is already exercised by
//! the existing FROST 2-of-3 and the 2-of-2 ECDSA tests.
//!
//! These tests do a full Paillier aux-info generation and take several
//! minutes to run. Run with:
//!
//!     cargo test -p horcrux-core --release --test multi_party_ecdsa -- \
//!         --ignored --nocapture --test-threads=1

use horcrux_core::mpc::session::SessionManager;
use horcrux_core::mpc::types::MpcMessage;
use horcrux_core::mpc::{CurveType, HorcruxConfig};
use std::collections::VecDeque;
use std::time::Instant;

/// Drive an in-process ceremony to completion. Works for DKG, signing,
/// and refresh — the per-party outbox dispatch logic is identical.
///
/// `is_complete` is polled after every inbox drain; the loop ends as
/// soon as every party reports done.
fn drive_to_completion<F>(
    tag: &str,
    total: u16,
    sessions: &mut [SessionManager],
    mut initial_msgs: Vec<Vec<MpcMessage>>,
    mut is_complete: F,
) where
    F: FnMut(&[SessionManager]) -> bool,
{
    assert_eq!(initial_msgs.len(), total as usize);

    let mut queues: Vec<VecDeque<MpcMessage>> = (0..total).map(|_| VecDeque::new()).collect();

    for (idx, batch) in initial_msgs.drain(..).enumerate() {
        let party_id = idx as u16 + 1;
        for msg in batch {
            let to = msg.to as usize;
            assert!(to >= 1 && to <= total as usize, "bad recipient {}", msg.to);
            if to as u16 == party_id {
                continue;
            }
            queues[to - 1].push_back(msg);
        }
    }

    let iter_limit = 2000u32;
    let mut iter = 0u32;
    let start = Instant::now();

    loop {
        iter += 1;
        if iter > iter_limit {
            panic!("[{tag}] ceremony did not complete within {iter_limit} iterations");
        }

        let mut progressed = false;
        for idx in 0..total as usize {
            let party_id = idx as u16 + 1;
            let batch: Vec<MpcMessage> = queues[idx].drain(..).collect();
            for msg in batch {
                let out = sessions[idx]
                    .handle_message(msg)
                    .unwrap_or_else(|e| panic!("[{tag}] p{party_id} handle_message: {e}"));
                for m in out {
                    let to = m.to as usize;
                    if to >= 1 && to <= total as usize && to as u16 != party_id {
                        queues[to - 1].push_back(m);
                    }
                }
                progressed = true;
            }
        }

        if is_complete(sessions) {
            break;
        }
        if !progressed {
            panic!(
                "[{tag}] deadlock at iter {iter}: all queues empty but not all parties complete"
            );
        }
    }

    eprintln!(
        "[{tag}] done in {:.2}s ({iter} iters)",
        start.elapsed().as_secs_f64()
    );
}

/// Full `t == n` DKG + signing round. Returns (public_key, shard_data_per_party).
fn run_full_dkg(tag: &str, session_id: &str, n: u16) -> (Vec<u8>, Vec<Vec<u8>>) {
    let mut sessions: Vec<SessionManager> = (0..n).map(|_| SessionManager::new()).collect();
    let mut initial: Vec<Vec<MpcMessage>> = Vec::with_capacity(n as usize);

    for (idx, session) in sessions.iter_mut().enumerate() {
        let party_id = idx as u16 + 1;
        let cfg = HorcruxConfig::new(n, n, party_id, CurveType::Secp256k1).expect("config");
        let msgs = session
            .create_keygen(session_id.to_string(), cfg)
            .unwrap_or_else(|e| panic!("p{party_id} create_keygen: {e}"));
        initial.push(msgs);
    }

    let session_id_owned = session_id.to_string();
    drive_to_completion(tag, n, &mut sessions, initial, |ss| {
        ss.iter()
            .all(|s| s.keygen_result(&session_id_owned).is_some())
    });

    let results: Vec<_> = sessions
        .iter()
        .map(|s| s.keygen_result(session_id).expect("result"))
        .collect();
    let pk = results[0].public_key.clone();
    for r in &results[1..] {
        assert_eq!(r.public_key, pk, "pubkey mismatch across parties");
    }
    let shards: Vec<Vec<u8>> = results.into_iter().map(|r| r.shard_data).collect();
    (pk, shards)
}

/// Run a signing ceremony with every party participating.
fn run_sign_all(
    tag: &str,
    session_id: &str,
    n: u16,
    shards: &[Vec<u8>],
    message_hash: Vec<u8>,
) -> Vec<u8> {
    let mut sessions: Vec<SessionManager> = (0..n).map(|_| SessionManager::new()).collect();
    let participants: Vec<u16> = (1..=n).collect();
    let mut initial: Vec<Vec<MpcMessage>> = Vec::with_capacity(n as usize);

    for (idx, session) in sessions.iter_mut().enumerate() {
        let party_id = idx as u16 + 1;
        let cfg = HorcruxConfig::new(n, n, party_id, CurveType::Secp256k1).expect("config");
        let msgs = session
            .create_signing(
                session_id.to_string(),
                cfg,
                message_hash.clone(),
                shards[idx].clone(),
                participants.clone(),
            )
            .unwrap_or_else(|e| panic!("p{party_id} create_signing: {e}"));
        initial.push(msgs);
    }

    let session_id_owned = session_id.to_string();
    drive_to_completion(tag, n, &mut sessions, initial, |ss| {
        ss.iter()
            .all(|s| s.signing_result(&session_id_owned).is_some())
    });

    let results: Vec<_> = sessions
        .iter()
        .map(|s| s.signing_result(session_id).expect("sig"))
        .collect();
    let sig = results[0].signature.clone();
    for r in &results[1..] {
        assert_eq!(r.signature, sig, "signature mismatch across parties");
    }
    sig
}

/// Run a refresh ceremony; returns fresh shards.
fn run_refresh(
    tag: &str,
    session_id: &str,
    n: u16,
    shards: &[Vec<u8>],
    old_pk: &[u8],
) -> Vec<Vec<u8>> {
    let mut sessions: Vec<SessionManager> = (0..n).map(|_| SessionManager::new()).collect();
    let mut initial: Vec<Vec<MpcMessage>> = Vec::with_capacity(n as usize);

    for (idx, session) in sessions.iter_mut().enumerate() {
        let party_id = idx as u16 + 1;
        let cfg = HorcruxConfig::new(n, n, party_id, CurveType::Secp256k1).expect("config");
        let msgs = session
            .create_refresh(session_id.to_string(), cfg, shards[idx].clone())
            .unwrap_or_else(|e| panic!("p{party_id} create_refresh: {e}"));
        initial.push(msgs);
    }

    let session_id_owned = session_id.to_string();
    drive_to_completion(tag, n, &mut sessions, initial, |ss| {
        ss.iter()
            .all(|s| s.keygen_result(&session_id_owned).is_some())
    });

    let results: Vec<_> = sessions
        .iter()
        .map(|s| s.keygen_result(session_id).expect("refresh"))
        .collect();
    for r in &results {
        assert_eq!(
            r.public_key, old_pk,
            "refresh changed the group public key!"
        );
    }
    results.into_iter().map(|r| r.shard_data).collect()
}

#[test]
#[ignore = "slow: Paillier aux-info for 3 parties takes ~1-2 minutes"]
fn multi_party_3_of_3_dkg_sign() {
    let (pk, shards) = run_full_dkg("DKG-3of3", "mp-dkg-3of3", 3);
    assert!(pk.len() == 33 || pk.len() == 65);
    let _sig = run_sign_all("SIGN-3of3", "mp-sign-3of3", 3, &shards, vec![0xABu8; 32]);
}

#[test]
#[ignore = "slow: full 3-of-3 DKG + sign + refresh + sign takes several minutes"]
fn multi_party_3_of_3_refresh_preserves_pubkey() {
    let (pk, shards) = run_full_dkg("DKG-3of3-R", "mp-dkg-3of3-r", 3);
    let _sig_pre = run_sign_all(
        "SIGN-3of3-pre",
        "mp-sign-3of3-pre",
        3,
        &shards,
        vec![0xCAu8; 32],
    );
    let fresh = run_refresh("REFRESH-3of3", "mp-refresh-3of3", 3, &shards, &pk);
    let _sig_post = run_sign_all(
        "SIGN-3of3-post",
        "mp-sign-3of3-post",
        3,
        &fresh,
        vec![0xCAu8; 32],
    );
    // Same pubkey + valid post-refresh sig is the contract.
}

#[test]
#[ignore = "very slow: 5-of-5 aux-info alone takes ~3-5 minutes"]
fn multi_party_5_of_5_dkg_sign() {
    let (pk, shards) = run_full_dkg("DKG-5of5", "mp-dkg-5of5", 5);
    assert!(pk.len() == 33 || pk.len() == 65);
    let _sig = run_sign_all("SIGN-5of5", "mp-sign-5of5", 5, &shards, vec![0x5Eu8; 32]);
}
