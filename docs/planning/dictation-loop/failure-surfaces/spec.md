# Aspect spec — `failure-surfaces`

Parent: `docs/planning/dictation-loop/prd.md` (R5). Module: `VoccaCore` + `VoccaUI` + `VoccaInject` (journal schema note).

## Problem slice

The loop needs two honest, persistent notices with **no held text**: the engine is not
ready (model still downloading) and transcription failed. `FailsafeReason` has no cases
for either (`FailsafeReason.swift:28-40`); the FAILSAFE reducer and copy table only know
the three ladder reasons.

## In scope

- `FailsafeReason` gains `.modelUnavailable` and `.transcriptionFailed` (String raw values,
  journal-safe spellings).
- Copy-table entries in `FailsafeCopy` for both, with target-app agnostic copy (no text held).
- A **reason-only** presentation: the failsafe panel shows the reason with no selectable
  transcript and no copy/retry affordances — only dismiss (✕). Reached via a new
  `FailsafeState` case and `FailsafeAction`; the reducer's decision table stays time-free
  (never-auto-dismiss holds for the new case).
- `FailsafePanel` gains a public entry point to present a reason-only notice.
- Headless tests: reducer decision table for the new state (closed action set), copy
  lookup for both reasons, and a journal round-trip proving the new raw spellings persist
  and re-render (the recovery journal is the FailsafeReason schema consumer).

## Out of scope

- Transient/auto-collapsing error states; sounds; retry for failed transcription
  (re-triggering dictation is the retry); anything that holds a transcript when none exists.

## Acceptance (test-first)

1. RED tests first: reducer table, copy, journal round-trip.
2. A reason-only notice is dismiss-only — the closed action set has exactly one exit
   (`.dismissRequested`), no time-based transition exists.
3. `.modelUnavailable` and `.transcriptionFailed` never render the ladder's affordances
   (⌘C / ⏎ disabled for this state).
4. Full suite green via `Scripts/test-with-floor.sh`.

## Dependencies / sequencing

Before `loop-wiring` (its refusal gate and failure paths produce these reasons). No
dependency on the widget live states.

## Open questions

- None material. The panel variant's visual (reason text where the transcript would sit)
  follows `FailsafeView`'s existing layout.
