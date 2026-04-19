pub mod ecdsa;
pub mod frost;
pub mod keygen;
pub mod prime_pool;
pub mod refresh;
pub mod session;
pub mod signing;
pub mod types;

use serde::{Deserialize, Serialize};

/// Configuration for a Horcrux MPC wallet.
///
/// Defines the t-of-n threshold: `threshold` participants out of `total_parties`
/// must cooperate to produce a valid signature.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HorcruxConfig {
    /// Minimum number of parties required to sign (t)
    pub threshold: u16,
    /// Total number of key shards (n)
    pub total_parties: u16,
    /// Which party index this device holds (1-based)
    pub party_index: u16,
    /// Target blockchain curve type
    pub curve: CurveType,
}

impl HorcruxConfig {
    pub fn new(
        threshold: u16,
        total_parties: u16,
        party_index: u16,
        curve: CurveType,
    ) -> Result<Self, MpcError> {
        if threshold < 2 {
            return Err(MpcError::InvalidConfig("threshold must be >= 2".into()));
        }
        if threshold > total_parties {
            return Err(MpcError::InvalidConfig(
                "threshold must be <= total_parties".into(),
            ));
        }
        if party_index < 1 || party_index > total_parties {
            return Err(MpcError::InvalidConfig(
                "party_index must be in [1, total_parties]".into(),
            ));
        }
        Ok(Self {
            threshold,
            total_parties,
            party_index,
            curve,
        })
    }
}

/// Supported elliptic curve types for different blockchains.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CurveType {
    /// secp256k1 — used by Ethereum (EVM) and Bitcoin
    Secp256k1,
    /// ed25519 — used by Solana
    Ed25519,
}

/// Errors from MPC operations.
#[derive(Debug, thiserror::Error)]
pub enum MpcError {
    #[error("invalid configuration: {0}")]
    InvalidConfig(String),
    #[error("keygen failed: {0}")]
    KeygenFailed(String),
    #[error("signing failed: {0}")]
    SigningFailed(String),
    #[error("session error: {0}")]
    SessionError(String),
    #[error("protocol error: {0}")]
    ProtocolError(String),
    #[error("insufficient parties: need {needed}, got {got}")]
    InsufficientParties { needed: u16, got: u16 },
}
