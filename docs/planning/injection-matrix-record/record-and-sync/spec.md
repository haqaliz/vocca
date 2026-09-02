# Spec: record-and-sync

**Aspect of:** `injection-matrix-record` (PRD M6 + S2) · **Date:** 2026-09-02

## Problem slice

The unit's records: the tracked table's first measured row, the house STATUS entry with its
honesty block, the CLAUDE.md front-door sync, and the citation-drift fixes this unit touches.
Template: `p2-gate-measurement/record-and-sync/{spec,plan}.md`.

## In scope

- The tracked table (`SMOKE_CHECKLIST.md:1898-1905`) gains the step-88 row: `Release | Date |
  Rows run | Skipped | Voided | FMS | Notes` — FMS recorded or explicitly **not closeable on
  this machine**, with the swap list, the evidence citations (run-log path, log-window), and
  steps 89-91's not-due notes.
- The harness table's ID-source column and the 22-row table updated with the six swaps (same
  discipline as the baseline's iTerm2→Warp / Slack→Teams record, `SMOKE_CHECKLIST.md:1755-1778`).
- `docs/STATUS.md` gains the unit entry, newest first, in the house voice — including the
  "**What this unit is NOT, and must not be claimed:**" block (no gate passed, no tolerance
  re-baselined, whisper/F2/external-users untouched).
- `CLAUDE.md`'s front door synced to the tree this branch ships in; the test floor re-recorded
  if it moved.
- S2: citation drift corrected only where this unit touches it (the tracked table's old
  1877-1879 citations in this unit's own docs; nothing else).

## Out of scope

- Rewriting history: STATUS.md is append-only; the v0.1.0 "unrecorded" row stays as written.
- Any number presented as a gate pass.

## Acceptance

- C1: the tracked table's measured row exists with every column filled, citing its run-log
  path and log window.
- C2: STATUS.md entry follows the house template (what landed, what was measured, honesty
  block) and every claim cites its run or its file.
- C3: the floor check runs green after the docs commit
  (`Scripts/test-with-floor.sh` — the single-source scans are part of the suite).
- C4: the CLAUDE.md status paragraphs describe the tree this branch ships in; no stale claim
  survives.

## Dependencies & sequencing

- Last aspect: requires `matrix-run`'s executed observations. Docs-only, but the floor check
  still runs (`p2-gate-measurement/record-and-sync/plan_20260901.md:7-9`).
- Checkpoint: present the STATUS.md entry draft to the founder before the final commit — the
  honesty block is the founder's record (house rule, same plan:90-91).

## Open questions

- None.