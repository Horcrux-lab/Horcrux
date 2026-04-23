# Severity Rubric

The audit firm is asked to use **this rubric**, not their in-house one.
If they prefer their own, they must provide a mapping table in the
final report.

## Severity levels

### Critical

Any finding where a **remote attacker with no prior access** can, in a
realistic deployment, cause one or more of:

- Extraction of any shard (plaintext or reduced-entropy ciphertext).
- Construction of a valid signature for any message the legitimate
  user did not approve.
- Silent substitution of the transaction bytes between display and
  signing (display-what-you-sign break).
- Permanent loss of funds for more than one user.

Critical findings **block the 1.0 release** until a fix is shipped and
the fix is re-reviewed.

### High

A realistic attack path exists, but requires one of:

- Local attacker (physical possession, or a malicious app on the same
  device post-jailbreak).
- A malicious cosigner already admitted to the group.
- A compromise of the relay server with the operator's cooperation.
- A Denial-of-Service result (no loss of funds) against a
  production-scale deployment.

High findings **block the 1.0 release** unless explicitly accepted by
the maintainers with documented rationale.

### Medium

Defence-in-depth weaknesses that do not by themselves break a security
goal from `docs/security-model.md §Security Goals`, but that would
amplify a separate compromise. Examples:

- Error messages that leak structural information about shards.
- Unnecessarily broad Keychain ACLs.
- Missing rate limits on non-critical endpoints.

Medium findings **should be fixed before 1.0** but are not release
blockers.

### Low

Hardening recommendations, style, or best-practice deviations with no
demonstrable exploitation path. Tracked in the roadmap; no release
gate.

### Informational

Observations about code clarity, test coverage, documentation gaps.
Accepted without a separate triage round.

## Reporting format (per finding)

Each finding MUST include:

1. **Severity** (from the rubric above).
2. **Title** — one sentence.
3. **Affected components** — path:line spans.
4. **Pre-conditions** — what the attacker must already have.
5. **Attack narrative** — step-by-step, with cryptographic detail if
   relevant.
6. **Proof-of-concept** — test vectors, fuzz seed, or reproducer
   script. "Conceptual only" is acceptable for informational findings
   but not for Critical / High.
7. **Recommended fix** — at least one concrete path. Multiple options
   welcome.
8. **Maintainer response** — left blank; maintainers fill this in
   during triage.

## Disagreement protocol

If the firm and the maintainers disagree on severity:

1. The firm's severity is published in the final report.
2. Maintainers may append a `severity-dispute` note with reasoning.
3. No finding is re-classified without mutual written agreement.
