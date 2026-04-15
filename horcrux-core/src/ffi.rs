//! UniFFI scaffolding — bridges UDL definitions to actual Rust implementations.
//!
//! UniFFI requires flat types at the FFI boundary. This module adapts the
//! internal Rust types (which may use generics, traits, etc.) into the
//! simple structs/enums declared in `horcrux.udl`.

use std::sync::Mutex;

use crate::chain;
use crate::mpc::{CurveType, HorcruxConfig, MpcError};
use crate::mpc::session::SessionManager;
use crate::mpc::types::{KeygenResult, MpcMessage, SigningResult};
use crate::shard::crypto::{self as shard_crypto, EncryptedShard};
use crate::shard::{ShardInfo, ShardManager};
use crate::transport::e2e::{E2EError, NoiseChannel, NoiseKeypair, SealedEnvelope, SessionToken};

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
            MpcError::InvalidConfig(msg) => HorcruxError::InvalidConfig { msg },
            MpcError::KeygenFailed(msg) => HorcruxError::KeygenFailed { msg },
            MpcError::SigningFailed(msg) => HorcruxError::SigningFailed { msg },
            MpcError::SessionError(msg) => HorcruxError::SessionError { msg },
            MpcError::ProtocolError(msg) => HorcruxError::ProtocolError { msg },
            MpcError::InsufficientParties { needed, got } => {
                HorcruxError::InsufficientParties { needed, got }
            }
        }
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
    #[error("{msg}")]
    Other { msg: String },
}

impl From<chain::ChainError> for ChainError {
    fn from(e: chain::ChainError) -> Self {
        match e {
            chain::ChainError::InvalidAddress(msg) => ChainError::InvalidAddress { msg },
            chain::ChainError::EncodingError(msg) => ChainError::EncodingError { msg },
            chain::ChainError::InsufficientBalance => ChainError::InsufficientBalance,
            chain::ChainError::Other(msg) => ChainError::Other { msg },
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

#[derive(uniffi::Record)]
pub struct FfiHorcruxConfig {
    pub threshold: u16,
    pub total_parties: u16,
    pub party_index: u16,
    pub curve: FfiCurveType,
}

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

#[derive(uniffi::Record)]
pub struct FfiMpcMessage {
    pub from_party: u16,
    pub to_party: u16,
    pub round: u32,
    pub session_id: String,
    pub payload: Vec<u8>,
}

impl From<MpcMessage> for FfiMpcMessage {
    fn from(m: MpcMessage) -> Self {
        FfiMpcMessage {
            from_party: m.from,
            to_party: m.to,
            round: m.round,
            session_id: m.session_id,
            payload: m.payload,
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

#[derive(uniffi::Record)]
pub struct FfiKeygenResult {
    pub public_key: Vec<u8>,
    pub shard_data: Vec<u8>,
    pub party_index: u16,
    pub threshold: u16,
    pub total_parties: u16,
}

impl From<KeygenResult> for FfiKeygenResult {
    fn from(r: KeygenResult) -> Self {
        FfiKeygenResult {
            public_key: r.public_key,
            shard_data: r.shard_data,
            party_index: r.party_index,
            threshold: r.threshold,
            total_parties: r.total_parties,
        }
    }
}

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

#[derive(uniffi::Record)]
pub struct FfiNoiseKeypair {
    pub private_key: Vec<u8>,
    pub public_key: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct FfiSessionToken {
    pub room_secret: Vec<u8>,
    pub access_token: Vec<u8>,
    pub room_id: String,
}

// ============================================================================
// EVM / BTC / Solana transaction params
// ============================================================================

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

#[derive(uniffi::Record)]
pub struct FfiBtcInput {
    pub txid: String,
    pub vout: u32,
    pub value: u64,
    pub pubkey_hash: Option<Vec<u8>>,
}

#[derive(uniffi::Record)]
pub struct FfiBtcOutput {
    pub address: String,
    pub value: u64,
    pub script_pubkey: Option<Vec<u8>>,
}

#[derive(uniffi::Record)]
pub struct FfiBtcTxParams {
    pub inputs: Vec<FfiBtcInput>,
    pub outputs: Vec<FfiBtcOutput>,
    pub testnet: bool,
}

#[derive(uniffi::Record)]
pub struct FfiSolanaTxParams {
    pub from_address: String,
    pub to_address: String,
    pub lamports: u64,
    pub recent_blockhash: String,
    pub devnet: bool,
}

#[derive(uniffi::Record)]
pub struct FfiTransaction {
    pub chain_type: String,
    pub raw_data: Vec<u8>,
    pub sign_hash: Vec<u8>,
}

// ============================================================================
// Namespace functions (free functions exposed via FFI)
// ============================================================================

#[uniffi::export]
pub fn horcrux_evm_address(uncompressed_pubkey: Vec<u8>) -> Result<String, ChainError> {
    chain::evm_address_from_pubkey(&uncompressed_pubkey).map_err(Into::into)
}

#[uniffi::export]
pub fn horcrux_btc_address(compressed_pubkey: Vec<u8>, hrp: String) -> Result<String, ChainError> {
    chain::btc_address_from_pubkey(&compressed_pubkey, &hrp).map_err(Into::into)
}

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

#[uniffi::export]
pub fn horcrux_keccak256(data: Vec<u8>) -> Vec<u8> {
    chain::keccak256(&data).to_vec()
}

#[uniffi::export]
pub fn horcrux_encrypt_shard(
    plaintext: Vec<u8>,
    device_key: Vec<u8>,
    pin: Vec<u8>,
) -> Result<FfiEncryptedShard, HorcruxError> {
    shard_crypto::encrypt_shard(&plaintext, &device_key, &pin)
        .map(Into::into)
        .map_err(|e| HorcruxError::EncryptionFailed { msg: e })
}

#[uniffi::export]
pub fn horcrux_decrypt_shard(
    encrypted: FfiEncryptedShard,
    device_key: Vec<u8>,
    pin: Vec<u8>,
) -> Result<Vec<u8>, HorcruxError> {
    let es: EncryptedShard = encrypted.into();
    shard_crypto::decrypt_shard(&es, &device_key, &pin)
        .map_err(|e| HorcruxError::DecryptionFailed { msg: e })
}

#[uniffi::export]
pub fn horcrux_generate_noise_keypair() -> FfiNoiseKeypair {
    let kp = NoiseKeypair::generate();
    FfiNoiseKeypair {
        private_key: kp.private,
        public_key: kp.public,
    }
}

#[uniffi::export]
pub fn horcrux_generate_session_token() -> FfiSessionToken {
    let st = SessionToken::generate();
    FfiSessionToken {
        room_secret: st.room_secret,
        access_token: st.access_token,
        room_id: st.room_id,
    }
}

// ============================================================================
// HorcruxSessionManager — object with methods
// ============================================================================

#[derive(uniffi::Object)]
pub struct HorcruxSessionManager {
    inner: Mutex<SessionManager>,
}

// SAFETY: All access to SessionManager goes through Mutex, ensuring exclusive
// access. The !Send bound comes from cggmp21's Rc-based state machines —
// our Mutex prevents any concurrent access to those internals.
unsafe impl Send for HorcruxSessionManager {}
unsafe impl Sync for HorcruxSessionManager {}

#[uniffi::export]
impl HorcruxSessionManager {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(SessionManager::new()),
        }
    }

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
        let mut mgr = self.inner.lock().unwrap();
        let msgs = mgr.create_keygen(session_id, cfg)?;
        Ok(msgs.into_iter().map(Into::into).collect())
    }

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
        let mut mgr = self.inner.lock().unwrap();
        let msgs = mgr.create_signing(session_id, cfg, message_hash, shard_data, participants)?;
        Ok(msgs.into_iter().map(Into::into).collect())
    }

    pub fn handle_message(&self, msg: FfiMpcMessage) -> Result<Vec<FfiMpcMessage>, HorcruxError> {
        let mut mgr = self.inner.lock().unwrap();
        let msgs = mgr.handle_message(msg.into())?;
        Ok(msgs.into_iter().map(Into::into).collect())
    }

    pub fn get_keygen_result(&self, session_id: String) -> Option<FfiKeygenResult> {
        let mgr = self.inner.lock().unwrap();
        mgr.keygen_result(&session_id).map(Into::into)
    }

    pub fn get_signing_result(&self, session_id: String) -> Option<FfiSigningResult> {
        let mgr = self.inner.lock().unwrap();
        mgr.signing_result(&session_id).map(Into::into)
    }

    pub fn remove_session(&self, session_id: String) {
        let mut mgr = self.inner.lock().unwrap();
        mgr.remove_session(&session_id);
    }
}

// ============================================================================
// HorcruxShardManager
// ============================================================================

#[derive(uniffi::Object)]
pub struct HorcruxShardManager {
    inner: Mutex<ShardManager>,
}

#[uniffi::export]
impl HorcruxShardManager {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(ShardManager::new()),
        }
    }

    pub fn add_shard(&self, info: FfiShardInfo) {
        let mut mgr = self.inner.lock().unwrap();
        mgr.add_shard(info.into());
    }

    pub fn list_shards(&self) -> Vec<FfiShardInfo> {
        let mgr = self.inner.lock().unwrap();
        mgr.list_shards().iter().map(Into::into).collect()
    }

    pub fn shards_for_key(&self, public_key: Vec<u8>) -> Vec<FfiShardInfo> {
        let mgr = self.inner.lock().unwrap();
        mgr.shards_for_key(&public_key)
            .into_iter()
            .map(Into::into)
            .collect()
    }
}

// ============================================================================
// HorcruxNoiseChannel — E2E encrypted communication
// ============================================================================

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

    pub fn write_handshake(&self, payload: Vec<u8>) -> Result<Vec<u8>, FfiE2EError> {
        let mut ch = self.inner.lock().unwrap();
        ch.write_handshake(&payload).map_err(Into::into)
    }

    pub fn read_handshake(&self, message: Vec<u8>) -> Result<Vec<u8>, FfiE2EError> {
        let mut ch = self.inner.lock().unwrap();
        ch.read_handshake(&message).map_err(Into::into)
    }

    pub fn is_handshake_finished(&self) -> bool {
        let ch = self.inner.lock().unwrap();
        ch.is_handshake_finished()
    }

    pub fn remote_static_key(&self) -> Option<Vec<u8>> {
        let ch = self.inner.lock().unwrap();
        ch.remote_static_key()
    }

    pub fn seal(&self, plaintext: Vec<u8>) -> Result<FfiSealedEnvelope, FfiE2EError> {
        let mut ch = self.inner.lock().unwrap();
        ch.seal(&plaintext).map(Into::into).map_err(Into::into)
    }

    pub fn open(&self, envelope: FfiSealedEnvelope) -> Result<Vec<u8>, FfiE2EError> {
        let mut ch = self.inner.lock().unwrap();
        let se: SealedEnvelope = envelope.into();
        ch.open(&se).map_err(Into::into)
    }
}

// ============================================================================
// UniFFI scaffolding
// ============================================================================

// Note: uniffi::setup_scaffolding!() is in lib.rs (crate root)
