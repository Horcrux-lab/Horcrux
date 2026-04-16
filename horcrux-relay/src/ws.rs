//! WebSocket handler — upgrades HTTP to WS and relays E2E encrypted messages.
//!
//! Security hardening:
//! - Server enforces `from == device_id` (prevents sender spoofing)
//! - Token accepted via Sec-WebSocket-Protocol header (keeps URLs clean)
//! - Per-connection token-bucket rate limiting
//! - Duplicate device_id rejection within same room
//! - Unicast filtering: `to` field routes to a single recipient
//! - Graceful handling of broadcast lag (slow consumers)

use axum::{
    extract::{
        ConnectInfo, Path, Query, State,
        WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use futures_util::{SinkExt, StreamExt};
use std::net::SocketAddr;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use tokio::sync::broadcast::error::RecvError;

use crate::config::RelayConfig;
use crate::ip_ratelimit::IpRateLimiter;
use crate::metrics::METRICS;
use crate::room::{RoomManager, RoomMessage, RoomError};

#[derive(serde::Deserialize)]
pub struct WsQuery {
    pub device_id: Option<String>,
    /// Token via query param (discouraged — prefer Sec-WebSocket-Protocol header).
    pub token: Option<String>,
}

/// Extract token from Sec-WebSocket-Protocol header.
/// Client sends: `Sec-WebSocket-Protocol: horcrux-token.{actual_token}`
/// This avoids putting the token in the URL (which leaks to logs/referer).
fn extract_token_from_headers(headers: &HeaderMap) -> Option<String> {
    headers
        .get("sec-websocket-protocol")
        .and_then(|v| v.to_str().ok())
        .and_then(|protocols| {
            protocols
                .split(',')
                .map(|p| p.trim())
                .find(|p| p.starts_with("horcrux-token."))
                .map(|p| p.strip_prefix("horcrux-token.").unwrap_or(p).to_string())
        })
}

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    Path(room_id): Path<String>,
    Query(query): Query<WsQuery>,
    headers: HeaderMap,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State((rooms, config, ip_limiter)): State<(RoomManager, RelayConfig, std::sync::Arc<IpRateLimiter>)>,
) -> Result<impl IntoResponse, StatusCode> {
    let device_id = query.device_id.clone().unwrap_or_default();

    // Prefer token from header, fall back to query param
    let token = extract_token_from_headers(&headers).or(query.token);

    // Validate room_id format
    if room_id.len() > 128
        || room_id.is_empty()
        || !room_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        tracing::warn!(room = %room_id, "invalid room_id format");
        return Err(StatusCode::BAD_REQUEST);
    }

    // Validate device_id — must be non-empty and reasonable
    if device_id.is_empty() || device_id.len() > 128 {
        return Err(StatusCode::BAD_REQUEST);
    }

    // Validate Origin header (CSWSH protection)
    if let Some(ref allowed) = config.allowed_origins {
        let origin = headers
            .get("origin")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        if !allowed.iter().any(|o| o == origin || o == "*") {
            tracing::warn!("rejected — origin not in allowed list");
            return Err(StatusCode::FORBIDDEN);
        }
    }

    // Per-IP connection rate limiting (prevents DoS room creation floods)
    if !ip_limiter.try_create(addr.ip()) {
        METRICS.rate_limited.fetch_add(1, Ordering::Relaxed);
        tracing::warn!(ip = %addr.ip(), room = %room_id, "IP rate limited");
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }

    let join_result = rooms
        .join_room_with_token(&room_id, token.as_deref(), &device_id)
        .await;

    match join_result {
        Ok((tx, rx)) => {
            tracing::info!(room = %room_id, device = %device_id, "WebSocket upgrade");
            METRICS.connections_total.fetch_add(1, Ordering::Relaxed);
            METRICS.connections_active.fetch_add(1, Ordering::Relaxed);

            // If token was provided via header protocol, echo it back so the
            // handshake succeeds (browser requires server to select a sub-protocol).
            let upgrade = if extract_token_from_headers(&headers).is_some() {
                ws.protocols(["horcrux-token"])
            } else {
                ws
            };

            Ok(upgrade.on_upgrade(move |socket| {
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
        Err(RoomError::DuplicateDevice) => {
            tracing::warn!(room = %room_id, device = %device_id, "duplicate device_id");
            Err(StatusCode::CONFLICT)
        }
        Err(RoomError::TooManyRooms) => {
            tracing::warn!(room = %room_id, "server room limit reached");
            Err(StatusCode::TOO_MANY_REQUESTS)
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

/// Validate, parse, and relay an incoming message (shared by Text + Binary paths).
/// Returns `Some(msg)` if valid, `None` if rejected (oversized, rate-limited, replayed, malformed).
async fn process_incoming(
    raw: &[u8],
    device_id: &str,
    room_id: &str,
    max_msg_size: usize,
    rate_limiter: &mut RateLimiter,
    rooms: &RoomManager,
) -> Option<RoomMessage> {
    if raw.len() > max_msg_size {
        METRICS.messages_rejected.fetch_add(1, Ordering::Relaxed);
        tracing::warn!(room = %room_id, size = raw.len(), "oversized");
        return None;
    }

    if !rate_limiter.try_consume() {
        METRICS.rate_limited.fetch_add(1, Ordering::Relaxed);
        tracing::warn!(room = %room_id, device = %device_id, "rate limited");
        return None;
    }

    let mut room_msg: RoomMessage = match serde_json::from_slice(raw) {
        Ok(m) => m,
        Err(e) => {
            METRICS.messages_rejected.fetch_add(1, Ordering::Relaxed);
            tracing::warn!(room = %room_id, error = %e, "malformed JSON");
            return None;
        }
    };

    // Server-side enforcement: overwrite `from` with the authenticated device_id.
    room_msg.from = device_id.to_string();

    // Replay protection: reject out-of-order messages.
    if !rooms.check_sequence(room_id, device_id, room_msg.seq).await {
        METRICS.messages_rejected.fetch_add(1, Ordering::Relaxed);
        tracing::warn!(room = %room_id, device = %device_id, seq = room_msg.seq, "replayed message rejected");
        return None;
    }

    rooms.touch(room_id).await;
    Some(room_msg)
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
                    if msg.from == device_id_for_relay {
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
                    if ws_sink.send(Message::Text(json)).await.is_err() {
                        break;
                    }
                }
                Err(RecvError::Lagged(n)) => {
                    tracing::warn!(
                        device = %device_id_for_relay,
                        skipped = n,
                        "slow consumer — skipped messages"
                    );
                }
                Err(RecvError::Closed) => break,
            }
        }
    });

    // --- Client → room broadcast with rate limiting ---
    let mut ping_interval = tokio::time::interval(config.ping_interval);
    ping_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut last_activity = Instant::now();
    let idle_timeout = config.ping_interval + config.pong_timeout;
    let mut rate_limiter = RateLimiter::new(config.rate_limit_count, config.rate_limit_window);

    loop {
        tokio::select! {
            _ = ping_interval.tick() => {
                if last_activity.elapsed() > idle_timeout {
                    tracing::warn!(room = %room_id, device = %device_id, "idle timeout");
                    break;
                }
            }

            frame = ws_stream.next() => {
                match frame {
                    Some(Ok(msg)) => {
                        last_activity = Instant::now();

                        match msg {
                            Message::Text(text) => {
                                if let Some(room_msg) = process_incoming(
                                    text.as_bytes(), &device_id, &room_id, max_msg_size,
                                    &mut rate_limiter, &rooms,
                                ).await {
                                    let _ = tx.send(room_msg);
                                    METRICS.messages_relayed.fetch_add(1, Ordering::Relaxed);
                                }
                            }
                            Message::Binary(data) => {
                                if let Some(room_msg) = process_incoming(
                                    &data, &device_id, &room_id, max_msg_size,
                                    &mut rate_limiter, &rooms,
                                ).await {
                                    let _ = tx.send(room_msg);
                                    METRICS.messages_relayed.fetch_add(1, Ordering::Relaxed);
                                }
                            }
                            Message::Pong(_) | Message::Ping(_) => {}
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
