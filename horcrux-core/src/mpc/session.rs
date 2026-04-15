//! Session coordinator — manages the lifecycle of DKG and signing sessions.

use super::{HorcruxConfig, MpcError};
use super::keygen::KeygenSession;
use super::signing::SigningSession;
use super::types::MpcMessage;
use std::collections::HashMap;

/// Manages multiple concurrent MPC sessions.
#[derive(Debug, Default)]
pub struct SessionManager {
    keygen_sessions: HashMap<String, KeygenSession>,
    signing_sessions: HashMap<String, SigningSession>,
}

impl SessionManager {
    pub fn new() -> Self {
        Self::default()
    }

    /// Create and start a new DKG session.
    pub fn create_keygen(
        &mut self,
        session_id: String,
        config: HorcruxConfig,
    ) -> Result<Vec<MpcMessage>, MpcError> {
        let mut session = KeygenSession::new(config);
        let msgs = session.start(&session_id)?;
        self.keygen_sessions.insert(session_id, session);
        Ok(msgs)
    }

    /// Create and start a new signing session.
    pub fn create_signing(
        &mut self,
        session_id: String,
        config: HorcruxConfig,
        message_hash: Vec<u8>,
        shard_data: Vec<u8>,
        participants: Vec<u16>,
    ) -> Result<Vec<MpcMessage>, MpcError> {
        let mut session = SigningSession::new(config, message_hash, shard_data, participants)?;
        let msgs = session.start(&session_id)?;
        self.signing_sessions.insert(session_id, session);
        Ok(msgs)
    }

    /// Route an incoming message to the correct session.
    pub fn handle_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        if let Some(session) = self.keygen_sessions.get_mut(&msg.session_id) {
            return session.process_message(msg);
        }
        if let Some(session) = self.signing_sessions.get_mut(&msg.session_id) {
            return session.process_message(msg);
        }
        Err(MpcError::SessionError(format!(
            "unknown session: {}", msg.session_id
        )))
    }

    /// Get keygen result if the session is complete.
    pub fn keygen_result(&self, session_id: &str) -> Option<super::types::KeygenResult> {
        self.keygen_sessions.get(session_id).and_then(|s| s.result())
    }

    /// Get signing result if the session is complete.
    pub fn signing_result(&self, session_id: &str) -> Option<super::types::SigningResult> {
        self.signing_sessions.get(session_id).and_then(|s| s.result())
    }

    /// Remove a completed session.
    pub fn remove_session(&mut self, session_id: &str) {
        self.keygen_sessions.remove(session_id);
        self.signing_sessions.remove(session_id);
    }
}
