# Deliverables

## Expected from the firm

1. **Kickoff call** (30–60 min) — maintainers walk through the
   architecture, threat model, and known caveats. Firm confirms scope
   and review tag.

2. **Mid-audit check-in** (30 min, mid-engagement) — firm surfaces
   any show-stoppers or scope ambiguities. No formal findings shared
   yet.

3. **Draft report**, delivered under NDA, containing:
   - Executive summary (≤ 2 pages, legible to non-cryptographers).
   - All findings per the `severity-rubric.md` format.
   - A "methodology" section naming the tools used (static / dynamic
     / manual), the time budget per module, and any areas the firm
     explicitly *did not* review.
   - A reproducibility section — any fuzz seeds, test vectors, or
     scripts used by the firm during the review, so maintainers can
     re-run after fixes.

4. **Triage window** (1–2 weeks after draft) — maintainers respond
   in-line, mark fixes / won't-fix / dispute-severity, and prepare
   patches.

5. **Re-test** — firm verifies each remediated finding.  Scope is the
   *delta* since the draft report, not a full re-audit.  Findings
   introduced by a fix are treated as new findings at no additional
   charge.

6. **Final report** — publishable.  Maintainers post it to the
   repository (likely `docs/audits/<date>-<firm>.pdf`) together with
   the maintainer responses.

## Timing

All dates are placeholders — the maintainers negotiate concrete dates
with the firm at contract signing.

| Milestone | Expected gap |
|---|---|
| Contract signed → kickoff | ≤ 1 week |
| Kickoff → draft report | 3–6 weeks (depends on firm capacity) |
| Draft → maintainer triage complete | 1–2 weeks |
| Triage complete → re-test | 1 week |
| Re-test → final report | 1 week |

## Disclosure policy

- The firm follows the maintainers' disclosure policy in `SECURITY.md`.
- For Critical findings: embargo until a fix is released and users
  have had 7 days to update.
- For High findings: embargo until release.
- For Medium / Low / Informational: publishable immediately in the
  final report with the maintainers' written consent.

## Payment terms

Tracked outside this document. Placeholders:

- 50% at contract signing.
- 50% on delivery of the final report.
- No contingent fees ("find a Critical or we don't pay") — we want the
  firm to tell us when the codebase is clean as eagerly as when it
  isn't.

## What the firm does **not** receive

- Production Apple Developer credentials.
- The relay server's TLS private key.
- Any user's real shards, real PINs, real device pairing state.
- Any material covered by the maintainers' personal NDAs.

All of the above are reproducible locally from the code and the
`docs/reproducible-build.md` manifest.
