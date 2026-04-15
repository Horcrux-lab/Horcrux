//! Room management — tracks connected participants per session.

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{broadcast, RwLock};

/// Shared state across all WebSocket connections.
pub type RoomManager = Arc<RoomManagerInner>;

pub fn new() -> RoomManager {
    Arc::new(RoomManagerInner::new())
}

pub struct RoomManagerInner {
    rooms: RwLock<HashMap<String, Room>>,
}

struct Room {
    /// Broadcast channel for this room
    tx: broadcast::Sender<RoomMessage>,
    /// Connected participant count
    participant_count: usize,
    /// When was this room created
    created_at: chrono::DateTime<chrono::Utc>,
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
    pub fn new() -> Self {
        Self {
            rooms: RwLock::new(HashMap::new()),
        }
    }

    /// Join (or create) a room. Returns a broadcast receiver.
    pub async fn join_room(&self, room_id: &str) -> (broadcast::Sender<RoomMessage>, broadcast::Receiver<RoomMessage>) {
        let mut rooms = self.rooms.write().await;

        if let Some(room) = rooms.get_mut(room_id) {
            room.participant_count += 1;
            let rx = room.tx.subscribe();
            tracing::info!(room = room_id, participants = room.participant_count, "participant joined");
            (room.tx.clone(), rx)
        } else {
            let (tx, rx) = broadcast::channel(256);
            rooms.insert(room_id.to_string(), Room {
                tx: tx.clone(),
                participant_count: 1,
                created_at: chrono::Utc::now(),
            });
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

    /// Get active room count.
    pub async fn room_count(&self) -> usize {
        self.rooms.read().await.len()
    }
}
