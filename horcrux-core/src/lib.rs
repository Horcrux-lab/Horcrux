//! Horcrux Core — MPC threshold signature library
//!
//! Private keys are never reconstructed. Each "horcrux" (shard) lives on a
//! separate device. Signing requires t-of-n participants to cooperate.

pub mod mpc;
pub mod chain;
pub mod shard;
pub mod transport;

pub use mpc::HorcruxConfig;
pub use shard::ShardManager;
