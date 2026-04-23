# Security Policy

Horcrux is a self-custody MPC wallet. A vulnerability in this codebase
could directly cause loss of funds for our users, so we take security
reports extremely seriously and commit to responsible-disclosure
cooperation with researchers.

## Reporting a Vulnerability

Please report suspected vulnerabilities through **one** of the following
channels — do **not** file a public GitHub issue or open a pull request
that demonstrates the exploit:

1. **GitHub Private Vulnerability Reporting** (preferred):
   <https://github.com/Horcrux-lab/Horcrux/security/advisories/new>
   This keeps the entire disclosure thread under GitHub's encrypted
   advisory channel and lets us coordinate a CVE if needed.

2. **Email**: `security@horcrux.app`
   PGP-encrypted reports are welcome. Public key is published at
   `https://horcrux.app/.well-known/security-pgp-key.asc` (TOFU — note
   the fingerprint on first use).

### What to include

- Affected component (iOS app / `horcrux-core` crate / `horcrux-relay`
  crate / relay deployment / build artefacts).
- A minimal reproduction. For cryptographic findings, a proof-of-concept
  script or captured transcript is ideal.
- Your assessment of severity (CVSS if you have one; we'll recalibrate).
- Whether you want public credit, and under what name / handle.

## Our commitments

| Stage                 | SLA (best effort)                       |
|-----------------------|-----------------------------------------|
| First human response  | within 3 business days                  |
| Triage decision       | within 7 business days                  |
| Patch or mitigation   | Critical ≤ 14 days, High ≤ 30 days      |
| Public advisory       | Coordinated with reporter; 90-day cap   |

We will:

- Acknowledge receipt promptly and give you a named point of contact.
- Keep you informed throughout triage, fix, and disclosure.
- Credit you in the advisory (or publish anonymously if you prefer).
- Not pursue legal action against good-faith researchers who follow
  this policy (see **Safe Harbor** below).

## Scope

**In scope**

- The iOS application under `ios/`.
- The Rust crates `horcrux-core` and `horcrux-relay`.
- The iOS UniFFI boundary (`uniffi-bindgen/`, generated Swift bindings).
- Build-time toolchain correctness (`ios/build-rust.sh`, `Dockerfile`,
  CI workflows) — e.g. a PR that could smuggle a backdoor into a
  release artefact.
- Any production deployment of `relay.horcrux.app`.

**Out of scope**

- The upstream MPC libraries we depend on (`cggmp21`, `frost-ed25519`),
  unless the finding is specific to our integration. Please report
  upstream issues to their maintainers and let us know.
- Social-engineering attacks against Horcrux team members.
- Denial-of-service that only reduces availability of the relay
  (confidentiality / integrity findings always in scope).
- Best-practice hardening suggestions with no demonstrable exploit
  path — please open a normal GitHub issue for those.
- Anything requiring physical access to an unlocked device with the
  user's PIN already entered — our trust model explicitly puts that
  out of scope.

## Safe Harbor

Activities undertaken in good faith under this policy are considered
authorised by Horcrux Lab. We will not:

- Pursue or support a civil claim, criminal complaint, or DMCA
  takedown against you.
- Ask a court to restrict your research.

…provided you:

- Do not access, modify, or destroy user data beyond what is strictly
  necessary to demonstrate the bug.
- Do not disrupt the relay service for other users.
- Give us a reasonable window to fix the issue before public
  disclosure (90 days is our default cap; shorter for actively
  exploited flaws once coordinated).

## More information

- System-level threat model, cryptographic primitives, and
  attack-scenario mitigations: [`docs/security-model.md`](docs/security-model.md).
- Codebase tour for auditors: [`docs/code-tour.md`](docs/code-tour.md).
- MPC protocol details: [`docs/mpc-protocol.md`](docs/mpc-protocol.md).
