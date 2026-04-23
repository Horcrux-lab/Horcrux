# Horcrux docs index

This directory collects all long-form documentation for Horcrux —
architecture, threat model, audit record, protocol specs, deployment,
and release engineering.

If you're reading this as an **external audit firm**, start with the
[audit RFP](audit-rfp/) folder and then read the "Suggested reading
order" below.

---

## Suggested reading order

| # | Document | Audience | Summary |
|---|---|---|---|
| 1 | [`architecture.md`](architecture.md) | Everyone | High-level component breakdown — Rust core, iOS, WS relay, FFI boundary. |
| 2 | [`security-model.md`](security-model.md) | Security reviewers | Threat model, trust boundaries, and the self-custodial guarantee. |
| 3 | [`mpc-protocol.md`](mpc-protocol.md) | Cryptographers | CGGMP21 (ECDSA) + FROST-Ed25519 specifics, message flow, Noise session binding. |
| 4 | [`code-tour.md`](code-tour.md) | New contributors | Short tour of the codebase and the key modules. |
| 5 | [`eip712-typed-data.md`](eip712-typed-data.md) | dApp integrators / auditors | Pure-Rust EIP-712 JSON → digest helper, verified security properties, error taxonomy. |
| 6 | [`security-audit-2026-04.md`](security-audit-2026-04.md) | Security reviewers | Record of the 28 C / H / M / L findings and the round-by-round close-out. Read last — it references everything else. |

---

## Operations

| Document | When to read |
|---|---|
| [`deployment.md`](deployment.md) | Before deploying the relay. |
| [`reproducible-build.md`](reproducible-build.md) + [`reproducible-build.manifest`](reproducible-build.manifest) | When producing or verifying a release artifact. |
| [`push-notifications.md`](push-notifications.md) | When wiring iOS push notifications for signing prompts. |

---

## Product / roadmap

| Document | Audience |
|---|---|
| [`product-roadmap.md`](product-roadmap.md) | Product management / stakeholders. |
| [`audit-rfp/`](audit-rfp/) | External audit firms evaluating scope. |

---

## Related top-level files

| File | Purpose |
|---|---|
| [`../README.md`](../README.md) | Project overview, quick start. |
| [`../CHANGELOG.md`](../CHANGELOG.md) | Release notes. The `[Unreleased]` section is the running hardening log. |
| [`../CONTRIBUTING.md`](../CONTRIBUTING.md) | Contributor workflow, PR policy, commit trailer expectations. |
| [`../SECURITY.md`](../SECURITY.md) | **Read first if you found a vulnerability.** Private disclosure path. |
| [`../LICENSE`](../LICENSE) | Licensing terms. |

---

## Writing new docs

When adding a new doc to this directory:

1. Give it a `.md` extension and kebab-case filename.
2. Add a row to the table above in the right section.
3. If the doc describes a security-relevant feature, cross-link it
   from `security-audit-2026-04.md` too.
4. Keep the doc short and linkable — prefer two focused docs over
   one sprawling one.
