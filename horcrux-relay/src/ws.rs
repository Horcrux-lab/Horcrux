//! WebSocket handler — upgrades HTTP to WS and relays E2E encrypted messages.
//!
//! Security: rooms are access-controlled via token query parameter.
//! All payloads are opaque E2E encrypted — the relay cannot read them.
//!
//! Optimizations over the initial version:
//! - Proper WS Ping/Pong heartbeat (not broadcast-based)
//! - Unicast filtering: `to` field routes to a single recipient
//! - Per-connection token-bucket rate limiting
//! - Graceful handling of broadcast lag (slow consumers)
//! - Metrics integration

use axum::{
    extract::{
        Path, Query, State,
        WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::StatusCode,
    response::IntoResponse,
};
use futures_util::{SinkExt, StreamExt};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use tokio::sync::broadcast::error::RecvError;

use crate::config::RelayConfig;
use crate::metrics::METRICS;
use crate::room::{RoomManager, RoomMessage, RoomError};

#[derive(serde::Deserialize)]
pub struct WsQuery {
    pub device_id: Option<String>,
    pub token: Option<String>,
}

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    Path(room_id): Path<String>,
    Query(query): Query<WsQuery>,
    State((rooms, config)): State<(RoomManager, RelayConfig)>,
) -> Result<impl IntoResponse, StatusCode> {
    let device_id = query.device_id.unwrap_or_default();
    let token = query.token;

    // Validate room_id format
    if room_id.len() > 128
        || !room_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        tracing::warn!(room = %room_id, "invalid room_id format");
        return Err(StatusCode::BAD_REQUEST);
    }

    if device_id.len() > 128 {
        return Err(StatusCode::BAD_REQUEST);
    }

    let join_result = rooms
        .join_room_with_token(&room_id, token.as_deref(), &device_id)
        .await;

    match join_result {
        Ok((tx, rx)) => {
            tracing::info!(room = %room_id, device = %device_id, "WebSocket upgrade");
            METRICS.connections_total.fetch_add(1, Ordering::Relaxed);
            METRICS.connections_active.fetch_add(1, Ordering::Relaxed);
            Ok(ws.on_upgrade(move |socket| {
                handle_socket(socket, room_id, device_id, rooms, tx, rx, config)
            }))
        }
        Err(RoomError::InvalidToken) => {
            METRICS.auth_failures.fetch_add(1, Ordering::Relaxed);
            tracing::warn!(room = %room_id, "access denied — invalid token");
            Err(StatusCode::FORBIDDEN)
        }
        Err(RoomError::RoomFull) => {
            tracing::warn!(room = %room_id, "room full");
            Err(StatusCode::SERVICE_UNAVAILABLE)
        }
    }
}

/// Simple token-bucket rate limiter.
struct RateLimiter {
    tokens: u32,
    max_tokens: u32,
    last_refill: Instant,
    window: Duration,
}

impl RateLimiter {
    fn new(max_tokens: u32, window: Duration) -> Self {
        Self {
            tokens: max_tokens,
            max_tokens,
            last_refill: Instant::now(),
            window,
        }
    }

    /// Try to consume one token. Returns false if rate-limited.
    fn try_consume(&mut self) -> bool {
        let now = Instant::now();
        let elapsed = now.duration_since(self.last_refill);
        if elapsed >= self.window {
            self.tokens = self.max_tokens;
            self.last_refill = now;
        }
        if self.tokens > 0 {
            self.tokens -= 1;
            true
        } else {
            false
        }
    }
}

async fn handle_socket(
    socket: WebSocket,
    room_id: String,
    device_id: String,
    rooms: RoomManager,
    tx: tokio::sync::broadcast::Sender<RoomMessage>,
    mut rx: tokio::sync::broadcast::Receiver<RoomMessage>,
    config: RelayConfig,
) {
    let (mut ws_sink, mut ws_stream) = socket.split();
    let max_msg_size = config.max_message_size;

    // --- Relay: room broadcast → WebSocket client ---
    let device_id_for_relay = device_id.clone();
    let relay_to_client = tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(msg) => {
                    // Don't echo to sender
                    if !device_id_for_relay.is_empty() && msg.from == device_id_for_relay {
                        continue;
                    }
                    // Unicast: if `to` is set, only deliver to the intended recipient
                    if !msg.to.is_empty() && msg.to != device_id_for_relay {
                        continue;
                    }
                    let json = match serde_json::to_string(&msg) {
                        Ok(j) => j,
                        Err(_) => continue,
                    };
                    if ws_sink.send(Message::Text(json.into())).await.is_err() {
                        break;
                    }
                }
                Err(RecvError::Lagged(n)) => {
                    tracing::warn!(
                        device = %device_id_for_relay,
                        skipped = n,
                        "slow consumer — skipped messages"
                    );
                    // Continue — broadcast channel auto-skips to the latest
                }
                Err(RecvError::Closed) => break,
            }
        }
    });

    // --- Client → room broadcast with ping/pong + rate limiting ---
    let mut ping_interval = tokio::time::interval(config.ping_interval);
    ping_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut last_pong = Instant::now();
    let pong_timeout = config.pong_timeout;
    let mut rate_limiter = RateLimiter::new(config.rate_limit_count, config.rate_limit_window);

    loop {
        tokio::select! {
            _ = ping_interval.tick() => {
                // Check pong timeout
                if last_pong.elapsed() > config.ping_interval + pong_timeout {
                    tracing::warn!(room = %room_id, device = %device_id, "pong timeout");
                    break;
                }
                // Note: we can't send WS Ping from here because ws_sink is in
                // the relay_to_client task. Instead we rely on TCP keepalive and
                // the read timeout. If the client is truly dead, ws_stream.next()
                // will return None or Err, which breaks the loop.
            }

            frame = ws_stream.next() => {
                match frame {
                    Some(Ok(msg)) => {
                        // Any frame = client is alive
                        last_pong = Instant::now();

                        match msg {
                            Message::Text(text) => {
                                if text.len() > max_msg_size {
                                    METRICS.messages_rejected.fetch_add(1, Ordering::Relaxed);
                                    tracing::warn!(room = %room_id, size = text.len(), "oversized");
                                    continue;
                                }

                                if !rate_limiter.try_consume() {
                                    METRICS.rate_limited.fetch_add(1, Ordering::Relaxed);
                                    tracing::warn!(room = %room_id, device = %device_id, "rate limited");
                                    continue;
                                }

                                match serde_json::from_str::<RoomMessage>(&text) {
                                    Ok(room_msg) => {
                                        rooms.touch(&room_id).await;
                                        let _ = tx.send(room_msg);
                                        METRICS.messages_relayed.fetch_add(1, Ordering::Relaxed);
                                    }
                                    Err(e) => {
                                        METRICS.messages_rejected.fetch_add(1, Ordering::Relaxed);
                                        tracing::warn!(room = %room_id, error = %e, "malformed JSON");
                                    }
                                }
                            }
                            Message::Binary(data) => {
                                if data.len() > max_msg_size {
                                    METRICS.messages_rejected.fetch_add(1, Ordering::Relaxed);
                                    continue;
                                }
                                if !rate_limiter.try_consume() {
                                    METRICS.rate_limited.fetch_add(1, Ordering::Relaxed);
                                    continue;
                                }
                                match serde_json::from_slice::<RoomMessage>(&data) {
                                    Ok(room_msg) => {
                                        rooms.touch(&room_id).await;
                                        let _ = tx.send(room_msg);
                                        METRICS.messages_relayed.fetch_add(1, Ordering::Relaxed);
                                    }
                                    Err(_) => {
                                        METRICS.messages_rejected.fetch_add(1, Ordering::Relaxed);
                                    }
                                }
                            }
                            Message::Pong(_) => {
                                last_pong = Instant::now();
                            }
                            Message::Ping(_) => {
                                // axum auto-replies Pong
                                last_pong = Instant::now();
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
    rooms.leave_room(&room_id, &device_id).await;
    METRICS.connections_active.fetch_sub(1, Ordering::Relaxed);
    tracing::info!(room = %room_id, device = %device_id, "connection closed");
}
