# Spec — record-and-sync (aspect 2 of injection-matrix-completion)

**Aspect of:** injection-matrix-completion · **PRD ref:** M3, M7 · **Date:** 2026-09-05

## Problem slice and user outcome

The run's numbers are worthless if they live only in the run log. Outcome: the FMS tally
computed with denominator discipline, the tracked table's **v0.2.1 row** appended (the
v0.2.0 row stays as recorded history — one row per release, step 93), and the unit's
record in `STATUS.md` + `CLAUDE.md` front door.

## In-scope

- **M3 — FMS tally:** deliverable rows whose expected rung landed / deliverable rows
  actually run; skips and voids named; a not-closeable outcome recorded as such
  (`SMOKE_CHECKLIST.md:1986-1987`).
- **M7 — the record:** `STATUS.md` honesty-block entry (what the unit did / what it is
  NOT — no gate passes); the v0.2.1 tracked-table row (release, date, rows run, skipped,
  voided, FMS, notes with the adjudication summary); `CLAUDE.md` front-door sync (the
  matrix's "not closeable" claim replaced by the measured outcome); the step 88-92 notes
  amended where the run changes them.

## Out-of-scope

- The run itself (aspect `matrix-run`).
- The P2 gate's judgment; any gate claim.
- Notarization; C9+.

## Acceptance criteria (testable)

- The tracked table's v0.2.1 row matches the run-log tally exactly (rows run / skipped /
  voided / FMS / notes).
- The `STATUS.md` entry follows the honesty-block format; the "what this unit is NOT"
  block is present.
- `CLAUDE.md`'s matrix sentence matches the tree.
- Floor 1758 holds; `git status` clean of strays.

## Dependencies and sequencing

- Last aspect — after `matrix-run`'s rows, adjudication, and windows are recorded.
- The FMS tally needs the run-log lines in hand.

## Open questions / risks

- Re-baseline margins are not this unit's concern (no tolerance rows are touched — the
  matrix has no tolerance table; the ≥95% bar is a gate reading, not a re-baseline).
- If a defect fix changed the harness (M6 in `matrix-run`), the record names it with its
  commit.