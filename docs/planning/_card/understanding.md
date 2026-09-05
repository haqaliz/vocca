# Understanding: injection-matrix-completion

> Phase 2 dig note for `feat/injection-matrix-completion`. Sources cited inline.

## What this work is

Complete the tracked injection-matrix run — C8's measurement half and the founder's last
milestone before the Product Hunt publish. The evidence chain, harness, and strategy
memory are all shipped (`injection-matrix-record` unit, merged 2026-09-03); what remains
is execution: **17 deliverable rows + step 92 (Secure Input refusals)**, with the FMS
tally recorded never gated. The tracked table's current row reads **not closeable**
(`SMOKE_CHECKLIST.md:1992`).

## The surface (dig findings, cited)

- **Tracked table** `SMOKE_CHECKLIST.md:1984-1992`: v0.1.0 rows unrecorded/not-closeable;
  a complete row = release, date, rows run, skipped, voided, FMS, notes. FMS = deliverable
  rows whose expected rung landed / 20 deliverable; bar ≥19/20; recorded never gated.
- **Steps 87-93**: 87 (baseline calibration) executed twice (19/0/3 bundle-ids after five
  swaps — Ghostty/IntelliJ/Zed uninstalled, no same-class swap, stay skipped); 88 (tracked
  run) 1 of 18 rows; 89 (seeded-hostile) dispositioned not executed (Slack half unrunnable
  while the row is Teams); 90 (re-probe) needs ≥5 clipboard deliveries + 7-day window;
  91 (promotion) window not elapsed (Xcode first candidate); 92 (Secure Input refusals)
  unexecuted — PASS = `attempted: []` in the log + failsafe copy + strategies.json gained
  nothing; 93 (per-release row) targets v0.2.1.
- **Harness** `Scripts/injection-matrix.sh`: `--verify-bundle-ids`, `--dry-run`, `--row`,
  `--run-log <path>`, full run; per-row JSONL to
  `~/Library/Application Support/Vocca/matrix-runs/<date>.jsonl`; 22 rows (20 deliverable +
  2 refusal with expected rung `none`).
- **Evidence chain**: `MatrixEvidence.swift` exact strings (`session opened mode=dictation`,
  `delivery target=… rung=… attempted: […] verified=…`); ladder emits exactly one
  `.delivery` per inject; `OSLogMatrixEvidence` category `matrix`; `strategies.json`
  written only on strategy change. **The file chain is load-bearing** — the unified-log
  live check was declined once.
- **PASS definition** `SMOKE_CHECKLIST.md:1806-1808`: bytes **and** the log naming the
  expected rung as the landing rung (rung half = founder y/N); bytes half automated
  (select-all/copy/pbpaste vs the fixed phrase).
- **Adjudication**: no checklist step prescribes formal ASR-vs-injection triage; the unit
  card makes it an acceptance item. The Notes byte-mismatch was recorded as step 19's
  matter (ASR transcription), not adjudicated as an injection failure. An
  `.accessibility` byte mismatch = read-back lying, a bug not a fallback
  (`injection-matrix.sh:472-473`).
- **Floor 1758** (`test-with-floor.sh:1444`); branch at 24b1b9d == origin/master.

## The honest bounds

- **FMS may be not-closeable on this machine**: with 3 rows skipped (no swap) and ≤20
  deliverable, ≥19/20 may be structurally unreachable — a recorded outcome, not a failure
  (`docs/planning/_card/understanding.md:85-87` of the prior unit).
- **Windows**: steps 90/91 need elapsed windows + clipboard-delivery counts — daily-use
  accumulation must start now (it also feeds the P0 7-day gate log); if the windows aren't
  elapsed by the run, they record as observed-not-elapsed and the tally proceeds on the
  rows that can run.
- **One tracked row per release** — the new row is for v0.2.1 (released 2026-09-04).

## Out of scope (honestly)

Notarization (blocked — not purchased), the P2 gate's third leg (≥5 external users), any
gate claim, C9+ (guardrail-blocked). Everything records; nothing gates.