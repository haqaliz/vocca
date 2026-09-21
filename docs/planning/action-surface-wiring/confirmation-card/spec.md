# Spec: confirmation-card (widget panel card)

> Aspect of `action-surface-wiring` (C13 slice 5). Source: PRD R2, the interview decision
> (widget panel card), the C12 reducer-row precedent, the PRD review's re-prompt default.

## Problem slice

The gate returns `.confirmationRequired(summary)`; nothing renders it. The first
human-in-the-loop safety surface must show the provider's sentence verbatim and be the
only route to `invoke` in the shipped configuration — without stealing focus from the
target app and without any "don't ask me again" affordance (M4a).

## In scope

- **`WidgetConfirmationState`** in `VoccaUI` (renders Core types only): the sentence, the
  provider/tool identity (for the card's heading), and a generation token so a stale card
  cannot be confirmed after the state moved on.
- **Reducer row** (`WidgetAction.confirmation(WidgetConfirmationSignal)`, the C12
  `contextChanged` precedent): presenting sets the card; the card survives every adoption
  (the `adopting` carry — egress/context precedent) and is **not** collapsed by
  `deliveredCollapse` or any timer; it clears only via explicit decline/confirm/dismiss
  actions. One card at a time (presenting over an existing card replaces it — per
  invocation).
- **Store entry points** (`WidgetStateStore`): `presentActionConfirmation(_:)`,
  `dismissActionConfirmation()`.
- **Panel rendering** in `WidgetPanel`/`WidgetView`: a card with the sentence verbatim,
  Confirm and Decline buttons, copy in `WidgetCopy` (pinned). The Confirm button invokes a
  closure supplied by the wiring (the `MenuBarItem` closure-seam precedent) — VoccaUI never
  names a provider or the gate.
- **The re-prompt default** (PRD review): the wiring's mismatch handling renders a fresh
  card with the gate's current sentence — the reducer needs no special case; the wiring
  presents again.
- M4a: no "remember"/"don't ask again" state exists anywhere in the reducer or the type.

## Out of scope

- The arm surface (Actions-tab aspect), the executor/gate calls (wiring), hotkey
  affordances (buttons only), anything that names `VoccaActions` types.

## Acceptance (tests written first)

1. Presenting a confirmation renders the exact sentence (reducer state carries it
  verbatim).
2. The card survives adoption of any other projection (recording, conversing, notice) —
  no timer or projection clears it except the explicit dismiss/confirm/decline actions.
3. Decline/dismiss clears the card; a cleared card's confirm closure is never invoked.
4. A stale card (generation mismatch) cannot confirm: the store refuses the wiring's
  confirm for an already-replaced card.
5. One card at a time: a second presentation replaces the first; the first's closure is
  never invoked.
6. No "don't ask again" affordance exists: the reducer has no such state row and the copy
  has no such string (copy pin).
7. The rendered UI is SwiftUI — executed by nothing in CI (stated in the aspect's record);
  CI asserts the reducer, the store, and the copy pins.

## Dependencies & sequencing

- Independent of the store/executor aspects (the wiring supplies the closures).
- The wiring aspect consumes the store entry points.