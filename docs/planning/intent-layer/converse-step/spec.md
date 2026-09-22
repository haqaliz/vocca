# Aspect spec: converse-step

> Source: `docs/planning/intent-layer/prd.md` R4, R10 · Branch `feat/intent-layer/aliz`
> · Date 2026-09-22.

## Problem slice and user outcome

The converse utterance pipeline gains the intent step: after per-mode cleanup, a resolved
utterance can speak a question (ask path) or drive a tool call — while `.none` leaves the
shipped reply generator untouched. The user's spoken utterance can branch to the action
machinery; an ambiguous one is answered with a spoken question and nothing executes.

## In-scope requirements

- `ConverseLoopDriver` widening: new lazy closures in the `asrProvider`/`cleanupProvider`
  shape — `intentProvider: @Sendable (String) async -> IntentResolution?` and an action
  handler `@Sendable (ActionInvocation) async -> IntentActionReply?` (the spoken reply
  text after the terminal decision, nil = silent). Wired between `clean` and the reply
  call (`ConverseLoopDriver.swift:326`).
- Pipeline branch: `.ask(question)` → the question is the spoken reply; `.toolCall` →
  the handler's reply; `.none`/nil → the existing reply generator, byte-identical
  behavior for the unwired case.
- Bounded re-ask: a second consecutive `.ask` resolution → fall through to `.none`/echo
  (bound 2, pinned by a test).
- The frozen-signature compile pin (`ConverseLoopDriverTests.swift:362-374`) is updated
  **deliberately** with the new parameters — a reviewed edit, not a bypass.
- `ConverseTurnFailure` stays untouched unless the handler leg needs a new failure case
  (decision: failures are returned values; the driver's silent-return discipline holds —
  the handler returning nil or an error-string is the honest-drop channel).

## Out-of-scope boundaries

- No change to `ReplyGenerator` (synchronous by frozen doctrine; the async leg lands on
  the driver, not the seam). No card presentation here (that is `action-round-trip`'s
  handler). No `TextInjector` anywhere (the prohibition leg). No capture/ASR/cleanup/TTS
  changes. No change to the dictation path.

## Acceptance criteria (test-first)

1. An `.ask` resolution makes the driver speak the question text and touch no provider.
2. A `.toolCall` resolution routes through the handler; the handler's reply is spoken.
3. `.none`/nil reproduces today's echo behavior byte-for-byte (the existing driver tests
   keep passing with only the pin's new parameters).
4. Two consecutive `.ask`s → the second falls through to the reply generator (bounded).
5. The widened init compiles at the pin with the two new closures defaulted to nil-safe
   no-op behavior for existing call sites (or explicit at all call sites — the pin test
   is updated in the same commit, never edit-to-match a broken build).

## Dependencies and sequencing

Depends on `intent-seam` (the vocabulary). Independent of `action-round-trip`'s wiring
(the handler is a closure the wiring supplies later). Tests use stub handlers.

## Open questions / risks

The widened signature touches every `ConverseLoopDriver(` call site (the wiring, the
probe drive, the pin test, any test doubles) — the plan must enumerate them. The
frozen-signature doctrine is the reviewed-edit mechanism; the commit message states the
widening explicitly.