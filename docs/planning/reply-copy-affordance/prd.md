# PRD — Reply copy affordance (N1)

**Issue:** #64 · **Capability:** C13 follow-on · **Phase:** P4 (reachability slice, no gate)

## Problem

The reply bubble is rendered in a window that is deliberately never key
(`WidgetPanel.canBecomeKey == false`). The text is `.textSelection(.enabled)`, but selecting
text in a non-key window is unreliable, and selecting a long reply with the mouse is not a copy
affordance. A user who wants the agent's answer has no dependable way to get it out.

This was recorded as N1 by `reply-text-rendering` and is the last user-facing gap in the reply
surface.

## Requirements

| ID | Requirement |
|----|-------------|
| R1 | While a reply bubble is shown, a copy control is shown in it. |
| R2 | Activating it copies the **full** reply text verbatim to the general pasteboard. |
| R3 | The panel does not become key and Vocca is not activated. The target app keeps focus. |
| R4 | `VoccaUI` names no pasteboard type; the write is injected by the composition root through the existing `ShippingPasteboard` adapter. |
| R5 | The reply seam and the rendering contract are unchanged: the bubble still shows exactly when `WidgetCopy.shouldShowReplyBubble` says so, and the text is still carried verbatim. |

## Non-goals

- Copy history, per-turn copy in the Conversation tab, or a keyboard shortcut.
- Changing the reply generator, the reducer, or the carrier.
- Any network path.

## Acceptance

1. `WidgetCopy.replyCopyAffordance` and its accessibility label are pinned by exact equality.
2. The view wires the control to an injected `(String) -> Void` carrying the reply text.
3. The panel accepts the first mouse click while inactive, so the control works without focus.
4. The composition root wires the control to `ShippingPasteboard.write`; `VoccaUI` remains
   pasteboard-free (the existing seam lint stays green).
5. The existing reply-bubble suite is unchanged and green.

## Risks

- **First-mouse click is window-server behaviour and is executed by nothing in CI.** Source pins
  and one SMOKE row are the proof; the live click remains a manual observation.
- Copying does not restore the user's previous pasteboard contents — a copy is a deliberate
  overwrite, the same contract as the failsafe's ⌘C.
