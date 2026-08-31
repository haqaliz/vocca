# PRD: speculative-asr

> **Unit:** C7 remainder (P2) — speculative pre-key-up ASR feed, real streaming engine
> adapters, re-warm-after-idle
> **Slug:** `speculative-asr` · **Owner:** aliz · **Date:** 2026-08-31
> **Source:** `docs/planning/_card/issue.md` (inline brief from `vocca-next`).
> **Authority:** `docs/technical/CAPABILITY_ROADMAP.md:171-195` (C7 + amendments),
> `docs/technical/ARCHITECTURE.md` §6/§16 (speculative design, open question 2),
> `docs/ROADMAP.md` P2, `docs/planning/warm-start-streaming/*` (shipped halves).

---

## Problem Statement

The dictation loop's perceived latency is dominated by post-key-up ASR: a 10-second
utterance pays full transcription cost after the key is released (`ARCHITECTURE.md:334` calls
speculative ASR "the whole trick" for the p50 ≤ 400 ms target). C7's shipped halves made the
*mechanism* exist — the streaming route, the widget-only partial sink, the
zero-injection-before-final guard, the latency ledger and benchmark gate, the launch warm
start — but **no production code feeds audio into that route, and no real engine streams**:
`EffectRouter.deliver` still calls the batch `route` (`AppBootstrap.swift:2385`), the
production `partialSink` is `nil` (`AppBootstrap.swift:430-433`), both engines report
`supportsStreaming == false` (`ParakeetEngine.swift:49`, `WhisperCppEngine.swift:55`), and
re-warm-after-idle has no counterpart at all (`DictationEngineResolver.swift:80,99` — sticky
`isPrepared`; engines' second `prepare()` is a no-op). Open question 2 — *final-on-key-up must
equal batch transcription of the same buffer* — has stood unmeasured since C7 shipped
(`ARCHITECTURE.md:695`).

The dig amended two premises the brief could not know:

- **Parakeet's "streaming" is pseudo-streaming.** FluidAudio 0.15.5's
  `SlidingWindowAsrManager` runs an *offline* encoder over overlapping windows
  (`SlidingWindowAsrManager.swift:9-10`; `ParakeetModelVariant.swift:4-9`). Default windows
  (11 s chunk + 2 s context) yield the first partial only after ~13 s of audio — silent for
  typical dictation — and `finish()` is built from heuristic token dedup the SDK itself labels
  "a temporary workaround" (`AsrManager+TokenProcessing.swift:113-114`). No TDT text promises
  final-vs-batch equality.
- **whisper.cpp inverts the risk.** The canonical streaming pattern (repeated `whisper_full` +
  `new_segment_callback`, both in the pinned v1.9.2 header) makes the key-up final equal to a
  batch transcription **by construction**, but the key-up decode is not cheaper and partial
  passes are O(n²).

So this unit ships the whole C7 remainder, but the **latency win is a measurement outcome,
not a design outcome** — the PRD claims mechanism and measurement, never a number CI did not
produce.

## Goals & Success Metrics

1. **Open question 2 is answered, not assumed.** An env-gated real-run harness compares the
   streaming adapter's final (on the fixture suite) against batch transcription of the same
   buffers. The verdict (WER + exact-text equality) is **recorded, never gated** (house
   discipline: `SMOKE_CHECKLIST.md` steps 71–72 precedent). A green CI never implies the
   equivalence holds; a red go/no-go row does not block shipping the feed — it blocks *claiming
   the latency win*.
2. **The production loop streams.** Partials appear in the widget during `.recording` /
   `.transcribing`, zero `TextInjector` calls before the final, for real engines — with the
   permanent guard test still passing (`DictationPipelineStreamingTests.swift:133-159`).
3. **Both engines really stream.** `supportsStreaming == true` on Parakeet (SDK defaults) and
   whisper.cpp (batch-by-construction), with the no-branch doctrine intact
   (`DictationPipelineStreamingTests.swift:358-374`).
4. **Re-warm-after-idle exists.** A 5-minute idle policy re-prepares the engine (disk-only,
   no mic dot), and the first dictation after idle is recorded as its own timing row
   (recorded, not gated).
5. **Nothing regresses.** Zero-network probe green (`ZeroNetworkTests.swift:673`); the closed
   four-span contract intact; test floor (1625) raised by hand in the commit that changes the
   count; no latency number claimed from CI (`STATUS.md:446-447`).

### The unit's success bar (pass/fail, not "recorded, never gated")

| Goal | Pass | Fail |
|------|------|------|
| G1 equivalence measurement | Harness ships, env-gated run executed, verdict row entered (PASS **or** FAIL — the *claim* differs, the unit does not) | Harness missing or unexecutable; verdict not recorded |
| G2 production streaming | Guard green; partials observable in the widget via the real feed + stub engine; every terminal cancels the feed | Guard broken; any terminal orphans the feed |
| G3 real streaming engines | Both engines `supportsStreaming == true` with their contract rows green | Either adapter violates the seam contract |
| G4 re-warm-after-idle | Idle policy ships; re-warm path real; timing row recorded | Policy ships but re-warm is a no-op |
| G5 no regression | Zero-network green; span contract resolved (see Technical Considerations); floor raised | Any invariant broken |

A FAIL verdict on the equivalence measurement is a **successful outcome for this unit** with
the latency claim dropped and the roadmap amendment made (see Risks, Q1) — the go/no-go is
the unit's purpose, not its hazard.

## User Personas & Scenarios

- **The daily dictator** (Vocca ICP): dictates into Slack/Notes/Docs all day, local-first,
  privacy-literal. Scenario: presses ⌥Space, talks for 8 s, watches words scroll in the widget
  as she speaks (Parakeet: after the ~13 s window for longer utterances; whisper: as segments
  complete), releases, and the final lands in the field — the widget partials are visibly
  provisional, never mistaken for delivered text. The 10-second-utterance p50/p95 feel is
  measured on her machine by `VOCCA_LATENCY_BENCH`, not asserted by CI.
- **The interrupted dictator**: presses ⌥Space, is interrupted by a colleague, hits Escape /
  key-up mid-sentence. Nothing injects, the widget shows the failure affordance, the feed
  cancels cleanly, and the transcript invariant (never lost) holds.
- **The coffee-break user**: returns after 10 minutes; the engine re-warmed in the background;
  the first dictation is not the slow one (recorded, not gated).

## Requirements

### Must-have

- **M1 — Equivalence measurement (open question 2, go/no-go).** Env-gated real-run harness
  (`VOCCA_MODEL_DIR`; skip visibly in CI) that transcribes the C2 fixture suite through the
  Parakeet streaming adapter (chunks → final) and through batch `transcribe`, and records
  WER and exact-text equality between the two per fixture. The verdict is a named row in the
  benchmark output and the SMOKE checklist; it **records, never gates**.
- **M2 — Speculative feed producer.** A mid-session chunk producer that observes the session's
  `.recording` state, drains the ring buffer at its own cadence (own constant, in exactly one
  file, single-source scanned), converts hardware-rate samples to 16 kHz mono through a
  chunked `AudioFormatConverter` lifecycle, and emits `AsyncStream<AudioBuffer>` into
  `routeStreaming`. Never touches the realtime thread; never blocks `endCapture`.
- **M3 — Production wiring.** `EffectRouter`: `.started` starts the feed, `.ended` switches to
  `pipeline.routeStreaming`, and **every terminal cancels the feed and its stream** — the full
  set: `.keyUp`, `.toggledOff`, `.ceilingReached`, `.pollDetectedRelease`,
  `.captureUnavailable`, Escape/cancel, and app termination. No terminal may leave a feed
  running (`EndReason.swift:50-123`; `AppBootstrap.swift:2400-2433,2141-2153,2292-2297`).
  The composition root wires a real `PartialTranscriptSink` to the widget store.
- **M4 — Sub-minimum safety.** No partial is presented before the engine's minimum duration
  (Parakeet: FluidAudio's 0.3 s, read live via `isBelowSDKMinimum`); sub-0.3 s sessions still
  terminate `.emptySkip` exactly as today; whisper's behavior below minimum is measured, and
  if it refuses, a measured constant mirrors Parakeet's (reasoning-about-the-C-library is not
  a shipped claim — `WhisperCppEngine.swift:154-169`).
- **M5 — Parakeet streaming adapter.** `SlidingWindowAsrManager` (SDK defaults, founder
  decision 2026-08-31) behind `ASREngine.stream`, `supportsStreaming == true`; seam contract:
  partials then exactly one final; the below-minimum empty answer unchanged; `finish()` maps
  through the existing transcript mapper.
- **M6 — whisper.cpp streaming adapter.** Repeated `whisper_full` on the growing buffer with
  `new_segment_callback` harvesting segments as partials; final = the last full decode (batch
  by construction); `supportsStreaming == true`. New C surface stays inside the seam's one
  file (`WhisperCAPI`), per the H8b one-file-per-seam lint.
- **M7 — Re-warm-after-idle.** A 5-minute idle policy (own constant, one file) that re-invokes
  `prepareIfNeeded()` after the app has been idle (no session, no active prepare); engines
  gain a genuine re-warm path (today a second `prepare()` is a no-op); idle re-warm recorded
  as a new `EngineTiming` row; launch warm-start behavior unchanged and still pinned.

### Should-have

- **S1 — Feed cadence named and pinned** (proposed: 50 ms drain tick, ~10 ms sanctioned ring
  poll; choose one, measure, pin in one file with a single-source scan).
- **S2 — SMOKE_CHECKLIST steps** for the first executions: first real streaming cycle with a
  real engine, first equivalence run, first idle re-warm observation (steps must respect the
  two rules: verify the state was entered; criteria tighter than the failure they guard).
- **S3 — Partial copy pins.** The widget's provisional-partial copy ("…" placeholder before
  the first partial, provisional styling) is verified against `PRODUCT_SPEC.md` expectations
  and pinned, since the product spec has no streaming-partials contract today.

### Nice-to-have

- **N1 — Parakeet window re-tuning** (shorter chunk → partials for sub-13 s dictation).
  Explicitly deferred: it is a measured decision to be made *after* M1 records the default
  config's equivalence, because re-tuning adds stitching boundaries at unknown WER cost.
- **N2 — whisper `whisper_full_with_state` incremental decoding** (real key-up savings).
  Deferred: drift vs batch is unmeasured; batch-by-construction is the shipped guarantee.

## Technical Considerations

- **Phase:** P2 (latency battle). The lowest unshipped phase whose prerequisites are met; C9+
  is guardrail-blocked until the P2 gate (`ROADMAP.md:180`).
- **Layer:** capture + ASR, OSS core, local-only. No egress; audio stays on-device; engines
  stay behind `ASREngine`; no caller branches on engine identity.
- **Ring ownership (the hard decision, made here):** the SPSC warrant on `AudioRingBuffer`
  (`AudioRingBuffer.swift:44,51-58`) forbids a second consumer. The feed **becomes the ring's
  consumer during `.recording`** and `endCapture` drains only the remainder — the alternative
  (a second feed-owned buffer written by the interleaver) adds a realtime-path writer and
  violates the warrant's spirit. This changes `MicrophoneSource`'s drain contract deliberately
  and is the first thing planned; every alternative is named in the plan for review.
- **Cadence:** the feed's tick is its own constant — the watchdog's 150 ms is a hot-mic bound,
  not a feed cadence (`WatchdogPolicy.pollInterval`). Repeating-timer machinery from
  VoccaHotkey is the house shape.
- **Latency instrumentation:** the ASR span already wraps stream consumption
  (`DictationPipeline.swift:211-227`). **Named contract question:** a speculative feed makes
  the ASR span begin pre-key-up; the benchmark gate's closed-span checks and p95-derived
  budgets (`LatencyBenchmarkTests.swift:673-727`) were written for post-key-up spans — the
  plan must resolve what the gate measures with the feed live (deliberate, named change or
  explicit decision that the gate stays post-key-up), never silent drift. The benchmark
  harness gains a streaming variant that writes fixture audio incrementally
  (`BenchmarkHarness.runCycle` precedent, `LatencyBenchmarkTests.swift:523-543`); real numbers
  come from the env-gated run, recorded never gated.
- **Privacy:** the orange-mic-dot policy is untouched — the *audio* engine stays cold when
  idle; only the *model* re-warms (`ARCHITECTURE.md:336-346`). The feed reads only the
  in-session ring.
- **Threading:** realtime thread writes only; feed drains on a timer; `SessionMachine` stays
  decision-free about audio content (`SessionWatchdog.swift:140-145`).
- **Testability:** the feed is headless-testable against `StreamingStubEngine` and a fake
  `CaptureGraphSeam` (the benchmark graph precedent); the adapters' contract rows are
  headless; their accuracy rows are env-gated.

## Risks & Open Questions

| # | Risk / Open question | Tied to | Response |
|---|---------------------|---------|----------|
| Q1 | **Open question 2 unresolved** — does the streaming final equal batch? SDK is silent; dedup is heuristic | M1 | Measurement first, recorded never gated. If the go/no-go fails, the feed ships anyway (widget partials are display value), and the latency *claim* is dropped, not the feature. |
| Q2 | **Parakeet silent < 13 s** — the shipped default produces no partials for typical dictation | M5 | Accepted, founder decision 2026-08-31 (SDK defaults). Widget shows the provisional placeholder; the recorded numbers tell whether a re-tune (N1) is worth it. |
| Q3 | **whisper has never transcribed anything on this machine** (step 19 unexecuted; tolerances seeded) | M6 | The adapter ships on the canonical pattern; short-audio behavior measured, not reasoned; the first real run is a SMOKE step. |
| Q4 | **Ring drain contract change** is the riskiest refactor in the unit | M2 | Planned first, alternatives named, `MicrophoneSource` docs updated in the same commit as the change. |
| Q5 | **Re-warm constant (5 min)** has no precedent; reload cost unmeasured | M7 | Provisional; recorded, not gated; re-baselined by the founder's real run (tolerances procedure). |
| R3 | **Latency ceiling worse than expected** on older Apple Silicon (`ROADMAP.md:302`) | All | p95 is the real number; measured across machines; smaller model tier on constrained machines. |
| R4 | **Dictation parity with FluidVoice/VoiceInk** (`ROADMAP.md:304`) | M2/M5/M6 | No claimed win without the founder's env-gated run; calibration is against incumbents at the P2 gate. |
| R10 | **Solo-founder bandwidth** (`ROADMAP.md:310`) | Unit | Five aspects sequenced with hard order; measurement first, re-tune deferred (N1). |

## Out of Scope

- **VAD / endpointing / EOU** — P3 (`ROADMAP.md:45`); the feed is keyed by the session, never
  by speech boundaries.
- **Streaming into the target app** — partials are widget-only, permanently
  (`ROADMAP.md:162`; the guard test is the enforcement).
- **Claiming a latency number from CI** — numbers come from the founder's env-gated run,
  recorded, re-baselined.
- **Parakeet window re-tuning (N1)** and **whisper stateful incremental (N2)** — deferred,
  measured decisions.
- **Other engines, model tiers, engine switching mid-session** — unchanged.
- **Cloud of any kind** — the OSS core stays local; nothing here is a hosted-tier seam.

## Non-Functional Requirements

- **Privacy:** zero network calls in the default path (permanent release blocker, unchanged);
  audio engine cold when idle (mic dot policy); feed reads only the in-session ring.
- **Reliability:** transcript never lost — every failure path still terminates in the widget
  failsafe; cancellation at every terminal; no orphaned feeds (a started feed is cancelled by
  construction on every `.ended`/terminal row).
- **Performance:** partial cap (`maxPartialCharacters` 200) unchanged; feed tick bounded; the
  feed never blocks the realtime thread or `endCapture`.
- **Testability:** every decision above the seams tested headlessly; env-gated runs skip
  visibly; test floor raised by hand.