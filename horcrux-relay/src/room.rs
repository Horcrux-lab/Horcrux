//! Room management — tracks connected participants per session.
//!
//! Rooms are access-controlled with token hashes. The RoomManager uses
//! a read-write lock at the map level but per-room mutations (touch, join,
//! leave) only require brief write locks, minimizing contention.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, AtomicU64, Ordering};
use std::time::Duration;
use sha2::{Sha256, Digest};
use tokio::sync::{broadcast, RwLock, Mutex};

use crate::config::RelayConfig;
use crate::metrics::METRICS;

/// Shared state across all WebSocket connections.
pub type RoomManager = Arc<RoomManagerInner>;

pub fn new(config: &RelayConfig) -> RoomManager {
    Arc::new(RoomManagerInner::new(config))
}

/// Spawns a background task that periodically removes expired rooms.
pub fn spawn_cleanup_task(manager: RoomManager) -> tokio::task::JoinHandle<()> {
    let interval_dur = manager.cleanup_interval;
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(interval_dur);
        loop {
            interval.tick().await;
            let removed = manager.cleanup_expired().await;
            if removed > 0 {
                tracing::info!(removed, "expired rooms cleaned up");
            }
        }
    })
}

pub struct RoomManagerInner {
    rooms: RwLock<HashMap<String, Room>>,
    ttl: Duration,
    cleanup_interval: Duration,
    max_participants: usize,
}

struct Room {
    /// Broadcast channel for this room
    tx: broadcast::Sender<RoomMessage>,
    /// Connected participant count (atomic for lock-free reads)
    participant_count: AtomicUsize,
    /// Last activity epoch in millis (atomic for lock-free touch)
    last_activity_ms: AtomicU64,
    /// SHA-256 hash of access token (None = legacy open room for tests)
    token_hash: Option<[u8; 32]>,
    /// Set of connected device IDs (for unicast routing)
    devices: Mutex<Vec<String>>,
    /// Per-device sequence tracking for replay protection
    device_sequences: Mutex<HashMap<String, u64>>,
}

impl Room {
    /// Verify token and join an existing room. Returns sender/receiver on success.
    /// Uses atomic compare-exchange for participant count to prevent TOCTOU races.
    async fn try_join(
        &self,
        token: Option<&str>,
        device_id: &str,
        max_participants: usize,
    ) -> Result<(broadcast::Sender<RoomMessage>, broadcast::Receiver<RoomMessage>), RoomError> {
        // Verify access token
        if let Some(ref stored_hash) = self.token_hash {
            let provided_hash = token.map(RoomManagerInner::hash_token);
            match provided_hash {
                Some(h) if constant_time_eq(&h, stored_hash) => {}
                _ => {
                    METRICS.auth_failures.fetch_add(1, Ordering::Relaxed);
                    return Err(RoomError::InvalidToken);
                }
            }
        }

        // Atomic CAS loop: increment participant count only if under limit.
        loop {
            let current = self.participant_count.load(Ordering::Acquire);
            if current >= max_participants {
                return Err(RoomError::RoomFull);
            }
            if self.participant_count.compare_exchange(
                current,
                current + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ).is_ok() {
                break;
            }
            // CAS failed — another thread modified count, retry.
        }

        // Count is now incremented. Check device uniqueness and rollback on failure.
        if !device_id.is_empty() {
            let mut devs = self.devices.lock().await;
            if devs.iter().any(|d| d == device_id) {
                self.participant_count.fetch_sub(1, Ordering::AcqRel);
                return Err(RoomError::DuplicateDevice);
            }
            // Belt-and-suspenders: ensure devices vec matches the atomic count.
            if devs.len() >= max_participants {
                self.participant_count.fetch_sub(1, Ordering::AcqRel);
                return Err(RoomError::RoomFull);
            }
            devs.push(device_id.to_string());
        }

        self.touch();
        let rx = self.tx.subscribe();

        Ok((self.tx.clone(), rx))
    }

    fn touch(&self) {
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        self.last_activity_ms.store(now_ms, Ordering::Relaxed);
    }

    fn is_expired(&self, ttl: Duration) -> bool {
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        let last = self.last_activity_ms.load(Ordering::Relaxed);
        now_ms.saturating_sub(last) > ttl.as_millis() as u64
    }

    /// Check and advance sequence counter for replay protection.
    /// Returns true if the message is valid (seq > last seen), false if replayed.
    async fn check_sequence(&self, device_id: &str, seq: u64) -> bool {
        if device_id.is_empty() { return true; }
        let mut seqs = self.device_sequences.lock().await;
        let last = seqs.entry(device_id.to_string()).or_insert(0);
        if seq > *last {
            *last = seq;
            true
        } else {
            false
        }
    }
}

/// A message relayed within a room.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RoomMessage {
    /// Sender identifier
    pub from: String,
    /// Target recipient (empty = broadcast to room)
    pub to: String,
    /// Opaque E2E encrypted payload (relay cannot read this)
    pub payload: String,
    /// Message sequence number
    pub seq: u64,
}

/// Error returned when room access is denied.
#[derive(Debug, thiserror::Error)]
pub enum RoomError {
    #[error("invalid access token")]
    InvalidToken,
    #[error("room is full")]
    RoomFull,
    #[error("device_id already connected to this room")]
    DuplicateDevice,
}

impl RoomManagerInner {
    pub fn new(config: &RelayConfig) -> Self {
        Self {
            rooms: RwLock::new(HashMap::new()),
            ttl: config.room_ttl,
            cleanup_interval: config.cleanup_interval,
            max_participants: config.max_participants,
        }
    }

    fn hash_token(token: &str) -> [u8; 32] {
        let mut hasher = Sha256::new();
        hasher.update(token.as_bytes());
        hasher.finalize().into()
    }

    /// Join (or create) a room with access token verification.
    pub async fn join_room_with_token(
        &self,
        room_id: &str,
        token: Option<&str>,
        device_id: &str,
    ) -> Result<(broadcast::Sender<RoomMessage>, broadcast::Receiver<RoomMessage>), RoomError> {
        // First try with a read lock (common case: room exists)
        {
            let rooms = self.rooms.read().await;
            if let Some(room) = rooms.get(room_id) {
                let result = room.try_join(token, device_id, self.max_participants).await?;
                let count = room.participant_count.load(Ordering::Relaxed);
                tracing::info!(room = room_id, participants = count, "participant joined");
                return Ok(result);
            }
        }

        // Room doesn't exist — upgrade to write lock and create
        let mut rooms = self.rooms.write().await;
        // Double-check after acquiring write lock
        if let Some(room) = rooms.get(room_id) {
            return room.try_join(token, device_id, self.max_participants).await;
        }

        let (tx, rx) = broadcast::channel(256);
        let token_hash = token.map(Self::hash_token);
        let initial_devices = if device_id.is_empty() {
            vec![]
        } else {
            vec![device_id.to_string()]
        };
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;

        rooms.insert(
            room_id.to_string(),
            Room {
                tx: tx.clone(),
                participant_count: AtomicUsize::new(1),
                last_activity_ms: AtomicU64::new(now_ms),
                token_hash,
                devices: Mutex::new(initial_devices),
                device_sequences: Mutex::new(HashMap::new()),
            },
        );
        METRICS.rooms_created.fetch_add(1, Ordering::Relaxed);
        tracing::info!(room = room_id, secured = token.is_some(), "new room created");
        Ok((tx, rx))
    }

    /// Legacy: join without token (for backward-compatible tests).
    #[cfg(test)]
    pub async fn join_room(
        &self,
        room_id: &str,
    ) -> (broadcast::Sender<RoomMessage>, broadcast::Receiver<RoomMessage>) {
        self.join_room_with_token(room_id, None, "").await
            .expect("join_room without token should not fail on new room")
    }

    /// Leave a room. Removes the room if no participants remain.
    pub async fn leave_room(&self, room_id: &str, device_id: &str) {
        let mut rooms = self.rooms.write().await;
        let should_remove = if let Some(room) = rooms.get(room_id) {
            // Bounds check: prevent underflow below zero.
            let prev = room.participant_count.load(Ordering::Acquire);
            if prev == 0 {
                tracing::warn!(room = room_id, "leave_room called on room with 0 participants");
                true // Remove stale room
            } else {
                room.participant_count.fetch_sub(1, Ordering::AcqRel);
                if !device_id.is_empty() {
                    let mut devs = room.devices.lock().await;
                    if let Some(pos) = devs.iter().position(|d| d == device_id) {
                        devs.swap_remove(pos);
                    }
                }
                if prev == 1 {
                    tracing::info!(room = room_id, "last participant left");
                    true
                } else {
                    tracing::info!(room = room_id, participants = prev - 1, "participant left");
                    false
                }
            }
        } else {
            return;
        };

        if should_remove {
            rooms.remove(room_id);
            tracing::info!(room = room_id, "room removed (empty)");
        }
    }

    /// Touch activity timestamp for a room. Lock-free — uses atomic store.
    pub async fn touch(&self, room_id: &str) {
        let rooms = self.rooms.read().await;
        if let Some(room) = rooms.get(room_id) {
            room.touch();
        }
    }

    /// Check message sequence for replay protection. Returns false if replayed or room missing.
    pub async fn check_sequence(&self, room_id: &str, device_id: &str, seq: u64) -> bool {
        let rooms = self.rooms.read().await;
        if let Some(room) = rooms.get(room_id) {
            room.check_sequence(device_id, seq).await
        } else {
            false // Room not found — reject message from unknown room
        }
    }

    /// Get active room count.
    pub async fn room_count(&self) -> usize {
        self.rooms.read().await.len()
    }

    /// List active room IDs (admin only — don't expose publicly).
    #[cfg(test)]
    pub async fn room_ids(&self) -> Vec<String> {
        self.rooms.read().await.keys().cloned().collect()
    }

    /// Room stats for admin endpoint.
    pub async fn room_stats(&self) -> Vec<RoomStats> {
        let rooms = self.rooms.read().await;
        rooms.iter().map(|(id, room)| RoomStats {
            room_id: id.clone(),
            participants: room.participant_count.load(Ordering::Relaxed),
            secured: room.token_hash.is_some(),
        }).collect()
    }

    /// Remove rooms that have exceeded their TTL. Returns number removed.
    pub async fn cleanup_expired(&self) -> usize {
        let mut rooms = self.rooms.write().await;
        let before = rooms.len();
        rooms.retain(|id, room| {
            let expired = room.is_expired(self.ttl);
            if expired {
                tracing::info!(room = %id, "room expired");
            }
            !expired
        });
        let removed = before - rooms.len();
        if removed > 0 {
            METRICS.rooms_expired.fetch_add(removed as u64, Ordering::Relaxed);
        }
        removed
    }
}

/// Room statistics for admin endpoint.
#[derive(Debug, serde::Serialize)]
pub struct RoomStats {
    pub room_id: String,
    pub participants: usize,
    pub secured: bool,
}

/// Constant-time comparison to prevent timing attacks on token verification.
fn constant_time_eq(a: &[u8; 32], b: &[u8; 32]) -> bool {
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_config() -> RelayConfig {
        RelayConfig::default()
    }

    fn test_config_ttl(ttl_ms: u64) -> RelayConfig {
        RelayConfig {
            room_ttl: Duration::from_millis(ttl_ms),
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn test_create_and_join_room() {
        let mgr = new(&test_config());
        let (_tx, _rx) = mgr.join_room("room-1").await;
        assert_eq!(mgr.room_count().await, 1);
        assert_eq!(mgr.room_ids().await, vec!["room-1".to_string()]);
    }

    #[tokio::test]
    async fn test_multiple_participants() {
        let mgr = new(&test_config());
        let (_tx1, _rx1) = mgr.join_room("room-1").await;
        let (_tx2, _rx2) = mgr.join_room("room-1").await;
        assert_eq!(mgr.room_count().await, 1);
    }

    #[tokio::test]
    async fn test_leave_room_decrements() {
        let mgr = new(&test_config());
        let (_tx1, _rx1) = mgr.join_room("room-1").await;
        let (_tx2, _rx2) = mgr.join_room("room-1").await;
        mgr.leave_room("room-1", "").await;
        assert_eq!(mgr.room_count().await, 1);
    }

    #[tokio::test]
    async fn test_leave_room_removes_when_empty() {
        let mgr = new(&test_config());
        let (_tx, _rx) = mgr.join_room("room-1").await;
        mgr.leave_room("room-1", "").await;
        assert_eq!(mgr.room_count().await, 0);
    }

    #[tokio::test]
    async fn test_leave_nonexistent_room() {
        let mgr = new(&test_config());
        mgr.leave_room("no-such-room", "").await;
        assert_eq!(mgr.room_count().await, 0);
    }

    #[tokio::test]
    async fn test_multiple_rooms() {
        let mgr = new(&test_config());
        let (_tx1, _rx1) = mgr.join_room("room-a").await;
        let (_tx2, _rx2) = mgr.join_room("room-b").await;
        assert_eq!(mgr.room_count().await, 2);
        let mut ids = mgr.room_ids().await;
        ids.sort();
        assert_eq!(ids, vec!["room-a".to_string(), "room-b".to_string()]);
    }

    #[tokio::test]
    async fn test_room_expiry() {
        let mgr = new(&test_config_ttl(50));
        let (_tx, _rx) = mgr.join_room("ephemeral").await;
        assert_eq!(mgr.room_count().await, 1);

        tokio::time::sleep(Duration::from_millis(100)).await;
        let removed = mgr.cleanup_expired().await;
        assert_eq!(removed, 1);
        assert_eq!(mgr.room_count().await, 0);
    }

    #[tokio::test]
    async fn test_touch_prevents_expiry() {
        let mgr = new(&test_config_ttl(200));
        let (_tx, _rx) = mgr.join_room("active").await;

        tokio::time::sleep(Duration::from_millis(120)).await;
        mgr.touch("active").await;
        tokio::time::sleep(Duration::from_millis(120)).await;

        let removed = mgr.cleanup_expired().await;
        assert_eq!(removed, 0);
        assert_eq!(mgr.room_count().await, 1);
    }

    #[tokio::test]
    async fn test_message_broadcast() {
        let mgr = new(&test_config());
        let (tx, _rx1) = mgr.join_room("chat").await;
        let (_tx2, mut rx2) = mgr.join_room("chat").await;

        let msg = RoomMessage {
            from: "alice".into(),
            to: String::new(),
            payload: "hello".into(),
            seq: 1,
        };
        tx.send(msg.clone()).unwrap();

        let received = rx2.recv().await.unwrap();
        assert_eq!(received.from, "alice");
        assert_eq!(received.payload, "hello");
    }

    // --- Token-gated room tests ---

    #[tokio::test]
    async fn test_token_gated_room_create_and_join() {
        let mgr = new(&test_config());
        let (_tx1, _rx1) = mgr.join_room_with_token("secure-room", Some("secret-token-123"), "d1").await.unwrap();
        assert_eq!(mgr.room_count().await, 1);

        let result = mgr.join_room_with_token("secure-room", Some("secret-token-123"), "d2").await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_token_gated_room_wrong_token_rejected() {
        let mgr = new(&test_config());
        let (_tx, _rx) = mgr.join_room_with_token("secure-room", Some("correct-token"), "d1").await.unwrap();

        let result = mgr.join_room_with_token("secure-room", Some("wrong-token"), "d2").await;
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), RoomError::InvalidToken));
    }

    #[tokio::test]
    async fn test_token_gated_room_no_token_rejected() {
        let mgr = new(&test_config());
        let (_tx, _rx) = mgr.join_room_with_token("secure-room", Some("my-token"), "d1").await.unwrap();

        let result = mgr.join_room_with_token("secure-room", None, "d2").await;
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), RoomError::InvalidToken));
    }

    #[tokio::test]
    async fn test_room_full_rejected() {
        let mut cfg = test_config();
        cfg.max_participants = 3;
        let mgr = new(&cfg);

        for i in 0..3 {
            let r = mgr.join_room_with_token("full-room", Some("tok"), &format!("d{}", i)).await;
            assert!(r.is_ok());
        }

        let result = mgr.join_room_with_token("full-room", Some("tok"), "d99").await;
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), RoomError::RoomFull));
    }

    #[tokio::test]
    async fn test_device_tracking() {
        let mgr = new(&test_config());
        let (_tx, _rx) = mgr.join_room_with_token("dev-room", None, "alice-phone").await.unwrap();
        let (_tx2, _rx2) = mgr.join_room_with_token("dev-room", None, "bob-phone").await.unwrap();

        let stats = mgr.room_stats().await;
        assert_eq!(stats.len(), 1);
        assert_eq!(stats[0].participants, 2);
    }

    #[tokio::test]
    async fn test_touch_is_lockfree_read() {
        // touch() should only need a read lock — this tests it doesn't deadlock
        let mgr = new(&test_config());
        let (_tx, _rx) = mgr.join_room("touch-test").await;

        // Multiple concurrent touches should not block
        let m1 = mgr.clone();
        let m2 = mgr.clone();
        let (r1, r2) = tokio::join!(
            m1.touch("touch-test"),
            m2.touch("touch-test"),
        );
        // If we get here, no deadlock
        let _ = (r1, r2);
    }

    #[tokio::test]
    async fn test_duplicate_device_id_rejected() {
        let mgr = new(&test_config());
        let (_tx, _rx) = mgr.join_room_with_token("dup-room", None, "device-A").await.unwrap();

        // Same device_id should be rejected
        let result = mgr.join_room_with_token("dup-room", None, "device-A").await;
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), RoomError::DuplicateDevice));

        // Different device_id should work fine
        let result = mgr.join_room_with_token("dup-room", None, "device-B").await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_device_id_reusable_after_leave() {
        let mgr = new(&test_config());
        let (_tx, _rx) = mgr.join_room_with_token("reuse-room", None, "phone-1").await.unwrap();
        mgr.leave_room("reuse-room", "phone-1").await;

        // After leaving, same device_id can reconnect
        // Room was removed (last participant), so this creates a new room
        let result = mgr.join_room_with_token("reuse-room", None, "phone-1").await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_unicast_filtering() {
        let mgr = new(&test_config());
        let (tx, _rx_alice) = mgr.join_room("uni").await;
        let (_tx2, mut rx_bob) = mgr.join_room("uni").await;
        let (_tx3, mut rx_carol) = mgr.join_room("uni").await;

        // Send unicast to bob only
        let msg = RoomMessage {
            from: "alice".into(),
            to: "bob".into(),
            payload: "secret".into(),
            seq: 1,
        };
        tx.send(msg).unwrap();

        // Both receive broadcast-level message (filtering is done at WS layer)
        let bob_msg = rx_bob.recv().await.unwrap();
        assert_eq!(bob_msg.to, "bob");
        let carol_msg = rx_carol.recv().await.unwrap();
        assert_eq!(carol_msg.to, "bob");
    }

    #[tokio::test]
    async fn test_broadcast_to_multiple_receivers() {
        let mgr = new(&test_config());
        let (tx, _rx1) = mgr.join_room("multi").await;
        let (_tx2, mut rx2) = mgr.join_room("multi").await;
        let (_tx3, mut rx3) = mgr.join_room("multi").await;

        let msg = RoomMessage {
            from: "alice".into(),
            to: String::new(),
            payload: "hello all".into(),
            seq: 1,
        };
        tx.send(msg).unwrap();

        let m2 = rx2.recv().await.unwrap();
        let m3 = rx3.recv().await.unwrap();
        assert_eq!(m2.payload, "hello all");
        assert_eq!(m3.payload, "hello all");
    }

    #[tokio::test]
    async fn test_slow_consumer_lagged() {
        let mut cfg = test_config();
        cfg.max_participants = 10;
        let mgr = new(&cfg);
        let (tx, _rx1) = mgr.join_room("lag").await;
        let (_tx2, mut rx2) = mgr.join_room("lag").await;

        // Fill the broadcast buffer (default 256) plus overflow
        for i in 0..300 {
            let _ = tx.send(RoomMessage {
                from: "sender".into(),
                to: String::new(),
                payload: format!("msg-{}", i),
                seq: i,
            });
        }

        // Slow consumer should get a Lagged error on first recv
        match rx2.recv().await {
            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                assert!(n > 0, "should report skipped messages");
            }
            Ok(msg) => {
                // Some messages may have been buffered; just check we can receive
                assert!(msg.payload.starts_with("msg-"));
            }
            Err(e) => panic!("unexpected error: {:?}", e),
        }
    }

    #[tokio::test]
    async fn test_sequence_replay_rejected() {
        let mgr = new(&test_config());
        let (_tx, _rx) = mgr.join_room_with_token("seq-room", None, "dev1").await.unwrap();

        // Access room directly for sequence checking
        let rooms = mgr.rooms.read().await;
        let room = rooms.get("seq-room").unwrap();

        // First message with seq=5 should pass
        assert!(room.check_sequence("dev1", 5).await);
        // Same seq=5 should be rejected (replay)
        assert!(!room.check_sequence("dev1", 5).await);
        // Lower seq=3 should be rejected
        assert!(!room.check_sequence("dev1", 3).await);
        // Higher seq=10 should pass
        assert!(room.check_sequence("dev1", 10).await);
    }

    #[tokio::test]
    async fn test_sequence_empty_device_always_passes() {
        let mgr = new(&test_config());
        let (_tx, _rx) = mgr.join_room("seq2").await;

        let rooms = mgr.rooms.read().await;
        let room = rooms.get("seq2").unwrap();

        // Empty device_id always passes (backward compat)
        assert!(room.check_sequence("", 1).await);
        assert!(room.check_sequence("", 1).await);
    }
}
