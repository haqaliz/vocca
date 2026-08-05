# Aspect spec — `hotkey-source`

Parent PRD: [`../prd.md`](../prd.md) · Capability C1 · Phase P0, week 1
Depends on: `project-skeleton` (merged), `session-lifecycle` (merged, `6b0b92d`)

---

## Problem slice

`session-lifecycle` built a session machine that reacts correctly to key events. Nothing produces
those events. This aspect is where Vocca first touches the operating system: a global event tap that
sees every keystroke on the machine, decides which belong to Vocca, and hands the rest back
untouched.

**User outcome:** pressing `⌥Space` anywhere starts a session, releasing it ends one, and every other
key the user types reaches the application they are typing into, unchanged.

**Why it is the riskiest aspect so far.** Everything in `session-lifecycle` was pure and ran
headlessly. Nothing here can: `CGEvent.tapCreate` returns `nil` without an Accessibility grant, and
**no hosted CI runner can be granted one** — there is no programmatic route to TCC short of
disabling SIP. So the seam must be drawn so that everything with a branch worth testing sits above
it, and the part that cannot be tested contains no decisions.

---

## What this aspect inherits — decided, do not relitigate

Each was established by a merged aspect and is load-bearing here.

| # | Constraint | Where it came from |
|---|---|---|
| 1 | **`.defaultTap` at `.cgSessionEventTap`, `.headInsertEventTap`.** HID-level taps are root-only (`CGEvent.h:269-271`); only an *active* tap can swallow. | C1 platform dig |
| 2 | **Swallow both the key-down and the matching key-up.** An unswallowed `⌥Space` inserts U+00A0 NO-BREAK SPACE into the field being dictated into; swallowing only the down leaves the app an unpaired key-up. | C1 platform dig |
| 3 | **Accessibility, not Input Monitoring.** An active keyboard tap needs assistive-device access. `tapCreate` returning `nil` **is** the permission check, and after a grant the tap must be **destroyed and re-created** — its mask was cleared at creation and `CGEventTapEnable` will not resurrect it. | `ARCHITECTURE.md` §13, corrected |
| 4 | **Deliver every key event to the machine, and return its disposition unchanged.** Stop rule (c) is "any event whose modifiers no longer carry the configured set", so the machine must see keys it has no interest in. A wrapper that decides propagation for itself eats the user's whole keyboard. | `session-lifecycle` task 5 |
| 5 | **Construct the machine in the tap's isolation domain.** `SessionMachine` is deliberately synchronous and non-`Sendable`; passing it into an actor's `init` from outside is a `sending` diagnostic. Clean shape: own it on `@MainActor`, tap on the main run loop, `MainActor.assumeIsolated` in the callback. | `ARCHITECTURE.md` §7, corrected |
| 6 | **Strip `fn` for key codes that carry it implicitly.** macOS sets the bit on F1–F20, arrows, Home/End/PgUp/PgDn, fwd-Delete and Help with no user involvement. Only this layer knows the key code. | Founder decision, pinned in `ModifierSet.swift` |
| 7 | **Do nothing in the tap callback.** No I/O, no allocation, no `await`, no engine start. A slow callback is what `kCGEventTapDisabledByTimeout` means. | C1 platform dig |

---

## In scope

### The `HotkeyEventSource` seam
Yields POD `RawKeyEvent` values. **No `CGEvent`, `CGEventFlags` or `CFMachPort` escapes the
implementation file.** This is the boundary that keeps the decision logic testable.

### The `CGEvent` tap implementation
- Mask: `keyDown | keyUp | flagsChanged`, plus handling for the two out-of-band disable events.
- Translation from `CGEventFlags` to Vocca's own `ModifierSet`, applying constraint 6.
- Returns `nil` from the callback to swallow, the event to pass through — driven entirely by the
  machine's answer.

### Tap health
- `kCGEventTapDisabledByTimeout` / `ByUserInput` are delivered **out of band**. On either:
  re-enable, **and end any in-flight session** — that key-up is never coming.
- A health poll (~1 s) on `tapIsEnabled`; if re-enable fails, tear down and **re-create**.
- Re-create on `NSWorkspace.didWakeNotification` — taps die silently across sleep/wake.
- Observe `com.apple.accessibility.api` via `DistributedNotificationCenter` to re-create after a grant.

### The physical-key read
`CGEventSourceKeyState` / `CGEventSourceFlagsState` with `.combinedSessionState`, behind the
protocol `session-lifecycle` already injects. This reads the true physical state independent of the
tap, which is why it recovers a key-up that generated no event at all.

### The timer that drives the watchdog
**This is the last remaining unbounded hot mic, and it is unmeasured.** `session-lifecycle` task 5
flagged two hazards explicitly without verifying them:
- A timer in the default run-loop mode stops firing during menu tracking and window drags. It must
  be added in `.common` modes.
- Vocca is `LSUIElement`; App Nap may throttle a background app's timers.
  `ProcessInfo.beginActivity(...)` is the usual countermeasure.

**Measure both.** Do not inherit the assumption. If the ceiling does not fire during a window drag,
the mic stays open and the widget says it is not.

### Secure Input
`IsSecureEventInputEnabled()` — when any app enables it (password fields, 1Password, Terminal with
Secure Keyboard Entry), taps receive **no key events at all**. The hotkey dies silently in exactly
the contexts users test first. Detect it and surface it; do not let it look like a bug in Vocca.

---

## Out of scope

- Audio capture (`audio-capture` — this aspect drives `SessionAudioSource` with a stub).
- The widget, permissions UI, onboarding.
- Hotkey rebinding UI. The *configuration* is already a value; a settings surface is later.
- Carbon `RegisterEventHotKey` fallback — **should-have, not must-have.** It needs no TCC grant, so
  it gives a working hotkey during onboarding before Accessibility is granted, but it cannot see
  `flagsChanged` and so cannot implement stop rules (b)/(c). Never the primary.

---

## Acceptance criteria (tests written first)

| # | Criterion | Testable headlessly? |
|---|---|---|
| H1 | `CGEventFlags` → `ModifierSet` translation is exact for every modifier, and **`fn` is stripped for every key code that carries it implicitly** | ✅ pure function |
| H2 | The full F-key/arrow/navigation key-code set is covered by H1, named individually | ✅ |
| H3 | A tap-disabled event ends the in-flight session and re-enables the tap | ✅ over the seam |
| H4 | Health poll re-creates the tap when re-enable fails | ✅ with an injected tap handle |
| H5 | `tapCreate` returning `nil` is reported as "permission missing", not as a crash or a silent no-op | ✅ with an injected creator |
| H6 | Every event the machine passes through reaches the caller unchanged — **both directions pinned** | ✅ |
| H7 | No `CGEvent` type escapes the implementation file | ✅ source lint |
| H8 | Secure Input is detected and surfaced distinctly | ⚠️ partly |
| H9 | The machine is constructed in the owning domain and the callback returns synchronously | ⚠️ compile-time |
| H10 | **The timer fires during a window drag and under App Nap** | ❌ manual, smoke checklist |

**H10 is the one that matters most and cannot be automated.** It goes in `SMOKE_CHECKLIST.md` with
the exact gesture to perform, and it must be run before any release claims the ceiling works.

---

## Open questions

1. Does the Carbon fallback earn its complexity, given it cannot implement stop rules (b)/(c)?
2. Where does tap re-creation live relative to the machine — can a session survive a tap re-create,
   or must it always end? (Recommend: always end. A tap that died may have dropped the key-up.)
3. `ProcessInfo.beginActivity` for the duration of a session: does it measurably change App Nap
   behaviour for an `LSUIElement` app, and what does it cost?
