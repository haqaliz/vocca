# Spec: record-and-sync

> Aspect of `injection-matrix-completion` (PRD rev 2026-09-09, M4, M7, R5, R6, S1-S3).

## Problem slice

The run produces numbers; the repository's honesty surfaces must carry them with their
denominator discipline. Without this aspect the evidence would live only in
`~/Library/Application Support/Vocca/matrix-runs/` — outside the tree, invisible to the next
session and to CI's readers.

## In scope

- **R6a — tracked-table row (step 93, `SMOKE_CHECKLIST.md:2000-2009`):** append the v0.3.0
  row — release, date, rows-run/landed/voided/skipped counts, FMS (memory-ordered, over 17),
  expected-rung calibration, the ceiling statement, and the swap/skip notes (3 permanent
  skips; ChatGPT row bundle id `com.openai.codex` confirmed against `/Applications/ChatGPT.app`
  2026-09-09). History rows (v0.2.1, v0.1.0 ×2) untouched — no re-labeling.
- **R6b — STATUS.md entry (append-only, newest first):** one entry naming: the run date and
  build (v0.3.0), every row's verdict (or a per-row table — N1), step 92's four conditions,
  the Notes/Mail re-probe observation, the FMS tally line and the ≥19/20 ceiling verdict,
  the harness changes shipped test-first (self-capture guard + memory-ordered FMS question,
  RED→GREEN, floor 1930), step 89/90/91 dispositions, and the **NOT block** (no gate passes;
  no percentage outside the denominator discipline; Terminal/Warp voids re-run from non-target
  terminals; remaining un-run items named).
- **R6c — CLAUDE.md front-door sync:** the status block's matrix sentence updated to the new
  state (per the front-door rule: describe the state of the tree this file ships in).
- **R6d — floor re-read:** `Scripts/test-with-floor.sh`'s floor value re-read and cited
  (single-source discipline; do not trust 1930 from memory).
- **S1 — Slack seed:** `com.tinyspeck.slackmacgap` (`SMOKE_CHECKLIST.md:1940`) — attempt
  `plutil` confirmation; if Slack is not installed, record "unconfirmable (app not
  installed)" and leave the seed's status flagged.
- **S2 — unified-log live check:** offer (opt-in, recorded) the `session opened` +
  `delivery rung=…` live capture for one row as corroboration; the file chain stays
  load-bearing regardless.
- **S3 — skip notes:** the 3 skipped rows' bundle IDs recorded as guesses (never
  plutil-confirmed).

## Out of scope

- No gate claims, no re-labeling of historical tracked rows, no row-set edits.
- No changes to `ROADMAP.md` gate language or `CAPABILITY_ROADMAP.md` status prose beyond
  the CLAUDE.md front-door sync rule (the capability note amendment pattern, if any, stays
  inside STATUS).

## Acceptance criteria

1. A reader with no access to the run directory can reconstruct from the tree: every row's
   verdict, the FMS number with its denominator, the ceiling, and the four step-92
   conditions.
2. The tracked table has exactly one new row (v0.3.0), historical rows byte-unchanged.
3. `STATUS.md` entry cites the run-log path and the floor value; the NOT block names
   everything still unmeasured.
4. `CLAUDE.md` front door's matrix state paragraph matches the STATUS entry.

## Dependencies & sequencing

- Last aspect: consumes `matrix-run`'s run log + tally.
- Depends on `harness-containment` only through the run (not directly).

## Open questions / risks

- **FMS semantics literacy:** the record must state the memory-ordered definition next to
  the number, so a reader comparing against the older "expected-rung landing" prose in
  STATUS (2026-09-05 entries) cannot misread the two.
- **Void semantics:** a voided row (e.g. a second grant denial) is recorded with its reason;
  the NOT block must say voids are not passes.