//! Solana transaction builder.
//!
//! Builds a Solana transaction message for a System Program transfer
//! instruction and computes the signing payload (the serialized message bytes).

use super::{ChainError, ChainType, Transaction, TransactionBuilder};
use serde::{Deserialize, Serialize};

/// System Program address (all zeros except the last byte is also zero — it's
/// the literal program id `11111111111111111111111111111111` in base58).
const SYSTEM_PROGRAM_ID: [u8; 32] = [0u8; 32];

/// System Program "Transfer" instruction index.
const TRANSFER_INSTRUCTION: u32 = 2;

/// Solana native SOL transfer parameters.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SolanaTxParams {
    /// Sender public key (base58).
    pub from: String,
    /// Recipient public key (base58).
    pub to: String,
    /// Amount in lamports.
    pub lamports: u64,
    /// Recent blockhash (base58).
    pub recent_blockhash: String,
    pub devnet: bool,
}

/// Builds a Solana System Program transfer instruction and serializes the transaction.
pub struct SolanaTransactionBuilder;

impl TransactionBuilder for SolanaTransactionBuilder {
    type Params = SolanaTxParams;

    fn build(&self, params: Self::Params) -> Result<Transaction, ChainError> {
        tracing::debug!(from = %params.from, to = %params.to, "building Solana transaction");

        let from_key = decode_pubkey(&params.from)?;
        let to_key = decode_pubkey(&params.to)?;
        let blockhash = decode_pubkey(&params.recent_blockhash)?;

        let message = build_transfer_message(&from_key, &to_key, params.lamports, &blockhash)?;

        // Solana signs the raw serialized message bytes.
        let sign_hash = message.clone();

        Ok(Transaction {
            chain: ChainType::Solana {
                devnet: params.devnet,
            },
            raw_data: message,
            sign_hash,
        })
    }
}

// ---------------------------------------------------------------------------
// Message construction
// ---------------------------------------------------------------------------

/// Build a Solana v0-legacy message for a single System Transfer instruction.
///
/// Message layout (legacy):
///   - header (3 bytes): num_required_signatures, num_readonly_signed, num_readonly_unsigned
///   - compact-array of account keys
///   - recent blockhash (32 bytes)
///   - compact-array of instructions
fn build_transfer_message(
    from: &[u8; 32],
    to: &[u8; 32],
    lamports: u64,
    recent_blockhash: &[u8; 32],
) -> Result<Vec<u8>, ChainError> {
    // Account keys in order:
    //  0 — from  (signer, writable)
    //  1 — to    (writable)
    //  2 — System Program (readonly, unsigned)
    let accounts: Vec<&[u8; 32]> = vec![from, to, &SYSTEM_PROGRAM_ID];

    let mut msg = Vec::with_capacity(256);

    // Header
    msg.push(1); // num_required_signatures (only `from`)
    msg.push(0); // num_readonly_signed_accounts
    msg.push(1); // num_readonly_unsigned_accounts (System Program)

    // Account addresses (compact array)
    encode_compact_u16(&mut msg, accounts.len() as u16);
    for acct in &accounts {
        msg.extend_from_slice(acct.as_slice());
    }

    // Recent blockhash
    msg.extend_from_slice(recent_blockhash);

    // Instructions (compact array of 1 instruction)
    encode_compact_u16(&mut msg, 1);
    // -- program_id index (System Program is at index 2)
    msg.push(2);
    // -- account indices for the transfer instruction: [from=0, to=1]
    encode_compact_u16(&mut msg, 2);
    msg.push(0); // from
    msg.push(1); // to
                 // -- instruction data: 4 bytes LE instruction index + 8 bytes LE lamports
    let ix_data = transfer_instruction_data(lamports);
    encode_compact_u16(&mut msg, ix_data.len() as u16);
    msg.extend_from_slice(&ix_data);

    Ok(msg)
}

/// Encode the System Program `Transfer` instruction data.
fn transfer_instruction_data(lamports: u64) -> Vec<u8> {
    let mut data = Vec::with_capacity(12);
    data.extend_from_slice(&TRANSFER_INSTRUCTION.to_le_bytes());
    data.extend_from_slice(&lamports.to_le_bytes());
    data
}

/// Decode a base58-encoded 32-byte key.
fn decode_pubkey(s: &str) -> Result<[u8; 32], ChainError> {
    let bytes = bs58::decode(s)
        .into_vec()
        .map_err(|e| ChainError::InvalidAddress(format!("bad base58: {e}")))?;
    if bytes.len() != 32 {
        return Err(ChainError::InvalidAddress(format!(
            "expected 32-byte key, got {}",
            bytes.len()
        )));
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

/// Solana compact-u16 encoding.
fn encode_compact_u16(buf: &mut Vec<u8>, val: u16) {
    let mut v = val;
    loop {
        let mut byte = (v & 0x7f) as u8;
        v >>= 7;
        if v != 0 {
            byte |= 0x80;
        }
        buf.push(byte);
        if v == 0 {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_params() -> SolanaTxParams {
        // Use well-known base58-encoded 32-byte keys
        SolanaTxParams {
            from: bs58::encode([1u8; 32]).into_string(),
            to: bs58::encode([2u8; 32]).into_string(),
            lamports: 1_000_000,
            recent_blockhash: bs58::encode([3u8; 32]).into_string(),
            devnet: true,
        }
    }

    #[test]
    fn test_decode_pubkey() {
        let key = [42u8; 32];
        let encoded = bs58::encode(key).into_string();
        let decoded = decode_pubkey(&encoded).unwrap();
        assert_eq!(decoded, key);
    }

    #[test]
    fn test_decode_pubkey_bad() {
        assert!(decode_pubkey("not_valid!!!").is_err());
    }

    #[test]
    fn test_decode_pubkey_wrong_length() {
        let short = bs58::encode([0u8; 16]).into_string();
        assert!(decode_pubkey(&short).is_err());
    }

    #[test]
    fn test_compact_u16() {
        let mut buf = Vec::new();
        encode_compact_u16(&mut buf, 0);
        assert_eq!(buf, vec![0x00]);

        buf.clear();
        encode_compact_u16(&mut buf, 1);
        assert_eq!(buf, vec![0x01]);

        buf.clear();
        encode_compact_u16(&mut buf, 127);
        assert_eq!(buf, vec![0x7f]);

        buf.clear();
        encode_compact_u16(&mut buf, 128);
        assert_eq!(buf, vec![0x80, 0x01]);

        buf.clear();
        encode_compact_u16(&mut buf, 0x3fff);
        assert_eq!(buf, vec![0xff, 0x7f]);
    }

    #[test]
    fn test_transfer_instruction_data() {
        let data = transfer_instruction_data(1_000_000);
        assert_eq!(data.len(), 12);
        // first 4 bytes = instruction index (2) LE
        assert_eq!(&data[..4], &[2, 0, 0, 0]);
        // next 8 bytes = lamports LE
        assert_eq!(&data[4..], &1_000_000u64.to_le_bytes());
    }

    #[test]
    fn test_build_solana_tx() {
        let builder = SolanaTransactionBuilder;
        let params = sample_params();
        let tx = builder.build(params).unwrap();

        // raw_data == sign_hash for Solana
        assert_eq!(tx.raw_data, tx.sign_hash);
        assert!(!tx.raw_data.is_empty());

        // Header check
        assert_eq!(tx.raw_data[0], 1); // num_required_signatures
        assert_eq!(tx.raw_data[1], 0); // num_readonly_signed
        assert_eq!(tx.raw_data[2], 1); // num_readonly_unsigned
    }

    #[test]
    fn test_solana_message_contains_accounts() {
        let builder = SolanaTransactionBuilder;
        let params = sample_params();
        let tx = builder.build(params).unwrap();

        // After header (3 bytes) + compact array length (1 byte for 3 accounts)
        // comes 3 × 32-byte keys
        let from_key = &tx.raw_data[4..36];
        assert_eq!(from_key, &[1u8; 32]);
        let to_key = &tx.raw_data[36..68];
        assert_eq!(to_key, &[2u8; 32]);
        let program = &tx.raw_data[68..100];
        assert_eq!(program, &[0u8; 32]); // System Program
    }

    #[test]
    fn test_solana_message_contains_blockhash() {
        let builder = SolanaTransactionBuilder;
        let params = sample_params();
        let tx = builder.build(params).unwrap();

        // blockhash starts at offset 4 + 3*32 = 100
        let blockhash = &tx.raw_data[100..132];
        assert_eq!(blockhash, &[3u8; 32]);
    }

    #[test]
    fn test_different_lamports_different_message() {
        let builder = SolanaTransactionBuilder;
        let mut p1 = sample_params();
        let p2 = sample_params();
        p1.lamports = 999;
        let tx1 = builder.build(p1).unwrap();
        let tx2 = builder.build(p2).unwrap();
        assert_ne!(tx1.sign_hash, tx2.sign_hash);
    }

    #[test]
    fn test_solana_chain_type() {
        let builder = SolanaTransactionBuilder;
        let params = sample_params();
        let tx = builder.build(params).unwrap();
        assert_eq!(tx.chain, ChainType::Solana { devnet: true });
    }

    #[test]
    fn test_bad_from_address() {
        let builder = SolanaTransactionBuilder;
        let mut params = sample_params();
        params.from = "!!!invalid".into();
        assert!(builder.build(params).is_err());
    }

    #[test]
    fn test_bad_blockhash() {
        let builder = SolanaTransactionBuilder;
        let mut params = sample_params();
        params.recent_blockhash = "short".into();
        assert!(builder.build(params).is_err());
    }

    #[test]
    fn test_solana_devnet_vs_mainnet() {
        let builder = SolanaTransactionBuilder;
        let mut p1 = sample_params();
        p1.devnet = false;
        let tx = builder.build(p1).unwrap();
        assert_eq!(tx.chain, ChainType::Solana { devnet: false });
    }

    #[test]
    fn test_solana_zero_lamports() {
        let builder = SolanaTransactionBuilder;
        let mut params = sample_params();
        params.lamports = 0;
        let tx = builder.build(params).unwrap();
        // Zero-value transfer should still serialize
        assert!(!tx.raw_data.is_empty());
        // Instruction data should encode 0 lamports
        let ix_data = transfer_instruction_data(0);
        assert_eq!(&ix_data[4..], &0u64.to_le_bytes());
    }

    #[test]
    fn test_bad_to_address() {
        let builder = SolanaTransactionBuilder;
        let mut params = sample_params();
        params.to = "!!!invalid".into();
        assert!(builder.build(params).is_err());
    }
}
