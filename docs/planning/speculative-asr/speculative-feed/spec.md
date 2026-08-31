# Aspect spec: speculative-feed

**Unit:** speculative-asr (C7 remainder) · **Aspect:** speculative-feed
**PRD refs:** M2, M3, M4, S1, S3

## Problem slice and user outcome

The streaming route exists but nothing feeds it in production: `EffectRouter.deliver` calls
the batch `route` (`AppBootstrap.swift:2385`), the production `partialSink` is `nil`
(`AppBootstrap.swift:430-433`), and the ring buffer's SPSC warrant forbids the mid-session
second consumer a feed would be (`AudioRingBuffer.swift:51-58`). Outcome: with a streaming
engine installed, words scroll in the widget while the user talks, the final lands on key-up,
and nothing else changes.

## In-scope requirements

1. **Ring-drain chunk producer** — a new object that (a) is told the session started (key-down
   → `.recording`) and ended (key-up / every terminal), (b) drains the ring at its own cadence
   while recording, (c) converts hardware-rate samples to 16 kHz mono via a chunked
   `AudioFormatConverter` lifecycle (today the converter is reset per session in
   `MicrophoneSource.beginCapture` and finished once at `endCapture`
   — `MicrophoneSource.swift:190,234`), (d) emits `AsyncStream<AudioBuffer>` into
   `routeStreaming`. Never touches the realtime thread; never allocates/locks in a drain tick
   beyond the ring's own read.
2. **Ring ownership change, deliberate and documented.** The feed becomes the ring's consumer
   during `.recording`; `MicrophoneSource.endCapture` drains only the remainder. The SPSC
   warrant comment and `MicrophoneSource`'s contract docs change in the same commit; the
   alternative (second feed-owned buffer written by the interleaver) is named and rejected in
   the plan with the warrant quoted.
3. **Router wiring.** `EffectRouter`: `.started`/`.opening` starts the feed; `.ended`
   (`AppBootstrap.swift:2361-2399`) switches `pipeline.route(.ended(...))` (:2385) to
   `pipeline.routeStreaming(chunks:target:sessionID:)`; `.captureUnavailable` and Escape/cancel
   (`AppBootstrap.swift:2400-2433,2141-2153,2292-2297`) cancel the feed and terminate the
   chunk stream; the production `pipelineAssembly` wires a real `PartialTranscriptSink` to the
   widget store.
4. **Sub-minimum suppression.** No partial is presented while the accumulated buffer is below
   the engine's minimum duration; Parakeet's threshold read live via `isBelowSDKMinimum`
   (`ParakeetEngine.swift:116-119`); a sub-0.3 s whole session still ends `.emptySkip`
   (`DictationPipeline.swift:345-348`) exactly as today.
5. **Cadence constant.** The feed's tick lives in exactly one file, single-source scanned
   (proposal: 50 ms; the ring doc sanctions ~10 ms consumer polls, `AudioRingBuffer.swift:27-31`
   — pick one value, measure the drain-tick cost, pin it).
6. **Partial copy pins (S3).** The widget's provisional-partial presentation (placeholder
   before the first partial, `partialText` in `.recording`/`.transcribing`, cleared on every
   adoption, never into DELIVERED — `WidgetStateReducer.swift:245,284,291`) is verified against
   `PRODUCT_SPEC.md` and pinned by test, since the product spec has no streaming-partials
   contract today.

## Out-of-scope boundaries

- No real engine changes here — the feed is tested against `StreamingStubEngine`
  (`ASRTestDoubles.swift:126-239`).
- No change to the no-branch doctrine, the closed four-span contract, or the guard test.
- No VAD/speech boundaries — the feed is session-keyed only.
- No Parakeet/whisper adapter work (own aspects).

## Acceptance criteria (tests written first)

- The guard test still passes: **zero `TextInjector` calls before the final** on the production
  wiring (ledger injector double, `DictationPipelineStreamingTests.swift:133-159` precedent).
- A feed test with a scripted growing buffer asserts: partials appear in the widget store
  during `.recording`, exactly one final on key-up, the final's text equals the batch result
  for the same audio (via the stub engine), and the widget shows no empty partials before the
  sub-minimum threshold.
- Cancellation rows: Escape mid-session and `.captureUnavailable` both cancel the feed, the
  chunk stream terminates, `.aborted` is finalized, and the injector is never touched after
  cancellation.
- `endCapture` with a feed that consumed part of the ring: the remainder is drained exactly
  once, the converted buffer's `missingSampleCount` bookkeeping is unchanged in meaning, and
  the SPSC comment and `MicrophoneSource` docs are updated in the same commit.
- No-branch scan still passes (`DictationPipelineStreamingTests.swift:358-374`); the
  zero-network probe still delivers a streaming cycle with zero `connect(2)`
  (`ZeroNetworkTests.swift:673`).
- Test floor raised by hand in the commit that changes the count.

## Dependencies and sequencing

- Depends on the shipped streaming route, `PartialTranscriptSink`, `StreamingStubEngine`,
  benchmark-graph precedent — all shipped.
- First aspect in the unit: everything here is headless-testable; the adapters (next) slot in
  without touching this aspect's code paths.

## Open questions / risks

- The ring-drain contract change is the riskiest refactor in the unit (PRD Q4) — planned
  first, alternatives named in the plan.
- Feed cadence value is a proposal until measured (S1).
- Cancellation race: a terminal arriving mid-drain-tick must not strand a chunk; the plan
  must pin the ordering (the watchdog's `wake()` → `machine.tick()` ordering precedent,
  `SessionWatchdog.swift:312-401`).