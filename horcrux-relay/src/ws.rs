//! WebSocket handler — upgrades HTTP to WS and relays messages within rooms.

use axum::{
    extract::{Path, State, WebSocketUpgrade, ws::{Message, WebSocket}},
    response::IntoResponse,
};
use futures_util::{SinkExt, StreamExt};

use crate::room::{RoomManager, RoomMessage};

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    Path(room_id): Path<String>,
    State(rooms): State<RoomManager>,
) -> impl IntoResponse {
    tracing::info!(room = %room_id, "WebSocket upgrade request");
    ws.on_upgrade(move |socket| handle_socket(socket, room_id, rooms))
}

async fn handle_socket(socket: WebSocket, room_id: String, rooms: RoomManager) {
    let (tx, mut rx) = rooms.join_room(&room_id).await;
    let (mut ws_sink, mut ws_stream) = socket.split();

    // Task: relay room broadcast → WebSocket client
    let room_id_clone = room_id.clone();
    let relay_to_client = tokio::spawn(async move {
        while let Ok(msg) = rx.recv().await {
            let json = match serde_json::to_string(&msg) {
                Ok(j) => j,
                Err(_) => continue,
            };
            if ws_sink.send(Message::Text(json.into())).await.is_err() {
                break;
            }
        }
    });

    // Task: WebSocket client → room broadcast
    while let Some(Ok(msg)) = ws_stream.next().await {
        match msg {
            Message::Text(text) => {
                if let Ok(room_msg) = serde_json::from_str::<RoomMessage>(&text) {
                    let _ = tx.send(room_msg);
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
    }

    // Cleanup
    relay_to_client.abort();
    rooms.leave_room(&room_id).await;
    tracing::info!(room = %room_id, "WebSocket connection closed");
}
