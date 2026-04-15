//! Room management — tracks connected participants per session.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, RwLock};

/// Default room time-to-live: 10 minutes.
const DEFAULT_ROOM_TTL: Duration = Duration::from_secs(600);

/// How often the cleanup task runs.
const CLEANUP_INTERVAL: Duration = Duration::from_secs(30);

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

impl RoomManagerInner {
    pub fn new(ttl: Duration) -> Self {
        Self {
            rooms: RwLock::new(HashMap::new()),
            ttl,
        }
    }

    /// Join (or create) a room. Returns a broadcast sender and receiver.
    pub async fn join_room(
        &self,
        room_id: &str,
    ) -> (broadcast::Sender<RoomMessage>, broadcast::Receiver<RoomMessage>) {
        let mut rooms = self.rooms.write().await;

        if let Some(room) = rooms.get_mut(room_id) {
            room.participant_count += 1;
            room.last_activity = tokio::time::Instant::now();
            let rx = room.tx.subscribe();
            tracing::info!(room = room_id, participants = room.participant_count, "participant joined");
            (room.tx.clone(), rx)
        } else {
            let (tx, rx) = broadcast::channel(256);
            rooms.insert(
                room_id.to_string(),
                Room {
                    tx: tx.clone(),
                    participant_count: 1,
                    last_activity: tokio::time::Instant::now(),
                },
            );
            tracing::info!(room = room_id, "new room created");
            (tx, rx)
        }
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
        // Still 1 participant, room exists
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
}
