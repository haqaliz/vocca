# Spec: actions-tab (Settings tab + arm surface)

> Aspect of `action-surface-wiring` (C13 slice 5). Source: PRD R4, R5, R6, S2, N1 + the
> interview decisions (new "Actions" tab, one store file, Invoke/Preview rows, explicit
> "Discover tools" that spawns).

## Problem slice

Servers cannot be configured, tools cannot be enabled, and no human can arm an action.
The D2 copy must sit on the surface; discovery must be explicit and spawn-aware; the arm
path must run through the gate only.

## In scope

- **`SettingsTab.actions`** — new case, title, symbol (`allCases`-driven sidebar; a case
  that exists gets a page or the build fails).
- **`ActionsTabState`** (reducer): servers (list/add/remove/edit fields), discovery states
  (`idle`/`discovering`/`succeeded([tools])`/`failed(key)`), per-tool enablement rows
  (default off), arm states (`idle`/`awaitingConfirmation`), preview states. The
  "Discover tools" action is **explicit and user-initiated**; the D2 copy is shown at that
  moment.
- **`ActionsTabPage`** + `ActionsTabCopy` (strings pinned, D2 copy exact-in-spirit:
  "configuring a server is trust extended to its author, not a guarantee we can make").
- **`SettingsBindings`** gains defaulted closures (claim-nothing defaults, the C12
  convention): `loadActionsConfig`, `saveActionsConfig`, `discoverTools(forServerID:)`,
  `setToolEnabled(providerID:toolID:enabled:)`, `armAction(providerID:toolID:)`,
  `previewAction(providerID:toolID:)`, `confirmationPresented()`/`confirmationDismissed()`
  (the wiring needs to know the card appeared).
- VoccaUI stays `["VoccaCore"]`-only: the tab renders a view model built from Core types
  (`ActionInvocation`, `ActionSummary`) plus a plain `ActionsTabModel` (server rows:
  id/name/path) defined in VoccaUI; the wiring maps `VoccaActions` types into it.
- The tab never spawns and never names `Process`/`MCPProvider` (module lints stay green;
  the transport prohibition lint's exactly-one permitted file is untouched).

## Out of scope

- Argument-building UI (intent layer later); voice-triggered actions; per-server enable-all
  (nice-to-have N1, deferred); anything network.

## Acceptance (tests written first)

1. `SettingsTab.allCases` includes `actions` and the sidebar renders it (tab enumeration
  test).
2. Reducer: add/remove/edit a server; discover transitions `idle → discovering →
  succeeded` and `→ failed(key)` with the tool list held on success; enable/disable a tool
  flips its row; **default off** (a newly discovered tool's row is off; absent is off).
3. Arm: arming an enabled tool yields `awaitingConfirmation` (the wiring's card signal);
  arming a disabled tool is refused by the reducer (no confirmation signal emitted) —
  the M7 never-read rule holds at the surface.
4. Preview: `previewAction` yields the sentence with zero provider side effects (stub call
  log, asserted at the wiring level; the tab's state test asserts the preview row renders).
5. Copy pins: the D2 copy and the no-"ask again" strings are exact (the M4a pin at the
  copy layer).
6. Binding defaults: a `SettingsBindings()` constructed bare claims nothing and changes
  nothing (the C12 convention test).
7. The tab's files name no network family and no `Process`.

## Dependencies & sequencing

- `enablement-store` first (the tab's closures read/write it).
- The wiring aspect wires the closures; `confirmation-card` provides the card the arm
  signal targets.