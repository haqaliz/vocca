# Aspect spec: agent-pins

> Source: `docs/planning/agent-auth-baseline/prd.md` R5 · Date 2026-10-01.

## Problem slice and user outcome

The invariant half: the composed default's promises, the lints and the digests survive
the baseline field, the provider parameters and the wiring — deliberately, as tests.
User outcome: the release blocker ("the default configuration spawns no child") holds
with HOME wired.

## In-scope requirements

- **The composed default unchanged**: `PROBE-CODING-AGENT` still reads
  `agents=0 spawnsSubprocess=false` (verbatim, with the unit's files in the tree).
- **Lint immobility**: the transport permitted set still exactly two; the FileManager
  seams still exactly eight; Family A/B unchanged; the `policy:` no-default call sites
  unchanged; the module-coverage cross-check green (no new module files).
- **Digests**: the dictation digests unchanged; the `AppBootstrap` digest equals the
  wiring REFACTOR's re-anchored value.
- **Zero-network**: the interposer tests unchanged and green (the baseline is a value
  merged into the environment of a child the default never spawns).

## Out-of-scope

- Any new probe drive (the post-condition is unchanged); anything the other aspects
  already test.

## Acceptance criteria (test-first)

1. The PROBE-CODING-AGENT line is verbatim-unchanged with the unit's files in the tree.
2. The lint pins hold (the non-vacuous extractor pattern).
3. The dictation digests unchanged; `AppBootstrap` equals the REFACTOR's value.
4. The module-coverage cross-check green.
5. The zero-network default-configuration test passes.

## Dependencies / sequencing

After `wiring-baseline`. Before `agent-record`.

## Open questions

- None.