# PRD: injection-matrix-completion

**Date:** 2026-09-05 · **Phase:** P2 (the latency + injection gate path) · **Unit type:** measurement + first-execution + defect fixes
**Source:** `docs/planning/_card/issue.md` + `docs/planning/_card/understanding.md` (vocca-next handoff; founder's last pre-PH milestone)

---

## Problem Statement

The injection matrix's evidence chain is real but its measurement is incomplete: the
tracked table's row reads **not closeable** (`SMOKE_CHECKLIST.md:1992`) — baseline run 2
stopped at **1 of 18 deliverable rows** (Notes; byte mismatch recorded as step 19's matter,
accessibility rung demoted with a fresh re-probe window), with 17 rows + step 92 (Secure
Input refusals) remaining. The ≥95% FMS number is the P2 gate's matrix leg
(`ROADMAP.md:176-181`), recorded never gated, and it is the number the Product Hunt
launch narrative reads. The acceptance for this unit is already written — the smoke
checklist's steps 88-93 — and the harness (`Scripts/injection-matrix.sh`) plus the
evidence chain (`MatrixEvidence`, the ladder's delivery seam, the per-row JSONL run log,
`strategies.json`) are shipped. This unit executes the remaining rows on the founder's
machine, adjudicates byte-compare mismatches instead of chasing them, fixes test-first
any defect the run surfaces, and records the FMS tally.

## Goals & Success Metrics

1. **The tracked run completes on the founder's machine** — the 17 remaining deliverable
   rows + step 92 (Secure Input refusals) executed and recorded, each with a file-based
   artifact (a harness run-log JSONL line; `strategies.json` where a strategy changed).
   **Measured by:** the tracked table's v0.2.1 row (`SMOKE_CHECKLIST.md:1984-1992`)
   recording rows run / skipped / voided / FMS / notes.
2. **FMS computed with denominator discipline** — deliverable rows whose expected rung
   landed / deliverable rows actually run, skips and voids named; a "not closeable on this
   machine" outcome recorded as such, never dressed as a pass or a failure
   (`SMOKE_CHECKLIST.md:1986-1987`).
3. **Byte-compare mismatches adjudicated, never auto-counted** — each mismatch triaged
   against the engine's transcript (step 19's matter) vs a real injection failure; an
   `.accessibility` byte mismatch is a read-back-lying bug, not a fallback
   (`injection-matrix.sh:472-473`).
4. **Every defect the run surfaces lands test-first** — RED→GREEN, suite floor 1758 never
   drops (`Scripts/test-with-floor.sh:1444`); the branch stays green after every task.
5. **The record is complete** — `STATUS.md` entry, the tracked-table v0.2.1 row, `CLAUDE.md`
   front-door sync; steps 90-91's windows observed and recorded (elapsed or not), step 89
   dispositioned.

**Non-goal:** no number becomes a *gate pass*. The P2 gate needs latency targets + ≥95%
matrix + ≥5 external users (`ROADMAP.md:176-180`); this unit produces the matrix leg's
record, nothing more.

## User Personas & Scenarios

- **The founder (aliz)** — the only executor: runs the harness rows against installed
  apps (Notes, TextEdit, Mail, Telegram, ChatGPT, Passwords, Warp, Teams, browsers,
  terminals…), answers the per-row rung y/N, adjudicates byte mismatches, signs the record.
  The run is the last pre-PH milestone — the FMS number (or its honest not-closeable
  outcome) goes into the launch narrative.
- **The future external user** — served indirectly: the matrix number is what P2's
  injection-reliability claim is built on.

## Requirements

### Must-have

- **M1 — The remaining 17 deliverable rows run.** `Scripts/injection-matrix.sh` full run
  (or `--row` per row) on the founder's machine with the v0.2.1 build, each row recorded
  in the run log with bytes_matched + verdict + note; per-row PASS = bytes **and** the
  log naming the expected rung as the landing rung (founder y/N, `SMOKE_CHECKLIST.md:1806-1808`).
- **M2 — Step 92 (Secure Input refusals).** All four pass conditions observed and
  recorded: log `attempted: []`, the failsafe copy path, the transcript copyable, and
  `strategies.json` gained nothing.
- **M3 — FMS tally + tracked row.** FMS computed over the deliverable rows actually run
  with denominator discipline; the **v0.2.1 row appended** to the tracked table
  (`SMOKE_CHECKLIST.md:1989`, one row per release — the v0.2.0 row stays as recorded
  history, not amended), a "not closeable" outcome recorded as such
  (`understanding.md` of the prior unit: `_card/understanding.md:85-87`).
- **M4 — Adjudication.** Every byte-compare mismatch triaged: re-transcribe the fixture
  phrase through the real engine (step 19's WER machinery, `WhisperCppEngineWERTests`/
  `ParakeetEngineWERTests` with `VOCCA_MODEL_DIR`) and compare — a transcript mismatch is
  recorded as ASR's matter, not an injection failure; an `.accessibility` byte mismatch
  with a lying read-back is a defect (fix test-first).
- **M5 — Windows observed.** Step 90 (re-probe: ≥5 clipboard deliveries + 7-day window)
  and step 91 (promotion) recorded with their window state — elapsed or not-elapsed —
  and the daily-use accumulation started (it also feeds the P0 7-day gate log); step 89
  dispositioned per `STATUS.md:260-262` (Teams half unrunnable while the row is Teams).
- **M6 — Defect fixes, test-first.** Every defect surfaced by the M1-M5 runs — a harness/
  script break on the founder's machine, a row that cannot be performed as written, a
  lying read-back, a digest/evidence gap — is fixed RED→GREEN with a regression test; the
  fix never lowers the floor (1758); a fix needing a PRD-level decision or a seam-contract
  change escalates as its own card instead.
- **M7 — The record.** `STATUS.md` entry (honesty-block format); `SMOKE_CHECKLIST.md`
  tracked-table v0.2.1 row + step 88-92 notes; `CLAUDE.md` front-door sync (the matrix
  row's "not closeable" claim replaced by the measured outcome).

### Should-have

- **S1 — The unified-log evidence gets its first live check** if the founder consents
  (the live `log stream` check was declined in the prior unit — the file chain remains
  load-bearing either way; a consented check records the log lines beside the file chain).

### Nice-to-have

- **N1 — Step 89's Docs half** (seeded-hostile) executed if the window allows.

## Technical Considerations

- **Phase and placement:** P2 — the measurement half of make-or-break battle #2
  (injection reliability). C8's strategy memory is shipped (`ARCHITECTURE.md`); this unit
  measures what the ladder + memory do against real apps. Local-only; no cloud; the
  zero-network invariant is untouched.
- **Execution surface:** the matrix runs only on the founder's machine (real apps, real
  grants); CI covers the harness's headless half (self-check, bundle-id verification
  mechanism, evidence format). The v0.2.1 released build is the preferred run target
  (`issue.md:51-53`).
- **Headless regression bar:** `Scripts/test-with-floor.sh` (floor 1758) after every
  task; the suite is a Swift 6 package.
- **Evidence discipline:** every row's record cites the run-log line + `strategies.json`
  state; the unified-log lines are corroboration, not the load-bearing artifact, until S1
  is consented.

### Execution order (sequencing guidance, not commitments)

1. **Daily-use accumulation starts** (clipboard deliveries + P0 gate log) — parallel,
   feeds steps 90-91's windows.
2. **M6-style harness sanity + the control row** — `--dry-run` + **Notes re-run** (the
   control: it has a recorded prior outcome — byte mismatch, accessibility demoted with a
   fresh re-probe window, `SMOKE_CHECKLIST.md:1992` — so a changed outcome on v0.2.1 is
   itself evidence, and a harness break has a specific regression shape to pin RED→GREEN).
   The v0.2.0 tracked row stays as recorded history; the v0.2.1 row carries the
   completion (one row per release, step 93).
3. **M1 — the remaining 17 rows** — one session per app group (native AppKit, Electron,
   browsers, terminals, hostile).
4. **M2 — step 92** (Secure Input refusals).
5. **M4 — adjudication pass** over every byte mismatch.
6. **M3 — FMS tally + tracked-table row.**
7. **M5 — windows + step 89 disposition.**
8. **M7 — record + sync.**

Session counts are guidance, not gates.

## Risks & Open Questions

- **R1 (high, expected) — first-execution defects.** Every prior first execution found
  defects CI cannot catch (short-press, evidence-chain absence, cask pin). The run's
  control row (execution order step 2) is the early-warning pass; M6 fixes test-first.
- **R2 — FMS not-closeable on this machine.** 3 rows are uninstalled with no same-class
  swap; ≥19/20 may be structurally unreachable. Recorded as a named outcome, never as a
  pass or failure (`_card/understanding.md` of the prior unit: 85-87).
- **R3 — The live unified-log check.** The founder declined it once; S1 is opt-in.
- **R4 — Adjudication ambiguity.** No checklist step prescribes formal triage; M4 defines
  it (engine re-transcription comparison) so rows adjudicate consistently.
- **OQ1 — Run target.** v0.2.1's installed build vs the worktree's dev build — the released
  build is the honest target (the tracked row names the release).
- **OQ2 — Window timing.** If the 7-day re-probe/promotion windows aren't elapsed by the
  run, they record as not-elapsed and the tally proceeds — or the tally waits for them
  (founder's call at the time).

## Out of Scope

- **Notarization / Developer ID** — blocked, not purchased; separate runbook.
- **The P2 gate's third leg (≥5 external users)** — needs a release + users.
- **C9 onward** — Kokoro, endpointing, dual mode, context, actions
  (`CAPABILITY_ROADMAP.md:228-317`); guardrail-blocked until the P2 gate passes.
- **New capability build** — the candidate set is closed at execution + adjudication +
  defect fixes + record.
- **Any gate claim** — the P2 gate is judged outside this unit.
- **Cloud, telemetry, or egress** — the matrix runs local, artifacts stay on the machine.