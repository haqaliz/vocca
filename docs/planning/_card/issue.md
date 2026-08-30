# Card: feat/hotkey-rebinding

**Type:** feat · **Id:** `hotkey-rebinding` (slug — no GitHub issue) · **Owner:** aliz
**Branch:** `feat/hotkey-rebinding/aliz` · **Worktree:** `.claude/worktrees/feat-hotkey-rebinding`
**Source:** inline brief (Vocca's GitHub Issues tracker is empty — `gh issue list --state all` returns "No Issues")

---

## Brief

Build hotkey rebinding for the General tab — the last unbuilt item in P0's scope envelope
(`docs/ROADMAP.md` P0 scope discipline: "No settings UI beyond permissions **and one hotkey**";
`docs/product/PRODUCT_SPEC.md:252` specifies General as "hotkeys (both modes, with conflict
detection against system shortcuts)"). It was deferred **by scope, not by a blocker**, at
`docs/planning/settings-live-controls/prd.md:173` — "Hotkey rebinding
(`SettingsCopy.hotkeyNotRebindable` stays true)".

Today the binding is the single constant `AppBootstrap.shippedHotkeyKeyCode: UInt16 = 49`
(`Sources/VoccaBootstrap/AppBootstrap.swift:573`), fed as a `keyCode` / `modifiers` /
`activation` triple into both machines at `AppBootstrap.swift:400` (hold-to-talk) and
`AppBootstrap.swift:438` (toggle). It becomes a persisted binding read from the existing
`SettingsStore` at launch, rebindable at runtime, with `SettingsCopy.hotkeyNotRebindable`
(`Sources/VoccaUI/SettingsTab.swift:84`) deleted because it stops being true.

## Why this, now

- **Last unbuilt P0-scope item.** Everything else in P0's settings envelope has shipped
  (permissions via `first-run-permissions`, the activation-mode control via
  `settings-live-controls`).
- **Cheapest remaining derisk on R4** (`docs/ROADMAP.md` risks register — "dictation parity with
  FluidVoice/VoiceInk isn't reached", Med likelihood / High impact). The P0 gate is explicitly
  calibrated against those two side by side and both let a user choose their shortcut.
- **⌥Space is Raycast's default hotkey**, and Raycast is named in `CAPABILITY_ROADMAP.md` C8's own
  clipboard-manager coexistence list. A fixed ⌥Space ends the P2 gate's "≥5 external users" run at
  install for anyone running Raycast.
- The change is contained: the tap's event mask is computed from event *types*, not key codes
  (`Sources/VoccaHotkey/TapEventClassification.swift`), so the tap adapter is untouched.

## Known caveat, to plan around rather than discover

**"Conflict detection against system shortcuts" cannot be made complete, and must not be claimed
as complete.** macOS exposes no public API to enumerate system keyboard shortcuts;
`com.apple.symbolichotkeys` is an undocumented plist, and third-party grabbers (Raycast, Alfred,
Rectangle) are invisible to it entirely. Detection has to be a **seeded known-conflicts table plus
a live empirical probe** — arm the binding and observe whether the key ever reaches the tap — with
copy that says which of the two it is.

Second caveat, the house pattern: the recorder view is executed by nothing in CI (the window-server
precedent — no window server on a hosted runner), so decisions live above the seam in a Core-owned
pure reducer and the adapter is translation-only, with new `docs/SMOKE_CHECKLIST.md` steps for its
first execution.

## The load-bearing hazard

A rebind must reach **both** machines — hold and toggle are both constructed at every launch
(`AppBootstrap.swift:400,438`) — **and** the watchdog's physical-key poll
(`CGEventSourceKeyState`, `Sources/VoccaHotkey/CGEventTapSource.swift:426`). A rebind that lands
in one machine but not the watchdog leaves the hot-mic guard reading the old key code, which is a
stuck-open microphone.

## Acceptance tests, written first

1. A rebind reaches **both** the hold and toggle machines *and* the watchdog's physical-key poll —
   pinned over the closed set of consumers, because a watchdog still reading key code 49 after a
   rebind is a hot mic.
2. The recorder reducer's decision table — a modifier-only chord is refused, Escape cancels the
   recording without arming, and a seeded conflict is reported rather than silently accepted.
3. The binding round-trips through `SettingsStore` with a tolerant decode and a loud fallback to
   ⌥Space on garbage, and applies at the next session boundary with no restart.
4. A rebind while a session is in flight is refused — the `settings-live-controls` model-removal
   precedent.

Plus: smoke steps for the recorder's first real execution and for a rebind surviving relaunch.

## Out of scope (named, so it isn't discovered mid-plan)

- Widget position, launch-at-login, sounds (`PRODUCT_SPEC.md:252`'s other General-tab rows) —
  still deferred at `settings-live-controls/prd.md:175`.
- The Privacy tab and its real network-connection counter (`PRODUCT_SPEC.md:277`).
- Anything on the C7 streaming/speculative path, and the C8 matrix baseline run.
- A second, separate hotkey per mode. `PRODUCT_SPEC.md:252` says "hotkeys (both modes …)" — whether
  that means one chord shared by both activation modes or one chord each is an **open question for
  the PRD**, not a decision to make here.
