# Spec: dictation-loop

**Aspect of:** p2-gate-measurement · **PRD ref:** M1, execution order step 2 · **Date:** 2026-09-01

## Problem slice and user outcome

The dictation loop has never delivered text end to end on a real machine
(`SMOKE_CHECKLIST.md:1067-1076`). Outcome: the founder's first real dictation lands
byte-for-byte in Notes and TextEdit, the Secure Input / Esc / short-press /
model-unavailable / toggle / ceiling rows behave as specified, 20 cycles end with zero
loss, and day 1 of the P0 gate's 7-day daily-use log is recorded. Every defect this
first execution surfaces lands test-first.

## In-scope

- Execute and record SMOKE steps 62–68 on the founder's machine (grants live, model
  present and prepared):
  - 62 — first dictation, Notes + TextEdit, byte-for-byte vs the engine's transcript.
  - 63 — Secure Input: no session starts over a password field; the `.secureInput`
    held-failsafe copy via the ⏎-retry route of step 27.
  - 64 — Esc during RECORDING and TRANSCRIBING; nothing lands; Esc-during-OPENING mic
    flash observed as expected.
  - 65 — shortest session (~80 ms): IDLE, no text, no failsafe, no failure notice.
  - 66 — model-unavailable: `.modelUnavailable` reason-only notice, mic never lights.
  - 67 — toggle triggers (`.toggledOff`), audio-configuration-change backstop, 120 s
    ceiling; hold-to-talk via the Settings → General mode switch if exercised.
  - 68 — 20-cycle stability, `recovery/` inspected, zero loss.
- Fix every defect surfaced by these steps (RED→GREEN, regression test, floor 1731
  holds; escalation rule per PRD M5).
- Record day 1 of the 7-day daily-use gate log (the log lives outside the repo; its
  first entry's existence is noted in the SMOKE rows).

## Out-of-scope

- The remaining 6 days of the 7-day gate (founder habit, outside the unit).
- The injection matrix (aspect `injection-matrix`), real-engine runs (aspect
  `real-engine-runs`), F2 (aspect `cleanup-eval-f2`).
- Any product change not surfaced by a failing step.

## Acceptance criteria (testable)

- All seven rows 62–68 recorded with pass conditions met, or explicitly "not performed"
  with the shipped reason (step 47's convention — never an invented criterion).
- Every surfaced defect has a test-first fix commit on the branch; the suite runs green
  via `Scripts/test-with-floor.sh` after each fix.
- No transcript lost in any row (the loop's invariant: every path terminates in the
  field, the held failsafe, or a reason-only notice).

## Dependencies and sequencing

- Requires `provision-and-verify` (model present) + Accessibility/mic grants (steps
  5–10).
- Before `injection-matrix`: the matrix assumes a working real loop.
- The streamed final vs batch (equivalence) is not this aspect's question — the byte
  compare is against the engine's own transcript.

## Open questions / risks

- R1: first-execution defects expected (the repo's consistent pattern); the aspect's
  budget assumes 1–3 defects, each bounded by M5's escalation rule.
- Toggle is the default since 2026-08-25; the checklist preamble's "toggle control not
  wired" claim is stale (`STATUS.md:534-542`) — the Settings switch is the route for the
  hold-to-talk half.