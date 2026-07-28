# MPC End-to-End Suite as a Release Gate

**Date:** 2026-07-28
**Status:** Approved, pending implementation

## Problem

`horcrux-core/tests/multi_party_ecdsa.rs` holds the only automated
proof that the full CGGMP21 ceremony works with more than two
parties — 3-of-3 DKG → sign, 3-of-3 DKG → sign → refresh → sign
(asserting the group public key survives refresh), and 5-of-5 DKG →
sign.

All three carry `#[ignore]`, so `cargo test --workspace` skips them
and **no CI workflow has ever run them**. The `rust-tests` job in
`ci.yml` runs plain `cargo test --workspace`; nothing passes
`--ignored`. They are therefore a manual gate that depends entirely
on a maintainer remembering.

This matters more than a typical skipped test. A regression in the
fan-out path (broadcast vs unicast routing, per-party mailbox,
completion detection) is invisible at n=2 because every broadcast has
exactly one recipient — which is precisely the degenerate case the
rest of the suite covers. A change that silently breaks 3-party
ceremonies would pass all 260 enforced tests.

Two secondary defects found while investigating:

1. The invocation recorded in `CHANGELOG.md` omits `--release`:
   `cargo test -p horcrux-core --test multi_party_ecdsa -- --ignored`.
   The test file's own doc comment specifies `--release`, and there
   are no `[profile]` overrides in any `Cargo.toml`, so the recorded
   command runs unoptimised bignum arithmetic — roughly an order of
   magnitude slower.
2. The same entry records the runtime as "~5 min". Measured on an
   Apple-silicon Mac in release mode with `--test-threads=1`, the
   three tests take **617.95 s ≈ 10.3 min** (`user 6m20s`,
   `sys 4m50s`).

## Goals

- The three ceremonies run automatically on the release path.
- Everyday `cargo test --workspace` stays fast and unchanged.
- Failure is loud and attributable to a specific tag.
- The recorded invocation and runtime become accurate.

## Non-Goals

- Running on pull requests. At an estimated 30–50 min on a GitHub
  runner this would multiply PR feedback time for a suite that only
  regresses when MPC internals change.
- Running nightly. Rejected in favour of release-only triggering.
- Removing `#[ignore]`. The attributes are what keep the three
  ceremonies out of the default run; un-ignoring them would add
  ~10.3 min of pure execution to every `cargo test --workspace`
  (measured at 4m23s wall-clock today, almost all of it compilation).
- Speeding the tests up. Out of scope; the runtime is inherent to
  Paillier aux-info generation.

## Design

### New workflow: `.github/workflows/mpc-e2e.yml`

A dedicated single-purpose workflow, consistent with the existing
`cargo-audit.yml`, `cargo-deny.yml`, and `relay-smoke.yml`.

The rejected alternative was a tag-gated job inside `ci.yml`.
`ci.yml` currently triggers only on `push` to `main` and
`pull_request`; adding tag triggers there would also re-run
`rust-tests`, `rust-coverage`, and the ~17-minute `ios-build` job on
every tag, changing existing behaviour as a side effect.

### Triggers

```yaml
on:
  push:
    tags:
      - "v*"
      - "!v*-dev.*"
  workflow_dispatch:
```

`v0.5.0-rc.2` and `v0.5.0` match; `v0.5.0-dev.9` is excluded. The
repository has cut nine `-dev` tags against two `-rc` tags, so
including them would fire this job roughly five times more often than
it carries value.

GitHub evaluates these patterns in order and requires at least one
non-exclusion pattern; `tags` and `tags-ignore` cannot both appear on
the same event, so the `!` form inside `tags` is the only way to
express include-plus-exclude.

`workflow_dispatch` exists because tag-triggered failure arrives too
late: `RELEASE.md` creates the tag at §3, so a failure discovered
then means deleting and re-cutting the tag. The manual trigger lets
§0 pre-flight run the suite while the tag can still be avoided. The
tag trigger remains as the backstop for when someone skips §0.

### Job configuration

- `runs-on: ubuntu-latest` — 4 vCPU / 16 GB on public repositories.
- `timeout-minutes: 90`.

No workflow in the repository currently sets a timeout, so the
default is 6 hours. `drive_to_completion` polls up to
`iter_limit = 2000` and a ceremony that stalls without completing
would otherwise burn the full default before failing. 90 minutes
leaves substantial headroom over the 30–50 min estimate while
bounding the damage.

### Test invocation

```bash
cargo test -p horcrux-core --release --test multi_party_ecdsa -- \
  --ignored --nocapture --test-threads=1
```

- `--release` is mandatory, not an optimisation.
- `--ignored` selects exactly the three ceremonies; because the
  target names a single test file, nothing else can be swept in.
- `--test-threads=1` matches the invocation documented in the test
  file. Running the three concurrently would likely cut wall-clock
  time on a 4-core runner, but that deviates from the known-good
  invocation for a job whose runtime does not gate anything.
- `--nocapture` surfaces the per-phase `Instant` timings the tests
  already emit, so the log carries evidence of how long each ceremony
  took — useful for spotting gradual slowdown.

### Concurrency

```yaml
concurrency:
  group: mpc-e2e-${{ github.ref }}
  cancel-in-progress: false
```

A deliberate deviation from the other four workflows, which all set
`cancel-in-progress: true`. Cancelling a half-finished release
verification would leave a run that is not red but also did not
prove anything. Because the group key is the tag ref, concurrent runs
across different tags are unaffected.

### Permissions and caching

`permissions: contents: read` — the job reads the repo and reports
status; it needs nothing else.

`actions/cache` with key prefix `cargo-mpc-e2e-`, keyed on
`hashFiles('**/Cargo.lock')` in line with the existing workflows. A
distinct prefix is required because this is the only job building the
`release` profile; sharing `ci.yml`'s `cargo-` key would mean the two
jobs repeatedly evict each other's artifacts.

All third-party actions stay pinned to the commit SHAs already used
elsewhere in `.github/workflows/`, matching the repository's
pinned-to-SHA convention.

## Documentation changes

- **`RELEASE.md` §0** — add a pre-flight item to dispatch the
  workflow manually (`gh workflow run mpc-e2e.yml`) and wait for it
  to pass before tagging, with a note on why the tag trigger alone is
  insufficient.
- **`CHANGELOG.md`** — record the new workflow, and correct the two
  errors in the existing dependabot-triage entry: the missing
  `--release` flag and the "~5 min" figure.

## Testing strategy

The deliverable is CI configuration, so verification is behavioural
rather than unit-tested:

1. `actionlint` if available, otherwise a YAML parse, to catch syntax
   errors before pushing.
2. Confirm the three tests pass locally under the exact command the
   workflow runs — already done: 3 passed, 0 failed in 617.95 s.
3. After merge, dispatch the workflow manually via
   `gh workflow run mpc-e2e.yml` and confirm it goes green. This
   exercises the `workflow_dispatch` path, the cache key, the release
   build on a runner, and the real runtime.
4. Confirm the tag filter by observation at the next `-rc` tag. The
   `-dev` exclusion cannot be proven without cutting a throwaway tag;
   the pattern semantics are documented, and the manual dispatch in
   step 3 covers the job body independently of the trigger.

## Risks

- **Runtime on the runner is an estimate.** 30–50 min is extrapolated
  from Apple-silicon timings; a 4-core x86 runner could be slower.
  The 90-minute timeout absorbs a roughly 3× miss, and step 3 above
  replaces the estimate with a measurement.
- **GMP builds from source** via the vendored
  `third_party/gmp-mpfr-sys`, adding to the cold-cache build. Bounded
  by the same timeout.
- **The gate can still be bypassed** by pushing a `-dev` tag or
  ignoring a red run — it reports, it does not enforce. Making it
  blocking would require branch/tag protection rules, which live
  outside the repository.
