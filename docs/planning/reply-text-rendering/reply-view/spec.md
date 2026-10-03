# Aspect spec: reply-view

> Source: `docs/planning/reply-text-rendering/prd.md` R4, R5, gap-3 pin · Date
> 2026-10-01.

## Problem slice and user outcome

The bubble: the CONVERSING branch renders the pill (five cues unchanged) plus the reply
bubble (card/failsafe precedents — material, hairline, verbatim wrap, scroll past the
bound, `textSelection(.enabled)`), the `WidgetCopy` additions, the accessibility label,
and the panel refit. User outcome: the reply is visible, readable, and selectable.

## In-scope requirements

- **The view**: the `.conversing` branch renders the pill + (when `replyText != nil`) a
  bubble beneath it — the confirmation-card styling precedent (material, hairline,
  shadow), `.fixedSize(horizontal: false, vertical: true)` for the wrap, a
  `ScrollView` with the failsafe's bounded shape (48–160 pt) past the cap,
  `textSelection(.enabled)`.
- **The copy**: `WidgetCopy` gains the bubble's label/accessibility strings (pure
  functions, pinned — the `WidgetCopyTests` shape); the VoiceOver label carries the
  reply text (gap-3 honesty: the widget panel is non-key, so announcement is
  best-effort — recorded, the SMOKE row observes it).
- **The panel refit**: the existing `fittingSize` mechanism (no new sizing logic).
- **The mode clarity**: the pill's cues (notch, hue, `◈` label, tick, no target) are
  untouched; the bubble is addition-only; the never-a-target render pin stays.

## Out-of-scope

- The carrier/state (own aspects); the copy affordance (N1); any cue change.

## Acceptance criteria (test-first)

1. The conversing view renders the bubble when `replyText != nil` and not when nil
   (a surface-level test over the view's decision inputs — the `WidgetCopy` pure
   functions carry what is testable headlessly).
2. The bubble's text is verbatim (no paraphrase; the wrap only).
3. The copy pins: the new strings exact-equality pinned; the existing `◈` labels
   unchanged.
4. The never-a-target pin stays green.
5. The pill's five-cue inputs unchanged (the token tests green untouched).

## Dependencies / sequencing

After `reply-state`. Before `agent-pins`.

## Open questions

- None — the render precedents are the recorded decisions.