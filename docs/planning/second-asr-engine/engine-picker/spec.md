# engine-picker — spec

> Aspect of `second-asr-engine` (C3). PRD: `docs/planning/second-asr-engine/prd.md`
> (M8, S2).

## Problem slice

The minimum settings surface that makes the engine "switchable in settings without
restart" (`CAPABILITY_ROADMAP.md:78`) with honest tradeoff copy — a Core-owned selection
value plus a minimal Speech-tab picker, resolving the C2-deferred settings tension
(`local-asr/prd.md:315-316`) without pulling C14's registry UI forward.

## In-scope

- **Core-owned selection** (`Sources/VoccaCore/EngineSelection.swift`): a value type +
  pure decision function — candidate engines (seeded: Parakeet v3 default, Whisper
  turbo), per-engine model tiers (whisper: `turbo` / `q5_0`), default, and the
  selection/tier mutation rules (e.g. a tier is only valid for its engine). Headless and
  table-tested — the picker's state reducer consumes it.
- **Speech-tab picker row** (`Sources/VoccaUI/`): minimal settings window/panel hosting
  the Speech tab — the two radio rows with the exact copy from
  `PRODUCT_SPEC.md:189-196` ("Parakeet v3 — Fastest. 25 European languages. [installed]"
  / "Whisper turbo — Slower, broader language coverage. [download]"), per-engine
  installed state from the store (`isPresent`), and the download affordance wired to the
  shipped Core-owned `ModelDownloadSession` seam (reusing `StoreModelDownloadSession` +
  `DownloadProgressView`). Whisper-tier menu (S2): turbo full / q5_0.
- A headless picker state reducer (the `FailsafeStateReducerTests` pattern): selection
  change, tier change, download lifecycle (idle/downloading/committed/failed), with the
  never-auto-switch rule: changing selection never happens implicitly.
- Honest copy only: no latency/accuracy numbers invented (S1 posture).

## Out-of-scope

- Model registry UI (disk used, remove, re-download) — C14
  (`download-ui/spec.md:54`).
- Auto-updating models (`PRODUCT_SPEC.md:273`).
- Settings persistence beyond the engine selection + tier (hotkey rebinding, etc. —
  other units).
- Per-mode engine choice (C11).

## Acceptance criteria (test-first)

1. `EngineSelection` decision table tests: default is Parakeet; tier choice is
   engine-scoped; no invalid (engine, tier) combination is representable.
2. Picker reducer tests: switching engine/tier transitions the state; download
   transitions through the `ModelDownloadSession` vocabulary (progress/committed/
   failed/cancelled); selection is never auto-changed by a download event.
3. The picker row renders the exact `PRODUCT_SPEC.md:189-196` copy (a snapshot/contract
   test on the copy constants — they are the honest-tradeoff surface).
4. Switching engines requires no restart (the selection is read at session start; a
   test asserts a session begun after a selection change uses the new engine).

## Dependencies / sequencing

Needs `EngineSelection` in Core (self-contained) and `model-lifecycle`'s manifests for
installed-state; independent of `whisper-engine` internals. UI code is executed by
nothing in CI (window-server precedent) — all decisions are in the headless reducer.

## Open questions

- There is no settings window in the product yet (C1's widget is minimal). This aspect
  scaffolds the minimal panel hosting the Speech tab; the full settings window is a
  later unit. Flag if the founder wants the window deferred — the reducer + selection
  ship regardless.
