# Card: feat/unmeasured-numbers-sweep

> Inline brief — no GitHub issue exists. Source: `vocca-next` handoff, 2026-09-04.

## Brief

Execute the remaining env-gated real-run smoke steps and record the first measured
numbers through the founder-signed re-baseline procedure. This is the unexecuted
M3/M4 remainder of the landed `p2-gate-measurement` unit (merged 2026-09-01) —
the three "still unmeasured" surfaces named in `CLAUDE.md`: whisper's WER (GGUF
absent), F2 cleanup eval (not run), and the perceived-latency gate number.

Three surfaces, all env-gated, executed by nothing in CI (visible `XCTSkip` is the
CI state; the founder's machine is the only execution environment):

1. **Whisper WER + streamed cycle** (`SMOKE_CHECKLIST.md` step 19) — real WER,
   streamed-final == batch text-for-text, short-audio rows (0.2 s / 0.5 s / 1 s
   through both `transcribe` and `stream`), and the O(n²) cost row. Needs GGUF
   provisioning first via `Scripts/provision-asr-fixtures.sh`; manifest
   verification (step 102) exercises the whisper manifests' provenance-less
   digests against provisioned bytes for the first time (`p2-gate-measurement/prd.md`
   R3/S2).
2. **F2 cleanup corpus + eval** (step 73) — ≥40 founder-recorded utterances, ≥5
   per class across the six `Tests/CleanupPairs/` classes, saved as
   `<name>.wav / .clean.txt / .class.txt` + `dictionary.json` under `~/Vocca/f2-pairs/`
   (on-disk only, never committed). First `VOCCA_CLEANUP_EVAL` run produces the
   ballot; the founder's blind preference answers fill `answers.tsv`; the verdict is
   recorded against `ProvisionalCleanupTargets.preferenceMinimum` (0.80). The
   recording session is the long pole — start it first, overlap everything else.
3. **Latency record** (steps 71-72) — verify which per-span rows
   `p2-gate-measurement` already recorded, then record the perceived-latency
   composite (p50 ≤ 400 ms / p95 ≤ 800 ms) against the provisional table, measured
   over the 60 s fixture with the substitution stated beside the numbers
   (`SMOKE_CHECKLIST.md:1350-1358`), suppression state `not-suppressed` beside every
   row.

Acceptance:

- Every run's printed rows recorded in `SMOKE_CHECKLIST.md` beside its step number;
  visible skips lifted (a skip counts as executed only when the row says so).
- Every re-baseline follows measure → margin (founder decision) → founder-signed row
  in the matching `tolerances_*.md` → land in exactly one file; the single-source
  scans stay green. Never silently relaxed.
- The F2 corpus is complete (≥40 pairs, ≥5 per class), never in the repo, and the
  ballot preserves blindness (the judge never sees labels).
- Every defect the runs surface fixes test-first: RED→GREEN, suite floor 1755 never
  drops (`Scripts/test-with-floor.sh`); a fix needing a PRD-level decision or a
  seam-contract change escalates as its own card instead.
- `docs/STATUS.md` gains the unit's entry; `SMOKE_CHECKLIST.md` tracked tables and
  `CLAUDE.md` front door synced. No gate passes as a result of this unit — every
  number records, nothing gates.

Caveats:

- **Whisper has never transcribed anything** (`SMOKE_CHECKLIST.md:2025`); tolerances
  are seeded from Parakeet's table (`STATUS.md:174-179`) and a miss re-baselines via
  `tolerances_20260810.md`, never relaxes silently.
- **The F2 number may differ materially from the "unnaturally clean" TTS stand-in
  corpus** (`cleanup-eval-f2/spec.md:54-55`); recorded, never gated.
- **The speculative equivalence verdict is NO-GO** (recorded, 2026-09-01) — the
  latency-win claim stays blocked no matter what this sweep measures.
- **GGUF provisioning is the sweep's external dependency** — the model file is absent
  and must be downloaded/verified before any whisper row can run.
- **Latency rows already recorded by `p2-gate-measurement`** (asr p50 79-102 ms /
  p95 354 ms, warm-start 0.348×, re-warm 82-85 ms) must not be re-claimed as new;
  the sweep records what is missing, not what is done.