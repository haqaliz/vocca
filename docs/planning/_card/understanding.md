# Understanding: injection-matrix-completion

> Phase 2 dig note. Source: `docs/planning/_card/issue.md` (vocca-next handoff 2026-09-09)
> + harness map + planning-record reconstruction (explore agents, 2026-09-09).

## What this work really is

Resume the P2 injection-matrix leg (C8 remainder, `ROADMAP.md:164`, `CAPABILITY_ROADMAP.md:219-234`)
to its recorded deliverable: **every row with a recorded rung or a named void, step 92 executed,
an honest gate-leg verdict** (`_card/issue.md`). Not a new capability — the harness
(`Scripts/injection-matrix.sh`, 696 lines), the evidence chain (`MatrixEvidence` vocabulary +
OSLog adapter + run-log JSONL), and strategy memory (`strategies.json`) all shipped and were
already used in three partial runs. The unit is resumable by record (`STATUS.md` injection-matrix
entries; tracked-table rows v0.1.0 ×2, v0.2.1).

## Row state (as of 2026-09-05 continuation, `STATUS.md:61-107`)

20 deliverable + 2 refusal rows (`injection-matrix.sh:92-115`):

- **Landed expected rung (4):** TextEdit `.accessibility`; Xcode, Telegram, Chrome `.clipboardPaste`
- **Delivered but missed (2):** Notes, Mail — bytes matched; `.accessibility` demoted by memory
  (re-probe window **2026-09-10** — tomorrow); demotion-honored miss, not defect
- **Voided, re-run needed (4):** Messages, Firefox — cold-launch harness defect, fixed test-first
  in `1985da6` (activation keys on bundle id, 10 s frontmost poll, VOID-not-fail otherwise);
  Terminal, Warp — **indistinguishable self-capture** (harness runs inside a terminal; its own
  scrollback satisfies the containment compare) → re-run from a **non-target terminal**
- **Unrun (7):** VSCode, Teams, Discord, ChatGPT, Obsidian, Safari, GoogleDocs
- **Permanent skips (3):** Ghostty, IntelliJ, Zed — not installed; no same-class swap yet;
  bundle IDs are guesses (never plutil-confirmed); **ceiling 17/20 vs ≥19/20 bar → structurally
  unreachable on this machine** (`STATUS.md:80-82`)
- **Refusal rows (2, step 92):** Passwords (`com.apple.Passwords`), PasswordField (Safari) —
  unexecuted; PASS = log records `attempted: []`, failsafe shows copy, transcript copyable,
  `strategies.json` gained nothing

## Affected areas

- `Scripts/injection-matrix.sh` — row table, run flow, verdicts, self-check, run-log JSONL
- `Tests/HarnessTests/InjectionMatrixHarnessTests.swift` + `MatrixHarnessSelfCheckTests.swift`
  — planted-violation pins; the missing **containment pin** is the unit's first test
- `Sources/VoccaCore/StrategyMemory/*`, `PersistentInjectionStrategyStore.swift` — the memory
  the matrix measures against; `strategies.json` deltas are per-row evidence
- `docs/SMOKE_CHECKLIST.md` §12 (steps 87–93, tracked table) — step numbering owns "step 92";
  harness has no step numbers
- `docs/STATUS.md` + tracked table — the record surface (append-only; floor 1930 per
  `test-with-floor.sh`, binding floor re-read at run time per record-and-sync discipline)

## Key ambiguities / decision points (from the docs' own flags)

- **D2 — FMS discipline for demotion-honored deliveries.** Notes/Mail bytes matched via
  clipboard after memory demoted accessibility. Recorded posture: "rung miss… not a defect"
  (counts against expected-rung landing). But the P2 gate says "first-method-success **with
  per-app strategy memory active**" (`ROADMAP.md:172`) — memory-ordered first method *was*
  clipboardPaste, and it succeeded. Which counting is FMS? (Interview question.)
- **D4 — the ceiling.** Swap Ghostty/IntelliJ/Zed for installed same-class apps (class column is
  the documented swap invariant, `injection-matrix.sh:77-78`) or record the 17/20 ceiling
  honestly. Swap depends on what's installed (checking).
- **D1 — step 89's Docs half** (fresh-memory run) vs protecting the steady-state run.
- **OQ1 — run target:** installed v0.2.1 build vs worktree dev build. Released build is the
  honest target; the tracked row names the release (v0.3.0 is current).
- **OQ2/D3 — re-probe/promotion windows** (step 90/91): Notes/Mail windows open 2026-09-10;
  step 91 promotion candidates (Xcode et al.) have 7-day windows from 2026-09-05 — not elapsed
  until 2026-09-12; record not-elapsed and proceed, or wait (founder's call).
- **Slack seed** `com.tinyspeck.slackmacgap` never plutil-confirmed (`SMOKE_CHECKLIST.md:1940`);
  step 89's Slack half unrunnable while the row is Teams.
- **Denominator inconsistency** in past docs ("18"/"20"/"17") — use the plan accounting:
  22 = 20 deliverable + 2 refusal; 3 skips → 17 installed; refusals excluded from FMS
  numerator and denominator.

## Honesty obligations (binding)

- No gate passes; **no injection-success percentage may be quoted** until the run completes.
- A skip/void is not a pass; Terminal/Warp are not passes.
- Every row needs a machine artifact (run-log JSONL line + founder's rung y/N answered from the
  log, `strategies.json` delta) — a row without one repeats the v0.1.0 "reported, not measured"
  state.
- The live unified-log check is opt-in (declined once); the file chain stays load-bearing.