# Aspect spec — `smoke-checklist`

Parent: `docs/planning/dictation-loop/prd.md` (R8-4, metric 1). File: `docs/SMOKE_CHECKLIST.md` (docs-only).

## Problem slice

No part of the loop runs in CI — no Accessibility grant, no TCC, no microphone on a
hosted runner. The founder's machine is the loop's first execution; the checklist must
say exactly what to do and what "pass" means, in the existing steps 22-35 discipline
(cause-specific gestures, expected results recorded).

## In scope

New `SMOKE_CHECKLIST.md` entries (following the file's existing section structure):

1. **First dictation** (Notes + TextEdit): 10-second utterance lands **verbatim**; the
   full state sequence OPENING → RECORDING (waveform moves with voice — the "it heard
   me" signal, `PRODUCT_SPEC.md:84`) → TRANSCRIBING → DELIVERED → IDLE.
2. **Secure Input through the loop**: a password field shows the reason-only notice;
   no text ever lands there.
3. **Esc during RECORDING** and **Esc during TRANSCRIBING**: aborts; nothing injected.
4. **Short press** (~80 ms): returns to IDLE, no injector call, no failsafe.
5. **Engine-not-ready refusal**: with the model removed/blocked, dictation is refused
   with `.modelUnavailable` copy and the mic never opens.
6. **Toggle session**: a toggle-mode session runs and ends via its triggers (ceiling /
   tap-disabled / system), per the session-lifecycle spec.
7. **20-cycle stability**: no crash, no stuck session.

## Out of scope

Real-engine WER runs (steps 18-19, unchanged); ladder adapters (steps 22-35, unchanged);
automation; changes to `CLAUDE.md` or other docs.

## Acceptance

- Each entry has a named gesture, the expected result, and the failure report line
  (the file's convention), citing the PRD metric they verify.
- No entry invents a behavior the spec or machine does not have.

## Dependencies / sequencing

Last; references the shipped behavior of `loop-wiring` + `widget-live-states`.
