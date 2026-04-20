//! CGGMP21 proactive key refresh — Phase A.
//!
//! Re-randomises every party's share of the same threshold key while keeping
//! the **group public key (wallet address) unchanged**. Used to defend against
//! gradual share leakage and to recover after a single device may have been
//! compromised, without resorting to a full migration.
//!
//! Constraints (CGGMP21 v0.6.3):
//! - Only valid for non-threshold (n-of-n) shares. Horcrux 2-of-2 wallets fit.
//! - For general t-of-n, upstream key_refresh would need patching (Phase B).
//!
//! After completion the resulting `KeyShare` is split back into
//! `IncompleteKeyShare` + `AuxInfo` and packaged into the same
//! `EcdsaShardData` envelope used by the rest of the codebase, so existing
//! signing / reload paths keep working unchanged.

use super::ecdsa::{AnyDriver, DriverAction, EcdsaPhase, EcdsaShardData, EcdsaWireMsg, SmDriver};
use super::types::{KeygenResult, MpcMessage};
use super::{HorcruxConfig, MpcError};

use cggmp21::key_share::{AuxInfo, DirtyKeyShare, IncompleteKeyShare};
use cggmp21::security_level::SecurityLevel128;
use cggmp21::supported_curves::Secp256k1;
use cggmp21::{ExecutionId, KeyShare};
use generic_ec::as_raw::AsRaw;
use generic_ec::core::UncompressedEncoding;
use generic_ec::{NonZero, Point};
use rand::rngs::OsRng;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EcdsaRefreshState {
    Running,
    Complete,
}

/// State machine wrapper for a single refresh ceremony.
pub struct EcdsaRefreshSession {
    config: HorcruxConfig,
    session_id: String,
    state: EcdsaRefreshState,
    driver: Option<Box<dyn AnyDriver>>,
    /// Public key of the input shard. The output shard MUST match this exactly;
    /// if not we abort to prevent silent address rotation.
    old_public_key: NonZero<Point<Secp256k1>>,
    /// Held until `start()` builds the driver.
    pending_key_share: Option<KeyShare<Secp256k1, SecurityLevel128>>,
    result: Option<KeygenResult>,
}

impl std::fmt::Debug for EcdsaRefreshSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EcdsaRefreshSession")
            .field("session_id", &self.session_id)
            .field("state", &self.state)
            .finish()
    }
}

fn make_refresh_driver(
    key_share: &KeyShare<Secp256k1, SecurityLevel128>,
    session_id: &str,
) -> Result<Box<dyn AnyDriver>, MpcError> {
    let eid_bytes: &'static [u8] = Box::leak(
        format!("horcrux-refresh-{}", session_id)
            .into_bytes()
            .into_boxed_slice(),
    );
    let eid = ExecutionId::new(eid_bytes);

    // Pregenerated primes are required by CGGMP21 — generation dominates wall
    // time (typically several seconds on mobile). We prefer the pool when it
    // has stock; otherwise we mint fresh ones synchronously. Pool entries are
    // always single-use, so a captured blob cannot be replayed.
    let pregen = super::prime_pool::take_or_generate();
    let proto_rng: &'static mut OsRng = Box::leak(Box::new(OsRng));
    let ks: &'static KeyShare<Secp256k1, SecurityLevel128> = Box::leak(Box::new(key_share.clone()));

    let sm = cggmp21::key_refresh(eid, ks, pregen).into_state_machine(proto_rng);

    Ok(Box::new(SmDriver { sm }))
}

impl EcdsaRefreshSession {
    pub fn new(config: HorcruxConfig, shard_data: Vec<u8>) -> Result<Self, MpcError> {
        let shard: EcdsaShardData = serde_json::from_slice(&shard_data)
            .map_err(|e| MpcError::InvalidConfig(format!("deserialize shard: {e}")))?;

        let incomplete: IncompleteKeyShare<Secp256k1> =
            serde_json::from_slice(&shard.incomplete_key_share)
                .map_err(|e| MpcError::InvalidConfig(format!("deserialize keygen: {e}")))?;

        let aux_info: AuxInfo<SecurityLevel128> = serde_json::from_slice(&shard.aux_info)
            .map_err(|e| MpcError::InvalidConfig(format!("deserialize aux_info: {e}")))?;

        // cggmp21 v0.6 `key_refresh` is only sound for additive (non-VSS)
        // shares — see horcrux-core/src/mpc/ecdsa.rs::make_keygen_driver for
        // the detailed rationale. Refuse up-front instead of running a
        // ceremony that will abort on the final invariant check with a
        // "public_shares.sum() != shared_public_key" error.
        if incomplete.vss_setup.is_some() {
            return Err(MpcError::InvalidConfig(
                "refresh not supported for legacy VSS key share: this wallet was created before \
                 proactive share rotation was available. Recreate the wallet to enable refresh."
                    .into(),
            ));
        }

        let old_public_key = incomplete.shared_public_key;

        let key_share = KeyShare::from_parts((incomplete, aux_info))
            .map_err(|e| MpcError::InvalidConfig(format!("combine key share: {e}")))?;

        Ok(Self {
            config,
            session_id: String::new(),
            state: EcdsaRefreshState::Running,
            driver: None,
            old_public_key,
            pending_key_share: Some(key_share),
            result: None,
        })
    }

    pub fn start(&mut self, session_id: &str) -> Result<Vec<MpcMessage>, MpcError> {
        self.session_id = session_id.to_string();
        let key_share = self
            .pending_key_share
            .take()
            .ok_or_else(|| MpcError::ProtocolError("refresh already started".into()))?;
        self.driver = Some(make_refresh_driver(&key_share, session_id)?);
        self.drain_outbox()
    }

    pub fn process_message(&mut self, msg: MpcMessage) -> Result<Vec<MpcMessage>, MpcError> {
        let wire: EcdsaWireMsg = serde_json::from_slice(&msg.payload)
            .map_err(|e| MpcError::ProtocolError(format!("deserialize wire: {e}")))?;
        if wire.phase != EcdsaPhase::Refresh {
            return Err(MpcError::ProtocolError(format!(
                "expected refresh phase, got {:?}",
                wire.phase
            )));
        }
        let driver = self
            .driver
            .as_mut()
            .ok_or_else(|| MpcError::ProtocolError("refresh driver not initialized".into()))?;
        driver.feed(wire.from - 1, wire.is_broadcast, &wire.payload)?;
        self.drain_outbox()
    }

    fn drain_outbox(&mut self) -> Result<Vec<MpcMessage>, MpcError> {
        let mut messages = Vec::new();
        loop {
            let driver = self
                .driver
                .as_mut()
                .ok_or_else(|| MpcError::ProtocolError("refresh driver not initialized".into()))?;
            match driver.drive()? {
                DriverAction::Send { recipient, data } => {
                    let wire = EcdsaWireMsg {
                        from: self.config.party_index,
                        phase: EcdsaPhase::Refresh,
                        is_broadcast: recipient.is_none(),
                        payload: data,
                    };
                    let payload = serde_json::to_vec(&wire)
                        .map_err(|e| MpcError::ProtocolError(format!("serialize wire: {e}")))?;
                    self.emit_messages(&mut messages, recipient, payload);
                }
                DriverAction::NeedMessage => break,
                DriverAction::Complete(output_bytes) => {
                    self.handle_complete(output_bytes)?;
                    break;
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
                    to: r + 1,
                    round: 0,
                    session_id: self.session_id.clone(),
                    payload,
                });
            }
        }
    }

    fn handle_complete(&mut self, output_bytes: Vec<u8>) -> Result<(), MpcError> {
        // Driver output is a fully-serialised new KeyShare.
        let new_key_share: KeyShare<Secp256k1, SecurityLevel128> =
            serde_json::from_slice(&output_bytes)
                .map_err(|e| MpcError::ProtocolError(format!("deserialize new keyshare: {e}")))?;

        // Critical invariant: refresh must NEVER change the wallet address.
        if new_key_share.shared_public_key != self.old_public_key {
            return Err(MpcError::ProtocolError(
                "refresh produced different group public key — aborting".into(),
            ));
        }

        // Split back into the (IncompleteKeyShare, AuxInfo) envelope used by
        // the rest of the codebase. Wrap the dirty halves in `Valid<_>` so the
        // existing reload path (which deserialises them as `Valid<_>`) works.
        let dirty: DirtyKeyShare<Secp256k1, SecurityLevel128> = new_key_share.into_inner();
        let DirtyKeyShare { core, aux } = dirty;

        let incomplete_valid = IncompleteKeyShare::<Secp256k1>::validate(core)
            .map_err(|e| MpcError::ProtocolError(format!("revalidate core: {e}")))?;
        let aux_valid = AuxInfo::<SecurityLevel128>::validate(aux)
            .map_err(|e| MpcError::ProtocolError(format!("revalidate aux: {e}")))?;

        let incomplete_bytes = serde_json::to_vec(&incomplete_valid)
            .map_err(|e| MpcError::ProtocolError(format!("serialize new core: {e}")))?;
        let aux_bytes = serde_json::to_vec(&aux_valid)
            .map_err(|e| MpcError::ProtocolError(format!("serialize new aux: {e}")))?;

        let shard_data = serde_json::to_vec(&EcdsaShardData {
            incomplete_key_share: incomplete_bytes,
            aux_info: aux_bytes,
        })
        .map_err(|e| MpcError::ProtocolError(format!("serialize shard: {e}")))?;

        let pk_bytes = self
            .old_public_key
            .as_raw()
            .to_bytes_uncompressed()
            .as_ref()
            .to_vec();

        self.result = Some(KeygenResult {
            public_key: pk_bytes,
            shard_data,
            party_index: self.config.party_index,
            threshold: self.config.threshold,
            total_parties: self.config.total_parties,
        });
        self.state = EcdsaRefreshState::Complete;
        tracing::info!(
            party = self.config.party_index,
            "ECDSA refresh complete (group pk preserved)"
        );
        Ok(())
    }

    pub fn result(&self) -> Option<KeygenResult> {
        self.result.clone()
    }

    pub fn is_complete(&self) -> bool {
        self.state == EcdsaRefreshState::Complete
    }
}
