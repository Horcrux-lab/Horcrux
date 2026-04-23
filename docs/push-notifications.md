# Push Notifications — Design Document

**Status:** Design only. Not yet implemented. Planned for a post-audit
release (tentatively 0.5.1).

**Scope:** Wake co-signer devices in the background when a signing
request is pending, without exposing transaction content to Apple, to
the relay, or to the initiator.

---

## Problem

Horcrux signing is a real-time MPC ceremony over a WebSocket relay. If
device B's Horcrux app is backgrounded for more than a few seconds, iOS
tears the socket down — B cannot learn that A has opened a room. Today
the only workaround is "both parties open the app at roughly the same
time," which is not viable for a mainstream product and silently drops
signing requests.

## Goals

1. Reliably wake co-signer devices when a signing request targets them.
2. Leak zero transaction content (amount, address, chain, peer
   identity) through Apple or any push infrastructure.
3. Preserve the ability to run a self-hosted relay. Self-host users
   must get equivalent signing UX.
4. Add at most one new trust anchor, with a clear opt-out.

## Non-goals

- Displaying rich content in the notification banner. The payload is
  purely a wake-up signal (`content-available: 1`).
- Cross-platform parity in this doc — Android is tracked separately
  under FCM when the Android port lands.
- Guaranteed delivery. APNs is best-effort; we treat push as a UX
  optimization, not a protocol requirement. The signing flow still
  works if push fails.

---

## Architecture — Option B: Official Push Gateway

```
┌─ iOS App (signer) ─┐     ┌─ Any Relay ─┐       ┌─ Official Push ─┐     ┌─ Apple APNs ─┐
│                    │     │  (official   │       │   Gateway       │     │              │
│ registerForRemote  │     │   or self-   │       │  push.horcrux.  │     │              │
│ Notifications()    │     │   hosted)    │       │  app            │     │              │
│        │           │     │              │       │                 │     │              │
│        ▼           │     │              │       │  holds the      │     │              │
│   POST /v1/push/   │──┐  │              │       │  only copy of   │     │              │
│   register         │  │  │              │       │  the APNs .p8   │     │              │
│   (token, pkhash,  │  │  │              │       │  signing key    │     │              │
│    sig)            │  │  │              │       │                 │     │              │
│                    │  └─▶│              │       │                 │     │              │
│                    │     │ store:       │       │                 │     │              │
│                    │     │  pkhash →    │       │                 │     │              │
│                    │     │  [dev_tok]   │       │                 │     │              │
│                    │     │              │       │                 │     │              │
│ initiator:         │     │              │       │                 │     │              │
│   POST /v1/rooms/  │────▶│ translate:   │──────▶│ translate:      │────▶│ HTTP/2 push  │
│   {room}/notify    │     │  pkhash →    │  ES256│  pkhash →       │ JWT │              │
│   (recipients =    │     │  dev_tok     │  HMAC │  dev_tok (own   │     │              │
│    [pkhash…], sig) │     │              │       │  mapping); send │     │              │
│                    │     │              │       │  silent push    │     │              │
│                    │     │              │       │                 │     │              │
│ (woken up)         │◀────────────── silent push `content-available: 1` ──┘              │
│ reconnects WSS,    │                                                                    │
│ fetches pending    │                                                                    │
└────────────────────┘                                                                    │
```

### Components

**Official Push Gateway (`push.horcrux.app`)** — a small, single-purpose
HTTPS service that holds the only instance of the Apple `.p8` signing
key. It translates `{pubkey_hash, relay_origin}` into `{device_token}`
and calls APNs HTTP/2 with an ES256-signed JWT. It never sees transaction
content, room contents, or the WebSocket traffic.

**Any Relay** — official or self-hosted. Stores
`pubkey_hash → [device_token, relay_origin]` mappings for devices that
have registered against *that relay*, and forwards `notify` calls to
the Push Gateway. A self-hosted relay is a full first-class participant.

**iOS App** — gains two new behaviours:
- On launch: request `UNAuthorizationOptions` and call
  `UIApplication.registerForRemoteNotifications()`. On success, POST
  `/v1/push/register` to whichever relay the user is bound to.
- On APNs wake-up: reconnect to the bound relay, fetch any pending
  room invitations for wallets this device holds a share in.

### Why a separate gateway (not in the relay itself)?

The `.p8` key is a Horcrux-team-level secret. If we embedded it in
self-hosted relays, anyone running a relay could spoof pushes to any
Horcrux user globally. Keeping it behind an HTTPS boundary we control
means:

- Self-hosters can relay signing traffic without handling Apple
  credentials.
- The attack surface of the `.p8` key is one small Rust service with
  a minimal HTTP API, not the whole relay.
- If the gateway is compromised, we can rotate a single `.p8` key and
  push a gateway-only patch; relay operators and apps are unaffected.

---

## HTTP API

### `POST /v1/push/register` (on any relay)

Registers a device's APNs token for the pubkey hashes it holds shares
for. Replayable — call on every app launch; relay stores the latest
entry per `(pubkey_hash, device_id)`.

Request:
```json
{
  "device_token":   "<64-byte APNs token, hex>",
  "pubkey_hashes":  ["<BLAKE3(pk_i), hex>", "…"],
  "nonce":          "<random 16 bytes, hex>",
  "timestamp":      1709990400,
  "signatures":     {
    "<pubkey_hash>": "<ECDSA(sk_i, nonce || timestamp || device_token)>"
  }
}
```

The per-pubkey signature proves the caller actually holds share `pk_i`,
preventing Mallory from registering someone else's pubkey against her
own device token.

Relay stores:
```
pubkey_hash → {
  device_tokens:  [(token, last_seen)],
  relay_origin:   "wss://relay.example.com"  // echoed on notify
}
```
TTL: 30 days, extended on each registration.

Response: `202 Accepted` (unconditionally, to avoid disclosing which
pubkey hashes are known).

### `POST /v1/rooms/{room_id}/notify` (on any relay)

Triggered by the session initiator's app once the room is open and
after `t` seconds without all peers joining.

Request:
```json
{
  "recipients": ["<pubkey_hash>", "…"],
  "nonce":      "<…>",
  "timestamp":  1709990400,
  "signature":  "<ECDSA(sk_initiator, room_id || recipients || nonce || timestamp)>"
}
```

The signature proves the caller is a legitimate participant in the
room (their pubkey is in the room's access-token subject list).

Relay side-effects:
1. Resolve recipients → `[(device_token, gateway_url)]`.
2. POST one request to the Push Gateway per recipient.
3. Rate-limit per `(pubkey_hash, relay_origin)`.

Response: `204 No Content`.

### `POST /v1/push` (Push Gateway → APNs)

Internal. Called by relays. Not public.

Request:
```json
{
  "device_tokens": ["<…>", "…"],
  "relay_origin":  "wss://relay.example.com",
  "relay_api_key": "<opaque>"
}
```

Gateway enforces:
- `relay_api_key` is valid and not rate-limited. Per-key quota.
- `device_tokens` are non-empty, hex-shaped.
- APNs payload is literally `{"aps": {"content-available": 1}}` plus
  a `relay_origin` field so the app knows which relay to reconnect to.
  No other payload keys.

---

## Privacy & Threat Model

See also: `docs/relay-abuse-analysis.md` (to be written alongside
implementation).

### What each party sees

| Party | Sees | Does NOT see |
|-------|------|--------------|
| APNs (Apple) | bundle id, target device token, push frequency, timestamps | pubkey, room id, transaction content, peer identities |
| Push Gateway | pubkey_hash → device_token mapping, relay origins, push volumes | pubkey itself, raw signing traffic, tx content |
| Relay (official or self-hosted) | pubkey_hash → device_token, room membership, WS timing | pk, decrypted payloads (MPC is E2E encrypted), tx content |
| Initiator | pubkey_hashes of intended recipients (they already know the pubkeys) | recipients' device tokens |
| Network observer | TLS-encrypted HTTPS flows between components | all plaintext |

### Key mitigations

- **`BLAKE3(pk)`, not `pk`.** Storing hashes prevents relay/gateway
  operator from correlating a pubkey against on-chain activity.
- **Silent payload only.** No transaction amount, address, chain, peer
  id, or user name in the APNs push.
- **Proof-of-ownership on register.** ECDSA signature per pubkey hash
  stops Mallory registering someone else's pubkey.
- **Proof-of-membership on notify.** Only room members can trigger
  wakeups for that room.
- **Unconditional 202 on register, 204 on notify.** The relay never
  leaks "this pubkey is known to me" through status codes.
- **Rate limits at three tiers.** Per-pubkey (anti-harassment),
  per-relay (anti-DoS of the gateway), per-source-IP
  (anti-enumeration).
- **Per-relay API key on the gateway.** Revokable if a relay misbehaves.
- **30-day TTL.** Stale devices are dropped; no long-lived
  accumulation.
- **Opt-out in-app.** Setting "Background push (uses Horcrux Labs push
  gateway)" can be disabled; degraded-UX fallback is "open the app
  yourself."
- **Self-hosted transparency.** Self-host users can inspect exactly
  what their relay sends to the gateway (one HTTP call, payload is
  `(token, api_key)` plus origin).

### Residual risk

- **Pubkey cluster linkage via gateway.** When the gateway pushes to
  multiple tokens for one room notification, it can infer that those
  pubkeys belong to the same wallet. We accept this: it's structurally
  unavoidable with APNs and is disclosed in the opt-out copy. For the
  privacy-maximalist, the opt-out preserves the existing
  "must-open-app" UX.
- **Metadata retention at the gateway.** The gateway should log only
  counters (requests/min per key), not pubkey-level history. A
  post-implementation audit should verify no PII reaches long-term
  storage.

---

## Deferred until implementation

- Exact Caddyfile / Kubernetes manifest for the gateway.
- APNs library selection (`a2` vs `apns2` vs hand-rolled HTTP/2).
- Provisioning profile / entitlement wiring for the iOS app.
- Mock APNs server for integration tests.
- FCM equivalent for Android.

These are intentionally out of scope for the pre-audit design
iteration. The interface contract above is stable enough to begin
implementation once:

1. External audit closes without findings that affect the relay ↔ app
   message format.
2. Apple Developer account and `.p8` signing key are provisioned and
   stored in the team secrets vault.
3. A production host is selected for the push gateway.

---

## Open questions

- Should `/v1/push/register` accept a single ECDSA signature covering
  the concatenation of all pubkey hashes, instead of one per hash?
  Smaller wire format; slightly harder to reason about partial-share
  rotation.
- Should the gateway bound response emit per-token success/failure
  back to the relay? Useful for pruning dead tokens; risks amplifying
  timing signals. Leaning toward async out-of-band prune via Apple's
  feedback service.
- Is a single global gateway enough, or do we need geo-sharded
  gateways for latency / compliance (e.g. EU residency)? Probably
  single until meaningful scale.
