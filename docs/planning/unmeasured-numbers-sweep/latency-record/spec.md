# Spec — latency-record (aspect 4 of unmeasured-numbers-sweep)

**Aspect of:** unmeasured-numbers-sweep · **PRD ref:** M6 · **Date:** 2026-09-04

## Problem slice and user outcome

Steps 71-72 ran fully in p2-gate-measurement (per-span rows recorded, `STATUS.md:208-211`), but step 72's deliverable is incomplete: no composite key-up → text-on-screen number against the provisional 400/800 table, no founder-signed re-baseline, no substitution/machine/model statement beside the numbers, and the cleanup span never measured. Outcome: the real runner emits a composite span row per cycle, the benchmark re-runs, and the P2 gate's latency leg has a complete, honest record. Recorded, never gated.

## In-scope

- **Composite row (test-first, RED→GREEN):** the real benchmark runner emits a composite (total) span row per cycle alongside captureClose/asr/cleanup/inject, with the cleanup span's status named (absent for the nil-cleanup pipeline, not silently dropped). **Constraint:** the seeded contract tests pin the span set to exactly `[captureClose, asr, inject]` (`LatencyBenchmarkTests.swift:112-121`, streaming `:482-491`) — the composite is an addition to the real-run printer only; a change to the seeded contract is a seam-contract change that escalates (PRD M7's rule), not a silent amendment.
- **Re-run (SMOKE 71-72):** `VOCCA_LATENCY_BENCH=1 VOCCA_MODEL_DIR=<dir> swift test --filter LatencyBenchmarkTests` (both variants where the runner supports it), suppression `not-suppressed` throughout — a throttled run is **voided, not recorded** (`SMOKE_CHECKLIST.md:1337-1340`).
- **Step-72 completion:** the composite p50/p95 recorded against the provisional table (p50 400 / p95 800, `ProvisionalTolerances`, `ROADMAP.md:171`), with the **60 s fixture substitution** (no 10 s clip in the suite), the machine, and the model version stated beside the numbers (`SMOKE_CHECKLIST.md:1350-1358`); the founder-signed re-baseline row lands in `tolerances_20260825.md` (measure → margin → founder-signed → land in exactly the named file; single-source scans stay green); `ProvisionalTolerances` untouched unless the founder signs a change.
- The already-recorded per-span numbers are **not re-claimed as new**; the record references them and adds what was missing.

## Out-of-scope

- Any regression gate on real numbers (this unit adds none; CI proves the mechanism over seeded fakes).
- Engine-tuning or window-config changes (founder decision, recorded not gated, only via the named single-source file).
- The equivalence NO-GO (recorded, stands; the latency-win claim stays blocked regardless of this aspect's numbers).

## Acceptance criteria (testable)

- A headless test asserts the real-run printer emits the composite row with the cleanup span named (RED before, GREEN after).
- The seeded contract tests still pin `[captureClose, asr, inject]` untouched.
- SMOKE 71-72 rows: per-span + composite p50/p95 recorded, suppression `not-suppressed`, the 60 s substitution + machine + model version beside the numbers.
- Founder-signed re-baseline row in `tolerances_20260825.md` with margin stated; single-source scans green.
- Any defect fix: RED→GREEN, floor 1755 holds.

## Dependencies and sequencing

- The runner change (test-first) before the re-run; the re-run itself is any founder session after.
- Requires the provisioned Parakeet model (`VOCCA_MODEL_DIR`); the whisper half of the sweep is independent.
- N1 (streamed-variant composite) applies if the runner change makes it free.

## Open questions / risks

- The composite is only as honest as its span coverage — the cleanup span's absence must be named, or the number overclaims (PRD R4).
- The 60 s fixture substitution must be recorded beside the number or the P2 gate reads it as a 10 s measurement.
- Suppression discipline: any throttling voids the run; re-run rather than record.