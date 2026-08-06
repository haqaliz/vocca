// Copyright 2026 The Vocca Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import VoccaCore

/// **`SessionWatchdog`, with its timer attached.**
///
/// `WatchdogSchedule` is an instruction — *wake me every 150 ms*, or *stop* — and `VoccaCore` has no
/// run loop to carry it out with. This is the carrying out: one object that reads the schedule after
/// every input and makes the timer match it.
///
/// ## Why it is the sink rather than something beside the sink
///
/// `TapHealthPolicy`'s documentation ends with an obligation on its owner: *"Re-read
/// `SessionWatchdog.schedule`. Ending a session moves it from `.wake(every:)` to `.stopped`, and
/// every entry point here can end one"*. `SessionWatchdog.observe(_:)` carries the same obligation
/// for key events, in as many words: *"it does **not** force the owner to re-read `schedule`, and
/// nothing in a module with no run loop could."*
///
/// Two obligations on an owner to remember something is how this project's merged aspects describe
/// nearly every defect they had to close. So the obligation is discharged structurally instead:
/// **this object is the `HotkeyEventSink`**, so every route into a session passes through it —
///
/// - every key event, because the tap delivers them here;
/// - every synthetic `.tapDisabled` the tap-health policy mints, because that travels through the
///   sink too, which is what makes `arm()`, `disarm()`, a wake, a grant change, a disablement and a
///   health poll all settle the timer without any of them knowing this object exists;
/// - and its own wakes, which it re-reads the schedule after.
///
/// It builds its own `SessionEventSink` rather than wrapping one an owner supplies, so that there is
/// one watchdog, one effect closure, and no way to hand it a sink pointed at a different session.
///
/// **What is still the owner's**, and it is stated because the list is short and closed:
/// `SessionWatchdog/cancel()` and `SessionWatchdog/observe(_ trigger:)` do not come through here —
/// they arrive from the widget and from `NSWorkspace`, neither of which exists yet — so an owner that
/// wires them must call ``reconsider()`` afterwards. Getting that wrong costs a timer left running
/// over an idle machine, which spends battery and ends nothing: `wake()` answers `.unchanged` in
/// `.idle`. It is not a hot mic, and the asymmetry is worth knowing — the failures this object
/// prevents are the ones in the other direction.
///
/// ## Isolation
///
/// Not `Sendable`, and it cannot be: it holds a `SessionWatchdog`, which holds a `SessionMachine`,
/// deliberately non-`Sendable` because a tap callback is a synchronous C function that cannot
/// `await`. The tap, the policy, this, the machine and both timers live in one domain — `@MainActor`
/// in `hotkey-source`.
public final class ScheduledWatchdog<Audio: CapturedAudio>: HotkeyEventSink {

    /// Read for its ``SessionWatchdog/schedule`` and driven for its ``SessionWatchdog/wake()``.
    ///
    /// The same object the sink below drives, held twice on purpose. `SessionWatchdog`'s own
    /// documentation sanctions exactly this: *"What the wrapping buys is that nothing **drives** a
    /// session by a route the schedule is not read after — not that the machine is unreachable."*
    /// Every drive from here goes through ``events``; this reference reads, and wakes.
    private let watchdog: SessionWatchdog<Audio>

    /// The sink the events actually go through. Built here rather than injected so that its effect
    /// closure and this object's watchdog cannot be pointed at two different sessions.
    private let events: SessionEventSink<Audio>

    /// The clock. Started and stopped only by ``reconsider()``, and never asked to remember anything.
    private let timer: any RepeatingTimer

    /// Where a wake's effect goes. The same closure the inner sink was built with — a wake can end a
    /// session, and an ending is a `SessionOutcome` carrying the user's audio, which is the one thing
    /// in this package that must never be dropped.
    private let deliverEffect: (SessionEffect<Audio>) -> Void

    /// - Parameters:
    ///   - watchdog: the session, and the schedule to obey.
    ///   - timer: the clock. See ``RepeatingTimer`` for the two obligations a conformance owes.
    ///   - deliverEffect: where every effect goes — from a key event and from a wake alike. One
    ///     closure, so a transcript cannot arrive by a route the owner forgot to wire.
    public init(
        watchdog: SessionWatchdog<Audio>,
        timer: any RepeatingTimer,
        deliverEffect: @escaping (SessionEffect<Audio>) -> Void
    ) {
        self.watchdog = watchdog
        self.timer = timer
        self.deliverEffect = deliverEffect
        self.events = SessionEventSink(watchdog: watchdog, deliverEffect: deliverEffect)
    }

    /// Stops the clock when the graph is torn down.
    ///
    /// The fire closure captures this object weakly, so a dropped `ScheduledWatchdog` would leave a
    /// timer firing into nothing rather than into freed memory — but it would still fire, forever, on
    /// the main run loop. `MainRunLoopTimer` has a `deinit` of its own that covers the case where
    /// this object is the timer's only owner; this covers the case where it is not.
    ///
    /// **It calls ``RepeatingTimer/stopWithoutAssertingIsolation()`` and not `stop()`, and the
    /// difference is a release-build crash.** `MainRunLoopTimer.stop()` opens with
    /// `MainActor.preconditionIsolated`, which is not compiled out at `-O`, and a `deinit` runs
    /// wherever the last release happens. The reachable chain is the package's own:
    /// ``CGEventTapSource/deinit`` is deliberately non-asserting because it may run anywhere, and it
    /// calls `tearDown()`, which sets `sink = nil` — and the sink is this object. So a tap source
    /// released off the main actor arrives here, and for one commit arrived at a trap.
    deinit {
        timer.stopWithoutAssertingIsolation()
    }

    // MARK: - HotkeyEventSink

    /// One observed key event, and then the timer is settled.
    ///
    /// **The order is load-bearing**: the schedule is derived from the machine's state, so it must be
    /// read *after* the event has moved it. Reading first would start a timer for a session that had
    /// not begun and stop one for a session that had not ended — both by exactly one event.
    ///
    /// The disposition is returned unchanged, which is inherited constraint 4. This method sees
    /// nearly every keystroke the user makes, in every application, for as long as Vocca runs, so a
    /// hard-coded value here is not an edge case — it is the whole keyboard. It is pinned in both
    /// directions.
    public func receive(_ event: RawKeyEvent) -> EventPropagation {
        let propagation = events.receive(event)
        reconsider()
        return propagation
    }

    // MARK: - The timer

    /// Make the timer match ``SessionWatchdog/schedule``.
    ///
    /// Called after every input this object sees, and public for the two inputs it does not — a
    /// cancellation and a system trigger.
    ///
    /// ## It holds no state, and that is what makes it safe to call constantly
    ///
    /// The comparison is against ``RepeatingTimer/interval``, which is a question put to the timer,
    /// not a flag remembered here. `SessionWatchdog` is written under the same prohibition and names
    /// the defect it prevents — [Handy #840](https://github.com/cjpais/Handy/issues/840), a running
    /// total that desynchronised permanently after one missed event. A `isTimerRunning` flag here
    /// would be that shape again, one layer out.
    ///
    /// ## Why a running timer at the right cadence is left alone, and what it costs to get wrong
    ///
    /// **Restarting it on every event would mean it never fires at all.** That is not a theoretical
    /// tidiness argument, it is arithmetic about hold-to-talk: macOS autorepeats a held key at
    /// roughly 30–90 ms, every autorepeat is a `.keyDown` delivered to ``receive(_:)``, and the
    /// watchdog's cadence is 150 ms. A timer restarted from zero on each of those never reaches its
    /// deadline — so the physical-key poll never runs and **the 120 s ceiling never fires**, for the
    /// entire class of sessions where the user is holding the key down, which in hold-to-talk is all
    /// of them. `ScheduledWatchdogTests` drives that autorepeat train and counts the fires.
    ///
    /// A cadence that has *changed* is a genuine restart, and the branch says so by comparing the
    /// interval rather than merely testing for `nil`. Nothing changes it today — `WatchdogSchedule`
    /// carries `WatchdogPolicy.pollInterval` and nothing else — which is exactly why it is written as
    /// a comparison now, while it is free, rather than left as a `nil` check for a later cadence to
    /// silently not take effect against.
    public func reconsider() {
        switch watchdog.schedule {
        case .wake(let interval):
            guard timer.interval != interval else { return }
            // Weak, and it is the direction that has to be weak: this object owns the timer, the
            // timer owns the closure, and a strong capture would close the cycle around the object
            // whose `deinit` is what stops the clock.
            timer.start(every: interval) { [weak self] in self?.wake() }

        case .stopped:
            guard timer.interval != nil else { return }
            timer.stop()
        }
    }

    /// One turn of the timer: wake the watchdog, deliver whatever came out, settle the clock.
    ///
    /// The third line is what stops the timer at the end of a session. A wake that ends one moves
    /// the schedule to `.stopped`, and nothing else is watching for that — the key events have
    /// stopped by definition, because the key came up.
    private func wake() {
        deliverEffect(watchdog.wake())
        reconsider()
    }
}
