# Aspect: `rebind-boundary`

**Unit:** `hotkey-rebinding` · **Depends on:** `binding-vocabulary`, `binding-store`
**Module:** `VoccaBootstrap` (the composition root's own mechanism)

## Problem slice

This is the aspect that carries the unit's only Fatal-rated risk.

The binding is immutable end to end: `HotkeyConfiguration`'s three fields are `let`,
`SessionMachine.configuration` is a `public let` (`SessionMachine.swift:76`), and each `Wiring`
bakes it in at construction (`AppBootstrap.swift:870-872`). So a rebind is not a value update. It
is either a mutation path that does not exist, or a rebuild.

Mutation is smaller and the watchdog would track it for free — `theBindingIsStillHeld` re-reads
`machine.configuration` on every ~150 ms poll (`SessionWatchdog.swift:444-449`). But a mutation
landing between a `keyDown` and its `keyUp` leaves `SessionRules.decide` and that poll disagreeing
about what is held, and a session stranded on a key nobody is holding is **C1-A, "stuck
recording", rated Fatal (trust)** in `docs/planning/audio-capture-hotkey/prd.md:319`.

**User outcome:** a new chord works on the next press, and no rebind can ever strand a recording.

## In scope

- **M4** — `DictationLoopRoot.rebind(_:)`, in the order `setActiveMode` established
  (`AppBootstrap.swift:1564-1581`): refuse a no-op → **refuse unless both machines are `.idle`** →
  persist → rebuild both `Wiring`s with the new configuration → re-point `ModeRoutingSink.active`
  at the wiring for the current mode. Every value stays immutable; nothing is mutated under a
  running session, so the disagreement above is unrepresentable rather than merely unlikely.
- **M4a — the rebuild is atomic and its failure is loud.** A rebuild that throws or half-completes
  leaves the **previous** wirings built and routed and surfaces the failure. It must never produce
  a graph with no routed sink: on an `LSUIElement` app, a silently dead hotkey looks exactly like a
  working one — the failure class behind three `fix/local-dev-launch` defects.
- **M5** — the refusal is **returned**, not just logged, so `general-tab-recorder` can show it.
  This follows the Speech tab's model-removal shape (`SpeechTabState.swift:297` → `.refused`)
  rather than activation mode's silent no-op, because a rebind that appears not to have registered
  invites a second attempt.
- The tap is **not** re-armed. It is binding-agnostic — its `eventsOfInterest` mask is built from
  event kinds, never key codes (`CGEventTapSource.swift:188`) — and is owned above the wirings.

## Out of scope

- Any view (`general-tab-recorder`). This aspect exposes a function and a result type.
- Changing which *activation mode* is live — `setActiveMode` already does that and is untouched.
- Rebinding while onboarding's TRY IT step holds its own delivery sink — the idle guard covers it,
  and no special case is added.

## Acceptance criteria (tests written first)

1. **Refused while a session is in flight**, driven over the closed set of non-`.idle` states for
   **both** machines independently — a rebind must be refused if *either* is busy, not only the
   routed one. This is the hot-mic guard and the load-bearing test of the aspect.
2. **After a successful rebuild:** both machines carry the new configuration; exactly one wiring is
   routed; the routed one matches the current activation mode; both are `.idle`.
3. **After a failed rebuild:** the *previous* configuration is still live, exactly one wiring is
   still routed, and the failure is reported — driven by a seeded failure at each construction
   step, because a rebuild that can only fail at the first step proves nothing.
4. **A no-op rebind is refused** and rebuilds nothing — asserted by identity, not by state.
5. **The persist happens before the adopt**, and a failed persist does not adopt — the ordering
   `setActiveMode` already commits to.
6. **The tap source is unchanged across a rebind** — same object, never re-created.
7. **A rebind to a chord `binding-vocabulary` refuses is rejected** before anything is persisted.
8. **The new chord starts a session and the old one does not**, driven end to end through the
   machine over a fake event source — the behavioural proof, not just the wiring proof.

## Dependencies & sequencing

Needs both earlier aspects. Build third. **Headlessly testable in full** over the existing fake
`HotkeyEventSource` — no tap, no window, no TCC. What CI cannot prove is the real rebuild against
a real tap; that is a smoke step.

## Open questions / risks

- **OQ1 from the PRD lands here:** whether the rebuild must re-arm the tap or only re-point the
  routing sink. Confirm against `AppBootstrap.swift:1502-1512` before writing the mechanism —
  do not assume.
- Rebuilding discards each `Wiring`'s watchdog and its timers. Any new `deinit` on that path may
  call only `tearDown` / `stopWithoutAssertingIsolation` / `deallocate` (`DeinitIsolationTests`) —
  a `MainActor.preconditionIsolated` in a `deinit` is a release-build crash, and this is the fourth
  place that rule has mattered.
