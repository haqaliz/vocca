# Aspect spec: reply-carrier

> Source: `docs/planning/reply-text-rendering/prd.md` R1, R3, R6, gap-1/2 pins · Date
> 2026-10-01.

## Problem slice and user outcome

The carrier: the driver's additive reply sink, the emission points (the reply at
`scheduleReply`, the ask path — gap 1, the barge-in/idle clears), and the wiring that
folds it into the widget store. User outcome: the reply text reaches the widget at
exactly the lifecycle moments the PRD pins.

## In-scope requirements

- **The sink**: `ConverseLoopDriver` gains `converseReplySink: (@Sendable (String) ->
  Void)?`-shaped (additive, default nil-shaped — byte-identical when not wired; the
  fourteen-parameter widening precedent).
- **The emissions**: the reply text at `scheduleReply` time (before/alongside audio);
  the **ask path** (the bounded re-ask's question is a reply — it must reach the sink
  too; verify the ask speaks through a path the sink covers); the clears: on listening
  (the next utterance) and on idle; on barge-in (the cancel path emits the clear —
  Q3).
- **The `replyFailed` pin** (critique gap 2): on synthesis/playback failure the text
  STAYS in the bubble (the reply happened as text; nothing was heard — the text is more
  valuable, recorded).
- **The wiring**: `AppBootstrap` wires the sink into `root.widgetStore` via the new
  store fold (the AppBootstrap:592-601 seam shape) — an `AppBootstrap.swift` change →
  the **G5 re-anchor** in REFACTOR (deliberate, computed, dictation digests unchanged).
- **Tests**: the emission points over a recording sink (the reply, the ask, the clears;
  the barge-in clear; the replyFailed keep).

## Out-of-scope

- The reducer state (own aspect), the view (own aspect); the audio path (unchanged).

## Acceptance criteria (test-first)

1. A committed turn with a reply → the sink receives the reply text once, at
   `scheduleReply` time.
2. The ask path's question reaches the sink.
3. Barge-in mid-reply → the sink receives the clear.
4. The next utterance (listening) and idle → the sink receives the clear.
5. `replyFailed` → no clear is emitted (the text stays).
6. The unwired default is byte-identical (no sink, no emission).
7. G5 re-anchored deliberately.

## Dependencies / sequencing

First. Before `reply-state` (the wiring's fold needs the store method) — or parallel
with it (the aspect order in review: carrier → state → view).

## Open questions

- None — the emissions and the replyFailed rule are the recorded resolutions.