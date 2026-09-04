# Spec — f2-defect-fixes (aspect 2 of unmeasured-numbers-sweep)

**Aspect of:** unmeasured-numbers-sweep · **PRD ref:** M4 · **Date:** 2026-09-04

## Problem slice and user outcome

The F2 eval flow cannot run end to end today: (a) the ballot is **never printed** — `printBallot` (`CleanupEvalHarnessTests.swift:835-855`) has no caller, the env-gated test skips when `answers.tsv` is missing without printing anything (`:459-463`), and nothing generates the ballot seed that `answers.tsv`'s first line must match (`:814-815`); (b) corpus discovery requires a `.raw.txt` per pair (`CleanupPairSuite.swift:91-95`) but every F2 procedure doc lists only `.wav/.clean.txt/.class.txt` + `dictionary.json` — a wav-only corpus loads 0 pairs. Outcome: the first `VOCCA_CLEANUP_EVAL=<pairs-dir>` invocation prints a seeded, side-blind ballot; the documented convention matches the loader's reality.

## In-scope

- **Ballot flow (test-first, RED→GREEN):** first invocation with a complete corpus and no `answers.tsv` prints the seeded ballot (seed generated, printed, and matchable against `answers.tsv`'s first line); second invocation with `answers.tsv` present prints per-pair rows and the verdict (`CleanupEvalHarnessTests.swift:882-906`). Ballot content: pair name and class tag may print (`printBallot` prints `## <name> [<class>]`, `:850`); the guarantee is **side-blindness** — the judge never sees which side is cleaned (PRD M4a).
- **Raw-side convention (doc + pin):** `.raw.txt` documented as the discovery requirement in the F2 procedure docs (`cleanup-eval-f2/spec.md:17`, `plan_20260901.md`, `SMOKE_CHECKLIST.md:1380-1383`) — raw side = the engine transcript written by the provisioning pass, or the hand-typed fallback; the convention pinned by a test where one is missing.

## Out-of-scope

- The F2 corpus itself, the ballot answers, and the verdict (aspect `cleanup-eval-f2`).
- Any change to the scorer, the denominator rule (tie/noPreference excluded), or the 0.80 target.
- The `VOCCA_CLEANUP_EVAL=1` stale-doc fix (recorded in `record-and-sync`'s S1; the env value is the pairs-dir path, `CleanupEvalHarnessTests.swift:450`).

## Acceptance criteria (testable)

- A headless test drives the env-gated flow with a stub corpus: first invocation prints a seeded ballot whose seed matches a subsequently written `answers.tsv`; second invocation prints the verdict rows. RED on the missing flow before the fix, GREEN after.
- The ballot never reveals which side is cleaned.
- The F2 procedure docs state `.raw.txt` is required for discovery; a test (or existing loader behavior) pins that requirement.
- Floor 1755 holds; branch green after every task.

## Dependencies and sequencing

- First aspect to execute (PRD execution order step 1) — the only build work in the F2 half; unblocks `cleanup-eval-f2`.
- Requires a stub-corpus test harness pattern already present in `CleanupEvalHarnessTests.swift` (the headless stand-in corpus path).

## Open questions / risks

- The seed format is pinned by `parseAnswers`'s `seed\t<hex>` first line (`:807-830`) — the printed seed must match that exact spelling or `answers.tsv` won't parse.
- Side-blindness is the spec's guarantee (`eval-harness/spec.md:63-64`); the class tag is cosmetic and stays — any removal is out of scope.
- The wav-substitution path (`CleanupEvalHarnessTests.swift:475`) loads raw from `.raw.txt` first, then may replace it with the engine transcript — the doc fix must describe that order accurately.