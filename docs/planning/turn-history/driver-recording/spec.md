# driver-recording — aspect spec

Aspect 2 of `turn-history`. Source: `../prd.md` (approved 2026-10-11), `../history-store/spec.md`
(the seam it records through). Planning decisions: recording is **awaited at commit** in
`runUtterancePipeline` (strict ordering — see D2 in `plan_20261011.md`); the barge-in mark is
delivered on every barge-in and attributed by the store; the recorder parameter is additive and
defaulted, so probes and existing suites are byte-identical.

## Problem slice / outcome

The `ConverseLoopDriver` becomes the one place a completed turn is captured: cleaned utterance +
spoken reply recorded when the reply is committed, the interrupted mark when a barge-in lands,
failed turns never recorded. No UI, no store implementation, no composition change in this
aspect (`composeConverseWiring` gains only a defaulted parameter).

## In scope

- `VoccaCore/Conversation/ConversationRecording.swift` (shipped by aspect 1) used as the driver's
  seam.
- `ConverseLoopDriver.init` gains `conversationRecorder: (any ConversationRecording)? = nil`
  (after `converseReplySink`); stored; called at the reply-commit point in
  `runUtterancePipeline` (`await recorder.recordTurn(utterance: cleaned, reply: reply)`, before
  `loop.scheduleReply(reply)`) and at the `.bargeIn` effect application
  (`Task { await recorder.markLastTurnInterrupted() }`).
- `composeConverseWiring` gains the same defaulted parameter and passes it through.

## Out of scope

The store (aspect 1); any AppBootstrap edit (aspect 3 — G5 untouched here); reply-bubble behavior
(the `converseReplySink` path is untouched); failure-copy behavior; mode/machine changes.

## Acceptance criteria (the failing tests, written first)

D1 **Record at commit**: with a spy recorder injected into the scripted driver harness, one
completed turn calls `recordTurn` exactly once, with the **cleaned** utterance and the exact
reply; the call is observed **before** the `.speakReply` effect is applied (ordering asserted by
the ledger, not assumed).
D2 **Interrupt attribution**: after a reply is committed, a barge-in delivers exactly one
`markLastTurnInterrupted`; a subsequent turn records normally and is not affected by the earlier
mark; the driver calls the mark for every barge-in (the store owns the empty-store no-op).
D3 **Failed turns skipped**: `asrFailed` / `replyFailed` / `captureFailed` turns produce zero
recorder calls; a user stop with no committed reply produces none; an ask turn and an action ack
turn both record (their reply is the spoken text at the one `.speakReply` point).
D4 **Default neutrality**: with the defaulted `nil` recorder the driver is byte-identical to
today — `TurnTakingComposedAcceptanceTests`, `ReplyRenderingInvariantTests`,
`ReplyCarrierTests`, `ConverseIntentWiringTests` and `ConverseLoopDriverTests` all stay green;
`PROBE-CONVERSE` composes by default and its line is byte-identical.
D5 **Foundation-free**: `VoccaCore` stays import-free (the protocol declares no imports; the
`CoreBoundaryTests` seam stays green); the driver stores `(any ConversationRecording)?` — no
`VoccaConversation` type reaches `VoccaCore`, and `ConverseLoopDriver` names only the protocol.

## Risks

The record call adds one actor hop + one small file write before playback scheduling (off the
audio path; **no latency number is claimed**). Ordering is the load-bearing property: awaiting
the record before `scheduleReply` is what makes D2 provable — a fire-and-forget record would
race the barge-in and mark a neighbor (PRD gap 2).
