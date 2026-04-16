//! Horcrux Core — MPC threshold signature library
//!
//! Private keys are never reconstructed. Each "horcrux" (shard) lives on a
//! separate device. Signing requires t-of-n participants to cooperate.

/// MPC protocol implementations: CGGMP21 threshold ECDSA (secp256k1) and IETF FROST EdDSA (ed25519).
pub mod mpc;
/// Blockchain transaction builders for EVM (EIP-1559), Bitcoin (BIP-143), and Solana.
pub mod chain;
/// Shard storage and AES-256-GCM encryption with HKDF key derivation.
pub mod shard;
/// Noise Protocol XX E2E encryption and session token management.
pub mod transport;
/// UniFFI FFI bindings for Swift (iOS) and Kotlin (Android).
pub mod ffi;

pub use mpc::HorcruxConfig;
pub use shard::ShardManager;

uniffi::setup_scaffolding!();
