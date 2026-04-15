use serde::{Deserialize, Serialize};

/// A round message exchanged during MPC protocols (DKG or signing).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MpcMessage {
    /// Sender party index
    pub from: u16,
    /// Recipient party index (0 = broadcast)
    pub to: u16,
    /// Protocol round number
    pub round: u32,
    /// Session identifier
    pub session_id: String,
    /// Serialized protocol payload
    pub payload: Vec<u8>,
}

/// Result of a completed DKG — the public key and this party's shard.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeygenResult {
    /// The aggregated public key (shared across all parties)
    pub public_key: Vec<u8>,
    /// This party's secret shard (encrypted before storage)
    pub shard_data: Vec<u8>,
    /// Party index
    pub party_index: u16,
    /// Threshold configuration
    pub threshold: u16,
    /// Total parties
    pub total_parties: u16,
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
