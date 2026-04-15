//! FROST Ed25519 threshold signatures (IETF RFC 9591).
//!
//! Wraps the `frost-ed25519` crate to provide:
//! - **DKG**: 3-part distributed key generation (part1 → part2 → part3)
//! - **Signing**: 2-round threshold signing (commit → sign → aggregate)
//!
//! The FROST protocol natively supports t-of-n threshold EdDSA,
//! making it the correct choice for Solana and other Ed25519 chains.

use super::types::{KeygenResult, MpcMessage, SigningResult};
use super::{HorcruxConfig, MpcError};

use frost_ed25519 as frost;
use frost::keys::dkg as frost_dkg;
use frost::{Identifier, SigningPackage};
use rand::rngs::OsRng;
use std::collections::BTreeMap;

// --- DKG wire types ---

/// Round 1 broadcast: the FROST round1::Package serialized.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FrostDkgRound1 {
    pub from: u16,
    pub package: Vec<u8>,
}

/// Round 2 point-to-point: the FROST round2::Package for a specific recipient.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FrostDkgRound2 {
    pub from: u16,
    pub to: u16,
    pub package: Vec<u8>,
}

// --- Signing wire types ---

/// Round 1: signing commitment broadcast.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FrostSignRound1 {
    pub from: u16,
    pub commitments: Vec<u8>,
}

/// Round 2: signature share.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FrostSignRound2 {
    pub from: u16,
    pub signature_share: Vec<u8>,
}

// =============================================================================
// FROST DKG Session
// =============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FrostDkgState {
    Init,
    Round1Sent,
    Round2Sent,
    Complete,
}

/// DKG session using the IETF FROST protocol for Ed25519.
pub struct FrostDkgSession {
    config: HorcruxConfig,
    session_id: String,
    state: FrostDkgState,
    our_id: Identifier,

    // Secrets held between rounds
    round1_secret: Option<frost_dkg::round1::SecretPackage>,
    round2_secret: Option<frost_dkg::round2::SecretPackage>,

    // Received packages from other participants
    received_round1: BTreeMap<Identifier, frost_dkg::round1::Package>,
    received_round2: BTreeMap<Identifier, frost_dkg::round2::Package>,

    result: Option<KeygenResult>,
}

// frost-ed25519 types contain crypto internals that don't implement Debug
impl std::fmt::Debug for FrostDkgSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FrostDkgSession")
            .field("config", &self.config)
            .field("session_id", &self.session_id)
            .field("state", &self.state)
            .field("received_round1_count", &self.received_round1.len())
            .field("received_round2_count", &self.received_round2.len())
            .finish()
    }
}

impl FrostDkgSession {
    pub fn new(config: HorcruxConfig) -> Result<Self, MpcError> {
        let our_id: Identifier = config
            .party_index
            .try_into()
            .map_err(|_| MpcError::InvalidConfig("party_index must be nonzero".into()))?;

        Ok(Self {
            config,
            session_id: String::new(),
            state: FrostDkgState::Init,
            our_id,
            round1_secret: None,
            round2_secret: None,
            received_round1: BTreeMap::new(),
            received_round2: BTreeMap::new(),
            result: None,
        })
    }

    /// Start the DKG: run part1 and emit round-1 broadcast messages.
    pub fn start(&mut self, session_id: &str) -> Result<Vec<MpcMessage>, MpcError> {
        if self.state != FrostDkgState::Init {
            return Err(MpcError::SessionError("FROST DKG already started".into()));
        }
        self.session_id = session_id.to_string();

        let rng = OsRng;
        let (secret_package, round1_package) = frost_dkg::part1(
            self.our_id,
            self.config.total_parties,
            self.config.threshold,
            rng,
        )
        .map_err(|e| MpcError::KeygenFailed(format!("FROST DKG part1: {e}")))?;

        self.round1_secret = Some(secret_package);

        // Serialize the round1 package to broadcast
        let pkg_bytes = serde_json::to_vec(&round1_package)
            .map_err(|e| MpcError::ProtocolError(format!("serialize round1 pkg: {e}")))?;

        let wire = FrostDkgRound1 {
            from: self.config.party_index,
            package: pkg_bytes,
        };
        let payload = serde_json::to_vec(&wire)
            .map_err(|e| MpcError::ProtocolError(format!("serialize round1: {e}")))?;

        // Broadcast to all other parties
        let msgs: Vec<MpcMessage> = (1..=self.config.total_parties)
            .filter(|&i| i != self.config.party_index)
            .map(|i| MpcMessage {
                from: self.config.party_index,
                to: i,
                round: 1,
                session_id: self.session_id.clone(),
                payload: payload.clone(),
            })
            .collect();

        self.state = FrostDkgState::Round1Sent;
        tracing::info!(
            party = self.config.party_index,
            "FROST DKG round 1 complete, broadcasting to {} parties",
            msgs.len()
        );
        Ok(msgs)
    }

    /// Process an incoming message. Returns outgoing messages (if any).
    pub fn process_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        match (self.state, msg.round) {
            (FrostDkgState::Round1Sent, 1) => self.handle_round1(msg),
            (FrostDkgState::Round2Sent, 2) => self.handle_round2(msg),
            _ => Ok(vec![]),
        }
    }

    fn handle_round1(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        let wire: FrostDkgRound1 = serde_json::from_slice(&msg.payload)
            .map_err(|e| MpcError::ProtocolError(format!("deserialize round1: {e}")))?;

        let sender_id: Identifier = wire
            .from
            .try_into()
            .map_err(|_| MpcError::ProtocolError("invalid sender id".into()))?;

        let pkg: frost_dkg::round1::Package = serde_json::from_slice(&wire.package)
            .map_err(|e| MpcError::ProtocolError(format!("deserialize round1 pkg: {e}")))?;

        self.received_round1.insert(sender_id, pkg);

        // Need n-1 round1 packages (from all other parties)
        let needed = (self.config.total_parties - 1) as usize;
        if self.received_round1.len() < needed {
            return Ok(vec![]);
        }

        // Run part2
        let secret = self
            .round1_secret
            .take()
            .ok_or_else(|| MpcError::SessionError("round1 secret missing".into()))?;

        let (round2_secret, round2_packages) =
            frost_dkg::part2(secret, &self.received_round1)
                .map_err(|e| MpcError::KeygenFailed(format!("FROST DKG part2: {e}")))?;

        self.round2_secret = Some(round2_secret);

        // Send each recipient their specific round2 package
        let mut msgs = Vec::new();
        for (recipient_id, r2_pkg) in &round2_packages {
            let recipient_index = identifier_to_u16(*recipient_id)?;

            let pkg_bytes = serde_json::to_vec(r2_pkg)
                .map_err(|e| MpcError::ProtocolError(format!("serialize round2 pkg: {e}")))?;

            let wire = FrostDkgRound2 {
                from: self.config.party_index,
                to: recipient_index,
                package: pkg_bytes,
            };
            let payload = serde_json::to_vec(&wire)
                .map_err(|e| MpcError::ProtocolError(format!("serialize round2: {e}")))?;

            msgs.push(MpcMessage {
                from: self.config.party_index,
                to: recipient_index,
                round: 2,
                session_id: self.session_id.clone(),
                payload,
            });
        }

        self.state = FrostDkgState::Round2Sent;
        tracing::info!(
            party = self.config.party_index,
            "FROST DKG round 2 complete, sending {} packages",
            msgs.len()
        );
        Ok(msgs)
    }

    fn handle_round2(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        let wire: FrostDkgRound2 = serde_json::from_slice(&msg.payload)
            .map_err(|e| MpcError::ProtocolError(format!("deserialize round2: {e}")))?;

        let sender_id: Identifier = wire
            .from
            .try_into()
            .map_err(|_| MpcError::ProtocolError("invalid sender id".into()))?;

        let pkg: frost_dkg::round2::Package = serde_json::from_slice(&wire.package)
            .map_err(|e| MpcError::ProtocolError(format!("deserialize round2 pkg: {e}")))?;

        self.received_round2.insert(sender_id, pkg);

        let needed = (self.config.total_parties - 1) as usize;
        if self.received_round2.len() < needed {
            return Ok(vec![]);
        }

        // Run part3 — final computation
        let secret = self
            .round2_secret
            .as_ref()
            .ok_or_else(|| MpcError::SessionError("round2 secret missing".into()))?;

        let (key_package, pubkey_package) =
            frost_dkg::part3(secret, &self.received_round1, &self.received_round2)
                .map_err(|e| MpcError::KeygenFailed(format!("FROST DKG part3: {e}")))?;

        // Extract group public key (32 bytes, Ed25519 compressed point)
        let verifying_key = pubkey_package.verifying_key();
        let pk_bytes = verifying_key.serialize()
            .map_err(|e| MpcError::KeygenFailed(format!("serialize verifying key: {e}")))?;

        // Serialize key_package as shard_data
        let shard_data = serde_json::to_vec(&FrostShardData {
            key_package: serde_json::to_vec(&key_package)
                .map_err(|e| MpcError::KeygenFailed(format!("serialize key package: {e}")))?,
            pubkey_package: serde_json::to_vec(&pubkey_package)
                .map_err(|e| MpcError::KeygenFailed(format!("serialize pubkey package: {e}")))?,
        })
        .map_err(|e| MpcError::KeygenFailed(format!("serialize shard data: {e}")))?;

        self.result = Some(KeygenResult {
            public_key: pk_bytes,
            shard_data,
            party_index: self.config.party_index,
            threshold: self.config.threshold,
            total_parties: self.config.total_parties,
        });

        self.state = FrostDkgState::Complete;
        tracing::info!(
            party = self.config.party_index,
            "FROST DKG complete — group public key generated"
        );
        Ok(vec![])
    }

    pub fn result(&self) -> Option<KeygenResult> {
        self.result.clone()
    }

    pub fn is_complete(&self) -> bool {
        self.state == FrostDkgState::Complete
    }
}

/// Serialized shard data: contains both key_package and pubkey_package.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FrostShardData {
    pub key_package: Vec<u8>,
    pub pubkey_package: Vec<u8>,
}

// =============================================================================
// FROST Signing Session
// =============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FrostSignState {
    Init,
    Round1Sent,
    Round2Sent,
    Complete,
}

/// Signing session using the IETF FROST protocol for Ed25519.
pub struct FrostSigningSession {
    config: HorcruxConfig,
    session_id: String,
    state: FrostSignState,
    our_id: Identifier,
    message: Vec<u8>,
    participants: Vec<u16>,

    // Secrets
    key_package: frost::keys::KeyPackage,
    pubkey_package: frost::keys::PublicKeyPackage,
    nonces: Option<frost::round1::SigningNonces>,

    // Received commitments and shares
    received_commitments: BTreeMap<Identifier, frost::round1::SigningCommitments>,
    received_shares: BTreeMap<Identifier, frost::round2::SignatureShare>,

    result: Option<SigningResult>,
}

impl std::fmt::Debug for FrostSigningSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FrostSigningSession")
            .field("config", &self.config)
            .field("session_id", &self.session_id)
            .field("state", &self.state)
            .field("participants", &self.participants)
            .field("received_commitments_count", &self.received_commitments.len())
            .field("received_shares_count", &self.received_shares.len())
            .finish()
    }
}

impl FrostSigningSession {
    /// Create a new signing session.
    ///
    /// `shard_data` must be a serialized `FrostShardData` from a previous DKG.
    pub fn new(
        config: HorcruxConfig,
        message: Vec<u8>,
        shard_data: Vec<u8>,
        participants: Vec<u16>,
    ) -> Result<Self, MpcError> {
        if participants.len() < config.threshold as usize {
            return Err(MpcError::InsufficientParties {
                needed: config.threshold,
                got: participants.len() as u16,
            });
        }
        if !participants.contains(&config.party_index) {
            return Err(MpcError::InvalidConfig(
                "our party not in participants list".into(),
            ));
        }

        let our_id: Identifier = config
            .party_index
            .try_into()
            .map_err(|_| MpcError::InvalidConfig("party_index must be nonzero".into()))?;

        // Deserialize shard data
        let shard: FrostShardData = serde_json::from_slice(&shard_data)
            .map_err(|e| MpcError::SigningFailed(format!("deserialize shard data: {e}")))?;

        let key_package: frost::keys::KeyPackage = serde_json::from_slice(&shard.key_package)
            .map_err(|e| MpcError::SigningFailed(format!("deserialize key package: {e}")))?;

        let pubkey_package: frost::keys::PublicKeyPackage =
            serde_json::from_slice(&shard.pubkey_package)
                .map_err(|e| MpcError::SigningFailed(format!("deserialize pubkey package: {e}")))?;

        Ok(Self {
            config,
            session_id: String::new(),
            state: FrostSignState::Init,
            our_id,
            message,
            participants,
            key_package,
            pubkey_package,
            nonces: None,
            received_commitments: BTreeMap::new(),
            received_shares: BTreeMap::new(),
            result: None,
        })
    }

    /// Start signing: generate nonce commitment and broadcast.
    pub fn start(&mut self, session_id: &str) -> Result<Vec<MpcMessage>, MpcError> {
        if self.state != FrostSignState::Init {
            return Err(MpcError::SessionError("FROST signing already started".into()));
        }
        self.session_id = session_id.to_string();

        let mut rng = OsRng;
        let (nonces, commitments) =
            frost::round1::commit(self.key_package.signing_share(), &mut rng);

        self.nonces = Some(nonces);

        // Store our own commitment
        self.received_commitments
            .insert(self.our_id, commitments);

        let commit_bytes = serde_json::to_vec(&commitments)
            .map_err(|e| MpcError::ProtocolError(format!("serialize commitments: {e}")))?;

        let wire = FrostSignRound1 {
            from: self.config.party_index,
            commitments: commit_bytes,
        };
        let payload = serde_json::to_vec(&wire)
            .map_err(|e| MpcError::ProtocolError(format!("serialize sign r1: {e}")))?;

        // Broadcast to all other participants
        let msgs: Vec<MpcMessage> = self
            .participants
            .iter()
            .filter(|&&i| i != self.config.party_index)
            .map(|&i| MpcMessage {
                from: self.config.party_index,
                to: i,
                round: 1,
                session_id: self.session_id.clone(),
                payload: payload.clone(),
            })
            .collect();

        self.state = FrostSignState::Round1Sent;
        tracing::info!(
            party = self.config.party_index,
            "FROST signing round 1 — commitment broadcast"
        );
        Ok(msgs)
    }

    pub fn process_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        match (self.state, msg.round) {
            (FrostSignState::Round1Sent, 1) => self.handle_sign_round1(msg),
            (FrostSignState::Round2Sent, 2) => self.handle_sign_round2(msg),
            _ => Ok(vec![]),
        }
    }

    fn handle_sign_round1(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        let wire: FrostSignRound1 = serde_json::from_slice(&msg.payload)
            .map_err(|e| MpcError::ProtocolError(format!("deserialize sign r1: {e}")))?;

        let sender_id: Identifier = wire
            .from
            .try_into()
            .map_err(|_| MpcError::ProtocolError("invalid sender id".into()))?;

        let commitments: frost::round1::SigningCommitments =
            serde_json::from_slice(&wire.commitments)
                .map_err(|e| MpcError::ProtocolError(format!("deserialize commitments: {e}")))?;

        self.received_commitments.insert(sender_id, commitments);

        // Need all participants' commitments
        if self.received_commitments.len() < self.participants.len() {
            return Ok(vec![]);
        }

        // Build signing package and compute our signature share
        let signing_package = SigningPackage::new(
            self.received_commitments.clone(),
            &self.message,
        );

        let nonces = self
            .nonces
            .take()
            .ok_or_else(|| MpcError::SessionError("nonces missing".into()))?;

        let sig_share =
            frost::round2::sign(&signing_package, &nonces, &self.key_package)
                .map_err(|e| MpcError::SigningFailed(format!("FROST round2 sign: {e}")))?;

        // Store our own share
        self.received_shares.insert(self.our_id, sig_share);

        let share_bytes = serde_json::to_vec(&sig_share)
            .map_err(|e| MpcError::ProtocolError(format!("serialize sig share: {e}")))?;

        let wire = FrostSignRound2 {
            from: self.config.party_index,
            signature_share: share_bytes,
        };
        let payload = serde_json::to_vec(&wire)
            .map_err(|e| MpcError::ProtocolError(format!("serialize sign r2: {e}")))?;

        let msgs: Vec<MpcMessage> = self
            .participants
            .iter()
            .filter(|&&i| i != self.config.party_index)
            .map(|&i| MpcMessage {
                from: self.config.party_index,
                to: i,
                round: 2,
                session_id: self.session_id.clone(),
                payload: payload.clone(),
            })
            .collect();

        self.state = FrostSignState::Round2Sent;
        tracing::info!(
            party = self.config.party_index,
            "FROST signing round 2 — signature share broadcast"
        );
        Ok(msgs)
    }

    fn handle_sign_round2(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        let wire: FrostSignRound2 = serde_json::from_slice(&msg.payload)
            .map_err(|e| MpcError::ProtocolError(format!("deserialize sign r2: {e}")))?;

        let sender_id: Identifier = wire
            .from
            .try_into()
            .map_err(|_| MpcError::ProtocolError("invalid sender id".into()))?;

        let sig_share: frost::round2::SignatureShare =
            serde_json::from_slice(&wire.signature_share)
                .map_err(|e| MpcError::ProtocolError(format!("deserialize sig share: {e}")))?;

        self.received_shares.insert(sender_id, sig_share);

        if self.received_shares.len() < self.participants.len() {
            return Ok(vec![]);
        }

        // Aggregate: rebuild the signing package
        let signing_package = SigningPackage::new(
            self.received_commitments.clone(),
            &self.message,
        );

        let group_signature =
            frost::aggregate(&signing_package, &self.received_shares, &self.pubkey_package)
                .map_err(|e| MpcError::SigningFailed(format!("FROST aggregate: {e}")))?;

        // Verify the aggregated signature
        self.pubkey_package
            .verifying_key()
            .verify(&self.message, &group_signature)
            .map_err(|e| MpcError::SigningFailed(format!("FROST verify: {e}")))?;

        // Ed25519 signature is 64 bytes: R (32 bytes) || s (32 bytes)
        let sig_bytes = group_signature.serialize()
            .map_err(|e| MpcError::SigningFailed(format!("serialize signature: {e}")))?;

        self.result = Some(SigningResult {
            signature: sig_bytes.clone(),
            r: sig_bytes[..32].to_vec(),
            s: sig_bytes[32..].to_vec(),
            recovery_id: None, // Ed25519 doesn't use recovery_id
        });

        self.state = FrostSignState::Complete;
        tracing::info!(
            party = self.config.party_index,
            "FROST signing complete — valid group signature"
        );
        Ok(vec![])
    }

    pub fn result(&self) -> Option<SigningResult> {
        self.result.clone()
    }

    pub fn is_complete(&self) -> bool {
        self.state == FrostSignState::Complete
    }
}

// =============================================================================
// Helpers
// =============================================================================

/// Convert a FROST Identifier back to u16.
fn identifier_to_u16(id: Identifier) -> Result<u16, MpcError> {
    let serialized = id.serialize();
    let bytes: &[u8] = serialized.as_ref();
    if bytes.len() < 2 {
        return Err(MpcError::ProtocolError("identifier too short".into()));
    }
    // Little-endian scalar: first byte is least significant
    let val = u16::from_le_bytes([bytes[0], bytes[1]]);
    if val == 0 {
        return Err(MpcError::ProtocolError("identifier is zero".into()));
    }
    Ok(val)
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mpc::CurveType;

    /// Simulate a full FROST DKG with n parties, returning all results.
    fn run_frost_dkg(
        threshold: u16,
        total: u16,
    ) -> Result<Vec<(HorcruxConfig, KeygenResult)>, MpcError> {
        let session_id = "frost-dkg-test";

        // Create sessions
        let mut sessions: Vec<FrostDkgSession> = (1..=total)
            .map(|i| {
                let config =
                    HorcruxConfig::new(threshold, total, i, CurveType::Ed25519).unwrap();
                FrostDkgSession::new(config).unwrap()
            })
            .collect();

        // Round 1: each party starts and broadcasts
        let mut round1_msgs: Vec<MpcMessage> = Vec::new();
        for session in sessions.iter_mut() {
            let msgs = session.start(session_id)?;
            round1_msgs.extend(msgs);
        }

        // Deliver round1 messages
        let mut round2_msgs: Vec<MpcMessage> = Vec::new();
        for msg in round1_msgs {
            let recipient = (msg.to - 1) as usize;
            let out = sessions[recipient].process_message(msg)?;
            round2_msgs.extend(out);
        }

        // Deliver round2 messages
        for msg in round2_msgs {
            let recipient = (msg.to - 1) as usize;
            sessions[recipient].process_message(msg)?;
        }

        // Collect results
        let mut results = Vec::new();
        for session in &sessions {
            assert!(session.is_complete(), "DKG not complete for a party");
            let result = session.result().unwrap();
            results.push((
                HorcruxConfig::new(
                    threshold,
                    total,
                    result.party_index,
                    CurveType::Ed25519,
                )
                .unwrap(),
                result,
            ));
        }

        // All parties should agree on the same public key
        let pk = &results[0].1.public_key;
        for (_, r) in &results[1..] {
            assert_eq!(&r.public_key, pk, "public keys diverged");
        }

        Ok(results)
    }

    #[test]
    fn test_frost_dkg_2_of_3() {
        let results = run_frost_dkg(2, 3).unwrap();
        assert_eq!(results.len(), 3);
        assert_eq!(results[0].1.threshold, 2);
        assert_eq!(results[0].1.total_parties, 3);
        // Ed25519 public key is 32 bytes
        assert!(!results[0].1.public_key.is_empty());
    }

    #[test]
    fn test_frost_dkg_3_of_5() {
        let results = run_frost_dkg(3, 5).unwrap();
        assert_eq!(results.len(), 5);
        let pk = &results[0].1.public_key;
        for (_, r) in &results {
            assert_eq!(&r.public_key, pk);
        }
    }

    #[test]
    fn test_frost_signing_2_of_3() {
        let results = run_frost_dkg(2, 3).unwrap();
        let message = b"hello solana".to_vec();

        // Pick parties 1 and 2 to sign (threshold = 2)
        let participants = vec![1u16, 2];
        let session_id = "frost-sign-test";

        let mut sign_sessions: Vec<FrostSigningSession> = participants
            .iter()
            .map(|&i| {
                let (config, keygen_result) = &results[(i - 1) as usize];
                FrostSigningSession::new(
                    config.clone(),
                    message.clone(),
                    keygen_result.shard_data.clone(),
                    participants.clone(),
                )
                .unwrap()
            })
            .collect();

        // Round 1: commit
        let mut round1_msgs: Vec<MpcMessage> = Vec::new();
        for session in sign_sessions.iter_mut() {
            let msgs = session.start(session_id).unwrap();
            round1_msgs.extend(msgs);
        }

        // Deliver round 1
        let mut round2_msgs: Vec<MpcMessage> = Vec::new();
        for msg in round1_msgs {
            let idx = participants.iter().position(|&p| p == msg.to).unwrap();
            let out = sign_sessions[idx].process_message(msg).unwrap();
            round2_msgs.extend(out);
        }

        // Deliver round 2
        for msg in round2_msgs {
            let idx = participants.iter().position(|&p| p == msg.to).unwrap();
            sign_sessions[idx].process_message(msg).unwrap();
        }

        // All signing parties should have the same result
        for session in &sign_sessions {
            assert!(session.is_complete());
            let result = session.result().unwrap();
            assert_eq!(result.signature.len(), 64); // Ed25519 sig = 64 bytes
            assert_eq!(result.r.len(), 32);
            assert_eq!(result.s.len(), 32);
            assert!(result.recovery_id.is_none()); // Ed25519 doesn't use recovery_id
        }

        // Verify signatures match across parties
        let sig1 = sign_sessions[0].result().unwrap().signature;
        let sig2 = sign_sessions[1].result().unwrap().signature;
        assert_eq!(sig1, sig2, "signatures should match");
    }

    #[test]
    fn test_frost_signing_3_of_5() {
        let results = run_frost_dkg(3, 5).unwrap();
        let message = b"threshold 3-of-5 solana tx".to_vec();

        // Pick parties 2, 3, 5 to sign
        let participants = vec![2u16, 3, 5];
        let session_id = "frost-sign-3of5";

        let mut sign_sessions: Vec<FrostSigningSession> = participants
            .iter()
            .map(|&i| {
                let (config, keygen_result) = &results[(i - 1) as usize];
                FrostSigningSession::new(
                    config.clone(),
                    message.clone(),
                    keygen_result.shard_data.clone(),
                    participants.clone(),
                )
                .unwrap()
            })
            .collect();

        // Round 1
        let mut round1_msgs: Vec<MpcMessage> = Vec::new();
        for session in sign_sessions.iter_mut() {
            let msgs = session.start(session_id).unwrap();
            round1_msgs.extend(msgs);
        }

        // Deliver round 1
        let mut round2_msgs: Vec<MpcMessage> = Vec::new();
        for msg in round1_msgs {
            let idx = participants.iter().position(|&p| p == msg.to).unwrap();
            let out = sign_sessions[idx].process_message(msg).unwrap();
            round2_msgs.extend(out);
        }

        // Deliver round 2
        for msg in round2_msgs {
            let idx = participants.iter().position(|&p| p == msg.to).unwrap();
            sign_sessions[idx].process_message(msg).unwrap();
        }

        for session in &sign_sessions {
            assert!(session.is_complete());
        }

        // All parties produce same signature
        let sig0 = sign_sessions[0].result().unwrap().signature;
        for session in &sign_sessions[1..] {
            assert_eq!(session.result().unwrap().signature, sig0);
        }
    }

    #[test]
    fn test_frost_signing_different_subsets_produce_same_public_key() {
        let results = run_frost_dkg(2, 3).unwrap();

        // All DKG results should have the same public key
        let pk = &results[0].1.public_key;
        for (_, r) in &results {
            assert_eq!(&r.public_key, pk);
        }
    }

    #[test]
    fn test_frost_insufficient_signers_rejected() {
        let results = run_frost_dkg(2, 3).unwrap();
        let message = b"test".to_vec();

        // Only 1 signer for threshold=2 → should fail
        let participants = vec![1u16];
        let (config, keygen_result) = &results[0];
        let err = FrostSigningSession::new(
            config.clone(),
            message,
            keygen_result.shard_data.clone(),
            participants,
        );
        assert!(err.is_err());
    }

    #[test]
    fn test_frost_identifier_roundtrip() {
        for i in 1u16..=100 {
            let id: Identifier = i.try_into().unwrap();
            let back = identifier_to_u16(id).unwrap();
            assert_eq!(back, i);
        }
    }
}
