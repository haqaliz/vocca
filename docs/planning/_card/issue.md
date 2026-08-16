# Issue Card — deterministic-cleanup

> No GitHub issue exists for this unit of work (invoked by slug via `vbf feat deterministic-cleanup`).
> Source of truth is the inline brief below, which comes from the `vocca-next` recommendation
> (handoff prompt) and the repo's own planning docs.

## Brief

Build C5 from `docs/technical/CAPABILITY_ROADMAP.md:114` — the `CleanupProvider` seam with the
deterministic rules implementation (filler removal, sentence segmentation/punctuation,
capitalization, spoken-punctuation commands, number/unit normalization) plus the user dictionary
as readable JSON with ordered, case-sensitive, word-boundary-controlled replacement rules, all
wired into the existing dictation pipeline between ASR and injection with the timeout policy that
yields the raw transcript rather than ever blocking or losing text.

Caveats to respect:

- The P0 gate (`docs/ROADMAP.md:100-104`) is a running calendar gate, not cleared — this is the
  roadmap's own week-5 slot, not a declared P1 start, so the 7-day daily-use log stays in
  parallel.
- The eval harness's held-out set needs the founder's real dictation recordings; the PRD must
  plan for them (TTS stand-ins only until then, with the tolerances marked provisional).
- Zero network in the default configuration must be preserved: the rules implementation is
  local-only by construction, and the zero-network dictation-cycle probe must still pass.

Acceptance tests come first, per the repo's test-first rule (`docs/technical/CAPABILITY_ROADMAP.md:13`):

1. A table-driven raw→clean suite covering each rule class in isolation and in combination.
2. A deliberately hung provider that still results in raw text reaching the injector within the
   timeout.
3. A user-dictionary test asserting declared-order application and no corruption outside a match.
4. The held-out eval harness whose blind pairwise-preference number is what the P1 gate is judged
   on (`docs/ROADMAP.md:137`).

Phase: P1. Layer: AI cleanup (`CleanupProvider`). Scope: macOS-only, local-first, dictation-first,
open-core — no cloud in the OSS core, nothing that cripples the local core.
