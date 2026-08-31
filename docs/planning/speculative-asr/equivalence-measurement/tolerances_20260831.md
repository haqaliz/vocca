# Equivalence tolerance record — the provisional table and the founder's re-baseline

Mechanism doc for the equivalence-measurement aspect's provisional table, in the
`tolerances_20260825.md` pattern
(`docs/planning/warm-start-streaming/warm-start/tolerances_20260825.md`): **this file
records measured values only; the table itself lives in exactly one file —
`Tests/HarnessTests/EquivalenceMeasurement.swift`
(`ProvisionalEquivalenceTolerances`) — and a re-baseline lands there, in exactly one place.**

## What the table is, and is not

| Target | Value | Source | Status |
|--------|-------|--------|--------|
| Per-fixture streamed-vs-batch WER ceiling | 0.05 for all six fixtures | Plan resolution 3 (the whisper "seeded, not measured" precedent — equivalence had no table to seed from) | **PROVISIONAL-BY-DECISION placeholder** — recorded, never gated |

The house honesty rule (`latency-instrumentation/prd.md:35-38`): **CI proves the mechanism,
never a product number.** CI drives the seeded unequal pair through the comparison and asserts
the verdict can fail (`EquivalenceMeasurementTests`) — a mechanism check over pure code. The
0.05 bounds are asserted nowhere against a real model; the env-gated real run
(`EquivalenceRealEngineTests`, `VOCCA_LATENCY_BENCH` + `VOCCA_MODEL_DIR`) prints the measured
rows with the suppression state beside every row and **records, never gates**: the test asserts
the record's shape, never its values. **A FAIL verdict is a successful unit outcome** — the
latency claim is dropped and the roadmap amended; nothing in this aspect gates on the numbers.

The first run prints the raw WER/exact/shape beside the provisional verdict — the re-baseline
decision is never made on the provisional verdict alone.

## Measured values (filled by the founder's first run — SMOKE step 125)

| Fixture | WER | exact | shape | key-up cost | batch cost | partials | Suppression | Machine | Model artifact | Date |
|---------|-----|-------|-------|-------------|------------|----------|-------------|---------|----------------|------|
| (none yet — step 125's execution is the first) | | | | | | | | | | |

The run prints the verdict table with `getpriority(PRIO_DARWIN_PROCESS, 0)` read fresh beside
every row (the `measure-timers.sh` discipline): a throttled number is recorded as throttled,
never presented as clean, and an unreadable state voids the whole run. Until the first row is
filled, everything this repository says about the streamed-vs-batch equivalence is a claim
about mechanism, not about measurement.

## Where the table lives

The 0.05 placeholder table stays in `ProvisionalEquivalenceTolerances`
(`Tests/HarnessTests/EquivalenceMeasurement.swift`), pinned by the single-source scan in
`EquivalenceMeasurementTests`. This file records measured values only; a re-baseline moves the
numbers in `EquivalenceMeasurement.swift`, never here.

## The re-baseline procedure

1. **Measure** — the founder runs the env-gated real run (`VOCCA_LATENCY_BENCH=1` +
   `VOCCA_MODEL_DIR=<provisioned>`, SMOKE step 125's first execution). The run prints the
   per-fixture WER/exact/shape, the key-up cost, the partials count and the suppression state.
2. **Margin** — the recorded WER is compared against `ProvisionalEquivalenceTolerances` with a
   margin that absorbs recording noise (the exact margin is a founder decision at re-baseline
   time, recorded in the smoke step's note).
3. **Founder-signed** — the founder signs the record: the measured rows, the machine, the model
   artifact, and the margin. The measured rows land in the table above.
4. **Land in exactly the one file** — `ProvisionalEquivalenceTolerances` changes only via this
   procedure; the single-source scan keeps the table single-sourced.
5. **A failing real run re-baselines, never silently relaxes** — a NO-GO verdict is a record and
   a signal (the latency claim is dropped, `ARCHITECTURE.md`'s open question 2 answered
   negatively, the window-retuning question N1 revisited), not a reason to raise the numbers
   quietly.

## Whisper needs no equivalence run

Its final equals batch by construction (repeated `whisper_full` on the growing buffer; the
final is the last full decode) — the harness is Parakeet-only, and the printed note says why.