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
    /// `None` = allow all (development mode).
    /// `Some(["https://app.horcrux.io"])` = only allow listed origins.
    pub allowed_origins: Option<Vec<String>>,
    /// Max WS connections per IP within the rate-limit window.
    pub ip_rate_limit_creates: u32,
    /// IP rate-limit sliding window.
    pub ip_rate_limit_window: Duration,
    /// Maximum number of concurrent rooms (prevents OOM DoS).
    pub max_rooms: usize,
}

/// Configuration validation errors.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("max_participants must be > 0")]
    InvalidMaxParticipants,
    #[error("max_message_size must be > 0")]
    InvalidMaxMessageSize,
    #[error("rate_limit_count must be > 0")]
    InvalidRateLimitCount,
    #[error("ip_rate_limit_creates must be > 0")]
    InvalidIpRateLimitCreates,
    #[error("max_rooms must be > 0")]
    InvalidMaxRooms,
    #[error("ping_interval must be greater than pong_timeout")]
    InvalidPingPongTiming,
    #[error("RELAY_ADMIN_TOKEN must be set when binding to a non-loopback host ({host}); set RELAY_ALLOW_UNAUTHENTICATED_ADMIN=1 to override")]
    AdminEndpointsExposed { host: String },
}

impl Default for RelayConfig {
    fn default() -> Self {
        Self {
            host: "0.0.0.0".into(),
            port: 3210,
            room_ttl: Duration::from_secs(600),
            cleanup_interval: Duration::from_secs(30),
            max_participants: 10,
            max_message_size: 4_194_304, // 4 MB — CGGMP21 Paillier proofs can be ~1.2 MB
            ping_interval: Duration::from_secs(300),
            pong_timeout: Duration::from_secs(60),
            rate_limit_count: 100,
            rate_limit_window: Duration::from_secs(10),
            admin_token: None,
            allowed_origins: None,
            ip_rate_limit_creates: 20,
            ip_rate_limit_window: Duration::from_secs(60),
            max_rooms: 10_000,
        }
    }
}

impl RelayConfig {
    /// Load configuration from environment variables (with sane defaults).
    pub fn from_env() -> Self {
        let mut cfg = Self::default();
        if let Ok(v) = std::env::var("RELAY_HOST") {
            cfg.host = v;
        }
        if let Ok(v) = std::env::var("RELAY_PORT") {
            if let Ok(p) = v.parse() {
                cfg.port = p;
            }
        }
        if let Ok(v) = std::env::var("RELAY_ROOM_TTL_SECS") {
            if let Ok(s) = v.parse::<u64>() {
                cfg.room_ttl = Duration::from_secs(s);
            }
        }
        if let Ok(v) = std::env::var("RELAY_MAX_PARTICIPANTS") {
            if let Ok(n) = v.parse::<usize>() {
                let clamped = n.clamp(1, 100);
                if clamped != n {
                    tracing::warn!(
                        env = "RELAY_MAX_PARTICIPANTS",
                        raw = n,
                        clamped,
                        "value clamped to safe range [1, 100]"
                    );
                }
                cfg.max_participants = clamped;
            }
        }
        if let Ok(v) = std::env::var("RELAY_MAX_MESSAGE_SIZE") {
            if let Ok(n) = v.parse::<usize>() {
                let clamped = n.clamp(1024, 100_000_000);
                if clamped != n {
                    tracing::warn!(
                        env = "RELAY_MAX_MESSAGE_SIZE",
                        raw = n,
                        clamped,
                        "value clamped to safe range [1024, 100000000]"
                    );
                }
                cfg.max_message_size = clamped;
            }
        }
        if let Ok(v) = std::env::var("RELAY_RATE_LIMIT") {
            if let Ok(n) = v.parse::<u32>() {
                let clamped = n.clamp(1, 10_000);
                if clamped != n {
                    tracing::warn!(
                        env = "RELAY_RATE_LIMIT",
                        raw = n,
                        clamped,
                        "value clamped to safe range [1, 10000]"
                    );
                }
                cfg.rate_limit_count = clamped;
            }
        }
        if let Ok(v) = std::env::var("RELAY_ADMIN_TOKEN") {
            cfg.admin_token = Some(v);
        }
        if let Ok(v) = std::env::var("RELAY_ALLOWED_ORIGINS") {
            cfg.allowed_origins = Some(v.split(',').map(|s| s.trim().to_string()).collect());
        }
        if let Ok(v) = std::env::var("RELAY_MAX_ROOMS") {
            if let Ok(n) = v.parse::<usize>() {
                let clamped = n.clamp(1, 1_000_000);
                if clamped != n {
                    tracing::warn!(
                        env = "RELAY_MAX_ROOMS",
                        raw = n,
                        clamped,
                        "value clamped to safe range [1, 1000000]"
                    );
                }
                cfg.max_rooms = clamped;
            }
        }
        cfg
    }

    /// Validate config values at startup. Returns error on invalid configuration.
    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.max_participants == 0 {
            return Err(ConfigError::InvalidMaxParticipants);
        }
        if self.max_message_size == 0 {
            return Err(ConfigError::InvalidMaxMessageSize);
        }
        if self.rate_limit_count == 0 {
            return Err(ConfigError::InvalidRateLimitCount);
        }
        if self.ip_rate_limit_creates == 0 {
            return Err(ConfigError::InvalidIpRateLimitCreates);
        }
        if self.max_rooms == 0 {
            return Err(ConfigError::InvalidMaxRooms);
        }
        if self.ping_interval <= self.pong_timeout {
            return Err(ConfigError::InvalidPingPongTiming);
        }
        if self.admin_token.is_none() {
            // A missing admin token only matters if the relay is reachable
            // from outside the host. Loopback-only deployments (127.0.0.1,
            // ::1, localhost) are a dev-convenience case — keep the warn
            // but boot. Anything else is almost certainly production and
            // we refuse to expose `/admin/rooms` + `/metrics` publicly
            // unless the operator opts in explicitly.
            let loopback_bind = matches!(
                self.host.as_str(),
                "127.0.0.1" | "::1" | "localhost"
            );
            let override_env = std::env::var("RELAY_ALLOW_UNAUTHENTICATED_ADMIN")
                .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                .unwrap_or(false);
            if loopback_bind || override_env {
                tracing::warn!("RELAY_ADMIN_TOKEN not set — admin endpoints are unprotected");
            } else {
                return Err(ConfigError::AdminEndpointsExposed {
                    host: self.host.clone(),
                });
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_validation_covers_admin_exposure() {
        // Merge the admin-exposure scenarios into one test so that env
        // mutation (`RELAY_ALLOW_UNAUTHENTICATED_ADMIN`) is sequential
        // and cannot race cargo's parallel test runner.
        unsafe {
            std::env::remove_var("RELAY_ALLOW_UNAUTHENTICATED_ADMIN");
        }

        // Default host 0.0.0.0 + no token → refuses.
        assert!(matches!(
            RelayConfig::default().validate(),
            Err(ConfigError::AdminEndpointsExposed { .. })
        ));

        // Explicit token → OK.
        let cfg_with_token = RelayConfig {
            admin_token: Some("dev-token".into()),
            ..Default::default()
        };
        assert!(cfg_with_token.validate().is_ok());

        // Loopback bind, no token → OK (dev convenience, still warns).
        let cfg_local = RelayConfig {
            host: "127.0.0.1".into(),
            ..Default::default()
        };
        assert!(cfg_local.validate().is_ok());

        // Explicit override env → OK even on 0.0.0.0 with no token.
        unsafe {
            std::env::set_var("RELAY_ALLOW_UNAUTHENTICATED_ADMIN", "1");
        }
        assert!(RelayConfig::default().validate().is_ok());
        unsafe {
            std::env::remove_var("RELAY_ALLOW_UNAUTHENTICATED_ADMIN");
        }
    }

    #[test]
    fn zero_max_participants_fails() {
        let cfg = RelayConfig {
            max_participants: 0,
            ..Default::default()
        };
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::InvalidMaxParticipants)
        ));
    }

    #[test]
    fn zero_max_rooms_fails() {
        let cfg = RelayConfig {
            max_rooms: 0,
            ..Default::default()
        };
        assert!(matches!(cfg.validate(), Err(ConfigError::InvalidMaxRooms)));
    }

    #[test]
    fn zero_rate_limit_fails() {
        let cfg = RelayConfig {
            rate_limit_count: 0,
            ..Default::default()
        };
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::InvalidRateLimitCount)
        ));
    }

    #[test]
    fn ping_lte_pong_fails() {
        let cfg = RelayConfig {
            ping_interval: Duration::from_secs(5),
            pong_timeout: Duration::from_secs(10),
            ..Default::default()
        };
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::InvalidPingPongTiming)
        ));

        let cfg2 = RelayConfig {
            ping_interval: Duration::from_secs(10),
            pong_timeout: Duration::from_secs(10),
            ..Default::default()
        };
        assert!(matches!(
            cfg2.validate(),
            Err(ConfigError::InvalidPingPongTiming)
        ));
    }
}
