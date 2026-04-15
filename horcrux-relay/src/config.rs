//! Server configuration — centralized, environment-driven.

use std::time::Duration;

/// All relay configuration in one place.
#[derive(Debug, Clone)]
pub struct RelayConfig {
    pub host: String,
    pub port: u16,
    /// Room time-to-live before auto-cleanup.
    pub room_ttl: Duration,
    /// How often the cleanup task runs.
    pub cleanup_interval: Duration,
    /// Maximum participants per room.
    pub max_participants: usize,
    /// Maximum WebSocket message size in bytes.
    pub max_message_size: usize,
    /// WebSocket ping interval.
    pub ping_interval: Duration,
    /// Pong timeout — disconnect if no pong within this duration.
    pub pong_timeout: Duration,
    /// Per-connection message rate limit (messages per window).
    pub rate_limit_count: u32,
    /// Rate limit sliding window duration.
    pub rate_limit_window: Duration,
    /// Whether /admin endpoints require the admin token.
    pub admin_token: Option<String>,
    /// Allowed WebSocket origins for CSWSH protection.
    /// None = allow all (development mode).
    /// Some(["https://app.horcrux.io"]) = only allow listed origins.
    pub allowed_origins: Option<Vec<String>>,
    /// Max WS connections per IP within the rate-limit window.
    pub ip_rate_limit_creates: u32,
    /// IP rate-limit sliding window.
    pub ip_rate_limit_window: Duration,
}

impl Default for RelayConfig {
    fn default() -> Self {
        Self {
            host: "0.0.0.0".into(),
            port: 3210,
            room_ttl: Duration::from_secs(600),
            cleanup_interval: Duration::from_secs(30),
            max_participants: 10,
            max_message_size: 1_048_576, // 1 MB
            ping_interval: Duration::from_secs(30),
            pong_timeout: Duration::from_secs(10),
            rate_limit_count: 100,
            rate_limit_window: Duration::from_secs(10),
            admin_token: None,
            allowed_origins: None,
            ip_rate_limit_creates: 20,
            ip_rate_limit_window: Duration::from_secs(60),
        }
    }
}

impl RelayConfig {
    /// Load configuration from environment variables (with sane defaults).
    pub fn from_env() -> Self {
        let mut cfg = Self::default();
        if let Ok(v) = std::env::var("RELAY_HOST") { cfg.host = v; }
        if let Ok(v) = std::env::var("RELAY_PORT") {
            if let Ok(p) = v.parse() { cfg.port = p; }
        }
        if let Ok(v) = std::env::var("RELAY_ROOM_TTL_SECS") {
            if let Ok(s) = v.parse::<u64>() { cfg.room_ttl = Duration::from_secs(s); }
        }
        if let Ok(v) = std::env::var("RELAY_MAX_PARTICIPANTS") {
            if let Ok(n) = v.parse::<usize>() {
                cfg.max_participants = n.clamp(1, 100);
            }
        }
        if let Ok(v) = std::env::var("RELAY_MAX_MESSAGE_SIZE") {
            if let Ok(n) = v.parse::<usize>() {
                cfg.max_message_size = n.clamp(1024, 100_000_000);
            }
        }
        if let Ok(v) = std::env::var("RELAY_RATE_LIMIT") {
            if let Ok(n) = v.parse::<u32>() {
                cfg.rate_limit_count = n.clamp(1, 10_000);
            }
        }
        if let Ok(v) = std::env::var("RELAY_ADMIN_TOKEN") {
            cfg.admin_token = Some(v);
        }
        if let Ok(v) = std::env::var("RELAY_ALLOWED_ORIGINS") {
            cfg.allowed_origins = Some(
                v.split(',').map(|s| s.trim().to_string()).collect()
            );
        }
        cfg
    }

    /// Validate config values at startup. Panics on invalid configuration.
    pub fn validate(&self) {
        assert!(self.max_participants > 0, "max_participants must be > 0");
        assert!(self.max_message_size > 0, "max_message_size must be > 0");
        assert!(self.rate_limit_count > 0, "rate_limit_count must be > 0");
        assert!(self.ip_rate_limit_creates > 0, "ip_rate_limit_creates must be > 0");
        if self.admin_token.is_none() {
            tracing::warn!("RELAY_ADMIN_TOKEN not set — admin endpoints are unprotected");
        }
    }
}
