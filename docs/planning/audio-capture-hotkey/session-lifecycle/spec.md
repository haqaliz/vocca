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
- `RawKeyEvent` is a **POD struct** (`kind`, `keyCode`, `modifiers`, `isAutorepeat`, `timestamp`).
  No `CGEvent` type ever crosses this boundary — that is what makes the tests possible.
  (`kind`/`modifiers` rather than `type`/`flags`: `type` reads as the Swift keyword and `flags`
  invites the assumption that it is a `CGEventFlags`, which is the one thing it must never be.)
- **Modifier state is derived from `event.modifiers` on every event and never accumulated.**
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
  `.pollDetectedRelease`, `.toggledOff`, `.systemEvent(SystemTrigger)`, `.userCancelled`.
  `.toggledOff` is toggle mode's stop (below): the next matching key-*down*, which is not a
  `.keyUp` and must not be labelled as one.
  As shipped these are grouped one level deep — `RetainedEndReason` for everything except
  cancellation, wrapped as `EndReason.retained(_)` — so that the reasons owing their audio
  downstream are a type rather than a convention. See `SessionOutcome`.
- **Every terminal transition hands the captured buffer downstream.** Discard is not
  representable in the type — mirroring `ARCHITECTURE.md:294` ("an unexpectedly-ended session
  yields its transcript to custody rather than discarding it") and `CAPABILITY_ROADMAP.md:20`.
  **The one exception is `.userCancelled`** (Esc), where discarding is the user's explicit
  instruction.

### Toggle mode
Hold-to-talk and toggle are two configurations of the *same* state machine, not two machines.
In toggle mode the start rule is unchanged and stop rules (a)/(b)/(c) are replaced by "next
matching key-down". Rules (d) and (e) still apply — **a toggle session still has a ceiling**, or
toggle mode reintroduces the hot-mic bug this aspect exists to prevent.

**Rule (f) does NOT apply in toggle mode.** This document said it did; that was wrong, and task 5's
implementation caught it. A toggle session runs with the key *released* for its whole life, so a
poll that ends the session on "the key is up" would end it on the first wake, 150 ms after it
started. Task 5 therefore placed the poll inside a `switch` on the activation mode with no
`default:`, so the file stops compiling at the line that must be re-decided the moment `.toggle`
becomes constructible.

**Task 6's answer: nothing replaces it, and the reason is structural rather than an omission.**
Rule (f) works in hold-to-talk because the condition a session continues under — *"the key is
held"* — is a state of the world, which `CGEventSourceKeyState` reads out of band, past the tap
that failed. A toggle session continues under *"the user has not pressed again"*, which is not a
state of anything: it is the absence of a future event, and no poll can read an absence. Detecting
the *press* instead was considered and rejected — the seam offers a level and that needs an edge,
150 ms sampling misses an ordinary 60 ms tap outright, and `isKeyDown(_:)` carries no modifiers, so
every bare press of the hotkey's key code would read as a toggle-off.

So a toggle session is bounded by: the **ceiling**, `.tapDisabled`, the five system triggers,
cancellation, and the user's next press. Only the ceiling is unconditional, which makes it
load-bearing here rather than a backstop. **The cost is measured, not asserted**: the same accident
— the user asks to stop and Vocca never hears it — costs **one poll interval (150 ms) in
hold-to-talk and the remainder of the ceiling in toggle** (105 s from a press at t=15 s), pinned
side by side in `SessionWatchdogTests`. The compensating control the user actually sees is the
widget's ceiling warning at ceiling − 10 s, which is derived and therefore fires in both modes.

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

---

## Carried forward from `project-skeleton` (final review)

Recorded here because the aspect that produced them is merged and its scratch ledger is gone.

**Inherit these patterns — each was earned by a defect that shipped past a green suite:**

1. **Assert the effect, never the reference.** Deleting the probe's `configure(_:)` call while
   leaving `AppBootstrap.self` in a placeholder list kept the suite green. The fix asserts an
   observable post-condition instead. The identical trap here: *"`stop()` was called"* is not
   *"the microphone was released."* Assert the released state, not the call.
2. **Fail closed on unclassifiable input.** The build-configuration detector throws four distinct
   ways rather than defaulting. A watchdog that cannot tell what state it is in must fault, not
   assume idle.
3. **Every zero-assertion needs a positive control sharing its mechanism.** The zero-network gate
   checks `interposerDidLoad` *before* asserting "we saw nothing". A test asserting "the mic did not
   stay open" must first prove it can detect a mic that did.
4. **Exhaustive switches over enums, no `default:`.** Adding a probe mode fails to compile until
   someone states its settle policy. Use the same shape for session states and the watchdog timeout
   table, so a new state cannot silently inherit someone else's behaviour.
5. **Give the new suite its own test-count floor.** `swift test` exits 0 when it discovers nothing —
   this is why `Scripts/test-with-floor.sh` exists. A green run is otherwise unfalsifiable.

**Avoid:**

- **Do not add a sixth `packageRoot` walker.** There are five near-identical copies across the test
  files (not yet diverged). Consolidate them in this aspect's first commit.
- **Do not drain subprocess pipes after `waitUntilExit`.** Two of three helpers get this right and
  document why; `NetworkInterposer.runProbe` is the outlier and carries a deferred deadlock risk.
- **`App/` stays a one-line shim.** It is outside the zero-network coverage guard. Start-up work
  belongs in `AppBootstrap.configure(_:)`, never in `App/` and never in `main()`.

**Open items inherited, none blocking:** notarization unproven (no Developer ID); passwords passed on
argv in the signing scripts (bounded, documented); `sign.sh`/`notarize.sh` default to different
configurations.
