# Spec: matrix-run

**Aspect of:** `injection-matrix-record` (PRD M3 + M4 + M5) · **Date:** 2026-09-02

## Problem slice

Execute the already-written acceptance — `SMOKE_CHECKLIST.md` §12 steps 87, 88, 92 — on the
founder's machine, with the evidence slice landed, and produce the tracked table's first
measured row. This aspect is founder-machine execution, not code: the harness cannot press
⌥Space or guess a rung (`Scripts/injection-matrix.sh:24-30`).

## In scope

- **Step 87 baseline:** `--verify-bundle-ids` to zero mismatches; six same-class swaps for the
  missing apps (Pages, Notion, Ghostty, IntelliJ, Zed, 1Password); fresh memory
  (delete `~/Library/Application Support/Vocca/strategies.json`, relaunch); `--dry-run` to
  confirm installed rows; full matrix; per-row: rung named in the log, bytes matched, surprises.
  The run's observations re-baseline the expected-rung column — never the reverse
  (`SMOKE_CHECKLIST.md:87`).
- **Step 88 tracked run:** steady-state memory (not freshly reset); ≥19 of 20 deliverable rows
  first-method; both refusal rows refuse; every installed row's observation backed by evidence:
  `log show --predicate 'subsystem == "dev.vocca.Vocca"'` lines + the harness run log (M2) +
  `strategies.json` where a strategy changed. Fewer than 19/20 → recorded, never a silent pass;
  the per-row misses are the work list.
- **Step 92 Secure Input:** refusal observed with memory active — log records `attempted: []`,
  failsafe shows the password-field copy, transcript recoverable, `strategies.json` gains
  nothing for the bundle id.
- **Steps 89-91 disposition:** recorded as not-due/unrunnable with reasons — 89's Slack half is
  blocked while the row is Teams (swapped 2026-09-01); 90/91's 7-day windows have not elapsed
  since the 2026-09-01 baseline (record `reprobeWindowSeconds`'s value beside the row per step
  90). A documented outcome, neither pass nor fail (`matrix-smoke/plan_20260827.md:195-197`).
- **Swap discipline (OQ1):** same class, installed, not already a row, chosen from `--dry-run`
  output; recorded in the harness table and the checklist's ID-source column, exactly like the
  baseline's iTerm2→Warp and Slack→Teams swaps. Candidate classes: Pages (native AppKit) →
  e.g. Freeform/Preview; Notion (Electron) → any installed non-row Electron app; Ghostty
  (terminal) → e.g. iTerm2; IntelliJ (Java/AWT) → any installed JVM app, else skip; Zed (native
  non-AppKit) → any installed non-AppKit native editor, else skip; 1Password (known-hostile) →
  step 92 runs via the PasswordField row if no password manager is installed.

## Out of scope

- Any gate claim or tolerance re-baseline (recorded, never gated — PRD X7 discipline).
- Fixing ladder behavior to reach 19/20: a miss is recorded and becomes the work list; the
  stopping rule is PRD R1 (`injection-matrix/plan_20260901.md:90-95` precedent: record, do NOT
  stop the unit, the founder decides at the gate).
- Whisper WER (step 19), F2 eval, external users, releases.

## Acceptance

- B1: `--verify-bundle-ids` reports zero mismatches after the swaps.
- B2: every installed row has a recorded observation with machine evidence (log lines + run log
  file); no row repeats the v0.1.0 "reported, not measured" state
  (`SMOKE_CHECKLIST.md:1905`).
- B3: step 88's tally and per-row notes are recorded, FMS computed over the deliverable rows
  actually run, skips/voids named ("a matrix run with many of either is not a matrix run",
  `SMOKE_CHECKLIST.md:1726-1728`).
- B4: step 92's four observations all hold (attempted `[]`, failsafe copy, recoverable
  transcript, nothing learned).
- B5: steps 89-91 recorded as not-due/unrunnable with the window value and the Teams-swap
  reason cited.

## Dependencies & sequencing

- Requires the `evidence-logging` aspect landed and the app rebuilt with it.
- Founder-machine prerequisites: Accessibility + Microphone grants live, model prepared,
  hotkey working (the checklist's own precondition discipline).

## Open questions

- None blocking. Swap selections finalize at `--dry-run` time from what is actually installed.