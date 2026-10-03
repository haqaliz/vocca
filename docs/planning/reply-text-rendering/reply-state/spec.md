# Aspect spec: reply-state

> Source: `docs/planning/reply-text-rendering/prd.md` R2, R3 · Date 2026-10-01.

## Problem slice and user outcome

The reducer: the `WidgetAction` closed set's deliberate amendment, the bounded
`replyText` state field, the reducer rules (set on speaking; cleared on
listening/idle/barge-in), the store's thin fold, and the amended invariant. User
outcome: the state is bounded and the lifecycle is one rule.

## In-scope requirements

- **The action**: `.replyPresented(String?)` — one new case in the `WidgetAction` closed
  set (the amendment is deliberate; the closed-set sweep and the invariant probe carry
  it).
- **The field**: `WidgetReducerState.replyText: String?` — **bounded in the reducer**
  (a named cap, the `maxPartialCharacters` shape; 2000 characters proposed; truncation
  is the reducer's single-place answer — the partial precedent).
- **The rules**: set when the reply arrives (speaking); cleared on `listening` (the
  next utterance) and on `idle`; cleared on the barge-in clear (the carrier emits
  nil). The `adopting` `.conversing` row's invariant is amended: "the phase is the
  state's only content (D1)" → "the phase plus the bounded reply text" — the
  `invariantViolation` `.conversing` case updated deliberately.
- **The store**: a thin `presentReply(_:)` fold (the `presentPartial` shape).
- **Tests**: the reducer rows (set/bound/clear on listening/idle/barge-in; the phase
  change keeps the text; the closed-set sweep carries the action; the invariant probe
  amended).

## Out-of-scope

- The carrier (own aspect), the view (own aspect).

## Acceptance criteria (test-first)

1. `.replyPresented("…")` sets `replyText`; over-cap text truncates at the named bound
   (one place, pinned).
2. A new utterance (listening adoption) clears it; idle clears it.
3. `.replyPresented(nil)` (the barge-in clear) clears it.
4. The phase change within conversing (listening → speaking) keeps the text until the
   next turn's listening clears it.
5. The closed-set sweep includes the action; the invariant probe's `.conversing` case
   allows the bounded text and nothing else.
6. The dictation-path rows are untouched (the field is converse-only — a dictation
   adoption clears it).

## Dependencies / sequencing

Independent of `reply-carrier`; before `reply-view`.

## Open questions

- The cap's exact value (2000 proposed) — pinned in the aspect.