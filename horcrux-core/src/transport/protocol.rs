//! Wire protocol for Horcrux inter-device communication.
//!
//! All channels (BLE, Wi-Fi Direct, Wi-Fi LAN, QR, Relay) use the same
//! envelope format. The payload is always E2E encrypted.

use serde::{Deserialize, Serialize};

/// Top-level envelope for all Horcrux messages.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Envelope {
    /// Protocol version
    pub version: u8,
    /// Message type
    pub msg_type: MessageType,
    /// Sender device ID
    pub sender_id: String,
    /// E2E encrypted payload (only the recipient can decrypt)
    pub payload: Vec<u8>,
    /// Ephemeral public key for X25519 key exchange (if needed)
    pub ephemeral_pubkey: Option<Vec<u8>>,
    /// Message sequence number (for ordering)
    pub seq: u64,
}

/// Types of messages in the Horcrux protocol.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MessageType {
    /// Discovery / handshake
    Hello,
    /// DKG protocol message
    Dkg,
    /// Signing protocol message
    Sign,
    /// Shard refresh protocol message
    Refresh,
    /// Session control (join, leave, abort)
    Control,
    /// Acknowledgement
    Ack,
}

/// Control messages for session management.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ControlMessage {
    /// Request to join a session
    JoinRequest { session_id: String, party_index: u16 },
    /// Confirmation of joining
    JoinAccept { session_id: String },
    /// Leave a session
    Leave { session_id: String },
    /// Abort a session (with reason)
    Abort { session_id: String, reason: String },
}

/// Channel type indicator.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ChannelType {
    /// Bluetooth Low Energy
    Ble,
    /// Wi-Fi Direct (P2P, no router)
    WifiDirect,
    /// Wi-Fi LAN (same network, mDNS discovery)
    WifiLan,
    /// QR code (animated fountain code for large data)
    QrCode,
    /// Relay WebSocket (remote, E2E encrypted)
    Relay,
}

impl Envelope {
    pub fn new(msg_type: MessageType, sender_id: String, payload: Vec<u8>) -> Self {
        Self {
            version: 1,
            msg_type,
            sender_id,
            payload,
            ephemeral_pubkey: None,
            seq: 0,
        }
    }
}
