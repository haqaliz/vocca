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

import Foundation

/// The shipped ``RepeatingTimer``: a `Timer` on the **main run loop**, in its **common** modes.
///
/// Both halves of that sentence are the whole of this file, and each is a measured hazard rather
/// than a preference.
///
/// ## `.common`, not `.default` — measured
///
/// `RunLoop.Mode.common` is a *set*, and what AppKit puts in it is what makes this work: it adds
/// `NSEventTrackingRunLoopMode` (`RunLoop.Mode.eventTracking`) to the common set when
/// `NSApplication` is initialised. A window drag and an open menu both run the main loop in that
/// mode, so a timer registered in `.default` alone is simply not serviced for the duration of the
/// gesture.
///
/// Measured with `Scripts/measure-timers.sh runloop 5` on macOS 26.5.2, Apple silicon
/// (2026-08-06), inside a real accessory `NSApplication`. Four timers running **simultaneously** —
/// the shipped one and a `.default`-only mutant, at each of this package's two cadences — through
/// 5 s of `RunLoop.Mode.eventTracking`, which is the mode AppKit runs the loop in for a drag,
/// entered directly so the number does not depend on a human's hand:
///
/// | Timer | fires while idle | **fires during the gesture** | longest gap during it |
/// |---|---|---|---|
/// | 150 ms, `.common` | 33 | **33** | 151 ms |
/// | 150 ms, `.default` | 33 | **0** | **5018 ms** |
/// | 1 s, `.common` | 5 | **5** | 1001 ms |
/// | 1 s, `.default` | 5 | **0** | **5018 ms** |
///
/// Both mutants resumed normally afterwards (35 and 6 fires), so this is a stall for the duration of
/// the gesture rather than a timer that died.
///
/// **The gap is the gesture, not one interval.** A five-second drag in the default mode is five
/// seconds with no 120 s ceiling, no physical-key poll and no tap-health poll — a third of a
/// thirty-three-fire deficit at the watchdog's cadence — while the widget goes on showing a
/// recording session. `MainRunLoopTimerTests` pins the same mechanism in the suite, so a regression
/// is a red build rather than a smoke step nobody ran.
///
/// **The dependency on AppKit is worth stating**, because it is the one way this could be true in the
/// probe and false in the product, or the reverse: `.eventTracking` is in the common set because
/// `NSApplication` put it there. In a process that never initialises one — a plain SwiftPM
/// executable, a unit test binary that has not touched AppKit — `.common` may be `.default` and
/// nothing else, and registering in it buys exactly nothing. Vocca always has an `NSApplication`
/// (`AppBootstrap`), so this holds in the product; the harness initialises one for the same reason.
///
/// ## The main run loop, not a dispatch queue
///
/// See ``RepeatingTimer``. Everything a fire reaches is non-`Sendable` and lives in one isolation
/// domain, and `CGEventTapSource.isDelivering` — read once a second by the health poll — carries
/// `MainActor.preconditionIsolated`. Off the main actor that is a 1 Hz crash in a release build.
///
/// Isolation is asserted at each entrance rather than by an `@MainActor` annotation, for the reason
/// ``CGEventTapSource`` gives: an annotation would put ``stop()`` out of reach of ``deinit``, which is
/// the one place a timer most needs tearing down.
///
/// ## App Nap: the throttle is real, is bounded, and is deliberately not worked around
///
/// The second hazard `spec.md` carried as unverified was that App Nap throttles an `LSUIElement`
/// app's timers, with `ProcessInfo.beginActivity(...)` as the countermeasure.
///
/// **The first version of this section said "no throttling was observed in any configuration
/// tried". That sentence was worthless and it is worth saying why**, because the mistake is easy to
/// repeat: the measurement never checked whether the process was in the state App Nap applies. A
/// negative result about a state must verify the state was entered. It is one free, no-root,
/// in-process read — `getpriority(PRIO_DARWIN_PROCESS, 0)`, which answers `1` when the task is in
/// the darwin-background suppressed state and `0` otherwise — and every row below now carries it.
///
/// Measured with `Scripts/measure-timers.sh appnap` on macOS 26.5.2 / Apple silicon / AC power. The
/// watchdog's own 150 ms cadence; `taskpolicy -b` is the supported CLI for the same task suppression
/// App Nap applies.
///
/// | Run | **suppressed?** | fires | median | worst |
/// |---|---|---|---|---|
/// | 300 s, real `LSUIElement` `.app` via Launch Services, backgrounded | **no — state 0 throughout** | 2000 / 2000 | 150.0 ms | 152.0 ms |
/// | 45 s under `taskpolicy -b` | **yes — state 1 on every fire** | 181 / 300 (60%) | **262.0 ms** | 336.7 ms |
/// | 45 s under `taskpolicy -b`, `.userInitiated` held | yes — state 1 | 188 / 300 (63%) | 245.4 ms | 339.8 ms |
/// | 45 s under `taskpolicy -b`, `.userInitiatedAllowingIdleSystemSleep` held | yes — state 1 | 192 / 300 (64%) | 247.1 ms | 346.4 ms |
///
/// Three findings, and the first two are the opposite of what the earlier version claimed:
///
/// 1. **The mechanism is not immune.** Under suppression a 150 ms `Timer` on `RunLoop.main` in
///    `.common` mode runs at a ~1.7× median interval and delivers about 60% of its due fires. The
///    1 s health poll stretches the same way (worst observed gap 1142 ms).
/// 2. **`beginActivity` does not lift a suppression already applied** — 63% and 64% against an
///    unassisted 60%, with the state still reading 1 throughout. That is consistent with it
///    preventing the system from *choosing* to suppress rather than overriding suppression in force.
///    Whether it prevents entry is untested, and untestable so long as the system never enters.
/// 3. **A real backgrounded `LSUIElement` app was never put into that state** in 300 s of continuous
///    observation — every one of ~2000 samples read 0. That is now a measured fact rather than an
///    inference from a fire count.
///
/// **So `beginActivity` is not called, and the reason is (1), not (3).** The throttle is real and it
/// is *bounded and modest*: the 150 ms watchdog becomes ~262 ms, the 1 s poll becomes ~1.8 s, and the
/// 120 s ceiling therefore fires roughly a quarter-second late instead of roughly an eighth of a
/// second late. **No microphone becomes unbounded, and no backstop stops working** — which is what
/// separates this from H10 above, where the timer stops entirely. A countermeasure that measurably
/// does not lift the state, bought against a quarter-second, is not worth its assertion.
///
/// **The cost claim that used to be here was also factually wrong**, and it is recorded because a
/// wrong justification in the file whose job is to be the durable record is worse than no
/// justification. It said the useful option sets include `.idleSystemSleepDisabled` — a decision to
/// keep the machine awake. Foundation ships
/// `ProcessInfo.ActivityOptions.userInitiatedAllowingIdleSystemSleep`, which is `.userInitiated`
/// *minus* that bit; verified on this SDK — `userInitiated = 0xffffff`,
/// `userInitiatedAllowingIdleSystemSleep = 0xefffff`, `idleSystemSleepDisabled = 0x100000`. The
/// earlier measurement chose the heaviest available option set and then used its weight as the reason
/// not to adopt it. There is a strictly cheaper form; it is in the table above; it does not help
/// either.
///
/// **Still not tried, and named so nobody reads the table as more than it is:** battery power, and a
/// machine left idle with the display asleep. Both are documented to make App Nap more aggressive and
/// neither was reachable here (the machine was on AC and `UserIsActive` was asserted system-wide
/// throughout). `SMOKE_CHECKLIST.md` carries both — with the suppression-state check as part of the
/// step, because without it the result is the uninformative one this section had to retract.
public final class MainRunLoopTimer: RepeatingTimer {

    /// The scheduled timer, or `nil` when there is none. The single fact ``interval`` is derived
    /// from, so there is no remembered cadence to disagree with the one actually installed.
    private var timer: Timer?

    public init() {}

    /// The message on the isolation preconditions.
    private let mustBeOnTheMainActor = """
        A MainRunLoopTimer was used off the main actor. It is attached to the main run loop, so its \
        fires arrive there, and everything a fire reaches — the session machine, the watchdog, the \
        tap-health policy, the tap — is deliberately non-Sendable and lives in that one domain.
        """

    public var interval: Duration? {
        MainActor.preconditionIsolated(mustBeOnTheMainActor)
        // Asked of the timer, never remembered.
        //
        // **The `isValid` read and `tearDown`'s `timer = nil` are a redundant pair today, and
        // deleting either alone is invisible — measured.** Each survives the suite on its own;
        // removing *both* is caught by `testTheIntervalIsNilBeforeStartingAndAfterStopping`. Said
        // plainly so that nobody deletes one as dead code: a `repeats: true` `Timer` never
        // self-invalidates and every teardown here nils the handle, so the case this read is written
        // for — an invalidated timer nobody told this object about — is unreachable in the shipped
        // code. It is kept because the alternative is a property that answers from a handle whose
        // validity it has not checked, which is the shape `RepeatingTimer.interval` exists to forbid.
        guard let timer, timer.isValid else { return nil }
        return .seconds(timer.timeInterval)
    }

    public func start(every interval: Duration, _ fire: @escaping () -> Void) {
        MainActor.preconditionIsolated(mustBeOnTheMainActor)

        // The protocol's obligation, and it is not a courtesy: a second scheduled timer would fire
        // into the same callback forever with no handle left to cancel it by.
        stop()

        // `Timer`'s block is `@Sendable` and `fire` is not — it reaches the session machine, which is
        // non-`Sendable` on purpose because a tap callback is a synchronous C function. This is the
        // narrowest form of the assertion that the block runs on the main run loop, which it does
        // because that is the loop it is added to two lines below. It is the same escape hatch, for
        // the same reason, as the one in `voccaHotkeyTapCallback`.
        nonisolated(unsafe) let unsafeFire = fire

        // **`self` is deliberately not captured.** The run loop retains a scheduled timer and the
        // timer retains its block, so a block capturing `self` would keep this object alive for as
        // long as the timer ran — which sounds safe and is the opposite: ``deinit`` could then never
        // run while a timer was live, so an owner that dropped this object would leak a timer that
        // fires forever with nothing left to stop it. Capturing only the closure leaves the owner's
        // release able to tear the timer down.
        let timer = Timer(timeInterval: seconds(interval), repeats: true) { _ in
            unsafeFire()
        }

        // `.common` and not `.default`: see the type's documentation for the measurement. This is
        // the H10 hazard and the single line this phase exists to get right.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        MainActor.preconditionIsolated(mustBeOnTheMainActor)
        tearDown()
    }

    /// The net under an owner that dropped this without stopping it.
    ///
    /// A `Timer` scheduled on a run loop is retained *by the run loop*, so nothing about this object
    /// going away stops it. Without this, a dropped timer fires into the session graph forever.
    ///
    /// It skips the isolation assertion for the reason ``CGEventTapSource/deinit`` does: a `deinit`
    /// runs wherever the last release happens, which is not this object's choice, and trapping there
    /// would turn "an owner released me on the wrong thread" into a crash at exit.
    ///
    /// **The thread question is not a clean no here, and saying otherwise would be the false safety
    /// claim this repository has now corrected twice.** `Timer.invalidate()` is documented as having
    /// to be called on the thread that installed the timer, which is the main one. What makes it
    /// acceptable is that every owner in this package is main-actor-confined by construction — the
    /// timer is reachable only from ``ScheduledWatchdog`` and ``TapHealthTimer``, both of which sit in
    /// the tap's isolation domain — so the last release is on the main thread unless something has
    /// already gone wrong. The alternative is worse and unbounded: a live timer nobody holds.
    deinit {
        tearDown()
    }

    /// The teardown itself, with no isolation assertion on it, so that ``deinit`` can reach it.
    private func tearDown() {
        timer?.invalidate()
        timer = nil
    }

    /// `Duration` to the `TimeInterval` `Timer` takes.
    ///
    /// Written out rather than reached for from a helper because it is the one arithmetic in this
    /// file and it is lossy in a direction worth naming: `Duration` is attosecond-exact and
    /// `TimeInterval` is a `Double`, so a cadence is reproduced to about a nanosecond. Against a
    /// 150 ms poll and a 120 s ceiling that is nothing, and the run loop's own resolution is orders
    /// of magnitude coarser than either.
    private func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
