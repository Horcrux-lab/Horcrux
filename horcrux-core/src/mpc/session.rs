//! Session coordinator — manages the lifecycle of DKG and signing sessions.
//!
//! Dispatches based on CurveType:
//! - **Secp256k1**: Uses CGGMP21 threshold ECDSA (ecdsa.rs)
//!   Falls back to Feldman VSS Schnorr if `use_ecdsa` is false
//!   Supports presign + 1-round signing for low latency
//! - **Ed25519**: Uses IETF FROST (frost.rs)

use super::{CurveType, HorcruxConfig, MpcError};
use super::keygen::KeygenSession;
use super::signing::SigningSession;
use super::frost::{FrostDkgSession, FrostSigningSession};
use super::ecdsa::{EcdsaDkgSession, EcdsaSigningSession, EcdsaPresignSession, EcdsaPresignedSigningSession};
use super::types::{KeygenResult, MpcMessage, SigningResult};
use generic_ec::{NonZero, Point};
use cggmp21::supported_curves::Secp256k1;
use std::collections::HashMap;

/// Abstracts over different DKG session types.
enum DkgSessionKind {
    Schnorr(KeygenSession),
    Frost(FrostDkgSession),
    Ecdsa(EcdsaDkgSession),
}

/// Abstracts over different signing session types.
enum SignSessionKind {
    Schnorr(SigningSession),
    Frost(FrostSigningSession),
    Ecdsa(EcdsaSigningSession),
    EcdsaPresign(EcdsaPresignSession),
    EcdsaPresigned(EcdsaPresignedSigningSession),
}

/// Manages multiple concurrent MPC sessions.
pub struct SessionManager {
    keygen_sessions: HashMap<String, DkgSessionKind>,
    signing_sessions: HashMap<String, SignSessionKind>,
    /// When true, Secp256k1 uses CGGMP21 ECDSA. When false, uses legacy Schnorr.
    pub use_ecdsa: bool,
}

impl Default for SessionManager {
    fn default() -> Self {
        Self {
            keygen_sessions: HashMap::new(),
            signing_sessions: HashMap::new(),
            use_ecdsa: true,
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
        self.keygen_sessions.insert(session_id, kind);
        Ok(msgs)
    }

    /// Create and start a new signing session (full 4-round).
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
                let mut session = FrostSigningSession::new(
                    config, message_hash, shard_data, participants,
                )?;
                let msgs = session.start(&session_id)?;
                (SignSessionKind::Frost(session), msgs)
            }
            CurveType::Secp256k1 if self.use_ecdsa => {
                let mut session = EcdsaSigningSession::new(
                    config, message_hash, shard_data, participants,
                )?;
                let msgs = session.start(&session_id)?;
                (SignSessionKind::Ecdsa(session), msgs)
            }
            CurveType::Secp256k1 => {
                let mut session = SigningSession::new(
                    config, message_hash, shard_data, participants,
                )?;
                let msgs = session.start(&session_id)?;
                (SignSessionKind::Schnorr(session), msgs)
            }
        };
        self.signing_sessions.insert(session_id, kind);
        Ok(msgs)
    }

    /// Create and start a presignature generation session (offline, 3-round MPC).
    ///
    /// After completion, retrieve the presignature with `presignature_bytes()`
    /// and cache it for later 1-round signing via `create_presigned_signing()`.
    pub fn create_presign(
        &mut self,
        session_id: String,
        config: HorcruxConfig,
        shard_data: Vec<u8>,
        participants: Vec<u16>,
    ) -> Result<Vec<MpcMessage>, MpcError> {
        let mut session = EcdsaPresignSession::new(config, shard_data, participants)?;
        let msgs = session.start(&session_id)?;
        self.signing_sessions
            .insert(session_id, SignSessionKind::EcdsaPresign(session));
        Ok(msgs)
    }

    /// Create and start a presigned signing session (online, 1 broadcast round).
    ///
    /// Uses a cached presignature from a prior `create_presign()` session.
    /// ⚠️ Never reuse presignatures!
    pub fn create_presigned_signing(
        &mut self,
        session_id: String,
        config: HorcruxConfig,
        message_hash: Vec<u8>,
        presignature_bytes: &[u8],
        group_public_key: NonZero<Point<Secp256k1>>,
    ) -> Result<Vec<MpcMessage>, MpcError> {
        let mut session = EcdsaPresignedSigningSession::new(
            config,
            message_hash,
            presignature_bytes,
            group_public_key,
        )?;
        let msgs = session.start(&session_id)?;
        self.signing_sessions
            .insert(session_id, SignSessionKind::EcdsaPresigned(session));
        Ok(msgs)
    }

    /// Route an incoming message to the correct session.
    pub fn handle_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        if let Some(session) = self.keygen_sessions.get_mut(&msg.session_id) {
            return match session {
                DkgSessionKind::Schnorr(s) => s.process_message(msg),
                DkgSessionKind::Frost(s) => s.process_message(msg),
                DkgSessionKind::Ecdsa(s) => s.process_message(msg),
            };
        }
        if let Some(session) = self.signing_sessions.get_mut(&msg.session_id) {
            return match session {
                SignSessionKind::Schnorr(s) => s.process_message(msg),
                SignSessionKind::Frost(s) => s.process_message(msg),
                SignSessionKind::Ecdsa(s) => s.process_message(msg),
                SignSessionKind::EcdsaPresign(s) => s.process_message(msg),
                SignSessionKind::EcdsaPresigned(s) => s.process_message(msg),
            };
        }
        Err(MpcError::SessionError(format!(
            "unknown session: {}", msg.session_id
        )))
    }

    /// Get keygen result if the session is complete.
    pub fn keygen_result(&self, session_id: &str) -> Option<KeygenResult> {
        self.keygen_sessions.get(session_id).and_then(|s| match s {
            DkgSessionKind::Schnorr(s) => s.result(),
            DkgSessionKind::Frost(s) => s.result(),
            DkgSessionKind::Ecdsa(s) => s.result(),
        })
    }

    /// Get signing result if the session is complete.
    pub fn signing_result(&self, session_id: &str) -> Option<SigningResult> {
        self.signing_sessions.get(session_id).and_then(|s| match s {
            SignSessionKind::Schnorr(s) => s.result(),
            SignSessionKind::Frost(s) => s.result(),
            SignSessionKind::Ecdsa(s) => s.result(),
            SignSessionKind::EcdsaPresign(_) => None, // presign doesn't produce SigningResult
            SignSessionKind::EcdsaPresigned(s) => s.result(),
        })
    }

    /// Get presignature bytes if presign session is complete.
    pub fn presignature_bytes(&self, session_id: &str) -> Option<Vec<u8>> {
        self.signing_sessions.get(session_id).and_then(|s| match s {
            SignSessionKind::EcdsaPresign(s) => s.presignature_bytes().map(|b| b.to_vec()),
            _ => None,
        })
    }

    /// Get group public key from a presign session.
    pub fn presign_public_key(&self, session_id: &str) -> Option<NonZero<Point<Secp256k1>>> {
        self.signing_sessions.get(session_id).and_then(|s| match s {
            SignSessionKind::EcdsaPresign(s) => Some(*s.group_public_key()),
            _ => None,
        })
    }

    /// Remove a completed session.
    pub fn remove_session(&mut self, session_id: &str) {
        self.keygen_sessions.remove(session_id);
        self.signing_sessions.remove(session_id);
    }
}
