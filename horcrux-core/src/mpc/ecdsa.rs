//! CGGMP21 threshold ECDSA for secp256k1 (EVM + Bitcoin).
//!
//! Wraps the `cggmp21` crate using its sync `state-machine` API to integrate
//! with our message-passing architecture. The protocol has three phases:
//!
//! 1. **Keygen**: Threshold DKG producing `IncompleteKeyShare`
//! 2. **Aux Info**: Paillier modulus generation producing `AuxInfo`
//! 3. **Signing**: Threshold ECDSA producing `Signature` with recovery_id

use super::types::{KeygenResult, MpcMessage, SigningResult};
use super::{HorcruxConfig, MpcError};

use cggmp21::security_level::SecurityLevel128;
use cggmp21::supported_curves::Secp256k1;
use cggmp21::ExecutionId;
use generic_ec::as_raw::AsRaw;
use generic_ec::core::UncompressedEncoding;
use generic_ec::{NonZero, Point, Scalar};
use rand::rngs::OsRng;
use round_based::state_machine::{ProceedResult, StateMachine};
use round_based::{Incoming, MessageDestination, MessageType};
use serde::{de::DeserializeOwned, Serialize};

// =============================================================================
// Type-erased state machine driver
// =============================================================================

pub(super) enum DriverAction {
    Send {
        recipient: Option<u16>,
        data: Vec<u8>,
    },
    NeedMessage,
    Complete(Vec<u8>),
}

/// Object-safe trait for driving any round-based state machine.
pub(super) trait AnyDriver {
    fn drive(&mut self) -> Result<DriverAction, MpcError>;
    fn feed(&mut self, sender: u16, is_broadcast: bool, data: &[u8]) -> Result<(), MpcError>;
}

/// Concrete driver wrapping a StateMachine whose Output = Result<T, E>.
pub(super) struct SmDriver<SM: StateMachine> {
    pub(super) sm: SM,
}

impl<SM, T, E> AnyDriver for SmDriver<SM>
where
    SM: StateMachine<Output = Result<T, E>>,
    SM::Msg: Serialize + DeserializeOwned,
    T: Serialize,
    E: std::fmt::Display + std::error::Error,
{
    fn drive(&mut self) -> Result<DriverAction, MpcError> {
        loop {
            match self.sm.proceed() {
                ProceedResult::SendMsg(outgoing) => {
                    let data = serde_json::to_vec(&outgoing.msg)
                        .map_err(|e| MpcError::ProtocolError(format!("serialize msg: {e}")))?;
                    let recipient = match outgoing.recipient {
                        MessageDestination::AllParties => None,
                        MessageDestination::OneParty(i) => Some(i),
                    };
                    return Ok(DriverAction::Send { recipient, data });
                }
                ProceedResult::NeedsOneMoreMessage => {
                    return Ok(DriverAction::NeedMessage);
                }
                ProceedResult::Output(result) => {
                    let success = result.map_err(|e| {
                        // Include the full source chain (alternate display)
                        // so callers see whether this was a ProtocolAborted,
                        // an IoError, or an InternalError(Bug) — the bare
                        // top-level Display just says "failed to complete".
                        let mut msg = format!("protocol error: {e}");
                        let mut src: &dyn std::error::Error = &e;
                        while let Some(inner) = src.source() {
                            msg.push_str(&format!(" -> {inner}"));
                            src = inner;
                        }
                        MpcError::ProtocolError(msg)
                    })?;
                    let data = serde_json::to_vec(&success)
                        .map_err(|e| MpcError::ProtocolError(format!("serialize output: {e}")))?;
                    return Ok(DriverAction::Complete(data));
                }
                ProceedResult::Yielded => continue,
                ProceedResult::Error(e) => {
                    return Err(MpcError::ProtocolError(format!(
                        "state machine error: {e:?}"
                    )));
                }
            }
        }
    }

    fn feed(&mut self, sender: u16, is_broadcast: bool, data: &[u8]) -> Result<(), MpcError> {
        let msg: SM::Msg = serde_json::from_slice(data)
            .map_err(|e| MpcError::ProtocolError(format!("deserialize msg: {e}")))?;
        let msg_type = if is_broadcast {
            MessageType::Broadcast
        } else {
            MessageType::P2P
        };
        let incoming = Incoming {
            id: 0,
            sender,
            msg_type,
            msg,
        };
        self.sm
            .received_msg(incoming)
            .map_err(|_| {
                MpcError::ProtocolError(format!(
                    "state machine rejected message from party {sender} (is_broadcast={is_broadcast}, {} bytes)",
                    data.len()
                ))
            })?;
        Ok(())
    }
}

// =============================================================================
// Factory functions — use Box::leak for 'static lifetime requirements
// =============================================================================

fn make_keygen_driver(
    i: u16,
    n: u16,
    t: u16,
    session_id: &str,
) -> Result<Box<dyn AnyDriver>, MpcError> {
    // All parties must share the same ExecutionId for CGGMP21 commitments to be compatible
    let eid_bytes: &'static [u8] = Box::leak(
        format!("horcrux-keygen-{}", session_id)
            .into_bytes()
            .into_boxed_slice(),
    );
    let eid = ExecutionId::new(eid_bytes);
    let rng: &'static mut OsRng = Box::leak(Box::new(OsRng));

    // CRITICAL: cggmp21 0.6 only supports `key_refresh` for non-threshold
    // (additive, `vss_setup = None`) shares — its invariant is
    // `sum(public_shares) == shared_public_key`, which a VSS share does NOT
    // satisfy. When `t == n` the two schemes are semantically equivalent
    // (every signer is always required), so we take the non-threshold path
    // so that proactive share rotation works. Only genuine t < n wallets
    // still produce VSS shares — those cannot be refreshed with upstream
    // cggmp21 and must block that UI flow in `EcdsaRefreshSession::new`.
    if t >= n {
        let sm = cggmp21::keygen::<Secp256k1>(eid, i, n).into_state_machine(rng);
        Ok(Box::new(SmDriver { sm }))
    } else {
        let sm = cggmp21::keygen::<Secp256k1>(eid, i, n)
            .set_threshold(t)
            .into_state_machine(rng);
        Ok(Box::new(SmDriver { sm }))
    }
}

fn make_auxinfo_driver(i: u16, n: u16, session_id: &str) -> Result<Box<dyn AnyDriver>, MpcError> {
    // All parties must share the same ExecutionId
    let eid_bytes: &'static [u8] = Box::leak(
        format!("horcrux-auxinfo-{}", session_id)
            .into_bytes()
            .into_boxed_slice(),
    );
    let eid = ExecutionId::new(eid_bytes);
    // Pop a pregenerated prime pair if the pool has one, otherwise fall back
    // to synchronous on-the-fly generation (slow on iOS; see prime_pool).
    let pregen = super::prime_pool::take_or_generate();
    let rng2: &'static mut OsRng = Box::leak(Box::new(OsRng));

    let sm = cggmp21::aux_info_gen(eid, i, n, pregen).into_state_machine(rng2);

    Ok(Box::new(SmDriver { sm }))
}

fn make_signing_driver(
    our_signing_index: u16,
    parties_at_keygen: &[u16],
    key_share: &cggmp21::KeyShare<Secp256k1, SecurityLevel128>,
    message_hash: &[u8],
    session_id: &str,
) -> Result<Box<dyn AnyDriver>, MpcError> {
    let eid_bytes: &'static [u8] = Box::leak(
        format!("horcrux-sign-{}", session_id)
            .into_bytes()
            .into_boxed_slice(),
    );
    let eid = ExecutionId::new(eid_bytes);
    let rng: &'static mut OsRng = Box::leak(Box::new(OsRng));

    let parties: &'static [u16] = Box::leak(parties_at_keygen.to_vec().into_boxed_slice());
    let ks: &'static cggmp21::KeyShare<Secp256k1, SecurityLevel128> =
        Box::leak(Box::new(key_share.clone()));

    let data_to_sign = cggmp21::DataToSign::from_scalar(
        Scalar::<Secp256k1>::from_be_bytes_mod_order(message_hash),
    );

    let sm = cggmp21::signing(eid, our_signing_index, parties, ks).sign_sync(rng, data_to_sign);

    Ok(Box::new(SmDriver { sm }))
}

// =============================================================================
// Wire protocol types
// =============================================================================

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct EcdsaWireMsg {
    pub from: u16,
    pub phase: EcdsaPhase,
    pub is_broadcast: bool,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum EcdsaPhase {
    Keygen,
    AuxInfo,
    Signing,
    Refresh,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct EcdsaShardData {
    pub incomplete_key_share: Vec<u8>,
    pub aux_info: Vec<u8>,
}

// =============================================================================
// ECDSA DKG Session
// =============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EcdsaDkgState {
    KeygenRunning,
    AuxInfoRunning,
    Complete,
}

pub struct EcdsaDkgSession {
    config: HorcruxConfig,
    session_id: String,
    state: EcdsaDkgState,
    driver: Option<Box<dyn AnyDriver>>,
    incomplete_key_share_bytes: Option<Vec<u8>>,
    result: Option<KeygenResult>,
}

impl std::fmt::Debug for EcdsaDkgSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EcdsaDkgSession")
            .field("session_id", &self.session_id)
            .field("state", &self.state)
            .finish()
    }
}

impl EcdsaDkgSession {
    pub fn new(config: HorcruxConfig) -> Result<Self, MpcError> {
        // Driver created in start() when session_id is available
        Ok(Self {
            config,
            session_id: String::new(),
            state: EcdsaDkgState::KeygenRunning,
            driver: None,
            incomplete_key_share_bytes: None,
            result: None,
        })
    }

    pub fn start(&mut self, session_id: &str) -> Result<Vec<MpcMessage>, MpcError> {
        self.session_id = session_id.to_string();
        let i = self.config.party_index - 1;
        let n = self.config.total_parties;
        let t = self.config.threshold;
        self.driver = Some(make_keygen_driver(i, n, t, session_id)?);
        self.drain_outbox()
    }

    pub fn process_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        let wire: EcdsaWireMsg = serde_json::from_slice(&msg.payload)
            .map_err(|e| MpcError::ProtocolError(format!("deserialize wire: {e}")))?;
        let driver = self
            .driver
            .as_mut()
            .ok_or_else(|| MpcError::ProtocolError("driver not initialized".into()))?;
        driver.feed(wire.from - 1, wire.is_broadcast, &wire.payload)?;
        self.drain_outbox()
    }

    fn drain_outbox(&mut self) -> Result<Vec<MpcMessage>, MpcError> {
        let mut messages = Vec::new();
        loop {
            let driver = self
                .driver
                .as_mut()
                .ok_or_else(|| MpcError::ProtocolError("driver not initialized".into()))?;
            match driver.drive()? {
                DriverAction::Send { recipient, data } => {
                    let phase = match self.state {
                        EcdsaDkgState::KeygenRunning => EcdsaPhase::Keygen,
                        EcdsaDkgState::AuxInfoRunning => EcdsaPhase::AuxInfo,
                        EcdsaDkgState::Complete => unreachable!(),
                    };
                    let wire = EcdsaWireMsg {
                        from: self.config.party_index,
                        phase,
                        is_broadcast: recipient.is_none(),
                        payload: data,
                    };
                    let payload = serde_json::to_vec(&wire)
                        .map_err(|e| MpcError::ProtocolError(format!("serialize wire: {e}")))?;
                    self.emit_messages(&mut messages, recipient, payload);
                }
                DriverAction::NeedMessage => break,
                DriverAction::Complete(output_bytes) => {
                    self.handle_phase_complete(output_bytes)?;
                    if self.state == EcdsaDkgState::Complete {
                        break;
                    }
                    continue;
                }
            }
        }
        Ok(messages)
    }

    fn emit_messages(
        &self,
        messages: &mut Vec<MpcMessage>,
        recipient: Option<u16>,
        payload: Vec<u8>,
    ) {
        match recipient {
            None => {
                for i in 1..=self.config.total_parties {
                    if i != self.config.party_index {
                        messages.push(MpcMessage {
                            from: self.config.party_index,
                            to: i,
                            round: 0,
                            session_id: self.session_id.clone(),
                            payload: payload.clone(),
                        });
                    }
                }
            }
            Some(r) => {
                messages.push(MpcMessage {
                    from: self.config.party_index,
                    to: r + 1, // convert 0-based back to 1-based
                    round: 0,
                    session_id: self.session_id.clone(),
                    payload,
                });
            }
        }
    }

    fn handle_phase_complete(&mut self, output_bytes: Vec<u8>) -> Result<(), MpcError> {
        match self.state {
            EcdsaDkgState::KeygenRunning => {
                self.incomplete_key_share_bytes = Some(output_bytes);
                let i = self.config.party_index - 1;
                let n = self.config.total_parties;
                self.driver = Some(make_auxinfo_driver(i, n, &self.session_id)?);
                self.state = EcdsaDkgState::AuxInfoRunning;
                tracing::info!(
                    party = self.config.party_index,
                    "keygen done, starting auxinfo"
                );
                Ok(())
            }
            EcdsaDkgState::AuxInfoRunning => {
                let incomplete_bytes = self
                    .incomplete_key_share_bytes
                    .take()
                    .ok_or_else(|| MpcError::KeygenFailed("missing keygen result".into()))?;

                let shard_data = serde_json::to_vec(&EcdsaShardData {
                    incomplete_key_share: incomplete_bytes.clone(),
                    aux_info: output_bytes,
                })
                .map_err(|e| MpcError::KeygenFailed(format!("serialize shard: {e}")))?;

                // Extract public key for KeygenResult
                let incomplete: cggmp21::IncompleteKeyShare<Secp256k1> =
                    serde_json::from_slice(&incomplete_bytes)
                        .map_err(|e| MpcError::KeygenFailed(format!("deserialize keygen: {e}")))?;

                // Convert to raw SEC1 uncompressed bytes (65 bytes: 0x04 || X || Y)
                let pk_point: Point<Secp256k1> = incomplete.shared_public_key.into();
                let pk_bytes = pk_point.as_raw().to_bytes_uncompressed().as_ref().to_vec();

                self.result = Some(KeygenResult {
                    public_key: pk_bytes,
                    shard_data,
                    party_index: self.config.party_index,
                    threshold: self.config.threshold,
                    total_parties: self.config.total_parties,
                });
                self.state = EcdsaDkgState::Complete;
                tracing::info!(party = self.config.party_index, "ECDSA DKG complete");
                Ok(())
            }
            EcdsaDkgState::Complete => Err(MpcError::SessionError("DKG already complete".into())),
        }
    }

    pub fn result(&self) -> Option<KeygenResult> {
        self.result.clone()
    }

    pub fn is_complete(&self) -> bool {
        self.state == EcdsaDkgState::Complete
    }
}

// =============================================================================
// ECDSA Signing Session
// =============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EcdsaSignState {
    Running,
    Complete,
}

pub struct EcdsaSigningSession {
    config: HorcruxConfig,
    session_id: String,
    state: EcdsaSignState,
    driver: Option<Box<dyn AnyDriver>>,
    group_public_key: NonZero<Point<Secp256k1>>,
    message_hash: Vec<u8>,
    result: Option<SigningResult>,
    // Deferred driver creation data
    our_signing_index: u16,
    parties_at_keygen: Vec<u16>,
    key_share: cggmp21::KeyShare<Secp256k1, SecurityLevel128>,
}

impl std::fmt::Debug for EcdsaSigningSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EcdsaSigningSession")
            .field("session_id", &self.session_id)
            .field("state", &self.state)
            .finish()
    }
}

impl EcdsaSigningSession {
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

        let shard: EcdsaShardData = serde_json::from_slice(&shard_data)
            .map_err(|e| MpcError::SigningFailed(format!("deserialize shard: {e}")))?;

        let incomplete: cggmp21::IncompleteKeyShare<Secp256k1> =
            serde_json::from_slice(&shard.incomplete_key_share)
                .map_err(|e| MpcError::SigningFailed(format!("deserialize keygen: {e}")))?;

        let aux_info: cggmp21::key_share::AuxInfo<SecurityLevel128> =
            serde_json::from_slice(&shard.aux_info)
                .map_err(|e| MpcError::SigningFailed(format!("deserialize aux_info: {e}")))?;

        let group_public_key = incomplete.shared_public_key;

        let key_share = cggmp21::KeyShare::from_parts((incomplete, aux_info))
            .map_err(|e| MpcError::SigningFailed(format!("combine key share: {e}")))?;

        let parties_at_keygen: Vec<u16> = participants.iter().map(|&p| p - 1).collect();
        let our_signing_index = participants
            .iter()
            .position(|&p| p == config.party_index)
            .ok_or_else(|| MpcError::InvalidConfig("our party not in participants".into()))?
            as u16;

        Ok(Self {
            config,
            session_id: String::new(),
            state: EcdsaSignState::Running,
            driver: None,
            group_public_key,
            message_hash,
            result: None,
            our_signing_index,
            parties_at_keygen,
            key_share,
        })
    }

    pub fn start(&mut self, session_id: &str) -> Result<Vec<MpcMessage>, MpcError> {
        self.session_id = session_id.to_string();
        self.driver = Some(make_signing_driver(
            self.our_signing_index,
            &self.parties_at_keygen,
            &self.key_share,
            &self.message_hash,
            session_id,
        )?);
        self.drain_outbox()
    }

    pub fn process_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        let wire: EcdsaWireMsg = serde_json::from_slice(&msg.payload)
            .map_err(|e| MpcError::ProtocolError(format!("deserialize wire: {e}")))?;
        let driver = self
            .driver
            .as_mut()
            .ok_or_else(|| MpcError::ProtocolError("signing driver not initialized".into()))?;
        driver.feed(wire.from - 1, wire.is_broadcast, &wire.payload)?;
        self.drain_outbox()
    }

    fn drain_outbox(&mut self) -> Result<Vec<MpcMessage>, MpcError> {
        let mut messages = Vec::new();
        loop {
            let driver = self
                .driver
                .as_mut()
                .ok_or_else(|| MpcError::ProtocolError("signing driver not initialized".into()))?;
            match driver.drive()? {
                DriverAction::Send { recipient, data } => {
                    let wire = EcdsaWireMsg {
                        from: self.config.party_index,
                        phase: EcdsaPhase::Signing,
                        is_broadcast: recipient.is_none(),
                        payload: data,
                    };
                    let payload = serde_json::to_vec(&wire)
                        .map_err(|e| MpcError::ProtocolError(format!("serialize wire: {e}")))?;

                    match recipient {
                        None => {
                            for i in 1..=self.config.total_parties {
                                if i != self.config.party_index {
                                    messages.push(MpcMessage {
                                        from: self.config.party_index,
                                        to: i,
                                        round: 0,
                                        session_id: self.session_id.clone(),
                                        payload: payload.clone(),
                                    });
                                }
                            }
                        }
                        Some(r) => {
                            messages.push(MpcMessage {
                                from: self.config.party_index,
                                to: r + 1,
                                round: 0,
                                session_id: self.session_id.clone(),
                                payload,
                            });
                        }
                    }
                }
                DriverAction::NeedMessage => break,
                DriverAction::Complete(output_bytes) => {
                    self.finalize_signature(output_bytes)?;
                    break;
                }
            }
        }
        Ok(messages)
    }

    fn finalize_signature(&mut self, output_bytes: Vec<u8>) -> Result<(), MpcError> {
        let signature: cggmp21::Signature<Secp256k1> = serde_json::from_slice(&output_bytes)
            .map_err(|e| MpcError::SigningFailed(format!("deserialize sig: {e}")))?;

        let r_bytes = scalar_to_bytes(&signature.r);
        let s_bytes = scalar_to_bytes(&signature.s);

        let recovery_id = compute_recovery_id(
            &self.group_public_key,
            &r_bytes,
            &s_bytes,
            &self.message_hash,
        );

        let mut sig_bytes = Vec::with_capacity(64);
        sig_bytes.extend_from_slice(&r_bytes);
        sig_bytes.extend_from_slice(&s_bytes);

        self.result = Some(SigningResult {
            signature: sig_bytes,
            r: r_bytes.to_vec(),
            s: s_bytes.to_vec(),
            recovery_id: Some(recovery_id),
        });
        self.state = EcdsaSignState::Complete;
        tracing::info!(
            party = self.config.party_index,
            recovery_id,
            "ECDSA signing complete"
        );
        Ok(())
    }

    pub fn result(&self) -> Option<SigningResult> {
        self.result.clone()
    }

    pub fn is_complete(&self) -> bool {
        self.state == EcdsaSignState::Complete
    }
}

// =============================================================================
// Recovery ID
// =============================================================================

fn compute_recovery_id(
    public_key: &NonZero<Point<Secp256k1>>,
    r_bytes: &[u8; 32],
    s_bytes: &[u8; 32],
    message_hash: &[u8],
) -> u8 {
    use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};

    let r_fb = k256::FieldBytes::clone_from_slice(r_bytes);
    let s_fb = k256::FieldBytes::clone_from_slice(s_bytes);

    let sig = match Signature::from_scalars(r_fb, s_fb) {
        Ok(s) => s,
        Err(_) => return 0,
    };

    let mut hash = [0u8; 32];
    let len = message_hash.len().min(32);
    hash[32 - len..].copy_from_slice(&message_hash[..len]);

    // Serialize group public key for comparison
    let pk_json = match serde_json::to_string(public_key) {
        Ok(j) => j,
        Err(e) => {
            tracing::error!("failed to serialize public key: {e}");
            return 0;
        }
    };

    for v in 0u8..=1 {
        let recid = RecoveryId::new(v != 0, false);
        if let Ok(recovered) = VerifyingKey::recover_from_prehash(&hash, &sig, recid) {
            let compressed = recovered.to_encoded_point(true);
            let hex_compressed = hex::encode(compressed.as_bytes());
            if pk_json.contains(&hex_compressed) {
                return v;
            }
        }
    }

    tracing::warn!("recovery_id fell through, defaulting to 0");
    0
}

fn scalar_to_bytes(s: &NonZero<Scalar<Secp256k1>>) -> [u8; 32] {
    let bytes = s.to_be_bytes();
    let mut out = [0u8; 32];
    let slice: &[u8] = bytes.as_ref();
    let len = slice.len().min(32);
    out[32 - len..].copy_from_slice(&slice[..len]);
    out
}

#[allow(dead_code)]
fn uuid_v4() -> String {
    let mut bytes = [0u8; 16];
    rand::RngCore::fill_bytes(&mut OsRng, &mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
        u16::from_be_bytes([bytes[4], bytes[5]]),
        u16::from_be_bytes([bytes[6], bytes[7]]),
        u16::from_be_bytes([bytes[8], bytes[9]]),
        u64::from_be_bytes([
            0, 0, bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ])
    )
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mpc::CurveType;

    #[test]
    fn test_uuid_v4_format() {
        let id = uuid_v4();
        assert_eq!(id.len(), 36);
        assert_eq!(id.chars().filter(|&c| c == '-').count(), 4);
        assert_eq!(id.chars().nth(14).unwrap(), '4');
    }

    #[test]
    fn test_ecdsa_dkg_creation() {
        let config = HorcruxConfig::new(2, 3, 1, CurveType::Secp256k1).unwrap();
        let session = EcdsaDkgSession::new(config);
        assert!(session.is_ok());
    }

    #[test]
    fn test_ecdsa_wire_msg_serialization() {
        let wire = EcdsaWireMsg {
            from: 1,
            phase: EcdsaPhase::Keygen,
            is_broadcast: true,
            payload: vec![1, 2, 3],
        };
        let bytes = serde_json::to_vec(&wire).unwrap();
        let decoded: EcdsaWireMsg = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(decoded.from, 1);
        assert_eq!(decoded.phase, EcdsaPhase::Keygen);
        assert!(decoded.is_broadcast);
    }

    #[test]
    fn test_ecdsa_shard_data_serialization() {
        let shard = EcdsaShardData {
            incomplete_key_share: vec![10, 20, 30],
            aux_info: vec![40, 50, 60],
        };
        let bytes = serde_json::to_vec(&shard).unwrap();
        let decoded: EcdsaShardData = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(decoded.incomplete_key_share, vec![10, 20, 30]);
        assert_eq!(decoded.aux_info, vec![40, 50, 60]);
    }

    #[test]
    fn test_scalar_to_bytes() {
        let one = Scalar::<Secp256k1>::from(1u64);
        if let Some(nz) = NonZero::from_scalar(one) {
            let bytes = scalar_to_bytes(&nz);
            assert_eq!(bytes[31], 1);
            assert_eq!(bytes[0], 0);
        }
    }
}
