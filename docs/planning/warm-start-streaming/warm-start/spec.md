# Spec — warm-start (slice 1 of warm-start-streaming)

## Problem slice

The launch `prepare()` already runs once (`AppBootstrap.swift:857-883`), the resolver is
resolve-once and single-flight (`DictationEngineResolver.swift:50-150`), and `EngineTiming`
already records `.coldLoad` / `.firstAfterLaunch` / `.warmTranscribe`
(`EngineTiming.swift:26-35`). None of it is pinned by a test, the 20%-of-steady-state bound
(`ROADMAP.md:174`) lives nowhere, and no run measures the ratio.

## In-scope

- **W1** Launch preload pinned: exactly one `prepareIfNeeded()` on the launch path; the
  session path never re-prepares; a session after launch routes through the prepared engine.
- **W2** The warm-start ratio evaluator + the 20% bound in exactly one place (the
  `ProvisionalCleanupTargets` single-source pattern).
- **W3** Env-gated real run prints the first-after-launch vs steady-state ratio with the
  process's suppression state (`VOCCA_LATENCY_BENCH` + `VOCCA_MODEL_DIR`, visible skip);
  records into the tolerances table, never gates a release on CI.
- **W4** `LatencyBenchmarkGate` gains the warm-start verdict with a seeded-slow-first-transcribe
  stub that must fail it (a gate that cannot fail proves nothing).
- **W5** Zero network: launch prepare is disk-only; the probe's cycle keeps `prepareCount`
  observable and zero `connect(2)` unchanged.

## Out-of-scope boundaries

- Re-warm after idle (needs an idle policy — separate unit).
- Real-engine streaming adapters; speculative pre-key-up feed (slice 2 + later).

## Acceptance criteria (testable)

1. `WarmStartRatio.evaluate(firstAfterLaunch:steadyState:)` returns `.withinBound(ratio:)`
   when ratio ≤ 1.2 and `.exceedsBound(ratio:bound:)` otherwise, with an insufficient-samples
   answer when either side is empty — table-tested, stdlib-only, in `VoccaCore`.
2. A launch-path test drives `DictationLoopRoot.startEnginePreparation()` with a counting
   stub engine and asserts `prepareCount == 1`, the readiness gate opens, and a session
   routes without any further prepare call.
3. A session-path test asserts a completed session does not call `prepare` (count still 1).
4. The benchmark gate fails when the stub's first-after-launch transcribe is 2× steady-state
   and passes when it is 1.1× — the gate can fail, and the failing verdict names the ratio.
5. The env-gated real run prints the ratio + suppression state and skips visibly in CI.
6. The zero-network probe cycle still makes zero `connect(2)` with `prepareCount` observable.

## Dependencies & sequencing

- After the `latency-instrumentation` unit (shipped): `EngineTiming`, `LatencyLedger`,
  `LatencyBenchmarkTests.swift`, `DictationEngineResolver` all exist.
- No dependency on slice 2; ships first.

## Open questions / risks

- Whether the session ledger's closed four-span set changes: planning resolves this — the
  ratio is cross-session (`EngineTiming` samples), so the session-record shape is unchanged;
  the gate gains a warm-start verdict row, not a new span name.