# Aspect spec: agent-record

> Source: `docs/planning/spoken-task-seeding/prd.md` R6 + the unit record · Date
> 2026-10-01.

## Problem slice and user outcome

The unit's closing half: SMOKE 162 (the real voice round trip — the founder's phrase row
+ placeholder row on the live build), the unit record, the docs sync, and the N1
deferral retired from the records. User outcome: the next unit reads exactly what this
slice did and did not prove.

## In-scope requirements

- **SMOKE 162** in `docs/SMOKE_CHECKLIST.md` (the established shape): a hand-edited
  placeholder row (`coding-agents.json` — the editor still refuses `<task>`, the file
  may carry it, recorded) + a phrase row naming it (`intent-phrases.json`) → converse →
  the card shows the substituted argv with the full utterance → confirm → the agent runs
  with it → the audit sentence reconstructs. Ground rules: recorded never gated; the
  surface-arm refusal row (arming the placeholder row from the Actions tab refuses
  loudly); no rate quoted.
- **The unit record** (`docs/STATUS.md`): per-aspect summary; the decisions (the
  full-utterance seeding, every-occurrence substitution, the pre-card refusal, the
  surface refusal, the driver widening); the deferrals (the editor checkbox — N1 of
  THIS unit; `$N` parameters; interactive sessions); the G5 re-anchor record (if any);
  the floor (3000 → new); **the N1 deferral of `coding-agent-handoff`/`agent-presets`
  retired** — the record names the retirement and what replaced it.
- **Docs sync**: `CLAUDE.md` status paragraph; `CAPABILITY_ROADMAP.md` C13 amendment;
  `ARCHITECTURE.md` only if a seam fact changed (expected: none — a field and a
  signature).

## Out-of-scope

- Any code change (docs-only); any gating of SMOKE 162.

## Acceptance criteria

1. STATUS.md's newest entry is append-only and matches the tree it ships in.
2. Every claim cites a file; deferrals name blockers; the floor is the script's parse.
3. The N1 deferral is retired in the records with the replacement named.

## Dependencies / sequencing

Last — after `agent-pins`.

## Open questions

- None.