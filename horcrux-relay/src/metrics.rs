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
    ///
    /// `active_rooms` is passed in because it comes from the `RoomManager`,
    /// not from an atomic counter.
    pub fn render(&self, active_rooms: usize) -> String {
        format!(
            "# HELP horcrux_connections_total Total WebSocket connections since startup\n\
             # TYPE horcrux_connections_total counter\n\
             horcrux_connections_total {}\n\n\
             # HELP horcrux_active_connections Current WebSocket connections\n\
             # TYPE horcrux_active_connections gauge\n\
             horcrux_active_connections {}\n\n\
             # HELP horcrux_messages_relayed_total Total messages relayed\n\
             # TYPE horcrux_messages_relayed_total counter\n\
             horcrux_messages_relayed_total {}\n\n\
             # HELP horcrux_messages_rejected_total Total messages rejected\n\
             # TYPE horcrux_messages_rejected_total counter\n\
             horcrux_messages_rejected_total {}\n\n\
             # HELP horcrux_rooms_created_total Total rooms created\n\
             # TYPE horcrux_rooms_created_total counter\n\
             horcrux_rooms_created_total {}\n\n\
             # HELP horcrux_rooms_expired_total Total rooms cleaned up due to TTL expiry\n\
             # TYPE horcrux_rooms_expired_total counter\n\
             horcrux_rooms_expired_total {}\n\n\
             # HELP horcrux_auth_failures_total Total auth failures\n\
             # TYPE horcrux_auth_failures_total counter\n\
             horcrux_auth_failures_total {}\n\n\
             # HELP horcrux_rate_limited_total Total messages dropped due to rate limiting\n\
             # TYPE horcrux_rate_limited_total counter\n\
             horcrux_rate_limited_total {}\n\n\
             # HELP horcrux_active_rooms Current active rooms\n\
             # TYPE horcrux_active_rooms gauge\n\
             horcrux_active_rooms {}\n",
            self.connections_total.load(Ordering::Relaxed),
            self.connections_active.load(Ordering::Relaxed),
            self.messages_relayed.load(Ordering::Relaxed),
            self.messages_rejected.load(Ordering::Relaxed),
            self.rooms_created.load(Ordering::Relaxed),
            self.rooms_expired.load(Ordering::Relaxed),
            self.auth_failures.load(Ordering::Relaxed),
            self.rate_limited.load(Ordering::Relaxed),
            active_rooms,
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
        let output = m.render(3);
        assert!(output.contains("horcrux_connections_total 42"));
        assert!(output.contains("horcrux_messages_relayed_total 100"));
        assert!(output.contains("horcrux_active_rooms 3"));
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

    #[test]
    fn test_metrics_prometheus_format() {
        let m = Metrics::new();
        m.rooms_created.store(5, Ordering::Relaxed);
        m.auth_failures.store(2, Ordering::Relaxed);
        m.messages_rejected.store(1, Ordering::Relaxed);
        m.connections_active.store(7, Ordering::Relaxed);
        let output = m.render(4);

        // Counters must have # TYPE ... counter headers
        assert!(output.contains("# TYPE horcrux_rooms_created_total counter"));
        assert!(output.contains("# TYPE horcrux_messages_relayed_total counter"));
        assert!(output.contains("# TYPE horcrux_auth_failures_total counter"));
        assert!(output.contains("# TYPE horcrux_messages_rejected_total counter"));
        assert!(output.contains("# TYPE horcrux_rooms_expired_total counter"));
        assert!(output.contains("# TYPE horcrux_rate_limited_total counter"));

        // Gauges must have # TYPE ... gauge headers
        assert!(output.contains("# TYPE horcrux_active_rooms gauge"));
        assert!(output.contains("# TYPE horcrux_active_connections gauge"));

        // Verify values
        assert!(output.contains("horcrux_rooms_created_total 5"));
        assert!(output.contains("horcrux_auth_failures_total 2"));
        assert!(output.contains("horcrux_messages_rejected_total 1"));
        assert!(output.contains("horcrux_active_connections 7"));
        assert!(output.contains("horcrux_active_rooms 4"));
    }
}
