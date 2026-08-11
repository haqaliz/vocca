# whisper-engine — spec

> Aspect of `second-asr-engine` (C3). PRD: `docs/planning/second-asr-engine/prd.md`
> (M1, M3, M5, M7-swap-half).

## Problem slice

The second real `ASREngine` implementation: `WhisperCppEngine`, a Swift 6 actor over the
whisper.cpp C API via exactly one bridge file, matching the shipped contract exactly
(attribution, empty buffer, attributable errors, load-once prepare) and confined by a new
seam lint.

## In-scope

- `Sources/VoccaASR/Whisper/WhisperCAPI.swift` — the **one file** permitted to name the
  whisper C-ABI family (`whisper_*`, `WHISPER_*`, `import whisper`). Pure translation:
  context init from a model path with parameters, `whisper_full`, segment reads,
  `whisper_free`. No decisions.
- `WhisperCppEngine.swift` — actor conforming to `ASREngine`
  (`identity = EngineIdentity(id: "whisper-large-v3-turbo", displayName: "Whisper
  turbo", isLocal: true)`, `supportsStreaming = false`, `prepare()` load-once idempotent
  via the injected `ModelStore`/manifest/transport, `transcribe` with empty-buffer
  early return).
- Headless decision files, Parakeet-shaped: `WhisperCppEngineIdentity.swift`,
  `WhisperLoadState.swift`, `WhisperTranscriptMapper.swift` (C segments → `Transcript`,
  per-segment ranges + confidence where the API exposes it).
- H8b-style seam lint (`WhisperSeamTests`): two-sided — the permitted file must name the
  family; no other file in `Sources/` may; no laundering routes (no typealias, no
  `@_exported`, no extension of the module's types under a local protocol).
- Unit tests mirroring `ParakeetCoreTests` + contract tests (attribution,
  empty-buffer-valid, attributable errors, prepare idempotence).
- `ARCHITECTURE.md` amendment: the `VoccaBridge` module (`ARCHITECTURE.md:40`) is **not**
  introduced; the one-file bridge lives in `VoccaASR/Whisper/` (the H7/H8b precedent);
  `VoccaBridge` stays reserved for a second C-ABI consumer (e.g. C9's Kokoro).

## Out-of-scope

- Real-model WER runs — the `fixture-harness` aspect owns the env-gated test.
- Model manifests/provisioning — the `model-lifecycle` aspect.
- The picker UI — the `engine-picker` aspect.
- Streaming (C7), `initial_prompt` plumbing (N1), `whisper_full_parallel` (N2).

## Acceptance criteria (test-first)

1. `WhisperCppEngine` satisfies `ASREngine` with zero call-site changes above the seam
   (the protocol conformance itself is the compile-time proof; a stub-swap test at the
   seam shows only `engineIdentity` differs).
2. Every returned `Transcript.engine == identity` (I1); empty buffer → valid empty
   transcript, never an error; missing model → `VoccaError.modelUnavailable(identity,
   reason:)`; inference failure → `transcriptionFailed(identity, underlying:)`.
3. `prepare()` is idempotent and load-once; transcription never runs on the main actor;
   Swift 6 strict concurrency clean (any warning fails CI).
4. The seam lint passes two-sided (permitted file names the family; nothing else does).
5. The engine makes zero transport/network calls during `transcribe` (H8 untouched; the
   engine only ever calls the injected store).

## Dependencies / sequencing

After `bridge-integration`. Parallel-safe with `model-lifecycle` and `engine-picker`.
`WhisperTranscriptMapper` is buildable and testable before the C API exists — it takes
abstract segment data (decided: mapper input is a headless `[WhisperSegment]` value type,
produced by the bridge).

## Open questions

- None blocking. Segment confidence: the C API exposes log-probability per token
  (`whisper_full_get_token_p`) — decide at implementation whether to surface it as
  segment confidence or nil; PRD allows nil ("engine exposes none").
