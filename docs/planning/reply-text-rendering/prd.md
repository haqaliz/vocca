# PRD: Reply Text Rendering

> Source: the deferred `reply-text rendering` item (`docs/technical/CAPABILITY_ROADMAP.md:340`,
> 564 — "stays deferred to the C13 design pass", `PRODUCT_SPEC.md:379` whose section has
> since drifted) + the 2026-10-01 dig. Founder decisions Q1–Q3 recorded below. C13 slice.

## Problem Statement

The CONVERSING surface speaks but never shows: the reply is audio-only end to end
(`ConverseLoopDriver.renderReply` → TTS → playback — no text survives to the widget; the
dig verified there is no carrier at all). The widget's five mode cues are all that render
during conversation. The user hears "Done." / "Cancelled." / the echoed reply — but
cannot see it, cannot re-read it, and a missed reply is gone forever (barge-in discards
it cleanly — in audio only). Every other text surface in the product (the failsafe, the
confirmation card, the audit) renders its text; the voice loop is the one surface that
does not.

What happens if we don't build this: the wedge's visible face is audio-only; the founder
(and any user) must either re-ask or watch an empty pill; the "smarter than SKI" loop
reads like a one-way radio.

## Goals & Success Metrics

- **G1 — The reply is visible.** The CONVERSING surface renders the spoken reply's text
  in a bubble beneath the pill (Q2), verbatim (the sentence doctrine), bounded (the
  failsafe precedent: scroll past a bound, never truncate silently).
- **G2 — The lifecycle is the conversation's** (Q1): the bubble shows when speaking
  starts; it clears when the next utterance begins (listening) or the session ends
  (idle).
- **G3 — Barge-in discards text too** (Q3): an interrupted reply's bubble clears
  immediately — text and audio discarded cleanly together (the C10 record's wording).
- **G4 — Mode clarity survives.** The five cues stay in the pill; the bubble is an
  addition, never a replacement (Q2). The structural never-a-target render stays.
- **G5 — Invariants hold.** The `WidgetAction` closed set's amendment is deliberate
  (one new action); the "phase is the state's only content (D1)" invariant is amended
  deliberately and pinned; the composed default facts unchanged; zero network; the
  dictation path untouched; lints green.

## User Personas & Scenarios

- **The founder (primary).** Converse: "ask claude to summarize the open PRs" → the card
  → Confirm → "Done." is spoken AND appears in the bubble under the pill; the agent's
  real reply (the ack) is visible. Barge in mid-reply → the bubble vanishes with the
  audio. Next utterance → the bubble clears and the cycle repeats.
- **The noise-averse user.** Wants the loop without speakers: the bubble is the reply.

## Requirements

### Must-have

- **R1 — The carrier**: the driver gains an additive reply sink (`converseReplySink:
  (@Sendable (String) -> Void)?`-shaped, default nil-shaped — byte-identical when not
  wired); the driver emits the reply text at `scheduleReply` time (before/alongside
  speaking). The wiring wires it into the widget store.
- **R2 — The state**: `WidgetReducerState` gains `replyText: String?` (bounded — a named
  cap in the reducer, the `maxPartialCharacters` shape, e.g. 2000 characters; the view
  scrolls beyond it, the failsafe precedent); the `WidgetAction` closed set gains one
  action (`.replyPresented(String?)` — nil clears); the store gains the thin fold
  method (the `presentPartial` shape).
- **R3 — The reducer rule** (Q1, Q3): `replyText` set at speaking; cleared on listening
  (a new utterance) and idle; cleared on barge-in (the interrupted reply's effect
  cancels — the driver emits the clear). The invariant amendment: "the phase is the
  state's only content" → "the phase plus the bounded reply text" — pinned in the
  closed-set sweep and the invariant probe.
- **R4 — The view**: the CONVERSING branch renders the pill (unchanged cues) + a bubble
  (the confirmation-card precedent: material, hairline, verbatim text, `.fixedSize`
  wrap, `ScrollView` past the bound; `textSelection(.enabled)` — the failsafe
  precedent); the panel refits via the existing `fittingSize` mechanism.
- **R5 — Accessibility**: the bubble's VoiceOver label is the reply text (the pinned
  label doctrine — `WidgetCopy` additions + pins).
- **R6 — Probe/pins**: the composed default facts unchanged; the G5 re-anchor if
  `AppBootstrap` changes (the wiring wires the new sink — likely); the `ConversePhase`
  family lint untouched (the field lives in VoccaUI, outside the scan root); SMOKE 164
  (the real spoken exchange with the bubble observed).

### Should-have

- **S1 — The spoken acks render** ("Done."/"Cancelled."/the failure copy — they are
  replies; the bubble shows them automatically once the carrier exists; verified, not
  special-cased).

### Nice-to-have

- **N1 — A copy affordance** on the bubble (⌘C to copy the reply) — deferred, recorded
  (the failsafe's ⌘C precedent).

## Technical Considerations

- **Phase:** P3 surface completion, C13 slice. Branch from master.
- **The carrier's seam**: the driver already sinks `TurnState` through
  `converseStateSink`; the reply text rides a sibling sink (the additive closure
  doctrine — the driver's fourteen-parameter init widened before). The wiring folds it
  into the store (the AppBootstrap:592-601 seam).
- **Bounds**: the reducer owns the cap (never an unbounded string in state — the
  partial-text doctrine); the view scrolls (the failsafe's 48–160 pt shape).
- **Mode clarity**: the bubble is beneath the pill, never replacing it; the never-a-
  target render pin stays.
- **Lints**: the `WidgetAction` closed set + the invariant probe are amended
  deliberately (the reducer tests' closed-set sweep carries the new action); VoccaUI
  imports only VoccaCore (the field + copy live in VoccaUI).
- **Dictation path**: untouched (digest-pinned).

## Risks & Open Questions

- **R-A — The bubble grows unboundedly**: capped in the reducer + the view scrolls (the
  failsafe precedent) — never truncated silently (a truncated reply is a different
  reply).
- **R-B — The bubble fights the mode cues**: the pill's cues stay; the bubble is
  addition-only (Q2) — the mode-clarity gate's zero-mis-injection stays structurally
  unchanged.
- **R-C — The carrier races the audio**: the text is sunk at `scheduleReply` (before
  audio starts) — the bubble appears with the speech, cleared by the same events that
  cancel the audio (barge-in, idle, next turn). The reducer rule is the single source.
- **Open:** the bubble's exact bound (2000 chars proposed — the view scrolls past it;
  the SMOKE row observes a long reply).

## Out of Scope

- The turn-history deliverable (`ROADMAP.md:205` — "bounded, inspectable, local turn
  history with a visible forget control" is a separate, unclaimed P3 item — recorded).
- A copy affordance (N1), any change to the safety spine, the dictation path, the
  audio path (the reply is still spoken — the bubble is additive).