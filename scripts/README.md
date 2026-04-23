# `scripts/` — operator & maintainer tooling

Small, self-contained Bash scripts used during development, release,
and deployment. Each script is executable, has a `-h` / `--help`
banner at the top, and exits non-zero on any failure so it's safe
to use as a gate in CI or deploy pipelines.

## Inventory

| Script | Purpose | Typical invocation |
|---|---|---|
| [`verify-build.sh`](verify-build.sh) | Reproducible-build verifier for the iOS Rust XCFramework. Hashes every file in the output and diffs against `docs/reproducible-build.manifest`. | `scripts/verify-build.sh` (verify)<br>`scripts/verify-build.sh --update` (maintainer: refresh manifest) |
| [`verify-relay-deploy.sh`](verify-relay-deploy.sh) | Pre/post-deploy smoke check for `horcrux-relay`. Exercises `/health`, `/metrics` (with Prometheus format validation), `/admin/rooms`, WebSocket upgrade (RFC-6455 `Sec-WebSocket-Accept` check), TLS certificate + min-version (≥ 1.2), and HSTS header. | `scripts/verify-relay-deploy.sh https://relay.example.tld \`<br>`  --admin-token $TOKEN --expect-version 0.3.0` |

## Conventions

- **Exit codes.** `0` = all checks pass, `1` = at least one check
  failed (soft failure — fix and re-run), `2` = usage error / missing
  dependency (hard failure — bad invocation).
- **Dependencies.** Assume a POSIX shell, `curl`, `awk`, `sed`.
  Scripts degrade gracefully when optional tools like `openssl` are
  missing (printing a "skipping" note rather than failing hard).
- **Colour output.** ANSI escape codes are emitted unconditionally —
  pipe through `| cat` or set `TERM=dumb` if colourless output is
  needed for a log file.
- **No network side-effects.** None of these scripts mutate remote
  state. They only read. Safe to run against production.
- **No secrets on the command line.** Scripts that accept a secret
  (e.g. `--admin-token`) document that the value will be visible in
  shell history / `ps` output — prefer sourcing from an env var or
  secret manager in CI.

## Adding a new script

1. Drop a `scripts/new-thing.sh` file starting with the standard
   shebang (`#!/usr/bin/env bash`) and a header comment describing
   **purpose**, **usage**, and **exit codes** (the `-h` banner is
   extracted from this comment by `sed -n ... | sed 's/^# //'`).
2. `chmod +x scripts/new-thing.sh`.
3. Add a row to the inventory table above.
4. If the script is intended to run in CI, also wire it into the
   relevant workflow under `.github/workflows/`.
