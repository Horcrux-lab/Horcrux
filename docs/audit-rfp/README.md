# Horcrux — External Security Audit RFP

This directory contains the firm-independent scaffolding the Horcrux
maintainers send out when engaging an external security-audit firm for
the pre-1.0 review. The documents here are meant to be read **in
addition to** the full repository; they are not a substitute for
`docs/security-audit-2026-04.md` (self-audit), `docs/security-model.md`
(threat model + goals), or `docs/mpc-protocol.md` (protocol details).

## Contents

| File | Purpose |
|---|---|
| [`scope.md`](scope.md) | In-scope / out-of-scope components, codebase map, crypto primitives, supported chains. |
| [`severity-rubric.md`](severity-rubric.md) | Severity classification the audit firm is expected to use. |
| [`deliverables.md`](deliverables.md) | Expected deliverables, timelines, disclosure policy, re-test scope. |

## How this is used

1. Maintainers short-list candidate audit firms (two to four).
2. Each firm receives:
   - This `audit-rfp/` directory (tarballed).
   - A link to the public repository at the review tag (e.g.
     `v0.5.0-rc.2`).
   - The private write-up of any still-open findings from
     `docs/security-audit-2026-04.md` with their remediation plans.
3. Firms return a proposal referencing the scope / severity / deliverable
   documents here. Proposals that silently redefine scope are rejected —
   the RFP is the contract.
4. Selected firm signs an NDA covering any material not yet made public
   (notably: the Apple Developer Team ID used for notarisation, the
   production relay deployment details, and any partially-applied
   mitigations that are still flag-gated).

## Status

- **Scope**: drafted, pending maintainer review.
- **Firm selection**: **not yet started** — see the "Pending decisions"
  log in checkpoint notes.
- **Retainer**: out of scope for this document; tracked separately.

## License

These documents are part of the Horcrux repository and covered by the
project's MIT license. They may be redistributed by the audit firm
alongside their final report.
