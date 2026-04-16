//! Multi-chain transaction abstraction layer.

pub mod bitcoin;
pub mod evm;
pub mod solana;

use serde::{Deserialize, Serialize};
use tiny_keccak::{Hasher, Keccak};

/// A chain-agnostic transaction to be signed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Transaction {
    pub chain: ChainType,
    /// Raw transaction bytes to be signed (pre-hash)
    pub raw_data: Vec<u8>,
    /// Hash of the transaction (the actual data to be signed by MPC)
    pub sign_hash: Vec<u8>,
}

/// Supported blockchain networks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ChainType {
    /// Ethereum and EVM-compatible chains
    Evm { chain_id: u64 },
    /// Bitcoin mainnet/testnet
    Bitcoin { testnet: bool },
    /// Solana mainnet/devnet
    Solana { devnet: bool },
}

/// Common interface for chain-specific transaction builders.
pub trait TransactionBuilder {
    type Params;
    fn build(&self, params: Self::Params) -> Result<Transaction, ChainError>;
}

#[derive(Debug, thiserror::Error)]
pub enum ChainError {
    #[error("invalid address: {0}")]
    InvalidAddress(String),
    #[error("encoding error: {0}")]
    EncodingError(String),
    #[error("insufficient balance")]
    InsufficientBalance,
    #[error("chain error: {0}")]
    Other(String),
}

// ---------------------------------------------------------------------------
// Address derivation utilities
// ---------------------------------------------------------------------------

/// Compute Keccak-256 hash (used by EVM).
pub fn keccak256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    let mut out = [0u8; 32];
    hasher.update(data);
    hasher.finalize(&mut out);
    out
}

/// Derive an EVM address from an uncompressed SEC1 public key (65 bytes, with
/// 0x04 prefix) or the raw 64-byte X||Y coordinates.
pub fn evm_address_from_pubkey(uncompressed: &[u8]) -> Result<String, ChainError> {
    let coords = if uncompressed.len() == 65 && uncompressed[0] == 0x04 {
        &uncompressed[1..]
    } else if uncompressed.len() == 64 {
        uncompressed
    } else {
        return Err(ChainError::InvalidAddress(
            "expected 64 or 65 byte uncompressed public key".into(),
        ));
    };
    let hash = keccak256(coords);
    Ok(format!("0x{}", hex::encode(&hash[12..])))
}

/// Derive a Bitcoin P2WPKH bech32 address from a 33-byte compressed public
/// key.  `hrp` should be `"bc"` for mainnet or `"tb"` for testnet.
pub fn btc_address_from_pubkey(compressed: &[u8], hrp_str: &str) -> Result<String, ChainError> {
    if compressed.len() != 33 {
        return Err(ChainError::InvalidAddress(
            "expected 33-byte compressed public key".into(),
        ));
    }
    let hash160 = bitcoin::hash160(compressed);
    let hrp = bech32::Hrp::parse(hrp_str)
        .map_err(|e| ChainError::EncodingError(format!("bad hrp: {e}")))?;
    // Witness version 0 + witness program (20-byte hash160)
    let addr = bech32::segwit::encode(hrp, bech32::segwit::VERSION_0, &hash160)
        .map_err(|e| ChainError::EncodingError(format!("bech32 encode: {e}")))?;
    Ok(addr)
}

/// Derive a Solana address (base58) from a 32-byte Ed25519 public key.
pub fn solana_address_from_pubkey(pubkey: &[u8; 32]) -> String {
    bs58::encode(pubkey).into_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_keccak256_empty() {
        let hash = keccak256(b"");
        assert_eq!(
            hex::encode(hash),
            "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
        );
    }

    #[test]
    fn test_evm_address_derivation() {
        // Known test vector (Vitalik-style): a dummy uncompressed key
        // We just verify format and length.
        let fake_pubkey = [0x04u8; 65]; // not a real point, but valid for hashing
        let addr = evm_address_from_pubkey(&fake_pubkey).unwrap();
        assert!(addr.starts_with("0x"));
        assert_eq!(addr.len(), 42); // "0x" + 40 hex chars
    }

    #[test]
    fn test_evm_address_rejects_bad_len() {
        assert!(evm_address_from_pubkey(&[0u8; 32]).is_err());
    }

    #[test]
    fn test_btc_address_derivation() {
        // Compressed pubkey (all-twos, not a real point but exercises the code path)
        let fake = [0x02u8; 33];
        let addr = btc_address_from_pubkey(&fake, "bc").unwrap();
        assert!(addr.starts_with("bc1q")); // P2WPKH mainnet
    }

    #[test]
    fn test_btc_address_testnet() {
        let fake = [0x03u8; 33];
        let addr = btc_address_from_pubkey(&fake, "tb").unwrap();
        assert!(addr.starts_with("tb1q"));
    }

    #[test]
    fn test_solana_address_derivation() {
        let key = [0u8; 32];
        let addr = solana_address_from_pubkey(&key);
        // base58 of 32 zero bytes
        assert_eq!(addr, bs58::encode([0u8; 32]).into_string());
    }
}
