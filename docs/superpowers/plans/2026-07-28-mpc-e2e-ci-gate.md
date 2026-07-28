# MPC E2E Release Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the three `#[ignore]`d multi-party CGGMP21 ceremony tests run automatically on the release path, via a dedicated GitHub Actions workflow triggered by release tags and manual dispatch.

**Architecture:** One new single-purpose workflow file, `.github/workflows/mpc-e2e.yml`, mirroring the structure of the existing `cargo-audit.yml`. It runs `cargo test -p horcrux-core --release --test multi_party_ecdsa -- --ignored` on `v*` tags excluding `-dev.N`, plus `workflow_dispatch`. Two documentation files are corrected alongside it. No Rust source changes — the `#[ignore]` attributes stay exactly as they are.

**Tech Stack:** GitHub Actions, cargo, Rust. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-28-mpc-e2e-ci-gate-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `.github/workflows/mpc-e2e.yml` | Create | The entire gate: triggers, job config, test invocation |
| `RELEASE.md` | Modify (§0 pre-flight) | Instruct the maintainer to dispatch the workflow *before* tagging |
| `CHANGELOG.md` | Modify (line ~222, and `### Supply chain`) | Correct two factual errors; record the new workflow |
| `horcrux-core/tests/multi_party_ecdsa.rs` | **Untouched** | The `#[ignore]` attributes are load-bearing and stay |

Tasks are ordered so the workflow exists before the docs that reference it.

---

### Task 1: Create the MPC E2E workflow

**Files:**
- Create: `.github/workflows/mpc-e2e.yml`

Third-party actions must be pinned to the same commit SHAs already used
in `.github/workflows/ci.yml` and `cargo-audit.yml` — this repository
pins every action to a SHA with a trailing version comment. Do not
substitute floating tags like `@v4`.

- [ ] **Step 1: Confirm the test command passes locally before automating it**

Automating a command you have not run is how green-but-meaningless
workflows get created. Run the exact command the workflow will run:

```bash
cd /Users/bill/Documents/GitHub/Horcrux
cargo test -p horcrux-core --release --test multi_party_ecdsa -- \
  --ignored --nocapture --test-threads=1
```

Expected: `test result: ok. 3 passed; 0 failed`. Takes ~10 min on
Apple silicon. This was measured at 617.95 s on 2026-07-28.

- [ ] **Step 2: Create the workflow file**

Create `.github/workflows/mpc-e2e.yml` with exactly this content:

```yaml
name: MPC E2E

# Multi-party CGGMP21 ceremony verification — the only automated
# proof that DKG, signing, and proactive refresh work with more
# than two parties.
#
# The three tests live in horcrux-core/tests/multi_party_ecdsa.rs
# and are #[ignore]d because they cost ~10 min of pure compute
# (Paillier aux-info generation dominates). `cargo test --workspace`
# therefore skips them, and until this workflow existed nothing in
# CI ever passed --ignored.
#
# Why they matter more than "a skipped test" suggests: the ceremony
# routing code (broadcast vs unicast, per-party mailbox, completion
# detection) is shared between 2-of-2 and n-of-n, but n=2 is a
# degenerate case where every broadcast has exactly one recipient.
# A fan-out regression is invisible to the 260 tests in ci.yml and
# only appears at n >= 3.
#
# Release-only by design: at an estimated 30-50 min on a runner
# this is too slow to gate pull requests, and the code it covers
# only changes when MPC internals do. `-dev.N` tags are excluded —
# nine were cut against two `-rc` tags, so including them would
# fire this job about five times more often than it pays for.
#
# Run it manually during RELEASE.md section 0 pre-flight:
#
#     gh workflow run mpc-e2e.yml
#
# The tag trigger is only a backstop for when pre-flight is
# skipped: by then the tag already exists, so a failure means
# deleting and re-cutting it.

on:
  push:
    tags:
      # Include-then-exclude. GitHub evaluates these in order and
      # requires at least one non-exclusion pattern; `tags` and
      # `tags-ignore` cannot both appear on one event, so the `!`
      # form inside `tags` is the only way to express this.
      - "v*"
      - "!v*-dev.*"
  workflow_dispatch:

concurrency:
  group: mpc-e2e-${{ github.ref }}
  # Deliberately NOT cancel-in-progress, unlike every other
  # workflow here. Cancelling a half-finished release verification
  # leaves a run that is not red but also proved nothing.
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  multi-party:
    name: Multi-party DKG / sign / refresh
    runs-on: ubuntu-latest
    # No other workflow in this repo sets a timeout, so the default
    # is 6 h. `drive_to_completion` polls up to iter_limit = 2000,
    # and a ceremony that stalls without completing would burn all
    # of it. 90 min is roughly 2x the 30-50 min estimate.
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4

      - name: Install Rust toolchain
        uses: dtolnay/rust-toolchain@29eef336d9b2848a0b548edc03f92a220660cdb8 # stable

      - name: Cache cargo
        uses: actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae # v5.0.5
        with:
          path: |
            ~/.cargo/registry
            ~/.cargo/git
            target
          # Distinct prefix: this is the only job building the
          # release profile. Sharing ci.yml's `cargo-` key would
          # make the two jobs repeatedly evict each other.
          key: cargo-mpc-e2e-${{ runner.os }}-${{ hashFiles('**/Cargo.lock') }}

      - name: Run multi-party ceremonies
        # --release is mandatory, not an optimisation: there are no
        # [profile] overrides in any Cargo.toml, so a debug build
        # runs unoptimised bignum arithmetic roughly an order of
        # magnitude slower.
        #
        # --test-threads=1 and --nocapture match the invocation
        # documented at the top of the test file. --nocapture keeps
        # the per-phase Instant timings in the log, so gradual
        # slowdown stays visible.
        run: |
          cargo test -p horcrux-core --release --test multi_party_ecdsa -- \
            --ignored --nocapture --test-threads=1
```

- [ ] **Step 3: Verify the YAML parses**

`actionlint` is not installed in this environment; use Python, which has
`pyyaml` available:

```bash
cd /Users/bill/Documents/GitHub/Horcrux
python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/mpc-e2e.yml')); print('parsed OK'); print('jobs:', list(d['jobs'])); print('timeout:', d['jobs']['multi-party']['timeout-minutes'])"
```

Expected output:
```
parsed OK
jobs: ['multi-party']
timeout: 90
```

- [ ] **Step 4: Verify the trigger block survived parsing intact**

YAML parses `on:` as the boolean `True` unless quoted, which silently
produces a workflow with no triggers. Confirm the key is readable and
the tag patterns are both present:

```bash
cd /Users/bill/Documents/GitHub/Horcrux
python3 -c "
import yaml
d = yaml.safe_load(open('.github/workflows/mpc-e2e.yml'))
trig = d.get('on', d.get(True))
print('trigger key parsed as bool True:', 'on' not in d)
print('tags:', trig['push']['tags'])
print('workflow_dispatch present:', 'workflow_dispatch' in trig)
"
```

Expected: `tags: ['v*', '!v*-dev.*']` and `workflow_dispatch present: True`.
The `trigger key parsed as bool True` line will print `True` — that is
the normal, harmless YAML 1.1 behaviour that GitHub itself handles; it
is printed here only so the reader is not surprised by it.

- [ ] **Step 5: Confirm the tag patterns match the intended tags**

Reproduce GitHub's include-then-exclude semantics against the
repository's real tag history:

```bash
cd /Users/bill/Documents/GitHub/Horcrux
python3 -c "
import fnmatch
pats = ['v*', '!v*-dev.*']
def fires(tag):
    hit = False
    for p in pats:
        if p.startswith('!'):
            if fnmatch.fnmatch(tag, p[1:]): hit = False
        elif fnmatch.fnmatch(tag, p): hit = True
    return hit
for t in ['v0.5.0-rc.2','v0.5.0','v0.5.0-dev.9','v0.5.0-dev.1','v1.0.0-rc.1']:
    print(f'{t:16} -> {fires(t)}')
"
```

Expected:
```
v0.5.0-rc.2      -> True
v0.5.0           -> True
v0.5.0-dev.9     -> False
v0.5.0-dev.1     -> False
v1.0.0-rc.1      -> True
```

- [ ] **Step 6: Commit**

```bash
cd /Users/bill/Documents/GitHub/Horcrux
git add .github/workflows/mpc-e2e.yml
git commit -m "ci: run the multi-party MPC suite on release tags

The three ceremonies in multi_party_ecdsa.rs are the only automated
proof that DKG, signing, and refresh work at n > 2, and all three are
#[ignore]d with no workflow passing --ignored. Because n=2 is the
degenerate case where every broadcast has exactly one recipient, a
fan-out regression passes all 260 tests ci.yml enforces.

Triggered on v* tags excluding -dev.N, plus workflow_dispatch so
RELEASE.md pre-flight can run it while the tag can still be avoided.
Release-only because the suite costs ~10 min of compute locally and an
estimated 30-50 min on a runner.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 2: Wire the gate into the release pre-flight checklist

**Files:**
- Modify: `RELEASE.md` (§0 Pre-flight, the checklist ending with the TODO sweep)

Without this the workflow only ever fires *after* the tag exists, which
is the failure mode the `workflow_dispatch` trigger was added to avoid.

- [ ] **Step 1: Locate the anchor text**

```bash
cd /Users/bill/Documents/GitHub/Horcrux
grep -n "validate-codeowners.sh" RELEASE.md
```

Expected: one hit inside the §0 checklist, around line 35.

- [ ] **Step 2: Add the pre-flight item**

In `RELEASE.md`, find this exact block:

```markdown
- [ ] `./scripts/validate-codeowners.sh` — passes
- [ ] No hand-written `TODO` / `FIXME` / `HACK` in `horcrux-core/src`
      or `horcrux-relay/src`
      (`git grep -nE '(TODO|FIXME|HACK)' horcrux-core/src horcrux-relay/src`
      should be empty).
```

Replace it with:

```markdown
- [ ] `./scripts/validate-codeowners.sh` — passes
- [ ] **Multi-party MPC suite green.** Dispatch it and wait — do not
      tag until it passes:

    ```bash
    gh workflow run mpc-e2e.yml
    gh run watch "$(gh run list --workflow=mpc-e2e.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
    ```

    Runs the three `#[ignore]`d ceremonies in
    `horcrux-core/tests/multi_party_ecdsa.rs` (3-of-3 DKG + sign,
    3-of-3 refresh, 5-of-5 DKG + sign). Nothing else in CI covers
    n > 2 — `cargo test --workspace` skips all three. Budget
    30-50 min.

    > Run it **here**, not by relying on the tag trigger. The
    > workflow also fires on `v*` tags (excluding `-dev.N`), but by
    > then the tag exists, and a failure means deleting and
    > re-cutting it.

    Locally the equivalent is:

    ```bash
    cargo test -p horcrux-core --release --test multi_party_ecdsa -- \
      --ignored --nocapture --test-threads=1
    ```

    `--release` is required; a debug build is roughly an order of
    magnitude slower.

- [ ] No hand-written `TODO` / `FIXME` / `HACK` in `horcrux-core/src`
      or `horcrux-relay/src`
      (`git grep -nE '(TODO|FIXME|HACK)' horcrux-core/src horcrux-relay/src`
      should be empty).
```

> **Indentation is load-bearing.** Block-level content (fences,
> blockquotes) inside a `- [ ] ` list item must be indented **4
> spaces**, not 6. At 6 spaces CommonMark treats it as an indented
> code block and GitHub renders the literal `>` and backticks as
> preformatted text. Verified against GitHub's own renderer via
> `gh api -X POST /markdown`. Plain lazy-continuation prose lines
> (no blank line before them) keep the file's existing 6-space
> alignment — those are unaffected.

- [ ] **Step 3: Verify the edit landed and the file still reads correctly**

```bash
cd /Users/bill/Documents/GitHub/Horcrux
sed -n '30,70p' RELEASE.md
```

Expected: the new checklist item sits between the CODEOWNERS item and
the TODO-sweep item, with the fenced code blocks indented under it.

- [ ] **Step 4: Commit**

```bash
cd /Users/bill/Documents/GitHub/Horcrux
git add RELEASE.md
git commit -m "docs(release): require the MPC E2E gate before tagging

The workflow also fires on release tags, but discovering a failure
there means the tag already exists. Pre-flight is the point where it
can still be avoided.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 3: Correct the changelog and record the new workflow

**Files:**
- Modify: `CHANGELOG.md` (the dependabot-triage paragraph at ~line 222, and the `### Supply chain` section)

Two errors are on record and both mislead anyone who follows them: the
invocation omits `--release`, and the runtime is understated by 2x.

- [ ] **Step 1: Fix the incorrect invocation and runtime**

Find this exact block in `CHANGELOG.md` (around line 222):

```markdown
  After each bump the real multi-party suite
  (`cargo test -p horcrux-core --test multi_party_ecdsa -- --ignored`,
  3 end-to-end DKG + signing + refresh cases, ~5 min) was re-run: 3/3
  passing. Note CI never runs these — they are `#[ignore]`d, so this
  is currently a manual gate.
```

Replace it with:

```markdown
  After each bump the real multi-party suite (3 end-to-end DKG +
  signing + refresh cases) was re-run: 3/3 passing.

  > **Correction.** This entry originally recorded the invocation as
  > `cargo test -p horcrux-core --test multi_party_ecdsa -- --ignored`
  > and the cost as "~5 min". Both were wrong. The `--release` flag is
  > mandatory — there are no `[profile]` overrides, so the command as
  > written runs unoptimised bignum arithmetic — and the measured
  > runtime is 617.95 s. The correct invocation is:
  >
  > ```bash
  > cargo test -p horcrux-core --release --test multi_party_ecdsa -- \
  >   --ignored --nocapture --test-threads=1
  > ```
  >
  > "CI never runs these" was true when written and is no longer — see
  > the `MPC E2E` workflow below.
```

- [ ] **Step 2: Record the new workflow**

In `CHANGELOG.md`, find the `### Supply chain` heading:

```markdown
### Supply chain
```

Replace it with:

```markdown
### Testing

- **Multi-party MPC suite now runs in CI** (`.github/workflows/mpc-e2e.yml`).
  The three ceremonies in `horcrux-core/tests/multi_party_ecdsa.rs` —
  3-of-3 DKG + sign, 3-of-3 DKG + sign + refresh + sign (asserting the
  group public key survives refresh), and 5-of-5 DKG + sign — were the
  only automated coverage of n > 2 and had never been executed by any
  workflow. All three are `#[ignore]`d and `ci.yml` runs plain
  `cargo test --workspace`, which does not pass `--ignored`.

  The gap was larger than "three skipped tests" implies. Ceremony
  routing — broadcast vs unicast, per-party mailbox, completion
  detection — is shared between 2-of-2 and n-of-n, but n=2 is
  degenerate: every broadcast has exactly one recipient. A regression
  in the fan-out path passes all 260 enforced tests and only surfaces
  at n >= 3.

  Triggered on `v*` tags **excluding** `-dev.N`, plus
  `workflow_dispatch`. Release-only because the suite costs 617.95 s
  measured locally in release mode and an estimated 30-50 min on a
  4-core runner — too slow to gate pull requests, and the code it
  covers only moves when MPC internals do. Nine `-dev` tags have been
  cut against two `-rc` tags, so including them would fire the job
  about five times more often than it pays for.

  `RELEASE.md` §0 now requires dispatching it manually before tagging;
  the tag trigger is a backstop, since a failure discovered there means
  the tag already exists. The job carries `timeout-minutes: 90` — the
  first in this repository to set one at all — because
  `drive_to_completion` polls up to `iter_limit = 2000` and a stalled
  ceremony would otherwise consume the 6-hour default. It also sets
  `cancel-in-progress: false`, deliberately unlike the other four
  workflows: a cancelled release verification is not red but has not
  proved anything either.

  The `#[ignore]` attributes are unchanged, so everyday
  `cargo test --workspace` is unaffected.

### Supply chain
```

- [ ] **Step 3: Verify both edits landed**

```bash
cd /Users/bill/Documents/GitHub/Horcrux
grep -n "Correction." CHANGELOG.md | head -2
grep -n "^### Testing" CHANGELOG.md | head -2
grep -c "cargo test -p horcrux-core --test multi_party_ecdsa -- --ignored" CHANGELOG.md
```

Expected: the first two commands each return one hit near the top of
the `[Unreleased]` section. The third must print `1` — the single
remaining occurrence is the quoted-as-wrong command inside the
correction note. If it prints `2` or more, an uncorrected copy remains.

- [ ] **Step 4: Commit**

```bash
cd /Users/bill/Documents/GitHub/Horcrux
git add CHANGELOG.md
git commit -m "docs(changelog): record the MPC E2E gate, correct two errors

The dependabot-triage entry recorded the multi-party invocation
without --release and put the cost at ~5 min. Without --release the
command runs unoptimised bignum arithmetic, and the measured runtime
is 617.95 s.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 4: Prove the workflow actually runs

A workflow that has never executed is not a gate. Everything up to here
is unverified configuration.

**Files:** none — this task is verification only.

- [ ] **Step 1: Push**

```bash
cd /Users/bill/Documents/GitHub/Horcrux
git push origin main
```

- [ ] **Step 2: Confirm GitHub registered the workflow**

`workflow_dispatch` only becomes available once the file is on the
default branch and parsed successfully.

```bash
cd /Users/bill/Documents/GitHub/Horcrux
gh workflow list --all | grep -i "MPC E2E"
```

Expected: one line naming `MPC E2E` with state `active`. If it is
absent, GitHub rejected the file — check the Actions tab for a syntax
error rather than retrying blindly.

- [ ] **Step 3: Dispatch it**

```bash
cd /Users/bill/Documents/GitHub/Horcrux
gh workflow run mpc-e2e.yml
sleep 10
gh run list --workflow=mpc-e2e.yml --limit 1
```

Expected: one `in_progress` run.

- [ ] **Step 4: Wait for it and capture the real runtime**

This replaces the 30-50 min estimate with a measurement.

```bash
cd /Users/bill/Documents/GitHub/Horcrux
RUN_ID="$(gh run list --workflow=mpc-e2e.yml --limit 1 --json databaseId -q '.[0].databaseId')"
gh run watch "$RUN_ID" --exit-status
gh run view "$RUN_ID" --json conclusion,createdAt,updatedAt \
  -q '"conclusion: \(.conclusion)  started: \(.createdAt)  ended: \(.updatedAt)"'
```

Expected: `conclusion: success`.

If it fails on timeout, the 90-minute budget was too tight — raise it
and note the real figure. If it fails on a test assertion, that is a
genuine finding: the ceremonies pass locally, so a failure here means a
platform-dependent bug, which is exactly what this gate exists to catch.
Do not disable the test to make CI green.

- [ ] **Step 5: Record the measured runtime**

Replace the estimate in `CHANGELOG.md` with the observed duration. In
the `### Testing` entry, find:

```markdown
  measured locally in release mode and an estimated 30-50 min on a
  4-core runner — too slow to gate pull requests, and the code it
```

and replace `an estimated 30-50 min` with the actual wall-clock time
from Step 4, phrased as measured rather than estimated, for example
`a measured 34 min`.

Then update the same figure in the two other places it appears:

```bash
cd /Users/bill/Documents/GitHub/Horcrux
grep -rn "30-50 min" .github/workflows/mpc-e2e.yml RELEASE.md CHANGELOG.md
```

Update each hit to the measured value, keeping the surrounding prose
grammatical. The `timeout-minutes: 90` comment in the workflow should
state the real ratio rather than "roughly 2x".

- [ ] **Step 6: Commit and push**

```bash
cd /Users/bill/Documents/GitHub/Horcrux
git add .github/workflows/mpc-e2e.yml RELEASE.md CHANGELOG.md
git commit -m "docs: replace the MPC E2E runtime estimate with the measured value

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push origin main
```

- [ ] **Step 7: Confirm nothing else regressed**

The push touches `.github/workflows/` and markdown only, but `ci.yml`
runs on every push to `main`:

```bash
cd /Users/bill/Documents/GitHub/Horcrux
sleep 30
gh run list --limit 6
```

Expected: the usual five workflows green (or in progress) on the new
commit. `MPC E2E` must **not** appear for a `main` push — it has no
`push: branches` trigger. If it does appear, the trigger block is wrong.

---

## Definition of Done

- [ ] `.github/workflows/mpc-e2e.yml` exists, parses, and is listed as
      `active` by `gh workflow list`.
- [ ] A manual dispatch has completed with `conclusion: success`.
- [ ] `MPC E2E` does not run on ordinary pushes to `main`.
- [ ] `RELEASE.md` §0 tells the maintainer to dispatch it before tagging.
- [ ] `CHANGELOG.md` no longer contains the `--release`-less invocation
      outside the explicit correction note, and no longer claims "~5 min".
- [ ] `horcrux-core/tests/multi_party_ecdsa.rs` is byte-for-byte
      unchanged. Verify against the commit this plan started from
      rather than a fixed `HEAD~N` offset, which drifts if any task
      produces a different number of commits:

      `git diff <pre-task-1-sha> -- horcrux-core/` must be empty.
- [ ] The runtime figure in the repo is measured, not estimated.
- [ ] Every markdown block added inside a `- [ ] ` list item renders
      as a real blockquote/code block, not preformatted text —
      check with
      `sed -n '<range>p' RELEASE.md | jq -Rs '{text: ., mode: "gfm"}' | gh api -X POST /markdown --input -`
      and confirm the output contains `<blockquote>` and
      `highlight-source-shell`, not `<pre><code>&gt;`.
