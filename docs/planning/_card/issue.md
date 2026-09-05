# Card: feat/injection-matrix-completion

> Inline brief — no GitHub issue exists. Source: `vocca-next` handoff + founder's pre-PH
> milestone ordering, 2026-09-04/05.

## Brief

Complete the tracked injection-matrix run — C8's measurement half, the founder's **last
milestone before the Product Hunt publish**. The evidence chain is real (the
`injection-matrix-record` unit landed it: `MatrixEvidence` lines, the ladder's delivery
seam, `Scripts/injection-matrix.sh`'s per-row JSONL run log, `strategies.json` demotions),
and the tracked table's row reads **not closeable** (`SMOKE_CHECKLIST.md:1906`): run 2
stopped at **1 of 18 deliverable rows** (Notes, byte mismatch, accessibility rung demoted
with a fresh re-probe window), with **17 rows + step 92 (Secure Input refusals) remaining**.
FMS = deliverable rows whose expected rung landed / deliverable rows run, the ≥95% bar
(`≥19/20`) is the P2 gate's matrix leg (`ROADMAP.md:176-181`), recorded never gated.

The unit executes the remaining rows on the founder's machine (the harness + evidence
chain are shipped), adjudicates byte-compare mismatches (the Notes failure was an
ASR-transcription matter — step 19's issue — not an injection failure; adjudicate, don't
chase), fixes test-first any defect the run surfaces (the previous run surfaced three: no
info-level logging, `strategies.json` write-on-change-only, no harness run log), and
records the FMS tally in the tracked table. The live unified-log check was declined once —
the file chain is load-bearing.

Acceptance:

- Every remaining deliverable row (17) + step 92 executed and recorded with a file-based
  artifact (harness run-log JSONL line + `strategies.json` where a strategy changed).
- FMS computed over the deliverable rows actually run, with skips/voids named and the
  denominator discipline applied; the tracked table gains a fully-measured row for v0.2.1.
- Byte-compare mismatches adjudicated (ASR-transcription vs injection), never auto-counted
  as injection failures; R1's silent-no-op recorded per row where observed.
- Every defect the run surfaces fixed test-first: RED→GREEN, suite floor 1758 never drops
  (`Scripts/test-with-floor.sh`).
- `docs/STATUS.md` entry, `SMOKE_CHECKLIST.md` tracked-table row, `CLAUDE.md` front-door
  sync. No gate passes as a result of this unit — the P2 gate needs latency targets +
  ≥95% matrix + ≥5 external users (`ROADMAP.md:176-180`).

Caveats:

- **FMS may be "not closeable on this machine's app set"**: Ghostty, IntelliJ, Zed are not
  installed and no same-class swap exists (`--verify-bundle-ids` 19 confirmed / 0
  mismatched / 3 unverified); with ≤20 deliverable rows, ≥19 may be unachievable — that is
  a recorded outcome, not a failure (`docs/planning/_card/understanding.md:85-87`).
- **Re-probe/promotion windows**: step 90's re-probe needs ≥5 clipboard deliveries + a
  7-day window elapsed; step 91's promotion needs a window elapsed — the run may need
  daily dictation accumulation before the final tally.
- **Unified-log session lines** are unproven on a live session (the live check was
  declined once); the file chain is load-bearing, not the log lines.
- The v0.2.1 release exists (2026-09-04); the tracked table expects one row per release —
  the new row is for v0.2.1, and the matrix should ideally run against the released build
  where the difference matters.