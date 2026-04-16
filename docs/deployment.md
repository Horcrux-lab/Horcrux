# Horcrux Relay — Production Deployment Guide

> Deployment, configuration, monitoring, and operational guidance for the
> `horcrux-relay` WebSocket relay server.

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Environment Variables Reference](#2-environment-variables-reference)
3. [Health & Monitoring](#3-health--monitoring)
4. [TLS Configuration](#4-tls-configuration)
5. [Scaling Strategy](#5-scaling-strategy)
6. [Resource Recommendations](#6-resource-recommendations)
7. [Security Hardening](#7-security-hardening)
8. [Docker Compose Example](#8-docker-compose-example)
9. [Kubernetes Deployment](#9-kubernetes-deployment)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Quick Start

### Build the Docker image

```bash
docker build -t horcrux-relay .
```

### Run with minimum viable configuration

```bash
docker run -d \
  --name horcrux-relay \
  -p 3000:8080 \
  -e RELAY_ADMIN_TOKEN="$(openssl rand -hex 32)" \
  -e RELAY_ALLOWED_ORIGINS="https://app.horcrux.io" \
  horcrux-relay
```

The Dockerfile defaults to port **8080** (`RELAY_PORT=8080`), so map it to
whichever host port you prefer.

### Verify it's running

```bash
curl http://localhost:3000/health
```

Expected response:

```json
{
  "status": "ok",
  "version": "0.2.0",
  "uptime_seconds": 12,
  "active_rooms": 0,
  "active_connections": 0
}
```

### Run without Docker

```bash
cargo build --release -p horcrux-relay
RELAY_PORT=8080 RELAY_ADMIN_TOKEN=secret ./target/release/horcrux-relay
```

---

## 2. Environment Variables Reference

### Configurable via Environment

| Variable | Default | Accepted Range | Description |
|----------|---------|---------------|-------------|
| `RELAY_HOST` | `0.0.0.0` | Any valid IP/hostname | Bind address for the listener |
| `RELAY_PORT` | `3210`¹ | 1–65535 | TCP port to listen on |
| `RELAY_ROOM_TTL_SECS` | `600` (10 min) | Any `u64` | Room time-to-live before auto-cleanup |
| `RELAY_MAX_PARTICIPANTS` | `10` | 1–100 (clamped) | Maximum participants per room |
| `RELAY_MAX_MESSAGE_SIZE` | `1048576` (1 MB) | 1024–100000000 (clamped) | Maximum WebSocket message size in bytes |
| `RELAY_RATE_LIMIT` | `100` | 1–10000 (clamped) | Per-connection message rate limit (messages per window) |
| `RELAY_ADMIN_TOKEN` | *None* | Any string | Bearer token protecting `/metrics` and `/admin/*` endpoints |
| `RELAY_ALLOWED_ORIGINS` | *None (permissive)* | Comma-separated URLs | Allowed WebSocket origins for CORS/CSWSH protection |
| `RUST_LOG` | `horcrux_relay=info` | [tracing directives] | Log level filter (e.g. `debug`, `horcrux_relay=trace`) |

> ¹ The Dockerfile overrides `RELAY_PORT` to `8080`. The Rust code default is `3210`.

### Hardcoded Defaults (not env-configurable)

These values are compiled into the binary. Override requires a code change:

| Parameter | Value | Description |
|-----------|-------|-------------|
| Cleanup interval | 30 s | How often the TTL cleanup task runs |
| Ping interval | 30 s | WebSocket ping interval |
| Pong timeout | 10 s | Disconnect if no pong received within this window |
| Rate limit window | 10 s | Sliding window for per-connection rate limiting |
| IP rate limit (creates) | 20 | Max new WebSocket connections per IP per window |
| IP rate limit window | 60 s | Sliding window for per-IP connection throttle |

### Example: Production environment file

```env
# .env.production
RELAY_HOST=0.0.0.0
RELAY_PORT=8080
RELAY_ROOM_TTL_SECS=600
RELAY_MAX_PARTICIPANTS=10
RELAY_MAX_MESSAGE_SIZE=1048576
RELAY_RATE_LIMIT=100
RELAY_ADMIN_TOKEN=a3f8c92e1b4d7f60e5a2c8d9b1f4e7a3c6d9f2b5e8a1c4d7f0e3b6a9c2d5f8
RELAY_ALLOWED_ORIGINS=https://app.horcrux.io,https://staging.horcrux.io
RUST_LOG=horcrux_relay=info
```

---

## 3. Health & Monitoring

### `/health` — Health Check

Unauthenticated. Returns server status and basic stats.

```bash
curl -s http://localhost:8080/health | jq .
```

```json
{
  "status": "ok",
  "version": "0.2.0",
  "uptime_seconds": 3600,
  "active_rooms": 12,
  "active_connections": 24
}
```

Use this for load-balancer health checks and container orchestrator liveness
probes. The Dockerfile includes a built-in `HEALTHCHECK` that calls this
endpoint every 30 seconds.

### `/metrics` — Prometheus Metrics

Protected by `RELAY_ADMIN_TOKEN` when set. Returns Prometheus text exposition
format (`text/plain; version=0.0.4`).

**Authentication** (two methods):

```bash
# Header-based
curl -H "x-admin-token: YOUR_TOKEN" http://localhost:8080/metrics

# Query parameter
curl "http://localhost:8080/metrics?admin_token=YOUR_TOKEN"
```

**Available metrics:**

| Metric | Type | Description |
|--------|------|-------------|
| `horcrux_connections_total` | counter | Total WebSocket connections since startup |
| `horcrux_active_connections` | gauge | Current open WebSocket connections |
| `horcrux_messages_relayed_total` | counter | Total messages successfully relayed |
| `horcrux_messages_rejected_total` | counter | Total messages rejected (validation failures) |
| `horcrux_rooms_created_total` | counter | Total rooms created since startup |
| `horcrux_rooms_expired_total` | counter | Total rooms cleaned up due to TTL expiry |
| `horcrux_auth_failures_total` | counter | Total authentication failures |
| `horcrux_rate_limited_total` | counter | Total messages dropped due to rate limiting |
| `horcrux_active_rooms` | gauge | Current number of active rooms |

### `/admin/rooms` — Room Inspector

Protected by `RELAY_ADMIN_TOKEN`. Returns detailed room state.

```bash
curl -H "x-admin-token: YOUR_TOKEN" http://localhost:8080/admin/rooms | jq .
```

```json
{
  "count": 2,
  "rooms": [ ... ]
}
```

### Prometheus Scrape Config

```yaml
# prometheus.yml
scrape_configs:
  - job_name: "horcrux-relay"
    scheme: http
    metrics_path: /metrics
    params:
      admin_token: ["YOUR_ADMIN_TOKEN"]
    static_configs:
      - targets: ["relay:8080"]
    scrape_interval: 15s
```

### Grafana Dashboard Queries

**Active connections over time:**

```promql
horcrux_active_connections
```

**Message relay rate (per second):**

```promql
rate(horcrux_messages_relayed_total[5m])
```

**Room creation rate:**

```promql
rate(horcrux_rooms_created_total[5m])
```

**Rate-limit events (alert on spikes):**

```promql
rate(horcrux_rate_limited_total[5m]) > 0
```

**Auth failure rate (possible attack indicator):**

```promql
rate(horcrux_auth_failures_total[5m]) > 1
```

**Room turnover (created vs. expired):**

```promql
rate(horcrux_rooms_created_total[5m]) - rate(horcrux_rooms_expired_total[5m])
```

**Connection churn:**

```promql
rate(horcrux_connections_total[5m]) - horcrux_active_connections
```

---

## 4. TLS Configuration

The relay **does not terminate TLS itself**. Use a reverse proxy in front of it
for TLS termination and WebSocket upgrade handling.

### nginx Reverse Proxy

```nginx
upstream relay {
    server 127.0.0.1:8080;
}

server {
    listen 443 ssl http2;
    server_name relay.horcrux.io;

    ssl_certificate     /etc/letsencrypt/live/relay.horcrux.io/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/relay.horcrux.io/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # WebSocket proxy
    location /ws/ {
        proxy_pass http://relay;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # Health & metrics (non-WebSocket)
    location / {
        proxy_pass http://relay;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}

# HTTP → HTTPS redirect
server {
    listen 80;
    server_name relay.horcrux.io;
    return 301 https://$host$request_uri;
}
```

### Caddy (simpler — auto Let's Encrypt)

```caddyfile
relay.horcrux.io {
    reverse_proxy localhost:8080
}
```

Caddy handles TLS certificates, WebSocket upgrade, and HTTP→HTTPS redirects
automatically. This is the recommended option for simple deployments.

### Let's Encrypt with certbot (for nginx)

```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d relay.horcrux.io
# Auto-renew is configured by default via systemd timer
```

---

## 5. Scaling Strategy

### Architecture characteristics

- **Stateless process** — all room state is ephemeral and in-memory.
- **No external dependencies** — no database, no Redis, no message broker.
- **Each instance is fully independent** — instances do not communicate with
  each other.

### Room affinity

All participants in the same MPC ceremony **must** connect to the **same relay
instance**. The room exists only in the memory of the instance that created it.

Strategies for ensuring room affinity:

| Strategy | How It Works | Complexity |
|----------|-------------|------------|
| Single instance | One relay handles all traffic | Simplest |
| DNS-based sharding | Clients resolve `room-hash.relay.horcrux.io` | Low |
| Sticky sessions | Load balancer routes by `room_id` from URL path | Medium |
| Client-directed | Client SDK selects relay from a known list | Medium |

### Load balancer configuration

Use **sticky sessions** based on the URL path (`/ws/{room_id}`):

```nginx
# nginx sticky routing by room_id
upstream relay_cluster {
    hash $uri consistent;
    server relay-1:8080;
    server relay-2:8080;
    server relay-3:8080;
}
```

> **Important:** Standard round-robin or least-connections load balancing will
> **break** ceremonies because participants will land on different instances.

### Scaling guidance

| Concurrent Ceremonies | Recommended Instances |
|----------------------|----------------------|
| < 1,000 | 1 |
| 1,000 – 5,000 | 2–3 |
| 5,000 – 20,000 | 4–8 |
| 20,000+ | Horizontal scale with affinity routing |

Each ceremony involves a small number of participants (≤ 10 by default) and
short-lived rooms (10 min TTL), so a single instance can handle a large volume
of concurrent ceremonies.

---

## 6. Resource Recommendations

| Tier | vCPU | RAM | Est. Connections | Use Case |
|------|------|-----|-----------------|----------|
| Dev | 1 | 256 MB | ~100 | Local testing |
| Staging | 2 | 512 MB | ~1,000 | Integration / beta |
| Production | 4 | 1 GB | ~10,000 | Production workload |
| High-traffic | 8 | 2 GB | ~50,000 | Peak load / events |

> The relay is CPU-light (mostly async I/O) and memory-light (rooms are small
> maps of participants). The bottleneck is typically open file descriptors and
> kernel network buffers, not CPU or RAM.

### OS tuning for high connection counts

```bash
# /etc/sysctl.conf
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
fs.file-max = 1048576

# /etc/security/limits.conf (or systemd LimitNOFILE)
relay  soft  nofile  65536
relay  hard  nofile  65536
```

---

## 7. Security Hardening

### Admin endpoint protection

Always set `RELAY_ADMIN_TOKEN` in production. Without it, `/metrics` and
`/admin/rooms` are publicly accessible.

```bash
# Generate a strong token
export RELAY_ADMIN_TOKEN="$(openssl rand -hex 32)"
```

The token is verified using **constant-time comparison** to prevent timing
attacks.

### CORS / Origin restriction

Set `RELAY_ALLOWED_ORIGINS` to restrict which web origins can open WebSocket
connections:

```bash
RELAY_ALLOWED_ORIGINS="https://app.horcrux.io,https://staging.horcrux.io"
```

When unset, CORS is permissive (suitable for development only). The server logs
a warning at startup when this is not configured.

### Non-root container

The Dockerfile creates a dedicated `relay` user and runs the process as that
user:

```dockerfile
RUN useradd --create-home --shell /bin/bash relay
USER relay
```

No additional configuration is needed.

### Network policies

Only port **8080** (or your configured `RELAY_PORT`) needs to be exposed.
Block all other inbound traffic:

```bash
# Docker: only expose the relay port
docker run -p 3000:8080 horcrux-relay

# iptables example
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
iptables -A INPUT -p tcp -j DROP
```

### Rate limiting

The relay has two layers of built-in rate limiting:

1. **Per-connection message rate** — `RELAY_RATE_LIMIT` messages per 10-second
   window (default: 100). Excess messages are dropped and counted in
   `horcrux_rate_limited_total`.

2. **Per-IP connection rate** — 20 new WebSocket connections per IP per 60-second
   window (hardcoded). Prevents connection flooding.

For production, review whether the defaults are appropriate for your traffic
patterns. If legitimate users are being rate-limited, increase `RELAY_RATE_LIMIT`.

### Checklist

- [ ] `RELAY_ADMIN_TOKEN` is set to a strong random value
- [ ] `RELAY_ALLOWED_ORIGINS` is set to production domain(s) only
- [ ] TLS termination is configured (see [§4](#4-tls-configuration))
- [ ] Container runs as non-root (default in Dockerfile)
- [ ] Only port 8080 is exposed externally
- [ ] Log level is `info` or `warn` in production (not `debug` or `trace`)
- [ ] `/metrics` is not publicly accessible without authentication
- [ ] Rate limit values are reviewed for expected traffic

---

## 8. Docker Compose Example

Complete setup with nginx TLS termination:

```yaml
# docker-compose.yml
version: "3.8"

services:
  relay:
    build: .
    restart: unless-stopped
    environment:
      RELAY_HOST: "0.0.0.0"
      RELAY_PORT: "8080"
      RELAY_ROOM_TTL_SECS: "600"
      RELAY_MAX_PARTICIPANTS: "10"
      RELAY_MAX_MESSAGE_SIZE: "1048576"
      RELAY_RATE_LIMIT: "100"
      RELAY_ADMIN_TOKEN: "${RELAY_ADMIN_TOKEN}"
      RELAY_ALLOWED_ORIGINS: "https://app.horcrux.io"
      RUST_LOG: "horcrux_relay=info"
    expose:
      - "8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 5s

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    depends_on:
      relay:
        condition: service_healthy

  prometheus:
    image: prom/prometheus:latest
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    depends_on:
      relay:
        condition: service_healthy

volumes:
  prometheus_data:
```

Create the nginx config alongside the compose file:

```nginx
# nginx.conf
upstream relay {
    server relay:8080;
}

server {
    listen 443 ssl http2;
    server_name relay.horcrux.io;

    ssl_certificate     /etc/letsencrypt/live/relay.horcrux.io/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/relay.horcrux.io/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location /ws/ {
        proxy_pass http://relay;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location / {
        proxy_pass http://relay;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}

server {
    listen 80;
    server_name relay.horcrux.io;
    return 301 https://$host$request_uri;
}
```

Start everything:

```bash
export RELAY_ADMIN_TOKEN="$(openssl rand -hex 32)"
docker compose up -d
```

---

## 9. Kubernetes Deployment

### Deployment

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: horcrux-relay
  labels:
    app: horcrux-relay
spec:
  replicas: 2
  selector:
    matchLabels:
      app: horcrux-relay
  template:
    metadata:
      labels:
        app: horcrux-relay
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: relay
          image: horcrux-relay:latest
          ports:
            - containerPort: 8080
              name: http
          env:
            - name: RELAY_HOST
              value: "0.0.0.0"
            - name: RELAY_PORT
              value: "8080"
            - name: RELAY_ROOM_TTL_SECS
              value: "600"
            - name: RELAY_MAX_PARTICIPANTS
              value: "10"
            - name: RELAY_RATE_LIMIT
              value: "100"
            - name: RELAY_ALLOWED_ORIGINS
              value: "https://app.horcrux.io"
            - name: RELAY_ADMIN_TOKEN
              valueFrom:
                secretKeyRef:
                  name: horcrux-relay-secrets
                  key: admin-token
            - name: RUST_LOG
              value: "horcrux_relay=info"
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 10
          resources:
            requests:
              cpu: "500m"
              memory: "256Mi"
            limits:
              cpu: "2000m"
              memory: "512Mi"
```

### Service

```yaml
# k8s/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: horcrux-relay
  labels:
    app: horcrux-relay
spec:
  type: ClusterIP
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
      name: http
  selector:
    app: horcrux-relay
```

### Ingress (with room-affinity sticky sessions)

```yaml
# k8s/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: horcrux-relay
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/upstream-hash-by: "$request_uri"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - relay.horcrux.io
      secretName: relay-tls
  rules:
    - host: relay.horcrux.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: horcrux-relay
                port:
                  number: 8080
```

### Secret

```bash
kubectl create secret generic horcrux-relay-secrets \
  --from-literal=admin-token="$(openssl rand -hex 32)"
```

### Apply

```bash
kubectl apply -f k8s/
```

---

## 10. Troubleshooting

### Common Issues

| Symptom | Likely Cause | Solution |
|---------|-------------|----------|
| `connection refused` on health check | Relay not started or wrong port | Check `RELAY_PORT` matches your curl target |
| `403 Forbidden` on `/metrics` | Missing or wrong admin token | Verify `RELAY_ADMIN_TOKEN` matches your request header/param |
| WebSocket connects then immediately drops | Pong timeout (10 s) | Check client sends pong responses; check network latency |
| `CORS error` in browser console | Origin not in allowlist | Add your domain to `RELAY_ALLOWED_ORIGINS` |
| Room not found after creation | Room expired (TTL) | Increase `RELAY_ROOM_TTL_SECS` or start the ceremony sooner |
| `429`-like drops / messages not delivered | Rate limit exceeded | Increase `RELAY_RATE_LIMIT`; check for runaway client loops |
| Cannot create new WebSocket connection | Per-IP connection limit (20/min) | Reduce reconnect frequency or deploy behind a proxy with unique IPs |
| High memory under load | Too many concurrent rooms | Monitor `horcrux_active_rooms`; reduce `RELAY_ROOM_TTL_SECS` |
| Startup panic: assertion failed | Invalid config values | Check env vars — `max_participants`, `rate_limit`, etc. must be > 0 |

### Log Level Configuration

Control verbosity with `RUST_LOG`:

```bash
# Production — info-level only (default)
RUST_LOG=horcrux_relay=info

# Debugging — trace-level relay logs
RUST_LOG=horcrux_relay=trace

# Verbose everything (includes framework internals)
RUST_LOG=debug

# Quiet — only warnings and errors
RUST_LOG=horcrux_relay=warn

# Per-module control
RUST_LOG="horcrux_relay=info,tower_http=debug"
```

### Checking the relay from the command line

```bash
# Health check
curl -s http://localhost:8080/health | jq .

# Metrics (with auth)
curl -s -H "x-admin-token: $RELAY_ADMIN_TOKEN" http://localhost:8080/metrics

# Room listing (with auth)
curl -s -H "x-admin-token: $RELAY_ADMIN_TOKEN" http://localhost:8080/admin/rooms | jq .

# Test WebSocket connectivity (requires websocat or wscat)
websocat ws://localhost:8080/ws/test-room-id
```

### Graceful Shutdown

The relay handles `SIGINT` (Ctrl+C) and `SIGTERM` gracefully — in-flight
WebSocket connections are drained before the process exits. Kubernetes and
Docker both send `SIGTERM` by default.

```bash
# Docker
docker stop horcrux-relay   # sends SIGTERM, waits 10s, then SIGKILL

# Kubernetes — set a generous termination grace period
spec:
  terminationGracePeriodSeconds: 30
```
