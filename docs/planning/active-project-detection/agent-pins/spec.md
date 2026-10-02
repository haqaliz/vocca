# Aspect spec: agent-pins

> Source: `docs/planning/active-project-detection/prd.md` R5 · Date 2026-10-01.

## Problem slice and user outcome

The invariant half: the composed default's promises, the lints and the module-coverage
cross-check survive the new VoccaContext file, the invocation field and the wiring —
deliberately, as tests. User outcome: the release blocker ("the default configuration
spawns no child") holds with detection composed.

## In-scope requirements

- **The composed default unchanged**: `PROBE-CODING-AGENT` still reads
  `agents=0 spawnsSubprocess=false` (the existing line + guard-the-guard — asserted
  verbatim with the new files in the tree).
- **Module coverage**: the new `VoccaContext` file is in a covered module (the
  cross-check is module-granular — the drive's witnesses already cover VoccaContext
  via `AccessibilityContext`; verify, and if a witness is needed, add it to the probe's
  placeholders list — a reviewed edit).
- **Lint immobility**: the transport permitted set still exactly two; the FileManager
  seams still exactly eight; the AX family still confined to `AXContextSource.swift`;
  Family A/B unchanged; the `policy:` no-default call sites unchanged.
- **Digests**: the dictation digests unchanged; the `AppBootstrap` digest equals the
  wiring REFACTOR's re-anchored value.
- **Zero-network**: `proc_pidinfo` is not a network call — the interposer tests
  unchanged and green (the new read happens only at arm time over the injected closure;
  the probe's default run never calls it).

## Out-of-scope

- Any new probe drive (the post-condition is unchanged); anything the other aspects
  already test (this aspect's pins are the cross-cutting re-assertions).

## Acceptance criteria (test-first)

1. The PROBE-CODING-AGENT line is verbatim-unchanged with the unit's files in the tree.
2. The module-coverage cross-check is green (every module driven; the new file's module
   covered).
3. The transport/FileManager/AX/Family A-B lints and the `policy:` scan are unchanged.
4. The dictation digests are unchanged; `AppBootstrap` is the REFACTOR's re-anchored
   value.
5. The zero-network default-configuration test passes with the new read in the tree
   (the interposer never sees a call from it).

## Dependencies / sequencing

After `agent-wiring-cwd`. Before `agent-record`.

## Open questions

- None.