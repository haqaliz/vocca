# Aspect spec: agent-record

> Source: `docs/planning/reply-text-rendering/prd.md` R6 + the unit record · Date
> 2026-10-01.

## Problem slice and user outcome

SMOKE 164 (the real spoken exchange with the bubble observed), the unit record, the docs
sync, and the deferred item retired from the records.

## In-scope requirements

- **SMOKE 164** in `docs/SMOKE_CHECKLIST.md`: converse → the reply is spoken AND the
  bubble shows it verbatim → the next utterance clears it → barge-in clears it mid-reply
  → a long reply scrolls (the cap observed) → the replyFailed case (best-effort; the
  text stays). Ground rules: recorded never gated; no rate quoted.
- **The unit record** (`docs/STATUS.md`): per-aspect summary; decisions (Q1–Q3; the
  ask-path coverage; the replyFailed keep; the VoiceOver best-effort honesty; the cap
  value); the G5 re-anchor record; the floor (3052 → new); **the `reply-text-rendering`
  deferral retired** (CAPABILITY_ROADMAP's remaining-machinery lists updated).
- **Docs sync**: `CLAUDE.md` status paragraph; `CAPABILITY_ROADMAP.md` C13 amendment
  (the remaining-machinery list drops reply-text rendering; the turn-history item stays
  named as unclaimed); `ARCHITECTURE.md` if a seam fact changed (the driver's sink —
  likely one clause).

## Out-of-scope

- Any code change; the turn-history item; N1 (the copy affordance).

## Acceptance criteria

1. STATUS.md's newest entry is append-only and matches the tree.
2. Every claim cites a file; deferrals name blockers; the floor is the script's parse.
3. The deferral is retired with the replacement named.

## Dependencies / sequencing

Last — after `agent-pins`.

## Open questions

- None.