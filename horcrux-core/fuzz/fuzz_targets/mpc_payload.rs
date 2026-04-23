#![no_main]
//! Fuzz target: MPC wire payload parsers.
//!
//! During a signing or keygen ceremony, peers exchange messages whose
//! `payload: Vec<u8>` field is a serde_json-encoded protocol-specific
//! struct. The outer Noise E2E channel authenticates the sender but
//! performs no payload validation — a malicious (or buggy) cosigner can
//! therefore ship arbitrary bytes to any of the decoders below. Any
//! panic here crashes the iOS host mid-ceremony and hands the attacker
//! a cheap DoS primitive.
//!
//! We multiplex all wire types through a single 1-byte dispatcher so a
//! single fuzzing session explores every parser and corpus entries can
//! be mutated across type boundaries. Paired with the
//! `mpc::prop_tests` module in `horcrux-core/src/mpc/mod.rs` which
//! gives CI a 256-case-per-type regression gate; this target adds
//! coverage-guided exploration for contributors running cargo-fuzz.

use horcrux_core::mpc::ecdsa::EcdsaWireMsg;
use horcrux_core::mpc::frost::{FrostDkgRound1, FrostDkgRound2, FrostSignRound1, FrostSignRound2};
use horcrux_core::mpc::keygen::{Round1Broadcast, Round2Share};
use horcrux_core::mpc::signing::{SignRound1, SignRound2};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if data.is_empty() {
        return;
    }
    let (tag, rest) = data.split_first().unwrap();
    match tag % 9 {
        0 => {
            let _ = serde_json::from_slice::<SignRound1>(rest);
        }
        1 => {
            let _ = serde_json::from_slice::<SignRound2>(rest);
        }
        2 => {
            let _ = serde_json::from_slice::<Round1Broadcast>(rest);
        }
        3 => {
            let _ = serde_json::from_slice::<Round2Share>(rest);
        }
        4 => {
            let _ = serde_json::from_slice::<FrostDkgRound1>(rest);
        }
        5 => {
            let _ = serde_json::from_slice::<FrostDkgRound2>(rest);
        }
        6 => {
            let _ = serde_json::from_slice::<FrostSignRound1>(rest);
        }
        7 => {
            let _ = serde_json::from_slice::<FrostSignRound2>(rest);
        }
        _ => {
            let _ = serde_json::from_slice::<EcdsaWireMsg>(rest);
        }
    }
});
