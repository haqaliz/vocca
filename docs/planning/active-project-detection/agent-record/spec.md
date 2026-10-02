# Aspect spec: agent-record

> Source: `docs/planning/active-project-detection/prd.md` R6 + the unit record · Date
> 2026-10-01.

## Problem slice and user outcome

The unit's closing half: SMOKE 161 (the D3 measurement — the real cwd read on the
founder's machine), the unit record, the docs sync, and the recorded `dev.vocca.agent`
prose drift fix (the dig found `CLAUDE.md`'s paragraphs still name the old id while the
code is `vocca.agent`).

## In-scope requirements

- **SMOKE 161** in `docs/SMOKE_CHECKLIST.md` (the established shape): focus each of the
  founder's real apps (VS Code, terminal/iTerm — and a negative row: an app whose cwd is
  `/`, e.g. Finder/desktop) → arm an agent row with an empty directory → the card shows
  the detected path → confirm → the run happens there → the audit sentence shows it.
  Ground rules: recorded never gated; "detected" = the resolved path, never a claim
  about every app; no rate quoted.
- **The unit record** (`docs/STATUS.md`): per-aspect summary; the decisions (D1 metadata
  lane, D2 explicit-wins, D3 ship+measure, the one-resolution contract, the carrier's
  rationale — the sentence binding's four renders, S2 voice-leg detection); the
  deferrals (tab-awareness — the critique's hard question recorded as frontmost-only
  this slice; the `~` expansion — the seam has no home accessor); the G5 re-anchor
  record; the floor (2958 → new).
- **Docs sync**: `CLAUDE.md` status paragraph (+ the `dev.vocca.agent` → `vocca.agent`
  prose drift in the coding-agent-handoff paragraph — a recorded correction, never a
  rewrite of the record); `CAPABILITY_ROADMAP.md` C13/C12 amendment paragraphs;
  `ARCHITECTURE.md` (the context seam table gains the cwd read — a seam fact, if the
  read ships as its own seam file).

## Out-of-scope

- Any code change (docs-only); any gating of SMOKE 161.

## Acceptance criteria

1. STATUS.md's newest entry is append-only and matches the tree it ships in.
2. Every claim cites a file; deferrals name blockers; the floor is the script's parse.
3. The CLAUDE.md prose drift is corrected without rewriting the historical record.

## Dependencies / sequencing

Last — after `agent-pins`.

## Open questions

- None.