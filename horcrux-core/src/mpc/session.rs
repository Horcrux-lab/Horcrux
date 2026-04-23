//! Session coordinator — manages the lifecycle of DKG and signing sessions.
//!
//! Dispatches based on CurveType:
//! - **Secp256k1**: Uses CGGMP21 threshold ECDSA (ecdsa.rs)
//!   Falls back to Feldman VSS Schnorr if `use_ecdsa` is false
//! - **Ed25519**: Uses IETF FROST (frost.rs)

use super::ecdsa::{EcdsaDkgSession, EcdsaSigningSession};
use super::frost::{FrostDkgSession, FrostSigningSession};
use super::keygen::KeygenSession;
use super::refresh::EcdsaRefreshSession;
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
    EcdsaRefresh(EcdsaRefreshSession),
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

    /// Create and start a new key refresh session (proactive share rotation).
    /// Only supported for Secp256k1 / CGGMP21 (n-of-n only); requires the
    /// existing shard for this party.
    pub fn create_refresh(
        &mut self,
        session_id: String,
        config: HorcruxConfig,
        shard_data: Vec<u8>,
    ) -> Result<Vec<MpcMessage>, MpcError> {
        if !matches!(config.curve, CurveType::Secp256k1) || !self.use_ecdsa {
            return Err(MpcError::InvalidConfig(
                "refresh only supported for CGGMP21 ECDSA (Secp256k1)".into(),
            ));
        }
        if config.threshold != config.total_parties {
            return Err(MpcError::InvalidConfig(
                "refresh currently only supported for n-of-n shares".into(),
            ));
        }
        let mut session = EcdsaRefreshSession::new(config, shard_data)?;
        let msgs = session.start(&session_id)?;
        self.keygen_sessions.insert(
            session_id,
            (DkgSessionKind::EcdsaRefresh(session), Instant::now()),
        );
        Ok(msgs)
    }

    /// Route an incoming message to the correct session.
    ///
    /// **DEPRECATED FOR PRODUCTION USE** — prefer
    /// [`handle_authenticated_message`] which binds the claimed `msg.from`
    /// party index to the transport-authenticated peer identity.
    ///
    /// This variant does **not** verify the sender and is only safe for
    /// local-process tests where every party is trusted.
    #[doc(hidden)]
    pub fn handle_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        self.dispatch_message(msg)
    }

    /// Route an incoming message to the correct session, verifying that
    /// the claimed sender (`msg.from`) matches the party index that the
    /// transport layer authenticated via Noise (or equivalent E2E channel).
    ///
    /// **Callers must pass `authenticated_from` derived from the Noise
    /// peer identity that actually decrypted the bytes**, not from the
    /// message payload itself — passing `msg.from` here defeats the check.
    ///
    /// Rejects the message with `ProtocolError` if the claimed sender
    /// does not match, preventing a malicious party `i` from impersonating
    /// another party `j` within the same ceremony (the "rogue party
    /// identity" attack — audit finding C1).
    pub fn handle_authenticated_message(
        &mut self,
        msg: MpcMessage,
        authenticated_from: u16,
    ) -> Result<Vec<MpcMessage>, MpcError> {
        if msg.from != authenticated_from {
            return Err(MpcError::ProtocolError(format!(
                "sender identity mismatch: message claims from={}, authenticated peer is {}",
                msg.from, authenticated_from
            )));
        }
        self.dispatch_message(msg)
    }

    fn dispatch_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        if let Some((session, ts)) = self.keygen_sessions.get_mut(&msg.session_id) {
            *ts = Instant::now();
            return match session {
                DkgSessionKind::Schnorr(s) => s.process_message(msg),
                DkgSessionKind::Frost(s) => s.process_message(msg),
                DkgSessionKind::Ecdsa(s) => s.process_message(msg),
                DkgSessionKind::EcdsaRefresh(s) => s.process_message(msg),
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
                DkgSessionKind::EcdsaRefresh(s) => s.result(),
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

    #[test]
    fn test_authenticated_message_rejects_impersonation() {
        // Audit finding C1: a party that holds index 3 must not be able
        // to inject messages claiming from=2. The unauthenticated entry
        // point would accept this; the authenticated one must reject.
        let mut mgr = SessionManager::new();
        let cfg = make_config(CurveType::Ed25519);
        let _ = mgr.create_keygen("k1".into(), cfg);

        let impersonation = crate::mpc::types::MpcMessage {
            session_id: "k1".into(),
            from: 2, // claimed
            to: 1,
            round: 1,
            payload: vec![0; 32],
        };

        // Authenticated peer is actually party 3, not 2 — must reject.
        let err = mgr
            .handle_authenticated_message(impersonation.clone(), 3)
            .unwrap_err();
        match err {
            crate::mpc::MpcError::ProtocolError(s) => {
                assert!(s.contains("sender identity mismatch"), "msg was: {}", s);
            }
            e => panic!("expected ProtocolError, got {:?}", e),
        }

        // Sanity: when claimed and authenticated match, the call is
        // dispatched (though the payload is invalid so dispatch fails).
        let matched = mgr.handle_authenticated_message(impersonation, 2);
        // We only care that it did NOT fail with the identity-mismatch
        // message; any protocol/decode failure is acceptable here.
        if let Err(crate::mpc::MpcError::ProtocolError(s)) = &matched {
            assert!(
                !s.contains("sender identity mismatch"),
                "should dispatch when from matches: {}",
                s
            );
        }
    }
}

/// Property-based robustness tests for the session router.
///
/// `dispatch_message` is the first entry point peer bytes hit after the
/// Noise E2E channel decrypts them. Even before per-protocol payload
/// parsers run, an attacker can ship wildly malformed `MpcMessage`
/// envelopes (unknown `session_id`, spoofed `from`, absurd `round`
/// numbers, empty / giant payloads). The router must degrade gracefully
/// — unknown sessions return `SessionError`, identity mismatches return
/// `ProtocolError`, everything else falls through to the protocol
/// layer which has its own panic-free proptests (`mpc::prop_tests`).
///
/// Round 19 hardening.
#[cfg(test)]
mod prop_tests {
    use super::{MpcMessage, SessionManager};
    use crate::mpc::MpcError;
    use proptest::prelude::*;

    fn arb_message() -> impl Strategy<Value = MpcMessage> {
        (
            any::<u16>(),
            any::<u16>(),
            any::<u32>(),
            "[a-zA-Z0-9_-]{0,40}",
            proptest::collection::vec(any::<u8>(), 0..2048),
        )
            .prop_map(|(from, to, round, session_id, payload)| MpcMessage {
                from,
                to,
                round,
                session_id,
                payload,
            })
    }

    proptest! {
        #![proptest_config(ProptestConfig { cases: 256, .. ProptestConfig::default() })]

        /// With no sessions registered, every message the router sees
        /// must surface as `SessionError("unknown session: ...")` — never
        /// a panic, never a stray `Ok`.
        #[test]
        fn prop_unknown_session_is_routing_error(msg in arb_message()) {
            let mut mgr = SessionManager::new();
            let expected_id = msg.session_id.clone();
            match mgr.handle_message(msg) {
                Err(MpcError::SessionError(s)) => {
                    prop_assert!(
                        s.contains(&expected_id) || expected_id.is_empty(),
                        "error should mention the unknown session id, got: {}",
                        s
                    );
                }
                other => prop_assert!(false, "expected SessionError, got {:?}", other),
            }
        }

        /// `handle_authenticated_message` rejects identity spoofing
        /// before any routing happens. When the claimed `msg.from`
        /// disagrees with the Noise-authenticated peer identity, we
        /// must see `ProtocolError("sender identity mismatch: ...")`
        /// no matter what payload the attacker chose.
        #[test]
        fn prop_identity_mismatch_rejected(
            msg in arb_message(),
            auth_delta in 1u16..=256u16,
        ) {
            let mut mgr = SessionManager::new();
            let authenticated_from = msg.from.wrapping_add(auth_delta);
            match mgr.handle_authenticated_message(msg, authenticated_from) {
                Err(MpcError::ProtocolError(s)) => {
                    prop_assert!(
                        s.contains("sender identity mismatch"),
                        "expected identity-mismatch error, got: {}",
                        s
                    );
                }
                other => prop_assert!(false, "expected ProtocolError, got {:?}", other),
            }
        }

        /// `MpcMessage` must survive a serde round-trip for any
        /// well-formed value. This is the wire format the iOS host
        /// builds before Noise encryption and the receiver reads after
        /// Noise decryption — a serde asymmetry would brick cross-
        /// device signing in a way unit tests would miss.
        #[test]
        fn prop_mpc_message_roundtrip(msg in arb_message()) {
            let bytes = serde_json::to_vec(&msg).expect("serialize");
            let back: MpcMessage = serde_json::from_slice(&bytes).expect("deserialize");
            prop_assert_eq!(back.from, msg.from);
            prop_assert_eq!(back.to, msg.to);
            prop_assert_eq!(back.round, msg.round);
            prop_assert_eq!(&back.session_id, &msg.session_id);
            prop_assert_eq!(&back.payload, &msg.payload);
        }
    }
}
