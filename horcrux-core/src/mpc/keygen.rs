//! Distributed Key Generation (DKG) for CGGMP21 (ECDSA) and FROST (EdDSA).
//!
//! This module implements the key generation ceremony where t-of-n parties
//! collaboratively generate a shared public key, with each party receiving
//! only their secret shard — the full private key never exists.

use super::{CurveType, HorcruxConfig, MpcError};
use super::types::{KeygenResult, MpcMessage};

/// State machine for the DKG protocol.
#[derive(Debug)]
pub struct KeygenSession {
    config: HorcruxConfig,
    state: KeygenState,
    inbound: Vec<MpcMessage>,
    outbound: Vec<MpcMessage>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum KeygenState {
    /// Waiting for all parties to join
    WaitingForParties,
    /// Round 1: commitment exchange
    Round1,
    /// Round 2: share distribution
    Round2,
    /// Round 3: verification
    Round3,
    /// DKG complete
    Complete,
    /// DKG failed
    Failed,
}

impl KeygenSession {
    /// Create a new DKG session.
    pub fn new(config: HorcruxConfig) -> Self {
        Self {
            config,
            state: KeygenState::WaitingForParties,
            inbound: Vec::new(),
            outbound: Vec::new(),
        }
    }

    /// Start the DKG protocol (generate round-1 messages).
    pub fn start(&mut self, session_id: &str) -> Result<Vec<MpcMessage>, MpcError> {
        if self.state != KeygenState::WaitingForParties {
            return Err(MpcError::SessionError("session already started".into()));
        }

        self.state = KeygenState::Round1;

        match self.config.curve {
            CurveType::Secp256k1 => self.start_cggmp_dkg(session_id),
            CurveType::Ed25519 => self.start_frost_dkg(session_id),
        }
    }

    /// Process an incoming message and return outgoing messages for the next round.
    pub fn process_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        self.inbound.push(msg);
        self.try_advance_round()
    }

    /// Check if the DKG is complete and return the result.
    pub fn result(&self) -> Option<KeygenResult> {
        if self.state != KeygenState::Complete {
            return None;
        }
        // TODO: return actual keygen result from protocol state
        Some(KeygenResult {
            public_key: vec![],
            shard_data: vec![],
            party_index: self.config.party_index,
            threshold: self.config.threshold,
            total_parties: self.config.total_parties,
        })
    }

    /// Current round state.
    pub fn current_state(&self) -> &str {
        match self.state {
            KeygenState::WaitingForParties => "waiting_for_parties",
            KeygenState::Round1 => "round_1",
            KeygenState::Round2 => "round_2",
            KeygenState::Round3 => "round_3",
            KeygenState::Complete => "complete",
            KeygenState::Failed => "failed",
        }
    }

    // --- CGGMP21 DKG (secp256k1 / ECDSA) ---

    fn start_cggmp_dkg(&mut self, session_id: &str) -> Result<Vec<MpcMessage>, MpcError> {
        tracing::info!(
            party = self.config.party_index,
            "starting CGGMP21 DKG round 1"
        );

        // TODO: Implement CGGMP21 DKG round 1
        // 1. Generate random commitment
        // 2. Create Schnorr proof of knowledge
        // 3. Broadcast commitment to all parties
        let msg = MpcMessage {
            from: self.config.party_index,
            to: 0, // broadcast
            round: 1,
            session_id: session_id.to_string(),
            payload: vec![], // TODO: actual commitment
        };

        Ok(vec![msg])
    }

    // --- FROST DKG (ed25519 / EdDSA) ---

    fn start_frost_dkg(&mut self, session_id: &str) -> Result<Vec<MpcMessage>, MpcError> {
        tracing::info!(
            party = self.config.party_index,
            "starting FROST DKG round 1"
        );

        // TODO: Implement FROST DKG round 1
        // 1. Generate polynomial commitments
        // 2. Create proof of knowledge for constant term
        // 3. Broadcast commitment package
        let msg = MpcMessage {
            from: self.config.party_index,
            to: 0,
            round: 1,
            session_id: session_id.to_string(),
            payload: vec![],
        };

        Ok(vec![msg])
    }

    fn try_advance_round(&mut self) -> Result<Vec<MpcMessage>, MpcError> {
        let expected_msgs = (self.config.total_parties - 1) as usize;
        let current_round = match self.state {
            KeygenState::Round1 => 1,
            KeygenState::Round2 => 2,
            KeygenState::Round3 => 3,
            _ => return Ok(vec![]),
        };

        let msgs_for_round: Vec<_> = self.inbound
            .iter()
            .filter(|m| m.round == current_round)
            .collect();

        if msgs_for_round.len() < expected_msgs {
            return Ok(vec![]);
        }

        // Advance to next round
        match self.state {
            KeygenState::Round1 => {
                self.state = KeygenState::Round2;
                // TODO: process round 1 messages and generate round 2
                Ok(vec![])
            }
            KeygenState::Round2 => {
                self.state = KeygenState::Round3;
                // TODO: process round 2 messages and generate round 3
                Ok(vec![])
            }
            KeygenState::Round3 => {
                self.state = KeygenState::Complete;
                // TODO: finalize keygen
                Ok(vec![])
            }
            _ => Ok(vec![]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_keygen_session_creation() {
        let config = HorcruxConfig::new(2, 3, 1, CurveType::Secp256k1).unwrap();
        let session = KeygenSession::new(config);
        assert_eq!(session.current_state(), "waiting_for_parties");
    }

    #[test]
    fn test_keygen_session_start() {
        let config = HorcruxConfig::new(2, 3, 1, CurveType::Secp256k1).unwrap();
        let mut session = KeygenSession::new(config);
        let msgs = session.start("test-session").unwrap();
        assert_eq!(session.current_state(), "round_1");
        assert!(!msgs.is_empty());
    }

    #[test]
    fn test_frost_keygen_session_start() {
        let config = HorcruxConfig::new(2, 3, 1, CurveType::Ed25519).unwrap();
        let mut session = KeygenSession::new(config);
        let msgs = session.start("test-session-frost").unwrap();
        assert_eq!(session.current_state(), "round_1");
        assert!(!msgs.is_empty());
    }
}
