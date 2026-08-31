# Spec: injection-matrix

**Aspect of:** p2-gate-measurement · **PRD ref:** M2, N1, execution order step 3 · **Date:** 2026-09-01

## Problem slice and user outcome

The matrix, its harness and its rows exist; the matrix has never been run — "the ≥95%
first-method-success number does not exist" (`STATUS.md:670-673`), and 8 of 22 bundle
ids are guessed (`SMOKE_CHECKLIST.md:1727`). Outcome: the first measured baseline row,
zero bundle-id mismatches on the founder's machine, and the strategy-memory behaviors
(re-probe, promotion) observed with real apps for the first time.

## In-scope

- `Scripts/injection-matrix.sh --verify-bundle-ids` on the founder's machine: zero
  mismatches; the 8 guessed ids (Slack, Pages, Notion, iTerm2, Ghostty, IntelliJ, Zed,
  1Password) confirmed or corrected in the harness/seeds, re-run clean (PRD N1).
- Fresh-memory state: delete `~/Library/Application Support/Vocca/strategies.json`,
  relaunch, `--dry-run`, then the tracked baseline run (step 88).
- Execute and record steps 87–93:
  - 87 — baseline calibration (the tracked table's first row).
  - 88 — tracked run: ≥19 of 20 deliverable rows at first-method-success (bytes **and**
    the log naming the expected rung as landing; fallback delivery is a miss); both
    refusal rows refuse.
  - 89 — seeded-hostile first run (Slack + Google Docs): log names `.clipboardPaste`
    first, never `.accessibility`.
  - 90 — re-probe after the 604 800 s window (or by hand-edited strategy): exactly one
    `.accessibility` attempt then the clipboard landing.
  - 91 — promotion: AX lands read-back-verified, `learnedAllowlist` true, the next
    dictation starts at the accessibility rung.
  - 92 — Secure Input + memory: `attempted: []`, password copy, `strategies.json` gains
    nothing.
  - 93 — tracked table row appended (first row).
- Fix every defect surfaced (RED→GREEN, floor holds, M5 escalation rule).

## Out-of-scope

- Expanding the matrix beyond its 22 rows (that is C8's scope; the matrix is shipped).
- Clipboard-manager coexistence runs beyond what the script already does.
- The release (follow-on card).

## Acceptance criteria (testable)

- `--verify-bundle-ids`: zero mismatches; every guessed id confirmed or corrected; the
  authoring-machine note updated.
- Baseline row: ≥19/20 deliverable rows PASS by the operational definition
  (`SMOKE_CHECKLIST.md:1694-1702`); refusal rows refuse.
- Steps 89–92 rows recorded with their pass conditions; step 93's tracked-table row
  written.
- Any defect fix: RED→GREEN, floor 1731 holds.

## Dependencies and sequencing

- Requires `dictation-loop` (the matrix assumes the real loop works; the sentinel design
  makes a denied Automation grant read VOID, not a byte mismatch).
- The 7-day re-probe window is provisional and re-baselined by this aspect's step 90
  observation, recorded never gated.

## Open questions / risks

- `com.tinyspeck.slackmacgap` is a guess; the founder's machine may reveal the real id
  (or Slack absent — then the row is skipped/voided per the table's conventions).
- Apps absent from the founder's machine (8 uninstalled on the authoring box) become
  skipped rows, never failures — the tracked table's Skipped column exists for this.