# C3 understanding note — second ASR engine (whisper.cpp)

> Phase 2 output, 2026-08-09. Synthesized from three parallel dig agents: shipped-code
> surface map, planning-doc digest, and whisper.cpp integration research.

## What the work really is

C3 ships a **second, real implementation of the shipped `ASREngine` seam**: whisper.cpp
large-v3-turbo behind a thin C bridge. It is the capability that *proves* the seam —
guardrail 7 ("every seam ships with two implementations") and R5's structural hedge
(`ROADMAP.md:304`). It is a P0 week-2 milestone brick: "Both engines transcribe the same
fixture; swapping requires no caller change" (`ROADMAP.md:83`).

## What already exists to build on (shipped, master)

- `ASREngine` protocol + `AudioBuffer`/`Transcript`/`EngineIdentity`/`VoccaError` in
  `Sources/VoccaCore/`. Batch `stream` default means C3 implements only
  `identity/supportsStreaming/prepare/transcribe`. `EngineIdentity.id` for C3 is already
  pinned by doc comment: `"whisper-large-v3-turbo"` (`EngineIdentity.swift:28`).
- `ModelStore`/`ModelDownloader`/`ModelManifest`/`ModelTransport` in `VoccaASR/Models/` —
  **fully engine-agnostic**, reusable as-is for a single-file GGUF (flat layout,
  `sdkDirectory: nil`). Needs: a checked-in manifest with real SHA-256/byteCount, and a
  provisioning-script generalization (currently hardcoded to Parakeet).
- Lints that will govern the new files: H8 (one file names `URLSession`), H8b (one file
  names the FluidAudio family), H7 per-seam one-file tables, module boundaries
  (`VoccaASR` imports only `VoccaCore`), Apache-2.0 headers everywhere, test-floor
  ratchets. A new seam lint is needed for the whisper C-ABI family.

## Integration path (research verdict)

- **No upstream SPM source package.** The official SPM path is the **XCFramework binary
  target** (`whisper-v1.9.2-xcframework.zip`, 51 MB, checksum-pinned, Metal-embedded via
  `GGML_METAL_EMBED_LIBRARY`, links Accelerate+Metal+Foundation, arm64+x86_64 macOS).
  Alternatives: community `exPHAT/SwiftWhisper` (source build), or `WhisperKit`
  (argmax-oss-swift, CoreML port — a different engine, macOS 14+).
- **C API batch flow** needs no callbacks: `whisper_init_from_file_with_params` →
  `whisper_full` → `whisper_full_n_segments`/`get_segment_text`. 16 kHz float mono —
  matches `AudioBuffer.interchangeSampleRate`. Swift 6 shape: `actor` holding the
  `OpaquePointer` (the ParakeetEngine precedent), C pointers confined to one isolation
  domain.
- **Models**: HF `ggerganov/whisper.cpp` (the official download script's host);
  `ggml-large-v3-turbo.bin` 1.5 GiB (multilingual), `-q5_0` 547 MiB as the constrained
  tier. Docs publish **SHA-1**; SHA-256 must be computed at provisioning time. Weights
  license needs confirmation before distribution; whisper.cpp/ggml are MIT (Apache-2.0
  compatible with attribution).
- **CI**: hosted macOS runners have no GPU → ggml falls back to CPU (supported mode);
  building works on macOS-latest. Real-engine inference on a runner unproven — same
  shape as the pending F1 verdict; env-gated runs are the default plan.

## Decisions the PRD must make (flagged, not papered over)

1. **Integration path** — recommend official XCFramework binary target: pinned checksum,
   Metal embedded, matches "thin C bridge", no vendored source to maintain. (Alternative:
   source build; rejected-on-merit: no upstream recipe, build time in CI.)
2. **Settings tension** — `ROADMAP.md:74` ("No settings UI beyond permissions and one
   hotkey") vs the engine picker requirement. Resolve: a minimal picker row in the
   existing Speech tab (`PRODUCT_SPEC.md:189-196`, exact copy given), download triggered
   via the shipped `ModelDownloadSession` seam; the full model registry (disk used /
   remove / re-download) remains C14's.
3. **WER tolerance ownership** — per-engine tolerance tables, parameterized harness
   returns per-fixture WER; provisional numbers (TTS stand-ins), founder recordings (F2)
   set them later "in exactly one place". C3's real-engine run env-gated.
4. **Model tiers** — large-v3-turbo default tier + q5_0 constrained tier (per-engine
   model-tier choice, `CAPABILITY_ROADMAP.md:79`).
5. **One-file-per-seam for the C family** — the bridge file lives in `VoccaASR/Whisper/`
   (matching the CGEvent/keystroke precedent) with an H8b-style seam lint; the
   `VoccaBridge` module from `ARCHITECTURE.md:40` is not needed and would violate the
   current module-boundary lint.

## Open questions for the interview

- Q1: Integration path preference (XCFramework vs source) — recommendation above.
- Q2: GGUF tier set + default (which quantization ships as default in P0?).
- Q3: How much picker surface in C3 vs C14 (recommendation above).
- Q4: Provisioning: SHA-256 provenance (compute during provisioning; who signs off).
- Q5: Weights license confirmation for distribution.
