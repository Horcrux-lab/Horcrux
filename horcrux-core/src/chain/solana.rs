//! Solana transaction builder.

use super::{ChainError, ChainType, Transaction, TransactionBuilder};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SolanaTxParams {
    pub from: String,
    pub to: String,
    pub lamports: u64,
    pub recent_blockhash: String,
    pub devnet: bool,
}

pub struct SolanaTransactionBuilder;

impl TransactionBuilder for SolanaTransactionBuilder {
    type Params = SolanaTxParams;

    fn build(&self, params: Self::Params) -> Result<Transaction, ChainError> {
        // TODO: Build Solana transfer instruction
        tracing::debug!(from = %params.from, to = %params.to, "building Solana transaction");

        let raw_data = vec![]; // TODO: Solana tx serialization
        let sign_hash = vec![]; // TODO: message bytes to sign

        Ok(Transaction {
            chain: ChainType::Solana { devnet: params.devnet },
            raw_data,
            sign_hash,
        })
    }
}
