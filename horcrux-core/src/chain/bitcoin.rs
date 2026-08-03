//! Bitcoin transaction builder (P2WPKH / native segwit).
//!
//! Implements basic transaction serialization and BIP-143 sighash computation
//! for spending P2WPKH outputs.

use super::{ChainError, ChainType, Transaction, TransactionBuilder};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Bitcoin fee rate (M8 — audit `docs/security-audit-2026-04.md`):
/// the unit is **satoshis per virtual byte** (sat/vB).
///
/// External APIs and exchanges variously quote `sat/B` (legacy bytes),
/// `sat/vB` (post-SegWit virtual bytes), or `sat/kB` (1,000 bytes), and
/// confusing two of them in the same code path leads to either dust
/// transactions that won't relay or miner-tip-of-the-century overpays.
///
/// This newtype documents the unit at every API surface that consumes
/// a fee rate. Conversion helpers are provided for the other two units
/// so callers translate explicitly rather than inferring from naming.
///
/// Construction is `From<u64>` (sat/vB) plus the explicit
/// `from_sat_per_kvbyte` / `from_sat_per_byte` helpers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SatPerVbyte(u64);

impl SatPerVbyte {
    /// Construct directly from sat/vB.
    pub const fn new(sat_per_vbyte: u64) -> Self {
        Self(sat_per_vbyte)
    }

    /// Construct from sat/kvB (sat per 1,000 vBytes), rounding up so
    /// fee-rate-too-low relay rejection is avoided.
    pub fn from_sat_per_kvbyte(sat_per_kvbyte: u64) -> Self {
        Self(sat_per_kvbyte.div_ceil(1000))
    }

    /// Construct from sat/B (sat per legacy serialized byte). Pre-SegWit
    /// callers used this; in current consensus it's identical to sat/vB
    /// for non-witness-bearing inputs but understates fee for SegWit.
    /// Treated as sat/vB here to keep relay above the floor — callers
    /// that genuinely mean "sat per legacy byte and willing to under-pay"
    /// should compute and pass the explicit sat/vB themselves.
    pub fn from_sat_per_byte(sat_per_byte: u64) -> Self {
        Self(sat_per_byte)
    }

    /// Raw value in sat/vB.
    pub const fn as_sat_per_vbyte(self) -> u64 {
        self.0
    }

    /// Convert to sat/kvB for callers that need the unit elsewhere.
    pub const fn as_sat_per_kvbyte(self) -> u64 {
        self.0.saturating_mul(1000)
    }
}

impl std::fmt::Display for SatPerVbyte {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} sat/vB", self.0)
    }
}

/// Bitcoin P2WPKH transaction parameters (inputs + outputs).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BtcTxParams {
    pub inputs: Vec<BtcInput>,
    pub outputs: Vec<BtcOutput>,
    pub testnet: bool,
}

/// A UTXO input reference (txid:vout) with value for sighash computation.
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
    /// Full raw bytes of the previous transaction (non-witness serialized).
    /// When supplied, the builder verifies that `dsha256(prev_tx_raw)`
    /// (displayed as big-endian hex) equals `txid`, and that output
    /// index `vout` has exactly the claimed `value`. This closes the
    /// BIP-143 SegWit "trusted-amount" footgun where a malicious PSBT
    /// producer can lie about `value` and steal the difference as
    /// miner fee (audit finding H9).
    ///
    /// Optional for back-compat: pre-dev.137 callers that don't
    /// populate this field fall into the legacy trust-the-amount path
    /// and log a warning so the code path is visible in telemetry.
    /// New callers MUST supply this.
    #[serde(default)]
    pub prev_tx_raw: Option<Vec<u8>>,
}

/// A Bitcoin transaction output (destination address + satoshi amount).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BtcOutput {
    pub address: String,
    pub value: u64,
    /// Raw scriptPubKey. When provided, `address` is informational only.
    #[serde(default)]
    pub script_pubkey: Option<Vec<u8>>,
}

/// Builds a P2WPKH SegWit Bitcoin transaction.
pub struct BtcTransactionBuilder;

/// SIGHASH_ALL
const SIGHASH_ALL: u32 = 1;
/// Transaction version 2 (supports BIP-68 relative lock-time).
const TX_VERSION: u32 = 2;
/// nSequence written on every input.
///
/// BIP-125 opt-in signalling requires a sequence **strictly less than**
/// `0xffffffff - 1`. The obvious-looking `0xfffffffe` fails that test by
/// one: it waives nLockTime finality and nothing else, so a transaction
/// stuck at a low fee cannot be replaced. `0xfffffffd` is the largest
/// value that both opts in and leaves BIP-68 relative locktime disabled
/// (bit 31 set).
///
/// This value is committed to by the signature in three places — the
/// hashSequence digest, the sighash preimage's per-input field, and the
/// broadcast serialisation. They must not drift apart; see
/// `test_sighash_commits_to_the_broadcast_sequence`.
const SEQUENCE_RBF: u32 = 0xFFFF_FFFD;

impl TransactionBuilder for BtcTransactionBuilder {
    type Params = BtcTxParams;

    fn build(&self, params: Self::Params) -> Result<Transaction, ChainError> {
        tracing::debug!(
            inputs = params.inputs.len(),
            outputs = params.outputs.len(),
            "building BTC transaction"
        );

        if params.inputs.is_empty() {
            return Err(ChainError::Other(
                "transaction must have at least one input".into(),
            ));
        }
        if params.outputs.is_empty() {
            return Err(ChainError::Other(
                "transaction must have at least one output".into(),
            ));
        }

        // H9: for every input that supplies a previous raw tx, confirm
        // that the claimed txid and value are genuinely derived from
        // it. Inputs without prev_tx_raw fall through to the legacy
        // path — warn loudly so the exposure is telemetered and
        // upstream callers get upgraded.
        for (i, input) in params.inputs.iter().enumerate() {
            match &input.prev_tx_raw {
                Some(raw) => verify_utxo_provenance(input, raw, i)?,
                None => {
                    tracing::warn!(
                        input_index = i,
                        txid = %input.txid,
                        "BTC input without prev_tx_raw — trusting self-reported amount \
                         (audit finding H9). Upgrade caller to supply prev_tx_raw."
                    );
                }
            }
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

/// Verify a PSBT input's claimed (txid, vout → value) matches the
/// supplied raw previous transaction. Returns Ok(()) on match and a
/// typed [`ChainError`] on any discrepancy.
///
/// Used internally by `BtcTransactionBuilder::build` but also exposed
/// so higher layers can eagerly validate PSBTs at import time — e.g.
/// refuse to even display a signing sheet for a PSBT whose amounts
/// don't prove out (audit finding H9).
pub fn verify_utxo_provenance(
    input: &BtcInput,
    prev_tx_raw: &[u8],
    input_index: usize,
) -> Result<(), ChainError> {
    // Bitcoin txid = dsha256(serialized_tx_without_witness), displayed
    // in big-endian hex. Since the raw bytes are already the
    // non-witness serialization, we just double-SHA256 and reverse.
    let inner = Sha256::digest(Sha256::digest(prev_tx_raw));
    let mut computed = inner.to_vec();
    computed.reverse();
    let computed_hex = hex::encode(&computed);

    let claimed_hex = input.txid.trim_start_matches("0x").to_ascii_lowercase();
    if computed_hex != claimed_hex {
        return Err(ChainError::Other(format!(
            "BTC input {input_index}: prev_tx_raw txid mismatch (computed {computed_hex}, \
             claimed {claimed_hex}) — possible amount-lying PSBT (H9)"
        )));
    }

    // Parse just enough of the previous tx to extract output `vout`'s
    // value. Bitcoin tx format (non-witness):
    //   [4-byte version] [vin_count varint] [vin_count * (36-byte outpoint
    //   + script varint + script + 4-byte seq)] [vout_count varint] [
    //   vout_count * (8-byte value + script varint + script)] [4-byte locktime]
    let value = extract_output_value(prev_tx_raw, input.vout).map_err(|e| {
        ChainError::Other(format!(
            "BTC input {input_index}: cannot parse prev_tx_raw to extract vout {}: {e}",
            input.vout
        ))
    })?;
    if value != input.value {
        return Err(ChainError::Other(format!(
            "BTC input {input_index}: value mismatch (prev_tx says {value}, \
             PSBT claims {}) — possible fee-stuffing attack (H9)",
            input.value
        )));
    }
    Ok(())
}

/// Parse `prev_tx_raw` and return the `value` (in satoshis) of output
/// `vout`. Returns Err on any structural issue.
fn extract_output_value(raw: &[u8], vout: u32) -> Result<u64, String> {
    let mut p = 0usize;
    // version (4)
    if raw.len() < p + 4 {
        return Err("truncated at version".into());
    }
    p += 4;
    // Optional witness marker+flag (0x00 0x01) — but since we hash the
    // non-witness serialization for txid matching, prev_tx_raw should
    // NOT include a witness. Reject if present, to keep the txid check
    // self-consistent.
    if raw.len() >= p + 2 && raw[p] == 0x00 && raw[p + 1] == 0x01 {
        return Err("prev_tx_raw contains witness marker; expect non-witness serialization".into());
    }
    // vin_count (varint)
    let (vin_count, sz) = read_varint(&raw[p..])?;
    p += sz;
    for _ in 0..vin_count {
        // outpoint (36)
        if raw.len() < p + 36 {
            return Err("truncated at outpoint".into());
        }
        p += 36;
        // script
        let (script_len, sz) = read_varint(&raw[p..])?;
        p += sz;
        let script_len = script_len as usize;
        if raw.len() < p + script_len + 4 {
            return Err("truncated at scriptSig".into());
        }
        p += script_len + 4; // script + sequence
    }
    // vout_count (varint)
    let (vout_count, sz) = read_varint(&raw[p..])?;
    p += sz;
    if (vout as u64) >= vout_count {
        return Err(format!("vout {vout} out of range ({vout_count} outputs)"));
    }
    for i in 0..vout_count {
        if raw.len() < p + 8 {
            return Err("truncated at output value".into());
        }
        let mut vbuf = [0u8; 8];
        vbuf.copy_from_slice(&raw[p..p + 8]);
        let value = u64::from_le_bytes(vbuf);
        p += 8;
        let (script_len, sz) = read_varint(&raw[p..])?;
        p += sz;
        let script_len = script_len as usize;
        if raw.len() < p + script_len {
            return Err("truncated at output script".into());
        }
        p += script_len;
        if i == vout as u64 {
            return Ok(value);
        }
    }
    unreachable!("vout bound-checked above")
}

fn read_varint(buf: &[u8]) -> Result<(u64, usize), String> {
    if buf.is_empty() {
        return Err("empty varint".into());
    }
    match buf[0] {
        n @ 0x00..=0xfc => Ok((n as u64, 1)),
        0xfd => {
            if buf.len() < 3 {
                return Err("truncated u16 varint".into());
            }
            Ok((u16::from_le_bytes([buf[1], buf[2]]) as u64, 3))
        }
        0xfe => {
            if buf.len() < 5 {
                return Err("truncated u32 varint".into());
            }
            let v = u32::from_le_bytes([buf[1], buf[2], buf[3], buf[4]]);
            Ok((v as u64, 5))
        }
        0xff => {
            if buf.len() < 9 {
                return Err("truncated u64 varint".into());
            }
            let mut a = [0u8; 8];
            a.copy_from_slice(&buf[1..9]);
            Ok((u64::from_le_bytes(a), 9))
        }
    }
}

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
    let pubkey_hash = input.pubkey_hash.as_deref().unwrap_or(&[0u8; 20]);
    let script_code = p2wpkh_script_code(pubkey_hash);

    let mut preimage = Vec::with_capacity(156);
    preimage.extend_from_slice(&TX_VERSION.to_le_bytes());
    preimage.extend_from_slice(&hash_prevouts);
    preimage.extend_from_slice(&hash_sequence);
    preimage.extend_from_slice(&outpoint);
    push_var_bytes(&mut preimage, &script_code);
    preimage.extend_from_slice(&input.value.to_le_bytes());
    preimage.extend_from_slice(&SEQUENCE_RBF.to_le_bytes());
    preimage.extend_from_slice(&hash_outputs);
    preimage.extend_from_slice(&0u32.to_le_bytes()); // locktime
    preimage.extend_from_slice(&SIGHASH_ALL.to_le_bytes());

    Ok(double_sha256(&preimage))
}

/// HASH160 = RIPEMD160(SHA256(data)).
pub fn hash160(data: &[u8]) -> [u8; 20] {
    // `ripemd` 0.2 moved to `digest` 0.11 while `sha2` is still on `digest`
    // 0.10, so the module-level `sha2::Digest` import does not cover
    // `Ripemd160`. Import ripemd's own trait anonymously — each type
    // implements exactly one of the two, so method resolution stays
    // unambiguous.
    use ripemd::{Digest as _, Ripemd160};
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
    let mut bytes =
        hex::decode(txid).map_err(|e| ChainError::InvalidAddress(format!("bad txid hex: {e}")))?;
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
        data.extend_from_slice(&SEQUENCE_RBF.to_le_bytes());
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
            .ok_or_else(|| ChainError::EncodingError("output must have script_pubkey".into()))?;
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
        buf.extend_from_slice(&SEQUENCE_RBF.to_le_bytes());
    }
    // output count
    push_varint(&mut buf, params.outputs.len() as u64);
    for out in &params.outputs {
        buf.extend_from_slice(&out.value.to_le_bytes());
        let spk = out
            .script_pubkey
            .as_deref()
            .ok_or_else(|| ChainError::EncodingError("output must have script_pubkey".into()))?;
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

    // ---- M8 SatPerVbyte newtype tests ----

    #[test]
    fn sat_per_vbyte_direct_construction() {
        let r = SatPerVbyte::new(15);
        assert_eq!(r.as_sat_per_vbyte(), 15);
        assert_eq!(r.as_sat_per_kvbyte(), 15_000);
    }

    #[test]
    fn sat_per_vbyte_from_kvbyte_rounds_up() {
        // 1500 sat/kvB → 2 sat/vB (rounded up so we don't underpay)
        assert_eq!(SatPerVbyte::from_sat_per_kvbyte(1500).as_sat_per_vbyte(), 2);
        // 1000 sat/kvB → exactly 1 sat/vB
        assert_eq!(SatPerVbyte::from_sat_per_kvbyte(1000).as_sat_per_vbyte(), 1);
        // 1 sat/kvB → 1 sat/vB (rounded up from 0.001)
        assert_eq!(SatPerVbyte::from_sat_per_kvbyte(1).as_sat_per_vbyte(), 1);
    }

    #[test]
    fn sat_per_vbyte_display_includes_unit() {
        assert_eq!(SatPerVbyte::new(42).to_string(), "42 sat/vB");
    }

    #[test]
    fn sat_per_vbyte_kvbyte_saturates_on_overflow() {
        let r = SatPerVbyte::new(u64::MAX);
        // saturating_mul(1000) → u64::MAX, not panic
        assert_eq!(r.as_sat_per_kvbyte(), u64::MAX);
    }

    fn dummy_params() -> BtcTxParams {
        BtcTxParams {
            inputs: vec![BtcInput {
                txid: "a".repeat(64), // 32 bytes of 0xaa
                vout: 0,
                value: 100_000,
                pubkey_hash: Some(vec![0xab; 20]),
                prev_tx_raw: None,
            }],
            outputs: vec![BtcOutput {
                address: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4".into(),
                value: 90_000,
                script_pubkey: Some(vec![
                    0x00, 0x14, // witness v0, push 20
                    0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4, 0x54, 0x94, 0x1c, 0x45, 0xd1,
                    0xb3, 0xa3, 0x23, 0xf1, 0x43, 0x3b, 0xd6,
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

    /// Known-answer test for HASH160 = RIPEMD160(SHA256(x)).
    ///
    /// Pins the exact byte output rather than just the length, so that a
    /// `ripemd` / `sha2` version bump cannot silently change Bitcoin address
    /// derivation. The vector is the BIP-173 P2WPKH example: hashing the
    /// compressed secp256k1 generator point must yield the witness program of
    /// `bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4`, which is already asserted
    /// elsewhere in this module.
    #[test]
    fn test_hash160_known_answer() {
        let pubkey =
            hex::decode("0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798")
                .unwrap();
        assert_eq!(
            hex::encode(hash160(&pubkey)),
            "751e76e8199196d454941c45d1b3a323f1433bd6"
        );

        // Empty input — RIPEMD160(SHA256("")).
        assert_eq!(
            hex::encode(hash160(b"")),
            "b472a266d0bd89c13706a4132ccfb16f7c3b9fcb"
        );
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
                prev_tx_raw: None,
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
        assert_eq!(&raw[raw.len() - 4..], &[0, 0, 0, 0]);
    }

    // --- BIP125 replaceability ---

    /// Read each input's nSequence out of a serialised segwit transaction.
    ///
    /// Deliberately parses the broadcast bytes rather than reading the
    /// constant back, so these tests observe what a node would observe.
    fn sequences_in_serialized_tx(raw: &[u8], input_count: usize) -> Vec<u32> {
        let mut p = 4; // version
        assert_eq!(&raw[p..p + 2], &[0x00, 0x01], "expected segwit marker+flag");
        p += 2;
        let (n, sz) = read_varint(&raw[p..]).expect("input count");
        assert_eq!(n as usize, input_count);
        p += sz;
        let mut out = Vec::with_capacity(input_count);
        for _ in 0..input_count {
            p += 36; // outpoint
            let (script_len, sz) = read_varint(&raw[p..]).expect("scriptSig len");
            p += sz + script_len as usize;
            out.push(u32::from_le_bytes([
                raw[p],
                raw[p + 1],
                raw[p + 2],
                raw[p + 3],
            ]));
            p += 4;
        }
        out
    }

    /// BIP125 opt-in requires an nSequence *strictly less than*
    /// `0xffffffff - 1`. `0xfffffffe` is not less than `0xfffffffe`; it
    /// only waives nLockTime finality. Without this, a transaction stuck
    /// at a low fee cannot be replaced at all — full-RBF-only nodes
    /// reject the replacement and default-policy nodes keep the original.
    #[test]
    fn test_serialized_tx_signals_bip125_optin() {
        let params = dummy_params();
        let raw = serialize_witness_tx(&params).unwrap();
        let seqs = sequences_in_serialized_tx(&raw, params.inputs.len());
        assert!(
            seqs.iter().any(|&s| s < 0xffff_ffff - 1),
            "no input opts into BIP125; sequences were {seqs:02x?}"
        );
    }

    /// nSequence is committed to by the signature in three separate
    /// places — the hashSequence digest, the preimage's own per-input
    /// field, and the broadcast serialisation. If any one drifts, the
    /// signature covers bytes that are not the bytes presented and the
    /// transaction is unspendable: the coins are stuck, not merely
    /// delayed.
    ///
    /// Rebuilds the BIP-143 preimage from the sequence read back out of
    /// the *serialised transaction*, so the assertion is anchored to
    /// what a node would see rather than to the constant itself.
    #[test]
    fn test_sighash_commits_to_the_broadcast_sequence() {
        let mut params = dummy_params();
        // Two inputs so hashSequence depends on the count, not just the
        // value — a one-input case would pass even if the loop were wrong.
        let mut second = params.inputs[0].clone();
        second.txid = "b".repeat(64);
        second.vout = 1;
        params.inputs.push(second);

        let raw = serialize_witness_tx(&params).unwrap();
        let seqs = sequences_in_serialized_tx(&raw, params.inputs.len());

        let input = &params.inputs[0];
        let mut preimage = Vec::new();
        preimage.extend_from_slice(&TX_VERSION.to_le_bytes());
        preimage.extend_from_slice(&double_sha256(&serialize_prevouts(&params.inputs)));
        let seq_bytes: Vec<u8> = seqs.iter().flat_map(|s| s.to_le_bytes()).collect();
        preimage.extend_from_slice(&double_sha256(&seq_bytes));
        preimage.extend_from_slice(&serialize_outpoint(input).unwrap());
        push_var_bytes(
            &mut preimage,
            &p2wpkh_script_code(input.pubkey_hash.as_deref().unwrap()),
        );
        preimage.extend_from_slice(&input.value.to_le_bytes());
        preimage.extend_from_slice(&seqs[0].to_le_bytes());
        preimage.extend_from_slice(&double_sha256(&serialize_outputs(&params.outputs).unwrap()));
        preimage.extend_from_slice(&0u32.to_le_bytes()); // locktime
        preimage.extend_from_slice(&SIGHASH_ALL.to_le_bytes());

        assert_eq!(
            double_sha256(&preimage),
            bip143_sighash(&params, 0).unwrap(),
            "the signed digest does not commit to the sequence in the broadcast bytes"
        );
    }

    // --- H9: UTXO provenance ---
    /// Build a minimal valid non-witness prev tx with one input and
    /// one output of `output_value` satoshis to scriptPubKey of 1 byte.
    fn minimal_prev_tx(output_value: u64) -> Vec<u8> {
        let mut raw = Vec::new();
        raw.extend_from_slice(&2u32.to_le_bytes()); // version
        raw.push(1); // vin_count
        raw.extend_from_slice(&[0u8; 32]); // prev txid
        raw.extend_from_slice(&0u32.to_le_bytes()); // prev vout
        raw.push(0); // empty scriptSig
        raw.extend_from_slice(&0xffffffffu32.to_le_bytes()); // sequence
        raw.push(1); // vout_count
        raw.extend_from_slice(&output_value.to_le_bytes());
        raw.push(1); // script len
        raw.push(0x51); // OP_1
        raw.extend_from_slice(&0u32.to_le_bytes()); // locktime
        raw
    }

    fn txid_of(raw: &[u8]) -> String {
        let inner = Sha256::digest(Sha256::digest(raw));
        let mut v = inner.to_vec();
        v.reverse();
        hex::encode(v)
    }

    #[test]
    fn test_verify_utxo_provenance_happy_path() {
        let raw = minimal_prev_tx(100_000);
        let input = BtcInput {
            txid: txid_of(&raw),
            vout: 0,
            value: 100_000,
            pubkey_hash: None,
            prev_tx_raw: Some(raw.clone()),
        };
        verify_utxo_provenance(&input, &raw, 0).expect("matching prev tx must verify");
    }

    #[test]
    fn test_verify_utxo_provenance_txid_mismatch() {
        let raw = minimal_prev_tx(100_000);
        let input = BtcInput {
            txid: "ff".repeat(32),
            vout: 0,
            value: 100_000,
            pubkey_hash: None,
            prev_tx_raw: Some(raw.clone()),
        };
        let err = verify_utxo_provenance(&input, &raw, 0).unwrap_err();
        assert!(format!("{err}").contains("txid mismatch"));
    }

    #[test]
    fn test_verify_utxo_provenance_value_mismatch() {
        let raw = minimal_prev_tx(100_000);
        let input = BtcInput {
            txid: txid_of(&raw),
            vout: 0,
            value: 200_000, // PSBT lies about the amount
            pubkey_hash: None,
            prev_tx_raw: Some(raw.clone()),
        };
        let err = verify_utxo_provenance(&input, &raw, 0).unwrap_err();
        assert!(format!("{err}").contains("value mismatch"));
    }

    #[test]
    fn test_build_rejects_lying_prev_tx() {
        // Attacker claims to spend 100k but prev_tx says 1k.
        let raw = minimal_prev_tx(1_000);
        let builder = BtcTransactionBuilder;
        let params = BtcTxParams {
            inputs: vec![BtcInput {
                txid: txid_of(&raw),
                vout: 0,
                value: 100_000,
                pubkey_hash: Some(vec![0xab; 20]),
                prev_tx_raw: Some(raw),
            }],
            outputs: vec![BtcOutput {
                address: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4".into(),
                value: 90_000,
                script_pubkey: Some(vec![
                    0x00, 0x14, 0u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                ]),
            }],
            testnet: false,
        };
        let err = builder.build(params).unwrap_err();
        assert!(format!("{err}").contains("value mismatch"));
    }

    #[test]
    fn test_verify_utxo_provenance_rejects_witness_serialized_prev() {
        // Prev-tx raw with marker+flag bytes should be rejected to
        // keep the txid comparison self-consistent.
        let mut raw = minimal_prev_tx(100_000);
        raw.insert(4, 0x01); // flag
        raw.insert(4, 0x00); // marker
        let input = BtcInput {
            txid: txid_of(&raw),
            vout: 0,
            value: 100_000,
            pubkey_hash: None,
            prev_tx_raw: Some(raw.clone()),
        };
        // txid will mismatch (since the claimed txid was derived from
        // the witness-prefixed bytes but internal parser rejects
        // witness format — either way this input is rejected).
        assert!(verify_utxo_provenance(&input, &raw, 0).is_err());
    }
}

/// Property-based robustness tests for the Bitcoin UTXO-amount
/// verifier (audit finding H9).
///
/// `verify_utxo_provenance` is called with `prev_tx_raw` bytes sourced
/// from an external block explorer API — an attacker who can MITM or
/// phish the RPC endpoint controls these bytes directly. Any panic
/// inside the parser (slice OOB, arithmetic overflow, alloc blowup)
/// would crash the iOS host during PSBT import and hand the attacker
/// a cheap DoS primitive. The only invariant enforced here is
/// "never panic"; structurally invalid inputs must surface as
/// `Err(ChainError)`.
///
/// Round 19 hardening. Companion to the core-side MPC-parser
/// coverage.
#[cfg(test)]
mod prop_tests {
    use super::{verify_utxo_provenance, BtcInput};
    use proptest::prelude::*;

    proptest! {
        #![proptest_config(ProptestConfig { cases: 512, ..ProptestConfig::default() })]

        /// Arbitrary bytes through `verify_utxo_provenance` must not
        /// panic. Most inputs will fail txid-match and return early;
        /// a minority will have a coincidentally matching computed
        /// txid (within the 2^-256 collision bound on random bytes)
        /// and reach `extract_output_value`, where the varint /
        /// output-count / value / script-len parsers all need to be
        /// panic-free too. To force coverage of the second path, we
        /// also test the branch where the caller pre-computes the
        /// txid — that's what `prop_matching_txid_never_panics`
        /// exercises below.
        #[test]
        fn prop_arbitrary_raw_never_panics(
            raw in prop::collection::vec(any::<u8>(), 0..4096),
            vout in any::<u32>(),
            value in any::<u64>(),
            claimed_txid in "[0-9a-f]{64}",
        ) {
            let input = BtcInput {
                txid: claimed_txid,
                vout,
                value,
                pubkey_hash: None,
                prev_tx_raw: None,
            };
            let _ = verify_utxo_provenance(&input, &raw, 0);
        }

        /// Force the `extract_output_value` path by computing the
        /// correct txid for the fuzzed bytes, so the varint/output
        /// parsing code is actually reached rather than short-
        /// circuited on txid mismatch. This is also the realistic
        /// attacker path: they control both the bytes *and* the
        /// PSBT's claimed txid string, and the relay/explorer is
        /// untrusted.
        #[test]
        fn prop_matching_txid_never_panics(
            raw in prop::collection::vec(any::<u8>(), 0..4096),
            vout in any::<u32>(),
            value in any::<u64>(),
        ) {
            use sha2::{Digest, Sha256};
            let inner = Sha256::digest(Sha256::digest(&raw));
            let mut txid_bytes = inner.to_vec();
            txid_bytes.reverse();
            let txid = hex::encode(&txid_bytes);
            let input = BtcInput {
                txid,
                vout,
                value,
                pubkey_hash: None,
                prev_tx_raw: None,
            };
            let _ = verify_utxo_provenance(&input, &raw, 0);
        }
    }
}
