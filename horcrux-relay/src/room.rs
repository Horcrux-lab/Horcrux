//! Room management — tracks connected participants per session.
//!
//! Rooms are now access-controlled: a room is created with a token hash,
//! and subsequent joins must present the matching token.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use sha2::{Sha256, Digest};
use tokio::sync::{broadcast, RwLock};

/// Default room time-to-live: 10 minutes.
const DEFAULT_ROOM_TTL: Duration = Duration::from_secs(600);

/// How often the cleanup task runs.
const CLEANUP_INTERVAL: Duration = Duration::from_secs(30);

/// Maximum participants per room.
const MAX_PARTICIPANTS: usize = 10;

/// Shared state across all WebSocket connections.
pub type RoomManager = Arc<RoomManagerInner>;

pub fn new() -> RoomManager {
    new_with_ttl(DEFAULT_ROOM_TTL)
}

pub fn new_with_ttl(ttl: Duration) -> RoomManager {
    Arc::new(RoomManagerInner::new(ttl))
}

/// Spawns a background task that periodically removes expired rooms.
pub fn spawn_cleanup_task(manager: RoomManager) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(CLEANUP_INTERVAL);
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
}

struct Room {
    /// Broadcast channel for this room
    tx: broadcast::Sender<RoomMessage>,
    /// Connected participant count
    participant_count: usize,
    /// Last activity timestamp (join, message, etc.)
    last_activity: tokio::time::Instant,
    /// SHA-256 hash of access token (None = legacy open room for tests)
    token_hash: Option<[u8; 32]>,
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
    #[error("room is full (max {MAX_PARTICIPANTS} participants)")]
    RoomFull,
}

impl RoomManagerInner {
    pub fn new(ttl: Duration) -> Self {
        Self {
            rooms: RwLock::new(HashMap::new()),
            ttl,
        }
    }

    /// Hash a raw access token for storage/comparison.
    fn hash_token(token: &str) -> [u8; 32] {
        let mut hasher = Sha256::new();
        hasher.update(token.as_bytes());
        hasher.finalize().into()
    }

    /// Join (or create) a room with access token verification.
    /// If the room already exists, the token must match.
    /// If creating a new room, the token is stored as the room's access credential.
    pub async fn join_room_with_token(
        &self,
        room_id: &str,
        token: Option<&str>,
    ) -> Result<(broadcast::Sender<RoomMessage>, broadcast::Receiver<RoomMessage>), RoomError> {
        let mut rooms = self.rooms.write().await;

        if let Some(room) = rooms.get_mut(room_id) {
            // Verify access token
            if let Some(ref stored_hash) = room.token_hash {
                let provided_hash = token.map(Self::hash_token);
                match provided_hash {
                    Some(h) if constant_time_eq(&h, stored_hash) => {}
                    _ => return Err(RoomError::InvalidToken),
                }
            }

            if room.participant_count >= MAX_PARTICIPANTS {
                return Err(RoomError::RoomFull);
            }

            room.participant_count += 1;
            room.last_activity = tokio::time::Instant::now();
            let rx = room.tx.subscribe();
            tracing::info!(room = room_id, participants = room.participant_count, "participant joined (authenticated)");
            Ok((room.tx.clone(), rx))
        } else {
            let (tx, rx) = broadcast::channel(256);
            let token_hash = token.map(Self::hash_token);
            rooms.insert(
                room_id.to_string(),
                Room {
                    tx: tx.clone(),
                    participant_count: 1,
                    last_activity: tokio::time::Instant::now(),
                    token_hash,
                },
            );
            tracing::info!(room = room_id, secured = token.is_some(), "new room created");
            Ok((tx, rx))
        }
    }

    /// Legacy: join without token (for backward-compatible tests).
    pub async fn join_room(
        &self,
        room_id: &str,
    ) -> (broadcast::Sender<RoomMessage>, broadcast::Receiver<RoomMessage>) {
        self.join_room_with_token(room_id, None).await.expect("join_room without token should not fail on new room")
    }

    /// Leave a room. Removes the room if empty.
    pub async fn leave_room(&self, room_id: &str) {
        let mut rooms = self.rooms.write().await;
        if let Some(room) = rooms.get_mut(room_id) {
            room.participant_count = room.participant_count.saturating_sub(1);
            if room.participant_count == 0 {
                rooms.remove(room_id);
                tracing::info!(room = room_id, "room removed (empty)");
            } else {
                tracing::info!(room = room_id, participants = room.participant_count, "participant left");
            }
        }
    }

    /// Touch activity timestamp for a room (call on message relay).
    pub async fn touch(&self, room_id: &str) {
        let mut rooms = self.rooms.write().await;
        if let Some(room) = rooms.get_mut(room_id) {
            room.last_activity = tokio::time::Instant::now();
        }
    }

    /// Get active room count.
    pub async fn room_count(&self) -> usize {
        self.rooms.read().await.len()
    }

    /// List active room IDs.
    pub async fn room_ids(&self) -> Vec<String> {
        self.rooms.read().await.keys().cloned().collect()
    }

    /// Remove rooms that have exceeded their TTL. Returns number removed.
    pub async fn cleanup_expired(&self) -> usize {
        let mut rooms = self.rooms.write().await;
        let now = tokio::time::Instant::now();
        let before = rooms.len();
        rooms.retain(|id, room| {
            let expired = now.duration_since(room.last_activity) > self.ttl;
            if expired {
                tracing::info!(room = %id, "room expired");
            }
            !expired
        });
        before - rooms.len()
    }
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
    use std::time::Duration;

    #[tokio::test]
    async fn test_create_and_join_room() {
        let mgr = new();
        let (_tx, _rx) = mgr.join_room("room-1").await;
        assert_eq!(mgr.room_count().await, 1);
        assert_eq!(mgr.room_ids().await, vec!["room-1".to_string()]);
    }

    #[tokio::test]
    async fn test_multiple_participants() {
        let mgr = new();
        let (_tx1, _rx1) = mgr.join_room("room-1").await;
        let (_tx2, _rx2) = mgr.join_room("room-1").await;
        assert_eq!(mgr.room_count().await, 1);
    }

    #[tokio::test]
    async fn test_leave_room_decrements() {
        let mgr = new();
        let (_tx1, _rx1) = mgr.join_room("room-1").await;
        let (_tx2, _rx2) = mgr.join_room("room-1").await;
        mgr.leave_room("room-1").await;
        assert_eq!(mgr.room_count().await, 1);
    }

    #[tokio::test]
    async fn test_leave_room_removes_when_empty() {
        let mgr = new();
        let (_tx, _rx) = mgr.join_room("room-1").await;
        mgr.leave_room("room-1").await;
        assert_eq!(mgr.room_count().await, 0);
    }

    #[tokio::test]
    async fn test_leave_nonexistent_room() {
        let mgr = new();
        mgr.leave_room("no-such-room").await;
        assert_eq!(mgr.room_count().await, 0);
    }

    #[tokio::test]
    async fn test_multiple_rooms() {
        let mgr = new();
        let (_tx1, _rx1) = mgr.join_room("room-a").await;
        let (_tx2, _rx2) = mgr.join_room("room-b").await;
        assert_eq!(mgr.room_count().await, 2);
        let mut ids = mgr.room_ids().await;
        ids.sort();
        assert_eq!(ids, vec!["room-a".to_string(), "room-b".to_string()]);
    }

    #[tokio::test]
    async fn test_room_expiry() {
        let ttl = Duration::from_millis(50);
        let mgr = new_with_ttl(ttl);
        let (_tx, _rx) = mgr.join_room("ephemeral").await;
        assert_eq!(mgr.room_count().await, 1);

        tokio::time::sleep(Duration::from_millis(100)).await;
        let removed = mgr.cleanup_expired().await;
        assert_eq!(removed, 1);
        assert_eq!(mgr.room_count().await, 0);
    }

    #[tokio::test]
    async fn test_touch_prevents_expiry() {
        let ttl = Duration::from_millis(100);
        let mgr = new_with_ttl(ttl);
        let (_tx, _rx) = mgr.join_room("active").await;

        tokio::time::sleep(Duration::from_millis(60)).await;
        mgr.touch("active").await;
        tokio::time::sleep(Duration::from_millis(60)).await;

        let removed = mgr.cleanup_expired().await;
        assert_eq!(removed, 0);
        assert_eq!(mgr.room_count().await, 1);
    }

    #[tokio::test]
    async fn test_message_broadcast() {
        let mgr = new();
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
        let mgr = new();
        // Create room with token
        let (_tx1, _rx1) = mgr.join_room_with_token("secure-room", Some("secret-token-123")).await.unwrap();
        assert_eq!(mgr.room_count().await, 1);

        // Join with correct token
        let result = mgr.join_room_with_token("secure-room", Some("secret-token-123")).await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_token_gated_room_wrong_token_rejected() {
        let mgr = new();
        let (_tx, _rx) = mgr.join_room_with_token("secure-room", Some("correct-token")).await.unwrap();

        // Try joining with wrong token
        let result = mgr.join_room_with_token("secure-room", Some("wrong-token")).await;
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), RoomError::InvalidToken));
    }

    #[tokio::test]
    async fn test_token_gated_room_no_token_rejected() {
        let mgr = new();
        let (_tx, _rx) = mgr.join_room_with_token("secure-room", Some("my-token")).await.unwrap();

        // Try joining without any token
        let result = mgr.join_room_with_token("secure-room", None).await;
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), RoomError::InvalidToken));
    }

    #[tokio::test]
    async fn test_room_full_rejected() {
        let mgr = new();
        // Fill the room to MAX_PARTICIPANTS
        let mut handles = Vec::new();
        for i in 0..MAX_PARTICIPANTS {
            let result = mgr.join_room_with_token(&format!("full-room"), Some("tok")).await;
            if i == 0 {
                assert!(result.is_ok());
            }
            handles.push(result);
        }

        // One more should fail
        let result = mgr.join_room_with_token("full-room", Some("tok")).await;
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), RoomError::RoomFull));
    }
}
