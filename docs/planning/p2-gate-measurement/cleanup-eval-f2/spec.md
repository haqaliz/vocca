# Spec: cleanup-eval-f2

**Aspect of:** p2-gate-measurement · **PRD ref:** M4, execution order step 5 · **Date:** 2026-09-01

## Problem slice and user outcome

The cleanup eval harness scores a stand-in corpus in CI; the P1 gate's number comes
from a real held-out set the founder records. F2 is ownerless beyond SMOKE step 73
(`STATUS.md:362-364`). Outcome: the F2 corpus exists on the founder's machine (≥40
utterances, ≥5 per class, never in the repo), the ballot runs, the verdict is recorded
against the 0.80 target, and `ProvisionalCleanupTargets` re-baselines via the
founder-signed procedure.

## In-scope

- Founder recording session: ≥40 utterances, ≥5 per class (the six
  `Tests/CleanupPairs/` classes), saved as `<name>.wav / .clean.txt / .class.txt` +
  `dictionary.json` under `~/Vocca/f2-pairs/` (on-disk only, never committed).
- First `VOCCA_CLEANUP_EVAL` run produces the ballot; the founder's blind preference
  answers fill `answers.tsv`.
- Second run: per-pair verdicts, `preference=NN.N%`, per-class tallies, the
  `RECORDED, not gated` line vs `CleanupRealRunTargets.preferenceMinimum` (0.80).
- The re-baseline: measure → margin (founder decision) → founder-signed row in
  `tolerances_20260815.md` → land in exactly one file (`ProvisionalCleanupTargets.swift`)
  — or record the 0.80 target as met without a code change if the number clears.
- Fix every defect surfaced (RED→GREEN, floor holds, M5 escalation rule).

## Out-of-scope

- LLM cleanup quality measurement (C6 explicitly claims nothing there;
  `STATUS.md:406-408`).
- The dictionary store's own behavior (shipped; only the corpus uses it).

## Acceptance criteria (testable)

- Corpus complete: ≥40 pairs, ≥5 per class, named per step 73's convention; the
  directory's existence and provenance recorded in the smoke step's note.
- Ballot produced and answered (blindness preserved — the judge never sees labels).
- Verdict row recorded against 0.80; the founder-signed procedure's chain followed in
  full; the single-source scan stays green.
- Any defect fix: RED→GREEN, floor 1731 holds.

## Dependencies and sequencing

- The recording (the long pole) overlaps aspects 2–4; the ballot + verdict run last,
  after the corpus is complete.
- The eval's `.wav` transcription uses the real Parakeet engine — requires the model
  from `provision-and-verify`.

## Open questions / risks

- Corpus quality drives the number; ≥5/class is the floor and the margin absorbs
  recording noise (the margin is the founder's decision at re-baseline time).
- The TTS stand-in corpus is "unnaturally clean" (`STATUS.md:351-353`) — the F2 number
  is the first real one and may differ materially; recorded, never gated.