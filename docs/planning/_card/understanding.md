# Understanding: injection-matrix-record

> Phase 2 dig note for `feat/injection-matrix-record`. Sources cited inline.

## What this work is

The first **recorded** run of the injection matrix (`docs/SMOKE_CHECKLIST.md` §12,
steps 87-93), in the landed `p2-gate-measurement` shape: execute the already-written
acceptance, fix the real defects the execution finds, record — never gate. The unit's
deliverable is the tracked table's first *measured* row (the v0.1.0 row at
`SMOKE_CHECKLIST.md:1905` reads **unrecorded**), plus whatever test-first fixes the run
surfaces.

## What the dig found — the load-bearing discovery

The first run's failure ("machine record shows no sessions and no strategies.json for
this window", `STATUS.md:101-107`) is **not only a procedure miss — the machine evidence
the checklist names does not exist in the current build**:

1. The shipped app's unified log has **no info-level session/transcript/landing-rung
   lines**. The complete `Logger(subsystem: "dev.vocca.Vocca")` surface is tap health,
   idle re-warm, speculative-feed start/cancel, abandoned engine preparation, and
   error-level only everywhere else. `VoccaCore` has zero logging. The ladder's
   `InjectionResult` (rung/attempted/verified) is consumed only by strategy memory and
   the in-memory latency ledger (probe-only, not persisted). Yet the checklist's row
   observation is "the log named the expected rung" (`SMOKE_CHECKLIST.md:88`).
2. `strategies.json` is written **only when a strategy changes**
   (`MemoryBackedInjectionStrategyOrder.record`): a steady-state step-88 pass writes
   nothing to disk.
3. `Scripts/injection-matrix.sh` writes **nothing** — stdout only, no run log — despite
   `docs/planning/injection-strategy-memory/matrix-smoke/plan_20260827.md:16` promising
   "writes nothing to disk except its own run log".
4. The harness deliberately cannot produce the rung itself (header lines 28-30: "A
   script that guessed the rung would produce exactly the number this whole exercise
   exists to stop guessing") — the rung half of a PASS is a founder y/N. That design is
   right; what's missing is a machine artifact the app itself emits.

So the unit has a **buildable, test-first first slice**: make the machine evidence real
— info-level rung/session log lines under the checklist's own log-discipline predicate
(`log show --predicate 'subsystem == "dev.vocca.Vocca"'`, used at `SMOKE_CHECKLIST.md`
steps 96/101/103), and/or a harness run log. This is exactly the repo's pattern: "every
prior first-execution in this repo found defects CI cannot catch" (`_card/issue.md`).

## The procedure (steps 87-93, cited)

- 87: baseline calibration — `--verify-bundle-ids` to zero mismatches; delete
  `strategies.json`, relaunch; `--dry-run`; full matrix; per-row: rung named in log,
  bytes matched, surprises. Failure = a row with no recorded observation.
- 88: the tracked run — ≥19 of 20 deliverable rows first-method; refusals refuse;
  append a tracked-table row. **Recorded, never gated** (prd X7).
- 89: seeded-hostile first run (Slack + Google Docs) — **Slack row is now Teams**
  (swapped 2026-09-01), so the Slack-specific part may not be runnable on this machine.
- 90: re-probe — needs ≥5 clipboard deliveries + the provisional
  `reprobeWindowSeconds` window elapsed (7 days); records the window value.
- 91: promotion — Xcode first candidate; needs a window elapsed.
- 92: Secure Input refusals — `attempted: []` in the log; `strategies.json` gains
  nothing.
- 93: one tracked-table row per release.

Skipped/voided rows are their own record (`SMOKE_CHECKLIST.md:1726-1728`); a voided
row (denied Automation grant → sentinel still on clipboard → exit 3) is neither pass
nor fail.

## State of the rows

16 confirmed / 0 mismatched / 6 skipped (Pages, Notion, Ghostty, IntelliJ, Zed,
1Password not installed — `STATUS.md:101-107`). The six are exactly the six **guess**
rows. iTerm2→Warp and Slack→Teams swapped per step 87, both ids plutil-read.
Deliverable denominator = 20 (rows 21-22 are refusal rows, expected rung `none`).

## Open questions for the PRD

1. **Install or swap the six missing apps?** The card says "install … or swap
   same-class per step 87". Same-class swaps (e.g. Notion→another Electron editor)
   keep the matrix runnable without installs; installing keeps the P0 matrix's named
   apps. Founder decision.
2. **Evidence fix scope**: app-side info-level rung/session logging (test-first, in
   the ladder's seams), a harness run log, or both? The harness run log is the
   cheapest and matches the promised-but-missing `plan_20260827.md:16` artifact; app
   logging is what the checklist's language ("the log names the rung") actually
   requires.
3. **Steps 89-92**: are they in this unit's run, or do their window preconditions
   (7-day re-probe, clipboard-delivery counts) push them to a later release run? Step
   89 needs Slack, which is no longer a row.
4. **FMS on this machine's app set**: with ≤20 deliverable rows, can ≥19 even be
   achieved if some swaps stay uninstalled? "Not closeable on this machine" is a
   recorded outcome, not a failure (`STATUS.md:106-107`).

## Out of scope (honestly)

Whisper WER (step 19, GGUF absent — separate real-engine-runs surface), F2 cleanup
eval (no founder corpus), the P2 gate's third leg (≥5 external users), and any gate
claim. No number lands as a pass; everything records.

## Phase placement

P2 (latency + injection feel). Injection reliability is make-or-break battle #2
(`CLAUDE.md`); this unit produces the number the P2→P3 gate's matrix leg is judged on
(`ROADMAP.md:176-181`). Guardrail-fit: macOS-only measurement, local-only, no cloud,
no crippling of the local core; dictation-first — it serves the dictation loop, not the
assistant layer.