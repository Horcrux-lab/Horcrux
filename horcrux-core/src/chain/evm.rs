//! Ethereum / EVM transaction builder.

use super::{ChainError, ChainType, Transaction, TransactionBuilder};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvmTxParams {
    pub to: String,
    pub value: u128,
    pub nonce: u64,
    pub gas_limit: u64,
    pub max_fee_per_gas: u128,
    pub max_priority_fee_per_gas: u128,
    pub chain_id: u64,
    pub data: Vec<u8>,
}

pub struct EvmTransactionBuilder;

impl TransactionBuilder for EvmTransactionBuilder {
    type Params = EvmTxParams;

    fn build(&self, params: Self::Params) -> Result<Transaction, ChainError> {
        // TODO: Implement EIP-1559 RLP encoding
        tracing::debug!(chain_id = params.chain_id, to = %params.to, "building EVM transaction");

        let raw_data = vec![]; // TODO: RLP encode
        let sign_hash = vec![]; // TODO: keccak256 of RLP

        Ok(Transaction {
            chain: ChainType::Evm { chain_id: params.chain_id },
            raw_data,
            sign_hash,
        })
    }
}
