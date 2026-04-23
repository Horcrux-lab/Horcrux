#![no_main]
//! Fuzz target: `decode_evm_calldata` robustness.
//!
//! The EVM calldata decoder is invoked on attacker-controlled bytes
//! every time the UI previews a pending transaction. Any panic here
//! crashes the iOS host process and creates a ceremony-abort DoS, so
//! this target's only goal is: **never panic, never UB**, regardless
//! of input shape.
//!
//! Paired with the `prop_decode_evm_calldata_never_panics` proptest
//! in `horcrux-core/src/chain/evm.rs` which provides a lightweight
//! regression gate for CI; this fuzz target runs the same surface
//! under libFuzzer's coverage-guided exploration for deeper reach.

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = horcrux_core::chain::evm::decode_evm_calldata(data);
});
