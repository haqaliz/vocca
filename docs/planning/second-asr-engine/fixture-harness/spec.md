# fixture-harness — spec

> Aspect of `second-asr-engine` (C3). PRD: `docs/planning/second-asr-engine/prd.md`
> (M6, M7, S1).

## Problem slice

The C3 acceptance made testable: the **same fixture suite runs against both engines**
with per-engine tolerance tables, the runtime swap is pinned, and the real-engine half
stays env-gated and honest.

## In-scope

- **Shared real-engine runner**: extract the body of `ParakeetEngineWERTests` into a
  parameterized runner (one test body, driven with an engine factory + a tolerance
  table), so the same suite runs against Parakeet and Whisper. The provisional
  tolerance table stays per-engine, in one place each (the C3 PRD M6 mechanism:
  measured-WER + margin from a real env-gated run, founder-signed; F2 recordings later
  replace them in those same places).
- `WhisperCppEngineWERTests`: env-gated (`VOCCA_MODEL_DIR`) real run over the six
  fixtures, offline, attribution asserted, provisional tolerances met — the mirror of
  `ParakeetEngineWERTests` (skips visibly without the env var).
- **Runtime swap test**: mid-session-boundary — run a session through one engine, swap
  to the other at the boundary, assert the only observable difference above the seam is
  `engineIdentity` (stubs in CI; the seam's `stream` default + `transcribe` through
  `any ASREngine` is the caller).
- Stub-level parameterization stays (the `ASRFixtureHarnessTests` doubles) — no
  real-model call in CI.
- S1: measured whisper RTF recorded (not asserted) in the fixture notes / smoke
  checklist once a real run exists; no unmeasured numbers anywhere.

## Out-of-scope

- Final tolerances (F2 founder recordings — later, same places).
- CI runner verdict (F1) — `ci-wiring` records it; env-gated path is the default for
  both engines regardless.
- Streaming/partials (C7).

## Acceptance criteria (test-first)

1. One test body, parameterized over engines, drives the six-fixture suite for both
   real engines when `VOCCA_MODEL_DIR` is set; both pass their provisional per-engine
   tolerances; every transcript attributed to its engine.
2. The swap test asserts: no caller above the seam changed (compile-time), and the only
   runtime difference is `engineIdentity`.
3. Without the env var, the real tests skip visibly; the headless suite runs entirely
   on stubs with zero network.
4. WER tolerance values for whisper live in exactly one place, marked provisional, with
   the re-baseline procedure documented next to them.

## Dependencies / sequencing

After `model-lifecycle` (real run needs manifests + artifacts) and `whisper-engine` (the
engine). The swap test needs only `bridge-integration` + `whisper-engine`.

## Open questions

- The "two-hundred-ms" fixture uses a substitution-count rule (≤1 substitution), not a
  WER ceiling (`fixture-suite/spec.md:60`) — the runner must carry that special case
  identically for both engines.
