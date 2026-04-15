//! Horcrux Relay — WebSocket relay service for remote MPC DKG and co-signing.
//!
//! The relay is a dumb pipe: it forwards E2E encrypted messages between
//! participants. It cannot decrypt any payload.

mod ws;
mod room;

use axum::{
    Router,
    routing::get,
};
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("horcrux_relay=info".parse()?))
        .init();

    let room_state = room::new();

    let app = Router::new()
        .route("/health", get(health))
        .route("/ws/{room_id}", get(ws::ws_handler))
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(room_state);

    let addr = "0.0.0.0:3210";
    tracing::info!("Horcrux Relay listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

async fn health() -> &'static str {
    "horcrux-relay ok"
}
