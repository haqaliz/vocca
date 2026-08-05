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
/// ## App Nap: measured, and **not** worked around
///
/// The second hazard `spec.md` carried as unverified was that App Nap throttles an `LSUIElement`
/// app's timers, with `ProcessInfo.beginActivity(...)` as the countermeasure. Measured with
/// `Scripts/measure-timers.sh appnap --bundle`, as a real `LSUIElement` `.app` launched through
/// Launch Services, with no window, not frontmost, on macOS 26.5.2 / Apple silicon / AC power:
///
/// | Run | watchdog fires | median interval | worst interval |
/// |---|---|---|---|
/// | 300 s, no activity assertion | 1999 / 2000 | 150.0 ms | 152.1 ms |
/// | 180 s, `beginActivity` held | 1200 / 1200 | 150.0 ms | 151.1 ms |
///
/// **No throttling was observed in any configuration tried, and the countermeasure changed nothing
/// measurable.** So `beginActivity` is deliberately *not* called here. It is not free — the useful
/// options include `.idleSystemSleepDisabled`, which is a decision to keep a machine awake, and
/// holding one for the length of every dictation session on a privacy-and-battery-conscious tool is
/// not a cost to pay against a hazard nobody could reproduce.
///
/// **What was not tried, stated so nobody reads the table as more than it is:** battery power, and a
/// machine left idle with the display asleep. Both are conditions under which App Nap is documented
/// to be more aggressive and neither was reachable here. `SMOKE_CHECKLIST.md` carries them as manual
/// steps, and this is where the countermeasure goes if one of them reproduces it.
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
        // Asked of the timer, never remembered. An invalidated timer reports `isValid == false`
        // without anybody telling this object, which is precisely the case a cached flag would miss.
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
