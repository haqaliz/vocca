# Aspect: `general-tab-recorder`

**Unit:** `hotkey-rebinding` · **Depends on:** all four earlier aspects
**Modules:** `VoccaCore` (recorder reducer + copy decisions), `VoccaUI` (the view, thin glue)

## Problem slice

After the first four aspects a binding can be validated, stored, applied and checked — and the only
way to set one is to edit a plist by hand. This aspect is the surface, and it is also where the
unit stops lying: `SettingsCopy.hotkeyNotRebindable` — *"Rebinding isn't available yet. ⌥Space is
the only shortcut for now."* (`SettingsTab.swift:83-84`) — becomes false the moment this ships.

**User outcome:** Settings → General, click the shortcut, press a chord, done — and it works on the
next press.

## In scope

- **S1 — the recorder**, as a Core-owned pure reducer plus thin view glue (the house pattern:
  `AppsTabState`/`EnginePickerStateReducer`/`OnboardingReducer`). States: idle → recording →
  (accepted | refused(reason) | warned(reason, pending confirm)). **Escape aborts** without
  arming; **Return commits**; clicking away aborts. No time-based transition exists in the reducer,
  per the house rule.
- **M9 — copy, pinned.** `hotkeyNotRebindable` is **deleted**. The tab gains a line stating plainly
  that Vocca cannot see shortcuts owned by other applications. `SettingsCopy` gains its **first
  byte-for-byte pin test** — it has never had one (PRD R5), so today deleting that string is a
  change no test would notice.
- **M10 — the displayed chord is live.** `SettingsBindings.hotkeyDisplayName` becomes a closure; it
  is today a plain `String` captured once (`SettingsView.swift:24-152`) while the window is built
  once and kept for the process lifetime (`AppBootstrap.swift:1031-1035`), so a rebind would leave
  it stale until relaunch. The **menu bar** (`MenuBarItem(hotkey:)`, `AppBootstrap.swift:519-520`)
  and **onboarding**'s "Hold ⌥Space" copy carry the same defect and are fixed with it.
- **M5's refusal, surfaced** — a rebind attempted mid-dictation shows in the tab rather than only
  in the log.
- **M12 — `PRODUCT_SPEC.md:252` amended.** Its unqualified "conflict detection against system
  shortcuts" is not deliverable (§5.3). **The replacement wording is drafted in this aspect's plan
  and approved by the founder before it is written** — "amend the spec" is not a blank cheque.

## Out of scope

- Widget position, launch at login, sounds — the other `PRODUCT_SPEC.md:252` rows, still deferred
  from `settings-live-controls/prd.md:175`.
- A Converse-mode second chord (P3).
- Any change to the activation-mode control beside it.

## Acceptance criteria (tests written first)

1. **The reducer's decision table**, one test per transition, including: Escape aborts from
   `recording` and leaves the binding untouched; a refused chord returns to `idle` with the reason
   shown and nothing persisted; a warned chord requires an explicit confirm.
2. **No time-based transition exists** in the action set — a closed-set test, the
   `WidgetStateReducer`/`AppsTabState` rule.
3. **The copy is pinned byte-for-byte**, including the new "cannot see other applications'
   shortcuts" line, and **`hotkeyNotRebindable` no longer exists anywhere in `Sources/`** — a scan,
   so it cannot survive as dead code.
4. **The three surfaces never disagree**: the tab, the menu bar and onboarding all render the
   current chord through `binding-vocabulary`'s one formatter — the `settings-live-controls`
   three-surface-agreement precedent, which is the test that caught the stranded-OPENING defect.
5. **A stale chord is impossible after a rebind** — asserted over the binding closures, not the
   view: reading twice across a rebind returns two different values.
6. **A mid-session rebind attempt surfaces `.refused`** rather than silently no-op'ing.

## Dependencies & sequencing

Last. Depends on all four. **Executed by nothing in CI** — no window server on a hosted runner
(the window-server precedent) — so the reducer, the copy pins and the surface-agreement test are
the tested half, and the panel's first execution is a smoke step.

## Open questions / risks

- **OQ2 from the PRD lands here, and it can move the aspect's size:** whether the recorder captures
  through the existing tap (already receiving the whole keyboard, no new API family) or a
  window-scoped local monitor (contained, but likely a new seam row and a lint update). Decide in
  the plan, before writing the view.
- The exact `PRODUCT_SPEC.md:252` replacement wording is unresolved and needs founder sign-off.
