#![no_main]
//! Fuzz target: Noise XX handshake read-path robustness.
//!
//! `NoiseChannel::read_handshake` is the first parser an attacker hits
//! — any byte string from the relay or a misbehaving peer lands here
//! before authentication can reject them. A panic here would let any
//! network endpoint crash the iOS ceremony host, and is treated as a
//! DoS-grade bug.
//!
//! The `prop_read_handshake_never_panics` proptest in
//! `horcrux-core/src/transport/e2e.rs` runs the same invariant as a
//! fast CI regression gate (256 cases per run); this fuzz target
//! augments it with libFuzzer's coverage-guided input mutation to
//! catch rare state-machine corners the property test would miss.

use libfuzzer_sys::fuzz_target;
use horcrux_core::transport::e2e::{NoiseChannel, NoiseKeypair};

fuzz_target!(|data: &[u8]| {
    // Fresh keypair per invocation — the handshake state machine is
    // the fuzz surface; cached keypairs would just add noise.
    let Ok(kp) = NoiseKeypair::generate() else { return };
    let Ok(mut responder) = NoiseChannel::responder(&kp) else { return };
    // Must return Ok(_) or Err(_) — never panic.
    let _ = responder.read_handshake(data);
});
