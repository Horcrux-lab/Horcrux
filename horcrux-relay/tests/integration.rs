//! Integration tests for the Horcrux relay HTTP endpoints.
//!
//! These tests exercise the full axum Router (routes, middleware, state)
//! without binding to a TCP port — using `tower::ServiceExt::oneshot`.

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;

use horcrux_relay::config::RelayConfig;
use horcrux_relay::ip_ratelimit::IpRateLimiter;
use horcrux_relay::metrics::METRICS;
use horcrux_relay::room;
use horcrux_relay::AppState;

/// Build a test app with default (permissive) config.
fn test_app() -> axum::Router {
    let config = RelayConfig::default();
    let rooms = room::new(&config);
    let ip_limiter = Arc::new(IpRateLimiter::new(
        config.ip_rate_limit_creates,
        config.ip_rate_limit_window,
    ));
    let state: AppState = (rooms, config, ip_limiter);
    horcrux_relay::init_start_time();
    horcrux_relay::build_app(state)
}

/// Build a test app with an admin token configured.
fn test_app_with_admin_token(token: &str) -> (axum::Router, room::RoomManager) {
    let config = RelayConfig {
        admin_token: Some(token.to_string()),
        ..Default::default()
    };
    let rooms = room::new(&config);
    let ip_limiter = Arc::new(IpRateLimiter::new(
        config.ip_rate_limit_creates,
        config.ip_rate_limit_window,
    ));
    let state: AppState = (rooms.clone(), config, ip_limiter);
    horcrux_relay::init_start_time();
    (horcrux_relay::build_app(state), rooms)
}

/// Build a test app with specific allowed origins for CORS testing.
fn test_app_with_origins(origins: Vec<String>) -> axum::Router {
    let config = RelayConfig {
        allowed_origins: Some(origins),
        ..Default::default()
    };
    let rooms = room::new(&config);
    let ip_limiter = Arc::new(IpRateLimiter::new(
        config.ip_rate_limit_creates,
        config.ip_rate_limit_window,
    ));
    let state: AppState = (rooms, config, ip_limiter);
    horcrux_relay::init_start_time();
    horcrux_relay::build_app(state)
}

/// Helper: collect response body as String.
async fn body_string(body: Body) -> String {
    let bytes = body.collect().await.unwrap().to_bytes();
    String::from_utf8(bytes.to_vec()).unwrap()
}

// ---------------------------------------------------------------------------
// HTTP endpoint tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_health_returns_json() {
    let app = test_app();
    let req = Request::get("/health").body(Body::empty()).unwrap();
    let resp = app.oneshot(req).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    let body: serde_json::Value =
        serde_json::from_str(&body_string(resp.into_body()).await).unwrap();

    assert_eq!(body["status"], "ok");
    assert!(body["version"].is_string());
    assert!(body["uptime_seconds"].is_number());
}

#[tokio::test]
async fn test_health_has_room_count() {
    let app = test_app();
    let req = Request::get("/health").body(Body::empty()).unwrap();
    let resp = app.oneshot(req).await.unwrap();

    let body: serde_json::Value =
        serde_json::from_str(&body_string(resp.into_body()).await).unwrap();

    assert!(
        body.get("active_rooms").is_some(),
        "missing active_rooms field"
    );
    assert!(
        body.get("active_connections").is_some(),
        "missing active_connections field"
    );
    // Fresh app — no rooms yet.
    assert_eq!(body["active_rooms"], 0);
}

#[tokio::test]
async fn test_metrics_returns_prometheus_format() {
    let app = test_app();
    let req = Request::get("/metrics").body(Body::empty()).unwrap();
    let resp = app.oneshot(req).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_string(resp.into_body()).await;
    assert!(
        body.contains("# TYPE"),
        "expected Prometheus TYPE header in metrics output"
    );
    assert!(
        body.contains("horcrux_connections_total"),
        "expected horcrux_connections_total counter"
    );
    assert!(
        body.contains("horcrux_active_rooms"),
        "expected horcrux_active_rooms gauge"
    );
}

#[tokio::test]
async fn test_metrics_protected_by_admin_token() {
    let (app, _rooms) = test_app_with_admin_token("super-secret-token");

    // Request without token → FORBIDDEN
    let req = Request::get("/metrics").body(Body::empty()).unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // Request with correct token via query param → OK
    let req = Request::get("/metrics?admin_token=super-secret-token")
        .body(Body::empty())
        .unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Request with correct token via header → OK
    let req = Request::get("/metrics")
        .header("x-admin-token", "super-secret-token")
        .body(Body::empty())
        .unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Request with wrong token → FORBIDDEN
    let req = Request::get("/metrics?admin_token=wrong")
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn test_not_found_returns_404() {
    let app = test_app();
    let req = Request::get("/nonexistent").body(Body::empty()).unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ---------------------------------------------------------------------------
// WebSocket upgrade validation (HTTP-level)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_ws_plain_get_rejected() {
    let app = test_app();

    // A plain GET (not a WebSocket upgrade) to /ws/{room_id} matches the
    // route but the `WebSocketUpgrade` extractor rejects it with 400
    // because the request is missing the required upgrade headers
    // (`Connection: Upgrade`, `Upgrade: websocket`, `Sec-WebSocket-Key`).
    // This is the correct, expected behavior — the endpoint exists but
    // cannot be used without a proper WS handshake.
    let req = Request::get("/ws/test-room?device_id=dev1")
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::BAD_REQUEST,
        "plain GET to /ws/ should be rejected by the WebSocketUpgrade extractor"
    );
}

#[tokio::test]
async fn test_ws_missing_room_id_segment() {
    let app = test_app();

    // /ws without a room_id path segment → no route match → 404
    let req = Request::get("/ws").body(Body::empty()).unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ---------------------------------------------------------------------------
// CORS headers
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_cors_headers_present() {
    let app = test_app_with_origins(vec!["https://app.horcrux.io".into()]);

    let req = Request::get("/health")
        .header("origin", "https://app.horcrux.io")
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    assert!(
        resp.headers().contains_key("access-control-allow-origin"),
        "expected CORS allow-origin header in response"
    );
}

#[tokio::test]
async fn test_cors_permissive_without_origins() {
    // Default config has no allowed_origins → permissive CORS
    let app = test_app();

    let req = Request::get("/health")
        .header("origin", "https://anything.example.com")
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    assert!(
        resp.headers().contains_key("access-control-allow-origin"),
        "permissive CORS should reflect origin"
    );
}

// ---------------------------------------------------------------------------
// Metrics counters and admin endpoints
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_metrics_counters_reflect_rooms() {
    let (app, rooms) = test_app_with_admin_token("tok");

    // Create a room via the RoomManager directly
    let _join = rooms
        .join_room_with_token("integration-room-1", Some("secret"), "device-a")
        .await
        .unwrap();

    // /admin/rooms should show the room
    let req = Request::get("/admin/rooms?admin_token=tok")
        .body(Body::empty())
        .unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body: serde_json::Value =
        serde_json::from_str(&body_string(resp.into_body()).await).unwrap();
    assert_eq!(body["count"], 1);

    // /metrics should also report 1 active room
    let req = Request::get("/metrics?admin_token=tok")
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    let text = body_string(resp.into_body()).await;
    assert!(
        text.contains("horcrux_active_rooms 1"),
        "expected active_rooms 1 in metrics, got: {text}"
    );
}

#[tokio::test]
async fn test_health_uptime_increases() {
    // Initialize start time (idempotent — may have been set by another test).
    horcrux_relay::init_start_time();

    let app = test_app();

    let req = Request::get("/health").body(Body::empty()).unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    let body1: serde_json::Value =
        serde_json::from_str(&body_string(resp.into_body()).await).unwrap();
    let uptime1 = body1["uptime_seconds"].as_u64().unwrap();

    // Small sleep to advance the clock
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let req = Request::get("/health").body(Body::empty()).unwrap();
    let resp = app.oneshot(req).await.unwrap();
    let body2: serde_json::Value =
        serde_json::from_str(&body_string(resp.into_body()).await).unwrap();
    let uptime2 = body2["uptime_seconds"].as_u64().unwrap();

    // Uptime in seconds — at minimum it should not go backwards.
    assert!(uptime2 >= uptime1, "uptime should not decrease");
}

// ---------------------------------------------------------------------------
// Admin endpoints
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_admin_rooms_protected() {
    let (app, _rooms) = test_app_with_admin_token("admin123");

    // Without token → FORBIDDEN
    let req = Request::get("/admin/rooms").body(Body::empty()).unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // With correct header token → OK
    let req = Request::get("/admin/rooms")
        .header("x-admin-token", "admin123")
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn test_admin_rooms_lists_rooms() {
    let (app, rooms) = test_app_with_admin_token("tok");

    // Join two rooms
    let _ = rooms
        .join_room_with_token("room-a", Some("t1"), "d1")
        .await
        .unwrap();
    let _ = rooms
        .join_room_with_token("room-b", Some("t2"), "d2")
        .await
        .unwrap();

    let req = Request::get("/admin/rooms?admin_token=tok")
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    let body: serde_json::Value =
        serde_json::from_str(&body_string(resp.into_body()).await).unwrap();

    assert_eq!(body["count"], 2);
    let rooms_arr = body["rooms"].as_array().unwrap();
    assert_eq!(rooms_arr.len(), 2);
}

// ---------------------------------------------------------------------------
// Global metrics counter smoke-test
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_global_metrics_rooms_created() {
    use std::sync::atomic::Ordering;

    let before = METRICS.rooms_created.load(Ordering::Relaxed);

    let config = RelayConfig::default();
    let rooms = room::new(&config);
    let _ = rooms
        .join_room_with_token("metric-test-room", Some("tok"), "dev1")
        .await
        .unwrap();

    let after = METRICS.rooms_created.load(Ordering::Relaxed);
    assert!(
        after > before,
        "rooms_created should increment after creating a room"
    );
}
