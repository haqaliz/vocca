# Spec: record-and-sync

**Aspect of:** p2-gate-measurement · **PRD ref:** M6, S1, execution order step 6 · **Date:** 2026-09-01

## Problem slice and user outcome

The measured numbers exist scattered across runs and shell history; the repo's record
must carry them in the single places the next unit and the gates read. Outcome: the
five `tolerances_*.md` files carry their measured-values rows, `STATUS.md` carries the
unit's entry, `SMOKE_CHECKLIST.md`'s tracked tables carry their first real rows,
`CLAUDE.md`'s front door is synced, and the stale citations this unit touched are
corrected — one coherent record commit (or a small set) that makes "what is measured"
true in exactly one place.

## In-scope

- Measured-values rows in the tolerances files whose runs happened:
  `tolerances_20260810.md` (WER both engines + whisper streamed rows),
  `tolerances_20260825.md` (warm-start ratio), `tolerances_20260831.md` (equivalence
  table + key-up costs), `tolerances_20260815.md` (F2 preference), and the
  `settings-live-controls/verification-smoke/tolerances_20260829.md` artifact-hash
  table where the step 19 run produced one.
- `STATUS.md`: the `p2-gate-measurement` entry (what the runs measured, what was fixed,
  what remains unmeasured — including the still-open items the unit deliberately did not
  close).
- `SMOKE_CHECKLIST.md`: the matrix tracked table's first row (step 93), the equivalence
  verdict row (step 126), the latency rows (steps 71-72, 77, 128), the F2 row (step 73).
- `CLAUDE.md`: front-door status paragraphs updated to the state of the tree this branch
  ships in.
- S1 — citation drift corrected where this unit touched it: stale `AppBootstrap.swift`
  line citations in the dictation-loop and matrix sections, and the stale step-67
  preamble (the Settings → General activation-mode switch shipped 2026-08-26,
  `STATUS.md:534-542`).
- `docs/planning/p2-gate-measurement/` artifacts are final and committed.

## Out-of-scope

- Re-running anything: this aspect records what the earlier aspects measured; a missing
  row is recorded as missing with its reason, never re-measured here.
- Inventing numbers: every row cites its run's printed output.
- The release (follow-on card) and the external-users gate leg.

## Acceptance criteria (testable)

- Every run that happened has its measured row in exactly the file the procedure names;
  every row cites its source run.
- The single-source scans stay green (a re-baseline that duplicated a constant fails).
- `STATUS.md`'s entry names what is NOT proven — the unit's own honesty block — with the
  same severity as what it proves.
- `CLAUDE.md` and the front door describe the tree this branch ships in.
- Floor 1731 holds (docs-only commits; no code change expected).

## Dependencies and sequencing

- Last aspect: requires the prior five to have produced their rows.
- S1's citation fixes are safe to apply here in one sweep (they touch only the sections
  this unit executed).

## Open questions / risks

- A number the founder declined to re-baseline stays provisional with a dated row saying
  so — "a number that moved with no row behind it is a number nobody can check"
  (`tolerances_20260829.md:67-69`).
- The 7-day gate log is outside the repo; its day-1 existence note is recorded in the
  dictation-loop rows, and the front door must not claim the P0 gate passed.