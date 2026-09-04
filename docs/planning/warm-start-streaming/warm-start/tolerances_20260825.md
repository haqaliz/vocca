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
| 1 | founder's machine (arm64, Apple Silicon) | 79 ms | 102 ms (clean), 354 ms (60 s) | 0.348× (WITHIN the 1.2× bound) | 0 (NOT suppressed) throughout | 2026-09-01 |
| 2 (streaming variant, feed live) | same | — | — | 0.348× (WITHIN the 1.2× bound) | 0 (NOT suppressed) | 2026-09-01 |

Re-warm (Q5) measured in the same runs: **82–85 ms** reload cost (one real `rewarm()` per run, `.rewarm` row), suppression 0 (NOT suppressed). The re-warm row is recorded, never gated; the 5-minute idle constant (`IdleReWarmTargets`) is untouched by this row.

Latency spans measured in the same runs (batch / streaming, per the closed four-span set — the cleanup span is `notPresent` for a nil-cleanup benchmark pipeline): captureClose p50 3 ms / p95 3 ms; asr p50 79–102 ms (per fixture) / p95 354 ms; inject p50 7 ms / p95 7 ms. Both variants PASS the provisional p50 table (RECORDED, not gated — the 400/800 ms numbers in `LatencyBenchmarkTests.swift` are re-baselined only by a founder-signed decision; none was made in this run, the numbers cleared their provisional bounds).

The run prints the engine's `firstAfterLaunch` and `warmTranscribe` samples, the ratio, and
`getpriority(PRIO_DARWIN_PROCESS, 0)` beside it (the `measure-timers.sh` discipline): a
throttled number is recorded as throttled, never presented as clean. Until the first row is
filled, everything this repository says about the warm-start ratio is a claim about mechanism,
not about measurement.

## Composite latency row (SMOKE 71-72 re-run, 2026-09-04, `latency-record`)

The 2026-09-01 run above recorded per-span rows only; step 72's deliverable — the composite
key-up → text-on-screen row — was recorded in this run (the printer's composite row, the
cleanup span **named** `notPresent` for the nil-cleanup pipeline, never dropped).

| Variant | captureClose p50/p95 | asr p50/p95 | cleanup | inject p50/p95 | **total p50/p95** | Suppression | Machine | Model |
|---|---|---|---|---|---|---|---|---|
| batch | 3 / 3 ms | 103 / 348 ms | `notPresent` | 7 / 7 ms | **113 / 358 ms** | 0 (NOT suppressed) throughout | founder's machine (arm64, Apple Silicon) | `parakeet-tdt-0.6b-v3`, version 1 (`verified`) |
| streaming (feed live) | 3 / 3 ms | 105 / 355 ms | `notPresent` | 7 / 7 ms | **115 / 365 ms** | 0 (NOT suppressed) throughout | same | same |

**The 60-second fixture substitution, stated beside the numbers:** the fixture suite has no
10-second clip, so the composite is measured over the **60 s fixture** — the closest length the
suite has (`SMOKE_CHECKLIST.md:1353-1354`). These are not 10 s numbers, and the P2 gate must not
read them as such.

Warm-start in the same run: **0.350× (batch) / 0.337× (streaming)** — WITHIN the 1.2× bound
(referencing the 2026-09-01 rows above, not re-claimed). Re-warm: **83/85 ms**. Suppression 0
(NOT suppressed) beside every row; date 2026-09-04.

**Margin and signature: the measured composite cleared the provisional 400/800 table well
inside, so the proposed margin is 0 — the table is unchanged and `ProvisionalTolerances` is
untouched. Founder ratification PENDING** — the founder signs the margin; this row records the
measurement, not the signature.

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