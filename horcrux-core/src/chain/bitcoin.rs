//! Bitcoin transaction builder (PSBT-based).

use super::{ChainError, ChainType, Transaction, TransactionBuilder};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BtcTxParams {
    pub inputs: Vec<BtcInput>,
    pub outputs: Vec<BtcOutput>,
    pub testnet: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BtcInput {
    pub txid: String,
    pub vout: u32,
    pub value: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BtcOutput {
    pub address: String,
    pub value: u64,
}

pub struct BtcTransactionBuilder;

impl TransactionBuilder for BtcTransactionBuilder {
    type Params = BtcTxParams;

    fn build(&self, params: Self::Params) -> Result<Transaction, ChainError> {
        // TODO: Implement PSBT construction
        tracing::debug!(inputs = params.inputs.len(), outputs = params.outputs.len(), "building BTC transaction");

        let raw_data = vec![]; // TODO: PSBT serialization
        let sign_hash = vec![]; // TODO: sighash computation

        Ok(Transaction {
            chain: ChainType::Bitcoin { testnet: params.testnet },
            raw_data,
            sign_hash,
        })
    }
}
