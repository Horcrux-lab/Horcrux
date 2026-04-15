//! Ethereum / EVM transaction builder.
//!
//! Implements EIP-1559 (type 2) transaction RLP encoding and signing hash
//! computation.

use super::{keccak256, ChainError, ChainType, Transaction, TransactionBuilder};
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
        tracing::debug!(chain_id = params.chain_id, to = %params.to, "building EVM transaction");

        let to_bytes = parse_address(&params.to)?;

        // RLP-encode the EIP-1559 inner list:
        // [chain_id, nonce, max_priority_fee_per_gas, max_fee_per_gas,
        //  gas_limit, to, value, data, access_list(empty)]
        let items: Vec<Vec<u8>> = vec![
            rlp_encode_u64(params.chain_id),
            rlp_encode_u64(params.nonce),
            rlp_encode_u128(params.max_priority_fee_per_gas),
            rlp_encode_u128(params.max_fee_per_gas),
            rlp_encode_u64(params.gas_limit),
            rlp_encode_bytes(&to_bytes),
            rlp_encode_u128(params.value),
            rlp_encode_bytes(&params.data),
            rlp_encode_list(&[]), // empty access_list
        ];

        let inner_payload = rlp_encode_list_raw(&items);

        // EIP-2718 typed envelope: 0x02 || RLP(...)
        let mut raw_data = Vec::with_capacity(1 + inner_payload.len());
        raw_data.push(0x02);
        raw_data.extend_from_slice(&inner_payload);

        let sign_hash = keccak256(&raw_data).to_vec();

        Ok(Transaction {
            chain: ChainType::Evm {
                chain_id: params.chain_id,
            },
            raw_data,
            sign_hash,
        })
    }
}

// ---------------------------------------------------------------------------
// Address parsing
// ---------------------------------------------------------------------------

fn parse_address(addr: &str) -> Result<[u8; 20], ChainError> {
    let hex_str = addr.strip_prefix("0x").unwrap_or(addr);
    let bytes = hex::decode(hex_str)
        .map_err(|e| ChainError::InvalidAddress(format!("bad hex: {e}")))?;
    if bytes.len() != 20 {
        return Err(ChainError::InvalidAddress(format!(
            "expected 20 bytes, got {}",
            bytes.len()
        )));
    }
    let mut out = [0u8; 20];
    out.copy_from_slice(&bytes);
    Ok(out)
}

// ---------------------------------------------------------------------------
// Minimal RLP encoder (sufficient for transaction encoding)
// ---------------------------------------------------------------------------

/// RLP-encode a single byte-string.
fn rlp_encode_bytes(data: &[u8]) -> Vec<u8> {
    if data.len() == 1 && data[0] < 0x80 {
        return data.to_vec();
    }
    let mut out = rlp_length_prefix(data.len(), 0x80);
    out.extend_from_slice(data);
    out
}

/// RLP-encode a u64 as the shortest big-endian representation.
fn rlp_encode_u64(val: u64) -> Vec<u8> {
    if val == 0 {
        return rlp_encode_bytes(&[]);
    }
    let be = val.to_be_bytes();
    let start = be.iter().position(|&b| b != 0).unwrap_or(7);
    rlp_encode_bytes(&be[start..])
}

/// RLP-encode a u128 as the shortest big-endian representation.
fn rlp_encode_u128(val: u128) -> Vec<u8> {
    if val == 0 {
        return rlp_encode_bytes(&[]);
    }
    let be = val.to_be_bytes();
    let start = be.iter().position(|&b| b != 0).unwrap_or(15);
    rlp_encode_bytes(&be[start..])
}

/// RLP-encode an ordered list from pre-encoded items.
fn rlp_encode_list_raw(items: &[Vec<u8>]) -> Vec<u8> {
    let payload: Vec<u8> = items.iter().flat_map(|i| i.iter().copied()).collect();
    let mut out = rlp_length_prefix(payload.len(), 0xc0);
    out.extend_from_slice(&payload);
    out
}

/// RLP-encode an empty list or list of byte-strings.
fn rlp_encode_list(items: &[&[u8]]) -> Vec<u8> {
    let encoded: Vec<Vec<u8>> = items.iter().map(|i| rlp_encode_bytes(i)).collect();
    rlp_encode_list_raw(&encoded)
}

/// Build the RLP length prefix for `len` bytes with the given `offset` (0x80
/// for strings, 0xc0 for lists).
fn rlp_length_prefix(len: usize, offset: u8) -> Vec<u8> {
    if len < 56 {
        vec![offset + len as u8]
    } else {
        let len_be = (len as u64).to_be_bytes();
        let start = len_be.iter().position(|&b| b != 0).unwrap_or(7);
        let len_bytes = &len_be[start..];
        let mut out = vec![offset + 55 + len_bytes.len() as u8];
        out.extend_from_slice(len_bytes);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rlp_encode_u64() {
        // 0 encodes as empty string 0x80
        assert_eq!(rlp_encode_u64(0), vec![0x80]);
        // 1 encodes as single byte
        assert_eq!(rlp_encode_u64(1), vec![0x01]);
        // 127 (0x7f) encodes as single byte
        assert_eq!(rlp_encode_u64(127), vec![0x7f]);
        // 128 (0x80) needs a length prefix
        assert_eq!(rlp_encode_u64(128), vec![0x81, 0x80]);
        // 256 = 0x0100
        assert_eq!(rlp_encode_u64(256), vec![0x82, 0x01, 0x00]);
    }

    #[test]
    fn test_rlp_encode_bytes_empty() {
        assert_eq!(rlp_encode_bytes(&[]), vec![0x80]);
    }

    #[test]
    fn test_rlp_encode_bytes_single() {
        assert_eq!(rlp_encode_bytes(&[0x42]), vec![0x42]);
        assert_eq!(rlp_encode_bytes(&[0x80]), vec![0x81, 0x80]);
    }

    #[test]
    fn test_rlp_empty_list() {
        assert_eq!(rlp_encode_list(&[]), vec![0xc0]);
    }

    #[test]
    fn test_parse_address_valid() {
        let addr = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
        let bytes = parse_address(addr).unwrap();
        assert_eq!(bytes.len(), 20);
    }

    #[test]
    fn test_parse_address_no_prefix() {
        let addr = "d8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
        let bytes = parse_address(addr).unwrap();
        assert_eq!(bytes.len(), 20);
    }

    #[test]
    fn test_parse_address_bad_length() {
        assert!(parse_address("0xabcd").is_err());
    }

    #[test]
    fn test_build_eip1559_tx() {
        let builder = EvmTransactionBuilder;
        let params = EvmTxParams {
            to: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045".to_string(),
            value: 1_000_000_000_000_000_000, // 1 ETH
            nonce: 0,
            gas_limit: 21000,
            max_fee_per_gas: 30_000_000_000,
            max_priority_fee_per_gas: 1_000_000_000,
            chain_id: 1,
            data: vec![],
        };
        let tx = builder.build(params).unwrap();

        // Type 2 envelope starts with 0x02
        assert_eq!(tx.raw_data[0], 0x02);
        // Sign hash is 32 bytes (keccak256)
        assert_eq!(tx.sign_hash.len(), 32);
        // Chain type matches
        assert_eq!(tx.chain, ChainType::Evm { chain_id: 1 });
    }

    #[test]
    fn test_build_eip1559_with_data() {
        let builder = EvmTransactionBuilder;
        let params = EvmTxParams {
            to: "0x0000000000000000000000000000000000000001".to_string(),
            value: 0,
            nonce: 42,
            gas_limit: 100_000,
            max_fee_per_gas: 50_000_000_000,
            max_priority_fee_per_gas: 2_000_000_000,
            chain_id: 137, // Polygon
            data: hex::decode("a9059cbb").unwrap(), // transfer selector
        };
        let tx = builder.build(params).unwrap();
        assert_eq!(tx.raw_data[0], 0x02);
        assert_eq!(tx.sign_hash.len(), 32);
        assert_eq!(tx.chain, ChainType::Evm { chain_id: 137 });
    }

    #[test]
    fn test_different_params_produce_different_hashes() {
        let builder = EvmTransactionBuilder;
        let base = EvmTxParams {
            to: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045".to_string(),
            value: 1_000_000_000_000_000_000,
            nonce: 0,
            gas_limit: 21000,
            max_fee_per_gas: 30_000_000_000,
            max_priority_fee_per_gas: 1_000_000_000,
            chain_id: 1,
            data: vec![],
        };
        let tx1 = builder.build(base.clone()).unwrap();
        let mut modified = base;
        modified.nonce = 1;
        let tx2 = builder.build(modified).unwrap();
        assert_ne!(tx1.sign_hash, tx2.sign_hash);
    }

    #[test]
    fn test_chain_id_affects_hash() {
        let builder = EvmTransactionBuilder;
        let base = EvmTxParams {
            to: "0x0000000000000000000000000000000000000001".to_string(),
            value: 0,
            nonce: 0,
            gas_limit: 21000,
            max_fee_per_gas: 1,
            max_priority_fee_per_gas: 1,
            chain_id: 1,
            data: vec![],
        };
        let tx1 = builder.build(base.clone()).unwrap();
        let mut base2 = base;
        base2.chain_id = 5;
        let tx2 = builder.build(base2).unwrap();
        assert_ne!(tx1.sign_hash, tx2.sign_hash);
    }
}
