# Understanding: feat/hotkey-rebinding

**Date:** 2026-08-30 · **Phase:** P0 (capability C1, unshipped must-have M10)
**Source:** `docs/planning/_card/issue.md` (inline brief — no GitHub issue exists)

> Written after a four-agent dig over the hotkey path, the settings path, the enforced
> conventions, and the macOS conflict-detection constraints. Every claim below carries a
> file:line. Two claims in the original brief were **wrong** and are corrected here.

---

## 1. What the work is really asking

Not "add a feature". **Deliver an unshipped must-have and make a risk-register row true.**

- `docs/planning/audio-capture-hotkey/prd.md:137` — **M10 "Rebindable hotkey"**, in the C1
  **Must-have** section: *"`⌥Space` is Alfred's default and a common Raycast binding."*
- `docs/planning/audio-capture-hotkey/prd.md:321` — risk **C1-E** (`⌥Space` collides with
  Alfred/Raycast, Med) records its mitigation as *"M10 rebinding"*.
- M10 appears in **no** C1 aspect spec. It was dropped at decomposition, deliberately and with a
  reason: `audio-capture-hotkey/hotkey-source/spec.md:88` — *"Hotkey rebinding UI. The
  **configuration is already a value**; a settings surface is later."*
- `docs/planning/audio-capture-hotkey/prd.md:263` — **N1** "Hotkey conflict detection against
  system shortcuts" was separately listed as **nice-to-have**.

So C1-E is currently mitigated on paper only, exactly as roadmap risk R5 was before C3 and as R11
is by the zero-network test. This unit closes it. **Note the asymmetry the PRD must preserve:
rebinding is a must-have; conflict detection is a nice-to-have.** They are not one requirement,
and the nice-to-have is the half that cannot be finished (§4.3).

## 2. Where it sits

- **Phase P0**, `docs/ROADMAP.md` — P0's scope discipline permits *"no settings UI beyond
  permissions **and one hotkey**"*. This is that hotkey.
- **Layer:** capture only. It touches no ASR, cleanup, injection, or TTS code.
- **Guardrail check** (`CLAUDE.md`): macOS-only ✅ · zero network ✅ (nothing here reaches a
  socket) · local-first ✅ · dictation-first ✅ (P0, not the agent layer) · does not cripple the
  local core ✅ · no cloud in the OSS core ✅. **No guardrail tension found.**
- **Accessibility is a first-class driver here, not a nicety** — see §4.2.

## 3. The code, as it actually is

**The binding is one immutable value, consumed in exactly two places.**

| Thing | Where | State |
|---|---|---|
| `HotkeyConfiguration` | `VoccaCore/HotkeyConfiguration.swift:20` | `Sendable, Hashable`; `keyCode`/`modifiers`/`activation` **all `let`** |
| Constructed | `VoccaBootstrap/AppBootstrap.swift:399-400` (hold), `:437-438` (toggle) | both from `shippedHotkeyKeyCode: UInt16 = 49` (`:573`) + `[.option]` |
| Consumed (1) | `VoccaCore/SessionRules.swift:157` `decide(_:state:config:)` | pure; compares `event.keyCode == config.keyCode` + chord |
| Consumed (2) | `VoccaCore/SessionWatchdog.swift:444-449` `theBindingIsStillHeld` | hold-to-talk hot-mic poll, ~150 ms |
| Held by | `VoccaCore/SessionMachine.swift:76` `public let configuration` | **immutable after init** |
| Persisted | — | **nothing.** Only `Activation` is stored (`SettingsStore.swift:49-51`) |

**`VoccaHotkey` is entirely binding-agnostic and needs no change.** The tap's `eventsOfInterest`
mask is built from event *kinds*, never key codes (`CGEventTapSource.swift:188` +
`TapEventClassification.swift`), so the tap forwards **the whole keyboard** unconditionally and
per-key matching happens above the seam in `SessionRules`. `TapEventDispatch.swift:44-46` says so
in its own comment. This is a large simplification versus what the brief assumed.

### Two corrections to the brief

1. **"The rebind must separately reach the watchdog's physical-key poll, or the hot-mic guard
   reads the old key code" — false.** `theBindingIsStillHeld` reads `machine.configuration`
   **fresh on every poll** (`SessionWatchdog.swift:445`), and
   `CGEventTapSource.isKeyDown(_:)` (`:426`) takes the key code as a *per-call parameter*. There
   is no second stale copy anywhere. The guard tracks a rebind automatically **if the
   configuration can change at all** — which it cannot.
2. **"A modifier-only chord is refused" was stated as settled — it is entangled with a spec
   requirement pointing the other way.** See §4.2. (Modifier-only — a chord with no non-modifier
   key — is still correctly refused; *single-key, no-modifier* is a different case the spec
   **requires** us to allow. The brief blurred them.)

### The real hazard, restated

`SessionMachine.configuration` is a `let`, and each `Wiring` bakes it in at construction
(`AppBootstrap.swift:870-872`). So a rebind is **not** a value update — it is either a mutation
path that does not exist yet, or a graph rebuild. And if it becomes a mutation, the live hazard is
`SessionRules.decide` and the watchdog poll **disagreeing mid-session** about what is bound:
a session stranded on a key nobody is holding is `ROADMAP.md`'s **C1-A, "stuck recording", rated
Fatal (trust)**. This is the single most important decision in the unit.

### The activation-mode precedent, and where it stops being one

`DictationLoopRoot.setActiveMode(_:)` (`AppBootstrap.swift:1564-1581`) is the template: refuse
no-op → **refuse while either machine is non-`.idle`** → persist → adopt → reroute. But it only
**re-routes between two pre-built machines that already share the same chord**. It never changes a
`keyCode`. Rebinding changes the match condition *inside* a route that is already built, so the
precedent covers the guard and the ordering, not the mechanism.

## 4. Open questions for the PRD

### 4.1 How does a rebind reach a built machine? *(the load-bearing one)*
Three shapes, materially different in risk: **(a)** make the configuration mutable behind a
main-actor read at decide-time; **(b)** rebuild both `Wiring`s on rebind; **(c)** persist now,
apply at next launch (restart-required). (a) is smallest but re-opens C1-A; (b) is clean but
discards watchdog/timer state and needs an idle guard; (c) is safest and worst for the user.

### 4.2 Single-key and non-modifier bindings — spec-required, and dangerous
`PRODUCT_SPEC.md:322` (§10 Accessibility) is explicit: *"Hotkeys fully rebindable, **including to
single keys or non-modifier combinations**, for users who can't hold chords."* That is a stated
accessibility need, not an edge case, so a blanket "a modifier is required" rule **contradicts the
spec**. But because the tap swallows the bound key (`ARCHITECTURE.md` §13: the tap must be active,
not listen-only, or macOS inserts U+00A0), binding a bare letter makes that letter untypeable
system-wide. `F13`–`F20` are the case the accessibility requirement actually wants; a bare `e` is
the case that bricks the keyboard. **The PRD must draw this line explicitly** rather than let the
recorder decide it by accident.

Certain refusals independent of any of the above: **Escape** (it is Vocca's own cancel key,
`SessionKeyPolicy.swift:56`, and the recorder needs it to abort), and **modifier-only** chords
(`HotkeyConfiguration` pairs a `keyCode` with a `ModifierSet` — there is no representation for
"modifiers alone").

### 4.3 What "conflict detection" can honestly be
Established as fact, not opinion:
- `com.apple.symbolichotkeys` covers **only Apple's own remappable shortcuts** (Spotlight,
  Mission Control, …). Undocumented, but plainly readable — no entitlement needed.
- There is **no API to enumerate hotkeys other processes registered**, via Carbon
  `RegisterEventHotKey` or via their own `CGEventTap`. Closed by design.
- **Therefore Raycast and Alfred — the two apps C1-E actually names — are structurally
  invisible.** The mitigation cannot detect the risk it was written for; it can only let the user
  move off the collision.

So detection ships as some subset of {seeded per-app table, `symbolichotkeys` read, empirical
arm-and-observe probe}. Which subset, and how the copy states its own incompleteness, is a PRD
decision. `TapHealthPolicy`'s `blockedBySecureInput` is the house precedent for "healthy but
structurally cannot receive this key" (`TapHealthPolicy.swift:219`).
**UNVERIFIED and flagged as such:** whether another process's `RegisterEventHotKey` reliably
prevents our tap from seeing the key at all. Nobody has measured it; the probe's usefulness
depends on it.

### 4.4 Refusal shape — two precedents disagree
Activation mode refuses **silently** (logs only, `AppBootstrap.swift:1568-1570`). The Speech tab's
model removal refuses **visibly** (`SpeechTabState.swift:297` → `.refused` state), and its own copy
cites activation mode as its template (`SpeechTabCopy.swift:105`). A rebind attempted mid-dictation
should probably surface; the PRD should say which and why.

### 4.5 One chord or two?
`PRODUCT_SPEC.md:252` says "hotkeys (both modes…)". §5's dual-mode table (`:192`) assigns `⌥Space`
to Dictate and `⌥⇧Space` to Converse — **Converse is P3 and unbuilt**. Resolution: ship **one**
binding, with a stored shape that does not foreclose a second. Note the two *activation* modes
(hold/toggle) share one chord today and should continue to.

## 5. Two smaller findings that will bite if missed

- **`SettingsBindings.hotkeyDisplayName` is a plain `String`, not a closure**
  (`SettingsView.swift:24-152`) — captured once at window construction, unlike every other live
  field. The settings window is built once and kept for the process lifetime
  (`AppBootstrap.swift:1031-1035`), so after a rebind it would display the **old** chord until
  relaunch. It has to become a closure.
- **`SettingsCopy` has no byte-for-byte pin test.** Grep of `Tests/` finds
  `hotkeyNotRebindable` only in three unrelated doc comments. So deleting it — which this unit
  must do, because it becomes false — is a change **no existing test would notice**. The house
  convention (`AppsTabCopyTests`, `CleanupTabCopyTests`) is to pin copy; this tab never got one.

## 6. Conventions this unit is bound by

- **Persistence must go in the existing `settings` seam's one file**
  (`UserDefaultsSettingsStore.swift`) — a second `UserDefaults`-naming file fails
  `InjectionSeamBoundaryTests.swift:1453-1481` outright. Tolerant decode belongs in
  `PersistedSettings` (absent → default silent; malformed → default + exactly one loud report).
- **Core owns the pure reducer**; `VoccaUI` may import only `VoccaCore`
  (`ModuleBoundaryTests`). The recorder view is executed by nothing in CI (window-server
  precedent) — decisions above the seam, adapter thin.
- **Test floor is 1501** (`Scripts/test-with-floor.sh`), bumped in the same commit that adds tests.
- Any tunable constant needs a **single-source scan test** (the `StrategyMemoryTargets` shape).
- New `deinit`s may call only `tearDown`/`stopWithoutAssertingIsolation`/`deallocate`
  (`DeinitIsolationTests`).
- Apache-2.0 header verbatim on every new file; **smoke steps append after 110**.

## 7. Contradictions surfaced, not papered over

1. **`PRODUCT_SPEC.md:252` promises "conflict detection against system shortcuts"; macOS cannot
   deliver it** for the apps the risk names. The promise is not fully keepable and the spec line
   should be amended by this unit rather than quietly under-delivered.
2. **C1-E claims a mitigation that does not exist.** True since C1.
3. **The brief's own acceptance test #2 conflicts with `PRODUCT_SPEC.md:322`** (§4.2). The spec
   wins; the acceptance test gets rewritten.
