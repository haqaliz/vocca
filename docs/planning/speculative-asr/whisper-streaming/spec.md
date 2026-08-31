# Aspect spec: whisper-streaming

**Unit:** speculative-asr (C7 remainder) · **Aspect:** whisper-streaming
**PRD refs:** M6, Q3

## Problem slice and user outcome

The second engine reports `supportsStreaming == false` (`WhisperCppEngine.swift:55`) and its
C surface (`WhisperCAPI`) sets no callbacks at all (`WhisperCAPI.swift:96-110`). The pinned
whisper.cpp v1.9.2 header offers the canonical streaming pattern — repeated `whisper_full` on
the growing buffer with `new_segment_callback` harvesting segments — which makes the key-up
final **equal to a batch transcription by construction** (same params, same audio). Outcome:
whisper genuinely streams behind the seam; partials appear in the widget as segments complete;
the key-up result is batch-equivalent by construction, honestly displayed, and no latency
saving is claimed that the pattern does not deliver.

## In-scope requirements

1. **Adapter behind `ASREngine.stream`.** `supportsStreaming == true`; seam contract: partials
   then exactly one final; `engineIdentity` unchanged.
2. **Repeated-`whisper_full` pattern with `new_segment_callback`.** New C surface lives inside
   the seam's one file (`WhisperCAPI`, H8b one-file-per-seam lint): callback registration,
   segment harvesting into partials (partial text = segments so far), final = the last full
   decode's segments (batch by construction). `whisper_full_with_state` is **not** used (N2,
   deferred — drift unmeasured).
3. **Below-minimum behavior measured, not reasoned.** The engine's comment admits short-audio
   behavior is "reasoning about the C library, not a measurement" (`WhisperCppEngine.swift:154-169`).
   The first real run measures it; if the library refuses, a measured constant mirrors
   Parakeet's guard. Until measured, the adapter's sub-minimum row is documented as unverified
   and the widget's provisional placeholder covers it.
4. **Cost honesty.** Partial passes are O(n²) over the utterance and the key-up final pays the
   full decode — the adapter's doc comment says so; no caller may assume key-up savings.

## Out-of-scope boundaries

- No `whisper_full_with_state` incremental decoding (N2, deferred).
- No equivalence measurement (final ≡ batch by construction; a note in the
  `equivalence-measurement` output says why).
- No WER re-baselining — step 19 (`SMOKE_CHECKLIST.md`) remains the first real run; this
  aspect ships the adapter, not the accuracy claim.

## Acceptance criteria (tests written first)

- Contract rows, headless: scripted segments (through a seam double of the C bridge) yield
  partials-then-one-final; the final equals the batch result for the same audio (the pattern's
  construction); a stream ending mid-utterance terminates the seam stream cleanly.
- The no-branch scan and one-file lint still pass; the bridge seam's shape is unchanged
  outside `WhisperCAPI`.
- The existing batch path's tests still pass untouched (batch `transcribe` is the same
  `whisper_full` path — the adapter must not alter it).
- SMOKE: step 19 first real run now includes a streamed cycle; short-audio behavior recorded
  (measured or explicitly unverified, never assumed).

## Dependencies and sequencing

- Depends on the `WhisperContext` seam (shipped). Independent of `parakeet-streaming` and
  `equivalence-measurement` — parallelizable.
- The production wiring from `speculative-feed` is what makes this adapter observable.

## Open questions / risks

- Q3: no whisper model has ever transcribed on this machine; tolerances are seeded from
  Parakeet's table, not measured (`STATUS.md` settings-live-controls entry). The adapter's
  correctness rows are headless; the accuracy rows are env-gated, and the first real run
  records, never claims.