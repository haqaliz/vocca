# Aspect spec: usage-wiring

> Parent PRD: `docs/planning/daily-use-ledger/prd.md` · Aspect 4 of 5
> Depends on: `usage-store` (the seam, the module, the format)
> Blocks: `usage-tab`

## Problem slice

Connect the two halves that exist: every finalized session folds into the day's aggregate, the
window is loaded at launch and written back, and "today" is resolved once — at the seam that is
allowed to read a clock.

Until this aspect, the ledger's vocabulary and its file are both real and neither has ever seen a
session.

## Four things to settle, and their answers

### 1. How a finalized record reaches the window

`LatencyLedger` gains an **optional sink**, invoked after a successful `finalize`, carrying the
completed `SessionRecord`.

Rejected: folding from `snapshot()` on a timer. `snapshot()` is bounded at 512 records and drops
oldest at finalize (`LatencyLedger.swift:50,91-94`), so a busy stretch could evict records before
they were ever folded, and repeated folds would double-count unless the fold tracked which ids it
had already seen. A sink folds each record exactly once, at the moment it becomes a record, and
loses nothing.

Rejected: a decorating `LatencyRecorder` that wraps the ledger. `DictationLoopRoot.latencyLedger`
is typed concretely as `LatencyLedger?` (`AppBootstrap.swift:1512-1516`) and a wrapper would null
it, breaking the probe's asserted `PROBE-LATENCY` line — a permanent release blocker.

### 2. Where "today" comes from

A `CalendarDay` provider, injected into the wiring from `VoccaUsage`. `VoccaCore` reads no clock
(`CoreBoundaryTests.swift:707`) and has no `Calendar`, so resolving a wall-clock instant into a
**local** calendar day happens in the adapter — the same shape as `LatencySpan.elapsed` arriving
already measured, and as `StrategyMemory`'s `now` being passed in.

The day is resolved **per fold**, not cached at launch, so an app left running past midnight
starts a new day without a restart (PRD E3).

⚠️ **Check before writing:** `Calendar`/`TimeZone`/`Date` would be new system-framework names in
`VoccaUsage`. The tree applies one-file-per-seam rules to system-framework families
(`InjectionSeamBoundaryTests`' tables for `FileManager` and `UserDefaults`), and the
`latency-instrumentation` PRD notes "the H7/H8 one-file-per-seam rules apply to any new
system-framework name". Determine whether a `Calendar` family table exists or must be added, and do
whichever the existing rules require. Do not weaken a lint to avoid it.

### 3. Write cadence — never on the dictation path

Folding is in-memory and O(1). Writing is not, and must never happen synchronously inside
`finalize` (PRD M8; the prior slice's rule that recording is "amortized O(1) appends",
`latency-instrumentation/prd.md:115-117`).

The write happens:
- **on day rollover** — the previous day is complete and worth committing,
- **on app termination** — wired in `AppBootstrap`, since `App/VoccaApp.swift` is pinned to an exact
  shim by `BundleConfigurationTests.testAppTargetSourceIsOnlyAShimToTheBootstrapModule` and cannot
  hold lifecycle code,
- and otherwise **debounced**, at most once per interval, so a heavy day is a bounded number of
  writes rather than one per dictation.

The debounce interval is the plan's decision; it bounds how much counting a crash can lose. Losing
counts is acceptable — losing a *transcript* is not, and no transcript is involved here.

### 4. Load at launch, and the witness debt

`AppBootstrap.configure` loads the window once at launch and seeds the in-memory window from it.

**This load discharges the debt `usage-store` recorded.** Adding a `.library` product made
`VoccaUsage` a shipping target, which `ZeroNetworkTests` requires the probe to witness
(`ZeroNetworkTests.swift:1330` refuses to exclude a shipping target); with no format yet, Phase 1
satisfied it with a metatype reference — bookkeeping, not proof. Now that a real load happens in
the default configuration, **the probe must exercise that load and the metatype reference must go**,
restoring the effect-not-reference rule the probe's other drives are written under.

## In scope

- The sink on `LatencyLedger`, and its wiring in `AppBootstrap`.
- The `CalendarDay` provider in `VoccaUsage` (plus whatever seam the lint rules require).
- Load at launch; fold per finalize; write on rollover, termination and debounce.
- Replacing the probe's metatype reference with the real load.
- The composition passing the store; the probe's drives constructing it over a temp directory so no
  test writes to the founder's real Application Support.

## Out of scope

- Any UI (`usage-tab`).
- Changing the format, the vocabulary, or the outcome classes.
- Migrating an existing file — version 1 is the first version.

## Acceptance criteria (tests written first)

| # | Test | Asserts |
|---|---|---|
| D1 | A finalized record reaches the window exactly once, with the day the provider supplied | The sink folds, and folds once |
| D2 | Every outcome class and both session kinds fold through the real wiring, not just the pure fold | The seam carries what the vocabulary can express |
| D3 | **No write occurs during a dictation cycle** — a fold alone does not touch the filesystem seam | M8, the critical-path rule, asserted on the injected seam's call log |
| D4 | A day rollover triggers a write, and the completed day is in it | Rollover |
| D5 | Termination triggers a write | The `AppBootstrap` hook |
| D6 | The debounce coalesces N folds in the interval into at most one write | Bounded I/O |
| D7 | The window loaded at launch seeds the in-memory window; a second launch sees the first launch's counts | The round trip through the real composition |
| D8 | A load failure (missing/corrupt) leaves a usable empty window and never blocks a dictation | M7, at the wiring level |
| D9 | The day is resolved per fold, so a session after midnight lands on the new day | E3 |
| D10 | **The probe exercises the real load**, and `PersistentUsageStore.self` is gone from the witness list | The debt, discharged |
| D11 | The zero-network probe stays green with the store enabled | R11, the permanent release blocker |

## Risks

| Risk | Mitigation |
|---|---|
| A write lands on the dictation path and moves p95 | D3 asserts it on the seam's call log, not by inspection; the benchmark gate is the backstop |
| `Calendar` becomes an unseamed system-framework name | Checked before writing; add the table row the rules require |
| The probe writes to the founder's real `~/Library/Application Support/Vocca/` | The probe's drives must construct the store over a temp directory — verify no test touches the real path |
| A crash loses counts | Accepted and bounded by the debounce interval. No transcript is involved |
| The sink makes `LatencyLedger` re-entrant or slow | The sink is invoked after the record is complete; it must not be able to fail the finalize or block it |

## Note

This is the aspect where a user's machine first gains the file. Everything up to here could be
removed by deleting code; after this, a running Vocca writes `usage.json`.
