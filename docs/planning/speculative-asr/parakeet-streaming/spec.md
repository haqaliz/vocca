# Aspect spec: parakeet-streaming

**Unit:** speculative-asr (C7 remainder) · **Aspect:** parakeet-streaming
**PRD refs:** M5, Q1, Q2

## Problem slice and user outcome

Parakeet is the default engine and reports `supportsStreaming == false`
(`ParakeetEngine.swift:49`). FluidAudio 0.15.5 exposes `SlidingWindowAsrManager` — a public
actor with `streamAudio(_:)`, `transcriptionUpdates`, `finish()` — for exactly the shipped TDT
model, but it is **pseudo-streaming** (offline encoder, overlapping windows;
`SlidingWindowAsrManager.swift:9-10`, `ParakeetModelVariant.swift:4-9`) with SDK-default
windows that yield the first partial only after ~13 s of audio. Outcome: Parakeet genuinely
streams behind the seam, partials are honest (silent below the window), and the adapter is
the measurement vehicle for open question 2 (the `equivalence-measurement` aspect).

## In-scope requirements

1. **Adapter behind `ASREngine.stream`.** `supportsStreaming == true`; seam contract: partials
   (`isFinal == false`) then exactly one final (`isFinal == true`); the below-minimum empty
   answer unchanged (`isBelowSDKMinimum`, `ParakeetEngine.swift:116-119,187-191`); `finish()`
   mapped through the existing `ParakeetTranscriptMapper`; `engineIdentity` attribution
   unchanged.
2. **SDK defaults only** (founder decision 2026-08-31): `SlidingWindowAsrConfig.default` as
   shipped — no window re-tuning in this unit. The `transcriptionUpdates` stream is consumed
   with `isConfirmed`/volatile semantics preserved (volatile partials are still partials; only
   the final carries `isFinal == true`).
3. **Model loading path survives.** `loadModels(_:)` accepts the same `ModelStore`-shaped
   models the batch path loads; warm `prepare()` semantics unchanged (still one load, still
   disk-only).
4. **Seam discipline.** New SDK names stay inside `ParakeetEngine.swift` (the H8b one-file-per-
   seam lint); no caller branches on `supportsStreaming`; the batch default in the seam's
   extension is untouched.

## Out-of-scope boundaries

- No window re-tuning (N1 — deferred, measured decision).
- No equivalence measurement here (own aspect, consumes this adapter).
- No change to the batch `transcribe` path or its WER contracts.
- No EOU/VAD work (P3).

## Acceptance criteria (tests written first)

- Contract rows, headless: the adapter's stream yields partials-then-one-final for a scripted
  chunk sequence; a stream that ends without `finish()` terminates the seam stream cleanly;
  a sub-minimum buffer answers empty without throwing (seam contract, `ASREngine.swift:28-37`).
- The no-branch scan and one-file lint still pass.
- The fixture WER runners (`ParakeetEngineWERTests`, env-gated on `VOCCA_MODEL_DIR`) still
  pass — batch path untouched.
- Env-gated: the adapter transcribes the `clean` fixture streamed (chunks) with
  `finish()`-final text non-empty; the first real execution is a SMOKE step (Q3 discipline —
  nothing claimed that CI produced).

## Dependencies and sequencing

- Depends on `ASREngine`/`Transcript` (shipped). Feeds `equivalence-measurement`.
- Can land before or after `speculative-feed` (feed tests use stub engines); the production
  wiring in `speculative-feed` is what makes this adapter observable.

## Open questions / risks

- **Q1 (open question 2):** the SDK is silent on final-vs-batch equality; dedup is heuristic
  (`AsrManager+TokenProcessing.swift:113-114`). This aspect only *builds the vehicle*; the
  verdict belongs to `equivalence-measurement`. The adapter must not be claimed correct until
  then.
- **Q2:** SDK-default windows are silent for sub-13 s dictation — accepted (founder decision),
  and the widget's provisional placeholder is the honest surface.
- Whisper-tier parity: `EngineTier.storageID` keying (`settings-live-controls` amendment)
  must be respected if model loading differs per tier.