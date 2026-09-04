# PRD: unmeasured-numbers-sweep

**Date:** 2026-09-04 · **Phase:** P2 (the latency + injection gate path) · **Unit type:** measurement + first-execution + defect fixes
**Source:** `docs/planning/_card/issue.md` + `docs/planning/_card/understanding.md` (vocca-next handoff, 2026-09-04)

---

## Problem Statement

The `p2-gate-measurement` unit landed its first measured numbers, but three "still
unmeasured" surfaces remain (`CLAUDE.md` 2026-09-01 status): **whisper's WER** (GGUF
absent — the engine is selectable in settings and honestly labelled unmeasured,
`CAPABILITY_ROADMAP.md:98-106`), **F2 cleanup eval** (not run — the P1 gate's ≥80%
number is still provisional, `ROADMAP.md:137`), and the **perceived-latency gate
number** (steps 71-72 ran, but step 72's deliverable is incomplete: no composite
key-up → text-on-screen p50/p95 against the 400/800 provisional table, no founder-
signed re-baseline, no substitution/machine statement beside the numbers,
`SMOKE_CHECKLIST.md:1350-1358`). The acceptance tests for this unit are **already
written** — they are the smoke checklist's env-gated first-execution steps. This unit
executes them, fixes what they surface (test-first), and records the first measured
numbers through the founder-signed re-baseline procedure. Recorded, never gated: no
gate passes as a result of this unit.

## Goals & Success Metrics

1. **Whisper's real WER + streamed cycle measured** — SMOKE 19 executed for whisper
   (six fixtures vs tolerances, streamed-final == batch text-for-text, short-audio
   0.2/0.5/1 s rows through both `transcribe` and `stream`, the O(n²) cost row),
   after provisioning **both tiers** (turbo + q5_0) and manifest verification (SMOKE
   102) against the provisioned bytes. **Measured by:** the step rows recorded in
   `SMOKE_CHECKLIST.md`; the whisper tolerance row in `tolerances_20260810.md`
   re-baselined via the founder-signed procedure.
2. **First whisper transcriptions land** — SMOKE 95 (tier download), 96/103 (first
   whisper transcription through the real engine, engine-attributed), 21 (whisper.cpp
   license sign-off). **Measured by:** the step rows.
3. **The F2 corpus exists and the eval produced its first preference number** — ≥40
   founder-recorded utterances, ≥5 per class across the six `Tests/CleanupPairs/`
   classes, in `~/Vocca/f2-pairs/` (never in repo), ballot → blind preference verdict
   against `ProvisionalCleanupTargets.preferenceMinimum` (0.80). The two known F2
   defects are fixed test-first before the run: the **ballot is never printed**
   (`printBallot` has no caller, no seed generation, `CleanupEvalHarnessTests.swift:835-855,
   459-463`) and the **raw-side convention omits `.raw.txt`** which discovery requires
   (`CleanupPairSuite.swift:91-95`). **Measured by:** the printed verdict rows
   (`preference=NN.N%`, per-class tallies, `RECORDED, not gated` vs 0.80).
4. **The latency step-72 deliverable is completed** — the real benchmark runner gains
   a **composite (total) span row** per cycle (test-first), steps 71-72 re-run, and the
   composite p50/p95 recorded against the provisional 400/800 table **with the 60 s
   fixture substitution stated, the machine and model version named, and the cleanup-
   span status recorded honestly** beside the numbers; the founder-signed re-baseline
   row lands in the latency tolerances file (`tolerances_20260825.md`), with
   `ProvisionalTolerances` untouched unless the founder signs a change. **Measured by:**
   the step-72 record complete per `SMOKE_CHECKLIST.md:1350-1358`.
5. **Every defect found lands test-first** — each fix RED→GREEN on this branch; the
   suite floor (1755, `Scripts/test-with-floor.sh`) never drops; the branch stays green
   after every task.
6. **The record is complete** — measured-value rows in the matching `tolerances_*.md`
   files, `STATUS.md` entry, `SMOKE_CHECKLIST.md` step rows, `CLAUDE.md` front-door
   sync.

**Non-goals of the metrics:** no number becomes a *gate pass* in this unit. The P2 gate
needs three legs (`ROADMAP.md:176-180`); the matrix leg and the ≥5-external-users leg
are separate cards. A failing real run re-baselines (or, where the procedure says so,
records "not performed") — never silently relaxes, never gates.

## User Personas & Scenarios

- **The founder (aliz)** — the only executor. Scenarios: the whisper GGUF download and
  first whisper transcription; the F2 recording session (the long pole, one focused
  session) and the blind ballot; the latency benchmark re-run with the composite row;
  the founder-signed tolerance rows. This unit has no other persona — it is the second
  contact with reality after `p2-gate-measurement`.
- **The future external user** — served indirectly: whisper's measured accuracy makes
  the engine-picker tradeoff honest (`CAPABILITY_ROADMAP.md:89`), the F2 number
  grounds the P1 gate, and the composite latency number is what the launch narrative
  (PH-publish plan) can cite.

## Requirements

### Must-have

- **M1 — Whisper provisioning + manifest verification (SMOKE 102, both tiers).**
  `Scripts/provision-asr-fixtures.sh` provisions turbo (1,624,555,275 B) and q5_0
  (574,041,195 B) with the `verified` marker; `testEveryShippedManifestMatchesTheProvisionedBytes`
  runs green with both tiers named `MANIFEST-VERIFY`; a digest mismatch is a defect
  fixed test-first with its provenance recorded (`STATUS.md:1043-1049`). Ordered
  **before** any whisper WER row (`tolerances_20260829.md:59-72`).
- **M2 — Whisper WER + streamed cycle (SMOKE 19).** `WhisperCppEngineWERTests` with
  `VOCCA_MODEL_DIR` set (visible skip lifted): six fixtures vs tolerances (clean 0.10 /
  spike-clip 0.10 / accented 0.12 / noisy 0.20 / sixty-second 0.10 / two-hundred-ms
  1.0), the streamed-final == batch assertion, short-audio rows (0.2/0.5/1 s) through
  both `transcribe` and `stream` — the record that turns "reasoning about the C
  library" into measurement (`WhisperCppEngine.swift:240-258`) — and the O(n²) cost
  observation against the shipped constant, never gated. **The tolerance rows are
  turbo's.** The q5_0 tier (the constrained-machine tier, C3) has no WER test class:
  its accuracy disposition is recorded explicitly — run q5_0 through the same six
  fixtures and record its WER rows against the turbo table, re-baselining a q5_0 row
  via `tolerances_20260810.md` if it misses (recorded, never gated), or record
  "q5_0 accuracy not tolerance-tested" as a named row if the founder declines the
  run. Provisioning a second tier must not silently open a new unmeasured surface.
- **M3 — First whisper transcriptions + license (SMOKE 95, 96/103, 21).** Tier
  download recorded; first whisper transcription engine-attributed (the whisper
  identity, not Parakeet's); whisper.cpp license sign-off recorded (model-lifecycle
  M10).
- **M4 — F2 defect fixes, test-first.** (a) The ballot flow: the env-gated first
  invocation prints the seeded ballot (seed generated and printed; `answers.tsv`'s
  first line must match it) — RED on the missing flow, GREEN after. Ballot content is
  resolved explicitly: the pair name and class tag may print (`printBallot` prints
  `## <name> [<class>]`, `CleanupEvalHarnessTests.swift:850`); the blindness the spec
  guarantees is **side-blindness** — the judge never sees which side is cleaned —
  and the ballot preserves that; (b) the raw-side convention: `.raw.txt` documented
  as the discovery requirement in the F2 procedure docs (spec/plan/SMOKE), with the
  convention pinned by a test where one is missing.
- **M5 — F2 corpus + eval (SMOKE 73).** ≥40 founder-recorded utterances, ≥5 per class,
  six classes, `<name>.wav / .clean.txt / .class.txt` + `dictionary.json` under
  `~/Vocca/f2-pairs/` (on-disk only, never committed); `VOCCA_CLEANUP_EVAL=<pairs-dir>`
  (the value is the directory — `CleanupEvalHarnessTests.swift:450`); first run prints
  the ballot, the founder's blind answers fill `answers.tsv` (tie/noPreference allowed,
  excluded from the denominator), second run prints per-pair rows, `preference=NN.N%`,
  per-class tallies, and the `RECORDED, not gated` verdict vs 0.80.
- **M6 — Latency composite + step-72 completion (SMOKE 71-72).** Test-first: the real
  benchmark runner emits a composite (total) span row per cycle alongside
  captureClose/asr/cleanup/inject, with the cleanup span's status named (recorded as
  absent for the nil-cleanup pipeline, not silently dropped). **Constraint:** the
  seeded contract tests pin the span set to exactly `[captureClose, asr, inject]`
  (`LatencyBenchmarkTests.swift:112-121`, streaming `:482-491`) — the composite is an
  addition to the real-run printer only; the seeded contract stays untouched, and a
  change to the contract itself is a seam-contract change that escalates under M7's
  rule rather than shipping in this unit. Steps 71-72 re-run with suppression
  `not-suppressed` throughout; the composite p50/p95 recorded against the provisional
  400/800 table (p50 400 / p95 800, `ProvisionalTolerances`), with the 60 s fixture
  substitution, machine, and model version stated beside the numbers; the
  founder-signed re-baseline row lands in `tolerances_20260825.md` (measure → margin →
  founder-signed → land in exactly the named file; the single-source scans stay green).
- **M7 — Defect fixes, test-first.** Every defect **surfaced by the M1-M6 runs** — a
  step failing its pass condition, a harness/script breaking on the founder's machine,
  a digest mismatch, a step that cannot be performed as written — is fixed RED→GREEN
  with a regression test; the fix never lowers the floor (1755); a fix needing a
  PRD-level decision or a seam-contract change escalates as its own card instead.
  Observations made *while* running but not caused by a run are not defects and go in
  the record, not the branch.
- **M8 — The record.** `STATUS.md` entry; `SMOKE_CHECKLIST.md` step rows (19, 21, 71-72,
  73, 95-96, 102-104, 103); tolerance rows in `tolerances_20260810.md` (whisper WER),
  `tolerances_20260815.md` (F2 preference), `tolerances_20260825.md` (latency, founder-
  signed); `CLAUDE.md` front-door status synced; `docs/planning/unmeasured-numbers-sweep/`
  artifacts committed.

### Should-have

- **S1 — Stale-doc fixes where touched.** `real-engine-runs/spec.md:8` (stale STATUS
  range citation → now the AppQuitPolicy entry; the whisper-seeded-tolerances claim
  lives at `STATUS.md:238-240`), `cleanup-eval-f2/plan_20260901.md` (floor 1731 → 1755;
  `VOCCA_CLEANUP_EVAL=1` → `<pairs-dir>`), and `tolerances_20260810.md` prose status
  (predates its own measured table; the 20260829 file is the current ordering source).

### Nice-to-have

- **N1 — Composite latency number also recorded for the streamed variant** (the
  `VOCCA_LATENCY_BENCH` streaming path) if the runner change makes it free.

## Technical Considerations

- **Phase and placement:** P2 — the gate path, not a build capability; C9+ stays
  guardrail-blocked (`CAPABILITY_ROADMAP.md:369`). Touches ASR (whisper), cleanup
  (F2 eval), and the latency benchmark surface — all measurement, no product surface.
  Local-only; the zero-network invariant is untouched; the F2 corpus stays on the
  machine (R11, `ROADMAP.md:310`).
- **Execution surface:** all real runs are env-gated (`VOCCA_MODEL_DIR`,
  `VOCCA_LATENCY_BENCH`, `VOCCA_CLEANUP_EVAL`) and executed by nothing in CI — visible
  `XCTSkip` is the CI state; the founder's machine is the only execution environment.
  Provisioning first: `Scripts/provision-asr-fixtures.sh` prints the `VOCCA_MODEL_DIR`
  value (Parakeet: 4 `.mlmodelc` + config.json + vocab; whisper: turbo + q5_0 GGUF).
- **Headless regression bar:** `Scripts/test-with-floor.sh` (floor 1755) after every
  task; filter syntax `swift test --filter <Class>`; the suite is a Swift 6 package.
- **Re-baseline discipline:** numbers record, never gate. Single-source scans fail on a
  duplicated constant; a re-baseline edits exactly the named file(s) plus a dated
  founder-signed row in the matching `tolerances_*.md` (`tolerances_20260810.md:26-52`,
  `tolerances_20260815.md:28-41`, `tolerances_20260825.md:25-32`). The margin is the
  founder's decision, recorded in the step's note.
- **Privacy/latency budgets:** latency numbers are measured and recorded against the
  provisional table — no regression gate on real numbers in CI, and this unit adds
  none. Suppression discipline: a throttled run is **voided, not recorded**
  (`SMOKE_CHECKLIST.md:1337-1340`).
- **F2 privacy:** the corpus is on-disk only, never uploaded, never committed; the
  ballot preserves blindness (the judge never sees which side is cleaned).

### Execution order (sequencing guidance, not commitments)

1. **F2 defect fixes (M4a, M4b)** — the two known-code slices, test-first; they are the
   only build work and they unblock the F2 flow. Small, do first.
2. **Latency composite row (M6's runner change)** — the second test-first slice; the
   re-run itself can happen any session after.
3. **Whisper provisioning + verification (M1)** — the download (~2.2 GB both tiers) is
   the sweep's external dependency; start early, verify before any whisper row.
4. **Whisper WER + first transcriptions (M2, M3)** — needs M1; SMOKE 96/103 before or
   with 19.
5. **F2 recording (M5, the long pole)** — one focused founder session, ≥40 utterances;
   can overlap 3-4; the ballot + verdict run after the corpus is complete.
6. **Latency re-run + step-72 record (M6)** — any session; needs the runner change.
7. **Record + sync (M8, S1)** — `tolerances_*.md` rows, `STATUS.md`, `SMOKE_CHECKLIST.md`
   step rows, `CLAUDE.md` front door.

Session counts are guidance, not gates: whisper WER ~1 session, F2 recording 1,
latency re-run 1, record/sync 1.

## Risks & Open Questions

- **R1 (high, expected) — first-execution defects.** Every prior first execution found
  defects CI cannot catch (short-press 0.3 s; local-dev-launch ×3; release symlink).
  This unit already knows two of its defects before running (the ballot hole, the
  raw-side convention) — they are planned as M4, not discovered. The whisper first-
  transcription path is the untested remainder (`SMOKE_CHECKLIST.md:2025`); whisper's
  real WER may miss the seeded tolerances — that re-baselines via
  `tolerances_20260810.md`, never silently relaxes.
- **R2 — GGUF download friction.** Both tiers are ~2.2 GB; a slow/partial download
  stalls the whisper half. The provisioning script's resumable transfer + digest
  verification is the mitigation; a digest failure is M1's defect fix, not a blocker.
- **R3 — F2 corpus quality.** The preference number is only as good as the corpus;
  ≥5/class is the floor and the margin decision absorbs recording noise
  (`tolerances_20260815.md:28-41`). The TTS stand-in corpus is "unnaturally clean"
  (`STATUS.md:351-353`) — the F2 number may differ materially; recorded, never gated.
- **R4 — Latency composite honesty.** The 60 s fixture substitution (no 10 s clip in
  the suite) must be recorded beside the composite or the number overclaims
  (`SMOKE_CHECKLIST.md:1350-1358`); the cleanup span is absent for the nil-cleanup
  pipeline and must be named, not dropped; the composite-row change must not disturb
  the seeded closed-span contract (`LatencyBenchmarkTests.swift:112-121`) — if it
  must, that is an escalated seam-contract change, not a silent amendment.
- **R5 — q5_0's accuracy surface.** The second tier is manifest-verified (M1) but has
  no tolerance table of its own; M2's disposition (run-and-record or explicitly
  named not-tested) is the hedge against opening a new unmeasured surface in a unit
  whose job is closing them.
- **OQ1 — Re-baseline margins.** The margin at each founder-signed re-baseline is a
  founder decision at the time, recorded in the step's note.
- **OQ2 — A blown provisional bound.** If measured whisper WER or the composite
  latency misses the provisional tables, the numbers are recorded and the founder
  decides at the gate — nothing in this unit gates, fails the branch, or relaxes a
  bound silently.

## Out of Scope

- **The injection matrix run** — C8's other half; sequenced after this unit
  (`injection-matrix-completion`, the founder's last pre-PH milestone).
- **Notarization / Developer ID** — blocked — not purchased; separate runbook.
- **The P2 gate's third leg (≥5 external users)** — needs a release.
- **C9 onward** — Kokoro, endpointing, dual mode, context, actions
  (`CAPABILITY_ROADMAP.md:228-317`); guardrail-blocked until the P2 gate passes.
- **New capability build of any kind** — the candidate set is closed at
  first-execution + defect fixes + measurement (the two known F2 defects and the
  latency runner row are the only code).
- **The 7-day daily-use gate log and the P0 gate's habit leg** — the founder logs it
  outside this unit.
- **Cloud, telemetry, or egress of any kind** — the F2 corpus and all recordings stay
  on the machine.