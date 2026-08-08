# Aspect spec — `parakeet-engine`

Parent PRD: [`../prd.md`](../prd.md) · Capability C2 · Phase P0
Depends on: `asr-seam` Phases 1–2 (committed); `model-downloader` (committed)
Unblocked — no `audio-capture` dependency (the completeness-bridge gating is `asr-seam` Phase 3's,
and it does not block this aspect)

---

## Problem slice

The seam exists as code and the downloader exists as code; **nothing transcribes**. This
aspect ships the first real `ASREngine` implementation — Parakeet TDT 0.6B v3 via FluidAudio
— behind the seam, wired to the store, with the model lifecycle's last two links: load-once
residency and the structural offline guarantee (`ModelHub.offlineMode`).

It is also the first aspect with **three things CI cannot reach**: the FluidAudio SDK's own
behaviour, the CoreML model, and (probably) the adapter's hold on the SDK's non-Sendable
manager object. The aspect's discipline is therefore the tap-adapter precedent, stated
plainly: **every decision is extracted above the FluidAudio line and tested; the adapter
file itself is thin glue that CI never executes.** The F1 spike (Phase 0) decides whether
even the *real-model* tests can run on a hosted runner — the stop/go the PRD's F1 demands.

**User outcome:** the first time the words appear. With the store, the downloader, and this
engine wired, a first-run user gets: model downloads (verified, resumable) → loads → holds
`⌥Space` → text in the widget. That is the second trust transaction the PRD names.

**Why it is the third aspect:** it consumes `ModelStore.baseURL` + the verified-marker
guarantee (`model-downloader`), implements the protocol (`asr-seam`), and its spike
generates the manifest content and the first fixture that `fixture-suite` formalises.

---

## What this aspect inherits — decided, do not relitigate

| # | Constraint | Where it came from |
|---|---|---|
| 1 | **FluidAudio is Apache-2.0, SPM `from: "0.12.4"`** — the repo's first external dependency; product `FluidAudio`. Batch API: `AsrModels.downloadAndLoad(version: .v3)` / manual `AsrModels.load(from:configuration:)`, `AsrManager(config: .default)` + `loadModels(_:)` + `transcribe(samples)` where samples are "16 kHz, already converted". | Verified 2026-08-09 against the README; PRD §5 |
| 2 | **`ModelHub.offlineMode = true`** — FluidAudio's own download path throws `DownloadError.networkDisabled` instead of egressing. Set at engine init, before any loader runs. Vocca downloads through its own `ModelDownloader`; FluidAudio never fetches. | PRD M6; the SDK's offline flag |
| 3 | **Models load manually from the Vocca-managed directory** — `AsrModels.load(from: ModelStore.baseURL(for:version:))` — never from FluidAudio's cache (`~/.cache/fluidaudio/Models/`). | PRD M6; the `ARCHITECTURE.md:489-490` layout |
| 4 | **The FluidAudio seam lint (H8b): exactly one file in `Sources/` may name FluidAudio identifiers.** The H7/H8 pattern applied to the SDK. | PRD M6/M14; the H7 precedent |
| 5 | **`VoccaASR` becomes an adapter** — moves `leafModules` → `adapterModules` with `dependencies: [VoccaCore]` (+ FluidAudio), the move the module-boundary lint exists to make a reviewed edit. The actor row `ARCHITECTURE.md:36` already names `VoccaASR` as an actor module. | `ModuleBoundaryTests`; PRD M5 |
| 6 | **The engine is an actor; transcription never runs on the main actor.** | `ARCHITECTURE.md:36`, I6 |
| 7 | **Warm load-once at C2; launch preload is C7's.** The C2 sentence "first dictation after launch is not the slow one" (`CAPABILITY_ROADMAP.md:58`) is unsatisfiable by load-once and is **amended in that document**. | PRD M7; the amendment is this aspect's docs task |
| 8 | **Every decision above the FluidAudio line.** The adapter file contains glue; the mapping rules, the load-state logic and the timing live in pure, headless, testable types. The adapter is "executed by nothing in CI" — stated, not hidden. | The H7/H8 lesson; the tap-adapter precedent (`CLAUDE.md`) |
| 9 | **The empty-buffer policy and attribution are already pinned at the seam** (`asr-seam`); the engine inherits them, it does not re-litigate them. | `ASREngineSeamTests` |
| 10 | **The F1 spike precedes the design finalisation.** If the SDK answers differ from the provisional shape here (Sendability of `AsrManager`, the exact `transcribe` result fields, whether `ModelHub.offlineMode` is readable), the adapter adapts, the seam does not, and the difference is recorded. | PRD F1, C2-B |

---

## In scope

- **The F1 spike (Phase 0):** a scratch probe (a `Tools/` package depending on FluidAudio, the
  `EngineStartProbe` pattern), run on a **macos-15 hosted runner** via a temporary
  `workflow_dispatch` workflow: does FluidAudio build under `-strict-concurrency=complete`?
  does the Parakeet model download/load on a VM (no ANE)? how long — build, download, load,
  transcribe of one 10 s fixture? memory? Output: recorded numbers + a **stop/go decision**
  on the CI-gated real-model suite (PRD F1); the SMOKE_CHECKLIST fallback is the documented
  no-go. The spike also generates the first manifest content and the first fixture (the F2
  task's beginning: the founder records one 10 s clip).
- **The testable core** (headless, no FluidAudio names):
  - `ParakeetTranscriptMapper` — the pure mapping: `text` + buffer + engine identity +
    missing samples → `Transcript` (single segment, `audioDuration` from the buffer, empty
    text → valid empty transcript, `missingSampleCount` carried). All decisions, primitives
    in, `Transcript` out.
  - `ParakeetLoadState` — the pure load-once logic: has-loaded flag, attempt counting,
    load completion; idempotence ("second `prepare` does not reload") testable without a
    manager.
  - `EngineTiming` — the local-only timing recorder (PRD S1): cold-load, warm transcribe,
    first-after-launch, over an injected `MonotonicClock`; readable, never transmitted.
  - The identity constant: `EngineIdentity(id: "parakeet-tdt-0.6b-v3", displayName:
    "Parakeet TDT 0.6B v3", isLocal: true)`.
- **The adapter** (`Sources/VoccaASR/Parakeet/ParakeetEngine.swift` — **the one FluidAudio
  file**): the actor conforming to `ASREngine`; sets `ModelHub.offlineMode = true` at init;
  `prepare()` = idempotent manual load from `store.baseURL` through an injected loader seam
  (default: the real `AsrModels.load` call); `transcribe` = ensure-prepared → samples →
  `manager.transcribe` → `ParakeetTranscriptMapper`; records timing through `EngineTiming`;
  holds the SDK manager (Sendability resolution is the spike's finding, constraint 10).
- **The wiring and lints:**
  - `Package.swift`: `.package(url: FluidAudio, from: "0.12.4")`, `VoccaASR` gains
    `VoccaCore` + `FluidAudio`.
  - `ModuleBoundaryTests`: `VoccaASR` moves leaf → adapter (the reviewed edit the lint
    demands); the package-manifest coverage guard updated to match.
  - The H8b lint test: exactly one file may name the FluidAudio identifier family
    (`AsrManager`, `AsrModels`, `ModelHub`, `FluidAudio`…), with the planted-detection
    negative control.
- **Docs amendments (reviewer: aliz):** `CAPABILITY_ROADMAP.md:58` warm-start wording;
  `ARCHITECTURE.md` §2/§5 if the adapter-row or seam table drifted; a SMOKE_CHECKLIST step:
  first real transcription with **airplane mode on** (the C2 acceptance's offline clause at
  the smoke level), via the default transport + store on founder hardware.

## Out of scope

- **The bridge** (`refusedSampleCount` → `AudioBuffer` → `Transcript.missingSampleCount`) —
  `asr-seam` Phase 3, gated on the `audio-capture` merge. The engine maps the buffer's own
  `missingSampleCount` (0 until the field exists); the wiring is the bridge's.
- **The fixture suite, WER scorer, CI model cache, the interposer run** — `fixture-suite`.
- **whisper.cpp, the engine picker settings, model tiers** — C3.
- **Streaming / partials** — C7; `supportsStreaming == false`.
- **The download UI** — `download-ui`. The engine surfaces `VoccaError.modelUnavailable`
  with an honest reason; surfacing is the UI's.
- **ITN, cleanup, any egress, any telemetry.**

---

## Acceptance criteria (tests written first)

1. **Mapper.** Known text + buffer + identity → `Transcript` with the identity, one segment
   covering the whole utterance, `audioDuration` from the buffer, `missingSampleCount`
   carried; empty text → valid empty transcript (`text == ""`, one empty segment, no throw);
   the near-miss: wrong identity is structurally impossible (`Transcript.engine` non-optional,
   the seam's compile-time pin).
2. **Load state.** `prepare` twice loads once; a failed load does not mark loaded (the next
   `prepare` retries); attempt counting is exact.
3. **Timing.** `EngineTiming` records cold-load / warm-transcribe / first-after-launch over
   the injected clock; values read back exactly; nothing is transmitted (a type-level claim:
   no network names anywhere near it — the H8b lint covers the tree).
4. **Identity.** The constant carries the three fields with `isLocal == true` (no egress
   badge, `ARCHITECTURE.md:152-156`).
5. **Module discipline.** `VoccaASR` imports `VoccaCore` (and FluidAudio) and no other Vocca
   module; the leaf→adapter move is a reviewed, tested edit; `Package.swift` pins
   `from: "0.12.4"`.
6. **H8b lint.** Exactly one file in `Sources/` names the FluidAudio family; the negative
   control catches a planted identifier; the permitted file actually names it (no vacuous
   green, both directions).
7. **Offline flag.** The engine's init sets `ModelHub.offlineMode = true` — asserted if the
   SDK makes it readable (spike finding), else the SMOKE step carries it (constraint 10's
   honest fallback).
8. **Spike decision.** `docs/planning/local-asr/parakeet-engine/spike_20260809.md` records
   the runner numbers and the stop/go for the CI-gated real-model suite (PRD F1, C2-A).

---

## Dependencies and sequencing

- **Phase 0 (spike) is first and is the schedule risk** (PRD F1). Everything after it
  adapts to its findings; the testable core (Phase 1) is written against the provisional
  shapes and adjusted if the SDK differs.
- Phases 1–3 are **unblocked** (no `audio-capture` dependency). The adapter (Phase 2) is
  written to compile; its real execution is founder-hardware/smoke territory.
- `fixture-suite` follows: it consumes the spike's fixture + manifest and the engine's
  existence.

---

## Open questions / risks

- **`AsrManager` Sendability** — holding it in an actor under `-strict-concurrency=complete`
  may need a documented wrapper; the spike answers it (C2-B).
- **The exact batch-result shape** — segment/confidence fields, or text only; the mapper is
  written against `text` (the README's quick start shows `result.text`); richer fields are
  C7's.
- **`ModelHub.offlineMode` readability** — if not readable, the "asserted" half of
  acceptance 7 becomes a smoke step, stated honestly.
- **Build-time cost** — FluidAudio in the headless job's build; the spike measures it
  against the 20-minute budget.
- **The spike's model download on a runner** — ~2 GB against the 20-minute job; the spike
  measures download speed on a runner, not just locally.
