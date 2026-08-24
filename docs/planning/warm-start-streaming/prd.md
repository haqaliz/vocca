# PRD — Warm start + widget-only streaming (C7 remainder)

Slug: `warm-start-streaming` · Phase: **P2** (latency — make-or-break battle #1,
`ROADMAP.md:150-174`) · Type: `feat` · Branch: `feat/warm-start-streaming/aliz`

## Problem Statement

The loop is measured but not fast, and the C7 seam vocabulary ships unused. The
`latency-instrumentation` unit gave us the spans and the gate (p50 ≤ 400 ms / p95 ≤ 800 ms,
`ProvisionalTolerances`), but none of the *mechanisms* the architecture names exist yet:

- `ASREngine.prepare()` — the warm-start hook (`ARCHITECTURE.md:271`) — runs exactly once at
  launch (`AppBootstrap.swift:857-883`), yet there is no warm-start test, no
  "within 20% of steady-state" assertion, and `EngineTiming` already records
  `.coldLoad` / `.firstAfterLaunch` / `.warmTranscribe` that nothing computes a ratio from.
- The widget shows a live *waveform* while recording (`LiveLevelSource`, level-only) but no
  text. `Transcript.isFinal` exists ("false for streaming partials (C7)") but nothing emits a
  partial. Both engines report `supportsStreaming == false` and nothing calls `stream(_:)`.
- "Zero injection before key-up" is true today only because injection is unreachable before
  key-up by construction — it is not pinned by any test, so a future streaming route could
  silently break it.

The architecture is explicit that speculative ASR is "the whole trick" for the p50 target
(`ARCHITECTURE.md:322`); this unit builds the seam's honest consumer and the guard that keeps
partials out of other people's fields forever (`CAPABILITY_ROADMAP.md:160`).

For whom: the founder running the P2 gate's warm-start metric (`ROADMAP.md:174`), every
dictation user watching the widget, and the release engineer whose regression gate must
actually fail when the loop gets slower.

## Goals & Success Metrics

1. **Warm start (slice 1):** first-dictation-after-launch latency is within **20% of
   steady-state** (`ROADMAP.md:174`), computed from `EngineTiming`
   (`.firstAfterLaunch` vs `.warmTranscribe`). The mechanism is headless-gated in CI over an
   injected clock and stub engines; the real number is recorded on the founder's machine by an
   env-gated run (`VOCCA_LATENCY_BENCH` + `VOCCA_MODEL_DIR`, the WER pattern) and never claimed
   by CI.
2. **Zero regression / zero network:** launch `prepare()` happens exactly once, never on the
   session path, and the zero-network probe's full cycle still makes **zero `connect(2)`**
   (R11, `ROADMAP.md:310`).
3. **Widget-only streaming mechanism (slice 2):** partials (raw, `isFinal == false`) flow to
   the widget surface only; the permanent guard asserts **zero `TextInjector` calls before the
   final transcript** across the closed route set (`CAPABILITY_ROADMAP.md:160`).
4. **Seam honesty:** no caller branches on `supportsStreaming` — a streaming stub yields
   partials then exactly one final through the same route; a batch engine (whisper-shaped)
   degrades to the default and yields one final (`ASREngine.swift:35-38`, the pinned rule).
5. **Guard-the-guard:** the new tests can fail (a gate that cannot fail proves nothing), and
   every new post-condition is asserted as an effect, not a golden string.

## User Personas & Scenarios

- **The founder running the P2 gate:** launches Vocca, dictates immediately, and expects that
  first dictation to feel like the hundredth — the metric is the 20%-of-steady-state ratio,
  printed by the env-gated benchmark beside the suppression state
  (`SMOKE_CHECKLIST.md` steps 71–72).
- **The dictation user:** presses ⌥Space and sees *text* (not just a waveform) while the
  transcript forms — always only in the widget, never in the target app until the final,
  atomic injection (`CAPABILITY_ROADMAP.md:152`).
- **The release engineer:** a future route that injects a partial, or a warm-start regression,
  fails CI with a named span — the regression has an address.

## Requirements

### Must-have — Slice 1 (warm start)

- **W1. Launch preload pinned.** A test asserts the composition root's launch path
  (`startEnginePreparation` / `prepareAndAssemble`) invokes the resolver's `prepareIfNeeded()`
  exactly once, and that a session after launch routes through the already-prepared engine
  with no re-prepare on the session path (`DictationEngineResolver` resolve-once is real).
- **W2. Warm-start ratio measured.** A headless test computes the
  `firstAfterLaunch`-vs-`warmTranscribe` ratio from `EngineTiming` over a stub engine with a
  simulated cold/warm cost split, and asserts the mechanism satisfies the within-20% bound.
- **W3. Real run, recorded not gated.** An env-gated warm-start run
  (`VOCCA_LATENCY_BENCH` + `VOCCA_MODEL_DIR`, visible skip otherwise) prints the real
  first-dictation-vs-steady-state ratio with the process's suppression state beside it; it
  records the number into the tolerances table, never gates a release on CI.
- **W4. Span-contract change is deliberate.** `LatencyBenchmarkGate`'s closed span contract
  (`LatencyBenchmarkTests.swift:514-521`) is extended for the warm-start/streaming spans by a
  named, reviewed change with its own test documenting the new contract — never a silent
  drift. **Named contract:** the gate's record-shape assertion gains an optional
  `.warmStart` span (recorded from `EngineTiming` on the first-after-launch session) and keeps
  the closed four-span set otherwise; a new gate assertion checks the
  `firstAfterLaunch`-vs-`warmTranscribe` ratio rather than absolute latency, so the mechanism
  is judged on the 20% bound, not on a CI-measured millisecond number.
- **W5. Zero network preserved.** Launch `prepare()` is disk-only (models in Application
  Support, `ModelHub.offlineMode = true`); the probe's cycle keeps `prepareCount` observable
  and asserts zero `connect(2)`.

### Must-have — Slice 2 (widget-only streaming mechanism)

- **S1. Pipeline streaming route.** `DictationPipeline` gains a route that consumes
  `engine.stream(chunks)` when the engine streams: partial transcripts (`isFinal == false`)
  are emitted to a widget-only sink; exactly one `isFinal == true` transcript continues through
  cleanup → inject. Batch engines take the default and never touch the sink.
  - **The chunk-source seam is explicit:** the route takes an injected
    `AsyncStream<AudioBuffer>` chunk source. In this unit the source is scripted (test-driven);
    the live mic→chunk feed (speculative start during recording) is the deferred slice
    (`Out of Scope`). This keeps the mechanism buildable and headless-testable now.
  - **No branch on `supportsStreaming`:** the stream-vs-transcribe choice is made once, by an
    injected capability strategy at pipeline construction (the `ASREngine.swift:35-38` rule),
    never by the pipeline reading the engine's flag mid-route.
- **S2. The permanent guard.** A test drives the streaming route over a scripted chunk stream
  and asserts **zero `TextInjector` calls before the final** — the guard that keeps partials
  out of other people's fields permanently (`CAPABILITY_ROADMAP.md:160`). It must be possible
  for this test to fail.
- **S3. Widget partial state.** `WidgetReducerState` gains a bounded `partialText`; a new
  `WidgetAction` carries partials; the projection maps partials into `.recording`/`.transcribing`
  without changing the closed P0 state set. Reduce Motion → static (no live text), the existing
  static-meter rule.
- **S4. Degradation + swap seam tests.** A streaming stub (`supportsStreaming == true`) yields
  partials then one final through the pipeline; the engine-swap test stays green with no caller
  branching on the flag; batch engines yield exactly one final.

### Should-have

- Widget partial copy: a placeholder (e.g. "…") before the first partial, and the partial text
  clearly provisional — never implying finality.
- `SMOKE_CHECKLIST.md` entries: the founder's real warm-start run (first-dictation-after-launch
  ratio) and the streaming visual (partials in widget, none in target app).

### Nice-to-have

- Bounded partial display length (character cap) with a per-tick refresh bound, so the widget
  stays cheap under long dictations.

## Technical Considerations

- **Placement:** seam events/types live in `VoccaCore` (pure stdlib, zero network — the
  `CoreBoundaryTests` rule); widget state/reducer in `VoccaUI`; wiring in `AppBootstrap`.
  No new system-framework names without an H7/H8 seam row.
- **The one consumer that already exists:** `DictationEngineResolver` is resolve-once and
  single-flight (`DictationEngineResolver.swift:50-150`); warm start builds on it, does not
  replace it.
- **Latency budget:** instrumentation and partial emission are off the critical path;
  recording stays amortized O(1) appends.
- **Privacy / local-first:** partials are durations and provisional text only — never
  persisted, never transmitted (R11). Warm model-start lights nothing (`ARCHITECTURE.md:334`);
  the *audio* engine stays cold by design (the orange-dot argument, `ARCHITECTURE.md:324`).
- **Test floor:** `Scripts/test-with-floor.sh` (`MINIMUM_EXECUTED_TESTS`) is raised by hand in
  the commit that changes the count.

## Feasibility & Slicing

- **Slice 1 (warm start) — small.** The launch `prepare()` already runs
  (`AppBootstrap.swift:857-883`); the work is a pin test (W1), a ratio gate (W2, W4), and the
  env-gated recording run (W3). Mostly new tests over existing machinery; low risk.
- **Slice 2 (widget-only streaming mechanism) — medium.** New: the pipeline streaming route +
  chunk-source seam + capability strategy (S1), the widget partial state/action/projection
  (S3), and three test surfaces (S2 guard, S4 degradation/swap). No real-engine work; all
  headless and zero-network. The deferred live feed keeps the real-engine risk out.
- **Not in this unit (each needs its own decision):** real streaming Parakeet adapter,
  speculative pre-key-up feed, re-warm-after-idle policy.

## Risks & Open Questions

- **Open question 2 (`ARCHITECTURE.md:630`) — deferred, not assumed.** Speculative
  final-vs-batch equivalence is unmeasured. This unit builds the mechanism and the guard over
  stubs; the **real streaming Parakeet adapter** is out of scope and gated on the founder's
  measurement. No latency number is claimed from CI.
- **The `LatencyBenchmarkGate` span contract is closed** (exactly
  `[captureClose, asr, inject]`, `cleanup` forbidden). Extending it is a deliberate, reviewed
  contract change (W4) — flagging so planning is not surprised.
- **Re-warm-after-idle** has no code counterpart (`isPrepared` is sticky-true) and needs an
  idle policy; deferred out of this unit.
- **The recorded p50/p95 budget is post-key-up only** in today's ledger; speculative timing
  (pre-key-up ASR) is the deferred feed slice, so this unit must not be read as proving the
  architecture's speculative budget.
- **The live capture→chunk feed** (speculative start during recording) is the later slice;
  this unit's streaming route is fed by a scripted source in tests.

## Out of Scope

- Real streaming Parakeet (or whisper) adapters (`supportsStreaming == true` implementations).
- Speculative ASR start-before-key-up (capture-side chunk feed).
- Re-warm-after-idle and any idle policy.
- C8 (injection matrix + strategy memory), the settings surface, C9+.
- Any claim of a measured latency number CI did not produce.
