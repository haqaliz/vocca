# Spec — cleanup-eval-f2 (aspect 3 of unmeasured-numbers-sweep)

**Aspect of:** unmeasured-numbers-sweep · **PRD ref:** M5 · **Date:** 2026-09-04

## Problem slice and user outcome

The P1 gate's number (rules ≥80% blind preference over raw, `ROADMAP.md:137`) is still provisional — the eval harness only ever scored a TTS stand-in corpus (`STATUS.md:566-571`). Outcome: the F2 corpus exists on the founder's machine (≥40 utterances, ≥5 per class, never in the repo), the ballot runs side-blind, the verdict is recorded against the 0.80 target, and `ProvisionalCleanupTargets` re-baselines via the founder-signed procedure if the number misses. Recorded, never gated.

## In-scope

- **Corpus:** ≥40 founder-recorded utterances, ≥5 per class across the six `Tests/CleanupPairs/` classes (fillers | punctuation | capitalization | numbers-units | dictionary | token-protection), saved per the SMOKE convention — `<name>.wav / <name>.raw.txt / <name>.clean.txt / <name>.class.txt` + `dictionary.json` under `~/Vocca/f2-pairs/` (`.raw.txt` is the discovery requirement per the `f2-defect-fixes` aspect; the engine transcript may replace the raw side when `.wav` + `VOCCA_MODEL_DIR` are present, `CleanupEvalHarnessTests.swift:475`).
- **Run:** `VOCCA_CLEANUP_EVAL=<pairs-dir>` (the value is the directory — `:450`); first invocation prints the seeded ballot; the founder's blind answers fill `answers.tsv` (`seed\t<hex>` first line + `name\tleft|right|tie|noPreference` rows); second invocation prints per-pair rows, `preference=NN.N%`, per-class tallies, and the `RECORDED, not gated` verdict vs 0.80 (tie/noPreference excluded from the denominator).
- **Re-baseline:** measure → margin (founder decision) → founder-signed row in `tolerances_20260815.md` → land in exactly `ProvisionalCleanupTargets.swift` (single-source scans stay green) — or record the 0.80 target as met without a code change if the number clears.

## Out-of-scope

- LLM cleanup quality measurement (C6 claims nothing there; `STATUS.md:406-408`).
- The dictionary store's own behavior (shipped; only the corpus uses it).
- The ballot-flow and convention code fixes (aspect `f2-defect-fixes` — prerequisites).

## Acceptance criteria (testable)

- Corpus complete: ≥40 pairs, ≥5 per class, named per the SMOKE convention; the directory's existence and provenance recorded in the step-73 note; nothing committed.
- Ballot produced and answered (side-blindness preserved).
- Verdict row recorded against 0.80; the founder-signed procedure's chain followed in full; the single-source scan stays green.
- Any defect fix: RED→GREEN, floor 1755 holds.

## Dependencies and sequencing

- The recording (the long pole) overlaps `whisper-wer` and `latency-record`; the ballot + verdict run last, after the corpus is complete.
- The eval's `.wav` transcription uses the real Parakeet engine — requires the model from the founder's provisioned store (`VOCCA_MODEL_DIR`); the eval hard-fails if `.wav` present without it (`:465-473`).
- Requires `f2-defect-fixes` first (the ballot must print).

## Open questions / risks

- Corpus quality drives the number; ≥5/class is the floor and the margin absorbs recording noise (the margin is the founder's decision at re-baseline time).
- The TTS stand-in corpus is "unnaturally clean" (`STATUS.md:351-353`) — the F2 number is the first real one and may differ materially; recorded, never gated.
- A sub-0.80 verdict is not a failure: it re-baselines or records the target as met-only-if-cleared — nothing in this aspect gates.