# PRD: p2-gate-measurement

**Date:** 2026-09-01 · **Phase:** P2 (the latency + injection gate path) · **Unit type:** measurement + first-execution + defect fixes
**Source:** `docs/planning/_card/issue.md` + `docs/planning/_card/understanding.md`

---

## Problem Statement

Every capability C1–C8 is shipped — the mechanism is complete — but **no product number
exists and no gate can clear**: the dictation loop has never delivered text end to end
(`docs/SMOKE_CHECKLIST.md:1067-1076`), the injection matrix has never been run — "the
≥95% first-method-success number does not exist" (`docs/STATUS.md:670-673`) — and the
latency p50/p95 are provisional targets in one table, unmeasured (`docs/STATUS.md:283-286`).
The P0, P1 and P2 gates (`docs/ROADMAP.md:100, 142, 176`) are all uncleared, C9 is
guardrail-blocked until the P2 gate passes (`docs/technical/CAPABILITY_ROADMAP.md:369`;
`docs/ROADMAP.md:180`), and the next installable release waits on `SMOKE_CHECKLIST.md`
steps 62–68 (`docs/STATUS.md:774`). The acceptance tests for this unit are **already
written** — they are the smoke checklist's gate-critical first-execution steps. This unit
executes them, fixes what they surface (test-first), and records the first measured
numbers through the founder-signed re-baseline procedure.

## Goals & Success Metrics

1. **The dictation loop's first real execution passes** — `SMOKE_CHECKLIST.md` steps
   62–68: a ~10 s utterance lands byte-for-byte (cleaned-by-rules == raw for a clean
   phrase) in Notes and TextEdit; Secure Input never lets a session start over a
   password field; Esc discards during RECORDING and TRANSCRIBING; the shortest-session
   row returns to IDLE with no injector call; the model-unavailable row shows the
   `.modelUnavailable` notice with the mic never lighting; the toggle triggers and
   backstops behave; 20 cycles end with zero loss and no crash. **Measured by:** the
   step rows recorded in `SMOKE_CHECKLIST.md`, each with its pass condition met.
2. **The injection matrix baseline is recorded** — `SMOKE_CHECKLIST.md` steps 87–93:
   `Scripts/injection-matrix.sh --verify-bundle-ids` clean on the founder's machine (the
   8 guessed bundle ids confirmed or corrected), `--dry-run` clean, then the tracked
   baseline at **≥19 of 20 deliverable rows** at first-method-success (bytes **and** the
   log naming the expected rung as landing, `SMOKE_CHECKLIST.md:1694-1702`), with the
   re-probe (90) and promotion (91) rows observed. **Measured by:** the tracked table's
   first row (`SMOKE_CHECKLIST.md:1877-1879`), the guess column resolved.
3. **The env-gated real runs produce their first measured numbers** — WER for both
   engines + whisper's streamed cycle and short-audio rows (step 19), the latency
   benchmark's per-span p50/p95 with warm-start ratio and `.rewarm` row (steps 71-72,
   77, 128), the streamed-vs-batch equivalence verdict (GO/NO-GO/VOID, steps 125-126),
   the Parakeet streaming WER row (step 124), and the manifest verification (step 102).
   **Measured by:** each run's printed rows; the provisional tolerances re-baselined via
   the founder-signed procedure — never silently relaxed, never gated.
4. **The F2 cleanup corpus exists and the eval produced its first preference number**
   (P1 gate leg) — ≥40 founder-recorded utterances, ≥5 per class, ballot run, verdict
   recorded against `ProvisionalCleanupTargets.preferenceMinimum` (0.80).
5. **Every defect found lands test-first** — each fix RED→GREEN on this branch; the
   suite floor (1731, `Scripts/test-with-floor.sh:1392`) never drops; the branch stays
   green after every task.
6. **The record is complete** — measured-values rows in the five `tolerances_*.md`
   files, `STATUS.md` entry, `SMOKE_CHECKLIST.md` tracked-table rows, `CLAUDE.md`
   front-door sync.

**Non-goals of the metrics:** no number becomes a *gate pass* in this unit. The P2 gate
needs three legs — latency targets, ≥95% matrix, **≥5 external users**
(`ROADMAP.md:176-180`) — and the external-users leg needs a release, which is a follow-on
card. A failing real run re-baselines (or, for equivalence, yields NO-GO, which only
blocks *claiming* the latency win — `docs/planning/speculative-asr/equivalence-measurement/tolerances_20260831.md:22-23`).

## User Personas & Scenarios

- **The founder (aliz)** — the only executor. Scenarios: the first real dictation into
  Notes; the first real matrix run across 22 apps; the first measured latency/warm-start
  bench; the F2 recording session; the founder-signed tolerance rows. This unit has no
  other persona — it is the product's first contact with reality.
- **The future external user** — served indirectly: this unit's measured numbers and
  fixes are what the P2 gate's parity claim and the first installable release are built
  on.

## Requirements

### Must-have

- **M1 — Dictation-loop first execution (steps 62–68).** All seven rows executed and
  recorded on the founder's machine with grants live and the model present and prepared;
  every pass condition met or explicitly recorded as "not performed" with the shipped
  reason (step 47's convention), never an invented criterion (`SMOKE_CHECKLIST.md:1075-1076`).
- **M2 — Matrix baseline (steps 87–93).** Bundle-id verification (zero mismatches),
  dry-run, full baseline at ≥19/20 deliverable rows, the two refusal rows refusing, the
  re-probe and promotion rows observed, tracked-table first row written.
- **M3 — Env-gated real runs.** Both engines' WER suites (visible skip lifted),
  whisper's streamed cycle (step 19), the latency benchmark (steps 71-72) with warm-start
  (77) and re-warm (128), the equivalence verdict (125-126), Parakeet streaming WER (124),
  manifest verification (102). Every run's rows recorded; every tolerance re-baselined by
  the founder-signed procedure.
- **M4 — F2 cleanup corpus + eval.** ≥40 utterances, ≥5 per class, in
  `~/Vocca/f2-pairs/` (never in repo); ballot produced; verdict recorded against the 0.80
  target; the F2 procedure's measure → margin → founder-signed → land-in-one-file chain
  followed (`tolerances_20260815.md:28-41`).
- **M5 — Defect fixes, test-first.** Every defect **surfaced by the M1–M4 runs** — a
  step failing its pass condition, a harness/script breaking on the founder's machine,
  a digest mismatch, a step that cannot be performed as written — is fixed RED→GREEN
  with a regression test; the fix never lowers the floor; a fix needing a PRD-level
  decision or a seam-contract change is escalated as its own card instead. Observations
  made *while* running but not caused by a run (adjacent improvements, preferences) are
  not defects and go in the record, not the branch.
- **M6 — The record.** `STATUS.md` entry; `SMOKE_CHECKLIST.md` tracked tables updated
  (matrix row, equivalence row, latency rows); `CLAUDE.md` front-door status synced;
  `docs/planning/p2-gate-measurement/` artifacts committed.

### Should-have

- **S1 — Smoke-checklist citation drift fixed.** `SMOKE_CHECKLIST.md`'s stale
  `AppBootstrap.swift` line citations (e.g. `setActiveMode` at `:700-719` vs actual
  `:1821`) and the stale step-67 preamble (the Settings → General activation-mode switch
  shipped 2026-08-26, `STATUS.md:534-542`) corrected where this unit touches them.
- **S2 — Whisper manifest provenance resolved.** Step 102's verification runs the
  shipped digests against provisioned bytes for the first time; if a digest fails, the
  corrected digest lands with its provenance recorded (`STATUS.md:820-825`).

### Nice-to-have

- **N1 — The 8 guessed bundle ids resolved.** Each confirmed or corrected in
  `SeededHostileApps` / the harness seed list on the founder's machine, with
  `--verify-bundle-ids` re-run clean.

## Technical Considerations

- **Phase and placement:** P2 — the gate path, not a build capability; C9+ stays
  guardrail-blocked (`CAPABILITY_ROADMAP.md:369`). Touches the whole loop — capture, ASR
  (both engines), cleanup, injection, widget — for its first real exercise. Local-only;
  the zero-network invariant and `ModelHub.offlineMode` are untouched; nothing leaves the
  machine (the F2 corpus is on-disk, never uploaded).
- **Execution surface:** all real runs are env-gated (`VOCCA_MODEL_DIR`,
  `VOCCA_LATENCY_BENCH`, `VOCCA_CLEANUP_EVAL`) and executed by nothing in CI — visible
  `XCTSkip` is the CI state; the founder's machine is the only execution environment.
  Provisioning first: `Scripts/provision-asr-fixtures.sh` prints the `VOCCA_MODEL_DIR`
  value (Parakeet: 4 `.mlmodelc` + `config.json` + vocab; whisper: GGUF tiers).
- **Headless regression bar:** `Scripts/test-with-floor.sh` (floor 1731) after every
  task; filter syntax `swift test --filter <Class>`; the suite is a Swift 6 package.
- **Re-baseline discipline:** numbers record, never gate. Single-source scans
  (`SwiftSourceScanner.swift:27-29`) fail on a duplicated constant; a re-baseline edits
  exactly the named file plus a dated founder-signed row in the matching
  `tolerances_*.md`. The margin is the founder's decision, recorded in the step's note.
- **Privacy/latency budgets:** latency numbers are measured and recorded against the
  provisional p50 400 ms / p95 800 ms table (`LatencyBenchmarkTests.swift:926,928`) — no
  regression gate on real numbers in CI, and this unit adds none.

### Execution order (sequencing guidance, not commitments)

1. **Provision + verify** — `Scripts/provision-asr-fixtures.sh` (both engines), then the
   manifest verification run (step 102); a digest failure is the first fix, before any
   dictation.
2. **Dictation loop** (steps 62–68) — the spine; everything downstream assumes a real
   loop. Day 1 of the 7-day gate log starts here.
3. **Matrix baseline** (steps 87–93) — needs the loop working.
4. **Env-gated real runs** — WER both engines + whisper streamed cycle (step 19),
   latency bench (71-72), warm-start (77), equivalence (125-126), Parakeet streaming WER
   (124), re-warm (128).
5. **F2 cleanup corpus + eval** (step 73) — the recording (**the long pole**, ≥40
   utterances ≈ one focused session) can overlap steps 2–4; the ballot + verdict run
   last.
6. **Record + sync** — `tolerances_*.md` measured rows, `STATUS.md`, `SMOKE_CHECKLIST.md`
   tracked tables, `CLAUDE.md` front door.

The unit spans several founder machine sessions; steps 2–4 are each one session, step 5's
recording is one, and step 6 is one. Session counts are guidance, not gates.

## Risks & Open Questions

- **R1 (high, expected) — first-execution defects.** Every prior first execution found
  defects CI cannot catch (short-press 0.3 s, `STATUS.md:694-713`; local-dev-launch ×3,
  `STATUS.md:474-495`; release symlink, `STATUS.md:725-760`). Mitigation: M5 (fix
  anything, test-first), escalation rule for PRD-level fixes. This is the roadmap's R1/R3
  measurement half: unmeasured injection and latency are the risk until these runs land.
- **R2 — whisper's never-executed path.** No whisper model has ever transcribed
  (`SMOKE_CHECKLIST.md:2025`); tolerances are seeded from Parakeet's table
  (`STATUS.md:174-179`). The streamed cycle may reveal short-audio or cost surprises;
  recorded, never gated.
- **R3 — manifest digest failure (S2).** The whisper manifests' "verified digests" lack
  provenance (`STATUS.md:820-825`); step 102 exercises them for the first time. A failure
  is a defect this unit fixes, not a blocker.
- **R4 — F2 corpus quality.** The preference number is only as good as the corpus;
  ≥5/class is the floor, and the margin decision absorbs recording noise
  (`tolerances_20260815.md:28-41`).
- **OQ1 — Re-baseline margins.** The margin at each founder-signed re-baseline is a
  founder decision at the time, recorded in the step's note.
- **OQ2 — A blown provisional bound.** If measured latency/matrix numbers miss the
  provisional tables, the numbers are recorded and the founder decides at the gate —
  nothing in this unit gates, fails the branch, or relaxes a bound silently.

## Out of Scope

- **The release** (DMG build, Homebrew tap publish, notarization) — follow-on card; it
  needs steps 62–68 and a Developer ID decision (`STATUS.md:762-774, 1267-1272`).
- **The ≥5 external users leg** of the P2 gate — needs the release.
- **C9 onward** — Kokoro, endpointing, dual mode, context, actions
  (`CAPABILITY_ROADMAP.md:228-317`); guardrail-blocked until the P2 gate passes.
- **New capability build of any kind** — the candidate set is closed at first-execution
  + defect fixes + measurement.
- **7-day daily-use gate execution** — the P0 gate's habit leg; the founder logs it daily
  outside this unit (only day 1's log is M1's step-62 context).
- **Cloud, telemetry, or egress of any kind** — the F2 corpus and all recordings stay on
  the machine.