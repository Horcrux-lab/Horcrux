use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, ZeroizeOnDrop};

/// A round message exchanged during MPC protocols (DKG or signing).
///
/// The `payload` field can carry secret material during keygen (e.g. an
/// encrypted point-to-point share). Cloning is supported because routing
/// often needs to fan-out the same logical message — each clone owns its
/// own buffer and zeroes on drop. Custom `Debug` redacts `payload` so a
/// stray `tracing::debug!` of an `MpcMessage` cannot accidentally dump
/// share bytes (M4, audit `docs/security-audit-2026-04.md`).
#[derive(Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct MpcMessage {
    /// Sender party index
    #[zeroize(skip)]
    pub from: u16,
    /// Recipient party index (0 = broadcast)
    #[zeroize(skip)]
    pub to: u16,
    /// Protocol round number
    #[zeroize(skip)]
    pub round: u32,
    /// Session identifier
    #[zeroize(skip)]
    pub session_id: String,
    /// Serialized protocol payload
    pub payload: Vec<u8>,
}

impl std::fmt::Debug for MpcMessage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MpcMessage")
            .field("from", &self.from)
            .field("to", &self.to)
            .field("round", &self.round)
            .field("session_id", &self.session_id)
            .field(
                "payload",
                &format_args!("<redacted: {} bytes>", self.payload.len()),
            )
            .finish()
    }
}

/// Result of a completed DKG — the public key and this party's shard.
///
/// `shard_data` is the long-term secret share. Custom `Debug` redacts it
/// and `ZeroizeOnDrop` ensures the buffer is overwritten on drop so a
/// caller that lets the result fall out of scope without explicitly
/// re-encrypting it doesn't leave the share in freed heap (M4).
#[derive(Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct KeygenResult {
    /// The aggregated public key (shared across all parties)
    #[zeroize(skip)]
    pub public_key: Vec<u8>,
    /// This party's secret shard (encrypted before storage)
    pub shard_data: Vec<u8>,
    /// Party index
    #[zeroize(skip)]
    pub party_index: u16,
    /// Threshold configuration
    #[zeroize(skip)]
    pub threshold: u16,
    /// Total parties
    #[zeroize(skip)]
    pub total_parties: u16,
}

impl std::fmt::Debug for KeygenResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KeygenResult")
            .field("public_key_len", &self.public_key.len())
            .field(
                "shard_data",
                &format_args!("<redacted: {} bytes>", self.shard_data.len()),
            )
            .field("party_index", &self.party_index)
            .field("threshold", &self.threshold)
            .field("total_parties", &self.total_parties)
            .finish()
    }
}

/// Result of a completed signing session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SigningResult {
    /// The final ECDSA/EdDSA signature
    pub signature: Vec<u8>,
    /// r component (for ECDSA)
    pub r: Vec<u8>,
    /// s component (for ECDSA)
    pub s: Vec<u8>,
    /// Recovery id (for EVM transaction signing)
    pub recovery_id: Option<u8>,
}

/// Tracks the state of a participant in a DKG or signing session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ParticipantState {
    /// Waiting to start
    Idle,
    /// Currently participating in rounds
    Active,
    /// Completed their part successfully
    Completed,
    /// Failed or timed out
    Failed,
}
