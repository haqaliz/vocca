# Spec: system-synthesizer

> Aspect of `kokoro-voice-output` (PRD G2/G5/G6/G7, R3/R5/R6/R7, S1, N1). Compiles against
> the `speech-seam` aspect.

## Problem slice

The seam's first real implementation: `SystemSynthesizer` (macOS `AVSpeechSynthesizer`
rendering PCM buffers), the env-gated real half of the parameterized suite, the TTFA
benchmark, and the deliberate lint amendments the new AVFAudio surface requires. **Kokoro is
the recorded follow-on unit** (runtime decision per `ARCHITECTURE.md:706`, ranked with the
phonemizer named); this aspect's record states the two-implementation doctrine's interim
state honestly.

## In scope

- **R3 (SystemSynthesizer):** `Sources/VoccaSpeech/System/SystemSynthesizer.swift` —
  `AVSpeechSynthesizer.write(_:toBufferCallback:)`, **one `AVSpeechUtterance` per sentence
  chunk** (the chunker's sentences from `speech-seam`), converting each `AVAudioPCMBuffer` to
  an `AudioChunk` (rate/channels from the buffer format, duration = frames ÷ rate). The
  `write` callback → `AsyncThrowingStream<AudioChunk, Error>` bridge lives in this file.
  `identity` = `engineID: "system"`, `voiceName` = the chosen system voice's identifier.
  `cancel()` = `stopSpeaking(at: .immediate)` + stream termination + safe immediate re-invoke.
  Voice + rate are plain data inputs (N1 — knobs for the follow-on UI). Zero network by
  construction.
- **R5 (TTFA benchmark, env-gated, recorded):** the time-to-first-chunk harness over
  `SystemSynthesizer`; recorded as **SMOKE step 126** (the next number after the current
  highest, step 125); the ≤300 ms P3 budget is a **recorded measurement, never a CI gate**
  (ratified).
- **R4-real (the suite's real half):** the parameterized body from `speech-seam` runs over
  `SystemSynthesizer` behind the env gate (`VOCCA_RUN_REAL_SPEECH=1`, the C3 real-engine
  pattern): pinned duration floor, ordering, cancel ≤50 ms, re-invoke.
- **R6 (probe):** the zero-network probe's placeholder witness for `VoccaSpeech` is replaced
  with real driven work (construct `SystemSynthesizer`, run an empty-speak + cancel — the
  module's default-configuration surface); the module-coverage cross-check must pass.
- **R7 (lints, deliberate amendments):**
  - `ModuleBoundaryTests.swift`: `VoccaSpeech` moves `leafModules` → `adapterModules`
    (may import `VoccaCore`, no other Vocca module) — the reviewed move with its positive
    control.
  - `AudioFormatConverterTests.swift` (the AVFoundation expected-import set): the set gains
    `VoccaSpeech/System/SystemSynthesizer.swift`.
  - The one-file seam-family row: AVSpeechSynthesizer/AVFAudio names confined to
    `VoccaSpeech/System/SystemSynthesizer.swift` (the Parakeet/whisper seam-test doctrine).
- **S1 (record):** the follow-on card for the Kokoro binding is written into the STATUS
  record: the runtime options ranked per `ARCHITECTURE.md:706` (C/C++ shim via the reserved
  `VoccaBridge`; ONNX/CoreML on the ANE; bundled MLX) with the phonemizer dependency
  (espeak-ng) named as the hidden cost of every option.

## Out of scope

- No Kokoro binding, no playback/ducking (C10), no UI, no P3 gate claims.

## Acceptance criteria (test-first)

1. RED: the adapter's tests fail against the seam-only tree (no `SystemSynthesizer`); the
   lint amendments are RED as reviewed edits (the module-boundary test fails on the leaf
   classification before the move; the AVFoundation set-equality fails before the amendment).
2. GREEN: the adapter's headless half (buffer → chunk conversion over constructed
   `AVAudioPCMBuffer`s; chunker→utterance mapping; cancel/stream termination over a
   minimal real invocation where the environment allows) passes; the env-gated real suite
   passes with the gate on; the lint amendments pass; the probe's module coverage passes;
   the full suite holds floor 1949.
3. The TTFA benchmark's recorded row lands in SMOKE_CHECKLIST as step 126 with the measured
   number and the recorded-never-gated note.

## Dependencies & sequencing

- After `speech-seam`. The env-gated real suite needs a machine with system voices (the
  founder's machine — CI skips the gate, the C3 precedent).

## Open questions / risks

- **AVSpeechSynthesizer rendering behavior is unmeasured here** (first-buffer latency, voice
  availability, `write` semantics under `stopSpeaking`): the env-gated suite + the TTFA
  benchmark are the measurement; a found blocker is fixed test-first or recorded (the PRD's
  posture — if TTFA lands over the 300 ms budget, the number is recorded and the Kokoro
  binding owns the budget; a warm-the-renderer mitigation is a recorded option, not this
  unit's promise).
- The `write(toBufferCallback:)` bridge's cancellation path must not deadlock the stream —
  pinned headlessly where the environment allows, env-gated otherwise.