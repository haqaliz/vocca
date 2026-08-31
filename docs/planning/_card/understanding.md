# Understanding: feat/speculative-asr

**Date:** 2026-08-31 · **Phase:** P2 (capability C7, unshipped remainder)
**Source:** `docs/planning/_card/issue.md` (inline brief from `vocca-next`)

> Written after a three-agent dig over the streaming pipeline, the resolved SDK surfaces
> (FluidAudio 0.15.5 checked out in the primary's `.build/`; whisper.cpp v1.9.2 XCFramework
> header), and the primary's uncommitted `docs/STATUS.md` / `CLAUDE.md`. Every claim below
> carries a file:line. Two premises of the original brief were **substantially amended** by
> the SDK findings and are recorded here.

---

## 1. What the work is really asking

Close the last unshipped half of C7 (`docs/technical/CAPABILITY_ROADMAP.md:187-195`): the
**speculative pre-key-up ASR feed** (begin ASR on the growing buffer while the user still
speaks, finalize on key-up, partials widget-only), the **real `supportsStreaming == true`
engine adapters** (Parakeet streams; whisper.cpp batches), and **re-warm-after-idle** — plus,
before anything, the **open-question-2 measurement** (`ARCHITECTURE.md:695`: final-on-key-up
must equal batch transcription of the same buffer, "or the latency win is bought with
accuracy"). That measurement is a go/no-go the brief names first.

## 2. What already exists (all verified in the worktree's sources)

- `ASREngine.stream(_:)` + batch default, `supportsStreaming`, no-branch doctrine pinned by
  test (`Sources/VoccaCore/ASREngine.swift:42-110`; `DictationPipelineStreamingTests.swift:358-374`).
- `DictationPipeline.routeStreaming` consumes `stream` unconditionally, partials → widget only,
  permanent zero-injection-before-final guard test (`Sources/VoccaCore/DictationPipeline.swift:207-255`;
  `DictationPipelineStreamingTests.swift:133-159`).
- **The production composition never uses it**: `EffectRouter.deliver` calls the batch
  `pipeline.route(.ended(...))` (`AppBootstrap.swift:2385`); `partialSink` is wired `nil`
  (`AppBootstrap.swift:430-433`); the only streaming composition is the zero-network probe
  (`StreamingCycleDrive.swift:394`).
- Warm start: `WarmStartTargets` 1.2 bound, `WarmStartRatio` evaluator, launch-preload pinned
  (`Sources/VoccaCore/WarmStartRatio.swift:25-29`; `WarmStartLaunchTests.swift:172,237`). **No
  re-warm path exists**: engines' `prepare()` is a no-op after first load (`ParakeetEngine.swift:142`,
  `WhisperCppEngine.swift:119`), resolver `isPrepared` is sticky (`DictationEngineResolver.swift:80,99`).
- Latency: closed four-span record, `LatencyLedger`, benchmark gate with `ProvisionalTolerances`
  (p50 400 ms / p95 800 ms), env-gated real run that records, never gates (`LatencyBenchmarkTests.swift:603-608,673-727`;
  `LatencyBenchmarkRealEngineTests.swift`).
- Short-press guard: `ParakeetEngine.isBelowSDKMinimum` reads FluidAudio's 0.3 s live
  (`ParakeetEngine.swift:116-119`; SDK `ASRConstants.swift:15,67-69`); sub-minimum sessions
  answer empty → `.emptySkip` (`DictationPipeline.swift:345-348`).

## 3. What the dig found that the brief could not know (the amendments)

**(A) The Parakeet streaming adapter is implementable — but the SDK's own design guts the
latency premise for typical dictation.** FluidAudio 0.15.5 exposes `SlidingWindowAsrManager`
(public actor, `streamAudio(_:)` / `transcriptionUpdates` / `finish()`), explicitly *not* a
cache-aware streaming architecture — TDT uses an offline encoder with overlapping windows
(`SlidingWindowAsrManager.swift:9-10` header; `ParakeetModelVariant.swift:4-9`). Default
config: 11 s chunk + 2 s left + 2 s right, **first partial after ~13 s of audio**, one per
~11 s; `hypothesisChunkSeconds` is dead config; the 15 s input cap constrains re-tuning
(`SlidingWindowAsrManager.swift:710-853,358`). Sub-13 s utterances (most dictation) get
**zero partials** and key-up still pays a full window decode. Partials are `volatile` until
10 s context + confidence threshold (`:552-576,856-895`). **Open question 2 is not answered
by the SDK**: `finish()` is built from heuristic token dedup, self-labeled "a temporary
workaround" (`AsrManager+TokenProcessing.swift:113-114`); no TDT text promises final-vs-batch
equality — only the different-model Unified engine does.

**(B) whisper.cpp inverts the risk.** The canonical pattern (repeated `whisper_full` on the
growing buffer + `new_segment_callback`, both present in the pinned v1.9.2 header) makes the
key-up final **equal to a batch transcription by construction** — the strongest possible
answer to open question 2 — but the key-up decode is *not* cheaper and partial passes are
O(n²). Stateful `whisper_full_with_state` could change that, on an unmeasured drift basis.
And no whisper model has ever transcribed on this machine (`SMOKE_CHECKLIST.md` step 19).

**(C) The hardest ownership question is the ring buffer, not the engines.** The SPSC warrant
on `AudioRingBuffer` (`@unchecked Sendable`, `AudioRingBuffer.swift:44,51-58`) forbids a
second consumer while `MicrophoneSource.endCapture` drains (`MicrophoneSource.swift:211-249`).
A mid-session feed is a second consumer by definition. Options: feed becomes the consumer
during `.recording` (endCapture drains only the remainder — changes a load-bearing contract),
a second feed-owned buffer written by the interleaver, or a documented hand-off. Must be
decided before code, and the realtime thread must never be touched by the feed.

**(D) The two decision points have clear homes.** Start-feeding belongs beside
`EffectRouter.deliver`'s `.opening`/`.started` (only production code that knows "a session
began" with sessionID + pipeline + widget store; `AppBootstrap.swift:2335-2360`); finalize is
`.ended` (`:2361-2399`), which must switch to `routeStreaming`; every other terminal
(`.captureUnavailable`, Escape) must cancel the feed. The machine/watchdog are deliberately
content-blind and must stay that way (`SessionWatchdog.swift:140-145`). Feed cadence is its
own constant (ring doc sanctions ~10 ms consumer polls, `AudioRingBuffer.swift:27-31` — not
the watchdog's 150 ms).

## 4. Scope placement

- **Phase:** P2 (ROADMAP's latency battle; the C7 amendment's unshipped remainder). P2 is the
  next unshipped phase; C9+ is guardrail-blocked until the P2 gate (`ROADMAP.md:180`).
- **Layer:** capture + ASR. Local-only OSS core; no egress; engines stay behind `ASREngine`;
  no engine identity reaches callers. Zero-network invariant untouched.
- **Privacy:** the feed reads only the in-session ring; nothing leaves the machine; the
  orange-mic-dot policy (engine cold when idle) is untouched (`ARCHITECTURE.md:336-346`).

## 5. Ambiguities and open questions carried into the PRD

1. **Parakeet window config:** ship the adapter on SDK defaults (honest: silent < 13 s) or
   re-tune (shorter chunk → partials for short dictation, more heuristic stitching, WER
   cost)? The 15 s cap constrains the knob. — founder decision, asked in interview.
2. **The p50 claim:** the architecture's "only the tail is unprocessed" premise
   (`ARCHITECTURE.md:334`) is unmeasurable for Parakeet sub-13 s and false for whisper
   (full re-decode at key-up). The unit ships mechanism + measurement; numbers are recorded
   and re-baseline, never gated (house discipline). The PRD must not claim a win the SDK
   structure precludes.
3. **Re-warm-after-idle threshold** is a product constant with no precedent; propose a value,
   flag for founder.
4. **Feed cadence / chunk size** for the ring drain: own constant, measured not assumed.
5. **Ring ownership decision (C above)** — engineering decision, made in PRD with the
   trade-offs named.

## 6. Contradictions surfaced (flag, don't paper over)

- `ROADMAP.md:42` claims Parakeet "ships with streaming + EOU we need in P3" — both engines
  report `supportsStreaming == false`; the adapter is net-new work, and the streaming it would
  ship is pseudo-streaming, not the cache-aware kind P3's EOU path implies.
- `CLAUDE.md:15,19` (primary, uncommitted) says "last aspects landed 2026-08-15" / "836 tests"
  while `STATUS.md:848-849` records 2026-08-30 units at floor 1625 — the front-door copy is
  stale; STATUS.md is authoritative.
- `PRODUCT_SPEC.md` has no streaming-partials contract; the widget partial behavior exists
  only in the warm-start-streaming PRD and implementation (`STATUS.md:434-437`).
- The shipped ledger records a post-key-up budget only; a green benchmark today would not
  prove the architecture's speculative claim (`STATUS.md:446-447`).