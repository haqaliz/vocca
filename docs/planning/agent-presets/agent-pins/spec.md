# Aspect spec: agent-pins

> Source: `docs/planning/agent-presets/prd.md` R5 · Date 2026-10-01.

## Problem slice and user outcome

The invariant half: the composed default must stay byte-identical in its promises —
`agents=0 spawnsSubprocess=false` — while the catalog, detection and editor land, and
the lints must stay untouched. User outcome: the release blocker ("the default
configuration spawns no child") survives the authoring slice unweakened.

## In-scope requirements

- **The PROBE-CODING-AGENT post-condition is unchanged** — the drive, its expected
  lifecycle constant and the guard-the-guard stay verbatim; a test asserts the line still
  reads `agents=0 spawnsSubprocess=false` with the new files in the tree (the 
  default-configuration test already proves it — this aspect makes the non-change
  deliberate and recorded).
- **Round-trip pin**: write a row via the editor's save path → the registry's own load
  reads it back (the authoring aspect's acceptance 1 — asserted here again through the
  *composed* wiring: `listAgents` renders the saved row, enablement default off).
- **Lint immobility**: the transport prohibition permitted set stays exactly two files;
  the FileManager seam table stays exactly eight seams; Family A/B unchanged; the
  `policy:` no-default call sites unchanged.
- **G5 verification**: the dictation digests (`SessionMachine`, `DictationPipeline`)
  unchanged across the whole unit — asserted after the authoring REFACTOR.
- **The catalog/detection do nothing by themselves**: no file written, no spawn, no
  network — a probe-style assertion that constructing the catalog and running detection
  over a recording seam produces zero side effects beyond the existence checks.

## Out-of-scope

- Any new probe drive (none needed — the post-condition is unchanged); anything the
  other aspects already test (this aspect's pins are the cross-cutting re-assertions).

## Acceptance criteria (test-first)

1. The PROBE-CODING-AGENT line is verbatim-unchanged with the unit's files in the tree.
2. A saved row renders through the composed `listAgents` with enablement default off.
3. The transport permitted set is still exactly two; the FileManager seams still exactly
   eight; Family A/B unchanged.
4. The dictation digests are unchanged; the `AppBootstrap` digest is the authoring
   REFACTOR's re-anchored value.
5. Catalog construction + detection over a recording seam write nothing, spawn nothing,
   and check exactly the expected paths.

## Dependencies / sequencing

After `agent-authoring` (needs the composed wiring + the re-anchored digest). Before
`agent-record`.

## Open questions

- None.