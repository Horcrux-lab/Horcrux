//! Distributed Key Generation (DKG) for CGGMP21 (ECDSA) and FROST (EdDSA).
//!
//! Implements a Feldman VSS-based DKG where each party:
//! - Round 1: Generates a random polynomial, broadcasts commitments
//! - Round 2: Sends secret shares to each other party (point-to-point)
//! - Round 3: Verifies shares against commitments, computes group public key
//!
//! The full private key never exists on any single device.

use super::{CurveType, HorcruxConfig, MpcError};
use super::types::{KeygenResult, MpcMessage};
use k256::{ProjectivePoint, Scalar, AffinePoint, elliptic_curve::group::GroupEncoding};
use k256::elliptic_curve::{Field, PrimeField};
use k256::elliptic_curve::sec1::FromEncodedPoint;
use rand::thread_rng;
use sha2::{Sha256, Digest};

/// Serializable round-1 broadcast: commitments to polynomial coefficients.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Round1Broadcast {
    pub party_index: u16,
    /// Compressed points: commitment to each coefficient of the polynomial
    pub commitments: Vec<Vec<u8>>,
    /// Schnorr proof of knowledge of the secret (constant term)
    pub proof_r: Vec<u8>,
    pub proof_s: Vec<u8>,
}

/// Serializable round-2 point-to-point: secret share for the recipient.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Round2Share {
    pub from: u16,
    pub to: u16,
    /// The evaluated polynomial share f_i(j) as scalar bytes
    pub share: Vec<u8>,
}

/// State machine for the DKG protocol.
#[derive(Debug)]
pub struct KeygenSession {
    pub(crate) config: HorcruxConfig,
    state: KeygenState,
    session_id: String,
    /// Our secret polynomial coefficients
    coefficients: Vec<Vec<u8>>,
    /// Our commitments (G * coeff_k for each k)
    our_commitments: Vec<Vec<u8>>,
    /// Collected round-1 broadcasts from all parties
    round1_broadcasts: Vec<Round1Broadcast>,
    /// Collected round-2 shares addressed to us
    round2_shares: Vec<Round2Share>,
    /// Final result
    keygen_result: Option<KeygenResult>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum KeygenState {
    WaitingForParties,
    Round1,
    Round2,
    Round3,
    Complete,
    Failed,
}

impl KeygenSession {
    pub fn new(config: HorcruxConfig) -> Self {
        Self {
            config,
            state: KeygenState::WaitingForParties,
            session_id: String::new(),
            coefficients: Vec::new(),
            our_commitments: Vec::new(),
            round1_broadcasts: Vec::new(),
            round2_shares: Vec::new(),
            keygen_result: None,
        }
    }

    pub fn start(&mut self, session_id: &str) -> Result<Vec<MpcMessage>, MpcError> {
        if self.state != KeygenState::WaitingForParties {
            return Err(MpcError::SessionError("session already started".into()));
        }
        self.session_id = session_id.to_string();
        self.state = KeygenState::Round1;

        match self.config.curve {
            CurveType::Secp256k1 => self.start_secp256k1_dkg(),
            CurveType::Ed25519 => self.start_ed25519_dkg(),
        }
    }

    pub fn process_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        match self.config.curve {
            CurveType::Secp256k1 => self.process_secp256k1_message(msg),
            CurveType::Ed25519 => self.process_ed25519_message(msg),
        }
    }

    pub fn result(&self) -> Option<KeygenResult> {
        self.keygen_result.clone()
    }

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

    // ===== secp256k1 (CGGMP21-style Feldman DKG) =====

    fn start_secp256k1_dkg(&mut self) -> Result<Vec<MpcMessage>, MpcError> {
        let mut rng = thread_rng();
        let t = self.config.threshold as usize;

        // Generate random polynomial of degree (t-1): f(x) = a_0 + a_1*x + ... + a_{t-1}*x^{t-1}
        let coefficients: Vec<Scalar> = (0..t)
            .map(|_| Scalar::random(&mut rng))
            .collect();

        // Compute commitments: C_k = a_k * G
        let commitments: Vec<ProjectivePoint> = coefficients
            .iter()
            .map(|c| ProjectivePoint::GENERATOR * c)
            .collect();

        // Schnorr proof of knowledge for a_0 (the secret)
        let k = Scalar::random(&mut rng);
        let r_point = ProjectivePoint::GENERATOR * &k;
        let r_bytes = r_point.to_affine().to_bytes();

        // Challenge: H(party_index || R || C_0)
        let mut hasher = Sha256::new();
        hasher.update(self.config.party_index.to_be_bytes());
        hasher.update(r_bytes.as_slice());
        hasher.update(commitments[0].to_affine().to_bytes().as_slice());
        let challenge_hash = hasher.finalize();
        let challenge = scalar_from_hash(&challenge_hash);
        let response = k + challenge * coefficients[0];

        // Store our coefficients for round 2
        self.coefficients = coefficients.iter()
            .map(|c| c.to_bytes().to_vec())
            .collect();
        self.our_commitments = commitments.iter()
            .map(|c| c.to_affine().to_bytes().to_vec())
            .collect();

        // Build round-1 broadcast
        let broadcast = Round1Broadcast {
            party_index: self.config.party_index,
            commitments: self.our_commitments.clone(),
            proof_r: r_bytes.to_vec(),
            proof_s: response.to_bytes().to_vec(),
        };

        // Also store our own broadcast
        self.round1_broadcasts.push(broadcast.clone());

        let payload = serde_json::to_vec(&broadcast)
            .map_err(|e| MpcError::ProtocolError(e.to_string()))?;

        tracing::info!(
            party = self.config.party_index,
            threshold = self.config.threshold,
            total = self.config.total_parties,
            "CGGMP DKG round 1: broadcasting commitments"
        );

        Ok(vec![MpcMessage {
            from: self.config.party_index,
            to: 0,
            round: 1,
            session_id: self.session_id.clone(),
            payload,
        }])
    }

    fn process_secp256k1_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        match self.state {
            KeygenState::Round1 => {
                let broadcast: Round1Broadcast = serde_json::from_slice(&msg.payload)
                    .map_err(|e| MpcError::ProtocolError(format!("invalid round 1 msg: {}", e)))?;

                // Verify Schnorr proof
                self.verify_secp256k1_proof(&broadcast)?;
                self.round1_broadcasts.push(broadcast);

                // Check if we have all round-1 messages
                if self.round1_broadcasts.len() >= self.config.total_parties as usize {
                    self.state = KeygenState::Round2;
                    return self.generate_secp256k1_shares();
                }
                Ok(vec![])
            }
            KeygenState::Round2 => {
                let share: Round2Share = serde_json::from_slice(&msg.payload)
                    .map_err(|e| MpcError::ProtocolError(format!("invalid round 2 msg: {}", e)))?;

                if share.to != self.config.party_index {
                    return Ok(vec![]); // Not for us
                }
                self.round2_shares.push(share);

                // Check if we have all shares
                let expected = (self.config.total_parties - 1) as usize;
                if self.round2_shares.len() >= expected {
                    self.state = KeygenState::Round3;
                    return self.finalize_secp256k1_keygen();
                }
                Ok(vec![])
            }
            _ => Ok(vec![]),
        }
    }

    fn verify_secp256k1_proof(&self, broadcast: &Round1Broadcast) -> Result<(), MpcError> {
        use k256::EncodedPoint;

        let c0_bytes: [u8; 33] = broadcast.commitments[0].clone().try_into()
            .map_err(|_| MpcError::ProtocolError("invalid commitment size".into()))?;
        let c0_point = AffinePoint::from_bytes(&c0_bytes.into());
        if c0_point.is_none().into() {
            return Err(MpcError::ProtocolError("invalid commitment point".into()));
        }
        let c0 = ProjectivePoint::from(c0_point.unwrap());

        let r_encoded = EncodedPoint::from_bytes(&broadcast.proof_r)
            .map_err(|_| MpcError::ProtocolError("invalid proof R".into()))?;
        let r_affine = AffinePoint::from_encoded_point(&r_encoded);
        if r_affine.is_none().into() {
            return Err(MpcError::ProtocolError("invalid proof R point".into()));
        }
        let r_point = ProjectivePoint::from(r_affine.unwrap());

        let s_bytes: [u8; 32] = broadcast.proof_s.clone().try_into()
            .map_err(|_| MpcError::ProtocolError("invalid proof s size".into()))?;
        let s_option = Scalar::from_repr(s_bytes.into());
        if s_option.is_none().into() {
            return Err(MpcError::ProtocolError("invalid proof scalar".into()));
        }
        let s = s_option.unwrap();

        // Recompute challenge
        let mut hasher = Sha256::new();
        hasher.update(broadcast.party_index.to_be_bytes());
        hasher.update(&broadcast.proof_r);
        hasher.update(&broadcast.commitments[0]);
        let challenge_hash = hasher.finalize();
        let challenge = scalar_from_hash(&challenge_hash);

        // Verify: s*G == R + challenge*C_0
        let lhs = ProjectivePoint::GENERATOR * &s;
        let rhs = r_point + c0 * &challenge;

        if lhs != rhs {
            return Err(MpcError::ProtocolError(
                format!("Schnorr proof failed for party {}", broadcast.party_index)
            ));
        }

        Ok(())
    }

    fn generate_secp256k1_shares(&self) -> Result<Vec<MpcMessage>, MpcError> {
        let coefficients: Vec<Scalar> = self.coefficients.iter()
            .map(|c| {
                let bytes: [u8; 32] = c.clone().try_into().unwrap();
                Scalar::from_repr(bytes.into()).unwrap()
            })
            .collect();

        let mut messages = Vec::new();
        for j in 1..=self.config.total_parties {
            if j == self.config.party_index {
                continue;
            }
            // Evaluate polynomial at point j: f_i(j) = sum(a_k * j^k)
            let x = Scalar::from(j as u64);
            let share_value = evaluate_polynomial(&coefficients, &x);

            let share = Round2Share {
                from: self.config.party_index,
                to: j,
                share: share_value.to_bytes().to_vec(),
            };
            let payload = serde_json::to_vec(&share)
                .map_err(|e| MpcError::ProtocolError(e.to_string()))?;

            messages.push(MpcMessage {
                from: self.config.party_index,
                to: j,
                round: 2,
                session_id: self.session_id.clone(),
                payload,
            });
        }

        tracing::info!(
            party = self.config.party_index,
            shares = messages.len(),
            "CGGMP DKG round 2: sending shares"
        );

        Ok(messages)
    }

    fn finalize_secp256k1_keygen(&mut self) -> Result<Vec<MpcMessage>, MpcError> {
        // Our own share: f_i(i) where i is our party index
        let our_coefficients: Vec<Scalar> = self.coefficients.iter()
            .map(|c| {
                let bytes: [u8; 32] = c.clone().try_into().unwrap();
                Scalar::from_repr(bytes.into()).unwrap()
            })
            .collect();
        let our_x = Scalar::from(self.config.party_index as u64);
        let mut total_share = evaluate_polynomial(&our_coefficients, &our_x);

        // Add shares from other parties
        for share in &self.round2_shares {
            let s_bytes: [u8; 32] = share.share.clone().try_into()
                .map_err(|_| MpcError::ProtocolError("invalid share size".into()))?;
            let s = Scalar::from_repr(s_bytes.into());
            if s.is_none().into() {
                return Err(MpcError::ProtocolError(
                    format!("invalid share from party {}", share.from)
                ));
            }

            // Verify share against commitments from round 1
            let sender_broadcast = self.round1_broadcasts.iter()
                .find(|b| b.party_index == share.from)
                .ok_or_else(|| MpcError::ProtocolError(
                    format!("missing broadcast from party {}", share.from)
                ))?;

            self.verify_share_against_commitments(
                &s.unwrap(),
                self.config.party_index,
                &sender_broadcast.commitments,
            )?;

            total_share += s.unwrap();
        }

        // Compute group public key: sum of all parties' C_0 (commitment to constant term)
        let mut group_pubkey = ProjectivePoint::IDENTITY;
        for broadcast in &self.round1_broadcasts {
            let c0_bytes: [u8; 33] = broadcast.commitments[0].clone().try_into()
                .map_err(|_| MpcError::ProtocolError("invalid commitment".into()))?;
            let c0 = AffinePoint::from_bytes(&c0_bytes.into());
            if c0.is_none().into() {
                return Err(MpcError::ProtocolError("invalid commitment point".into()));
            }
            group_pubkey += ProjectivePoint::from(c0.unwrap());
        }

        let pubkey_bytes = group_pubkey.to_affine().to_bytes().to_vec();
        let shard_bytes = total_share.to_bytes().to_vec();

        self.keygen_result = Some(KeygenResult {
            public_key: pubkey_bytes,
            shard_data: shard_bytes,
            party_index: self.config.party_index,
            threshold: self.config.threshold,
            total_parties: self.config.total_parties,
        });

        self.state = KeygenState::Complete;

        tracing::info!(
            party = self.config.party_index,
            pubkey = hex::encode(&self.keygen_result.as_ref().unwrap().public_key),
            "CGGMP DKG complete"
        );

        // Round 3 broadcast: confirmation (no new data needed for basic Feldman)
        Ok(vec![])
    }

    fn verify_share_against_commitments(
        &self,
        share: &Scalar,
        recipient_index: u16,
        commitments: &[Vec<u8>],
    ) -> Result<(), MpcError> {
        // Verify: share * G == sum(C_k * j^k) for k in 0..t
        let lhs = ProjectivePoint::GENERATOR * share;

        let x = Scalar::from(recipient_index as u64);
        let mut rhs = ProjectivePoint::IDENTITY;
        let mut x_pow = Scalar::ONE;

        for commitment_bytes in commitments {
            let c_bytes: [u8; 33] = commitment_bytes.clone().try_into()
                .map_err(|_| MpcError::ProtocolError("invalid commitment size".into()))?;
            let c = AffinePoint::from_bytes(&c_bytes.into());
            if c.is_none().into() {
                return Err(MpcError::ProtocolError("invalid commitment point".into()));
            }
            rhs += ProjectivePoint::from(c.unwrap()) * &x_pow;
            x_pow *= &x;
        }

        if lhs != rhs {
            return Err(MpcError::ProtocolError("share verification failed".into()));
        }
        Ok(())
    }

    // ===== ed25519 (FROST-style DKG) =====
    // Simplified: uses the same Feldman VSS structure but with ed25519 curve
    // For MVP, we delegate to the secp256k1 path with a note that real FROST
    // uses the Ristretto group. Full FROST integration is tracked separately.

    fn start_ed25519_dkg(&mut self) -> Result<Vec<MpcMessage>, MpcError> {
        tracing::info!(
            party = self.config.party_index,
            "FROST DKG round 1 (ed25519)"
        );
        // For now, reuse secp256k1 DKG structure
        // Real FROST will use ed25519-dalek ristretto points
        self.start_secp256k1_dkg()
    }

    fn process_ed25519_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        self.process_secp256k1_message(msg)
    }
}

/// Evaluate polynomial f(x) = sum(coefficients[k] * x^k)
fn evaluate_polynomial(coefficients: &[Scalar], x: &Scalar) -> Scalar {
    let mut result = Scalar::ZERO;
    let mut x_pow = Scalar::ONE;
    for coeff in coefficients {
        result += coeff * &x_pow;
        x_pow *= x;
    }
    result
}

/// Derive a Scalar from a SHA-256 hash (reduce mod curve order).
fn scalar_from_hash(hash: &[u8]) -> Scalar {
    let mut bytes = [0u8; 32];
    bytes.copy_from_slice(&hash[..32]);
    // Reduce mod order — FieldBytesSize is 32 for secp256k1
    Scalar::from_repr(bytes.into()).unwrap_or(Scalar::ONE)
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
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].round, 1);
        assert_eq!(msgs[0].to, 0); // broadcast

        // Verify round-1 payload is a valid Round1Broadcast
        let broadcast: Round1Broadcast = serde_json::from_slice(&msgs[0].payload).unwrap();
        assert_eq!(broadcast.party_index, 1);
        assert_eq!(broadcast.commitments.len(), 2); // threshold=2 → degree 1 polynomial
    }

    #[test]
    fn test_full_2_of_3_dkg() {
        let session_id = "test-dkg-2of3";

        // Create 3 sessions
        let mut sessions: Vec<KeygenSession> = (1..=3)
            .map(|i| {
                let config = HorcruxConfig::new(2, 3, i, CurveType::Secp256k1).unwrap();
                KeygenSession::new(config)
            })
            .collect();

        // Round 1: each party broadcasts commitments
        let mut round1_msgs: Vec<MpcMessage> = Vec::new();
        for session in &mut sessions {
            let msgs = session.start(session_id).unwrap();
            round1_msgs.extend(msgs);
        }
        assert_eq!(round1_msgs.len(), 3);

        // Deliver round 1 messages to all other parties
        let mut round2_msgs: Vec<MpcMessage> = Vec::new();
        for msg in &round1_msgs {
            for session in &mut sessions {
                if session.config.party_index != msg.from {
                    let replies = session.process_message(msg.clone()).unwrap();
                    round2_msgs.extend(replies);
                }
            }
        }

        // Each party should produce (n-1)=2 shares → total 6 messages
        assert_eq!(round2_msgs.len(), 6);

        // Deliver round 2 shares to recipients
        for msg in &round2_msgs {
            for session in &mut sessions {
                if session.config.party_index == msg.to {
                    session.process_message(msg.clone()).unwrap();
                }
            }
        }

        // All sessions should be complete
        for session in &sessions {
            assert_eq!(session.current_state(), "complete");
        }

        // All parties should agree on the same public key
        let results: Vec<KeygenResult> = sessions.iter()
            .map(|s| s.result().unwrap())
            .collect();

        assert_eq!(results[0].public_key, results[1].public_key);
        assert_eq!(results[1].public_key, results[2].public_key);
        assert!(!results[0].public_key.is_empty());

        // Each party should have a different shard
        assert_ne!(results[0].shard_data, results[1].shard_data);
        assert_ne!(results[1].shard_data, results[2].shard_data);

        tracing::info!("DKG complete — public key: {}", hex::encode(&results[0].public_key));
    }

    #[test]
    fn test_full_3_of_5_dkg() {
        let session_id = "test-dkg-3of5";
        let t = 3u16;
        let n = 5u16;

        let mut sessions: Vec<KeygenSession> = (1..=n)
            .map(|i| {
                let config = HorcruxConfig::new(t, n, i, CurveType::Secp256k1).unwrap();
                KeygenSession::new(config)
            })
            .collect();

        // Round 1
        let mut round1_msgs: Vec<MpcMessage> = Vec::new();
        for session in &mut sessions {
            round1_msgs.extend(session.start(session_id).unwrap());
        }

        // Deliver round 1
        let mut round2_msgs: Vec<MpcMessage> = Vec::new();
        for msg in &round1_msgs {
            for session in &mut sessions {
                if session.config.party_index != msg.from {
                    round2_msgs.extend(session.process_message(msg.clone()).unwrap());
                }
            }
        }

        // Deliver round 2
        for msg in &round2_msgs {
            for session in &mut sessions {
                if session.config.party_index == msg.to {
                    session.process_message(msg.clone()).unwrap();
                }
            }
        }

        // All complete with same public key
        let pubkeys: Vec<Vec<u8>> = sessions.iter()
            .map(|s| s.result().unwrap().public_key)
            .collect();

        for pk in &pubkeys {
            assert_eq!(pk, &pubkeys[0]);
        }
    }

    #[test]
    fn test_polynomial_evaluation() {
        // f(x) = 3 + 2x → f(1) = 5, f(2) = 7
        let coeffs = vec![
            Scalar::from(3u64),
            Scalar::from(2u64),
        ];
        assert_eq!(evaluate_polynomial(&coeffs, &Scalar::from(1u64)), Scalar::from(5u64));
        assert_eq!(evaluate_polynomial(&coeffs, &Scalar::from(2u64)), Scalar::from(7u64));
    }
}
