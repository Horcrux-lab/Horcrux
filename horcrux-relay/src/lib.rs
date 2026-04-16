//! Horcrux Relay — library crate exposing the app builder and internal modules
//! for integration testing.

pub mod config;
pub mod ip_ratelimit;
pub mod metrics;
pub mod room;
pub mod ws;

use axum::{
    extract::{Query, State},
    http::{HeaderMap, HeaderValue, Method, StatusCode},
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use std::sync::Arc;
use std::time::Instant;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::trace::TraceLayer;

use crate::config::RelayConfig;
use crate::ip_ratelimit::IpRateLimiter;
use crate::metrics::METRICS;
use crate::room::RoomManager;
use subtle::ConstantTimeEq;

/// App state passed to all handlers.
pub type AppState = (RoomManager, RelayConfig, Arc<IpRateLimiter>);

/// Server start time — used by /health for uptime calculation.
static START_TIME: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

/// Initialize the global start time. Idempotent — only the first call takes effect.
pub fn init_start_time() {
    START_TIME.get_or_init(Instant::now);
}

/// Build the axum Router with all routes and middleware.
pub fn build_app(state: AppState) -> Router {
    let config = &state.1;

    let cors = match &config.allowed_origins {
        Some(origins) => {
            let origin_list: Vec<HeaderValue> = origins
                .iter()
                .filter_map(|o| o.parse().ok())
                .collect();
            CorsLayer::new()
                .allow_origin(AllowOrigin::list(origin_list))
                .allow_methods([Method::GET])
                .allow_headers(tower_http::cors::Any)
        }
        None => CorsLayer::permissive(),
    };

    Router::new()
        .route("/health", get(health))
        .route("/metrics", get(metrics_handler))
        .route("/admin/rooms", get(admin_rooms_handler))
        .route("/ws/{room_id}", get(ws::ws_handler))
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn health(State((rooms, _config, _ip)): State<AppState>) -> impl IntoResponse {
    let uptime = START_TIME
        .get()
        .map(|t| t.elapsed().as_secs())
        .unwrap_or(0);
    let active_rooms = rooms.room_count().await;
    let active_connections = METRICS
        .connections_active
        .load(std::sync::atomic::Ordering::Relaxed);
    Json(serde_json::json!({
        "status": "ok",
        "version": env!("CARGO_PKG_VERSION"),
        "uptime_seconds": uptime,
        "active_rooms": active_rooms,
        "active_connections": active_connections,
    }))
}

/// Prometheus-compatible metrics endpoint (admin-protected when token is set).
async fn metrics_handler(
    headers: HeaderMap,
    Query(query): Query<AdminQuery>,
    State((rooms, config, _ip)): State<AppState>,
) -> Result<impl IntoResponse, StatusCode> {
    verify_admin_token(&headers, &query, &config)?;
    let active_rooms = rooms.room_count().await;
    Ok((
        [(axum::http::header::CONTENT_TYPE, "text/plain; version=0.0.4")],
        METRICS.render(active_rooms),
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
    State((rooms, config, _ip)): State<AppState>,
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
            Some(t) if t.as_bytes().ct_eq(expected.as_bytes()).into() => Ok(()),
            _ => Err(StatusCode::FORBIDDEN),
        }
    } else {
        Ok(())
    }
}
