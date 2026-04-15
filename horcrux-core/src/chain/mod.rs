//! Multi-chain transaction abstraction layer.

pub mod evm;
pub mod bitcoin;
pub mod solana;

use serde::{Deserialize, Serialize};

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
