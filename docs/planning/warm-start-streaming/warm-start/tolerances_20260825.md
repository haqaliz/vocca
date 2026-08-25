# Warm-start tolerance record — provisional bound and the founder's re-baseline

Mechanism doc for the warm-start aspect's provisional number, in the
`tolerances_20260815.md` pattern
(`docs/planning/deterministic-cleanup/eval-harness/tolerances_20260815.md`): **this file
records measured values only; the bound itself lives in exactly one file —
`Sources/VoccaCore/WarmStartRatio.swift` (`WarmStartTargets.maxFirstAfterLaunchMultiple`) —
and a re-baseline lands there, in exactly one place.**

## What the number is, and is not

| Target | Value | Source | Status |
|--------|-------|--------|--------|
| First-transcription-after-launch vs steady-state ratio | ≤ 1.2× (within 20%) | `ROADMAP.md:174` (the warm-start gate, W2) | **Provisional** — the gate's instrument, recorded not proven |

The house honesty rule (`latency-instrumentation/prd.md:35-38`): **CI proves the mechanism,
never a product number.** CI drives the seeded-slow stub through the gate and asserts the gate
can fail on a 2× first transcription (`LatencyBenchmarkTests`, W4) — a mechanism check over
pure code. The 1.2× bound is asserted nowhere against a real model; the env-gated real run
(`LatencyBenchmarkRealEngineTests`, W3) prints the measured ratio and **records, never gates**:
the test asserts the record's shape, not its value.

## Measured values (filled by the founder's real run)

| Run | Machine | firstAfterLaunch p50 | steadyState p50 | Ratio | Suppression state | Date |
|-----|---------|----------------------|-----------------|-------|-------------------|------|
| (none yet — `VOCCA_LATENCY_BENCH` + `VOCCA_MODEL_DIR` is the first execution) | | | | | | |

The run prints the engine's `firstAfterLaunch` and `warmTranscribe` samples, the ratio, and
`getpriority(PRIO_DARWIN_PROCESS, 0)` beside it (the `measure-timers.sh` discipline): a
throttled number is recorded as throttled, never presented as clean. Until the first row is
filled, everything this repository says about the warm-start ratio is a claim about mechanism,
not about measurement.

## Where the bound lives

The 1.2 bound stays in `WarmStartTargets.maxFirstAfterLaunchMultiple`
(`Sources/VoccaCore/WarmStartRatio.swift`), pinned by the single-source scan in
`WarmStartRatioTests`. This file records measured values only; a re-baseline moves the number
in `WarmStartRatio.swift`, never here.

## The re-baseline procedure

1. **Measure** — the founder runs the env-gated real run (`VOCCA_LATENCY_BENCH=1` +
   `VOCCA_MODEL_DIR=<provisioned>`, the smoke step's first execution). The run prints the
   samples, the ratio and the suppression state.
2. **Margin** — the recorded ratio is compared against
   `WarmStartTargets.maxFirstAfterLaunchMultiple` with a margin that absorbs recording noise
   (the exact margin is a founder decision at re-baseline time, recorded in the smoke step's
   note).
3. **Founder-signed** — the founder signs the record: the measured ratio, the machine, the
   model artifact, and the margin. The measured row lands in the table above.
4. **Land in exactly the one file** — `WarmStartRatio.swift` changes only via this procedure;
   the single-source scan keeps the figure single-sourced.
5. **A failing real run re-baselines, never silently relaxes** — a ratio past the bound is a
   record and a signal to fix the warm start (a colder first transcription than steady state),
   not a reason to raise the number quietly.