# Aspect spec — `session-lifecycle`

Parent PRD: [`../prd.md`](../prd.md) · Capability C1 · Phase P0, week 1

---

## Problem slice

macOS does not guarantee the key-up that ends a hold-to-talk session. The hotkey can be stolen,
the OS can disable the event tap without warning, the machine can sleep, and the user can
release the modifier before the key. Any of these leaves the microphone open while the widget
says nothing is happening.

**This aspect is where that bug lives, so this is where its tests live.** It is deliberately
**pure Swift with zero system APIs** — no `CGEvent`, no `AVAudioEngine`, no AppKit — so 100% of
it runs headlessly on a CI runner with no permissions, no microphone, and no network.

**User outcome:** the microphone stops the instant the user stops asking for it, on every path,
without exception — and the audio captured before that point is never thrown away by accident.

---

## In scope

### The decision function
```swift
func decide(_ event: RawKeyEvent, state: SessionState) -> Decision
```
- Pure. Same inputs → same output. No clock read, no I/O, no globals.
- `RawKeyEvent` is a **POD struct** (`type`, `keyCode`, `flags`, `isAutorepeat`, `timestamp`).
  No `CGEvent` type ever crosses this boundary — that is what makes the tests possible.
- **Modifier state is derived from `event.flags` on every event and never accumulated.**
  This is the [Handy #840](https://github.com/cjpais/Handy/issues/840) defect: v0.1.4 derived
  and worked, v0.2.0 accumulated on `flagsChanged` and desynced permanently after one missed
  event. The prohibition is the requirement.

### Start rule
`type == .keyDown` ∧ `keyCode == configured` ∧ `flags ⊇ configured modifiers` ∧
`!isAutorepeat` ∧ `state == .idle`

### Stop rules — all six, not a subset
| # | Trigger |
|---|---|
| a | `keyUp` on the configured key |
| b | `flagsChanged` that no longer carries the configured modifier |
| c | **any** event whose flags no longer carry the configured modifier |
| d | tap disabled (`tapDisabledByTimeout` / `ByUserInput`) |
| e | ceiling elapsed (120 s default) |
| f | physical-state poll reports the key released |

Rule (b) is what covers "released Option before Space" — the single likeliest stuck-recording
cause. Rule (c) is free, since every keyboard event is already visible.

### Session state machine
- States: `idle → recording → ending → idle`.
- **Injected clock.** No `Date()`, no `DispatchTime.now()` reachable from this module — ceiling
  and poll-interval tests must be deterministic and instant.
- **Exactly one** `endSession(reason: EndReason)` funnel. Every stop path goes through it.
- `EndReason` is an enum: `.keyUp`, `.modifierReleased`, `.tapDisabled`, `.ceilingReached`,
  `.pollDetectedRelease`, `.systemEvent(SystemTrigger)`, `.userCancelled`.
- **Every terminal transition hands the captured buffer downstream.** Discard is not
  representable in the type — mirroring `ARCHITECTURE.md:294` ("an unexpectedly-ended session
  yields its transcript to custody rather than discarding it") and `CAPABILITY_ROADMAP.md:20`.
  **The one exception is `.userCancelled`** (Esc), where discarding is the user's explicit
  instruction.

### Toggle mode
Hold-to-talk and toggle are two configurations of the *same* state machine, not two machines.
In toggle mode the start rule is unchanged and stop rules (a)/(b)/(c) are replaced by "next
matching key-down". Rules (d)–(f) still apply — **a toggle session still has a ceiling and a
watchdog**, or toggle mode reintroduces the hot-mic bug this aspect exists to prevent.

### Watchdog policy
Owned here as **policy**; the physical-key read itself is injected (it is a system call, and
lives in `hotkey-source`). This module decides *when* to poll and *what a release means*.

### System triggers
Accepts `SystemTrigger` values (`willSleep`, `screensDidSleep`, `sessionDidResignActive`,
`audioConfigurationChanged`, `secureInputEnabled`) and maps each to a stop. **Delivery** of
those notifications is not this module's job.

---

## Out of scope

- Creating or managing the `CGEvent` tap (`hotkey-source`).
- Reading physical key state via `CGEventSourceKeyState` (`hotkey-source` — injected here).
- Audio capture, ring buffer, format conversion (`audio-capture`).
- Widget rendering (`widget`). This module **emits** state; it does not draw it.
- Permission checks (`permissions-onboarding`).

---

## Acceptance criteria (tests written first)

| # | Criterion |
|---|---|
| B1 | **100 synthetic key-down/key-up pairs at durations 80 ms – 60 s → exactly 100 started, 100 ended, 0 overlapping, 0 orphaned.** The `CAPABILITY_ROADMAP.md:42` acceptance, realised over the seam rather than the real tap |
| B2 | Table-driven `decide` coverage of every start and stop rule **in isolation and in combination** |
| B3 | **Release-modifier-first**: `flagsChanged` dropping the modifier ends the session, and a later unmatched `keyUp` does **not** start or end anything |
| B4 | **Autorepeat** key-downs during `recording` neither restart nor end the session |
| B5 | Ceiling expiry ends the session at exactly the configured deadline (injected clock) |
| B6 | Poll reporting release ends the session within one poll interval |
| B7 | Tap-disabled ends the session — the key-up is never coming |
| B8 | **Every `EndReason` yields the captured buffer downstream. Property-based: for all reasons except `.userCancelled`, audio is emitted exactly once** |
| B9 | Double-start, stop-without-start, and stop-twice are all safe no-ops |
| B10 | Toggle mode: start/stop on successive key-downs, **and the ceiling still fires** |
| B11 | `decide` is pure — same inputs give the same output across 10,000 randomised sequences |
| B12 | No `import AppKit`/`CoreGraphics`/`AVFoundation` anywhere in the module (asserted by a source-lint test, so the boundary can't erode) |

B8 and B12 are the load-bearing ones. B8 is the "never lose the words" invariant made
executable; B12 is what keeps this module testable forever.

---

## Dependencies and sequencing

**Depends on:** `project-skeleton` (needs a target to live in).
**Blocks:** `hotkey-source` and `audio-capture` both consume these types.

**Build this second, before anything that needs a permission.** It is the highest-risk logic in
C1 and the cheapest to test. PRD §8 G1 flags the real danger: if C1 overruns, polish must slip
and this must not.

---

## Open questions / risks

1. Ring-buffer capacity is decided in `audio-capture`, but the **120 s ceiling here sets it**
   (~23 MB at 48 kHz Float32 mono). PRD open question 2. If that is too much, the ceiling is
   the lever — decide here, not there.
2. Poll interval: 100–250 ms was the researched range. Faster costs battery; slower widens the
   worst-case hot-mic window. Recommend **150 ms**, and make it a named constant with the
   tradeoff in a comment.
3. `.userCancelled` is the single path that discards audio. It should be structurally distinct
   in the type — not just an enum case that happens to be handled differently — so a future
   refactor cannot accidentally route another reason through it.
