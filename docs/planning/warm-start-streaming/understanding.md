# Understanding — warm-start-streaming (C7 remainder)

**Placement:** P2 (latency — the make-or-break UX battle #1), `CAPABILITY_ROADMAP.md:150-165`,
`ROADMAP.md:169-174`. Local-only OSS core: the model stays on the machine, no span is ever
transmitted (R11, `ROADMAP.md:310`). Follow-on slice of the shipped `latency-instrumentation`
unit (PR #3).

## What the work is really asking

The C7 seam vocabulary already shipped, unused: `ASREngine` has `prepare()` (the warm-start
hook), `supportsStreaming`, and `stream(_:)` with a batch default; `Transcript.isFinal`
already means "false for streaming partials"; `EngineTiming` already splits
`.coldLoad`/`.firstAfterLaunch`/`.warmTranscribe`; `DictationEngineResolver` is resolve-once,
single-flight, readiness-gated; the latency ledger + `LatencyBenchmarkGate` (p50 ≤ 400 ms /
p95 ≤ 800 ms in `ProvisionalTolerances`) exist with a seeded-slow regression gate. Nothing
streams; no warm-start claim is measured.

Two independent gaps remain, per the brief:

1. **Warm start** — `prepareIfNeeded()` runs exactly once at launch
   (`AppBootstrap.swift:857-883`); there is no "within 20% of steady-state" test or gate, no
   re-warm-after-idle hook, and `isPrepared` is sticky-true forever.
2. **Widget-only streaming partials** — the capture path has no mid-session chunk channel;
   `DictationPipeline` receives one final buffer at key-up and never calls `stream`; the
   widget has zero partial-text state (`WidgetReducerState` carries no text, `LiveLevelSource`
   is level-only); both engines report `supportsStreaming == false`; and "zero injection calls
   before key-up" is only *trivially* true today (injection happens post-key-up by
   construction) — it needs a guard + test that pins it.

## Affected areas

- `VoccaCore/ASREngine.swift` (seam), `VoccaCore/DictationPipeline.swift`,
  `VoccaCore/DictationEngineResolver.swift`, `VoccaCore/WidgetProjection.swift` (projection +
  `LiveLevelSource`), `VoccaCore/LatencyLedger.swift` + `SessionRecord.swift`.
- `VoccaBootstrap/AppBootstrap.swift` (composition root: `startEnginePreparation`,
  `prepareAndAssemble`, the pipeline assembly).
- `VoccaUI/WidgetStateReducer.swift` + `WidgetStateStore.swift` (partial-text state, a new
  action).
- `VoccaASR/Parakeet/ParakeetEngine.swift` + `Whisper/WhisperCppEngine.swift` (streaming
  capability, only if we touch real engines).
- `Tests/HarnessTests/`: `LatencyBenchmarkTests.swift` (span contract + `ProvisionalTolerances`),
  `DictationPipelineTests.swift`, `DictationEngineResolverTests.swift`, `WidgetStateReducerTests.swift`,
  `ASREngineSeamTests.swift`, `EngineSwapTests.swift`, `ZeroNetworkTests.swift` (probe), and
  `Scripts/test-with-floor.sh` (test floor, raised by hand in the commit that changes the count).

## Contradictions / cautions surfaced (flagged, not papered over)

- **The benchmark gate's span contract is closed** — `LatencyBenchmarkGate` requires exactly
  `[.captureClose, .asr, .inject]` with `cleanup` forbidden (`LatencyBenchmarkTests.swift:514-521`).
  Adding warm-start/streaming spans is a deliberate contract change, to be planned explicitly.
- **The recorded budget is post-key-up only.** `ARCHITECTURE.md:310,315,322` frames speculative
  ASR as the p50 mechanism (≤250 ms ASR finalize on the *tail*), but the shipped loop
  transcribes only after key-up (`DictationPipeline.swift:215`) — so the 400/800 ms numbers as
  recorded are a post-key-up budget, not the architecture's speculative budget. We must not
  claim a speculative latency win we didn't measure.
- **`ARCHITECTURE.md:630` open question 2** — speculative final-vs-batch equivalence is
  unmeasured: "the latency win is bought with accuracy" if final-on-key-up ≠ batch. The brief's
  caveat holds: the streaming slice claims the widget guard and the record, never a latency
  number CI didn't produce.
- **"Parakeet streams" is net-new adapter work, not a config flip.** `CAPABILITY_ROADMAP.md:162`
  expects Parakeet to stream and whisper to batch, but the shipped `ParakeetEngine` is
  batch-only behind FluidAudio (`supportsStreaming == false`,
  `ParakeetEngine.swift:49`). Building a real streaming Parakeet adapter is the riskiest,
  least-CI-measurable part and directly hits open question 2.
- **"Pre-warmed after idle" has no counterpart in code.** The resolver has no idle concept;
  re-warm-after-idle is a design decision (what is "idle"? how long? does a warm model hold a
  device? — `ARCHITECTURE.md:334` says model warm-start lights nothing, which frees us, but the
  trigger policy is ours to define).

## Scoping stance for the PRD

- **Slice 1 — warm start** is fully buildable and headless-testable: launch preload +
  re-warm-after-idle policy + the 20%-of-steady-state gate computed from `EngineTiming`
  (`.firstAfterLaunch` vs `.warmTranscribe`), over an injected clock and stub engines.
- **Slice 2 — widget-only streaming** builds the *mechanism* and pins the guard: a
  partial-transcript channel through the pipeline (widget-only), partial state in the widget
  reducer, the permanent "zero injection before key-up" test, and the
  no-caller-branches-on-`supportsStreaming` degradation test over a stub streaming engine.
  The **real streaming Parakeet adapter** is the known-hard, unmeasurable part (open question
  2) — scope it as its own slice/decision gated on the founder's measurement, not silently
  folded into "make it stream."

## Open questions for the interview

1. Does "re-warm after idle" ship in slice 1 (needs an idle policy + a second prepare hook) or
   is launch-only preload the first slice?
2. Is the real streaming Parakeet adapter in this unit (with its correctness risk) or deferred
   to a later slice gated on founder measurement, leaving this unit to the mechanism + guard?
3. Does the streaming partial channel carry raw (unclean) partials only, and is the widget's
   partial display capped (length / rate) for the reduce-motion and perf constraints?
4. What happens to the partial state on Esc during TRANSCRIBING (cancel path) — cleared, never
   injected (already the rule), shown?
