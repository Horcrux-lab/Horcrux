//! Threshold signing sessions for CGGMP21 (ECDSA) and FROST (EdDSA).
//!
//! Signing requires t-of-n parties to cooperate. Each party contributes their
//! shard to the MPC protocol — the full private key is never reconstructed.

use super::{CurveType, HorcruxConfig, MpcError};
use super::types::{MpcMessage, SigningResult};

/// State machine for a threshold signing session.
#[derive(Debug)]
pub struct SigningSession {
    config: HorcruxConfig,
    state: SigningState,
    /// The message hash to sign
    message_hash: Vec<u8>,
    /// This party's shard data
    shard_data: Vec<u8>,
    inbound: Vec<MpcMessage>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SigningState {
    /// Waiting for parties to join the signing session
    WaitingForParties,
    /// Pre-signing round (offline phase)
    PreSign,
    /// Signing round (online phase)
    Sign,
    /// Signing complete
    Complete,
    /// Signing failed
    Failed,
}

impl SigningSession {
    /// Create a new signing session.
    pub fn new(config: HorcruxConfig, message_hash: Vec<u8>, shard_data: Vec<u8>) -> Self {
        Self {
            config,
            state: SigningState::WaitingForParties,
            message_hash,
            shard_data,
            inbound: Vec::new(),
        }
    }

    /// Start the signing protocol.
    pub fn start(&mut self, session_id: &str) -> Result<Vec<MpcMessage>, MpcError> {
        if self.state != SigningState::WaitingForParties {
            return Err(MpcError::SessionError("signing session already started".into()));
        }

        self.state = SigningState::PreSign;

        match self.config.curve {
            CurveType::Secp256k1 => self.start_cggmp_signing(session_id),
            CurveType::Ed25519 => self.start_frost_signing(session_id),
        }
    }

    /// Process an incoming message.
    pub fn process_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        self.inbound.push(msg);
        self.try_advance()
    }

    /// Get the signing result if complete.
    pub fn result(&self) -> Option<SigningResult> {
        if self.state != SigningState::Complete {
            return None;
        }
        // TODO: return actual signature
        Some(SigningResult {
            signature: vec![],
            r: vec![],
            s: vec![],
            recovery_id: None,
        })
    }

    pub fn current_state(&self) -> &str {
        match self.state {
            SigningState::WaitingForParties => "waiting_for_parties",
            SigningState::PreSign => "pre_sign",
            SigningState::Sign => "sign",
            SigningState::Complete => "complete",
            SigningState::Failed => "failed",
        }
    }

    // --- CGGMP21 Signing (ECDSA) ---

    fn start_cggmp_signing(&mut self, session_id: &str) -> Result<Vec<MpcMessage>, MpcError> {
        tracing::info!(
            party = self.config.party_index,
            "starting CGGMP21 pre-signing"
        );

        // TODO: Implement CGGMP21 pre-signing
        // 1. Generate nonce commitment
        // 2. MtA (Multiplicative-to-Additive) share conversion
        // 3. Broadcast commitment
        let msg = MpcMessage {
            from: self.config.party_index,
            to: 0,
            round: 1,
            session_id: session_id.to_string(),
            payload: vec![],
        };

        Ok(vec![msg])
    }

    // --- FROST Signing (EdDSA) ---

    fn start_frost_signing(&mut self, session_id: &str) -> Result<Vec<MpcMessage>, MpcError> {
        tracing::info!(
            party = self.config.party_index,
            "starting FROST signing"
        );

        // TODO: Implement FROST signing
        // 1. Generate nonce pair (hiding + binding)
        // 2. Broadcast nonce commitment
        let msg = MpcMessage {
            from: self.config.party_index,
            to: 0,
            round: 1,
            session_id: session_id.to_string(),
            payload: vec![],
        };

        Ok(vec![msg])
    }

    fn try_advance(&mut self) -> Result<Vec<MpcMessage>, MpcError> {
        // TODO: advance state machine based on received messages
        Ok(vec![])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_signing_session_creation() {
        let config = HorcruxConfig::new(2, 3, 1, CurveType::Secp256k1).unwrap();
        let session = SigningSession::new(config, vec![0u8; 32], vec![1, 2, 3]);
        assert_eq!(session.current_state(), "waiting_for_parties");
    }

    #[test]
    fn test_signing_session_start() {
        let config = HorcruxConfig::new(2, 3, 1, CurveType::Secp256k1).unwrap();
        let mut session = SigningSession::new(config, vec![0u8; 32], vec![1, 2, 3]);
        let msgs = session.start("test-sign").unwrap();
        assert_eq!(session.current_state(), "pre_sign");
        assert!(!msgs.is_empty());
    }
}
