# Aspect spec: working-directory-source

> Source: `docs/planning/active-project-detection/prd.md` R1 · Date 2026-10-01.

## Problem slice and user outcome

The measured, seam-ridden read: the focused app's working directory via
`proc_pidinfo(PROC_PIDVNODEPATHINFO)`, exposed through `AccessibilityContext`, headless-
testable over an injected closure. User outcome: the composition root can answer "what
project is the user looking at" with a `String?`, never throwing, never persisting.

## In-scope requirements

- **The seam** (`Sources/VoccaContext/Accessibility/WorkingDirectoryRead.swift`): a
  synchronous seam over an injected libproc closure
  (`(pid_t) -> String?`-shaped; the adapter calls `proc_pidinfo` with
  `PROC_PIDVNODEPATHINFO` and reads `vi_cwd`), the never-throw doctrine (any failure →
  nil), and the file-naming rules: **no AX prefix, no FileManager, no
  `Process`-prefixed identifier** (the transport lint's deliberate prefix family — the
  naming hazard the dig named), `import Darwin` allowed in VoccaContext.
- **Exposure**: `AccessibilityContext` (the AX seam's sibling) gains
  `workingDirectory() -> String?` — the frontmost app's PID already flows through
  `AXContextSource.bundleIdentifier(of:)`; the read is extended there or handed through
  the existing seam shapes (the dig's option (a)/(b) — decide in the aspect, keeping
  Secure Input refusal first and the AX-family lint green: only `AXContextSource.swift`
  may name AX prefixes).
- **The honest facts**: nil on no focused app, Secure Input, or any libproc failure;
  the read is metadata (a path), never persisted, never in `ContextSnapshot` (the
  metadata lane stays separate from the BYOK gate).
- **Measurement**: the SMOKE 161 row lives in the record aspect; the headless suite here
  pins the seam over a recording fake (the exact closure call shape, first-wins, nil
  paths).

## Out-of-scope

- `ContextSnapshot` changes (by design — the metadata lane); the carrier/wiring (own
  aspects); any heuristic filtering of the path (the `/`-cwd fact is measured, never
  refused — R-C of the PRD).

## Acceptance criteria (test-first)

1. The seam returns the injected closure's answer unchanged; a nil closure answer → nil.
2. A recording fake proves the exact call shape (pid → result), and the adapter never
   calls anything else.
3. The exposure returns nil when Secure Input is active (refusal first — the AX source's
   existing ordering).
4. No focused app / failed PID resolution → nil, quietly.
5. The new file names no forbidden family: the transport lint, the FileManager table,
   the AX-family lint and the module-boundary tests all stay green untouched.
6. The read is never persisted and never joins `ContextSnapshot` (asserted by the
   absence of any wiring to those paths in this aspect's diff).

## Dependencies / sequencing

First (the wiring needs the closure). Before `invocation-carrier` only in review order —
the carrier is independent.

## Open questions

- Which exposure shape (extend `AXContextSource` vs. a new seam file + adapter): decided
  in the aspect against the AX-family lint's single-file rule.