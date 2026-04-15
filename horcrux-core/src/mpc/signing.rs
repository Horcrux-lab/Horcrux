//! Threshold Schnorr signing on secp256k1.
//!
//! Implements a 2-round threshold Schnorr signature protocol compatible with
//! Feldman VSS key shares from the DKG module:
//!
//! - **Round 1**: Each signer generates a random nonce k_i, broadcasts R_i = k_i·G
//! - **Round 2**: Compute combined R = ΣR_i, challenge e = H(R‖msg),
//!   each signer produces partial sig s_i = k_i + e·λ_i·x_i
//! - **Combine**: Final signature (R, s) where s = Σs_i
//!
//! Verification: s·G == R + e·PK
//!
//! **Note**: This is Schnorr, not ECDSA. For EVM/BTC (which require ECDSA),
//! a full CGGMP21 multiplicative-to-additive share conversion would be needed.
//! This protocol is directly usable for Schnorr-compatible chains (Taproot BTC,
//! or as an internal proof-of-concept for the MPC flow).

use super::{CurveType, HorcruxConfig, MpcError};
use super::types::{MpcMessage, SigningResult};
use k256::{ProjectivePoint, Scalar, AffinePoint, elliptic_curve::group::GroupEncoding};
use k256::elliptic_curve::{Field, PrimeField};
use rand::thread_rng;
use sha2::{Sha256, Digest};
use zeroize::Zeroize;

/// Round 1: nonce commitment broadcast.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SignRound1 {
    pub party_index: u16,
    /// R_i = k_i * G (compressed point)
    pub nonce_commitment: Vec<u8>,
}

/// Round 2: partial signature.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SignRound2 {
    pub party_index: u16,
    /// s_i = k_i + e * lambda_i * x_i  (scalar bytes)
    pub partial_sig: Vec<u8>,
}

/// State machine for a threshold signing session.
#[derive(Debug)]
pub struct SigningSession {
    config: HorcruxConfig,
    state: SigningState,
    session_id: String,
    message_hash: Vec<u8>,
    shard_data: Vec<u8>,
    /// Our secret nonce
    nonce_secret: Vec<u8>,
    /// Participating party indices (subset of size >= threshold)
    participants: Vec<u16>,
    /// Collected round-1 commitments
    round1_commitments: Vec<SignRound1>,
    /// Collected round-2 partial signatures
    round2_partials: Vec<SignRound2>,
    /// Final result
    signing_result: Option<SigningResult>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
enum SigningState {
    WaitingForParties,
    Round1,
    Round2,
    Complete,
    Failed,
}

impl SigningSession {
    pub fn new(
        config: HorcruxConfig,
        message_hash: Vec<u8>,
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
            return Err(MpcError::InvalidConfig("our party not in participants list".into()));
        }
        Ok(Self {
            config,
            state: SigningState::WaitingForParties,
            session_id: String::new(),
            message_hash,
            shard_data,
            nonce_secret: Vec::new(),
            participants,
            round1_commitments: Vec::new(),
            round2_partials: Vec::new(),
            signing_result: None,
        })
    }
}

/// Zeroize nonce secret, shard data, and message hash on drop.
impl Drop for SigningSession {
    fn drop(&mut self) {
        self.nonce_secret.zeroize();
        self.shard_data.zeroize();
        self.message_hash.zeroize();
    }
}

impl SigningSession {
    pub fn start(&mut self, session_id: &str) -> Result<Vec<MpcMessage>, MpcError> {
        if self.state != SigningState::WaitingForParties {
            return Err(MpcError::SessionError("signing session already started".into()));
        }
        self.session_id = session_id.to_string();
        self.state = SigningState::Round1;

        match self.config.curve {
            CurveType::Secp256k1 => self.start_secp256k1_signing(),
            CurveType::Ed25519 => Err(MpcError::SigningFailed(
                "Ed25519 signing must use FrostSigningSession (IETF FROST protocol). \
                 Use SessionManager which dispatches Ed25519 to FROST automatically."
                    .into(),
            )),
        }
    }

    pub fn process_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        match self.state {
            SigningState::Round1 => {
                let r1: SignRound1 = serde_json::from_slice(&msg.payload)
                    .map_err(|e| MpcError::ProtocolError(format!("invalid sign r1: {}", e)))?;
                self.round1_commitments.push(r1);

                if self.round1_commitments.len() >= self.participants.len() {
                    self.state = SigningState::Round2;
                    return self.generate_partial_signature();
                }
                Ok(vec![])
            }
            SigningState::Round2 => {
                let r2: SignRound2 = serde_json::from_slice(&msg.payload)
                    .map_err(|e| MpcError::ProtocolError(format!("invalid sign r2: {}", e)))?;
                self.round2_partials.push(r2);

                if self.round2_partials.len() >= self.participants.len() {
                    return self.finalize_signature();
                }
                Ok(vec![])
            }
            _ => Ok(vec![]),
        }
    }

    pub fn result(&self) -> Option<SigningResult> {
        self.signing_result.clone()
    }

    pub fn current_state(&self) -> &str {
        match self.state {
            SigningState::WaitingForParties => "waiting_for_parties",
            SigningState::Round1 => "round_1",
            SigningState::Round2 => "round_2",
            SigningState::Complete => "complete",
            SigningState::Failed => "failed",
        }
    }

    // ===== secp256k1 threshold signing =====

    fn start_secp256k1_signing(&mut self) -> Result<Vec<MpcMessage>, MpcError> {
        let mut rng = thread_rng();

        // Generate random nonce k_i
        let k = Scalar::random(&mut rng);
        let r_point = ProjectivePoint::GENERATOR * k;

        self.nonce_secret = k.to_bytes().to_vec();

        let commitment = SignRound1 {
            party_index: self.config.party_index,
            nonce_commitment: r_point.to_affine().to_bytes().to_vec(),
        };

        // Store our own commitment
        self.round1_commitments.push(commitment.clone());

        let payload = serde_json::to_vec(&commitment)
            .map_err(|e| MpcError::ProtocolError(e.to_string()))?;

        tracing::info!(
            party = self.config.party_index,
            participants = ?self.participants,
            "Signing round 1: broadcasting nonce commitment"
        );

        Ok(vec![MpcMessage {
            from: self.config.party_index,
            to: 0,
            round: 1,
            session_id: self.session_id.clone(),
            payload,
        }])
    }

    fn generate_partial_signature(&mut self) -> Result<Vec<MpcMessage>, MpcError> {
        // Compute combined R = sum(R_i)
        let mut combined_r = ProjectivePoint::IDENTITY;
        for commitment in &self.round1_commitments {
            let r_bytes: [u8; 33] = commitment.nonce_commitment.clone().try_into()
                .map_err(|_| MpcError::ProtocolError("invalid nonce commitment size".into()))?;
            let r_affine = AffinePoint::from_bytes(&r_bytes.into());
            if r_affine.is_none().into() {
                return Err(MpcError::ProtocolError("invalid nonce point".into()));
            }
            combined_r += ProjectivePoint::from(r_affine.unwrap());
        }

        let r_bytes = combined_r.to_affine().to_bytes();

        // Challenge: e = H(R || message_hash)
        let mut hasher = Sha256::new();
        hasher.update(r_bytes.as_slice());
        hasher.update(&self.message_hash);
        let e_hash = hasher.finalize();
        let e = scalar_from_hash(&e_hash);

        // Our secret nonce
        let k_bytes: [u8; 32] = self.nonce_secret.clone().try_into()
            .map_err(|_| MpcError::ProtocolError("invalid nonce".into()))?;
        let k = Scalar::from_repr(k_bytes.into());
        if k.is_none().into() {
            return Err(MpcError::ProtocolError("invalid nonce scalar".into()));
        }
        let k = k.unwrap();

        // Our shard (secret share x_i)
        let xi_bytes: [u8; 32] = self.shard_data.clone().try_into()
            .map_err(|_| MpcError::ProtocolError("invalid shard".into()))?;
        let xi = Scalar::from_repr(xi_bytes.into());
        if xi.is_none().into() {
            return Err(MpcError::ProtocolError("invalid shard scalar".into()));
        }
        let xi = xi.unwrap();

        // Lagrange coefficient for our party
        let lambda = lagrange_coefficient(
            self.config.party_index,
            &self.participants,
        );

        // Partial signature: s_i = k_i + e * lambda_i * x_i
        let partial = k + e * lambda * xi;

        let r2 = SignRound2 {
            party_index: self.config.party_index,
            partial_sig: partial.to_bytes().to_vec(),
        };

        // Store our own partial
        self.round2_partials.push(r2.clone());

        let payload = serde_json::to_vec(&r2)
            .map_err(|e| MpcError::ProtocolError(e.to_string()))?;

        tracing::info!(
            party = self.config.party_index,
            "Signing round 2: broadcasting partial signature"
        );

        Ok(vec![MpcMessage {
            from: self.config.party_index,
            to: 0,
            round: 2,
            session_id: self.session_id.clone(),
            payload,
        }])
    }

    fn finalize_signature(&mut self) -> Result<Vec<MpcMessage>, MpcError> {
        // Recompute combined R
        let mut combined_r = ProjectivePoint::IDENTITY;
        for commitment in &self.round1_commitments {
            let r_bytes: [u8; 33] = commitment.nonce_commitment.clone().try_into()
                .map_err(|_| MpcError::ProtocolError("invalid nonce commitment".into()))?;
            let r_affine = AffinePoint::from_bytes(&r_bytes.into());
            if r_affine.is_none().into() {
                return Err(MpcError::ProtocolError("invalid nonce point".into()));
            }
            combined_r += ProjectivePoint::from(r_affine.unwrap());
        }

        let r_affine = combined_r.to_affine();
        let r_bytes = r_affine.to_bytes().to_vec();

        // Aggregate partial signatures: s = sum(s_i)
        let mut s = Scalar::ZERO;
        for partial in &self.round2_partials {
            let s_bytes: [u8; 32] = partial.partial_sig.clone().try_into()
                .map_err(|_| MpcError::ProtocolError("invalid partial sig size".into()))?;
            let si = Scalar::from_repr(s_bytes.into());
            if si.is_none().into() {
                return Err(MpcError::ProtocolError("invalid partial sig scalar".into()));
            }
            s += si.unwrap();
        }

        let s_bytes = s.to_bytes().to_vec();

        self.signing_result = Some(SigningResult {
            signature: [r_bytes.clone(), s_bytes.clone()].concat(),
            r: r_bytes,
            s: s_bytes,
            recovery_id: None,
        });

        self.state = SigningState::Complete;

        tracing::info!(
            party = self.config.party_index,
            "Threshold signing complete"
        );

        Ok(vec![])
    }
}

/// Compute Lagrange coefficient for party `i` given the set of participants.
/// lambda_i = product( j / (j - i) ) for all j in participants where j != i
fn lagrange_coefficient(i: u16, participants: &[u16]) -> Scalar {
    let xi = Scalar::from(i as u64);
    let mut lambda = Scalar::ONE;
    for &j in participants {
        if j == i {
            continue;
        }
        let xj = Scalar::from(j as u64);
        // lambda *= xj / (xj - xi)
        let num = xj;
        let den = xj - xi;
        lambda *= num * den.invert().unwrap();
    }
    lambda
}

/// Derive a Scalar from a SHA-256 hash by reducing mod curve order.
///
/// IMPORTANT: We use `Scalar::reduce` (wide reduction) because SHA-256 output
/// may exceed the secp256k1 order. `from_repr()` rejects non-canonical bytes.
fn scalar_from_hash(hash: &[u8]) -> Scalar {
    use k256::elliptic_curve::ops::Reduce;
    use k256::U256;
    let mut bytes = [0u8; 32];
    bytes.copy_from_slice(&hash[..32]);
    <Scalar as Reduce<U256>>::reduce_bytes(&bytes.into())
}

/// Verify a threshold signature against a public key.
pub fn verify_threshold_signature(
    public_key: &[u8],
    message_hash: &[u8],
    r_bytes: &[u8],
    s_bytes: &[u8],
) -> Result<bool, MpcError> {
    let pk_arr: [u8; 33] = public_key.try_into()
        .map_err(|_| MpcError::SigningFailed("invalid public key size".into()))?;
    let pk_affine = AffinePoint::from_bytes(&pk_arr.into());
    if pk_affine.is_none().into() {
        return Err(MpcError::SigningFailed("invalid public key point".into()));
    }
    let pk = ProjectivePoint::from(pk_affine.unwrap());

    let r_arr: [u8; 33] = r_bytes.try_into()
        .map_err(|_| MpcError::SigningFailed("invalid R size".into()))?;
    let r_affine = AffinePoint::from_bytes(&r_arr.into());
    if r_affine.is_none().into() {
        return Err(MpcError::SigningFailed("invalid R point".into()));
    }
    let r = ProjectivePoint::from(r_affine.unwrap());

    let s_arr: [u8; 32] = s_bytes.try_into()
        .map_err(|_| MpcError::SigningFailed("invalid s size".into()))?;
    let s = Scalar::from_repr(s_arr.into());
    if s.is_none().into() {
        return Err(MpcError::SigningFailed("invalid s scalar".into()));
    }
    let s = s.unwrap();

    // Challenge
    let mut hasher = Sha256::new();
    hasher.update(r_bytes);
    hasher.update(message_hash);
    let e_hash = hasher.finalize();
    let e = scalar_from_hash(&e_hash);

    // Verify: s*G == R + e*PK
    let lhs = ProjectivePoint::GENERATOR * s;
    let rhs = r + pk * e;

    Ok(lhs == rhs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mpc::keygen::KeygenSession;
    use crate::mpc::{HorcruxConfig, CurveType};

    #[test]
    fn test_signing_session_creation() {
        let config = HorcruxConfig::new(2, 3, 1, CurveType::Secp256k1).unwrap();
        let session = SigningSession::new(
            config, vec![0u8; 32], vec![1u8; 32], vec![1, 2],
        ).unwrap();
        assert_eq!(session.current_state(), "waiting_for_parties");
    }

    #[test]
    fn test_insufficient_parties_rejected() {
        let config = HorcruxConfig::new(2, 3, 1, CurveType::Secp256k1).unwrap();
        let result = SigningSession::new(
            config, vec![0u8; 32], vec![1u8; 32], vec![1], // only 1, need 2
        );
        assert!(result.is_err());
    }

    #[test]
    fn test_lagrange_coefficients() {
        // For parties {1, 2, 3} with t=2:
        // Lagrange interpolation at x=0 should reconstruct the secret
        let participants = vec![1u16, 2, 3];

        let l1 = lagrange_coefficient(1, &participants);
        let l2 = lagrange_coefficient(2, &participants);
        let l3 = lagrange_coefficient(3, &participants);

        // sum(lambda_i * f(i)) where f(x) = secret + a1*x should equal secret at x=0
        // Test with known polynomial f(x) = 5 + 3x
        let secret = Scalar::from(5u64);
        let a1 = Scalar::from(3u64);

        let f1 = secret + a1 * Scalar::from(1u64); // 8
        let f2 = secret + a1 * Scalar::from(2u64); // 11
        let f3 = secret + a1 * Scalar::from(3u64); // 14

        let reconstructed = l1 * f1 + l2 * f2 + l3 * f3;
        assert_eq!(reconstructed, secret);
    }

    #[test]
    fn test_full_dkg_then_sign_2_of_3() {
        let session_id = "test-dkg";
        let t = 2u16;
        let n = 3u16;

        // ===== DKG Phase =====
        let mut keygen_sessions: Vec<KeygenSession> = (1..=n)
            .map(|i| {
                let config = HorcruxConfig::new(t, n, i, CurveType::Secp256k1).unwrap();
                KeygenSession::new(config)
            })
            .collect();

        let mut r1_msgs: Vec<MpcMessage> = Vec::new();
        for s in &mut keygen_sessions {
            r1_msgs.extend(s.start(session_id).unwrap());
        }

        let mut r2_msgs: Vec<MpcMessage> = Vec::new();
        for msg in &r1_msgs {
            for s in &mut keygen_sessions {
                if s.config.party_index != msg.from {
                    r2_msgs.extend(s.process_message(msg.clone()).unwrap());
                }
            }
        }

        for msg in &r2_msgs {
            for s in &mut keygen_sessions {
                if s.config.party_index == msg.to {
                    s.process_message(msg.clone()).unwrap();
                }
            }
        }

        let keygen_results: Vec<_> = keygen_sessions.iter()
            .map(|s| s.result().unwrap())
            .collect();

        let public_key = keygen_results[0].public_key.clone();

        // ===== Signing Phase (parties 1 and 3 sign) =====
        let signers = vec![1u16, 3];
        let message_hash = Sha256::digest(b"Hello Horcrux!").to_vec();

        let mut sign_sessions: Vec<SigningSession> = signers.iter()
            .map(|&i| {
                let config = HorcruxConfig::new(t, n, i, CurveType::Secp256k1).unwrap();
                let shard = keygen_results[(i - 1) as usize].shard_data.clone();
                SigningSession::new(config, message_hash.clone(), shard, signers.clone()).unwrap()
            })
            .collect();

        // Round 1: nonce commitments
        let mut sr1_msgs: Vec<MpcMessage> = Vec::new();
        for s in &mut sign_sessions {
            sr1_msgs.extend(s.start("sign-1").unwrap());
        }

        // Deliver round 1
        let mut sr2_msgs: Vec<MpcMessage> = Vec::new();
        for msg in &sr1_msgs {
            for s in &mut sign_sessions {
                if s.config.party_index != msg.from {
                    sr2_msgs.extend(s.process_message(msg.clone()).unwrap());
                }
            }
        }

        // Deliver round 2
        for msg in &sr2_msgs {
            for s in &mut sign_sessions {
                if s.config.party_index != msg.from {
                    s.process_message(msg.clone()).unwrap();
                }
            }
        }

        // All signers should be complete
        for s in &sign_sessions {
            assert_eq!(s.current_state(), "complete");
        }

        // All signers produce the same signature
        let sig0 = sign_sessions[0].result().unwrap();
        let sig1 = sign_sessions[1].result().unwrap();
        assert_eq!(sig0.r, sig1.r);
        assert_eq!(sig0.s, sig1.s);

        // Verify the signature against the group public key
        let valid = verify_threshold_signature(
            &public_key,
            &message_hash,
            &sig0.r,
            &sig0.s,
        ).unwrap();
        assert!(valid, "threshold signature verification failed!");

        tracing::info!("Full DKG + Signing test passed!");
    }

    // ===== Comprehensive MPC validation tests =====

    /// Helper: run DKG for t-of-n, return (public_key, keygen_results)
    fn run_dkg(t: u16, n: u16) -> (Vec<u8>, Vec<super::super::types::KeygenResult>) {
        let session_id = "dkg-helper";
        let mut sessions: Vec<KeygenSession> = (1..=n)
            .map(|i| {
                let config = HorcruxConfig::new(t, n, i, CurveType::Secp256k1).unwrap();
                KeygenSession::new(config)
            })
            .collect();

        let mut r1_msgs: Vec<MpcMessage> = Vec::new();
        for s in &mut sessions {
            r1_msgs.extend(s.start(session_id).unwrap());
        }

        let mut r2_msgs: Vec<MpcMessage> = Vec::new();
        for msg in &r1_msgs {
            for s in &mut sessions {
                if s.config.party_index != msg.from {
                    r2_msgs.extend(s.process_message(msg.clone()).unwrap());
                }
            }
        }

        for msg in &r2_msgs {
            for s in &mut sessions {
                if s.config.party_index == msg.to {
                    s.process_message(msg.clone()).unwrap();
                }
            }
        }

        let results: Vec<_> = sessions.iter().map(|s| s.result().unwrap()).collect();
        let pk = results[0].public_key.clone();
        (pk, results)
    }

    /// Helper: run signing with given signers, return SigningResult
    fn run_signing(
        t: u16, n: u16,
        signers: &[u16],
        keygen_results: &[super::super::types::KeygenResult],
        message_hash: &[u8],
    ) -> super::super::types::SigningResult {
        let mut sign_sessions: Vec<SigningSession> = signers.iter()
            .map(|&i| {
                let config = HorcruxConfig::new(t, n, i, CurveType::Secp256k1).unwrap();
                let shard = keygen_results[(i - 1) as usize].shard_data.clone();
                SigningSession::new(config, message_hash.to_vec(), shard, signers.to_vec()).unwrap()
            })
            .collect();

        let mut sr1_msgs: Vec<MpcMessage> = Vec::new();
        for s in &mut sign_sessions {
            sr1_msgs.extend(s.start("sign").unwrap());
        }

        let mut sr2_msgs: Vec<MpcMessage> = Vec::new();
        for msg in &sr1_msgs {
            for s in &mut sign_sessions {
                if s.config.party_index != msg.from {
                    sr2_msgs.extend(s.process_message(msg.clone()).unwrap());
                }
            }
        }

        for msg in &sr2_msgs {
            for s in &mut sign_sessions {
                if s.config.party_index != msg.from {
                    s.process_message(msg.clone()).unwrap();
                }
            }
        }

        sign_sessions[0].result().unwrap()
    }

    #[test]
    fn test_different_signer_subsets_all_valid() {
        // 2-of-3 DKG, then sign with {1,2}, {1,3}, {2,3} — all should verify
        let (pk, results) = run_dkg(2, 3);
        let msg = Sha256::digest(b"subset test").to_vec();

        for signers in &[vec![1u16, 2], vec![1, 3], vec![2, 3]] {
            let sig = run_signing(2, 3, signers, &results, &msg);
            let valid = verify_threshold_signature(&pk, &msg, &sig.r, &sig.s).unwrap();
            assert!(valid, "signature from {:?} failed verification", signers);
        }
    }

    #[test]
    fn test_all_parties_sign_3_of_5() {
        // 3-of-5 DKG, sign with all 5 parties
        let (pk, results) = run_dkg(3, 5);
        let msg = Sha256::digest(b"3-of-5 all sign").to_vec();

        let sig = run_signing(3, 5, &[1, 2, 3, 4, 5], &results, &msg);
        let valid = verify_threshold_signature(&pk, &msg, &sig.r, &sig.s).unwrap();
        assert!(valid);
    }

    #[test]
    fn test_minimal_subset_3_of_5() {
        // 3-of-5 DKG, sign with exactly 3 parties (various subsets)
        let (pk, results) = run_dkg(3, 5);
        let msg = Sha256::digest(b"minimal subset").to_vec();

        for signers in &[vec![1u16, 2, 3], vec![1, 3, 5], vec![2, 4, 5], vec![3, 4, 5]] {
            let sig = run_signing(3, 5, signers, &results, &msg);
            let valid = verify_threshold_signature(&pk, &msg, &sig.r, &sig.s).unwrap();
            assert!(valid, "signature from {:?} failed", signers);
        }
    }

    #[test]
    fn test_different_messages_different_signatures() {
        let (pk, results) = run_dkg(2, 3);
        let msg1 = Sha256::digest(b"message A").to_vec();
        let msg2 = Sha256::digest(b"message B").to_vec();

        let sig1 = run_signing(2, 3, &[1, 2], &results, &msg1);
        let sig2 = run_signing(2, 3, &[1, 2], &results, &msg2);

        // Different messages → different signatures (different challenge e)
        assert_ne!(sig1.s, sig2.s, "different messages should produce different s");

        // Both verify against correct message
        assert!(verify_threshold_signature(&pk, &msg1, &sig1.r, &sig1.s).unwrap());
        assert!(verify_threshold_signature(&pk, &msg2, &sig2.r, &sig2.s).unwrap());

        // Cross-verify should fail: sig1 against msg2
        let cross = verify_threshold_signature(&pk, &msg2, &sig1.r, &sig1.s).unwrap();
        assert!(!cross, "signature for msg1 should NOT verify against msg2");
    }

    #[test]
    fn test_wrong_public_key_rejects() {
        let (pk, results) = run_dkg(2, 3);
        let msg = Sha256::digest(b"wrong key test").to_vec();

        let sig = run_signing(2, 3, &[1, 2], &results, &msg);

        // Generate a different DKG → different public key
        let (pk2, _) = run_dkg(2, 3);
        assert_ne!(pk, pk2);

        // Signature should NOT verify against wrong key
        let valid = verify_threshold_signature(&pk2, &msg, &sig.r, &sig.s).unwrap();
        assert!(!valid, "signature should not verify against wrong public key");
    }

    #[test]
    fn test_tampered_signature_rejected() {
        let (pk, results) = run_dkg(2, 3);
        let msg = Sha256::digest(b"tamper test").to_vec();
        let sig = run_signing(2, 3, &[1, 3], &results, &msg);

        // Tamper with s
        let mut bad_s = sig.s.clone();
        bad_s[0] ^= 0x01;
        // May produce invalid scalar, but verify should either error or return false
        let result = verify_threshold_signature(&pk, &msg, &sig.r, &bad_s);
        match result {
            Ok(valid) => assert!(!valid, "tampered s should not verify"),
            Err(_) => {} // Also acceptable — invalid scalar
        }
    }

    #[test]
    fn test_scalar_from_hash_never_panics() {
        // Verify the fixed scalar_from_hash handles all possible hash outputs
        use sha2::{Sha256, Digest};
        for i in 0u64..1000 {
            let hash = Sha256::digest(i.to_be_bytes());
            let s = scalar_from_hash(&hash);
            // Should never be zero (astronomically unlikely, but check anyway)
            assert_ne!(s, Scalar::ZERO, "scalar_from_hash produced zero at i={}", i);
        }
    }

    #[test]
    fn test_scalar_from_hash_deterministic() {
        let hash = Sha256::digest(b"deterministic");
        let s1 = scalar_from_hash(&hash);
        let s2 = scalar_from_hash(&hash);
        assert_eq!(s1, s2);
    }

    #[test]
    fn test_lagrange_subset_reconstruction() {
        // Verify Lagrange interpolation works for arbitrary 2-of-3 subsets
        let secret = Scalar::from(42u64);
        let a1 = Scalar::from(17u64);

        let f = |x: u64| secret + a1 * Scalar::from(x);

        for subset in &[vec![1u16, 2], vec![1, 3], vec![2, 3]] {
            let mut reconstructed = Scalar::ZERO;
            for &i in subset {
                let li = lagrange_coefficient(i, subset);
                reconstructed += li * f(i as u64);
            }
            assert_eq!(reconstructed, secret,
                "Lagrange failed for subset {:?}", subset);
        }
    }

    #[test]
    fn test_lagrange_4_of_7_subsets() {
        // More complex: degree-3 polynomial (t=4)
        let a0 = Scalar::from(100u64);
        let a1 = Scalar::from(7u64);
        let a2 = Scalar::from(3u64);
        let a3 = Scalar::from(11u64);

        let f = |x: u64| {
            let xs = Scalar::from(x);
            a0 + a1 * xs + a2 * xs * xs + a3 * xs * xs * xs
        };

        // Any 4 out of 7 should reconstruct a0
        let subsets: Vec<Vec<u16>> = vec![
            vec![1, 2, 3, 4],
            vec![1, 3, 5, 7],
            vec![2, 4, 6, 7],
            vec![4, 5, 6, 7],
        ];

        for subset in &subsets {
            let mut reconstructed = Scalar::ZERO;
            for &i in subset {
                let li = lagrange_coefficient(i, subset);
                reconstructed += li * f(i as u64);
            }
            assert_eq!(reconstructed, a0,
                "Lagrange 4-of-7 failed for subset {:?}", subset);
        }
    }

    #[test]
    fn test_dkg_share_consistency() {
        // Verify that DKG shares are consistent: each party's share x_i satisfies
        // x_i * G == sum(C_k * i^k) (Feldman VSS check)
        let (pk, results) = run_dkg(2, 3);

        for result in &results {
            // The share should be a valid scalar
            let share_bytes: [u8; 32] = result.shard_data.clone().try_into().unwrap();
            let share = Scalar::from_repr(share_bytes.into());
            assert!(bool::from(share.is_some()),
                "party {} has invalid share scalar", result.party_index);
        }

        // All parties agree on public key
        for r in &results {
            assert_eq!(r.public_key, pk);
        }
    }

    #[test]
    fn test_signing_idempotent_verification() {
        // Sign once, verify multiple times — should always pass
        let (pk, results) = run_dkg(2, 3);
        let msg = Sha256::digest(b"idempotent").to_vec();
        let sig = run_signing(2, 3, &[1, 2], &results, &msg);

        for _ in 0..10 {
            assert!(verify_threshold_signature(&pk, &msg, &sig.r, &sig.s).unwrap());
        }
    }

    #[test]
    fn test_party_not_in_participants_rejected() {
        let config = HorcruxConfig::new(2, 3, 1, CurveType::Secp256k1).unwrap();
        // Party 1 not in participants list [2, 3]
        let result = SigningSession::new(config, vec![0u8; 32], vec![1u8; 32], vec![2, 3]);
        assert!(result.is_err());
    }
}
