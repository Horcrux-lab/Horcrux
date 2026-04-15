//! Lightweight metrics — no external dependency, just atomics.
//!
//! Exposes counters for operational observability without pulling in
//! a full Prometheus client.

use std::sync::atomic::{AtomicU64, Ordering};

/// Global relay metrics (singleton, zero-cost when not read).
pub static METRICS: Metrics = Metrics::new();

pub struct Metrics {
    pub connections_total: AtomicU64,
    pub connections_active: AtomicU64,
    pub messages_relayed: AtomicU64,
    pub messages_rejected: AtomicU64,
    pub rooms_created: AtomicU64,
    pub rooms_expired: AtomicU64,
    pub auth_failures: AtomicU64,
    pub rate_limited: AtomicU64,
}

impl Metrics {
    const fn new() -> Self {
        Self {
            connections_total: AtomicU64::new(0),
            connections_active: AtomicU64::new(0),
            messages_relayed: AtomicU64::new(0),
            messages_rejected: AtomicU64::new(0),
            rooms_created: AtomicU64::new(0),
            rooms_expired: AtomicU64::new(0),
            auth_failures: AtomicU64::new(0),
            rate_limited: AtomicU64::new(0),
        }
    }

    /// Render metrics as Prometheus text exposition format.
    pub fn render(&self) -> String {
        format!(
            "# HELP horcrux_connections_total Total WebSocket connections since startup\n\
             # TYPE horcrux_connections_total counter\n\
             horcrux_connections_total {}\n\
             # HELP horcrux_connections_active Currently active WebSocket connections\n\
             # TYPE horcrux_connections_active gauge\n\
             horcrux_connections_active {}\n\
             # HELP horcrux_messages_relayed Total messages successfully relayed\n\
             # TYPE horcrux_messages_relayed counter\n\
             horcrux_messages_relayed {}\n\
             # HELP horcrux_messages_rejected Total messages rejected (malformed/oversized)\n\
             # TYPE horcrux_messages_rejected counter\n\
             horcrux_messages_rejected {}\n\
             # HELP horcrux_rooms_created Total rooms created since startup\n\
             # TYPE horcrux_rooms_created counter\n\
             horcrux_rooms_created {}\n\
             # HELP horcrux_rooms_expired Total rooms cleaned up due to TTL expiry\n\
             # TYPE horcrux_rooms_expired counter\n\
             horcrux_rooms_expired {}\n\
             # HELP horcrux_auth_failures Total authentication/token failures\n\
             # TYPE horcrux_auth_failures counter\n\
             horcrux_auth_failures {}\n\
             # HELP horcrux_rate_limited Total messages dropped due to rate limiting\n\
             # TYPE horcrux_rate_limited counter\n\
             horcrux_rate_limited {}\n",
            self.connections_total.load(Ordering::Relaxed),
            self.connections_active.load(Ordering::Relaxed),
            self.messages_relayed.load(Ordering::Relaxed),
            self.messages_rejected.load(Ordering::Relaxed),
            self.rooms_created.load(Ordering::Relaxed),
            self.rooms_expired.load(Ordering::Relaxed),
            self.auth_failures.load(Ordering::Relaxed),
            self.rate_limited.load(Ordering::Relaxed),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;

    #[test]
    fn test_metrics_render() {
        let m = Metrics::new();
        m.connections_total.store(42, Ordering::Relaxed);
        m.messages_relayed.store(100, Ordering::Relaxed);
        let output = m.render();
        assert!(output.contains("horcrux_connections_total 42"));
        assert!(output.contains("horcrux_messages_relayed 100"));
    }

    #[test]
    fn test_metrics_increment() {
        let m = Metrics::new();
        m.connections_active.fetch_add(1, Ordering::Relaxed);
        m.connections_active.fetch_add(1, Ordering::Relaxed);
        assert_eq!(m.connections_active.load(Ordering::Relaxed), 2);
        m.connections_active.fetch_sub(1, Ordering::Relaxed);
        assert_eq!(m.connections_active.load(Ordering::Relaxed), 1);
    }
}
