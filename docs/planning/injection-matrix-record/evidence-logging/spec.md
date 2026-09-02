# Spec: evidence-logging

**Aspect of:** `injection-matrix-record` (PRD M1 + M2) · **Date:** 2026-09-02

## Problem slice

The matrix's row observations rest on machine evidence that does not exist: the app's unified
log has no info-level session/rung lines, `strategies.json` writes only on strategy change, and
the harness writes nothing (`docs/planning/_card/understanding.md`). This aspect makes the
evidence real, test-first, before any run happens.

## In scope

- **M1 — app-side evidence logging.**
  - A pure `MatrixEvidenceEvent` vocabulary + line formatter in `VoccaCore` (which stays
    logging-free — vocabulary only, no `os.Logger` import). Events: `.sessionOpened(mode:)`
    and `.delivery(targetBundleID:result:)` — the delivery event carries the rung, the full
    `attempted` trace, and `verified`. No transcript text, ever (privacy: evidence is shape,
    not content).
  - A `MatrixEvidenceRecording` protocol in `VoccaCore` (records a `MatrixEvidenceEvent`).
  - `LadderInjector` gains an optional `evidence` slot (same pattern as the existing `recorder`
    slot): after `decide`, emit the delivery event. `nil` keeps every pre-existing construction
    site byte-for-byte identical. Refusals (Secure Input short-circuit → `attempted: []`,
    `rung: .widgetFailsafe`) flow through the same emission, giving step 92 its
    "the log records `attempted: []`" artifact.
  - A thin `os.Logger` adapter (category `matrix`, subsystem `dev.vocca.Vocca`) in `VoccaInject`,
    wired in `AppBootstrap.assembleShippingLadder`'s construction.
  - Session-opened emission: one info line from the loop's session-start handling in
    `VoccaBootstrap/AppBootstrap.swift` via its existing loop logger. Thin wiring; the formatter
    is the tested half.
- **M2 — harness run log.** `Scripts/injection-matrix.sh` appends one JSONL line per completed
  row (date, row name, rung observed, bytes matched, verdict pass/failed/skipped/voided/refusal,
  note) to `~/Library/Application Support/Vocca/matrix-runs/<run>.jsonl`, defaulting there with
  a `--run-log <path>` override (PRD N1), and prints the path at run start.

## Out of scope

- Any change to ladder behavior, strategy memory, the latency ledger, or the recovery journal.
- Transcript text in any log line or run-log line.
- Spans, counters, per-session persistence, or any egress (the zero-network default test must
  keep passing untouched).
- The runs themselves (aspect `matrix-run`) and the records (aspect `record-and-sync`).

## Acceptance (test-first, before the runs)

- A1: `MatrixEvidenceLine.format` tests assert the exact line strings for a delivery
  (accessibility verified, clipboardPaste unverified, keystrokeSynthesis), a failsafe outcome,
  and a refusal (`attempted: []`), plus `.sessionOpened(mode:)`. One test per event shape.
- A2: a stub-recorder test drives `LadderInjector.inject` and asserts exactly one delivery event
  was recorded, whose line renders the result's rung/attempted/verified and the target bundle id.
- A3: the nil-slot contract: the existing injector tests (no evidence slot) pass unchanged —
  evidence is optional, like `recorder`.
- A4: `VoccaCore` imports stay stdlib-only (existing module-boundary lint enforces; a `Logger`
  import in `VoccaCore` fails the lint).
- A5: the harness `--self-check` half still passes in CI; the run-log function is a thin,
  reviewable append (verified by inspection + a `sh -n` syntax check in the suite if the suite
  already does this).
- A6: suite floor 1746 never drops (`Scripts/test-with-floor.sh`).

## Dependencies & sequencing

- First aspect in this unit: the runs (aspect `matrix-run`) require A1/A2/A3 to be landed and
  the app built with them before execution.

## Open questions

- None blocking. Emission point for `.sessionOpened`: the loop's session-start handling in
  `AppBootstrap` (thin wiring; exact call site resolved in the plan).