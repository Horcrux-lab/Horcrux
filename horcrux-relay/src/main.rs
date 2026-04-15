//! Horcrux Relay — WebSocket relay service for remote MPC DKG and co-signing.
//!
//! The relay is a dumb pipe: it forwards E2E encrypted messages between
//! participants. It cannot decrypt any payload.
//!
//! Optimized for:
//! - Low-latency message forwarding (lock-free touch, atomic counters)
//! - Security (token-gated rooms, rate limiting, input validation)
//! - Observability (Prometheus-compatible /metrics endpoint)
//! - Graceful shutdown (SIGINT/SIGTERM drains connections)

mod config;
mod metrics;
mod room;
mod ws;

use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;
use tracing_subscriber::EnvFilter;

use crate::config::RelayConfig;
use crate::metrics::METRICS;
use crate::room::RoomManager;

/// App state passed to all handlers.
type AppState = (RoomManager, RelayConfig);

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::from_default_env().add_directive("horcrux_relay=info".parse()?),
        )
        .init();

    let config = RelayConfig::from_env();
    let room_state = room::new(&config);
    let _cleanup_handle = room::spawn_cleanup_task(room_state.clone());

    let addr = format!("{}:{}", config.host, config.port);

    let state: AppState = (room_state, config);

    let app = Router::new()
        .route("/health", get(health))
        .route("/metrics", get(metrics_handler))
        .route("/admin/rooms", get(admin_rooms_handler))
        .route("/ws/{room_id}", get(ws::ws_handler))
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    tracing::info!("Horcrux Relay listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr).await?;

    // Graceful shutdown on SIGINT / SIGTERM
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    tracing::info!("Relay shut down gracefully");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => tracing::info!("received SIGINT, shutting down"),
        _ = terminate => tracing::info!("received SIGTERM, shutting down"),
    }
}

async fn health() -> &'static str {
    "horcrux-relay ok"
}

/// Prometheus-compatible metrics endpoint (admin-protected when token is set).
async fn metrics_handler(
    headers: HeaderMap,
    Query(query): Query<AdminQuery>,
    State((_rooms, config)): State<AppState>,
) -> Result<impl IntoResponse, StatusCode> {
    verify_admin_token(&headers, &query, &config)?;
    Ok((
        [(axum::http::header::CONTENT_TYPE, "text/plain; version=0.0.4")],
        METRICS.render(),
    ))
}

/// Admin query parameters.
#[derive(serde::Deserialize)]
struct AdminQuery {
    admin_token: Option<String>,
}

/// Protected admin endpoint — lists room details.
async fn admin_rooms_handler(
    headers: HeaderMap,
    Query(query): Query<AdminQuery>,
    State((rooms, config)): State<AppState>,
) -> Result<impl IntoResponse, StatusCode> {
    verify_admin_token(&headers, &query, &config)?;

    let stats = rooms.room_stats().await;
    let count = rooms.room_count().await;
    Ok(Json(serde_json::json!({
        "count": count,
        "rooms": stats,
    })))
}

/// Verify admin token using constant-time comparison.
fn verify_admin_token(
    headers: &HeaderMap,
    query: &AdminQuery,
    config: &RelayConfig,
) -> Result<(), StatusCode> {
    if let Some(ref expected) = config.admin_token {
        let provided = query
            .admin_token
            .as_deref()
            .or_else(|| {
                headers
                    .get("x-admin-token")
                    .and_then(|v| v.to_str().ok())
            });
        match provided {
            Some(t) if constant_time_str_eq(t, expected) => Ok(()),
            _ => Err(StatusCode::FORBIDDEN),
        }
    } else {
        Ok(())
    }
}

/// Constant-time string comparison (prevents timing attacks on admin tokens).
fn constant_time_str_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.bytes().zip(b.bytes()) {
        diff |= x ^ y;
    }
    diff == 0
}
