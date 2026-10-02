# Aspect spec: utterance-threading

> Source: `docs/planning/spoken-task-seeding/prd.md` R3, R4 · Date 2026-10-01.

## Problem slice and user outcome

The utterance's path to the invocation: the driver's handler widening, the wiring's
enrichment (fill `taskText` when the row's argv carries the placeholder), and the
surface-arm refusal. User outcome: "ask claude to X" in conversation runs X; arming a
placeholder row from the Actions tab refuses loudly.

## In-scope requirements

- **The driver widening** (`ConverseLoopDriver`): the intent-action handler gains the
  utterance — `intentActionHandler: @Sendable (ActionInvocation, utterance: String) async
  -> String?` (the deliberate-widening precedent; the default closure updates; the
  driver's compile pins update deliberately). The utterance is in scope at the intent
  step's call site — the change is honest, not a re-plumbing.
- **The wiring enrichment** (`IntentWiring`): `performAction` — when the resolved tool
  is an agent row whose argv carries `taskPlaceholder`, build the invocation with
  `taskText: utterance` (the FULL utterance — critique resolution: the trigger words
  stay in the task; the audit records exactly what was said); otherwise nil
  (byte-identical to today). The row is read per call (the existing per-turn registry
  read).
- **The refusal path**: an agent row whose argv carries the placeholder but no
  utterance reaches it (hand-built invocation, surface-armed) → the wiring refuses
  BEFORE the card (declined, recorded, never a card, never a run — critique gap 2).
- **The surface refusal** (R4): arming a placeholder row from the Actions tab → the
  loud refusal (the loud copy, recorded); the editor's `<task>`-Save refusal unchanged.
- **G5**: `AppBootstrap` changes if `composeIntentWiring` call sites or the routing
  shift — the deliberate re-anchor in REFACTOR (computed, never edit-to-match;
  dictation digests unchanged).

## Out-of-scope

- The substitution itself (own aspect); the editor; the safety spine.

## Acceptance criteria (test-first)

1. A phrase row naming a placeholder-row agent: converse → the card shows the
   substituted argv with the FULL utterance; confirm → the run's arguments contain it;
   the audit sentence shows it.
2. A phrase row naming a non-placeholder agent: `taskText` nil, byte-identical to
   today.
3. A placeholder row reached without an utterance → refused before the card (recorded).
4. The Actions-tab arm of a placeholder row → the loud refusal, nothing recorded as a
   run, never a card.
5. The driver's compile pins update deliberately (the widened handler's default).
6. The composed default facts unchanged; G5 re-anchored deliberately if touched.

## Dependencies / sequencing

After `task-carrier`. Before `agent-pins`.

## Open questions

- None — the full-utterance decision and the pre-card refusal are the recorded
  resolutions.