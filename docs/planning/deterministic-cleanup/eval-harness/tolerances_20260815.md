# Cleanup eval tolerance record — provisional targets and the F2 re-baseline

Mechanism doc for the cleanup eval harness's provisional numbers, in the
`tolerances_20260810.md` pattern (`docs/planning/second-asr-engine/fixture-harness/tolerances_20260810.md`):
**this file is where the mechanism is explained; the numbers themselves live in exactly one
file — `Tests/HarnessTests/ProvisionalCleanupTargets.swift` — and a re-baseline lands there.**

## What the numbers are, and are not

| Target | Value | Source | Status |
|--------|-------|--------|--------|
| Blind pairwise preference, cleaned-over-raw | ≥ 80% | `ROADMAP.md:137` (P1 gate) | **Provisional** — the P1-gate instrument, not a measured product claim |
| Rules-path p50 | < 10 ms | `ARCHITECTURE.md:310` | **Provisional** — the latency budget, mechanism-gated in CI only |

The house honesty rule (`latency-instrumentation/prd.md:35-38`): **CI proves the mechanism,
never a product number.** CI runs the stand-in corpus through the shipped rules and asserts the
p50 stays under the budget and the gate can fail (a seeded-slow rule must blow it) — a mechanism
check over a pure stdlib function. The ≥ 80% preference figure is not asserted in CI at all; the
stand-in corpus's own percentage is a harness-sanity number printed by the headless run, not a
gate.

## The tie-denominator choice (re-openable only here)

The preference percentage divides by **pairs with a preference** — `tie` and `noPreference`
rows are excluded from the denominator (`eval-harness/spec.md:42-43`). Re-opening this choice is
an F2-re-baseline decision, recorded here before any number moves.

## The F2 re-baseline procedure

1. **Measure** — the founder records the F2 corpus (≥ 40 pairs, ≥ 5 per class; `SMOKE_CHECKLIST.md`
   step 73) and runs the scorer: `VOCCA_CLEANUP_EVAL=<pairs-dir>`, two invocations (ballot →
   answers). The run prints the preference percentage, the per-class breakdown and the seed.
2. **Margin** — the recorded percentage is compared against `ProvisionalCleanupTargets.preferenceMinimum`
   with a margin that absorbs recording noise (the exact margin is a founder decision at
   re-baseline time, recorded in the smoke step's note).
3. **Founder-signed** — the founder signs the record: the measured percentage, the machine, the
   corpus provenance, and the margin.
4. **Land in exactly the one file** — `ProvisionalCleanupTargets.swift` changes only via this
   procedure; the B6 scan keeps the figure single-sourced.
5. **A failing real run re-baselines, never silently relaxes** — a result below the target is a
   record and a signal to fix the rules, not a reason to lower the number quietly.

Until step 1 has happened once, everything this repository says about cleanup quality is a claim
about mechanism, not about measurement.
