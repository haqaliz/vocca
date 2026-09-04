# Spec — record-and-sync (aspect 5 of unmeasured-numbers-sweep)

**Aspect of:** unmeasured-numbers-sweep · **PRD ref:** M8, S1 · **Date:** 2026-09-04

## Problem slice and user outcome

Measured numbers are worthless if they live only in terminal output. Outcome: every run's numbers land in the repo's record surfaces (`STATUS.md`, `SMOKE_CHECKLIST.md` step rows, the matching `tolerances_*.md` files, `CLAUDE.md` front door), the stale docs the sweep touched are corrected, and the engine-picker copy decision the sweep enables is surfaced — so the pre-PH pass and the P2 gate read honest, cited numbers.

## In-scope

- **M8 — The record:**
  - `docs/STATUS.md`: the unit's entry (append-only, newest first, honesty-block format per the established pattern).
  - `SMOKE_CHECKLIST.md`: step rows 19, 21, 71-72, 73, 95-96, 102-104, 103 with the measured values beside each step number.
  - Tolerance rows: `tolerances_20260810.md` (whisper WER, incl. the q5_0 disposition), `tolerances_20260815.md` (F2 preference), `tolerances_20260825.md` (latency composite, founder-signed with margin).
  - `CLAUDE.md` front-door status synced (the "Still unmeasured" sentence retires the surfaces this unit closed).
- **S1 — Stale-doc fixes where touched:** `real-engine-runs/spec.md:8` (stale STATUS range → the whisper-seeded-tolerances claim lives at `STATUS.md:238-240`), `cleanup-eval-f2/plan_20260901.md` (floor 1731 → 1755; `VOCCA_CLEANUP_EVAL=1` → `<pairs-dir>`), `tolerances_20260810.md` prose status (predates its own measured table).
- **Engine-picker copy decision point (recorded, founder-signed):** the engine-picker tradeoff copy (`CAPABILITY_ROADMAP.md:89`; the settings Speech tab) is a product claim that follows from the measured numbers. This aspect surfaces the decision — update the copy to match the measured whisper WER (e.g. weaker-on-noise if the number says so), or record the copy as-is with the founder's sign-off. The decision is recorded in the unit's STATUS entry either way; the copy change itself, if approved, is a small test-first slice (the picker copy is pinned by tests where it exists).

## Out-of-scope

- Any gate claim — no number lands as a pass; the P2 gate's three legs are evaluated outside this unit.
- The injection matrix tracked table (C8's other half; `injection-matrix-completion` owns it).
- Notarization/runbook status (blocked — not purchased; `release-distribution` owns it).

## Acceptance criteria (testable)

- Every executed SMOKE step has a recorded row with its measured values; nothing recorded without a run artifact behind it.
- Every tolerance file carries the founder-signed row with margin; the single-source scans stay green.
- `CLAUDE.md`'s unmeasured-surfaces sentence matches the tree after the sweep.
- The engine-picker copy decision is recorded with the founder's sign-off (either disposition).
- Floor 1755 holds (the copy change, if approved, is RED→GREEN).

## Dependencies and sequencing

- Last aspect — runs after all measurements (whisper-wer, cleanup-eval-f2, latency-record) and their re-baselines exist.
- The copy decision needs the whisper WER numbers in hand.

## Open questions / risks

- Re-baseline margins are the founder's decision at record time, recorded in each step's note.
- The STATUS entry must follow the repo's honesty-block format (what the unit is NOT, and must not be claimed) — the pattern in every prior entry.
- If a tolerance re-baseline changes a shipped constant, the single-source scan enforces land-in-exactly-one-file; a second site is a test failure, not a doc note.