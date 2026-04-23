#![no_main]
//! Fuzz target: shard-backup deserialization + decrypt pipeline.
//!
//! Exercises the path an attacker hits when they supply a malformed
//! backup JSON on import: `serde_json::from_slice::<EncryptedShard>`
//! followed by `decrypt_shard` with a fixed key/PIN. Both stages must
//! return `Err` cleanly — never panic, never UB — regardless of
//! input shape.
//!
//! A panic here would crash the iOS host process during a backup
//! restore flow, so this is DoS-sensitive. The decrypt-failure path
//! (AES-GCM MAC verify) is separately covered by the
//! `prop_wrong_pin_rejected` / `prop_wrong_device_key_rejected`
//! proptests; this target adds coverage-guided exploration of the
//! *parser* + the transition between the parser and the crypto.

use libfuzzer_sys::fuzz_target;
use horcrux_core::shard::crypto::{decrypt_shard, EncryptedShard};

fuzz_target!(|data: &[u8]| {
    // Two shape classes:
    // 1. Raw JSON blob that may or may not deserialize into EncryptedShard.
    //    Most inputs short-circuit here with a serde error — that's fine.
    if let Ok(shard) = serde_json::from_slice::<EncryptedShard>(data) {
        // 2. If deserialization succeeds, feed the shard into decrypt
        //    with deterministic key/PIN. Expected outcome is ~always
        //    Err (AES-GCM MAC mismatch) unless the fuzzer reproduces
        //    a real ciphertext — but no panic/UB allowed either way.
        let _ = decrypt_shard(&shard, b"fuzz-device-key-................", b"fuzz-pin");
    }
});
