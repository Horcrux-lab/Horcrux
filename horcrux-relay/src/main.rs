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

use std::net::SocketAddr;
use tracing_subscriber::EnvFilter;

use horcrux_relay::config::RelayConfig;
use horcrux_relay::ip_ratelimit::IpRateLimiter;
use horcrux_relay::room;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("horcrux_relay=info".parse()?))
        .init();

    horcrux_relay::init_start_time();

    let config = RelayConfig::from_env();
    config.validate()?;
    let room_state = room::new(&config);
    let _cleanup_handle = room::spawn_cleanup_task(room_state.clone());
    let ip_limiter = std::sync::Arc::new(IpRateLimiter::new(
        config.ip_rate_limit_creates,
        config.ip_rate_limit_window,
    ));
    // GC stale IP entries alongside room cleanup
    {
        let limiter = ip_limiter.clone();
        let interval_dur = config.cleanup_interval;
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(interval_dur);
            loop {
                interval.tick().await;
                limiter.gc();
            }
        });
    }

    let addr = format!("{}:{}", config.host, config.port);

    let state: horcrux_relay::AppState = (room_state, config, ip_limiter);
    let app = horcrux_relay::build_app(state);

    tracing::info!("Horcrux Relay listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr).await?;

    // Graceful shutdown on SIGINT / SIGTERM
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await?;

    tracing::info!("Relay shut down gracefully");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        if let Err(e) = tokio::signal::ctrl_c().await {
            tracing::error!("failed to install Ctrl+C handler: {e}");
            std::future::pending::<()>().await;
        }
    };

    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut sig) => {
                sig.recv().await;
            }
            Err(e) => {
                tracing::error!("failed to install SIGTERM handler: {e}");
                std::future::pending::<()>().await;
            }
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => tracing::info!("received SIGINT, shutting down"),
        _ = terminate => tracing::info!("received SIGTERM, shutting down"),
    }
}
