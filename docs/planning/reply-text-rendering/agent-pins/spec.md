# Aspect spec: agent-pins

> Source: `docs/planning/reply-text-rendering/prd.md` R6 · Date 2026-10-01.

## Problem slice and user outcome

The invariant half: the composed default's promises, the lints, the digests and the
widget-family pins survive the carrier, the state amendment and the bubble —
deliberately, as tests.

## In-scope requirements

- **The composed default unchanged**: `PROBE-CODING-AGENT` still reads
  `agents=0 spawnsSubprocess=false` (verbatim, with the unit's files in the tree).
- **Lint immobility**: the transport permitted set still exactly two; the FileManager
  seams still exactly eight; Family A/B unchanged; the `ConversePhase` family confined
  to `WidgetProjection.swift`; the M4a no-remember scans green; the token suites green.
- **Digests**: the dictation digests unchanged; the `AppBootstrap` digest equals the
  carrier REFACTOR's re-anchored value.
- **Zero-network**: the interposer tests unchanged and green.
- **Module coverage**: unchanged (VoccaUI/VoccaBootstrap files — covered; verify).

## Out-of-scope

- Any new probe drive; anything the other aspects already test.

## Acceptance criteria (test-first)

1. The PROBE-CODING-AGENT line is verbatim-unchanged with the unit's files in the tree.
2. The lint pins hold (the non-vacuous extractor pattern).
3. The dictation digests unchanged; `AppBootstrap` equals the REFACTOR's value.
4. The module-coverage cross-check green.
5. The zero-network default-configuration test passes.

## Dependencies / sequencing

After `reply-view`. Before `agent-record`.

## Open questions

- None.