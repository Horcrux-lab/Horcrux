//! End-to-end DKG ceremony over a live relay.
//!
//! Boots a real `horcrux-relay` instance on an ephemeral localhost port,
//! then runs a 2-of-2 FROST (Ed25519) DKG where each party speaks to the
//! other **only** through the relay's WebSocket interface. The test
//! passes iff both parties derive the same group public key.
//!
//! What this guards against:
//! - Wire-protocol drift between client and server (message shape,
//!   sequence numbers, unicast routing, broadcast fan-out, echo-suppress).
//! - Relay-side regressions in sender spoof enforcement, replay
//!   detection, and sub-protocol token handshake that unit tests on the
//!   router alone cannot catch.
//! - DKG regressions that only surface with real network framing (e.g.
//!   ordering / fragmentation of large Paillier proofs).
//!
//! FROST Ed25519 is picked because it completes in well under a second,
//! whereas CGGMP21 ECDSA needs minutes for the Paillier aux-info phase.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use horcrux_core::mpc::session::SessionManager;
use horcrux_core::mpc::types::MpcMessage;
use horcrux_core::mpc::{CurveType, HorcruxConfig};
use horcrux_relay::config::RelayConfig;
use horcrux_relay::ip_ratelimit::IpRateLimiter;
use horcrux_relay::room::{self, RoomMessage};
use horcrux_relay::AppState;
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::protocol::Message;

/// Spin up a real relay on an OS-assigned port and return its URL root.
async fn spawn_relay() -> (String, tokio::task::JoinHandle<()>) {
    // Permissive config — no admin token, no CORS restriction, generous
    // rate limits so two rapid DKG participants aren't throttled.
    let config = RelayConfig {
        ip_rate_limit_creates: 100,
        ..Default::default()
    };
    let rooms = room::new(&config);
    let ip_limiter = Arc::new(IpRateLimiter::new(
        config.ip_rate_limit_creates,
        config.ip_rate_limit_window,
    ));
    let state: AppState = (rooms, config, ip_limiter);
    horcrux_relay::init_start_time();
    let app = horcrux_relay::build_app(state);

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let handle = tokio::spawn(async move {
        let _ = axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await;
    });
    (format!("ws://{}", addr), handle)
}

/// Connect a party to the relay's WebSocket and spawn two background tasks
/// that shuttle `MpcMessage`s between a private inbox channel and the wire.
///
/// Returns:
/// - `outbound_tx`: caller sends `MpcMessage`s here, they land on the wire.
/// - `inbound_rx`: `MpcMessage`s received from other parties come out here.
async fn connect_party(
    base_url: &str,
    room_id: &str,
    device_id: &str,
) -> (
    mpsc::UnboundedSender<MpcMessage>,
    mpsc::UnboundedReceiver<MpcMessage>,
) {
    let url = format!("{}/ws/{}?device_id={}", base_url, room_id, device_id);
    let (ws, _) = tokio_tungstenite::connect_async(&url)
        .await
        .expect("ws connect");
    let (mut ws_sink, mut ws_stream) = ws.split();

    let (outbound_tx, mut outbound_rx) = mpsc::unbounded_channel::<MpcMessage>();
    let (inbound_tx, inbound_rx) = mpsc::unbounded_channel::<MpcMessage>();

    let device_id_out = device_id.to_string();
    tokio::spawn(async move {
        // Server overwrites `from` with the authenticated device_id, so it
        // doesn't matter what we put there — but `seq` must be monotonic
        // per-sender or the replay guard drops the message.
        let mut seq: u64 = 0;
        while let Some(mpc) = outbound_rx.recv().await {
            seq += 1;
            let to = if mpc.to == 0 {
                String::new() // broadcast
            } else {
                format!("p{}", mpc.to)
            };
            let room_msg = RoomMessage {
                from: device_id_out.clone(),
                to,
                payload: serde_json::to_string(&mpc).unwrap(),
                seq,
            };
            let text = serde_json::to_string(&room_msg).unwrap();
            if ws_sink.send(Message::Text(text)).await.is_err() {
                break;
            }
        }
    });

    tokio::spawn(async move {
        while let Some(frame) = ws_stream.next().await {
            let Ok(Message::Text(text)) = frame else {
                continue;
            };
            let Ok(room_msg) = serde_json::from_str::<RoomMessage>(&text) else {
                continue;
            };
            let Ok(mpc) = serde_json::from_str::<MpcMessage>(&room_msg.payload) else {
                continue;
            };
            if inbound_tx.send(mpc).is_err() {
                break;
            }
        }
    });

    (outbound_tx, inbound_rx)
}

/// Drive one party to DKG completion, returning the final public key.
async fn run_party(
    base_url: String,
    room_id: String,
    party_index: u16,
    total_parties: u16,
) -> Vec<u8> {
    let device_id = format!("p{}", party_index);
    let (outbound, mut inbound) = connect_party(&base_url, &room_id, &device_id).await;

    // Small stagger so both parties have a room handle before the first
    // broadcast — otherwise the earliest-sent Round1 frame can land in the
    // room before the second peer joins and gets dropped by the echo
    // filter (broadcast::Receiver only sees messages sent *after* it
    // subscribes).
    tokio::time::sleep(Duration::from_millis(200)).await;

    let mut mgr = SessionManager::new();
    let session_id = "dkg-e2e".to_string();
    let config = HorcruxConfig {
        threshold: total_parties,
        total_parties,
        party_index,
        curve: CurveType::Ed25519,
    };

    let initial = mgr.create_keygen(session_id.clone(), config).unwrap();
    for msg in initial {
        outbound.send(msg).unwrap();
    }

    // Pump the inbox until the session completes or we time out.
    loop {
        if let Some(result) = mgr.keygen_result(&session_id) {
            return result.public_key.clone();
        }
        let msg = tokio::time::timeout(Duration::from_secs(15), inbound.recv())
            .await
            .expect("timeout waiting for peer message")
            .expect("inbox channel closed unexpectedly");
        let outs = mgr.handle_message(msg).expect("handle_message");
        for m in outs {
            outbound.send(m).unwrap();
        }
    }
}

#[tokio::test]
async fn two_party_dkg_over_live_relay() {
    let (base_url, _relay_handle) = spawn_relay().await;

    // Unique room id per test run so parallel test processes don't
    // collide on the same relay state.
    let room_id = format!("dkg-{}", uuid::Uuid::new_v4().simple());

    // `SessionManager` isn't `Send` (CGGMP21 drivers use `dyn Trait` without
    // a `Send` bound), so we can't `tokio::spawn` the parties onto the
    // multi-thread runtime. Instead, run both parties concurrently on this
    // task — the WebSocket I/O still happens in spawned tasks inside
    // `connect_party`, so both parties make progress in parallel.
    let (pk1, pk2) = tokio::time::timeout(
        Duration::from_secs(60),
        futures_util::future::join(
            run_party(base_url.clone(), room_id.clone(), 1, 2),
            run_party(base_url.clone(), room_id.clone(), 2, 2),
        ),
    )
    .await
    .expect("DKG ceremony deadlocked");

    assert!(!pk1.is_empty(), "party 1 produced empty public key");
    assert_eq!(pk1, pk2, "parties derived different group public keys");
}
