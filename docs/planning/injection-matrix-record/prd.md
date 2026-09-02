# PRD: injection-matrix-record

**Unit:** `injection-matrix-record` · **Branch:** `feat/injection-matrix-record/aliz` · **Phase:** P2 (latency + injection feel) · **Date:** 2026-09-02

> Inline brief only (no GitHub issue) — see `docs/planning/_card/issue.md`. Template shape: the
> landed `p2-gate-measurement` unit. Everything here **records, never gates**: no number lands as
> a gate pass; the P2 gate's three legs (`docs/ROADMAP.md:176-181`) stay the gate's call.

## Problem Statement

The injection matrix — the measurement surface the P2 gate's ≥95% first-method-success leg is
judged on — has no recorded first row. The `p2-gate-measurement` unit ran the baseline
(`STATUS.md:100-107`): `--verify-bundle-ids` came back 16 confirmed / 0 mismatched, six rows
skipped (not installed), and the founder reported all rows landing — but **the machine record
shows no sessions and no `strategies.json` for the run windows**, so the tracked table's v0.1.0
row reads `FMS: **unrecorded**` (`SMOKE_CHECKLIST.md:1905`).

The dig (`docs/planning/_card/understanding.md`) established the root cause: **the machine
evidence the checklist names does not exist in the current build**. The app's unified log has no
info-level session or landing-rung lines (`VoccaCore` has zero logging; `InjectionResult` is
consumed only by strategy memory and the probe-only latency ledger); `strategies.json` writes
only on strategy change; and `Scripts/injection-matrix.sh` writes nothing to disk despite
`matrix-smoke/plan_20260827.md:16` promising "its own run log". A row's rung observation is a
founder y/N with no independent machine artifact behind it.

So the unit is: make the evidence real (test-first), then execute the already-written acceptance
(steps 87-93) and record the first measured row.

## Goals & Success Metrics

- **G1 — Evidence exists.** The checklist's own log-discipline
  (`log show --predicate 'subsystem == "dev.vocca.Vocca"'`, used at `SMOKE_CHECKLIST.md` steps
  96/101/103) names a session milestone and a landing rung per real dictation; the harness
  writes a per-row run log. Both are test-first and CI-executable in their pure halves.
- **G2 — Baseline recalibrated.** Step 87 executed: six missing apps swapped same-class per
  step 87's own instruction (baseline precedent: iTerm2→Warp, Slack→Teams); `--verify-bundle-ids`
  zero mismatches; expected-rung column re-baselined from the run's observations.
- **G3 — First measured row.** Step 88 tracked run executed; every installed row produces a
  recorded observation with machine evidence; the tracked table gains its first measured row
  (`SMOKE_CHECKLIST.md:1898-1905`, columns `Release | Date | Rows run | Skipped | Voided | FMS |
  Notes`) with FMS recorded or explicitly **not closeable on this machine**. Denominator
  discipline: FMS is computed over the 20 deliverable rows actually run, with skips/voids named
  in the row — "a matrix run with many of either is not a matrix run"
  (`SMOKE_CHECKLIST.md:1726-1728`).
- **G4 — Steps 89-92 dispositioned.** Step 92 (Secure Input refusals) run and recorded; steps
  89 (Slack-specific half unrunnable — the row is Teams since 2026-09-01), 90 (re-probe window
  not elapsed), 91 (promotion window not elapsed) recorded as not-due/unrunnable with reasons —
  a documented outcome, neither pass nor fail (`matrix-smoke/plan_20260827.md:195-197`).
- **G5 — No regressions, no overclaim.** Suite floor 1746 never drops
  (`Scripts/test-with-floor.sh`); every fix lands test-first; no gate is claimed.

## User Personas & Scenarios

- **The founder (sole operator).** Runs the matrix by hand per the checklist — the harness
  deliberately cannot press ⌥Space or guess a rung (`injection-matrix.sh:24-30`). This unit
  makes his per-row y/N answerable from a machine artifact instead of memory, and gives him a
  run log to cite in the tracked table.
- **The P2 gate.** The consumer of the FMS number. It must be able to distinguish "measured" from
  "reported, not measured" (`SMOKE_CHECKLIST.md:1905`).

## Requirements

### Must-have

- **M1 — App-side evidence logging.** Info-level log lines, subsystem `dev.vocca.Vocca`,
  emitted by the real session/ladder path: session milestones (open/record/transcribe/deliver)
  and the landing rung for a delivery (including `attempted: []` refusals and the falls-through
  trace). Pure formatter/vocabulary tested headlessly (house pattern: decisions above the seam,
  thin `os.Logger` adapter — `CLAUDE.md`'s CGEvent-tap caveat). Zero behavior change to the
  ladder; zero telemetry (local-only, no egress — the zero-network invariant must keep passing).
- **M2 — Harness run log.** `Scripts/injection-matrix.sh` appends one machine-readable line per
  completed row (row name, date, rung observed, bytes matched, verdict pass/fail/skip/void) to a
  log file under `~/Library/Application Support/Vocca/` (same home as `strategies.json`), and
  prints its path. This is the artifact `matrix-smoke/plan_20260827.md:16` promised. The
  `--self-check` half stays CI-runnable; the shell-side writing is a thin, reviewable slice.
- **M3 — Baseline run (step 87).** `--verify-bundle-ids` to zero mismatches; six same-class
  swaps (Pages, Notion, Ghostty, IntelliJ, Zed, 1Password → installed same-class apps) recorded
  in the harness table and the checklist's ID-source column; fresh memory
  (delete `strategies.json`, relaunch); full matrix; per-row rung/bytes/surprises recorded.
  Failure = a row with no recorded observation (`SMOKE_CHECKLIST.md:87`).
- **M4 — Tracked run (step 88).** Steady-state memory; ≥19 of 20 deliverable rows first-method
  and both refusals refuse; per-row observations backed by the M1/M2 evidence; tracked table's
  first measured row appended. Fewer than 19/20 → recorded, never a silent pass; the per-row
  misses become the work list.
- **M5 — Step 92 (Secure Input).** Refusal row observed with memory active: log records
  `attempted: []`, failsafe shows the password-field copy, transcript recoverable, `strategies.json`
  gains nothing for the bundle id.
- **M6 — Record-and-sync.** Tracked table rows, `docs/STATUS.md` entry with the house honesty
  block ("What this unit is NOT, and must not be claimed:"), `CLAUDE.md` front-door sync, test
  floor re-recorded if it moved. Every claim cites its run.

### Should-have

- **S1 — Seed re-check.** After swaps, confirm no seeded row lost its seed (the six swapped rows
  are all `.clipboardPaste`, so this is a verification pass, not a change — unless a swap lands
  on an allowlist/hostile seed, which must be flagged before changing).
- **S2 — Citation-drift fix.** The tracked table moved to `SMOKE_CHECKLIST.md:1898-1905`; stale
  references (e.g. the 1877-1879 citations in the p2-gate-measurement plan) corrected only where
  this unit touches them.

### Nice-to-have

- **N1 — Run-log path flag** (`--run-log <path>`) for a custom evidence location.

## Technical Considerations

- **Where the rung line comes from:** `LadderInjector.inject` already produces the full
  `InjectionResult` (rung / attempted trace / verified) that strategy memory consumes
  (`ARCHITECTURE.md`'s ladder + `InjectionStrategyStore`). M1 adds an evidence logger at that
  seam — no new abstraction, no new behavior.
- **Test-first surface:** the pure half (event vocabulary + line formatting + verdict derivation
  from `InjectionResult`) is CI-executable; the `os.Logger` emission is a thin adapter. The
  harness's `--self-check` stays the CI-runnable half; live modes stay founder-machine.
- **Sequencing:** M1/M2 (evidence) land **before** M3/M4 (the runs) — a run without evidence
  repeats the v0.1.0 failure. M3 and M4 are the founder's machine-time steps, executed per the
  checklist's gesture text, not invented.
- **House pattern for measurement units:** docs-only record-and-sync phases still run the floor
  check (`p2-gate-measurement/record-and-sync/plan_20260901.md:7-9`).
- **Rough sizing (feasibility signal):** the evidence slice (M1/M2) is the only code — a pure
  vocabulary/formatter + thin adapters, small relative to house precedent
  (e.g. `latency-instrumentation`'s ledger). M3-M6 are founder-machine execution + records,
  mirroring `p2-gate-measurement`'s own split.
- **Privacy:** log lines are session-shaped, not transcript-shaped (a rung name and milestone —
  never the text itself); the zero-network default test is a permanent release blocker and must
  stay green.

## Risks & Open Questions

- **R1 — Evidence lands but the run still can't close.** ≥19/20 may be unachievable on this
  machine's app set even after swaps (some swapped classes may themselves fail, or a swap is a
  promotion candidate whose window hasn't elapsed). Outcome: recorded, "not closeable on this
  machine", the per-row misses are the work list (`STATUS.md:106-107` precedent). Not a failure.
  **Stopping rule (from the p2-gate-measurement precedent):** if the baseline lands materially
  below 19/20, record it and do NOT stop the unit — numbers are recorded, never gated, and the
  founder decides at the gate (`injection-matrix/plan_20260901.md:90-95`).
- **R2 — The run's observations contradict expected rungs.** Step 87's output *is* the
  calibrated expectation (`SMOKE_CHECKLIST.md:87`); re-baseline through the recorded
  observations, never by editing expectations to match a bad run.
- **R3 — Logging scope-creep.** M1 must stay evidence, not instrumentation: no spans, no
  counters, no persistence beyond the recovery journal, no egress. If the latency ledger is
  touched, stop and flag.
- **R4 — Slack-row unobservability.** Step 89's Slack half is unrunnable while the row is Teams;
  recorded as such (M4/G4), not rewritten to fit.
- **OQ1 — Swapped apps' expected rungs.** Same-class swaps keep the class's expected rung
  (`.clipboardPaste`) unless the baseline observation says otherwise. Confirm at step 87, don't
  assume. The tech-plan must name candidate swap apps per class before the run.
- **OQ2 — Where the run log lives.** Default `~/Library/Application Support/Vocca/matrix-runs/`
  unless the founder prefers a repo-cited path (N1).
- **OQ3 — Logger home across modules.** Session milestones originate in `VoccaCore`'s session
  machine; the landing rung in `VoccaInject`'s `LadderInjector`. One evidence logger must be
  reachable from both without a new module dependency — resolve in tech-plan (vocabulary +
  formatter in `VoccaCore`, emission via an injected recorder at the ladder seam).

## Out of Scope

- Whisper WER + streamed cycle (step 19 — GGUF absent; a separate real-engine-runs surface).
- F2 cleanup eval (no founder corpus), the P0 7-day log, the P2 gate's third leg (≥5 external
  users), and any release/DMG/cask work.
- Any gate claim, tolerance re-baseline, or strategy-memory behavior change.
- Transcript text in any log or run artifact (evidence is shape, not content).
- Steps 89/90/91 execution (not-due/unrunnable this release — see G4).