# Spec — matrix-smoke (the measurement surface of injection-strategy-memory)

Feature: `injection-strategy-memory` · Aspect: `matrix-smoke` · Date: 2026-08-27
Requirements: PRD G1, R10, X7 (and X2's re-baseline) · `docs/planning/injection-strategy-memory/prd.md`
Source authority: `ROADMAP.md:89-91,164,172` · `CAPABILITY_ROADMAP.md:178-193` · `ARCHITECTURE.md:154,644` ·
`SMOKE_CHECKLIST.md:14-37` (the two rules), `:390-622` (the ladder matrix)

## Problem slice

The P2 gate and the P5 publication are judged on **≥95% first-method-success across a 20+
app matrix with per-app strategy memory active** (`ROADMAP.md:172`, `CAPABILITY_ROADMAP.md:189`),
and `ROADMAP.md:164` promises the matrix is "run as a semi-automated harness, tracked per
release". None of that exists as an artifact. The docs contradict each other on the size — "20-app
matrix" (`ROADMAP.md:172`) vs "past 20 apps" (`CAPABILITY_ROADMAP.md:183`) vs "20+ real apps"
(`ARCHITECTURE.md:644`) — and no document names the concrete P2 app set. The P0 matrix
(`ROADMAP.md:91`) is 14 named apps plus the Secure Input class; the smoke checklist's ladder
section (steps 22–35) runs them by hand with the fixed-phrase + `pbpaste` byte-compare discipline
(`SMOKE_CHECKLIST.md:398-413`). This aspect settles the list, expands the checklist to cover it
with memory-active expectations, and ships the semi-automated harness that turns the runs into
the founder's measured number. **The CI-testable half of the memory is the sibling aspects'
business; this aspect is the measurement surface.** The ≥95% number is produced on the founder's
machine, by the founder, per release — the `WarmStartRatio`/WER precedent: CI proves the
mechanism, the smoke rows are the only real execution (`PRD X7`).

## In-scope (map to PRD)

- **R10, whole.** The concrete 20+ app list — this aspect owns the decision (the docs
  contradict "20 apps"/"20+ apps" and name no P2 set); the expanded smoke-checklist rows, each
  naming its expected rung with memory ACTIVE (the matrix is run with memory active per
  `ROADMAP.md:172`), the memory-active expectations included; and the semi-automated harness
  script in `Scripts/` driving the fixed-phrase gesture + `pbpaste` byte-compare per row.
- **G1, the measurement surface.** The rows + harness are the founder's evidence for the ≥95%
  first-method-success figure. This aspect defines *what first-method-success means operationally*
  (below, §5) and the tracked per-release table that accumulates the number. The figure itself
  is **recorded, never gated in CI**.
- **X7, made explicit.** Nothing in this aspect runs in CI: no window server, no Automation
  grants, no microphone, no real pasteboard session. The harness's *self-check* half is the only
  part a machine can run.
- **X2, the re-baseline surface.** The re-probe window (~7 days, provisional, PRD R4) is
  re-baselined from the founder's real matrix run; the re-probe observation row (below) is where
  that measurement happens. The provisional constant stays in exactly one place (the
  `memory-order` aspect's code); this aspect's rows observe it, never copy it.

### Decision 1 — the concrete 22-row app list

The list starts from the P0 set (`ROADMAP.md:91`) and adds apps a solo founder (full-stack +
ML engineer, macOS) plausibly has, chosen to **span failure classes rather than to be
exhaustive** — the P0 selection principle, extended. The class coverage is the invariant; a row
whose app is missing from the founder's machine is **swapped for a same-class app**, never
dropped (the swap is recorded in the tracked table). Bundle IDs are verified at the baseline run
with `plutil` (`injection-adapters` phase E discipline — the seed's own three were confirmed
that way; nothing here is assumed).

| # | App | Class | Seeded | Expected rung, memory active (steady state) |
|---|-----|-------|--------|----------------------------------------------|
| 1 | Notes | native AppKit | yes (allowlist) | `.accessibility` |
| 2 | Mail | native AppKit | yes (allowlist) | `.accessibility` |
| 3 | TextEdit | native AppKit | yes (allowlist) | `.accessibility` |
| 4 | Xcode | native AppKit | no | `.accessibility` (promotion candidate) |
| 5 | Messages | native AppKit | no | `.accessibility` (promotion candidate) |
| 6 | Pages | native AppKit | no | `.accessibility` (promotion candidate; rich-text caveat) |
| 7 | VS Code | Electron | no | `.clipboardPaste` |
| 8 | Slack | Electron | **hostile** (R5) | `.clipboardPaste` |
| 9 | Discord | Electron | no | `.clipboardPaste` |
| 10 | Notion | Electron | no | `.clipboardPaste` |
| 11 | Obsidian | Electron | no | `.clipboardPaste` |
| 12 | Safari | browser | no | `.clipboardPaste` |
| 13 | Chrome | browser | no | `.clipboardPaste` |
| 14 | Google Docs (in Chrome) | browser, custom editor | **hostile** (R5) | `.clipboardPaste` |
| 15 | Firefox | browser | no | `.clipboardPaste` |
| 16 | Terminal | terminal | no | `.clipboardPaste` |
| 17 | iTerm2 | terminal | no | `.clipboardPaste` |
| 18 | Ghostty | terminal | no | `.clipboardPaste` |
| 19 | IntelliJ | Java/AWT | no | `.clipboardPaste` (promotion candidate) |
| 20 | Zed | native, non-AppKit | no | `.clipboardPaste` (promotion candidate) |
| 21 | 1Password | known-hostile | — | **no rung attempted** (Secure Input refusal) |
| 22 | Password field (Safari/Chrome) | known-hostile | — | **no rung attempted** (Secure Input refusal) |

Counts: **22 rows ≥ 20+** (settling the "20 apps"/"20+ apps" contradiction: the figure is
"20+"). Classes: native AppKit 6 (the 3 seeds + 3 promotion candidates), Electron 5, browsers 4,
terminals 3, Java/AWT 1, native-other 1, known-hostile 2. **Deliverable rows: 20** — rows 21–22
are refusal rows, not delivery rows (see Decision 5's denominator).

Why these additions (and not others): Xcode/Messages/Pages grow the AppKit class the seed already
blesses, so the learned-promotion path (PRD R6) has real room to prove itself; Notion/Obsidian
are the Electron class's second generation; Firefox adds a third browser engine (WebKit/Blink/
Gecko); Zed is the native-but-not-AppKit editor class, the current best probe of "does the AX
rung work anywhere it is tried, or only in AppKit text views"; IntelliJ stays the Java class. No
row was added for its brand; each was added for a class the P0 set under-samples.

**Open question carried to `memory-order` (not decided here):** Google Docs runs *inside*
Chrome, and the memory keys on the target app's bundle ID (`LadderInjector`'s `target.bundleID`)
— so the Docs row's strategy key is Chrome's. Seeding "Docs begins with AX excluded" (R5)
browser-wide would also exclude Chrome's plain fields, which may be AX-good. The `memory-order`
aspect must decide whether the seed is browser-wide or field-class-scoped; the matrix rows 14
(Docs) and 13 (Chrome plain field) are written so either answer is observable — Docs expects
clipboard while Chrome's plain field may legitimately differ.

### Decision 2 — one matrix run per release, tracked in a table

`CAPABILITY_ROADMAP.md:183` says "run as a semi-automated harness against each release"; this
aspect makes "per release" concrete: **the full 22-row matrix is run once per release** (the
release cadence is weeks, a full run is ~15–20 minutes with the harness doing the comparison, and
a rotated subset would make the tracked table's rows incomparable). The smoke-checklist section
gains a **tracked table** — one appended row per release: release, date, rows run / rows skipped,
first-method-success (Decision 5's math), and a notes column (swaps, voids, memory reset or not).
An unrun release is a failed step, per the checklist's own preamble ("an unrun step is a failed
step").

### Decision 3 — the harness shape: `Scripts/injection-matrix.sh`

For each row, the script: (a) verifies the app is installed (`open -Ra` exit code) and brings it
to front (`open -a`), (b) prints the row's expected rung and the field to click into, (c) **waits
for the founder to dictate** — the script cannot press the hotkey or drive the session, and it
must not pretend otherwise: the dictation needs the real tap, the real TCC grants, and a real
microphone, which is the whole reason this is a founder-machine script — (d) after the founder
signals, the script does select-all + copy through `System Events` (the terminal hosting the
script needs Automation grants for the target apps — a documented, founder-granted precondition;
the step-29 class of denial applies to the script's host too), (e) `pbpaste` byte-compares against
the fixed phrase, (f) prompts the founder to confirm the ladder's log named the expected rung,
and (g) tallies first-method-success. **The script automates the comparison; the dictation and
the rung observation are the founder's** — documented in the script header and in the checklist
rows. A `--dry-run` mode prints the row table and each row's install status without touching any
app; a `--self-check` mode validates the internal row table (≥20 rows, unique names, expected
rung from the closed vocabulary, hostile rows expect no rung) **and** greps each row name into
`SMOKE_CHECKLIST.md`, so the two artifacts cannot drift silently. The row table lives in the
script as data (the `SeededInjectionAllowlist` pattern); the checklist rows are written from it
in the same commit.

### Decision 4 — the re-probe observation row

PRD R4's re-probe is lazy and time-based (~7 days, provisional); a seeded-hostile app (Slack)
that has delivered via clipboard for N dictations spanning the window must, on the next
dictation, log **one** `.accessibility` re-probe attempt that fails and re-demotes with a fresh
window. The founder observes it in the ladder's log: the log names the re-probe attempt (the
`.accessibility` rung tried first, once, then the clipboard landing and the re-demotion). The
observation row (step 90) states: N ≥ 5 clipboard deliveries spanning ≥ the provisional window,
then the next dictation's log line is the evidence; a log with **no** re-probe attempt after the
window has elapsed is a failure of R4's decay schedule, not a pass. The window figure itself is
read from the `memory-order` code's one place and recorded beside the row — the measure → margin
→ founder-signed procedure, `tolerances_20260815.md` precedent.

### Decision 5 — the ≥95% math: first-method-success, operationally

Per row, the founder records the rung the ladder's log names as the first attempt **and** the
rung that landed. **First-method-success = the strategy's first (memory-chosen) rung landed the
insertion, byte-perfect.** Operationally, per row: PASS = the field holds the cleaned transcript
byte-identical **and** the log names the row's expected rung as the landing rung (for a
steady-state memory, expected rung == first rung). A row that *delivered* via a fallback rung
(the memory chose AX, AX failed, clipboard landed) is a **delivery without first-method success**
— a miss for the metric and a demote-on-fail signal for memory. The denominator is the
**deliverable rows (20)**; rows 21–22 (Secure Input refusals) are excluded from numerator and
denominator and recorded separately under the 0%-loss invariant (the transcript must be
copyable — the step-27 discipline). ≥95% = **≥19 of 20 deliverable rows** land first-method. The
tracked table accumulates the tally per release; the figure is recorded, never gated in CI.

## Out-of-scope boundaries

- **No memory code.** No `InjectionStrategyStore`, no order implementation, no recording, no
  seed data — all `core-memory`/`store-seam`/`memory-order` business.
- **No CI assertions on the number.** The ≥95% figure is founder-machine evidence (PRD: "CI
  proves the mechanism, not the number"). The harness's `--self-check`/`--dry-run` are the only
  CI-runnable halves, and wiring them into CI is not part of this aspect (noted as an option).
- **No Apps tab.** The settings surface is built *against* the calibrated matrix (sequencing
  below), not with it.
- **No renumbering or rewriting of steps 22–35.** The checklist is append-only ("When this file
  is wrong: add to it"); new rows take the next free numbers (87+).
- **No new failure classes beyond the row table.** The fixed phrase, the pass/fail shape, the
  byte-compare discipline and the two preamble rules are inherited, not re-invented.
- **No change to the memory's seed data or re-probe constants.** Those are `memory-order`'s;
  this aspect observes them.

## Acceptance criteria (testable)

1. **The list reaches 20+:** the checklist's matrix section names ≥20 deliverable rows plus the
   two refusal rows; the harness's `--self-check` asserts the same table (≥20 rows, unique,
   closed-vocabulary rungs) and exits non-zero on violation.
2. **The harness compiles and dry-runs headlessly:** `bash -n Scripts/injection-matrix.sh`
   passes; `Scripts/injection-matrix.sh --self-check` passes on a machine with **no** target apps
   installed (it must not require any app, any grant, or a window server); `--dry-run` prints the
   row table with per-row install status and exits 0.
3. **Rows are reviewable artifacts:** each new checklist row (87–93) follows the house shape —
   gesture, pass, failure — names its expected rung with memory active, and obeys both preamble
   rules (preconditions verified before negatives; pass criteria tighter than the failure they
   guard; a `.accessibility`-named row with nothing in the field is a bug, not a pass).
4. **The re-probe is observable:** step 90 documents exactly which log line is the evidence and
   what a missing re-probe attempt after the elapsed window means.
5. **The math is written down:** the tracked table's header states the FMS definition and the
   19-of-20 bar, so a recorded number cannot be a number nobody defined.
6. **The suite stays green:** `Scripts/test-with-floor.sh` passes untouched — this aspect
   changes no Swift.
7. **The Docs-in-Chrome key question is carried:** the spec's open question (browser-wide vs
   field-class seed) is recorded for `memory-order`, and rows 13/14 are written to make either
   answer observable.

## Dependencies & sequencing

- **After `memory-order`.** The rows name the rungs memory produces — an expected-rung column
  is meaningless before the memory exists to produce them. The baseline run (step 87) is
  additionally the first real execution of R5's seeds and R4's window, which is why this aspect
  lands last in the unit.
- **Before `apps-tab`** (per the review-gate recommendation): the Apps tab's health column
  (`typing directly` / `pasting` / `manual only`) is built against the **calibrated** matrix —
  the baseline run decides which apps actually reach `.accessibility`; building the tab's copy
  and expectations before the calibration risks a UI that describes rungs the matrix never
  observes.
- The checklist rows and the harness land in the same commit (single-source sync); nothing
  blocks on anything outside the unit.

## Open questions / risks

1. **Apps the founder may not have installed** (Pages, Obsidian, Notion, Firefox, Zed, Ghostty,
   IntelliJ). Each is swappable for a same-class app — the class coverage is the invariant, the
   brand is not — and the swap is recorded in the tracked table. The baseline run settles the
   actual installed set; the checklist rows name one canonical app per class plus a recorded
   alternative.
2. **Pages' rich text.** TextEdit needed ⌘⇧T because rich text reflows and defeats the byte
   compare; Pages has no plain-text mode and its autocorrect (smart quotes) could mutate the
   copy. The phrase contains no quote/apostrophe characters, so smart quotes cannot touch it, but
   if Pages' copy round-trip still mutates bytes, the row is swapped for another native AppKit
   app (Reminders, Bear) rather than weakened — a pass criterion looser than the failure it
   guards accepts the failure (rule 2).
3. **The Docs-in-Chrome seed scope** (above) — a real decision for `memory-order`, observable
   here.
4. **The re-probe window is provisional** and re-baselined from this aspect's step 90 — until
   then, a matrix run before the window elapses simply has no re-probe row to observe (recorded
   in the tracked table, not a pass or a fail).
5. **Terminal row rung.** A terminal's expected rung is `.clipboardPaste` by design (the shell
   swallows pastes cleanly; keystroke synthesis risks interpretation). If the baseline run shows
   the memory promoting a terminal, that is a finding to record — terminals are the one class
   where keystroke synthesis may actually be the better first rung — and the expected-rung column
   is calibrated at the baseline, not asserted in advance.