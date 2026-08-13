# Spec — core-ledger

Aspect of `latency-instrumentation` (C7 first slice) · `docs/planning/latency-instrumentation/prd.md`

## Problem slice

The P0-completing counters need a vocabulary and a store that can never transmit, never
fabricate, and never lose a session's record. This aspect builds that foundation in
`VoccaCore` — pure types and one actor, headless-testable today — so the loop-wiring aspect
can hook recording into the pipeline, engines and injector without touching the types.

## In scope

1. **Span vocabulary** — `LatencySpan`: name ∈ {captureClose, asr, cleanup, inject}, elapsed
   (`Duration`), and a presence state. **cleanup is vocabulary with a `notPresent` state** —
   C5 is unbuilt; the ledger must never fabricate a `0` or a fake duration for it
   (prd.md "Must-have").
2. **Outcome classes** — `SessionOutcomeClass`: `delivered(rung:verified:)`,
   `failsafeHeld`, `aborted`, `failed`, `emptySkip`. Distinct classes, never force-labeled:
   the P0 first-method-success metric is derived, not stored (prd.md, confirmed decision).
3. **Session record** — `SessionRecord`: id, outcome class, ordered spans, engine identity
   (attribution non-optional, the C2 rule — carried as `EngineIdentity`). One record per
   session.
4. **The ledger** — `LatencyLedger`: a `VoccaCore` actor, in-memory, bounded (oldest dropped
   at a fixed cap), append-only within a run. Entry points: begin a session (mints the id),
   record a span for a session, finalize a session with its outcome class, snapshot, and a
   pure `describe()`.
5. **The recorder seam** — `LatencyRecorder`: the protocol engines/injector/pipeline record
   through; the ledger is the shipped conformance. The seam exists so recording crosses
   module boundaries without `VoccaCore` importing anything.
6. **CoreBoundary compliance** — zero imports (empty allow-list), no stdlib clock read
   (`MonotonicClock` injected), no `@discardableResult`, no mutable-global markers, no
   `@MainActor`/`@unchecked Sendable` in the new files. The actor is the only stateful type.

## Out of scope (loop-wiring aspect)

- Hooking recording into `DictationPipeline` / `AppBootstrap` / engines / injector / probe.
- Whisper engine parity and `EngineTiming` migration (whisper's clock and Parakeet's
  `EngineTiming` stay untouched; loop-wiring bridges or migrates).
- The histogram UI, on-disk persistence, the benchmark harness, the regression gate.

## Isolation decisions (from the PRD review gate)

- **No span closes on the realtime thread.** The capture-close span closes on the *caller of
  `stop()`*, above the callback; the ASR span closes in the engine's own context; the inject
  span on the pipeline's. `RealtimeSafetyTests.expectedRealtimeDeclarations` is set-equality
  and must NOT change in this aspect.
- **Time enters only through the injected `MonotonicClock`.** The ledger never reads a clock;
  callers pass deltas. The existing `testVoccaCoreReadsNoClockOfItsOwn` lint stays green by
  construction.
- **Session identity** is minted by the ledger (`SessionRecord.ID`, a stdlib-only
  monotonically increasing wrapper) — the record exists from begin to finalize; binding to
  `SessionOutcome.Seal` at finalize is the loop-wiring aspect's decision.

## Acceptance criteria (tests written first, in `Tests/HarnessTests/`)

- A1 **Closed-set coverage**: a table over the five outcome classes — each route the
  pipeline can exit by — drives the recorder; every finalize yields exactly one record with
  the class it was given. No path can produce no record.
- A2 **Order and presence**: spans are recorded in call order per session; the cleanup span
  exists in the record as `notPresent` (never `0`, never missing) until a caller records it.
- A3 **No fabrication**: a span recorded twice overwrites nothing and appends nothing false —
  the second record of the same name for the same session is refused or replaces? (Decision:
  refused — a duplicate span name is a wiring bug and must fail loudly in tests, not silently
  in production; the ledger records the first and discards the duplicate, and the test asserts
  the duplicate is visible as a rejected write via the recorder's return value.)
- A4 **Bounded**: at the cap, the oldest record drops and the newest survives; the cap is
  fixed, documented, and asserted.
- A5 **Pure describe**: `describe()` is deterministic over a snapshot, is `String`-only, and
  a test asserts it contains every session's id, class, and each span's name and elapsed.
- A6 **Attribution**: a record finalize with an engine identity carries it on the record; the
  class `delivered` carries the rung and verification state from an `InjectionResult`
  (constructed by hand in the test — the Phase C precedent).
- A7 **Boundary**: the new files import nothing (CoreBoundaryTests suite stays green without
  edits); the ledger's clock is injected — a test drives it with a hand-moved clock and
  asserts the recorded elapsed equals the deltas it was given.
- A8 **Isolation**: recording from a non-main actor context compiles and runs under strict
  concurrency (the suite runs with warnings-as-errors); the actor's methods are `async` and
  the types are `Sendable`.

## Dependencies / sequencing

- Depends on: `VoccaCore` existing types `MonotonicClock` (`Sources/VoccaCore/MonotonicClock.swift`),
  `InjectionRung`/`InjectionResult` (`Sources/VoccaCore/InjectionResult.swift`),
  `EngineIdentity` (`Sources/VoccaCore/ASREngine.swift`).
- Nothing in this aspect touches `VoccaASR`, `VoccaAudio`, `VoccaInject`, `VoccaUI`,
  `VoccaBootstrap`, or the probe.
- Suites to keep green after every commit: `Scripts/test-with-floor.sh` (floor 836).
- License headers required on every new file (`LicenseHeaderTests`).

## Open questions / risks

- Whether `EngineTiming` (VoccaASR) survives as the engine-side ledger or migrates into
  `LatencyLedger` — decided in loop-wiring, not here; the vocabulary must make either cheap.
- `SessionRecord.ID` vs `Seal` as the cross-aspect identity — loop-wiring binds them; this
  aspect only requires `ID` be `Hashable` and stable.
