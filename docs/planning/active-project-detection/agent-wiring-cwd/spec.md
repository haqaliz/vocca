# Aspect spec: agent-wiring-cwd

> Source: `docs/planning/active-project-detection/prd.md` R3, R4, S2 · Date 2026-10-01.

## Problem slice and user outcome

The composition: arm-time resolution and the threading through arm/confirm, the intent
leg's enrichment (S2 — voice-armed rows detect too), the editor copy, and the G5
re-anchor. User outcome: arming (or phrase-arming) a row whose directory is empty shows
the detected project in the sentence — resolved once, bound, honest.

## In-scope requirements

- **The closure**: `composeCodingAgentWiring` gains an injected
  `activeProjectDirectory: @Sendable () async -> String?` (default nil-shaped — a
  composition that doesn't wire it is byte-identical to today); `AppBootstrap` fills it
  from `AccessibilityContext.workingDirectory()` (the metadata lane — **never** through
  the consent-gated `contextResolution` slot).
- **Arm path**: at arm, when the row's `projectDirectory` is empty, resolve once and
  build the invocation **with** `resolvedDirectory`; the card signal carries it; confirm
  rebuilds the identical invocation — one resolution, four identical renders (G3).
- **The voice leg (S2)**: `IntentWiring`'s action leg enriches the invocation with the
  same resolution when the row's directory is empty (one resolution per turn; the
  catalog/enablement machinery untouched).
- **Editor copy (R4)**: the Project directory field's caption — "leave empty to detect
  the focused app's project".
- **G5**: `AppBootstrap` changes → the deliberate re-anchor in this aspect's REFACTOR
  (computed with `shasum -a 256`, never edit-to-match; dictation digests unchanged).

## Out-of-scope

- The read and the carrier (own aspects); `ContextSnapshot`; the safety spine; the
  dictation path.

## Acceptance criteria (test-first)

1. A row with an empty directory: arm → the sentence shows the resolved directory
   verbatim (over an injected fake resolution); confirm runs in it; the audit record
   shows the sentence.
2. A row with an explicit directory: detection is never consulted (a recording fake
   proves zero calls — explicit wins, G2).
3. One resolution per arm: the fake counts exactly one call across arm → re-render →
   confirm (the four renders share the carried value; the binding holds).
4. A focus change mid-card cannot change the run directory (the invocation carries the
   arm-time value — asserted by confirming after the fake's answer would have changed).
5. The voice leg: a phrase-armed row with an empty directory resolves and runs in the
   detected directory (S2); without detection available → the clause-less sentence.
6. The composed default facts unchanged (`agents=0 spawnsSubprocess=false`); the
   editor caption shipped; G5 re-anchored deliberately.

## Dependencies / sequencing

After `working-directory-source` + `invocation-carrier`. Before `agent-pins`.

## Open questions

- None — the metadata lane, the explicit-wins rule and the one-resolution contract are
  the recorded decisions.