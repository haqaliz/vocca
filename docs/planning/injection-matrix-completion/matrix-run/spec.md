# Spec: matrix-run

> Aspect of `injection-matrix-completion` (PRD rev 2026-09-09, M1-M5, R2-R5, R7).

## Problem slice

The matrix is at 10 of 20 deliverable rows with FMS not computable (`STATUS.md:61-107`).
This aspect executes the remaining rows on the installed v0.3.0 build, step 92, the
Notes/Mail re-probe, and produces the FMS tally + gate-leg verdict under the ratified
memory-ordered definition. Everything is installed (verified 2026-09-09: VSCode, Teams,
Discord, ChatGPT `/Applications/ChatGPT.app` → `com.openai.codex`, Obsidian, Safari,
GoogleDocs/Chrome, Messages, Firefox, Terminal, Warp; Ghostty/IntelliJ/Zed not installed).

## In scope

- **Run precondition checks:** `--verify-bundle-ids` exits 0 (0 mismatched); the installed
  Vocca app is **v0.3.0** (verified via the bundle's CFBundleShortVersionString); Vocca is
  running, armed, model prepared; Automation grants present for the target apps (a denied
  grant VOIDs per-row, that is the designed signal); `strategies.json` snapshot taken
  (`cat` → recorded in the run notes) — **memory stays active, no reset**.
- **R2 — the 11 remaining deliverable rows** (each ~30 s of dictation, one `--row` invocation
  per row, one JSONL line each):
  1. VSCode, 2. Teams, 3. Discord, 4. ChatGPT, 5. Obsidian, 6. Safari, 7. GoogleDocs
     (unrun) — 8. Messages, 9. Firefox (voided 2026-09-05 on the pre-`1985da6` harness;
     re-run on the aim-fixed harness) — 10. Terminal, 11. Warp (**driven from a
     non-target terminal**: Terminal's row from Warp, Warp's row from Terminal.app).
- **R3 — Notes + Mail re-probe:** the demotion re-probe windows open **2026-09-10**
  (`strategies.json` reprobeWindows). If the run date ≥ 2026-09-10: run both rows first,
  observe whether `.accessibility` is re-probed (it must be — the window has elapsed and the
  memory is one-shot re-probe eligible) and whether it lands or is demoted again. If the run
  date < 2026-09-10: record **not elapsed** and schedule the re-probe as the next-day first
  action; the unit's record carries the due date. Either way the observation is recorded,
  never forced.
- **R4 — step 92 (refusal rows):** Passwords + PasswordField. PASS = all four conditions
  (log `attempted: []`, failsafe shows the password-field copy, transcript present/copyable,
  `strategies.json` gained nothing). Recorded as `refusal` verdicts.
- **R5 — FMS tally + verdict:** FMS = bytes-matched deliveries whose landing rung was the
  first rung attempted (memory-ordered, per PRD M3, answered per-row by the founder from the
  log). Denominator = 17 installed deliverable rows. Expected-rung landings tallied
  separately as calibration. Verdict: the ≥19/20 bar is **structurally unreachable** (3
  permanent skips → ceiling 17/20); the verdict line names FMS over 17 + the ceiling + "not
  a gate pass".
- **R7 — dispositions:** step 89 (seeded-hostile first run: Google Docs half — decision:
  NOT executed on fresh memory, because a fresh-memory reset would wipe the Notes/Mail
  demotions and candidate windows mid-run; recorded with the reason. Slack half unrunnable
  while the row is Teams — recorded). Step 90/91 (re-probe/promotion observations: recorded
  elapsed / not-elapsed per window date; promotion candidates Xcode/Telegram/Chrome windows
  open ~2026-09-12 — not elapsed, recorded). Step 93 (tracked-table row) belongs to
  record-and-sync.

## Out of scope

- No `strategies.json` reset, no row-set edits, no app installs (ratified).
- No harness code changes here — the guard + FMS question ship in `harness-containment`
  first.
- No gate passes; no percentage quoted outside the record's denominator discipline.

## Acceptance criteria

1. Every one of the 17 installed deliverable rows has exactly one run-log JSONL line with a
   verdict of `pass`, `failed` (bytes or fallback), or `voided` (named reason) — no row
   without a machine artifact ("reported, not measured" is retired for these rows).
2. Step 92's two refusal rows record `refusal` verdicts with all four conditions verified
   and named in the run notes.
3. FMS computed over 17 with the memory-ordered definition; the tally line and the ceiling
   statement recorded verbatim in the run notes.
4. Notes/Mail re-probe observation recorded (elapsed-and-observed, or not-elapsed with the
   due date).
5. `--verify-bundle-ids` output and the installed-v0.3.0 check recorded as run
   preconditions.

## Dependencies & sequencing

- Depends on `harness-containment` (the guard makes Terminal/Warp re-runs honest; the
  landing-rung recording makes FMS computable).
- Founder-in-the-loop by design: the script cannot press ⌥Space or read the ladder log.

## Open questions / risks

- **Re-probe timing:** if the founder runs before 2026-09-10, Notes/Mail re-probe is
  not-due; the PRD M5 says "observed, not forced" — the record carries the due date and the
  re-probe runs next day (or is recorded as a follow-up).
- **A row may surface a harness defect** (M8 rule): fix test-first, continue; only an
  evidence-chain-invalidating defect stops the run.
- **Teams row note:** Teams was installed 2026-09-01 (root-owned); if it now refuses the
  ⌘A/⌘C Automation grant, the row VOIDs with "no Automation grant" — a recorded outcome,
  not a failure.