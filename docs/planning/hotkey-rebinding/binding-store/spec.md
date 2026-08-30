# Aspect: `binding-store`

**Unit:** `hotkey-rebinding` · **Depends on:** `binding-vocabulary`
**Modules:** `VoccaCore` (seam + decode), `VoccaUI/Settings` (the one adapter file), `VoccaBootstrap`

## Problem slice

The chord is a compiled-in constant — `AppBootstrap.shippedHotkeyKeyCode: UInt16 = 49`
(`AppBootstrap.swift:573`) — with **no persisted counterpart anywhere in the repo**. Nothing reads
a binding at launch because there is nothing to read. Until there is, a rebind cannot survive a
relaunch, which is the whole point.

**User outcome:** a chosen chord is still the chord after a restart.

## In scope

- **M1** — `keyCode` and `modifiers` join the `SettingsStore` protocol
  (`VoccaCore/SettingsStore.swift:43-59`) beside `activationMode()`. Reads synchronous and total;
  writes best-effort and non-throwing, per the seam's stated contract (`:25-35`).
- Decode through `PersistedSettings`' existing three-answer contract: **absent → ⌥Space, silent**;
  **malformed → ⌥Space plus exactly one loud report**; **known → the value, silent**.
- **M2** — the keys live in `UserDefaultsSettingsStore.swift`, the one file permitted to name
  `UserDefaults` for the `settings` seam (`InjectionSeamBoundaryTests.swift:1453-1481`). Reads go
  through the existing `rawValue(forKey:)` so a stored non-string takes the loud path rather than
  reading as absent.
- Two keys, not one: `settings.hotkey.keyCode` and `settings.hotkey.modifiers`, so a half-written
  pair degrades to the default rather than to a chord nobody chose.
- **M3** — `AppBootstrap` reads the binding at launch and builds both `HotkeyConfiguration`s from
  it, replacing the hardcoded call sites (`AppBootstrap.swift:399-400,437-438`). Both activation
  modes continue to share one chord.
- A stored binding that **fails `binding-vocabulary`'s validity check** is treated as malformed —
  default plus one loud report. A refused chord must not become reachable by editing a plist.

## Out of scope

- Changing a binding at runtime (`rebind-boundary`) — this aspect ships launch-read only.
- Any UI. After this aspect a binding is settable only by writing defaults by hand, which is
  deliberate: it is the same staging the cleanup config shipped in (`cleanup-config.json` before
  the Cleanup tab).

## Acceptance criteria (tests written first)

1. **Absent ⇒ ⌥Space, and nothing is logged.** The silent half of the contract.
2. **Malformed ⇒ ⌥Space plus exactly one report** — asserted as *exactly one*, per the existing
   `PersistedSettings` tests, driven over: non-numeric, out-of-range, a stored non-string, one key
   present and the other absent, and a chord `binding-vocabulary` refuses.
3. **A valid stored binding round-trips** through set → read, over a table including the shipped
   default, a modified chord, and a safe single key.
4. **The launch read reaches both machines** — after `configure`, the hold-to-talk and toggle
   configurations both carry the stored chord and differ only in `activation`.
5. **Caps Lock is masked before storage**, so a stored binding can never carry a bit that cannot
   match.
6. **The seam lint still passes**: no second file in `Sources/` names `UserDefaults`.
7. **Nothing changed for an existing install.** With no stored keys, `configure` produces byte-for
   byte today's two configurations — the `pipeline-wiring` B2 precedent.

## Dependencies & sequencing

Needs `binding-vocabulary` for the validity check on read. Build second. Fully headless.

## Open questions / risks

- Whether the completion of this aspect alone should delete `SettingsCopy.hotkeyNotRebindable` —
  **no**: after this aspect it is still true for any user who cannot edit a plist. It is deleted in
  `general-tab-recorder`, with its replacement.
