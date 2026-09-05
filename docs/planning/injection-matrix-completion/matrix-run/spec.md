# Spec — matrix-run (aspect 1 of injection-matrix-completion)

**Aspect of:** injection-matrix-completion · **PRD ref:** M1, M2, M4, M5, M6 · **Date:** 2026-09-05

## Problem slice and user outcome

The tracked matrix row reads "not closeable" — 17 deliverable rows + step 92 remain
(`SMOKE_CHECKLIST.md:1992`). Outcome: every remaining row executes on the founder's
machine against the v0.2.1 build with a file-based artifact, byte mismatches are
adjudicated (ASR vs injection), and the run's numbers exist for the FMS tally.
Recorded, never gated.

## In-scope

- **M1 — the 17 remaining deliverable rows.** `Scripts/injection-matrix.sh` (full run or
  `--row`) on the founder's machine, v0.2.1 build; per-row PASS = bytes (automated
  select-all/copy/pbpaste vs the fixed phrase) **and** the log naming the expected rung
  as the landing rung (founder y/N, `SMOKE_CHECKLIST.md:1806-1808`); every row's evidence
  cites the run-log JSONL line + `strategies.json` state.
- **Control row first:** Notes re-run (prior recorded outcome: byte mismatch,
  accessibility demoted with fresh re-probe window 2026-09-10) — a changed outcome on
  v0.2.1 is itself evidence; a harness break pins RED→GREEN (M6).
- **M2 — step 92 (Secure Input refusals):** all four conditions — log `attempted: []`,
  failsafe copy path, transcript copyable, `strategies.json` gained nothing.
- **M4 — adjudication:** every byte mismatch re-checked by re-transcribing the fixture
  phrase through the real engine (`VOCCA_MODEL_DIR` + the WER machinery); a transcript
  mismatch records as ASR's matter (step 19), never an injection failure; an
  `.accessibility` byte mismatch with a lying read-back is a defect (fix test-first).
- **M5 — windows:** step 90 (re-probe: ≥5 clipboard deliveries + 7-day window) and step
  91 (promotion) recorded elapsed/not-elapsed; daily-use accumulation runs in parallel
  (feeds the P0 gate log too); step 89 dispositioned (Teams half unrunnable while the row
  is Teams).
- **M6 — defect fixes, test-first:** RED→GREEN, floor 1758, escalation rule for
  PRD-level/seam changes.

## Out-of-scope

- The FMS tally and the tracked-table row (aspect `record-and-sync`).
- The live unified-log check (S1 — opt-in, consent only).
- Any gate claim, notarization, C9+.

## Acceptance criteria (testable)

- Every one of the 17 rows + step 92 has a run-log line + named evidence; no row runs
  without an artifact.
- PASS rows satisfy bytes + rung-y/N; FAIL rows carry the adjudication note (ASR vs
  injection) in the run-log note field.
- The control row's outcome is recorded beside its prior state.
- Every defect fix: RED→GREEN, floor 1758 holds; the branch stays green.
- Step 90/91 window state recorded; step 89 dispositioned.

## Dependencies and sequencing

- The harness + evidence chain are shipped (injection-matrix-record unit) — this aspect
  is execution.
- Daily-use accumulation (clipboard deliveries) starts before the run and continues
  through it.
- The v0.2.1 released build is the run target (`PRD` OQ1).

## Open questions / risks

- R2: FMS may be not-closeable (3 uninstalled rows) — recorded outcome, not failure.
- A genuinely refusing app (not a lying read-back) records as a row-failure — the
  matrix's expected finding, not a defect (PRD approval locked this in).
- The unified-log lines stay corroboration-only until S1 is consented.