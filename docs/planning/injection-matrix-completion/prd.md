# PRD: Injection Matrix Completion (resumption)

> **Revision 2026-09-09** — resumption of the unit concluded 2026-09-05 by founder decision
> (`docs/STATUS.md`, `injection-matrix-completion` entry). Source card:
> `docs/planning/_card/issue.md` (vocca-next handoff 2026-09-09). This revision supersedes the
> 2026-09-05 PRD's scope: the harness and evidence chain are shipped and proven; what remains is
> the run, its honest verdict, and one missing harness pin.

## Problem Statement

The P2 injection matrix (`ROADMAP.md:164`, C8, `CAPABILITY_ROADMAP.md:219-234`) is at
**10 of 20 deliverable rows** — 6 firmly recorded, 4 voided, 7 never run — and FMS is
**not computable**. The result: the P2 gate's injection leg (`ROADMAP.md:172`: ≥95%
first-method-success, 20-app matrix, strategy memory active) is blocked; **no
injection-success percentage may be quoted** (`STATUS.md:99-100`); and R1 ("AX silently
no-ops", fatal-trust risk, `ROADMAP.md:300`) has no measurement. Every remaining row is
installed and runnable on this machine (verified 2026-09-09), so the block is execution,
not capability. What happens if we don't build this: the tool ships with its core promise
— "types into any app" — measured on 6 of 20 apps, and the P2 gate's hardest leg stays
unmeasurable; users, not our matrix, would discover any silent-injection defect.

## Goals & Success Metrics

- **M1 — The run completes.** All **17 installed deliverable rows** run against the
  **installed v0.3.0 build** (ratified 2026-09-09), each with a recorded rung or a named
  void in the run-log JSONL (`~/Library/Application Support/Vocca/matrix-runs/<date>.jsonl`).
- **M2 — Step 92 executes** (`SMOKE_CHECKLIST.md:1977-1989`): Passwords + PasswordField rows,
  all four pass conditions — log records `attempted: []`; failsafe shows the password-field
  copy; transcript present and copyable; `strategies.json` gained nothing for the bundle ID.
- **M3 — FMS computed under the ratified definition.** **Memory-ordered first method**:
  a bytes-matched delivery via the first rung the memory chose counts as success; expected-rung
  landings are tallied separately as calibration. Numerator and denominator over the 17
  installed deliverable rows; refusals excluded from both; skips/voids are never passes.
- **M4 — The honest gate-leg verdict.** FMS over 17 with the **17/20 ceiling** named
  (Ghostty/IntelliJ/Zed not installed, no same-class swap available — verified), and the
  ≥19/20 bar recorded as **structurally unreachable on this machine** — a recorded outcome,
  never a pass or a failure.
- **M5 — Windows observed, not forced.** Notes/Mail re-probe (window opens **2026-09-10**,
  tomorrow) run as part of the run; step 91 promotion candidates' windows (~2026-09-12)
  recorded **not elapsed**; step 90/91 observations dispositioned in the record.
- **M6 — One harness pin ships test-first.** A **containment pin** asserting no row's capture
  can originate from the harness's own terminal (the Terminal/Warp void reason, `386f433`
  semantics) — RED before GREEN, floor 1930 never drops.
- **M7 — Recorded, honestly.** Tracked-table **v0.3.0 row** appended (step 93), `STATUS.md`
  entry, `CLAUDE.md` front-door sync.
- **M8 — Defects have a named rule, not a mood.** A harness/app defect discovered during the
  run is fixed **test-first, then the run continues** (the `1985da6` pattern — it happened
  mid-run in 2026-09-05 and was the right call). Only a defect that invalidates the evidence
  chain (run-log corruption, byte-compare false positive) stops the run; the affected rows are
  voided with the reason named, never silently re-run or dropped.

## User Personas & Scenarios

- **The founder (solo user).** Dictates into Notes/Mail/Chrome daily. Scenario: the matrix
  run is ~30 s of dictation per row; the verdicts and the gate-leg number must be
  comprehensible from the record alone.
- **A future external user / design partner.** The P2 gate requires ≥5 external users to
  confirm dictation parity (`ROADMAP.md:180`). This unit produces the injection number that
  leg depends on.
- **A future contributor.** The per-row evidence chain (run-log JSONL + `strategies.json`
  delta + founder rung answer) must let someone reconstruct any row's verdict from files
  alone — "reported, not measured" is the state this unit retires (`SMOKE_CHECKLIST.md:1905`).

## Requirements

### Must-have

- **R1 (harness-containment):** a CI-run pin (planted-violation style, as in
  `InjectionMatrixHarnessTests.swift`) asserting that when a terminal-class row's target
  terminal is the harness's own host terminal, the row **cannot record a PASS** — it must
  VOID with a named reason (self-capture), or refuse to run with the reason. Written first,
  RED→GREEN; the suite keeps floor 1930. **The RED shape is defined before implementation:**
  the pin's planted violation neutralizes the containment guard in a copy of the script and
  the self-check must fail against it — a pin that cannot be made RED is not a pin.
- **R2 (run):** the 11 remaining deliverable rows — VSCode, Teams, Discord, ChatGPT,
  Obsidian, Safari, GoogleDocs (unrun), Messages, Firefox (aim-fixed harness `1985da6`),
  Terminal, Warp (driven from a **non-target terminal**) — each with: run-log JSONL line,
  founder rung y/N answered from the unified-log/ladder evidence, `strategies.json` delta,
  and byte-compare result.
- **R3 (re-probe):** Notes + Mail re-run (window opens 2026-09-10) with the demotion
  expected to be re-probed; outcome recorded whether or not the rung flips.
- **R4 (step 92):** Passwords + PasswordField refusal rows per M2.
- **R5 (FMS + verdict):** FMS computed per M3 over the 17 installed rows; the ceiling and
  gate-leg verdict recorded per M4. **No percentage may be quoted outside the record's
  denominator discipline.**
- **R6 (record):** tracked-table v0.3.0 row, `STATUS.md` entry (append-only), `CLAUDE.md`
  sync, `SMOKE_CHECKLIST.md` table row updated.
- **R7 (dispositions):** step 89 (seeded-hostile: Google Docs half — fresh-memory vs
  steady-state decision; Slack half unrunnable while the row is Teams) and step 90/91
  window observations recorded with their reasons.

### Should-have

- **S1:** Slack seed `com.tinyspeck.slackmacgap` (`SMOKE_CHECKLIST.md:1940`) plutil-confirmed
  or explicitly recorded as unconfirmable (app not installed).
- **S2:** the unified-log live check (`session opened` + `delivery rung=…`) re-offered as
  opt-in corroboration per row; the file chain stays load-bearing either way.
- **S3:** the 3 skipped rows' bundle IDs recorded as **guesses** (never plutil-confirmed)
  in the tracked row's notes.

### Nice-to-have

- **N1:** a one-line per-row table in the STATUS entry (row | verdict | rung landed | bytes).

## Technical Considerations

- **Harness:** `Scripts/injection-matrix.sh` (696 lines) — rows at `:92-115`, flow at
  `:504-612`; no changes expected beyond the containment pin unless a run surfaces a defect
  (then: test-first, floor 1930).
- **Evidence chain:** run-log JSONL (`start_run_log`/`log_run_row`), `MatrixEvidence` unified-
  log lines (`Sources/VoccaCore/MatrixEvidence.swift`), `strategies.json` deltas
  (`PersistentInjectionStrategyStore.swift`, byte-stable `.sortedKeys` output).
- **Run target:** installed v0.3.0 build (ratified). Precondition: the installed app's
  version is verified before the run; the tracked row names v0.3.0.
- **Bundle-ID verification is a run precondition.** `--verify-bundle-ids` executes first;
  a mismatch or an app that changed since 2026-09-05 (Teams, ChatGPT, system apps) is
  **adjudicated, never run blind** — confirm the running app's real ID before the row, and
  record the confirmation in the run log.
- **Non-target terminal for Terminal/Warp rows:** the harness must be driven from a terminal
  that is not the row's target (e.g. the other of Terminal/Warp, or the worktree's own shell
  running in a non-target app). The containment pin makes a self-capture PASS impossible.
- **Test discipline:** every code change RED→GREEN; suite run via `Scripts/test-with-floor.sh`
  (floor 1930 — re-read from the script at record time, single-source discipline); CI runs
  the harness's `--self-check` and planted-violation tests; the run itself is manual
  (window server, Automation grants, mic, pasteboard).
- **Memory state:** `strategies.json` currently holds Notes/Mail `.accessibility` demotions
  (re-probe 2026-09-10) and Xcode/Telegram/Chrome clipboard-success promotion-candidate
  windows. The run measures **with memory active** — no reset (that is step 89's fresh-memory
  question, dispositioned separately, never folded into the steady-state run).

## Risks & Open Questions

- **The ceiling is not closable here.** 17/20 vs ≥19/20 is a *named outcome* — never dressed
  as a pass or failure. If the founder later installs same-class apps (iTerm2, a JetBrains
  IDE, Zed), the row set becomes 20 and the bar reachable; that is a future unit or founder
  decision, out of scope here.
- **FMS semantics changed (ratified).** The memory-ordered definition differs from the
  recorded "expected-rung landing" posture; the PRD and record must say so explicitly so the
  number is never misread against `STATUS.md`'s earlier wording.
- **Terminal/Warp self-capture:** if the containment pin cannot be made deterministic
  headlessly (the harness's host-terminal detection), the fallback is a documented procedural
  guard (run from a non-target terminal) *plus* the pin asserting the void, not the pass.
- **Bundle-ID drift:** `--verify-bundle-ids` runs first; an unverified ID is adjudicated
  before its row runs (per Technical Considerations). If the installed app genuinely changed
  (e.g. Teams), the row's bundle ID is updated **test-first** against the harness's
  planted-violation pins, and the change recorded.
- **ChatGPT row:** bundle id `com.openai.codex` confirmed against the installed
  `/Applications/ChatGPT.app` (2026-09-09) — resolved, recorded here for the run plan.
- **Denominator history:** prior docs cite 18/20/17 inconsistently; this unit uses the plan
  accounting (22 = 20 deliverable + 2 refusal; 17 installed; refusals excluded).
- **Unified-log live check** was declined once (opt-in, S2); no dependency on it.

## Out of Scope

- **No gate passes claimed** — this unit produces evidence and a verdict, never a green gate.
- **No row-set redefinition, no app installs** (ratified 2026-09-09).
- **No strategy-memory code changes** unless a run surfaces a defect (then test-first).
- **No latency work, no P3 work, no external-users leg** — those are separate units.
- **No re-baselining of `tolerances_*` or cleanup targets.**

---

## Aspect decomposition

| Aspect | Boundary |
|--------|----------|
| `harness-containment` | The containment pin (test-first) + any harness change needed to make self-capture unrecordable as a PASS; CI-safe. |
| `matrix-run` | The run itself: 11 deliverable rows, Notes/Mail re-probe, step 92, FMS tally, verdict, step 89/90/91 dispositions. |
| `record-and-sync` | Tracked-table v0.3.0 row, STATUS entry, CLAUDE.md sync, SMOKE table update, floor re-read. |