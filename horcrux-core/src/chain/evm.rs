//! Ethereum / EVM transaction builder.
//!
//! Implements EIP-1559 (type 2) transaction RLP encoding and signing hash
//! computation.

use super::{keccak256, ChainError, ChainType, Transaction, TransactionBuilder};
use serde::{Deserialize, Serialize};

/// EIP-1559 Ethereum transaction parameters.
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

/// Builds an EIP-1559 Ethereum transaction and computes the keccak256 signing hash.
pub struct EvmTransactionBuilder;

impl TransactionBuilder for EvmTransactionBuilder {
    type Params = EvmTxParams;

    fn build(&self, params: Self::Params) -> Result<Transaction, ChainError> {
        tracing::debug!(chain_id = params.chain_id, to = %params.to, "building EVM transaction");

        // H10: refuse to sign a transaction whose worst-case total
        // cost (gas_limit × max_fee_per_gas + value) overflows u128.
        // Such a transaction can never be included on chain, and
        // performing the math unchecked leaks into downstream UIs and
        // can panic on debug builds. Return a typed error instead.
        let _ = max_total_cost_wei(&params)?;

        // Sanity: max_priority_fee_per_gas ≤ max_fee_per_gas per EIP-1559.
        // A well-formed RPC fee oracle will never violate this, but a
        // malicious UI could — catching it here prevents an eventually
        // rejected broadcast while also hardening against "tip stuffing"
        // where a manipulated priority fee forces higher than advertised
        // total cost.
        if params.max_priority_fee_per_gas > params.max_fee_per_gas {
            return Err(ChainError::ArithmeticOverflow(
                "max_priority_fee_per_gas > max_fee_per_gas",
            ));
        }

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

/// Compute the worst-case total wei this transaction could debit from the
/// sender: `gas_limit * max_fee_per_gas + value`, saturating on overflow
/// to a typed error rather than panicking or silently wrapping.
///
/// Exposed so UI layers and FFI callers can preview the upper bound
/// before asking the user for approval (audit finding H10).
pub fn max_total_cost_wei(params: &EvmTxParams) -> Result<u128, ChainError> {
    let gas_cost = (params.gas_limit as u128)
        .checked_mul(params.max_fee_per_gas)
        .ok_or(ChainError::ArithmeticOverflow(
            "gas_limit * max_fee_per_gas",
        ))?;
    gas_cost
        .checked_add(params.value)
        .ok_or(ChainError::ArithmeticOverflow(
            "gas_limit * max_fee_per_gas + value",
        ))
}

fn parse_address(addr: &str) -> Result<[u8; 20], ChainError> {
    let hex_str = addr.strip_prefix("0x").unwrap_or(addr);
    let bytes =
        hex::decode(hex_str).map_err(|e| ChainError::InvalidAddress(format!("bad hex: {e}")))?;
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

// ---------------------------------------------------------------------------
// Calldata decoder — minimal ERC-20 / ERC-721 selector recognition used by
// the wallet's approval sheet to surface what an EVM transaction actually
// does, rather than presenting an opaque hex blob to the user.
//
// Audit finding C4 ("EVM blind signing"): Ledger / Trezor have been
// criticised historically for allowing users to sign `approve(spender, max)`
// calls without understanding them; this is the attack surface that
// fake-airdrop scams exploit to drain wallets.
//
// We do not attempt to be a full ABI parser. We recognise the handful of
// selectors that account for the vast majority of malicious approvals
// seen in the wild, and expose a structured enum that the iOS approval
// sheet can render as human-readable explanations ("Approve UNLIMITED
// USDT to 0xabc…?").
// ---------------------------------------------------------------------------

/// Structured view of what an outgoing EVM calldata blob is asking the
/// signer to do. Anything that is not a recognised selector surfaces as
/// `Unknown` so the UI can warn: "This transaction cannot be decoded —
/// are you sure?".
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum DecodedCall {
    /// Plain value transfer (empty calldata) — ETH/native token move.
    Transfer,
    /// `transfer(address,uint256)` — ERC-20 token send.
    Erc20Transfer { to: String, amount_hex: String },
    /// `transferFrom(address,address,uint256)` — ERC-20 pull.
    Erc20TransferFrom {
        from: String,
        to: String,
        amount_hex: String,
    },
    /// `approve(address,uint256)` — ERC-20 allowance grant.
    /// `is_unlimited` is true when the amount is at least 2^255 (the
    /// conventional "infinite approval" pattern; exact 2^256-1 and
    /// anything near it is treated as unlimited for UX purposes).
    Erc20Approve {
        spender: String,
        amount_hex: String,
        is_unlimited: bool,
    },
    /// `setApprovalForAll(address,bool)` — ERC-721 / ERC-1155 blanket
    /// approval. Almost always the signature used to drain NFT wallets.
    SetApprovalForAll { operator: String, approved: bool },
    /// Calldata present but selector unknown. UI should render as
    /// "unverified — proceed with caution".
    Unknown {
        selector_hex: String,
        data_len: usize,
    },
}

/// Threshold at which an approval is flagged as "unlimited" in the UI.
/// Many tokens normalise max approvals to `type(uint256).max`, but some
/// approval-bait contracts use `2^255` or similar large constants —
/// treat any amount with the top bit set as effectively unlimited.
#[allow(dead_code)]
const UNLIMITED_APPROVAL_THRESHOLD_BIT: usize = 255;

/// Decode an outgoing EVM calldata blob into a structured [`DecodedCall`].
///
/// Returns [`DecodedCall::Transfer`] for empty data (value-only send),
/// [`DecodedCall::Unknown`] for anything we do not recognise. Never
/// returns an error — the UI must always have *something* to show; an
/// opaque selector is still better than a hex dump.
pub fn decode_evm_calldata(data: &[u8]) -> DecodedCall {
    if data.is_empty() {
        return DecodedCall::Transfer;
    }
    if data.len() < 4 {
        return DecodedCall::Unknown {
            selector_hex: hex::encode(data),
            data_len: data.len(),
        };
    }

    let selector = &data[0..4];
    let args = &data[4..];

    match selector {
        // transfer(address,uint256) = 0xa9059cbb
        [0xa9, 0x05, 0x9c, 0xbb] if args.len() >= 64 => {
            let to = decode_address_arg(&args[0..32]);
            let amount_hex = hex::encode(&args[32..64]);
            DecodedCall::Erc20Transfer { to, amount_hex }
        }
        // transferFrom(address,address,uint256) = 0x23b872dd
        [0x23, 0xb8, 0x72, 0xdd] if args.len() >= 96 => {
            let from = decode_address_arg(&args[0..32]);
            let to = decode_address_arg(&args[32..64]);
            let amount_hex = hex::encode(&args[64..96]);
            DecodedCall::Erc20TransferFrom {
                from,
                to,
                amount_hex,
            }
        }
        // approve(address,uint256) = 0x095ea7b3
        [0x09, 0x5e, 0xa7, 0xb3] if args.len() >= 64 => {
            let spender = decode_address_arg(&args[0..32]);
            let amount_bytes: &[u8; 32] = args[32..64].try_into().unwrap_or(&[0u8; 32]);
            let is_unlimited = is_amount_unlimited(amount_bytes);
            DecodedCall::Erc20Approve {
                spender,
                amount_hex: hex::encode(amount_bytes),
                is_unlimited,
            }
        }
        // setApprovalForAll(address,bool) = 0xa22cb465
        [0xa2, 0x2c, 0xb4, 0x65] if args.len() >= 64 => {
            let operator = decode_address_arg(&args[0..32]);
            let approved = args[32..64].iter().any(|&b| b != 0);
            DecodedCall::SetApprovalForAll { operator, approved }
        }
        _ => DecodedCall::Unknown {
            selector_hex: hex::encode(selector),
            data_len: data.len(),
        },
    }
}

/// A 32-byte address argument is the low 20 bytes of the word.
fn decode_address_arg(word: &[u8]) -> String {
    if word.len() < 32 {
        return "0x0".into();
    }
    format!("0x{}", hex::encode(&word[12..32]))
}

/// Check whether a uint256 amount qualifies as "unlimited" for UX warning
/// purposes. We flag anything with bit 255 or higher set — that captures
/// `type(uint256).max`, the common `2^256-1`, and most of the "practically
/// infinite" values that approval-bait contracts use.
fn is_amount_unlimited(amount: &[u8; 32]) -> bool {
    // Bit 255 is the MSB of the first byte.
    amount[0] & 0x80 != 0 || {
        // Also flag the classic `type(uint256).max - k` patterns for
        // small k, where the top byte is 0xFF even though bit 255 is
        // also set (already caught above). Fallthrough: if the first 16
        // bytes are all 0xFF we treat as unlimited regardless.
        amount[..16].iter().all(|&b| b == 0xff)
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
            chain_id: 137,                          // Polygon
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

    #[test]
    fn test_eip1559_large_chain_id() {
        // chain_id > 255 requires multi-byte RLP encoding
        let builder = EvmTransactionBuilder;
        let params = EvmTxParams {
            to: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045".to_string(),
            value: 1_000_000_000_000_000_000,
            nonce: 5,
            gas_limit: 21000,
            max_fee_per_gas: 30_000_000_000,
            max_priority_fee_per_gas: 1_000_000_000,
            chain_id: 42161, // Arbitrum One
            data: vec![],
        };
        let tx = builder.build(params).unwrap();
        assert_eq!(tx.raw_data[0], 0x02);
        assert_eq!(tx.sign_hash.len(), 32);
        assert_eq!(tx.chain, ChainType::Evm { chain_id: 42161 });

        // Verify a different large chain_id produces a different hash
        let params2 = EvmTxParams {
            to: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045".to_string(),
            value: 1_000_000_000_000_000_000,
            nonce: 5,
            gas_limit: 21000,
            max_fee_per_gas: 30_000_000_000,
            max_priority_fee_per_gas: 1_000_000_000,
            chain_id: 8453, // Base
            data: vec![],
        };
        let tx2 = builder.build(params2).unwrap();
        assert_ne!(tx.sign_hash, tx2.sign_hash);
    }

    #[test]
    fn test_eip1559_zero_gas_limit() {
        let builder = EvmTransactionBuilder;
        let params = EvmTxParams {
            to: "0x0000000000000000000000000000000000000001".to_string(),
            value: 0,
            nonce: 0,
            gas_limit: 0,
            max_fee_per_gas: 1,
            max_priority_fee_per_gas: 1,
            chain_id: 1,
            data: vec![],
        };
        // Zero gas limit is technically valid at the encoding level
        let tx = builder.build(params).unwrap();
        assert_eq!(tx.raw_data[0], 0x02);
        assert_eq!(tx.sign_hash.len(), 32);
    }

    // --- H10: checked fee / value arithmetic ---

    fn overflow_params() -> EvmTxParams {
        EvmTxParams {
            to: "0x0000000000000000000000000000000000000001".to_string(),
            value: 0,
            nonce: 0,
            gas_limit: u64::MAX,
            max_fee_per_gas: u128::MAX,
            max_priority_fee_per_gas: u128::MAX,
            chain_id: 1,
            data: vec![],
        }
    }

    #[test]
    fn test_max_total_cost_gas_overflow_is_rejected() {
        let params = overflow_params();
        match max_total_cost_wei(&params) {
            Err(ChainError::ArithmeticOverflow(msg)) => {
                assert!(msg.contains("max_fee_per_gas"));
            }
            other => panic!("expected ArithmeticOverflow, got {:?}", other),
        }
    }

    #[test]
    fn test_max_total_cost_value_overflow_is_rejected() {
        // gas_limit=1 * max_fee_per_gas=1 = 1; then 1 + u128::MAX overflows.
        let params = EvmTxParams {
            to: "0x0000000000000000000000000000000000000001".to_string(),
            value: u128::MAX,
            nonce: 0,
            gas_limit: 1,
            max_fee_per_gas: 1,
            max_priority_fee_per_gas: 1,
            chain_id: 1,
            data: vec![],
        };
        match max_total_cost_wei(&params) {
            Err(ChainError::ArithmeticOverflow(msg)) => {
                assert!(msg.contains("value"));
            }
            other => panic!("expected ArithmeticOverflow, got {:?}", other),
        }
    }

    #[test]
    fn test_build_rejects_overflowing_tx() {
        let builder = EvmTransactionBuilder;
        assert!(matches!(
            builder.build(overflow_params()),
            Err(ChainError::ArithmeticOverflow(_))
        ));
    }

    #[test]
    fn test_build_rejects_priority_gt_max_fee() {
        let builder = EvmTransactionBuilder;
        let params = EvmTxParams {
            to: "0x0000000000000000000000000000000000000001".to_string(),
            value: 0,
            nonce: 0,
            gas_limit: 21_000,
            max_fee_per_gas: 10,
            max_priority_fee_per_gas: 100,
            chain_id: 1,
            data: vec![],
        };
        assert!(matches!(
            builder.build(params),
            Err(ChainError::ArithmeticOverflow(_))
        ));
    }

    #[test]
    fn test_max_total_cost_normal_case() {
        let params = EvmTxParams {
            to: "0x0000000000000000000000000000000000000001".to_string(),
            value: 1_000_000_000_000_000_000, // 1 ETH
            nonce: 0,
            gas_limit: 21_000,
            max_fee_per_gas: 30_000_000_000, // 30 gwei
            max_priority_fee_per_gas: 1_000_000_000,
            chain_id: 1,
            data: vec![],
        };
        let cost = max_total_cost_wei(&params).unwrap();
        // 21000 * 30e9 + 1e18 = 630000 * 1e9 + 1e18 = 6.3e14 + 1e18
        assert_eq!(
            cost,
            21_000u128 * 30_000_000_000 + 1_000_000_000_000_000_000
        );
    }
}

#[cfg(test)]
mod decode_tests {
    use super::*;

    fn hex_decode(s: &str) -> Vec<u8> {
        hex::decode(s).unwrap()
    }

    #[test]
    fn decode_empty_is_transfer() {
        assert_eq!(decode_evm_calldata(&[]), DecodedCall::Transfer);
    }

    #[test]
    fn decode_erc20_transfer() {
        // transfer(0x1111...1111, 1000)
        let mut data = vec![0xa9, 0x05, 0x9c, 0xbb];
        data.extend_from_slice(&[0u8; 12]);
        data.extend_from_slice(&[0x11u8; 20]);
        let mut amt = [0u8; 32];
        amt[30] = 0x03;
        amt[31] = 0xe8; // 1000
        data.extend_from_slice(&amt);

        match decode_evm_calldata(&data) {
            DecodedCall::Erc20Transfer { to, amount_hex } => {
                assert_eq!(to, "0x1111111111111111111111111111111111111111");
                assert!(amount_hex.ends_with("03e8"));
            }
            x => panic!("expected Erc20Transfer, got {:?}", x),
        }
    }

    #[test]
    fn decode_erc20_approve_unlimited_flagged() {
        // approve(0xabcd..., 2^256-1)
        let mut data = vec![0x09, 0x5e, 0xa7, 0xb3];
        data.extend_from_slice(&[0u8; 12]);
        data.extend_from_slice(&[0xab; 20]);
        data.extend_from_slice(&[0xff; 32]);

        match decode_evm_calldata(&data) {
            DecodedCall::Erc20Approve {
                is_unlimited,
                spender,
                ..
            } => {
                assert!(is_unlimited, "max-approval must be flagged");
                assert!(spender.starts_with("0x"));
                assert_eq!(spender.len(), 42);
            }
            x => panic!("expected Erc20Approve, got {:?}", x),
        }
    }

    #[test]
    fn decode_erc20_approve_small_not_flagged() {
        // approve(0xabcd..., 100)
        let mut data = vec![0x09, 0x5e, 0xa7, 0xb3];
        data.extend_from_slice(&[0u8; 12]);
        data.extend_from_slice(&[0xab; 20]);
        let mut amt = [0u8; 32];
        amt[31] = 0x64; // 100
        data.extend_from_slice(&amt);

        match decode_evm_calldata(&data) {
            DecodedCall::Erc20Approve { is_unlimited, .. } => {
                assert!(!is_unlimited);
            }
            x => panic!("expected Erc20Approve, got {:?}", x),
        }
    }

    #[test]
    fn decode_set_approval_for_all_true() {
        let mut data = vec![0xa2, 0x2c, 0xb4, 0x65];
        data.extend_from_slice(&[0u8; 12]);
        data.extend_from_slice(&[0xcd; 20]);
        let mut flag = [0u8; 32];
        flag[31] = 1;
        data.extend_from_slice(&flag);

        match decode_evm_calldata(&data) {
            DecodedCall::SetApprovalForAll { approved, .. } => assert!(approved),
            x => panic!("{:?}", x),
        }
    }

    #[test]
    fn decode_unknown_selector() {
        let data = hex_decode("deadbeef00000000");
        match decode_evm_calldata(&data) {
            DecodedCall::Unknown { selector_hex, .. } => {
                assert_eq!(selector_hex, "deadbeef");
            }
            x => panic!("{:?}", x),
        }
    }

    #[test]
    fn decode_short_calldata() {
        let data = vec![0x12, 0x34];
        match decode_evm_calldata(&data) {
            DecodedCall::Unknown { data_len, .. } => assert_eq!(data_len, 2),
            x => panic!("{:?}", x),
        }
    }

    #[test]
    fn is_amount_unlimited_threshold() {
        // Exactly 2^255 = top bit set.
        let mut at_threshold = [0u8; 32];
        at_threshold[0] = 0x80;
        assert!(is_amount_unlimited(&at_threshold));

        // Just below threshold.
        let mut below = [0u8; 32];
        below[0] = 0x7f;
        below[1] = 0xff;
        assert!(!is_amount_unlimited(&below));

        // type(uint256).max
        assert!(is_amount_unlimited(&[0xff; 32]));
    }

    #[test]
    fn decode_handles_trailing_junk() {
        // approve with extra trailing bytes — real-world calldata sometimes
        // has padding; the decoder should still return the approval.
        let mut data = vec![0x09, 0x5e, 0xa7, 0xb3];
        data.extend_from_slice(&[0u8; 12]);
        data.extend_from_slice(&[0xab; 20]);
        data.extend_from_slice(&[0xff; 32]);
        data.extend_from_slice(b"junk");

        assert!(matches!(
            decode_evm_calldata(&data),
            DecodedCall::Erc20Approve { .. }
        ));
    }
}
