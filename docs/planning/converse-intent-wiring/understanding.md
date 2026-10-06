# converse-intent-wiring — Phase 2 understanding (2026-10-07)

Layer: voice loop → actions (C11/C13 seam), P3/P4. Local-only; no cloud, no new process. No gate passes.

## What the work is
Make the shipped converse path call the intent leg. Today `AppBootstrap.swift:583` calls
`composeConverseWiring` without `intentProvider`/`intentActionHandler` (defaults nil,
`ConverseWiring.swift:89-91`), so every utterance echoes; `root.intentWiring` (set at ~:747) is read only by
the probe. Mechanically small: pass two lazy `[weak root]` closures reading `root.intentWiring` at call time
(the `converseReplySink`/`sessionActive` precedent). Ordering is a non-issue — the Task body at :583 runs
after `configure` returns, and lazy reads see the wiring.

## Corrections to my own brief
The card-up guard and `auditRecorded == false` handling are in `IntentWiring.performAction`
(~:213-360), not the driver. The driver only does ask/toolCall/none routing (`ConverseLoopDriver.swift:412-441`).

## Findings that change the scope (all trust-surface)
1. **The user hears an echo while a destructive-action card is up.** `performAction` returns nil for
   `.confirmationRequired`, the card-up refusal and `.notInvoked`; the driver then falls through to
   `replyGenerator.reply(to: raw)` — Vocca speaks the user's own words back while the card shows
   (pinned today as the "honest-drop fall-through", `IntentDriverIntegrationTests:174-182`). Once voice can
   really act, silence-then-echo on "wipe the log" is a UX trap: the user is not told a confirmation is
   waiting.
2. **No spoken confirm/decline exists** — card clicks only. Voice approval would be a new trust surface (N2:
   an approval asserts a human said yes; ambient audio or the app's own TTS could say "yes"). Deferred.
3. **A card can land mid-conversation** — `IntentWiring` has no session-active guard (`ActionWiring:269`
   refuses to arm during a session; the voice leg does not). The card persists after the session ends
   (reducer keeps `confirmation` across state changes). Whether the panel lays out a card together with the
   reply bubble is unverified — only a real-machine look can show it.
4. **Reachability is still file-authoring.** A phrase needs a hand-edited `intent-phrases.json` plus an
   enabled tool (Actions tab); no phrase UI exists. After this unit voice acts for exactly the user who
   authored both — the intended two-step opt-in, but it means the capability is founder-only until a phrase
   surface exists.
5. Default stays byte-identical: no file / no enabled tool → `.none` → echo; `PROBE-CONVERSE` line unchanged
   (counts only). Shell cannot be phrased (refused at load); keyword switch stays off by default and
   excludes shell + coding agents.
6. G5 re-anchors once more (`AppBootstrap.swift` edit); twentieth unit ahead of the uncleared P3→P4 /
   P4→P5 gates; R8 enters a real voice path for the first time.

## Open questions → PRD
- Q1 what is spoken when a card is up (recommend a fixed "Confirm on screen." — see PRD).
- Q2 how to test without `configure` (needs NSApplication): extract the closure construction into a static.
- Q3 mid-conversation card: accept and record, or refuse while a session is active (recommend accept).
