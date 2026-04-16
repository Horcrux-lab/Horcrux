//! Transport layer — message protocol definitions and E2E encryption
//! for all communication channels.
//!
//! This defines the wire protocol used across BLE, Wi-Fi Direct, Wi-Fi LAN,
//! QR code, and Relay WebSocket channels.

pub mod e2e;
pub mod protocol;
