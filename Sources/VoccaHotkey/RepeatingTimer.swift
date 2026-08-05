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

/// **The clock behind every "bounded" claim in this package.**
///
/// `VoccaCore` has no run loop and reads no time — `SessionMachine` advances only when somebody ticks
/// it, and `TapHealthPolicy` only when somebody polls it. This is the somebody. Two of them run:
/// ``ScheduledWatchdog``'s, at `WatchdogPolicy.pollInterval`, and ``TapHealthTimer``'s, at
/// `TapHealthPolling.interval`.
///
/// It is a seam for the ordinary reason — a test that waited for a real timer would be measuring a
/// scheduler rather than a decision — and the shipped conformance is ``MainRunLoopTimer``.
///
/// ## Two obligations a plausible conformance breaks, and neither is discoverable from CI
///
/// **1. It must fire on the main run loop, and a dispatch queue is not one.** Everything a fire
/// reaches is non-`Sendable` and lives in one isolation domain: the machine, the watchdog, the sink,
/// the policy and the tap. `CGEventTapSource`'s four seam members carry
/// `MainActor.preconditionIsolated`, and ``TapHealthPolicy/pollTapHealth()`` reads one of them —
/// `isDelivering` — once a second for as long as Vocca runs. **A poll off the main actor is
/// therefore a 1 Hz crash in a release build**, because a precondition is not compiled out. A
/// `DispatchSourceTimer` is wrong whatever queue it names; only its main-queue form is even close,
/// and the main queue is not the main run loop's mode set.
///
/// **2. It must be registered in the run loop's *common* modes.** A timer in the default mode alone
/// stops being serviced the moment AppKit runs the loop in `NSEventTrackingRunLoopMode` — which is
/// every window drag and every open menu. Measured, not inherited: see the measurement in
/// `hotkey-source` phase 5's report, and ``MainRunLoopTimer`` for the numbers. The tap's own
/// run-loop source already asks for common modes; **a timer inherits nothing from that.**
///
/// What (2) costs when it is got wrong is the whole point of the phase that added this file. The
/// watchdog's timer is stop rule (e) — the 120 s ceiling — and stop rule (f) — the physical poll. A
/// user who starts dictating and then drags a window has both of those switched off for the duration
/// of the drag, with the widget still showing a running session. `PRODUCT_SPEC.md:11` exists to
/// defend against exactly the state where the microphone is open and Vocca says otherwise.
///
/// ## Not `@MainActor`, for the reason ``TapHealthPolicy`` is not
///
/// The isolation is a fact about how a conformance is *used*, and annotating the protocol would put
/// it out of reach of a `deinit`, which is the one place a timer most needs to be torn down. The
/// shipped conformance asserts it at every entrance instead — the same shape ``CGEventTapSource``
/// arrived at.
public protocol RepeatingTimer: AnyObject {
    /// The interval it is firing at, or `nil` when it is not running.
    ///
    /// **The single fact, kept in one place, so that no caller has to keep a shadow copy of it.**
    /// That is not tidiness: ``ScheduledWatchdog`` is written to hold no state of its own, exactly as
    /// `SessionWatchdog` is, because a flag saying "the timer is running" is a flag that can disagree
    /// with the timer. Both questions a caller has — *is it running?* and *is it running at the right
    /// cadence?* — are answered from here.
    ///
    /// A conformance answers from the timer it holds, never from a value it remembered on the way in.
    var interval: Duration? { get }

    /// Start firing `fire` every `interval`, until ``stop()``.
    ///
    /// **A start on a running timer is a `stop()` followed by a start**, the same obligation
    /// `HotkeyEventSource/start(delivering:)` carries and for a related reason: a conformance that
    /// merely added a second scheduled timer would leave the first one firing into the same callback
    /// forever, at a cadence nobody asked for, with no handle left to cancel it by.
    ///
    /// **It must not call `fire` before it returns.** One that did would put a session end on the
    /// caller's own stack, in the middle of whatever moved the schedule — which is the re-entrancy
    /// `CallbackSafeTapDisablement` exists to keep off a tap callback, arrived at from the other end.
    /// The caller re-reads the schedule immediately after starting, so a synchronous first fire would
    /// also mean the schedule being read while the effect it depends on is still on the stack.
    ///
    /// The first fire is therefore no sooner than one `interval` away. That is a real cost and it is
    /// the right one: the watchdog's timer starts when a session starts, and a session cannot have
    /// reached its ceiling or lost its key in the instant it began.
    func start(every interval: Duration, _ fire: @escaping () -> Void)

    /// Stop firing, and release `fire`. Idempotent.
    ///
    /// Releasing the closure is part of the contract rather than a consequence of it: `fire` reaches
    /// the session machine, and a timer that held one after being stopped would keep the whole
    /// session graph alive for as long as the timer object lived.
    func stop()
}
