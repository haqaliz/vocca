# ci-wiring — spec

> Aspect of `second-asr-engine` (C3). PRD: `docs/planning/second-asr-engine/prd.md`
> (M11).

## Problem slice

C3 lands green: the headless suite (with the new lint, the parameterized harness, the
binary target) passes on a macOS hosted runner under strict concurrency within budget;
the real-engine runs skip visibly; and the repo's honest-scope docs (SMOKE_CHECKLIST,
CLAUDE.md, README, ARCHITECTURE.md) record exactly what CI can and cannot prove about
the whisper engine.

## In-scope

- Verify `.github/workflows/ci.yml`'s headless job builds the package with the new
  XCFramework dependency and runs the full suite through `Scripts/test-with-floor.sh`;
  any-warning-fails stays (Swift 6 strict concurrency).
- Suite budget: the parameterized additions stay within the existing headless job's
  window (stub-driven; no real-model calls).
- Env-gated real WER tests skip visibly in CI (XCTSkip without `VOCCA_MODEL_DIR`) —
  both engines; the F1 runner verdict (real-model suite on a hosted runner) is recorded
  in the existing `ci-wiring-decision_20260809.md` doc, not re-decided here.
- Docs updated to the repo's honesty standard: `docs/SMOKE_CHECKLIST.md` gains the
  whisper real-run + license-verification manual steps; `CLAUDE.md` status section and
  `README.md` engine row move whisper.cpp from "planned" to "shipped second engine
  (proven seam)"; `ARCHITECTURE.md` engine table + `VoccaBridge` note amended
  (one-file bridge decision); fixture notes record measured whisper RTF once a real run
  exists (S1) — never before.
- Test-floor ratchet in the same commit (the repo's invariant: every landed change
  raises or holds the floor).

## Out-of-scope

- Deciding the F1 runner verdict (recorded, not decided).
- Caching the 1.5 GiB GGUF on hosted runners (env-gated runs happen on the founder's
  machine).
- Any product feature work.

## Acceptance criteria (test-first)

1. `Scripts/test-with-floor.sh` passes locally and in CI on the branch (build + full
  suite, floor met, no warnings).
2. The env-gated real tests skip visibly in the headless job (they do not fail, and the
  skip is asserted in the job log/run output).
3. Every doc claim about the whisper engine is backed by either a merged artifact or a
  marked-provisional measurement — no unmeasured claims (audit the diff's doc lines).
4. The floor count after merge ≥ the floor before merge.

## Dependencies / sequencing

Last — integrates `bridge-integration`, `whisper-engine`, `model-lifecycle`,
`fixture-harness`, `engine-picker`.

## Open questions

- None.
