//! Per-IP rate limiting for room creation to prevent DoS.
//!
//! Uses a sliding-window counter per IP address. Stale entries are
//! garbage-collected periodically by the same cleanup task that prunes rooms.

use parking_lot::Mutex;
use std::collections::HashMap;
use std::net::IpAddr;
use std::time::{Duration, Instant};

/// Tracks per-IP room creation attempts.
pub struct IpRateLimiter {
    /// Max room creations per IP per window.
    max_creates: u32,
    /// Sliding window duration.
    window: Duration,
    /// IP → list of creation timestamps (sorted ascending).
    entries: Mutex<HashMap<IpAddr, Vec<Instant>>>,
    /// Maximum tracked IPs before forced eviction.
    max_entries: usize,
}

impl IpRateLimiter {
    /// Create a new per-IP rate limiter.
    ///
    /// * `max_creates` — maximum room creations allowed per IP within the window.
    /// * `window` — sliding time window for the rate limit.
    pub fn new(max_creates: u32, window: Duration) -> Self {
        Self {
            max_creates,
            window,
            entries: Mutex::new(HashMap::new()),
            max_entries: 10_000,
        }
    }

    /// Check if the IP may create a room. Returns `true` if allowed.
    pub fn try_create(&self, ip: IpAddr) -> bool {
        let now = Instant::now();
        let cutoff = now - self.window;
        let mut map = self.entries.lock();
        let timestamps = map.entry(ip).or_default();

        // Remove expired entries
        timestamps.retain(|t| *t > cutoff);

        if timestamps.len() < self.max_creates as usize {
            timestamps.push(now);
            true
        } else {
            false
        }
    }

    /// Garbage-collect stale IPs. Call periodically (e.g., from cleanup task).
    /// Also evicts oldest entries if the map exceeds `max_entries`.
    pub fn gc(&self) {
        let now = Instant::now();
        let cutoff = now - self.window;
        let mut map = self.entries.lock();
        map.retain(|_ip, timestamps| {
            timestamps.retain(|t| *t > cutoff);
            !timestamps.is_empty()
        });
        // Circuit-breaker: if too many tracked IPs, force evict oldest half.
        if map.len() > self.max_entries {
            let to_remove = map.len() / 2;
            let mut entries_by_age: Vec<(IpAddr, Instant)> = map
                .iter()
                .map(|(ip, ts)| (*ip, ts.last().copied().unwrap_or(now)))
                .collect();
            entries_by_age.sort_by_key(|(_, t)| *t);
            for (ip, _) in entries_by_age.into_iter().take(to_remove) {
                map.remove(&ip);
            }
            tracing::warn!(
                evicted = to_remove,
                remaining = map.len(),
                "IP rate limiter eviction"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    #[test]
    fn allows_under_limit() {
        let limiter = IpRateLimiter::new(3, Duration::from_secs(60));
        let ip = IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1));
        assert!(limiter.try_create(ip));
        assert!(limiter.try_create(ip));
        assert!(limiter.try_create(ip));
    }

    #[test]
    fn blocks_over_limit() {
        let limiter = IpRateLimiter::new(2, Duration::from_secs(60));
        let ip = IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1));
        assert!(limiter.try_create(ip));
        assert!(limiter.try_create(ip));
        assert!(!limiter.try_create(ip));
    }

    #[test]
    fn different_ips_independent() {
        let limiter = IpRateLimiter::new(1, Duration::from_secs(60));
        let ip1 = IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1));
        let ip2 = IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2));
        assert!(limiter.try_create(ip1));
        assert!(!limiter.try_create(ip1));
        assert!(limiter.try_create(ip2)); // different IP
    }

    #[test]
    fn gc_clears_stale() {
        let limiter = IpRateLimiter::new(1, Duration::from_millis(10));
        let ip = IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1));
        assert!(limiter.try_create(ip));
        assert!(!limiter.try_create(ip));
        std::thread::sleep(Duration::from_millis(50));
        limiter.gc();
        assert!(limiter.try_create(ip)); // window expired
    }
}
