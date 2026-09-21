# Spec: wiring (composition root + probe + G5)

> Aspect of `action-surface-wiring` (C13 slice 5). Source: PRD R7, R9, S1 + the C11/C12
> additive recipe (`ContextWiring.swift`, `ConverseWiring.swift`), the G5 pin contract.

## Problem slice

The machinery and the surfaces exist; nothing composes them, and no shipped configuration
can execute an action. This aspect makes the composition real, keeps the zero-network /
no-spawn default provable, and re-anchors G5 the way C11/C12 did.

## In scope

- **`ActionWiring.swift`** in `VoccaBootstrap` (`extension AppBootstrap`, the
  `composeActionWiring(...)` shape):
  - Builds the `ActionExecutor` over the real `FileSystemActionAuditStore`.
  - Builds the `ActionConfigStore` (real dir), the policy floor — **`.none`, named in a
    comment as the recorded decision** (F1/F2 fail-safes already confirm absent claims;
    a stricter floor breaks M3).
  - The confirmation-card closures: present → `root.widgetStore.presentActionConfirmation`;
    confirm → executor submit with `.granted` and the **exact sentence shown** → fold the
    outcome into the widget (notice) + dismiss; mismatch → re-present a fresh card (the
    PRD review's default); decline/dismiss → executor records the refused decision + clear
    the card.
  - The arm refusal: arming while a session is in flight is refused (the C11 in-flight
    refusal precedent) — the recipe reads a session-active flag supplied by the root.
  - The `spawnsSubprocess` fact fold: the composed default reports `servers=0` and
    `spawnsSubprocess=false` into the probe line (the `requiresNetwork` analogue).
  - **Probe-safe by construction**: nothing spawns, reads, or starts at composition time
    (the `ContextWiring` recipe's doc contract).
- **Root slots** on `DictationLoopRoot` (nullable, defaulted — the converse/context
  precedent): action executor, config store, action confirm/decline closures, actions-tab
  bindings.
- **`AppBootstrap.configure`** composition (additive, inline task — the context
  precedent).
- **Probe**: `PROBE-ACTION-SURFACE` drive (or an extended `exerciseActionAudit`):
  executor round trip over real temp stores — arm `audit.clear` → `confirmationRequired`
  (sentence) → grant with the shown sentence → `invoked` → reload → reconstruct; plus the
  binding-mismatch refusal path; plus the composed default's fact line. Expected-lifecycle
  constant + **guard-the-guard** test refusing a weakened golden string
  (`ZeroNetworkTests` precedent). The module-coverage cross-check stays green (no new
  module).
- **G5 re-anchor**: `AppBootstrap.swift` digest recomputed and edited in the same commit
  (never edit-to-match); `SessionMachine.swift` and `DictationPipeline.swift` digests
  unchanged (asserted by the pin).
- **Wiring-family lint**: the `ContextWiringSeamBoundaryTests` shape — a permitted set for
  the action-wiring family (recipe file, `AppBootstrap.swift`, the probe drive file) and a
  no-action-family-names-in-the-pinned-dictation-files assertion.

## Out of scope

- The card UI, the tab UI, the store internals (their aspects own them); the intent layer;
  any change to the dictation path.

## Acceptance (tests written first)

1. The composed executor's arm → confirm → invoke → audit-reconstruct path runs headless
  over real temp stores inside the zero-network interposer (the probe line proves it:
  `servers=0`, `spawnsSubprocess=false`, a `confirmed` entry reconstructing).
2. The binding mismatch path through the wiring: a sentence that changed between show and
  confirm is refused and a fresh card is presented (asserted at the wiring level by
  attempting the call).
3. Arming while a session is in flight is refused (wiring-level test with a session-active
  stub).
4. The G5 pin: dictation digests unchanged; `AppBootstrap.swift` re-anchored deliberately.
5. The wiring-family lint: no action-family name in the two pinned dictation files; the
  permitted set is exactly the recipe, `AppBootstrap.swift`, and the probe drive.
6. The zero-network test stays green over the new probe line (the full default-configuration
  probe run).
7. The transport prohibition lint's permitted set is unchanged (exactly one file).

## Dependencies & sequencing

- All other aspects first (binding, store, executor, card, tab).
- This aspect's commit re-anchors G5 exactly once.