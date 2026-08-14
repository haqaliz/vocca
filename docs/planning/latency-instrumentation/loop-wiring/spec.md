# Spec — loop-wiring

Aspect of `latency-instrumentation` (C7 first slice) · `docs/planning/latency-instrumentation/prd.md`
Depends on `core-ledger` (merged: `LatencySpan`, `SessionOutcomeClass`, `SessionRecord`,
`LatencyRecorder`, `LatencyLedger` in `VoccaCore`).

## Problem slice

The ledger exists and is executed by nothing. This aspect records every session through it —
begin at key-down, spans measured at the adapters, finalize on every route out — so the loop's
own numbers become observable, with zero network and no span ever closing on the realtime
thread.

## In scope

1. **DictationPipeline records (Core).** The pipeline already *is* the closed-set decision
   table (its own header documents the 8 rows). It gains defaulted `recorder:
   (any LatencyRecorder)?` and `clock: (any MonotonicClock)?` inits and a defaulted
   `sessionID: SessionRecord.ID?` on `route(_:target:)`. When all three are present:
   - measures the **ASR span** around `engine.transcribe` (clock deltas; never a clock read
     of its own — the clock is injected, the `SessionMachine` precedent);
   - records the **inject span** from `InjectionResult.elapsed` (already measured);
   - records **engine attribution** from `Transcript.engine` (non-optional, the C2 rule);
   - finalizes on **every path**, with the class from its own table: cancelled → `aborted`;
     empty buffer → `emptySkip`; `Task.isCancelled` before/after transcribe → `aborted`;
     transcribe throws → `failed`; empty text → `emptySkip`; delivered rung →
     `delivered(rung:verified:)` (from the `InjectionResult`); widgetFailsafe + held →
     `failsafeHeld`; widgetFailsafe + nothing held → `failed`.
   All existing `DictationPipelineTests` call sites stay compiling via the defaults.
2. **Router begins and guarantees the terminal paths (AppBootstrap, @MainActor).**
   - `.opening` → `recorder.beginSession()`; the ID is stored in router state.
   - `.captureUnavailable` → finalize `failed` (the one terminal that never reaches the
     pipeline) and clear.
   - `.ended` task → passes the ID to `route`; the no-pipeline branch (panel
     `.exhausted`) finalizes `failed`; the ID is cleared after the route returns (the route
     owns finalize on every path it runs).
   - `cancelTranscription` needs no finalize of its own — the cancelled route finalizes
     `aborted` internally (the route checks `Task.isCancelled` first).
3. **Capture-close span at the adapter (VoccaAudio).** `MicrophoneSource` gains defaulted
   `recorder` and `sessionIDProvider: @Sendable () -> SessionRecord.ID?` inits. `endCapture()`
   measures `graph.stop()` on its caller side — **never on the realtime thread** (the review
   gate's hard question, resolved: the span closes on the stop path, after the graph
   returns) — and records the `captureClose` span. The ID comes from a
   `LatencySessionBox` (a small `@unchecked Sendable` class in `VoccaBootstrap`; the
   `@unchecked`/`@MainActor` lint is Core-only) that the router writes at `.opening` and the
   source reads at `endCapture` — safe because `.opening` delivery happens-before
   `beginCapture`, which happens-before `endCapture` at key-up.
4. **Whisper parity (VoccaASR).** `WhisperCppEngine` records the `EngineTiming` kinds
   (`coldLoad` / `warmTranscribe` / `firstAfterLaunch`) in `prepare`/`transcribe`, mirroring
   `ParakeetEngine` exactly — the clock it already owns, read by nothing today, is the one
   that records.
5. **Probe + zero-network assertion.** `DictationLoopRoot` exposes the ledger for
   inspection. `PROBE-CYCLE` prints a `PROBE-LATENCY` line via the ledger's pure `describe()`
   (headless inspect, prd.md goal 3), and the zero-network suite asserts the cycle's report
   carries exactly one record of class `delivered` with `captureClose`/`asr`/`inject` spans
   and `cleanup` `notPresent` — with the interposer proving zero `connect(2)`.

## Out of scope (benchmark-gate aspect)

- The fixture-replay benchmark, the CI regression gate, the env-gated real p50/p95 runner,
  the `SMOKE_CHECKLIST` entry.
- The histogram UI; on-disk persistence; `EngineTiming` migration into `LatencyLedger`
  (engine-internal ledger stays; the session record's ASR span is pipeline-measured — the
  two answer different questions).

## Isolation decisions

- **No span closes on the realtime thread** — capture-close on the `stop()` caller,
  ASR/inject in the pipeline's async context, all actor-safe (`LatencyRecorder` entry points
  are `async`). `RealtimeSafetyTests.expectedRealtimeDeclarations` must NOT change.
- **Core reads no clock**: the pipeline's clock is injected (`MonotonicClock`), exactly the
  `SessionMachine` contract; the existing clock lint stays green by construction.
- **`VoccaBootstrap` may use `@unchecked Sendable`** (the lint is Core-only): the box is the
  one exception to actor-isolated plumbing, and it is confined to the composition root.

## Acceptance criteria (tests written first)

- W1 **Closed-set finalize**: the pipeline's table is driven over all eight rows with a
  real recorder + hand-moved clock + real `SessionRecord.ID`; each row yields exactly one
  record, class per the table, spans in order (asr then inject), `cleanup` `notPresent`,
  engine = the fake engine's identity, delivered rows carry rung + verified from the
  `InjectionResult`.
- W2 **Begin/finalize symmetry at the router**: a composed-root cycle (the `DictationLoopTests`
  shape) leaves the ledger with exactly one record for a delivered session; a
  `captureUnavailable` cycle yields one `failed` record; a cancelled (Esc) cycle yields one
  `aborted` record; no cycle leaves an in-flight (unfinalized) record — the ledger's
  snapshot after each equals the finalized set.
- W3 **Capture-close measured on the stop path**: `MicrophoneSourceTests` with an injected
  recorder + fixed ID assert `endCapture()` records a `captureClose` span whose elapsed
  equals the fake graph's stop duration; nothing is recorded when recorder/ID are absent.
- W4 **Whisper parity**: whisper's `prepare` records `coldLoad` and its `transcribe` records
  `warmTranscribe`/`firstAfterLaunch` exactly like Parakeet's (drive both engines' tests with
  the same clock double; the ledger's samples match the deltas).
- W5 **Probe**: the zero-network suite asserts the `PROBE-LATENCY` line contains the one
  delivered record, its spans, and its id; the interposer continues to fail on any
  `connect(2)`; `describe()` output is stable (deterministic, mint order).
- W6 **Boundary**: `RealtimeSafetyTests` set unchanged; `CoreBoundaryTests` green with no
  edits (the pipeline's additions import nothing); `LicenseHeaderTests` green; full floor
  (836) green after every commit.

## Dependencies / sequencing

- Depends on: `core-ledger` types; `MonotonicClock`; `EngineTiming` (VoccaASR, public in the
  module); `AppBootstrap.configure` + `DictationLoopRoot` + `Wiring` (@MainActor);
  `MicrophoneSource`/`CaptureGraphSeam`; the probe's `exerciseDictationCycle`.
- Test seams already exist: `DictationPipelineTests` fakes, `MicrophoneSourceTests` graph
  fake, `DictationLoopTests` composed root, `ZeroNetworkTests` + `NetworkInterposer`,
  `TestClock` in `SessionTestDoubles.swift`.

## Open questions / risks

- The pipeline's `route` gains a parameter — ten existing call sites compile via the default,
  but the default must be `nil` and the recording path must be inert without it (W3's
  absence assertions).
- The box is process-global-ish state confined to the root; a concurrent second session
  (impossible by the machine's single-session invariant) would clobber it — note the
  invariant in the box's doc.
