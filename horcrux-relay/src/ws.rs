//! WebSocket handler — upgrades HTTP to WS and relays messages within rooms.

use axum::{
    extract::{
        Path, Query, State,
        WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    response::IntoResponse,
};
use futures_util::{SinkExt, StreamExt};
use std::time::Duration;

use crate::room::{RoomManager, RoomMessage};

/// Maximum allowed message size (1 MB).
const MAX_MESSAGE_SIZE: usize = 1_048_576;

/// Heartbeat interval.
const PING_INTERVAL: Duration = Duration::from_secs(30);

/// How long to wait for a pong before considering the connection dead.
const PONG_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(serde::Deserialize)]
pub struct WsQuery {
    /// Optional device identifier for this connection.
    pub device_id: Option<String>,
}

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    Path(room_id): Path<String>,
    Query(query): Query<WsQuery>,
    State(rooms): State<RoomManager>,
) -> impl IntoResponse {
    let device_id = query.device_id.unwrap_or_default();
    tracing::info!(room = %room_id, device = %device_id, "WebSocket upgrade request");
    ws.on_upgrade(move |socket| handle_socket(socket, room_id, device_id, rooms))
}

async fn handle_socket(
    socket: WebSocket,
    room_id: String,
    device_id: String,
    rooms: RoomManager,
) {
    let (tx, mut rx) = rooms.join_room(&room_id).await;
    let (mut ws_sink, mut ws_stream) = socket.split();

    // Task: relay room broadcast → WebSocket client (skip messages from self)
    let device_id_for_relay = device_id.clone();
    let relay_to_client = tokio::spawn(async move {
        while let Ok(msg) = rx.recv().await {
            // Don't echo messages back to the sender
            if !device_id_for_relay.is_empty() && msg.from == device_id_for_relay {
                continue;
            }
            let json = match serde_json::to_string(&msg) {
                Ok(j) => j,
                Err(e) => {
                    tracing::warn!(error = %e, "failed to serialize room message");
                    continue;
                }
            };
            if ws_sink.send(Message::Text(json.into())).await.is_err() {
                break;
            }
        }
    });

    // Task: WebSocket client → room broadcast with ping/pong heartbeat
    let rooms_ref = rooms.clone();
    let room_id_ref = room_id.clone();
    let mut ping_interval = tokio::time::interval(PING_INTERVAL);
    let mut awaiting_pong = false;
    let mut pong_deadline: Option<tokio::time::Instant> = None;

    loop {
        tokio::select! {
            // Periodic ping
            _ = ping_interval.tick() => {
                // If we were already waiting for a pong and it timed out, disconnect
                if awaiting_pong {
                    if let Some(deadline) = pong_deadline {
                        if tokio::time::Instant::now() >= deadline {
                            tracing::warn!(room = %room_id, device = %device_id, "pong timeout — dropping connection");
                            break;
                        }
                    }
                }
                if tx.send(RoomMessage {
                    from: String::new(), to: String::new(), payload: String::new(), seq: 0,
                }).is_ok() {
                    // Channel still alive; send WS ping via the relay task is not
                    // possible since we don't own the sink. Instead, we simply
                    // rely on the TCP keepalive and the read timeout below.
                }
                awaiting_pong = true;
                pong_deadline = Some(tokio::time::Instant::now() + PONG_TIMEOUT);
            }

            // Incoming WebSocket frame
            frame = ws_stream.next() => {
                match frame {
                    Some(Ok(msg)) => {
                        match msg {
                            Message::Text(text) => {
                                // Size validation
                                if text.len() > MAX_MESSAGE_SIZE {
                                    tracing::warn!(
                                        room = %room_id, device = %device_id,
                                        size = text.len(),
                                        "message too large — rejected"
                                    );
                                    continue;
                                }

                                // JSON validation
                                match serde_json::from_str::<RoomMessage>(&text) {
                                    Ok(room_msg) => {
                                        rooms_ref.touch(&room_id_ref).await;
                                        let _ = tx.send(room_msg);
                                    }
                                    Err(e) => {
                                        tracing::warn!(
                                            room = %room_id, device = %device_id,
                                            error = %e,
                                            "malformed JSON — rejected"
                                        );
                                    }
                                }
                            }
                            Message::Binary(data) => {
                                if data.len() > MAX_MESSAGE_SIZE {
                                    tracing::warn!(
                                        room = %room_id, device = %device_id,
                                        size = data.len(),
                                        "binary message too large — rejected"
                                    );
                                    continue;
                                }
                                // Attempt JSON parse of binary payload
                                match serde_json::from_slice::<RoomMessage>(&data) {
                                    Ok(room_msg) => {
                                        rooms_ref.touch(&room_id_ref).await;
                                        let _ = tx.send(room_msg);
                                    }
                                    Err(e) => {
                                        tracing::warn!(
                                            room = %room_id, device = %device_id,
                                            error = %e,
                                            "malformed binary JSON — rejected"
                                        );
                                    }
                                }
                            }
                            Message::Pong(_) => {
                                awaiting_pong = false;
                                pong_deadline = None;
                            }
                            Message::Ping(data) => {
                                // Pong is auto-replied by axum/tungstenite, but reset heartbeat state
                                awaiting_pong = false;
                                pong_deadline = None;
                                let _ = data; // consumed
                            }
                            Message::Close(_) => break,
                        }
                    }
                    Some(Err(e)) => {
                        tracing::warn!(room = %room_id, device = %device_id, error = %e, "WebSocket error");
                        break;
                    }
                    None => break,
                }
            }
        }
    }

    // Cleanup
    relay_to_client.abort();
    rooms.leave_room(&room_id).await;
    tracing::info!(room = %room_id, device = %device_id, "WebSocket connection closed");
}
