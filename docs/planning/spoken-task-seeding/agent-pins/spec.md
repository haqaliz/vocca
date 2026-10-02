# Aspect spec: agent-pins

> Source: `docs/planning/spoken-task-seeding/prd.md` R5 · Date 2026-10-01.

## Problem slice and user outcome

The invariant half: the composed default's promises, the lints, the driver's compile
pins and the digests survive the carrier and the threading — deliberately, as tests.
User outcome: the release blocker ("the default configuration spawns no child") holds
with spoken-task seeding composed.

## In-scope requirements

- **The composed default unchanged**: `PROBE-CODING-AGENT` still reads
  `agents=0 spawnsSubprocess=false` (verbatim, with the new files in the tree).
- **Lint immobility**: the transport permitted set still exactly two; the FileManager
  seams still exactly eight; Family A/B unchanged; the `policy:` no-default call sites
  unchanged; the driver's seam-boundary compile pins green (the widened signature is a
  deliberate pin update, not a widening).
- **Digests**: the dictation digests unchanged; the `AppBootstrap` digest equals the
  threading REFACTOR's re-anchored value (or is unchanged if `AppBootstrap` was never
  touched — assert the honest alternative).
- **Zero-network**: the interposer tests unchanged and green (the substitution happens
  only in the provider over an invocation field — no new call).
- **Module coverage**: unchanged (a field + wiring, no new module files — verify).

## Out-of-scope

- Any new probe drive (the post-condition is unchanged); anything the other aspects
  already test (the pins are the cross-cutting re-assertions).

## Acceptance criteria (test-first)

1. The PROBE-CODING-AGENT line is verbatim-unchanged with the unit's files in the tree.
2. The lint pins hold (extracted from the lint suites' own literals, the non-vacuous
   extractor pattern).
3. The dictation digests are unchanged; the `AppBootstrap` digest is the REFACTOR's
   value (or unchanged — assert the actual).
4. The driver's compile pins green.
5. The zero-network default-configuration test passes.

## Dependencies / sequencing

After `utterance-threading`. Before `agent-record`.

## Open questions

- None.