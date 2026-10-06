# intent-leg-wiring — aspect spec

Single aspect of `converse-intent-wiring`. Source: `../prd.md` (approved 2026-10-07; Q1 = the fixed
"Confirm on screen." line, Q3 = accept a mid-conversation card, both recommendations confirmed by approval).

## Problem slice / outcome
The shipped converse path calls the intent leg. A matching phrase on an enabled tool reaches the shared
executor in the real app; a destructive result is spoken as "Confirm on screen." instead of an echo; the
default (no file / no enabled tool) is byte-identical to today's echo.

## In scope
PRD must-haves 1-6: the named static, the card-up spoken line, default-unchanged assertion, safety rows
through the real path, no-egress/probe unchanged, pins + G5 + floor; should-haves (docs, one SMOKE row).

## Out of scope
Per PRD: spoken confirm, session guard / clear-on-end, phrase or keyword UI, shell voice, display names,
dictation/injection/ASR, gate-evidence work, a probe drive of the real converse+intent composition.

## Acceptance criteria (the failing tests, written first)
B1 provider closure: root released → nil; `root.intentWiring == nil` → nil; wiring present → returns the
   wiring's resolution (a phrase hit → `.toolCall`; `.none` → nil-or-`.none`, either echoes).
B2 lazy: a closure built BEFORE `root.intentWiring` is assigned resolves through it AFTER (the ordering claim).
B3 handler, read-only tool: returns the wiring's ack ("Done."), audited `autoRanReadOnly`, no card.
B4 handler, destructive tool: wiring returns nil and a card is up → the handler returns exactly
   `"Confirm on screen."`; provider invoke count 0; audit trail `[.refused]`; card present.
B5 handler, second action while a card is up (the existing refusal, nil) → `"Confirm on screen."`
   (a card is waiting); no second card; audit unchanged.
B6 handler, nil with NO card (`.notInvoked`/placeholder-less refusal) → nil → the driver echoes (unchanged).
B7 failure copy: `auditRecorded == false` still returns the wiring's failure string verbatim, never the
   confirm line.
B8 through the real `ConverseLoopDriver` (the `ConverseIntentStepTests` `makeDriver` harness with the static's
   closures over an `IntentRoundTripHarness` root): read-only → spoken "Done."; destructive → spoken
   "Confirm on screen." (NOT the echo of the utterance) and the card is up; default (empty table) → the echo of
   the utterance exactly as the generator produces it; a `.ask`-free miss → echo.
B9 source-scan pin: `configure`'s `composeConverseWiring(` call passes `intentProvider:` and
   `intentActionHandler:` built by the static, reaching the root through `rootBox` (never a strong capture).
B10 G5 re-anchored once (seven sites, dictation digests unchanged), floor raised to the real count,
   zero-network suite green, PROBE-CONVERSE line unchanged.

## Risks
The confirm line is only true if the card is visible (SMOKE-only); wrapper must not speak it for a call that
produced no card and no earlier card; closures are `@Sendable` over `@MainActor` closures (actor hop).
