//! UniFFI scaffolding — bridges UDL definitions to actual Rust implementations.
//!
//! UniFFI requires flat types at the FFI boundary. This module adapts the
//! internal Rust types (which may use generics, traits, etc.) into the
//! simple structs/enums declared in `horcrux.udl`.

use std::sync::Mutex;

use crate::chain;
use crate::chain::TransactionBuilder;
use crate::mpc::session::SessionManager;
use crate::mpc::types::{KeygenResult, MpcMessage, SigningResult};
use crate::mpc::{CurveType, HorcruxConfig, MpcError};
use crate::shard::crypto::{self as shard_crypto, EncryptedShard};
use crate::shard::{ShardInfo, ShardManager};
use crate::transport::e2e::{E2EError, NoiseChannel, NoiseKeypair, SealedEnvelope, SessionToken};

// ============================================================================
// Helpers
// ============================================================================

/// Safely lock a mutex, returning an error instead of panicking on poison.
macro_rules! lock_or_err {
    ($mutex:expr, $err_type:ident, $variant:ident) => {
        $mutex.lock().map_err(|_| $err_type::$variant {
            msg: "internal mutex poisoned".into(),
        })
    };
}

// ============================================================================
// Error adapters — UniFFI needs simple string-carrying enums
// ============================================================================

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum HorcruxError {
    #[error("Invalid config: {msg}")]
    InvalidConfig { msg: String },
    #[error("Keygen failed: {msg}")]
    KeygenFailed { msg: String },
    #[error("Signing failed: {msg}")]
    SigningFailed { msg: String },
    #[error("Encryption failed: {msg}")]
    EncryptionFailed { msg: String },
    #[error("Decryption failed: {msg}")]
    DecryptionFailed { msg: String },
    #[error("Storage error: {msg}")]
    StorageError { msg: String },
    #[error("Protocol error: {msg}")]
    ProtocolError { msg: String },
    #[error("Session error: {msg}")]
    SessionError { msg: String },
    #[error("Insufficient parties: need {needed}, got {got}")]
    InsufficientParties { needed: u16, got: u16 },
}

impl From<MpcError> for HorcruxError {
    fn from(e: MpcError) -> Self {
        match e {
            MpcError::InvalidConfig(msg) => HorcruxError::InvalidConfig {
                msg: sanitize_ffi_msg("InvalidConfig", &msg),
            },
            MpcError::KeygenFailed(msg) => HorcruxError::KeygenFailed {
                msg: sanitize_ffi_msg("KeygenFailed", &msg),
            },
            MpcError::SigningFailed(msg) => HorcruxError::SigningFailed {
                msg: sanitize_ffi_msg("SigningFailed", &msg),
            },
            MpcError::SessionError(msg) => HorcruxError::SessionError {
                msg: sanitize_ffi_msg("SessionError", &msg),
            },
            MpcError::ProtocolError(msg) => HorcruxError::ProtocolError {
                msg: sanitize_ffi_msg("ProtocolError", &msg),
            },
            MpcError::InsufficientParties { needed, got } => {
                HorcruxError::InsufficientParties { needed, got }
            }
        }
    }
}

/// M5 (audit `docs/security-audit-2026-04.md`): scrub error messages
/// before they cross the FFI boundary into Swift / Kotlin UI.
///
/// MPC and chain layers occasionally embed transient internal state
/// (cipher-suite strings, library version stubs, raw byte counts) in
/// error messages. None of those are secret per se, but they have no
/// value to the end-user and they widen the attack surface for
/// fingerprinting + targeted exploit selection. We:
///
/// 1. Emit the full original message via `tracing::error!` so
///    operator-side telemetry retains the diagnostic detail.
/// 2. Truncate to 256 chars and strip newlines / control bytes so a
///    multi-line panic-style trace can't smuggle structured data
///    into a single-line UI toast.
/// 3. Reject byte sequences that look hex-encoded (>=64 contiguous
///    hex chars) — likely a leaked key, hash, or signature material.
pub(crate) fn sanitize_ffi_msg(category: &'static str, raw: &str) -> String {
    tracing::error!(category, msg = raw, "ffi error");

    let cleaned: String = raw
        .chars()
        .map(|c| {
            if c == '\n' || c == '\r' || c == '\t' {
                ' '
            } else if (c as u32) < 0x20 {
                '?'
            } else {
                c
            }
        })
        .collect();

    // Detect long contiguous hex runs (likely accidental key / digest leak)
    let mut hex_run = 0usize;
    let mut had_long_hex = false;
    for c in cleaned.chars() {
        if c.is_ascii_hexdigit() {
            hex_run += 1;
            if hex_run >= 64 {
                had_long_hex = true;
                break;
            }
        } else {
            hex_run = 0;
        }
    }
    if had_long_hex {
        return format!("{category}: <redacted: long hex run>");
    }

    if cleaned.chars().count() > 256 {
        let truncated: String = cleaned.chars().take(253).collect();
        format!("{truncated}...")
    } else {
        cleaned
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ChainError {
    #[error("Invalid address: {msg}")]
    InvalidAddress { msg: String },
    #[error("Encoding error: {msg}")]
    EncodingError { msg: String },
    #[error("Insufficient balance")]
    InsufficientBalance,
    #[error("Solana blockhash expired: age {age_ms}ms > max {max_ms}ms")]
    BlockhashExpired { age_ms: u64, max_ms: u64 },
    #[error("Arithmetic overflow: {msg}")]
    ArithmeticOverflow { msg: String },
    #[error("{msg}")]
    Other { msg: String },
}

impl From<chain::ChainError> for ChainError {
    fn from(e: chain::ChainError) -> Self {
        match e {
            chain::ChainError::InvalidAddress(msg) => ChainError::InvalidAddress {
                msg: sanitize_ffi_msg("InvalidAddress", &msg),
            },
            chain::ChainError::EncodingError(msg) => ChainError::EncodingError {
                msg: sanitize_ffi_msg("EncodingError", &msg),
            },
            chain::ChainError::InsufficientBalance => ChainError::InsufficientBalance,
            chain::ChainError::BlockhashExpired { age_ms, max_ms } => {
                ChainError::BlockhashExpired { age_ms, max_ms }
            }
            chain::ChainError::ArithmeticOverflow(msg) => ChainError::ArithmeticOverflow {
                msg: sanitize_ffi_msg("ArithmeticOverflow", msg),
            },
            chain::ChainError::Other(msg) => ChainError::Other {
                msg: sanitize_ffi_msg("Other", &msg),
            },
        }
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiE2EError {
    #[error("Handshake error: {msg}")]
    Handshake { msg: String },
    #[error("Handshake incomplete")]
    HandshakeIncomplete,
    #[error("Handshake already complete")]
    HandshakeComplete,
    #[error("Encryption error: {msg}")]
    Encryption { msg: String },
    #[error("Decryption error: {msg}")]
    Decryption { msg: String },
}

impl From<E2EError> for FfiE2EError {
    fn from(e: E2EError) -> Self {
        match e {
            E2EError::Handshake(msg) => FfiE2EError::Handshake { msg },
            E2EError::HandshakeIncomplete => FfiE2EError::HandshakeIncomplete,
            E2EError::HandshakeComplete => FfiE2EError::HandshakeComplete,
            E2EError::Encryption(msg) => FfiE2EError::Encryption { msg },
            E2EError::Decryption(msg) => FfiE2EError::Decryption { msg },
        }
    }
}

// ============================================================================
// FFI data types — flat structs for the FFI boundary
// ============================================================================

/// MPC ceremony configuration passed from the host application.
#[derive(uniffi::Record)]
pub struct FfiHorcruxConfig {
    pub threshold: u16,
    pub total_parties: u16,
    pub party_index: u16,
    pub curve: FfiCurveType,
}

/// Elliptic curve type selector for the FFI boundary.
#[derive(uniffi::Enum)]
pub enum FfiCurveType {
    Secp256k1,
    Ed25519,
}

impl From<FfiCurveType> for CurveType {
    fn from(c: FfiCurveType) -> Self {
        match c {
            FfiCurveType::Secp256k1 => CurveType::Secp256k1,
            FfiCurveType::Ed25519 => CurveType::Ed25519,
        }
    }
}

impl From<CurveType> for FfiCurveType {
    fn from(c: CurveType) -> Self {
        match c {
            CurveType::Secp256k1 => FfiCurveType::Secp256k1,
            CurveType::Ed25519 => FfiCurveType::Ed25519,
        }
    }
}

/// An MPC protocol message serialized for the FFI boundary.
#[derive(uniffi::Record)]
pub struct FfiMpcMessage {
    pub from_party: u16,
    pub to_party: u16,
    pub round: u32,
    pub session_id: String,
    pub payload: Vec<u8>,
}

impl From<MpcMessage> for FfiMpcMessage {
    fn from(mut m: MpcMessage) -> Self {
        // ZeroizeOnDrop blocks partial moves; std::mem::take leaves
        // owned defaults in `m` so its Drop runs over zeroed buffers.
        FfiMpcMessage {
            from_party: m.from,
            to_party: m.to,
            round: m.round,
            session_id: std::mem::take(&mut m.session_id),
            payload: std::mem::take(&mut m.payload),
        }
    }
}

impl From<FfiMpcMessage> for MpcMessage {
    fn from(m: FfiMpcMessage) -> Self {
        MpcMessage {
            from: m.from_party,
            to: m.to_party,
            round: m.round,
            session_id: m.session_id,
            payload: m.payload,
        }
    }
}

/// Result of a distributed key generation ceremony.
#[derive(uniffi::Record)]
pub struct FfiKeygenResult {
    pub public_key: Vec<u8>,
    pub shard_data: Vec<u8>,
    pub party_index: u16,
    pub threshold: u16,
    pub total_parties: u16,
}

impl From<KeygenResult> for FfiKeygenResult {
    fn from(mut r: KeygenResult) -> Self {
        // ZeroizeOnDrop blocks partial moves; std::mem::take hands the
        // owned buffers to the FFI struct and leaves zeroed defaults
        // for the dropping `r`.
        FfiKeygenResult {
            public_key: std::mem::take(&mut r.public_key),
            shard_data: std::mem::take(&mut r.shard_data),
            party_index: r.party_index,
            threshold: r.threshold,
            total_parties: r.total_parties,
        }
    }
}

/// Result of a threshold signing ceremony (ECDSA / EdDSA).
#[derive(uniffi::Record)]
pub struct FfiSigningResult {
    pub signature: Vec<u8>,
    pub r: Vec<u8>,
    pub s: Vec<u8>,
    pub recovery_id: Option<u8>,
}

impl From<SigningResult> for FfiSigningResult {
    fn from(r: SigningResult) -> Self {
        FfiSigningResult {
            signature: r.signature,
            r: r.r,
            s: r.s,
            recovery_id: r.recovery_id,
        }
    }
}

/// AES-256-GCM encrypted shard with nonce and PBKDF2 salt.
#[derive(uniffi::Record)]
pub struct FfiEncryptedShard {
    pub nonce: Vec<u8>,
    pub ciphertext: Vec<u8>,
    pub salt: Vec<u8>,
}

impl From<EncryptedShard> for FfiEncryptedShard {
    fn from(e: EncryptedShard) -> Self {
        FfiEncryptedShard {
            nonce: e.nonce,
            ciphertext: e.ciphertext,
            salt: e.salt,
        }
    }
}

impl From<FfiEncryptedShard> for EncryptedShard {
    fn from(e: FfiEncryptedShard) -> Self {
        EncryptedShard {
            nonce: e.nonce,
            ciphertext: e.ciphertext,
            salt: e.salt,
        }
    }
}

/// Metadata about a stored key shard (no secret material).
#[derive(uniffi::Record)]
pub struct FfiShardInfo {
    pub shard_id: String,
    pub public_key: Vec<u8>,
    pub party_index: u16,
    pub threshold: u16,
    pub total_parties: u16,
    pub curve: FfiCurveType,
    pub created_at: u64,
    pub is_local: bool,
}

impl From<&ShardInfo> for FfiShardInfo {
    fn from(s: &ShardInfo) -> Self {
        FfiShardInfo {
            shard_id: s.shard_id.clone(),
            public_key: s.public_key.clone(),
            party_index: s.party_index,
            threshold: s.threshold,
            total_parties: s.total_parties,
            curve: s.curve.into(),
            created_at: s.created_at,
            is_local: s.is_local,
        }
    }
}

impl From<FfiShardInfo> for ShardInfo {
    fn from(s: FfiShardInfo) -> Self {
        ShardInfo {
            shard_id: s.shard_id,
            public_key: s.public_key,
            party_index: s.party_index,
            threshold: s.threshold,
            total_parties: s.total_parties,
            curve: s.curve.into(),
            created_at: s.created_at,
            is_local: s.is_local,
        }
    }
}

/// Noise-encrypted message envelope (handshake or transport payload).
#[derive(uniffi::Record)]
pub struct FfiSealedEnvelope {
    pub ciphertext: Vec<u8>,
    pub handshake: bool,
}

impl From<SealedEnvelope> for FfiSealedEnvelope {
    fn from(e: SealedEnvelope) -> Self {
        FfiSealedEnvelope {
            ciphertext: e.ciphertext,
            handshake: e.handshake,
        }
    }
}

impl From<FfiSealedEnvelope> for SealedEnvelope {
    fn from(e: FfiSealedEnvelope) -> Self {
        SealedEnvelope {
            ciphertext: e.ciphertext,
            handshake: e.handshake,
        }
    }
}

/// Curve25519 static keypair for Noise protocol (FFI-safe, not zeroized).
#[derive(uniffi::Record)]
pub struct FfiNoiseKeypair {
    pub private_key: Vec<u8>,
    pub public_key: Vec<u8>,
}

/// Session token containing room credentials for relay access control.
#[derive(uniffi::Record)]
pub struct FfiSessionToken {
    pub room_secret: Vec<u8>,
    pub access_token: Vec<u8>,
    pub room_id: String,
}

// ============================================================================
// EVM / BTC / Solana transaction params
// ============================================================================

/// EIP-1559 Ethereum transaction parameters.
#[derive(uniffi::Record)]
pub struct FfiEvmTxParams {
    pub to: String,
    pub value_wei: String, // decimal string for u128
    pub nonce: u64,
    pub gas_limit: u64,
    pub max_fee_per_gas: String,
    pub max_priority_fee_per_gas: String,
    pub chain_id: u64,
    pub data: Vec<u8>,
}

/// A Bitcoin UTXO input reference.
#[derive(uniffi::Record)]
pub struct FfiBtcInput {
    pub txid: String,
    pub vout: u32,
    pub value: u64,
    pub pubkey_hash: Option<Vec<u8>>,
    /// Raw bytes of the previous transaction (non-witness serialized).
    /// When supplied, the signing core verifies the input's claimed
    /// (txid, vout, value) against it. Omit at your peril — signing a
    /// P2WPKH input with a forged value field can send unbounded fees
    /// to miners (audit finding H9).
    pub prev_tx_raw: Option<Vec<u8>>,
}

/// A Bitcoin transaction output (destination + amount).
#[derive(uniffi::Record)]
pub struct FfiBtcOutput {
    pub address: String,
    pub value: u64,
    pub script_pubkey: Option<Vec<u8>>,
}

/// Bitcoin P2WPKH transaction parameters.
#[derive(uniffi::Record)]
pub struct FfiBtcTxParams {
    pub inputs: Vec<FfiBtcInput>,
    pub outputs: Vec<FfiBtcOutput>,
    pub testnet: bool,
}

/// Solana native SOL transfer parameters.
#[derive(uniffi::Record)]
pub struct FfiSolanaTxParams {
    pub from_address: String,
    pub to_address: String,
    pub lamports: u64,
    pub recent_blockhash: String,
    /// Unix-millis timestamp when `recent_blockhash` was fetched from
    /// RPC. Together with `now_unix_ms` below, this lets the signing
    /// core reject stale blockhashes (audit C5). Pass `None` for
    /// durable-nonce-backed transactions, or when the caller genuinely
    /// cannot record a fetch timestamp (legacy path — logs a warning).
    pub blockhash_fetched_at_unix_ms: Option<u64>,
    /// Unix-millis wall clock at sign time. Required whenever
    /// `blockhash_fetched_at_unix_ms` is `Some`. Passing both keeps the
    /// clock source under caller control (iOS uses its
    /// monotonic-anchored wall clock so a user tampering with device
    /// time can't trivially bypass the freshness gate — the RPC fetch
    /// and the sign time share the same reference).
    pub now_unix_ms: Option<u64>,
    /// If `true`, the transaction's blockhash slot is backed by a
    /// durable nonce account rather than a recent blockhash; skip the
    /// freshness check entirely. Mutually exclusive with
    /// `blockhash_fetched_at_unix_ms`.
    pub durable_nonce: bool,
    pub devnet: bool,
}

/// Chain-agnostic built transaction: raw serialized bytes + hash to sign.
#[derive(uniffi::Record)]
pub struct FfiTransaction {
    pub chain_type: String,
    pub raw_data: Vec<u8>,
    pub sign_hash: Vec<u8>,
}

// ============================================================================
// Namespace functions (free functions exposed via FFI)
// ============================================================================

/// Derive an Ethereum address from an uncompressed secp256k1 public key (65 bytes).
#[uniffi::export]
pub fn horcrux_evm_address(uncompressed_pubkey: Vec<u8>) -> Result<String, ChainError> {
    chain::evm_address_from_pubkey(&uncompressed_pubkey).map_err(Into::into)
}

/// Derive a bech32m Bitcoin address from a compressed secp256k1 public key (33 bytes).
#[uniffi::export]
pub fn horcrux_btc_address(compressed_pubkey: Vec<u8>, hrp: String) -> Result<String, ChainError> {
    chain::btc_address_from_pubkey(&compressed_pubkey, &hrp).map_err(Into::into)
}

/// Derive a base58 Solana address from an Ed25519 public key (32 bytes).
#[uniffi::export]
pub fn horcrux_solana_address(pubkey: Vec<u8>) -> Result<String, ChainError> {
    if pubkey.len() != 32 {
        return Err(ChainError::InvalidAddress {
            msg: "Ed25519 public key must be 32 bytes".into(),
        });
    }
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&pubkey);
    Ok(chain::solana_address_from_pubkey(&arr))
}

/// Compute Keccak-256 hash (used for Ethereum address derivation and signing).
#[uniffi::export]
pub fn horcrux_keccak256(data: Vec<u8>) -> Vec<u8> {
    chain::keccak256(&data).to_vec()
}

// ============================================================================
// EVM calldata decoder — surfaces what `data` field of an EIP-1559 tx is
// actually requesting, so the iOS approval sheet can warn on unlimited
// approvals, NFT blanket grants, and unrecognised selectors (audit C4).
// ============================================================================

/// Structured view of an outgoing EVM calldata blob. Mirrors
/// [`chain::evm::DecodedCall`] in an FFI-friendly shape (uniffi doesn't
/// export Rust enums with struct variants directly from other modules,
/// hence the translation layer).
#[derive(uniffi::Enum)]
pub enum FfiDecodedCall {
    /// Empty calldata — native value transfer.
    Transfer,
    /// `transfer(address,uint256)` — ERC-20 send.
    Erc20Transfer { to: String, amount_hex: String },
    /// `transferFrom(address,address,uint256)` — ERC-20 pull.
    Erc20TransferFrom {
        from: String,
        to: String,
        amount_hex: String,
    },
    /// `approve(address,uint256)`. `is_unlimited` flags approvals whose
    /// amount has bit 255 set (the "effectively infinite" convention).
    Erc20Approve {
        spender: String,
        amount_hex: String,
        is_unlimited: bool,
    },
    /// `setApprovalForAll(address,bool)` — blanket NFT approval.
    SetApprovalForAll { operator: String, approved: bool },
    /// Unknown selector — UI should warn the user explicitly.
    Unknown { selector_hex: String, data_len: u32 },
}

impl From<chain::evm::DecodedCall> for FfiDecodedCall {
    fn from(v: chain::evm::DecodedCall) -> Self {
        match v {
            chain::evm::DecodedCall::Transfer => FfiDecodedCall::Transfer,
            chain::evm::DecodedCall::Erc20Transfer { to, amount_hex } => {
                FfiDecodedCall::Erc20Transfer { to, amount_hex }
            }
            chain::evm::DecodedCall::Erc20TransferFrom {
                from,
                to,
                amount_hex,
            } => FfiDecodedCall::Erc20TransferFrom {
                from,
                to,
                amount_hex,
            },
            chain::evm::DecodedCall::Erc20Approve {
                spender,
                amount_hex,
                is_unlimited,
            } => FfiDecodedCall::Erc20Approve {
                spender,
                amount_hex,
                is_unlimited,
            },
            chain::evm::DecodedCall::SetApprovalForAll { operator, approved } => {
                FfiDecodedCall::SetApprovalForAll { operator, approved }
            }
            chain::evm::DecodedCall::Unknown {
                selector_hex,
                data_len,
            } => FfiDecodedCall::Unknown {
                selector_hex,
                data_len: data_len as u32,
            },
        }
    }
}

/// Decode an outgoing EVM `data` field (the calldata that would be sent
/// to `to`) into a structured [`FfiDecodedCall`]. Never throws: unknown
/// selectors become `FfiDecodedCall::Unknown` so the UI always has a
/// deterministic rendering path.
///
/// Callers must pass the entire calldata (including the 4-byte selector),
/// not just the arguments.
#[uniffi::export]
pub fn horcrux_decode_evm_calldata(data: Vec<u8>) -> FfiDecodedCall {
    chain::evm::decode_evm_calldata(&data).into()
}

/// FFI-friendly EIP-712 domain. Mirrors `chain::evm::Eip712Domain`
/// except `verifying_contract` is passed as a hex/0x-prefixed string
/// (uniffi Record types cannot carry fixed-size byte arrays directly).
#[derive(uniffi::Record)]
pub struct FfiEip712Domain {
    pub name: String,
    pub version: String,
    pub chain_id: u64,
    /// 20-byte address, hex or 0x-prefixed hex.
    pub verifying_contract: String,
}

/// Compute the EIP-712 typed-data digest (audit H8).
///
/// This is the sanctioned entry point for any EIP-712 signing flow:
/// it hard-fails when the domain is missing chain-id / contract /
/// name bindings that would let a signature be replayed on another
/// chain or another contract. The UI must have already displayed and
/// obtained user consent for the decoded domain fields before
/// invoking this — see `docs/security-audit-2026-04.md` H8.
///
/// `struct_hash` is the 32-byte `hashStruct(message)` value the UI
/// already computed from the typed-data payload.
#[uniffi::export]
pub fn horcrux_eip712_digest(
    domain: FfiEip712Domain,
    struct_hash: Vec<u8>,
) -> Result<Vec<u8>, ChainError> {
    if struct_hash.len() != 32 {
        return Err(ChainError::Other {
            msg: format!(
                "EIP-712 struct_hash must be 32 bytes, got {}",
                struct_hash.len()
            ),
        });
    }
    let addr_str = domain
        .verifying_contract
        .strip_prefix("0x")
        .unwrap_or(&domain.verifying_contract);
    let addr_bytes = hex::decode(addr_str)
        .map_err(|e| ChainError::InvalidAddress { msg: format!("bad hex: {e}") })?;
    if addr_bytes.len() != 20 {
        return Err(ChainError::InvalidAddress {
            msg: format!("expected 20 bytes, got {}", addr_bytes.len()),
        });
    }
    let mut addr = [0u8; 20];
    addr.copy_from_slice(&addr_bytes);

    let inner = chain::evm::Eip712Domain {
        name: domain.name,
        version: domain.version,
        chain_id: domain.chain_id,
        verifying_contract: addr,
    };
    let mut sh = [0u8; 32];
    sh.copy_from_slice(&struct_hash);
    chain::evm::eip712_digest(&inner, sh)
        .map(|d| d.to_vec())
        .map_err(Into::into)
}

/// Compute an EIP-712 v4 digest directly from an `eth_signTypedData_v4`
/// JSON payload (the canonical dApp / WalletConnect shape:
/// `{types, primaryType, domain, message}`). Delegates every
/// domain-binding check to `eip712_digest` so the audit-H8 guards
/// (non-zero `chainId`, non-zero `verifyingContract`, non-empty
/// `name`) apply identically to the UI-bound and JSON-bound paths.
#[uniffi::export]
pub fn horcrux_eip712_digest_from_typed_data(json: String) -> Result<Vec<u8>, ChainError> {
    chain::eip712_typed::eip712_digest_from_typed_data_json(&json)
        .map(|d| d.to_vec())
        .map_err(Into::into)
}

// ============================================================================
// Paillier prime pool — see mpc::prime_pool for rationale.
// ============================================================================

/// Install the pool directory. Must be called once at app startup before any
/// DKG / refresh ceremony. Subsequent calls overwrite the prior path.
#[uniffi::export]
pub fn horcrux_prime_pool_init(dir: String) -> Result<(), HorcruxError> {
    crate::mpc::prime_pool::init(std::path::PathBuf::from(dir))
        .map_err(|msg| HorcruxError::StorageError { msg })
}

/// Current number of pregenerated prime pairs available in the pool.
#[uniffi::export]
pub fn horcrux_prime_pool_count() -> u32 {
    crate::mpc::prime_pool::count()
}

/// Generate one prime pair and add it to the pool. Blocks the calling thread
/// for tens of seconds on mobile hardware; the host MUST invoke this on a
/// low-priority background thread (iOS `Task.detached(priority: .background)`).
/// Returns `Ok(())` on success, error string otherwise.
#[uniffi::export]
pub fn horcrux_prime_pool_generate_one() -> Result<(), HorcruxError> {
    crate::mpc::prime_pool::generate_one().map_err(|msg| HorcruxError::StorageError { msg })
}

/// Encrypt a key shard using AES-256-GCM with an HKDF-SHA256-derived key.
///
/// The key derivation mixes `device_key` (host-managed, e.g. SE-sealed on iOS)
/// and `pin` (a second user-supplied secret) as IKM via
/// `HKDF(ikm = device_key || pin, salt = random 16 B, info = b"horcrux-shard-encryption")`.
///
/// Note: on iOS the `pin` parameter is NOT the user's numeric PIN — it is the
/// Shard Wrap Key (SWK) unwrapped via either Face ID (Secure Enclave) or the
/// PIN-wrapped blob. The original `pin` name is preserved for ABI stability
/// with existing UniFFI Swift bindings. See
/// `ios/Horcrux/Security/SecureKeyVault.swift` for the full architecture.
#[uniffi::export]
pub fn horcrux_encrypt_shard(
    plaintext: Vec<u8>,
    device_key: Vec<u8>,
    pin: Vec<u8>,
) -> Result<FfiEncryptedShard, HorcruxError> {
    shard_crypto::encrypt_shard(&plaintext, &device_key, &pin)
        .map(Into::into)
        .map_err(|e| HorcruxError::EncryptionFailed {
            msg: sanitize_ffi_msg("EncryptionFailed", &e.to_string()),
        })
}

/// Decrypt a previously encrypted key shard. See `horcrux_encrypt_shard` for
/// the semantics of `device_key` / `pin`.
#[uniffi::export]
pub fn horcrux_decrypt_shard(
    encrypted: FfiEncryptedShard,
    device_key: Vec<u8>,
    pin: Vec<u8>,
) -> Result<Vec<u8>, HorcruxError> {
    let es: EncryptedShard = encrypted.into();
    let decrypted = shard_crypto::decrypt_shard(&es, &device_key, &pin).map_err(|e| {
        HorcruxError::DecryptionFailed {
            msg: sanitize_ffi_msg("DecryptionFailed", &e.to_string()),
        }
    })?;
    // Zeroizing<Vec<u8>> → Vec<u8> for FFI; caller (iOS) must zero the result.
    Ok(decrypted.to_vec())
}

/// Generate a fresh Curve25519 Noise keypair for E2E encrypted communication.
#[uniffi::export]
pub fn horcrux_generate_noise_keypair() -> Result<FfiNoiseKeypair, FfiE2EError> {
    let kp = NoiseKeypair::generate()?;
    Ok(FfiNoiseKeypair {
        private_key: kp.private.clone(),
        public_key: kp.public.clone(),
    })
}

/// Generate a random session token (room_id, room_secret, access_token) for relay access.
#[uniffi::export]
pub fn horcrux_generate_session_token() -> Result<FfiSessionToken, FfiE2EError> {
    let st = SessionToken::generate().map_err(FfiE2EError::from)?;
    Ok(FfiSessionToken {
        room_secret: st.room_secret.clone(),
        access_token: st.access_token.clone(),
        room_id: st.room_id.clone(),
    })
}

/// Build an EVM (EIP-1559) transaction and return the signing hash.
#[uniffi::export]
pub fn horcrux_build_evm_transaction(params: FfiEvmTxParams) -> Result<FfiTransaction, ChainError> {
    let parse_u128 = |s: &str, name: &str| -> Result<u128, ChainError> {
        s.parse::<u128>().map_err(|_| ChainError::Other {
            msg: format!("invalid {name}: '{s}' is not a valid u128"),
        })
    };
    let evm_params = chain::evm::EvmTxParams {
        to: params.to,
        value: parse_u128(&params.value_wei, "value_wei")?,
        nonce: params.nonce,
        gas_limit: params.gas_limit,
        max_fee_per_gas: parse_u128(&params.max_fee_per_gas, "max_fee_per_gas")?,
        max_priority_fee_per_gas: parse_u128(
            &params.max_priority_fee_per_gas,
            "max_priority_fee_per_gas",
        )?,
        chain_id: params.chain_id,
        data: params.data,
    };
    let tx = chain::evm::EvmTransactionBuilder.build(evm_params)?;
    Ok(FfiTransaction {
        chain_type: format!("evm:{}", params.chain_id),
        raw_data: tx.raw_data,
        sign_hash: tx.sign_hash,
    })
}

/// Build a Bitcoin transaction (P2WPKH segwit) and return the BIP-143 sighash for a given input.
#[uniffi::export]
pub fn horcrux_build_btc_transaction(
    params: FfiBtcTxParams,
    input_index: u32,
) -> Result<FfiTransaction, ChainError> {
    let testnet = params.testnet;
    let btc_params = chain::bitcoin::BtcTxParams {
        inputs: params
            .inputs
            .into_iter()
            .map(|i| chain::bitcoin::BtcInput {
                txid: i.txid,
                vout: i.vout,
                value: i.value,
                pubkey_hash: i.pubkey_hash,
                prev_tx_raw: i.prev_tx_raw,
            })
            .collect(),
        outputs: params
            .outputs
            .into_iter()
            .map(|o| chain::bitcoin::BtcOutput {
                address: o.address,
                value: o.value,
                script_pubkey: o.script_pubkey,
            })
            .collect(),
        testnet,
    };
    let tx = chain::bitcoin::BtcTransactionBuilder.build(btc_params.clone())?;
    let sighash = chain::bitcoin::bip143_sighash(&btc_params, input_index as usize)?;
    Ok(FfiTransaction {
        chain_type: if testnet {
            "btc:testnet".into()
        } else {
            "btc:mainnet".into()
        },
        raw_data: tx.raw_data,
        sign_hash: sighash.to_vec(),
    })
}

/// Build a Solana transfer transaction and return the signing hash.
#[uniffi::export]
pub fn horcrux_build_solana_transaction(
    params: FfiSolanaTxParams,
) -> Result<FfiTransaction, ChainError> {
    let blockhash_mode = if params.durable_nonce {
        Some(chain::solana::SolanaBlockhashMode::DurableNonce)
    } else {
        match (params.blockhash_fetched_at_unix_ms, params.now_unix_ms) {
            (Some(fetched_at_unix_ms), Some(now_unix_ms)) => {
                Some(chain::solana::SolanaBlockhashMode::Recent {
                    fetched_at_unix_ms,
                    now_unix_ms,
                })
            }
            _ => None,
        }
    };
    let sol_params = chain::solana::SolanaTxParams {
        from: params.from_address,
        to: params.to_address,
        lamports: params.lamports,
        recent_blockhash: params.recent_blockhash,
        blockhash_mode,
        devnet: params.devnet,
    };
    let tx = chain::solana::SolanaTransactionBuilder.build(sol_params)?;
    Ok(FfiTransaction {
        chain_type: if params.devnet {
            "sol:devnet".into()
        } else {
            "sol:mainnet".into()
        },
        raw_data: tx.raw_data,
        sign_hash: tx.sign_hash,
    })
}

// ============================================================================
// HorcruxSessionManager — object with methods
// ============================================================================

/// Thread-safe MPC session manager exposed to the host application via UniFFI.
///
/// Manages concurrent DKG and signing sessions. All access goes through a Mutex
/// to protect the internal state machines (which may use non-Send types).
#[derive(uniffi::Object)]
pub struct HorcruxSessionManager {
    inner: Mutex<SessionManager>,
}

// SAFETY: All access to SessionManager goes through Mutex, ensuring exclusive
// access. The !Send bound comes from cggmp21's Rc-based state machines —
// our Mutex prevents any concurrent access to those internals.
unsafe impl Send for HorcruxSessionManager {}
unsafe impl Sync for HorcruxSessionManager {}

impl Default for HorcruxSessionManager {
    fn default() -> Self {
        Self::new()
    }
}

#[uniffi::export]
impl HorcruxSessionManager {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(SessionManager::new()),
        }
    }

    /// Initiate a distributed key generation session. Returns initial outgoing messages.
    pub fn create_keygen(
        &self,
        session_id: String,
        config: FfiHorcruxConfig,
    ) -> Result<Vec<FfiMpcMessage>, HorcruxError> {
        let cfg = HorcruxConfig::new(
            config.threshold,
            config.total_parties,
            config.party_index,
            config.curve.into(),
        )?;
        let mut mgr = lock_or_err!(self.inner, HorcruxError, SessionError)?;
        let msgs = mgr.create_keygen(session_id, cfg)?;
        Ok(msgs.into_iter().map(Into::into).collect())
    }

    /// Start a threshold signing session. Requires the local shard and participant list.
    pub fn create_signing(
        &self,
        session_id: String,
        config: FfiHorcruxConfig,
        message_hash: Vec<u8>,
        shard_data: Vec<u8>,
        participants: Vec<u16>,
    ) -> Result<Vec<FfiMpcMessage>, HorcruxError> {
        let cfg = HorcruxConfig::new(
            config.threshold,
            config.total_parties,
            config.party_index,
            config.curve.into(),
        )?;
        let mut mgr = lock_or_err!(self.inner, HorcruxError, SessionError)?;
        let msgs = mgr.create_signing(session_id, cfg, message_hash, shard_data, participants)?;
        Ok(msgs.into_iter().map(Into::into).collect())
    }

    /// Initiate a proactive key refresh session. Re-randomises the local
    /// shard while keeping the wallet's group public key unchanged.
    /// Currently restricted to n-of-n CGGMP21 ECDSA shares.
    pub fn create_refresh(
        &self,
        session_id: String,
        config: FfiHorcruxConfig,
        shard_data: Vec<u8>,
    ) -> Result<Vec<FfiMpcMessage>, HorcruxError> {
        let cfg = HorcruxConfig::new(
            config.threshold,
            config.total_parties,
            config.party_index,
            config.curve.into(),
        )?;
        let mut mgr = lock_or_err!(self.inner, HorcruxError, SessionError)?;
        let msgs = mgr.create_refresh(session_id, cfg, shard_data)?;
        Ok(msgs.into_iter().map(Into::into).collect())
    }

    /// Process an inbound MPC protocol message and return any outgoing responses.
    ///
    /// ⚠️ **DO NOT CALL FROM PRODUCTION SWIFT CODE.** This variant does not
    /// verify the claimed sender against the transport-authenticated peer.
    /// Use `handle_authenticated_message` instead — see audit finding C1.
    pub fn handle_message(&self, msg: FfiMpcMessage) -> Result<Vec<FfiMpcMessage>, HorcruxError> {
        let mut mgr = lock_or_err!(self.inner, HorcruxError, SessionError)?;
        let msgs = mgr.handle_message(msg.into())?;
        Ok(msgs.into_iter().map(Into::into).collect())
    }

    /// Process an inbound MPC protocol message, verifying that the claimed
    /// sender (`msg.from_party`) equals `authenticated_from`.
    ///
    /// The caller MUST pass the party index bound at keygen time to the
    /// Noise-authenticated peer that actually decrypted the inbound bytes.
    /// Passing `msg.from_party` is a vulnerability — it trivially satisfies
    /// the check and reintroduces the rogue-party impersonation window.
    pub fn handle_authenticated_message(
        &self,
        msg: FfiMpcMessage,
        authenticated_from: u16,
    ) -> Result<Vec<FfiMpcMessage>, HorcruxError> {
        let mut mgr = lock_or_err!(self.inner, HorcruxError, SessionError)?;
        let msgs = mgr.handle_authenticated_message(msg.into(), authenticated_from)?;
        Ok(msgs.into_iter().map(Into::into).collect())
    }

    /// Retrieve the DKG result (public key + shard). Returns `None` if still in progress.
    pub fn get_keygen_result(&self, session_id: String) -> Option<FfiKeygenResult> {
        let mgr = self.inner.lock().ok()?;
        mgr.keygen_result(&session_id).map(Into::into)
    }

    /// Retrieve a refresh ceremony result (new shard, same public key).
    /// Returns `None` if still in progress. Uses the same payload shape as
    /// `FfiKeygenResult`; on success the `public_key` is identical to the
    /// pre-refresh value and `shard_data` is the new encrypted-on-disk shard.
    pub fn get_refresh_result(&self, session_id: String) -> Option<FfiKeygenResult> {
        let mgr = self.inner.lock().ok()?;
        mgr.keygen_result(&session_id).map(Into::into)
    }

    /// Retrieve the signing result (signature). Returns `None` if still in progress.
    pub fn get_signing_result(&self, session_id: String) -> Option<FfiSigningResult> {
        let mgr = self.inner.lock().ok()?;
        mgr.signing_result(&session_id).map(Into::into)
    }

    /// Remove a completed or abandoned session from memory.
    pub fn remove_session(&self, session_id: String) {
        if let Ok(mut mgr) = self.inner.lock() {
            mgr.remove_session(&session_id);
        }
    }
}

// ============================================================================
// HorcruxShardManager
// ============================================================================

/// Thread-safe shard registry for tracking key shards across wallets.
#[derive(uniffi::Object)]
pub struct HorcruxShardManager {
    inner: Mutex<ShardManager>,
}

impl Default for HorcruxShardManager {
    fn default() -> Self {
        Self::new()
    }
}

#[uniffi::export]
impl HorcruxShardManager {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(ShardManager::new()),
        }
    }

    /// Register a shard in the in-memory registry.
    pub fn add_shard(&self, info: FfiShardInfo) {
        if let Ok(mut mgr) = self.inner.lock() {
            mgr.add_shard(info.into());
        }
    }

    /// List all registered shards.
    pub fn list_shards(&self) -> Vec<FfiShardInfo> {
        match self.inner.lock() {
            Ok(mgr) => mgr.list_shards().iter().map(Into::into).collect(),
            Err(_) => Vec::new(),
        }
    }

    /// Filter shards by their associated public key.
    pub fn shards_for_key(&self, public_key: Vec<u8>) -> Vec<FfiShardInfo> {
        match self.inner.lock() {
            Ok(mgr) => mgr
                .shards_for_key(&public_key)
                .into_iter()
                .map(Into::into)
                .collect(),
            Err(_) => Vec::new(),
        }
    }
}

// ============================================================================
// HorcruxNoiseChannel — E2E encrypted communication
// ============================================================================

/// E2E encrypted Noise channel exposed to the host application.
///
/// Wraps the Noise_XX state machine (Curve25519 + ChaChaPoly + SHA-256).
/// Progress: `new_initiator/new_responder` → handshake → `seal`/`open`.
#[derive(uniffi::Object)]
pub struct HorcruxNoiseChannel {
    inner: Mutex<NoiseChannel>,
}

#[uniffi::export]
impl HorcruxNoiseChannel {
    /// Create an initiator channel (the party that starts the handshake).
    #[uniffi::constructor]
    pub fn new_initiator(keypair: FfiNoiseKeypair) -> Result<Self, FfiE2EError> {
        let kp = NoiseKeypair {
            private: keypair.private_key,
            public: keypair.public_key,
        };
        let channel = NoiseChannel::initiator(&kp)?;
        Ok(Self {
            inner: Mutex::new(channel),
        })
    }

    /// Create a responder channel.
    #[uniffi::constructor]
    pub fn new_responder(keypair: FfiNoiseKeypair) -> Result<Self, FfiE2EError> {
        let kp = NoiseKeypair {
            private: keypair.private_key,
            public: keypair.public_key,
        };
        let channel = NoiseChannel::responder(&kp)?;
        Ok(Self {
            inner: Mutex::new(channel),
        })
    }

    /// Write the next handshake message (caller → peer).
    pub fn write_handshake(&self, payload: Vec<u8>) -> Result<Vec<u8>, FfiE2EError> {
        let mut ch = lock_or_err!(self.inner, FfiE2EError, Handshake)?;
        ch.write_handshake(&payload).map_err(Into::into)
    }

    /// Read a handshake message from the peer and return the decrypted payload.
    pub fn read_handshake(&self, message: Vec<u8>) -> Result<Vec<u8>, FfiE2EError> {
        let mut ch = lock_or_err!(self.inner, FfiE2EError, Handshake)?;
        ch.read_handshake(&message).map_err(Into::into)
    }

    /// Check whether the Noise handshake is complete (channel in transport mode).
    pub fn is_handshake_finished(&self) -> bool {
        self.inner
            .lock()
            .map(|ch| ch.is_handshake_finished())
            .unwrap_or(false)
    }

    /// Get the peer's static public key (available after handshake completes).
    pub fn remote_static_key(&self) -> Option<Vec<u8>> {
        self.inner.lock().ok()?.remote_static_key()
    }

    /// Encrypt a message for transport (post-handshake).
    pub fn seal(&self, plaintext: Vec<u8>) -> Result<FfiSealedEnvelope, FfiE2EError> {
        let mut ch = lock_or_err!(self.inner, FfiE2EError, Handshake)?;
        ch.seal(&plaintext).map(Into::into).map_err(Into::into)
    }

    /// Decrypt a sealed envelope from the peer (post-handshake).
    pub fn open(&self, envelope: FfiSealedEnvelope) -> Result<Vec<u8>, FfiE2EError> {
        let mut ch = lock_or_err!(self.inner, FfiE2EError, Handshake)?;
        let se: SealedEnvelope = envelope.into();
        ch.open(&se).map_err(Into::into)
    }
}

// ============================================================================
// UniFFI scaffolding
// ============================================================================

// Note: uniffi::setup_scaffolding!() is in lib.rs (crate root)

#[cfg(test)]
mod tests {
    use super::*;

    // ---- M5 sanitize_ffi_msg tests ----

    #[test]
    fn sanitize_passes_normal_messages() {
        let s = sanitize_ffi_msg("Cat", "invalid party index");
        assert_eq!(s, "invalid party index");
    }

    #[test]
    fn sanitize_strips_newlines_and_control_bytes() {
        let s = sanitize_ffi_msg("Cat", "line1\nline2\twith\x07bell");
        assert_eq!(s, "line1 line2 with?bell");
    }

    #[test]
    fn sanitize_truncates_long_messages() {
        let raw = "x".repeat(1024);
        let s = sanitize_ffi_msg("Cat", &raw);
        assert!(s.ends_with("..."));
        assert_eq!(s.chars().count(), 256);
    }

    #[test]
    fn sanitize_redacts_long_hex_runs() {
        let raw = format!("decryption failed at {}", "deadbeef".repeat(8));
        let s = sanitize_ffi_msg("DecryptionFailed", &raw);
        assert!(s.contains("redacted"), "expected redaction, got: {s}");
    }

    // ---- EVM transaction tests ----

    fn valid_evm_params() -> FfiEvmTxParams {
        FfiEvmTxParams {
            to: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045".into(),
            value_wei: "1000000000000000000".into(), // 1 ETH
            nonce: 0,
            gas_limit: 21000,
            max_fee_per_gas: "30000000000".into(),
            max_priority_fee_per_gas: "1000000000".into(),
            chain_id: 1,
            data: vec![],
        }
    }

    #[test]
    fn test_ffi_build_evm_transaction_valid() {
        let tx = horcrux_build_evm_transaction(valid_evm_params()).unwrap();
        assert!(tx.chain_type.starts_with("evm:"));
        assert_eq!(tx.chain_type, "evm:1");
        assert!(!tx.raw_data.is_empty());
        assert!(!tx.sign_hash.is_empty());
        assert_eq!(tx.sign_hash.len(), 32);
    }

    #[test]
    fn test_ffi_build_evm_transaction_invalid_value_wei() {
        let mut params = valid_evm_params();
        params.value_wei = "not_a_number".into();
        let result = horcrux_build_evm_transaction(params);
        assert!(result.is_err());
        match result {
            Err(ChainError::Other { .. }) => {}
            other => panic!("expected ChainError::Other, got is_err={}", other.is_err()),
        }
    }

    #[test]
    fn test_ffi_build_evm_transaction_invalid_max_fee() {
        let mut params = valid_evm_params();
        params.max_fee_per_gas = "bad_fee".into();
        assert!(horcrux_build_evm_transaction(params).is_err());
    }

    #[test]
    fn test_ffi_build_evm_transaction_invalid_priority_fee() {
        let mut params = valid_evm_params();
        params.max_priority_fee_per_gas = "xyz".into();
        assert!(horcrux_build_evm_transaction(params).is_err());
    }

    #[test]
    fn test_ffi_build_evm_transaction_zero_value() {
        let mut params = valid_evm_params();
        params.value_wei = "0".into();
        let tx = horcrux_build_evm_transaction(params).unwrap();
        assert!(tx.chain_type.starts_with("evm:"));
        assert!(!tx.raw_data.is_empty());
        assert_eq!(tx.sign_hash.len(), 32);
    }

    // ---- BTC transaction tests ----

    fn valid_btc_params() -> FfiBtcTxParams {
        FfiBtcTxParams {
            inputs: vec![FfiBtcInput {
                txid: "aa".repeat(32),
                vout: 0,
                value: 100_000,
                pubkey_hash: Some(vec![0xab; 20]),
                prev_tx_raw: None,
            }],
            outputs: vec![FfiBtcOutput {
                address: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx".into(),
                value: 90_000,
                script_pubkey: Some(vec![
                    0x00, 0x14, // witness v0, push 20
                    0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4, 0x54, 0x94, 0x1c, 0x45, 0xd1,
                    0xb3, 0xa3, 0x23, 0xf1, 0x43, 0x3b, 0xd6,
                ]),
            }],
            testnet: true,
        }
    }

    #[test]
    fn test_ffi_build_btc_transaction_valid() {
        let tx = horcrux_build_btc_transaction(valid_btc_params(), 0).unwrap();
        assert_eq!(tx.chain_type, "btc:testnet");
        assert!(!tx.raw_data.is_empty());
        assert!(!tx.sign_hash.is_empty());
        assert_eq!(tx.sign_hash.len(), 32);
    }

    #[test]
    fn test_ffi_build_btc_transaction_mainnet() {
        let mut params = valid_btc_params();
        params.testnet = false;
        let tx = horcrux_build_btc_transaction(params, 0).unwrap();
        assert_eq!(tx.chain_type, "btc:mainnet");
    }

    // ---- Solana transaction tests ----

    fn valid_solana_params() -> FfiSolanaTxParams {
        FfiSolanaTxParams {
            from_address: bs58::encode([1u8; 32]).into_string(),
            to_address: bs58::encode([2u8; 32]).into_string(),
            lamports: 1_000_000,
            recent_blockhash: bs58::encode([3u8; 32]).into_string(),
            blockhash_fetched_at_unix_ms: Some(0),
            now_unix_ms: Some(0),
            durable_nonce: false,
            devnet: true,
        }
    }

    #[test]
    fn test_ffi_build_solana_transaction_valid() {
        let tx = horcrux_build_solana_transaction(valid_solana_params()).unwrap();
        assert!(tx.chain_type.contains("sol:"));
        assert_eq!(tx.chain_type, "sol:devnet");
        assert!(!tx.raw_data.is_empty());
        assert!(!tx.sign_hash.is_empty());
    }

    #[test]
    fn test_ffi_build_solana_transaction_mainnet() {
        let mut params = valid_solana_params();
        params.devnet = false;
        let tx = horcrux_build_solana_transaction(params).unwrap();
        assert_eq!(tx.chain_type, "sol:mainnet");
    }

    // ---- Noise keypair & session token tests ----

    #[test]
    fn test_ffi_generate_noise_keypair() {
        let kp = horcrux_generate_noise_keypair().unwrap();
        assert_eq!(kp.private_key.len(), 32);
        assert_eq!(kp.public_key.len(), 32);
        // Two keypairs should differ
        let kp2 = horcrux_generate_noise_keypair().unwrap();
        assert_ne!(kp.private_key, kp2.private_key);
        assert_ne!(kp.public_key, kp2.public_key);
    }

    #[test]
    fn test_ffi_generate_session_token() {
        let st = horcrux_generate_session_token().unwrap();
        assert!(!st.room_secret.is_empty());
        assert!(!st.access_token.is_empty());
        assert!(!st.room_id.is_empty());
    }
}
