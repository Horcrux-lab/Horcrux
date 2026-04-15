//! Horcrux Relay — WebSocket relay service for remote MPC DKG and co-signing.
//!
//! The relay is a dumb pipe: it forwards E2E encrypted messages between
//! participants. It cannot decrypt any payload.

mod room;
mod ws;

use axum::{extract::State, response::IntoResponse, routing::get, Json, Router};
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;
use tracing_subscriber::EnvFilter;

use crate::room::RoomManager;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::from_default_env().add_directive("horcrux_relay=info".parse()?),
        )
        .init();

    let room_state = room::new();

    // Start background room cleanup task
    let _cleanup_handle = room::spawn_cleanup_task(room_state.clone());

    let app = Router::new()
        .route("/health", get(health))
        .route("/rooms", get(rooms_handler))
        .route("/ws/{room_id}", get(ws::ws_handler))
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(room_state);

    let host = std::env::var("RELAY_HOST").unwrap_or_else(|_| "0.0.0.0".into());
    let port = std::env::var("RELAY_PORT").unwrap_or_else(|_| "3210".into());
    let addr = format!("{host}:{port}");
    tracing::info!("Horcrux Relay listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

async fn health() -> &'static str {
    "horcrux-relay ok"
}

async fn rooms_handler(State(rooms): State<RoomManager>) -> impl IntoResponse {
    let count = rooms.room_count().await;
    let ids = rooms.room_ids().await;
    Json(serde_json::json!({
        "count": count,
        "rooms": ids,
    }))
}
