# PRD — Latency instrumentation (C7 first slice)

Slug: `latency-instrumentation` · Phase: **P2 by capability tag, P0-completing** (this slice
is the unshipped half of P0 week-4 milestone 7, `docs/ROADMAP.md:86`) · Type: `feat`.

## Problem Statement

P0's week-4 milestone promises "Failsafe + **telemetry-free instrumentation** — Widget retains
last transcript with ⌘C; **local-only latency/success counters**" (`docs/ROADMAP.md:86`). The
failsafe half shipped with C4 and the dictation-loop unit; the counters did not. Today:

- The loop's latency is **unmeasured**: `EngineTiming` exists but is read by nothing
  (`Sources/VoccaASR/Parakeet/EngineTiming.swift:20-22`), whisper owns a clock wired to
  nothing (`Sources/VoccaASR/Whisper/WhisperCppEngine.swift:67-68`), and the capture graph's
  numbers live in prose comments only.
- P0's own success metric — "latency: measured and recorded, but not yet a gate"
  (`ROADMAP.md:98`) — is unmet, so the P0 decision gate cannot be honestly evaluated.
- Risk R3 ("Latency ceiling is worse than expected", `ROADMAP.md:302`) has no measurement to
  retire it, and a regression has no address: nothing fails when the loop gets slower.
- `ARCHITECTURE.md:589` already names the missing deliverable: a **benchmark harness** that
  replays fixtures, asserts p50/p95, and fails CI on regression.

For whom: the founder running the P0 gate and every future release; the honest-scope claim
("latency is a product feature with a number", `ROADMAP.md:29`) cannot be true without it.

## Goals & Success Metrics

1. **Every session produces one complete record** — spans + outcome — on every exit path
   (delivered, held, aborted, failed). Zero records missing on any route.
2. **Zero network**: a measured dictation cycle makes no `connect(2)` (asserted by the
   zero-network probe — the permanent release blocker extends to instrumentation: no span is
   ever transmitted, R11 `ROADMAP.md:310`).
3. **User-inspectable, headless**: a pure snapshot/describe API over the in-memory ledger;
   a headless path (probe output + tests) proves inspection. UI surface deferred.
4. **Benchmark harness with a regression gate**: CI runs a headless fixture-replay benchmark
   that fails the build on regression; the real p50 ≤ 400 ms / p95 ≤ 800 ms numbers
   (`ROADMAP.md:171`) are produced by an env-gated run on the founder's machine (the
   `VOCCA_MODEL_DIR` WER precedent), never claimed by CI.
5. **The P0 latency metric becomes recordable**: capture/ASR/inject spans and per-session
   outcomes let the P0 gate's "measured and recorded" criterion be answered from real runs.

## User Personas & Scenarios

- **The founder running the P0 gate**: dictates for the 7-day gate; wants to know the loop's
  p50/p95 and where time goes, without any telemetry leaving the machine.
- **The release engineer (founder, later contributors)**: CI fails on a latency regression
  and the failure names its span.
- **The skeptical user of a local-first tool**: can inspect that nothing is recorded outside
  the machine — the ledger is in-memory and local by construction.
- **The whisper/Parakeet switcher**: engine attribution of ASR spans is unambiguous, so the
  two engines' numbers are comparable from the same counter.

## Requirements

### Must-have

- **Span vocabulary (VoccaCore)**: named spans — capture-close, ASR, cleanup, inject — each a
  monotonic elapsed over an injected clock (the `MonotonicClock` precedent). Cleanup exists
  as vocabulary with a **not-present** state (C5 is unbuilt and phase-gated; the ledger never
  fabricates a 0 or a fake duration). Pure stdlib types: no Foundation/Dispatch/Darwin in
  `VoccaCore` (the `CoreBoundaryTests` rule).
- **Per-session records**: one record per session with the route taken, the spans, and the
  outcome — as **distinct outcome classes** (delivered-by-rung, failsafe-held, aborted,
  failed/transcription-failed, empty-skip), never force-labeled success. The P0
  first-method-success metric is *derived* from the record, not stored.
- **The ledger**: a Core-owned, in-memory, local-only store that engines/injector/pipeline
  record into through seams (nothing below it can transmit: it imports nothing).
- **Complete coverage**: records are written on every route out of `DictationPipeline`
  (`Sources/VoccaCore/DictationPipeline.swift`: route cases cancelled / empty / failed /
  held / delivered) — the acceptance test enumerates the closed set of routes and asserts one
  record each.
- **Whisper parity**: wire whisper's owned clock so its ASR spans record like Parakeet's
  (`EngineTiming` kinds coldLoad / warmTranscribe / firstAfterLaunch).
- **Injection span**: reuse the already-measured `InjectionResult.elapsed`
  (`Sources/VoccaCore/InjectionResult.swift:41`) as the inject span, with the rung and
  verification state from the same result.
- **Headless inspection**: a pure `describe()`/snapshot API over the ledger, exercised by the
  zero-network probe and by tests.
- **Zero-network assertion**: the probe's measured cycle asserts no `connect(2)` while a
  record is produced (extend `PROBE-CYCLE`).
- **Benchmark harness + regression gate (CI)**: headless replay of the fixture suite through
  the composed route asserting the span contract end to end; a seeded-slow span must fail the
  gate (proves the gate can fail before any real regression can slip).
- **Env-gated real run**: a script/runner gated exactly like the WER tests
  (`VOCCA_MODEL_DIR`, visible `XCTSkip`) that prints the real p50/p95 per span on the
  founder's machine, with the process's suppression state recorded beside every row
  (`getpriority(PRIO_DARWIN_PROCESS, 0)` — the `measure-timers.sh` discipline) so a
  throttled number is never presented as a clean one.
- **Capture-close span**: timed at the graph stop (`AudioCaptureGraph.stop()`), the
  `CaptureStartTiming` precedent (114 ms jack / 42 ms array figures exist for C7 to build on).

### Should-have

- A `SMOKE_CHECKLIST.md` entry: the founder's first real measured run (steps 62–68 precedent).
- The P0 gate's "measured and recorded" criterion addressed from the ledger in the run log.

### Nice-to-have

- A small bounded on-disk history — deferred: in-memory only this slice (confirmed).

## Technical Considerations

- **Placement**: vocabulary + ledger live in `VoccaCore` (imports nothing; the histogram needs
  only stdlib `Duration`). Recording happens through seams — engines/injector receive the
  ledger or its recorder by dependency (the injected-clock precedent), never by Core importing
  the engine modules. `VoccaBootstrap`'s `deliver(_:)`/`present(surface:)` fold pipeline
  surfaces into widget events (`Sources/VoccaBootstrap/AppBootstrap.swift:1011-1155`) — the
  natural place to close a session record.
- **Seam/lint discipline**: the H7/H8 one-file-per-seam rules apply to any new system-framework
  name; the ledger itself is pure and adds no framework names. Module-boundary lint must be
  updated if a new target is added (prefer none — Core holds the types).
- **Concurrency**: `EngineTiming` is an actor; the ledger must be safe for recording from the
  capture graph's realtime callback (`@realtime` accounting precedent —
  `MicrophoneLevelSource.swift:84`) and from `@MainActor` pipeline code.
- **Latency budget**: instrumentation must not be on the critical path — recording is
  amortized O(1) appends; the benchmark gate asserts the instrumented path adds nothing
  measurable to the fixture replay.
- **Privacy/local-first**: no persistence of audio or text; spans are durations only; the
  ledger never leaves the process. This is the R11 line, asserted by the probe.
- **Phase placement**: this slice completes P0 milestone 7 and does not advance past any gate;
  the full C7 (warm start, widget-only streaming partials) remains deferred
  (`CAPABILITY_ROADMAP.md:150-165`; `ARCHITECTURE.md:612`).

## Data Model

`SessionRecord`: session identity (sealed outcome's id or equivalent), outcome class
(delivered-by-rung / failsafe-held / aborted / failed / empty-skip), spans
`[LatencySpan]: capture-close | asr | cleanup(absent) | inject`, each `{ name, elapsed }`,
plus engine identity (attribution non-optional, the C2 rule) and the injection rung +
verification state when delivered. Ledger: in-memory, bounded, append-only within a run.

## Risks & Open Questions

- **R3 — latency ceiling** (`ROADMAP.md:302`): this slice measures; it does not optimize. The
  env-gated real run on M1–M4 is the first data the mitigation asks for ("measure across
  M1–M4 early").
- **CI cannot run the real loop** (no mic/TCC/model): the absolute p50/p95 never comes from CI;
  the gate is contract + seeded-relative. Stated loudly so no CI number is ever presented as
  a product number.
- **The capture close span on a real machine** is measurable only on the founder's machine —
  same class of caveat as the WER runs.
- **Open**: whether `EngineTiming`'s three kinds are the final ASR span shape once streaming
  (later C7 slice) lands; the vocabulary is designed to extend, not to be final.

## Out of Scope

- Warm start / launch preload and widget-only streaming partials (later C7 slices,
  `CAPABILITY_ROADMAP.md:154-159`).
- Cleanup implementation (C5 — unbuilt, phase-gated; vocabulary only here).
- A settings/UI surface for the histogram (deferred with the settings work).
- Any persistence beyond the in-memory ledger; any telemetry; any network path.
- On-disk history (confirmed out for this slice).
