# feat/reply-text-rendering — inline brief

No GitHub issue filed; the source is the deferred `reply-text-rendering` item
(`docs/technical/CAPABILITY_ROADMAP.md:340` — "stays deferred to the C13 design pass";
`:564` — the remaining-machinery list) and the founder's "if anything left go for it"
(2026-10-01).

## Brief

The CONVERSING surface is audio-only: the reply text has no carrier to the widget (the
dig verified end to end). This unit renders the spoken reply in a bubble beneath the
pill — verbatim, bounded, selectable — with the founder's lifecycle decisions:
Q1 the bubble shows until the next turn (or idle); Q2 the pill + bubble (the five mode
cues stay); Q3 barge-in clears the text with the audio. Gap resolutions: the ask path's
question reaches the sink; `replyFailed` keeps the text (nothing was heard — the text is
the record); VoiceOver is best-effort on the non-key panel (recorded). Out of scope: the
turn-history deliverable (a separate unclaimed P3 item), the copy affordance (N1).

## Labels (proposed)

feat, C13 slice, P3 surface