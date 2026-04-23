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

/// Hard upper bound on the number of parties in an MPC ceremony.
///
/// CGGMP21 and FROST both scale as O(n^2) in message count and O(n^3) in
/// aggregate cryptographic work during DKG. Allowing arbitrarily large `n`
/// exposes the app (and peers' devices) to denial-of-service by way of
/// memory exhaustion and CPU pinning before any signature can complete.
///
/// A realistic self-custody wallet tops out well below this bound
/// (3-5 devices per user, maybe 7 for a small org).
pub const MAX_TOTAL_PARTIES: u16 = 20;

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
        if total_parties == 0 {
            return Err(MpcError::InvalidConfig("total_parties must be >= 1".into()));
        }
        if total_parties > MAX_TOTAL_PARTIES {
            return Err(MpcError::InvalidConfig(format!(
                "total_parties must be <= {} (DoS protection)",
                MAX_TOTAL_PARTIES
            )));
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

#[cfg(test)]
mod config_tests {
    use super::*;

    #[test]
    fn rejects_total_parties_over_max() {
        let err =
            HorcruxConfig::new(2, MAX_TOTAL_PARTIES + 1, 1, CurveType::Secp256k1).unwrap_err();
        match err {
            MpcError::InvalidConfig(s) => assert!(s.contains("DoS"), "msg was: {}", s),
            e => panic!("expected InvalidConfig, got {:?}", e),
        }
    }

    #[test]
    fn rejects_zero_total_parties() {
        assert!(HorcruxConfig::new(2, 0, 1, CurveType::Secp256k1).is_err());
    }

    #[test]
    fn accepts_boundary_total_parties() {
        assert!(HorcruxConfig::new(2, MAX_TOTAL_PARTIES, 1, CurveType::Secp256k1).is_ok());
    }
}
