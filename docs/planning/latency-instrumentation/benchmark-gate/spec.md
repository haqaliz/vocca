# Spec — benchmark-gate

Aspect of `latency-instrumentation` (C7 first slice) · `docs/planning/latency-instrumentation/prd.md`
Depends on `core-ledger` + `loop-wiring` (merged: the loop records every session; the ledger
is inspectable; `PROBE-LATENCY` prints `describe()` under the interposer).

## Problem slice

The loop now *records* its numbers; nothing *checks* them. `ARCHITECTURE.md:589` names the
missing deliverable: a benchmark harness that replays fixtures, asserts p50/p95, and fails CI
on regression. CI cannot run the real engine, so the gate is two honest halves: a headless
harness that proves the span contract and the *mechanism* of the gate (a seeded slow span
must fail it), and an env-gated real run on the founder's machine that produces the actual
p50 ≤ 400 ms / p95 ≤ 800 ms numbers (`ROADMAP.md:171`) with the suppression-state discipline
(`measure-timers.sh` precedent) — never a CI number presented as a product number.

## In scope

1. **Headless benchmark harness (CI).** A new suite (`LatencyBenchmarkTests`) drives
   fixture-derived audio through the composed route (the `DictationCycleDrive` shape) with a
   stub engine + fast fakes, then asserts the **span contract** on the ledger's records:
   every record has `captureClose`/`asr`/`inject` spans in order, `cleanup` absent, engine
   attribution present, spans non-negative and consistent with the injected clock's deltas.
2. **The regression gate, with its mechanism proven.** A threshold table (per-span,
   injectable — CI runs wide/stub thresholds; the real table lives in one place) and a gate
   check. The load-bearing test: a **seeded slow fake** (an injector whose `inject` takes
   ~100 ms against a 10 ms threshold) makes the gate *fail*, while fast fakes pass — proving
   the gate can fail before any real regression can slip (prd.md goal 4). The gate fails the
   build: a test asserts it.
3. **Env-gated real run.** A runner gated exactly like the WER tests (visible `XCTSkip`
   without the env var; model provisioning via `VOCCA_MODEL_DIR`), driving the **real
   engine** through the same harness over the fixture suite, printing p50/p95 per span with
   the process's suppression state (`getpriority(PRIO_DARWIN_PROCESS, 0)`) beside every row.
   Provisional tolerances (p50 ≤ 400 ms / p95 ≤ 800 ms for a 10-second utterance,
   `ROADMAP.md:171`) live in exactly one table; the runner records rather than gates until
   the founder re-baselines (the C3 tolerances precedent: `tolerances_20260810.md` mechanism).
4. **`SMOKE_CHECKLIST.md` entry.** The founder's first real measured run — steps in the
   checklist's own style (steps 18–19 / 62–68 precedent), naming the env vars, the fixtures,
   and what "pass" means.

## Out of scope

- Warm start and widget-only streaming partials (later C7 slices).
- Optimizing anything the benchmark measures (R3's mitigation is *measure* first).
- Persistence/history of benchmarks; a UI for the histogram.
- Absolute p50/p95 claims from CI: CI proves contract + gate mechanism only.

## Isolation / honesty decisions

- **CI never produces a product latency number.** The headless harness's thresholds are
  deliberately wide or stub-seeded; the seeded-slow test proves the gate mechanism; the real
  numbers come only from the env-gated run on the founder's machine.
- **Suppression state beside every real row** — the `measure-timers.sh` discipline: a
  throttled number is recorded as throttled, never presented as clean.
- **No network, no new dependencies**: the harness is pure in-process; fixtures are the
  existing `Tests/Fixtures/*.wav`; the interposer's zero-`connect(2)` claim is inherited.

## Acceptance criteria (tests written first)

- B1 **Contract**: the harness drives ≥ 3 fixture-derived cycles (different fixture lengths);
  each ledger record has captureClose+asr+inject spans in order, no cleanup token, engine =
  the stub engine's identity, and spans equal the injected clock's deltas exactly.
- B2 **Gate mechanism**: with the threshold table injected, fast fakes pass the gate; a
  seeded ~100 ms injector against a ~10 ms inject threshold makes the gate fail — both
  asserted in the suite.
- B3 **Env gate**: without the env var the real runner skips visibly (the WER `XCTSkip`
  pattern); with it, it drives the real engine over the fixtures and prints per-span p50/p95
  with suppression state on every row.
- B4 **Tolerances in one place**: the provisional p50/p95 table is a single named constant
  set, asserted by a test to exist and to be referenced by the env-gated runner.
- B5 **Checklist**: `docs/SMOKE_CHECKLIST.md` gains the real-run steps (numbered in the
  existing sequence).
- B6 **Floor/boundary**: full floor green after every commit; no lint edits; no new
  dependencies; `expectedRealtimeDeclarations` unchanged.

## Dependencies / sequencing

- Depends on: `loop-wiring` (the ledger records; the root exposes it), `ASRFixtureSuite` +
  `Tests/Fixtures/*.wav`, the WER env-gating pattern (`ParakeetEngineWERTests.swift`),
  `DictationCycleDrive`/probe fakes, `Tools/TimerProbe`'s suppression helper pattern.
- The real runner reuses the real-engine provisioning path (`VOCCA_MODEL_DIR`,
  `Scripts/provision-asr-fixtures.sh`).

## Open questions / risks

- No 10-second fixture exists (the suite has clean/spike/accented/noisy/60 s/200 ms): the
  harness uses the existing fixtures; the 10 s p50/p95 target is measured on the founder's
  machine with the 60 s fixture or a provisioned 10 s clip — noted in the checklist entry,
  not invented here.
- Whether the gate's CI thresholds are per-span constants or derived from the stub's known
  cost — derived (stub cost + margin) keeps the gate honest without pretending.
