//! Session coordinator — manages the lifecycle of DKG and signing sessions.
//!
//! Dispatches based on CurveType:
//! - **Secp256k1**: Uses CGGMP21 threshold ECDSA (ecdsa.rs)
//!   Falls back to Feldman VSS Schnorr if `use_ecdsa` is false
//! - **Ed25519**: Uses IETF FROST (frost.rs)

use super::ecdsa::{EcdsaDkgSession, EcdsaSigningSession};
use super::frost::{FrostDkgSession, FrostSigningSession};
use super::keygen::KeygenSession;
use super::signing::SigningSession;
use super::types::{KeygenResult, MpcMessage, SigningResult};
use super::{CurveType, HorcruxConfig, MpcError};
use std::collections::HashMap;
use std::time::Instant;

/// Abstracts over different DKG session types.
#[allow(clippy::large_enum_variant)]
enum DkgSessionKind {
    Schnorr(KeygenSession),
    Frost(FrostDkgSession),
    Ecdsa(EcdsaDkgSession),
}

/// Abstracts over different signing session types.
#[allow(clippy::large_enum_variant)]
enum SignSessionKind {
    Schnorr(SigningSession),
    Frost(FrostSigningSession),
    Ecdsa(EcdsaSigningSession),
}

/// Manages multiple concurrent MPC sessions.
pub struct SessionManager {
    keygen_sessions: HashMap<String, (DkgSessionKind, Instant)>,
    signing_sessions: HashMap<String, (SignSessionKind, Instant)>,
    /// When true, Secp256k1 uses CGGMP21 ECDSA. When false, uses legacy Schnorr.
    pub use_ecdsa: bool,
    /// Session TTL — sessions older than this are evicted by `cleanup_expired()`.
    pub session_ttl_secs: u64,
}

impl Default for SessionManager {
    fn default() -> Self {
        Self {
            keygen_sessions: HashMap::new(),
            signing_sessions: HashMap::new(),
            use_ecdsa: true,
            session_ttl_secs: 600, // 10 minutes
        }
    }
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
        let (kind, msgs) = match config.curve {
            CurveType::Ed25519 => {
                let mut session = FrostDkgSession::new(config)?;
                let msgs = session.start(&session_id)?;
                (DkgSessionKind::Frost(session), msgs)
            }
            CurveType::Secp256k1 if self.use_ecdsa => {
                let mut session = EcdsaDkgSession::new(config)?;
                let msgs = session.start(&session_id)?;
                (DkgSessionKind::Ecdsa(session), msgs)
            }
            CurveType::Secp256k1 => {
                let mut session = KeygenSession::new(config);
                let msgs = session.start(&session_id)?;
                (DkgSessionKind::Schnorr(session), msgs)
            }
        };
        self.keygen_sessions
            .insert(session_id, (kind, Instant::now()));
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
        let (kind, msgs) = match config.curve {
            CurveType::Ed25519 => {
                let mut session =
                    FrostSigningSession::new(config, message_hash, shard_data, participants)?;
                let msgs = session.start(&session_id)?;
                (SignSessionKind::Frost(session), msgs)
            }
            CurveType::Secp256k1 if self.use_ecdsa => {
                let mut session =
                    EcdsaSigningSession::new(config, message_hash, shard_data, participants)?;
                let msgs = session.start(&session_id)?;
                (SignSessionKind::Ecdsa(session), msgs)
            }
            CurveType::Secp256k1 => {
                let mut session =
                    SigningSession::new(config, message_hash, shard_data, participants)?;
                let msgs = session.start(&session_id)?;
                (SignSessionKind::Schnorr(session), msgs)
            }
        };
        self.signing_sessions
            .insert(session_id, (kind, Instant::now()));
        Ok(msgs)
    }

    /// Route an incoming message to the correct session.
    pub fn handle_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        if let Some((session, ts)) = self.keygen_sessions.get_mut(&msg.session_id) {
            *ts = Instant::now();
            return match session {
                DkgSessionKind::Schnorr(s) => s.process_message(msg),
                DkgSessionKind::Frost(s) => s.process_message(msg),
                DkgSessionKind::Ecdsa(s) => s.process_message(msg),
            };
        }
        if let Some((session, ts)) = self.signing_sessions.get_mut(&msg.session_id) {
            *ts = Instant::now();
            return match session {
                SignSessionKind::Schnorr(s) => s.process_message(msg),
                SignSessionKind::Frost(s) => s.process_message(msg),
                SignSessionKind::Ecdsa(s) => s.process_message(msg),
            };
        }
        Err(MpcError::SessionError(format!(
            "unknown session: {}",
            msg.session_id
        )))
    }

    /// Get keygen result if the session is complete.
    pub fn keygen_result(&self, session_id: &str) -> Option<KeygenResult> {
        self.keygen_sessions
            .get(session_id)
            .and_then(|(s, _)| match s {
                DkgSessionKind::Schnorr(s) => s.result(),
                DkgSessionKind::Frost(s) => s.result(),
                DkgSessionKind::Ecdsa(s) => s.result(),
            })
    }

    /// Get signing result if the session is complete.
    pub fn signing_result(&self, session_id: &str) -> Option<SigningResult> {
        self.signing_sessions
            .get(session_id)
            .and_then(|(s, _)| match s {
                SignSessionKind::Schnorr(s) => s.result(),
                SignSessionKind::Frost(s) => s.result(),
                SignSessionKind::Ecdsa(s) => s.result(),
            })
    }

    /// Remove a completed session.
    pub fn remove_session(&mut self, session_id: &str) {
        self.keygen_sessions.remove(session_id);
        self.signing_sessions.remove(session_id);
    }

    /// Evict sessions that have been idle longer than `session_ttl_secs`.
    /// Returns the number of sessions evicted.
    pub fn cleanup_expired(&mut self) -> usize {
        let ttl = std::time::Duration::from_secs(self.session_ttl_secs);
        let now = Instant::now();
        let before = self.keygen_sessions.len() + self.signing_sessions.len();
        self.keygen_sessions
            .retain(|_, (_, ts)| now.duration_since(*ts) < ttl);
        self.signing_sessions
            .retain(|_, (_, ts)| now.duration_since(*ts) < ttl);
        let after = self.keygen_sessions.len() + self.signing_sessions.len();
        before - after
    }

    /// Number of active sessions (keygen + signing).
    pub fn session_count(&self) -> usize {
        self.keygen_sessions.len() + self.signing_sessions.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mpc::HorcruxConfig;

    fn make_config(curve: CurveType) -> HorcruxConfig {
        HorcruxConfig {
            threshold: 2,
            total_parties: 3,
            party_index: 1,
            curve,
        }
    }

    #[test]
    fn test_session_count() {
        let mut mgr = SessionManager::new();
        assert_eq!(mgr.session_count(), 0);

        let cfg = make_config(CurveType::Ed25519);
        let _ = mgr.create_keygen("k1".into(), cfg);
        assert_eq!(mgr.session_count(), 1);

        mgr.remove_session("k1");
        assert_eq!(mgr.session_count(), 0);
    }

    #[test]
    fn test_cleanup_expired() {
        let mut mgr = SessionManager::new();
        mgr.session_ttl_secs = 0; // expire immediately

        let cfg = make_config(CurveType::Ed25519);
        let _ = mgr.create_keygen("k1".into(), cfg);
        assert_eq!(mgr.session_count(), 1);

        std::thread::sleep(std::time::Duration::from_millis(10));
        let evicted = mgr.cleanup_expired();
        assert_eq!(evicted, 1);
        assert_eq!(mgr.session_count(), 0);
    }

    #[test]
    fn test_cleanup_preserves_fresh_sessions() {
        let mut mgr = SessionManager::new();
        mgr.session_ttl_secs = 3600; // 1 hour

        let cfg = make_config(CurveType::Ed25519);
        let _ = mgr.create_keygen("k1".into(), cfg);

        let evicted = mgr.cleanup_expired();
        assert_eq!(evicted, 0);
        assert_eq!(mgr.session_count(), 1);
    }

    #[test]
    fn test_unknown_session_returns_error() {
        let mut mgr = SessionManager::new();
        let msg = crate::mpc::types::MpcMessage {
            session_id: "nonexistent".into(),
            from: 1,
            to: 2,
            round: 1,
            payload: vec![],
        };
        assert!(mgr.handle_message(msg).is_err());
    }
}
