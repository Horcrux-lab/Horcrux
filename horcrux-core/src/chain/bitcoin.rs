//! Bitcoin transaction builder (P2WPKH / native segwit).
//!
//! Implements basic transaction serialization and BIP-143 sighash computation
//! for spending P2WPKH outputs.

use super::{ChainError, ChainType, Transaction, TransactionBuilder};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BtcTxParams {
    pub inputs: Vec<BtcInput>,
    pub outputs: Vec<BtcOutput>,
    pub testnet: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BtcInput {
    /// Previous transaction id (hex, big-endian display order).
    pub txid: String,
    /// Output index in the previous transaction.
    pub vout: u32,
    /// Value of the UTXO being spent (satoshis) — needed for BIP-143 sighash.
    pub value: u64,
    /// The 20-byte pubkey-hash for the P2WPKH scriptCode.
    /// If omitted, the sighash for this input will use all-zero placeholder.
    #[serde(default)]
    pub pubkey_hash: Option<Vec<u8>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BtcOutput {
    pub address: String,
    pub value: u64,
    /// Raw scriptPubKey. When provided, `address` is informational only.
    #[serde(default)]
    pub script_pubkey: Option<Vec<u8>>,
}

pub struct BtcTransactionBuilder;

/// SIGHASH_ALL
const SIGHASH_ALL: u32 = 1;
/// Transaction version 2 (supports BIP-68 relative lock-time).
const TX_VERSION: u32 = 2;

impl TransactionBuilder for BtcTransactionBuilder {
    type Params = BtcTxParams;

    fn build(&self, params: Self::Params) -> Result<Transaction, ChainError> {
        tracing::debug!(
            inputs = params.inputs.len(),
            outputs = params.outputs.len(),
            "building BTC transaction"
        );

        if params.inputs.is_empty() {
            return Err(ChainError::Other("transaction must have at least one input".into()));
        }
        if params.outputs.is_empty() {
            return Err(ChainError::Other("transaction must have at least one output".into()));
        }

        let raw_data = serialize_witness_tx(&params)?;

        // BIP-143 sighash for first input (index 0).  The caller can later
        // request sighash for other indices via `bip143_sighash`.
        let sign_hash = bip143_sighash(&params, 0)?.to_vec();

        Ok(Transaction {
            chain: ChainType::Bitcoin {
                testnet: params.testnet,
            },
            raw_data,
            sign_hash,
        })
    }
}

// ---------------------------------------------------------------------------
// Public helpers
// ---------------------------------------------------------------------------

/// Compute the BIP-143 sighash for input at `index`.
pub fn bip143_sighash(params: &BtcTxParams, index: usize) -> Result<[u8; 32], ChainError> {
    if index >= params.inputs.len() {
        return Err(ChainError::Other("input index out of range".into()));
    }

    let hash_prevouts = double_sha256(&serialize_prevouts(&params.inputs));
    let hash_sequence = double_sha256(&serialize_sequences(&params.inputs));
    let hash_outputs = double_sha256(&serialize_outputs(&params.outputs)?);

    let input = &params.inputs[index];
    let outpoint = serialize_outpoint(input)?;

    // scriptCode for P2WPKH: OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
    let pubkey_hash = input
        .pubkey_hash
        .as_deref()
        .unwrap_or(&[0u8; 20]);
    let script_code = p2wpkh_script_code(pubkey_hash);

    let mut preimage = Vec::with_capacity(156);
    preimage.extend_from_slice(&TX_VERSION.to_le_bytes());
    preimage.extend_from_slice(&hash_prevouts);
    preimage.extend_from_slice(&hash_sequence);
    preimage.extend_from_slice(&outpoint);
    push_var_bytes(&mut preimage, &script_code);
    preimage.extend_from_slice(&input.value.to_le_bytes());
    preimage.extend_from_slice(&0xFFFF_FFFEu32.to_le_bytes()); // sequence (rbf-enabled)
    preimage.extend_from_slice(&hash_outputs);
    preimage.extend_from_slice(&0u32.to_le_bytes()); // locktime
    preimage.extend_from_slice(&SIGHASH_ALL.to_le_bytes());

    Ok(double_sha256(&preimage))
}

/// HASH160 = RIPEMD160(SHA256(data)).
pub fn hash160(data: &[u8]) -> [u8; 20] {
    use ripemd::Ripemd160;
    let sha = Sha256::digest(data);
    let ripe = Ripemd160::digest(sha);
    let mut out = [0u8; 20];
    out.copy_from_slice(&ripe);
    out
}

// ---------------------------------------------------------------------------
// Serialisation helpers
// ---------------------------------------------------------------------------

fn double_sha256(data: &[u8]) -> [u8; 32] {
    let first = Sha256::digest(data);
    let second = Sha256::digest(first);
    let mut out = [0u8; 32];
    out.copy_from_slice(&second);
    out
}

fn parse_txid(txid: &str) -> Result<[u8; 32], ChainError> {
    let mut bytes = hex::decode(txid)
        .map_err(|e| ChainError::InvalidAddress(format!("bad txid hex: {e}")))?;
    if bytes.len() != 32 {
        return Err(ChainError::InvalidAddress(format!(
            "txid must be 32 bytes, got {}",
            bytes.len()
        )));
    }
    // Bitcoin txids are displayed big-endian but serialised little-endian.
    bytes.reverse();
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

fn serialize_outpoint(input: &BtcInput) -> Result<Vec<u8>, ChainError> {
    let txid = parse_txid(&input.txid)?;
    let mut out = Vec::with_capacity(36);
    out.extend_from_slice(&txid);
    out.extend_from_slice(&input.vout.to_le_bytes());
    Ok(out)
}

fn serialize_prevouts(inputs: &[BtcInput]) -> Vec<u8> {
    let mut data = Vec::with_capacity(inputs.len() * 36);
    for inp in inputs {
        // unwrap: validation happens elsewhere; this is internal
        if let Ok(op) = serialize_outpoint(inp) {
            data.extend_from_slice(&op);
        }
    }
    data
}

fn serialize_sequences(inputs: &[BtcInput]) -> Vec<u8> {
    let mut data = Vec::with_capacity(inputs.len() * 4);
    for _ in inputs {
        data.extend_from_slice(&0xFFFF_FFFEu32.to_le_bytes());
    }
    data
}

fn serialize_outputs(outputs: &[BtcOutput]) -> Result<Vec<u8>, ChainError> {
    let mut data = Vec::new();
    for out in outputs {
        data.extend_from_slice(&out.value.to_le_bytes());
        let spk = out
            .script_pubkey
            .as_deref()
            .ok_or_else(|| {
                ChainError::EncodingError("output must have script_pubkey".into())
            })?;
        push_var_bytes(&mut data, spk);
    }
    Ok(data)
}

/// Serialize a full segwit transaction (marker + flag + witness).
fn serialize_witness_tx(params: &BtcTxParams) -> Result<Vec<u8>, ChainError> {
    let mut buf = Vec::new();
    // version
    buf.extend_from_slice(&TX_VERSION.to_le_bytes());
    // segwit marker + flag
    buf.push(0x00);
    buf.push(0x01);
    // input count
    push_varint(&mut buf, params.inputs.len() as u64);
    for inp in &params.inputs {
        buf.extend_from_slice(&serialize_outpoint(inp)?);
        // empty scriptSig for segwit
        buf.push(0x00);
        // sequence
        buf.extend_from_slice(&0xFFFF_FFFEu32.to_le_bytes());
    }
    // output count
    push_varint(&mut buf, params.outputs.len() as u64);
    for out in &params.outputs {
        buf.extend_from_slice(&out.value.to_le_bytes());
        let spk = out.script_pubkey.as_deref().ok_or_else(|| {
            ChainError::EncodingError("output must have script_pubkey".into())
        })?;
        push_var_bytes(&mut buf, spk);
    }
    // witness (empty placeholders — real witness is added after signing)
    #[allow(clippy::same_item_push)]
    for _ in &params.inputs {
        buf.push(0x00); // 0 witness items
    }
    // locktime
    buf.extend_from_slice(&0u32.to_le_bytes());
    Ok(buf)
}

/// P2WPKH scriptCode: OP_DUP OP_HASH160 <20-byte-hash> OP_EQUALVERIFY OP_CHECKSIG
fn p2wpkh_script_code(pubkey_hash: &[u8]) -> Vec<u8> {
    let mut sc = Vec::with_capacity(25);
    sc.push(0x76); // OP_DUP
    sc.push(0xa9); // OP_HASH160
    sc.push(0x14); // push 20 bytes
    sc.extend_from_slice(pubkey_hash);
    sc.push(0x88); // OP_EQUALVERIFY
    sc.push(0xac); // OP_CHECKSIG
    sc
}

fn push_varint(buf: &mut Vec<u8>, val: u64) {
    if val < 0xfd {
        buf.push(val as u8);
    } else if val <= 0xffff {
        buf.push(0xfd);
        buf.extend_from_slice(&(val as u16).to_le_bytes());
    } else if val <= 0xffff_ffff {
        buf.push(0xfe);
        buf.extend_from_slice(&(val as u32).to_le_bytes());
    } else {
        buf.push(0xff);
        buf.extend_from_slice(&val.to_le_bytes());
    }
}

fn push_var_bytes(buf: &mut Vec<u8>, data: &[u8]) {
    push_varint(buf, data.len() as u64);
    buf.extend_from_slice(data);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dummy_params() -> BtcTxParams {
        BtcTxParams {
            inputs: vec![BtcInput {
                txid: "a".repeat(64), // 32 bytes of 0xaa
                vout: 0,
                value: 100_000,
                pubkey_hash: Some(vec![0xab; 20]),
            }],
            outputs: vec![BtcOutput {
                address: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4".into(),
                value: 90_000,
                script_pubkey: Some(vec![
                    0x00, 0x14, // witness v0, push 20
                    0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
                    0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23,
                    0xf1, 0x43, 0x3b, 0xd6,
                ]),
            }],
            testnet: false,
        }
    }

    #[test]
    fn test_double_sha256() {
        let hash = double_sha256(b"hello");
        assert_eq!(hash.len(), 32);
        // double-sha256("hello") is deterministic
        let hash2 = double_sha256(b"hello");
        assert_eq!(hash, hash2);
    }

    #[test]
    fn test_hash160() {
        let h = hash160(b"test");
        assert_eq!(h.len(), 20);
    }

    #[test]
    fn test_parse_txid() {
        let txid = "aa".repeat(32);
        let parsed = parse_txid(&txid).unwrap();
        // all 0xaa bytes, reversed is still all 0xaa
        assert_eq!(parsed, [0xaa; 32]);
    }

    #[test]
    fn test_parse_txid_bad() {
        assert!(parse_txid("not_hex").is_err());
        assert!(parse_txid("aabb").is_err());
    }

    #[test]
    fn test_build_btc_tx() {
        let builder = BtcTransactionBuilder;
        let params = dummy_params();
        let tx = builder.build(params).unwrap();

        // sign_hash should be 32 bytes
        assert_eq!(tx.sign_hash.len(), 32);
        // raw_data starts with version 2 LE
        assert_eq!(&tx.raw_data[..4], &2u32.to_le_bytes());
        // segwit marker + flag
        assert_eq!(tx.raw_data[4], 0x00);
        assert_eq!(tx.raw_data[5], 0x01);
    }

    #[test]
    fn test_btc_tx_empty_inputs() {
        let builder = BtcTransactionBuilder;
        let params = BtcTxParams {
            inputs: vec![],
            outputs: vec![BtcOutput {
                address: "".into(),
                value: 1000,
                script_pubkey: Some(vec![0x00]),
            }],
            testnet: false,
        };
        assert!(builder.build(params).is_err());
    }

    #[test]
    fn test_btc_tx_empty_outputs() {
        let builder = BtcTransactionBuilder;
        let params = BtcTxParams {
            inputs: vec![BtcInput {
                txid: "aa".repeat(32),
                vout: 0,
                value: 1000,
                pubkey_hash: None,
            }],
            outputs: vec![],
            testnet: false,
        };
        assert!(builder.build(params).is_err());
    }

    #[test]
    fn test_bip143_sighash_deterministic() {
        let params = dummy_params();
        let h1 = bip143_sighash(&params, 0).unwrap();
        let h2 = bip143_sighash(&params, 0).unwrap();
        assert_eq!(h1, h2);
    }

    #[test]
    fn test_bip143_sighash_index_oob() {
        let params = dummy_params();
        assert!(bip143_sighash(&params, 5).is_err());
    }

    #[test]
    fn test_different_inputs_different_hash() {
        let mut p1 = dummy_params();
        let p2 = dummy_params();
        p1.inputs[0].value = 200_000;
        let h1 = bip143_sighash(&p1, 0).unwrap();
        let h2 = bip143_sighash(&p2, 0).unwrap();
        assert_ne!(h1, h2);
    }

    #[test]
    fn test_p2wpkh_script_code() {
        let hash = [0xab; 20];
        let sc = p2wpkh_script_code(&hash);
        assert_eq!(sc.len(), 25);
        assert_eq!(sc[0], 0x76); // OP_DUP
        assert_eq!(sc[1], 0xa9); // OP_HASH160
        assert_eq!(sc[2], 0x14); // push 20
        assert_eq!(sc[23], 0x88); // OP_EQUALVERIFY
        assert_eq!(sc[24], 0xac); // OP_CHECKSIG
    }

    #[test]
    fn test_varint_encoding() {
        let mut buf = Vec::new();
        push_varint(&mut buf, 0);
        assert_eq!(buf, vec![0x00]);

        buf.clear();
        push_varint(&mut buf, 252);
        assert_eq!(buf, vec![0xfc]);

        buf.clear();
        push_varint(&mut buf, 253);
        assert_eq!(buf, vec![0xfd, 0xfd, 0x00]);

        buf.clear();
        push_varint(&mut buf, 0x1234);
        assert_eq!(buf, vec![0xfd, 0x34, 0x12]);
    }

    #[test]
    fn test_serialize_witness_tx_structure() {
        let params = dummy_params();
        let raw = serialize_witness_tx(&params).unwrap();
        // Verify basic structure: version(4) + marker(1) + flag(1) = first 6 bytes
        assert!(raw.len() > 6);
        // ends with locktime (4 zero bytes)
        assert_eq!(&raw[raw.len()-4..], &[0, 0, 0, 0]);
    }
}
