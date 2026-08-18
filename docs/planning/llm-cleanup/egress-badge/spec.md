# Spec — egress-badge

Aspect of `llm-cleanup` (C6) · `docs/planning/llm-cleanup/prd.md`
Requirements: **M8** (owned here).
Depends on: nothing inside C6 (VoccaUI-only; runs parallel to the providers). The
`root-wiring` aspect feeds it at the composition root and asserts it through the probe.

## Problem slice

`PRODUCT_SPEC.md:250-264` — the widget carries a persistent marker whenever an active
provider has `requiresNetwork == true`: **non-dismissable** while the cloud provider is
active, appearing "in the moment text would leave the machine", with hover copy stating
plainly where the text goes. `ARCHITECTURE.md:296` makes the seam's flag load-bearing: "The
widget reads it directly." Nothing reads `requiresNetwork` at runtime today — the badge is
the first consumer, and the widget store is the path it must flow through
(`WidgetStateStore`/`WidgetStateReducer`, the reducer shape that runs headless).

## In scope

1. **`WidgetEgressState`** in `Sources/VoccaUI/` — `.none` | `.active(endpoint: String)`.
   `WidgetReducerState` gains `egress: WidgetEgressState = .none`; the closed `WidgetAction`
   set gains `case egressChanged(WidgetEgressState)` (a deliberate edit to the closed set —
   the structural pins update with it, `WidgetStateReducer.swift:113-117`); the reducer
   stores it and no other action touches it (**no time-based transition exists** — the
   `FailsafeStateReducer` never-auto-dismiss precedent).
2. **The render.** `WidgetView` shows the ☁︎ glyph in the opening/recording/transcribing
   branches whenever `egress != .none` (the `PRODUCT_SPEC.md:250-264` mock places it in the
   recording pill, after the elapsed timer). Hover (the pill has no affordances today,
   `WidgetPanel.swift:94-97`): a display-only hover surface — `.help()` or a SwiftUI overlay,
   the first in the codebase — stating the endpoint copy. No focus implications: the pill
   never becomes key (`WidgetPanel.swift:90-99`).
3. **`BadgeCopy`** — pure constants/functions in the copy family shape (`WidgetCopy`,
   `EnginePickerCopy`): the glyph `☁︎` (U+2601 U+FE0F, byte-fidelity-pinned) and
   `egressHoverText(endpoint:)` = "Cleanup runs on <endpoint>. Your text is sent there."
   — pinned byte-for-byte to `PRODUCT_SPEC.md:250-264` (the `EnginePickerCopyTests` rule).
4. **Reducer decision table** — headless: `egressChanged` sets the state; every other action
   (timer fires, session effects, notices) leaves it untouched; there is no action that
   dismisses it.

## Out of scope

- The wiring that folds `egressChanged` (the composition root + probe assertion —
  `root-wiring`).
- The Cleanup tab and any provider-selection UI (`prd.md` Out of Scope).
- Any badge behavior beyond the pill (no settings-surface marker; `PRODUCT_SPEC.md:246`'s
  Privacy tab is the deferred settings surface's).

## Isolation / honesty decisions

- **The badge is reducer state, not view state.** The whole decision table runs headless;
  the view is thin glue (the house rule: "the window itself is thin glue over this type",
  `EnginePickerState.swift:40-41`).
- **Non-dismissable is structural**: no action in the closed set can clear an `.active`
  state — a test enumerates the closed set and asserts none of them touch egress.
- **"In the moment text would leave the machine" is launch-derived.** The provider is
  resolve-once (`cleanup-config`), so the badge is static per launch: visible for every
  session while an LLM rung is selected, absent otherwise. The spec's "moment" is satisfied
  because the badge precedes any session; a per-session flip-flop would be theater.

## Acceptance criteria (tests written first)

Failing XCTests in `Tests/HarnessTests/` — `EgressBadgeReducerTests.swift`,
`BadgeCopyTests.swift`:

- B1 **State + action shape.** `WidgetEgressState` with `.none`/`.active(endpoint:)`;
  `WidgetReducerState.egress` defaults `.none`.
- B2 **Reducer table.** `egressChanged(.active(endpoint:))` sets the state; every other
  action in the closed set leaves it untouched (enumerated); the closed set's structural pin
  updates with the new case.
- B3 **No dismissal exists.** No action in the closed set can transition `.active` to
  `.none` — the decision table asserts it (the never-auto-dismiss rule).
- B4 **Copy byte-fidelity.** The glyph and the hover template match `PRODUCT_SPEC.md:250-264`
  byte-for-byte; `egressHoverText(endpoint:)` interpolates the endpoint.
- B5 **State survives the session.** Timer actions (elapsed, esc-hint, ceiling) and session
  effects do not disturb `egress` — folded sequences asserted.
- B6 **Boundary discipline.** Full suite green under the floor; Swift 6 clean; Apache
  headers; no new dependency.

## Dependencies / sequencing

- None within C6 — may run in parallel with `ollama-provider`/`byok-provider`.
- `root-wiring` then: (a) folds `egressChanged` from the resolved provider's
  `requiresNetwork` + endpoint after resolve-once; (b) asserts `egress=none` through the
  probe's default path.
- Precedents: `WidgetStateReducer`/`WidgetAction` (the closed set + injected clock),
  `FailsafeStateReducer` (never-auto-dismiss), `EnginePickerCopy` + its contract test
  (byte-fidelity), `WidgetView` (the rendering branches).

## Open questions / risks

- **The endpoint string for the hover.** The badge needs the configured endpoint — Ollama
  shows `http://localhost:11434`, BYOK the configured URL. The provider exposes it (its
  identity or a dedicated property) and the wiring folds it in; the plan pins where it comes
  from without leaking the key (never the key — `byok-provider`'s hygiene).
- **Hover surface mechanics.** `.help()` on macOS shows a system tooltip after a delay and
  needs no key/focus; a custom overlay is prettier but new. The plan picks one; the smoke
  step (M10) verifies it on the founder's machine.
- **Which states render the glyph.** PRD: opening/recording/transcribing. A reviewer may
  argue DELIVERED too (text has left by then) — the PRD pins the three, and the smoke step
  checks both directions (visible while active, absent on rules).
