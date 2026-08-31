# Aspect spec: equivalence-measurement

**Unit:** speculative-asr (C7 remainder) · **Aspect:** equivalence-measurement
**PRD refs:** M1, Q1, Goals 1 & 5

## Problem slice and user outcome

Open question 2 (`ARCHITECTURE.md:695`) has stood unmeasured since C7 shipped: the streaming
final must equal a batch transcription of the same buffer, "or the latency win is bought with
accuracy". The SDK promises nothing for TDT — `finish()` is built from heuristic token dedup
the SDK labels "a temporary workaround" (`AsrManager+TokenProcessing.swift:113-114`). Outcome:
a named, recorded verdict — go or no-go — that the founder and the roadmap can see, produced
by the house measurement discipline (recorded, never gated).

## In-scope requirements

1. **Env-gated real-run harness** (house precedent: `LatencyBenchmarkRealEngineTests`,
   gated on `VOCCA_MODEL_DIR`; skip visibly in CI). For each fixture in the C2 suite
   (`clean`, `accented`, `noisy`, `sixty-second`, `two-hundred-ms` — `ASRFixtureSuite.swift:50-81`):
   transcribe batch (existing path) and transcribe streamed (chunks → adapter → `finish()`
   final), then compare.
2. **Equality metrics, recorded:** per-fixture WER between streamed-final and batch, exact-text
   equality, and the token-diff shape (prefix-equal-then-diverge vs wholesale drift) — the
   shape matters because the roadmap's speculative premise is "only the tail is unprocessed".
3. **Go/no-go verdict as a named row** in the benchmark output and a SMOKE step: PASS
   (per-fixture WER within the provisional tolerance table), FAIL (recorded as a go/no-go
   failure — blocks *claiming the latency win*, never blocks shipping the feed), or VOID
   (precondition not entered — suppression state / model not present, per SMOKE rule 1).
4. **The post-key-up budget question, measured not assumed:** record what the streamed final
   actually costs at key-up for the `sixty-second` fixture (tail decode) vs the full batch —
   the architecture's "only the tail is unprocessed" premise (`ARCHITECTURE.md:334`) is
   unmeasurable for sub-13 s utterances (no partials, full window at key-up) and this row
   says so with numbers.

## Out-of-scope boundaries

- No CI gate on the verdict (records, never gates — `LatencyBenchmarkRealEngineTests` charter).
- No changes to `ProvisionalTolerances` without the founder's re-baseline procedure
  (`tolerances_20260825.md:42-57` precedent).
- No production code changes — measurement only.

## Acceptance criteria (tests written first)

- The harness's mechanism is headless-tested: scripted "streamed" and "batch" results flow
  through the same comparison, the verdict rows render correctly, and a seeded unequal pair
  produces FAIL while an equal pair produces PASS — a gate that cannot fail proves nothing.
- CI skips visibly without `VOCCA_MODEL_DIR` and fails loudly with provisioning instructions
  (`LatencyBenchmarkRealEngineTests.swift:84-96` precedent).
- The verdict table is printed with suppression state beside every row (SMOKE rule 1,
  `getpriority(PRIO_DARWIN_PROCESS, 0)` precedent).
- A SMOKE step records the first execution with its go/no-go row; the result is entered in the
  tracked table.

## Dependencies and sequencing

- Depends on `parakeet-streaming` (the vehicle) and the fixture suite (shipped).
- Runs after `parakeet-streaming`; its verdict is an input to whether N1 (window re-tuning)
  is ever worth proposing — recorded in the PRD's risk table, not a gate.

## Open questions / risks

- Q1 verdict is genuinely open; if FAIL, the feed ships with display-value partials and the
  latency claim is dropped (PRD risk Q1).
- Whisper needs no equivalence run (final ≡ batch by construction) — the harness is
  Parakeet-only; a note in the output says why.