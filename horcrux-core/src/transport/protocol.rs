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
    JoinRequest {
        session_id: String,
        party_index: u16,
    },
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn envelope_roundtrip_json() {
        let env = Envelope::new(MessageType::Dkg, "device-1".into(), vec![0xDE, 0xAD]);
        let json = serde_json::to_string(&env).unwrap();
        let decoded: Envelope = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.version, 1);
        assert_eq!(decoded.msg_type, MessageType::Dkg);
        assert_eq!(decoded.sender_id, "device-1");
        assert_eq!(decoded.payload, vec![0xDE, 0xAD]);
        assert_eq!(decoded.seq, 0);
        assert!(decoded.ephemeral_pubkey.is_none());
    }

    #[test]
    fn envelope_with_ephemeral_key() {
        let mut env = Envelope::new(MessageType::Hello, "device-2".into(), vec![1, 2, 3]);
        env.ephemeral_pubkey = Some(vec![0xAA; 32]);
        env.seq = 42;
        let json = serde_json::to_string(&env).unwrap();
        let decoded: Envelope = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.ephemeral_pubkey.unwrap().len(), 32);
        assert_eq!(decoded.seq, 42);
    }

    #[test]
    fn all_message_types_serialize() {
        let types = [
            MessageType::Hello,
            MessageType::Dkg,
            MessageType::Sign,
            MessageType::Refresh,
            MessageType::Control,
            MessageType::Ack,
        ];
        for mt in types {
            let json = serde_json::to_string(&mt).unwrap();
            let decoded: MessageType = serde_json::from_str(&json).unwrap();
            assert_eq!(decoded, mt);
        }
    }

    #[test]
    fn control_message_roundtrip() {
        let msgs = vec![
            ControlMessage::JoinRequest {
                session_id: "sess-1".into(),
                party_index: 2,
            },
            ControlMessage::JoinAccept {
                session_id: "sess-1".into(),
            },
            ControlMessage::Leave {
                session_id: "sess-1".into(),
            },
            ControlMessage::Abort {
                session_id: "sess-1".into(),
                reason: "timeout".into(),
            },
        ];
        for msg in &msgs {
            let json = serde_json::to_string(msg).unwrap();
            let decoded: ControlMessage = serde_json::from_str(&json).unwrap();
            let re_json = serde_json::to_string(&decoded).unwrap();
            assert_eq!(json, re_json);
        }
    }

    #[test]
    fn all_channel_types_serialize() {
        let types = [
            ChannelType::Ble,
            ChannelType::WifiDirect,
            ChannelType::WifiLan,
            ChannelType::QrCode,
            ChannelType::Relay,
        ];
        for ct in types {
            let json = serde_json::to_string(&ct).unwrap();
            let decoded: ChannelType = serde_json::from_str(&json).unwrap();
            assert_eq!(decoded, ct);
        }
    }

    #[test]
    fn envelope_empty_payload() {
        let env = Envelope::new(MessageType::Ack, "d3".into(), vec![]);
        let json = serde_json::to_string(&env).unwrap();
        let decoded: Envelope = serde_json::from_str(&json).unwrap();
        assert!(decoded.payload.is_empty());
    }
}
