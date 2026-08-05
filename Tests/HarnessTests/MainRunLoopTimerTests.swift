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

import CoreFoundation
import Foundation
import VoccaCore
import VoccaHotkey
import XCTest

/// A timer registered in `RunLoop.Mode.default` alone — **the mutant**, kept as a runnable object.
///
/// It is `MainRunLoopTimer` with one token changed, which is the whole of the H10 hazard: the
/// difference between a ceiling that fires during a window drag and one that does not is `.common`
/// against `.default` on one line. A control that is described rather than run proves nothing, and
/// the assertions below are only meaningful because this one is here to fail them.
private final class DefaultModeTimer: RepeatingTimer {
    private var timer: Timer?

    var interval: Duration? {
        guard let timer, timer.isValid else { return nil }
        return .seconds(timer.timeInterval)
    }

    func start(every interval: Duration, _ fire: @escaping () -> Void) {
        stop()
        nonisolated(unsafe) let unsafeFire = fire
        let timer = Timer(
            timeInterval: TimeInterval(interval.components.seconds)
                + TimeInterval(interval.components.attoseconds) / 1e18,
            repeats: true
        ) { _ in unsafeFire() }
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}

/// A counter a timer's closure can reach without capturing an actor-isolated `self`.
private final class FireCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// **The H10 hazard, measured in the suite rather than asserted in a comment.**
///
/// The claim under test is one line of `MainRunLoopTimer`: a timer registered in the run loop's
/// *common* modes keeps being serviced while the loop is running in `NSEventTrackingRunLoopMode`,
/// and one registered in the default mode alone does not. That mode is what AppKit runs the main
/// loop in for the whole of a window drag and for as long as a menu is open — so if the claim is
/// false, a dictation session started before such a gesture has **no 120 s ceiling and no
/// physical-key poll** for its duration, with the widget still showing it as recording.
///
/// ## Why this can be a test at all, given nothing else in this aspect can
///
/// Because the mechanism is a run-loop mode rather than an Accessibility grant. Two things make it
/// reachable here:
///
/// - **The mode can be entered directly.** `RunLoop.run(mode:before:)` puts the main loop in
///   `.eventTracking` exactly as a drag does. What a real drag adds is a hand on a mouse.
/// - **`.eventTracking` is a common mode because AppKit says so**, and `CFRunLoopAddCommonMode` is
///   the call AppKit makes. This suite makes it in ``setUp()``, because a unit-test process has no
///   `NSApplication`. That is the one substitution here, it is named, and it is exactly what the
///   product gets from `AppBootstrap`.
///
/// The number in `MainRunLoopTimer`'s documentation comes from `Scripts/measure-timers.sh`, which
/// runs the shipped timer inside a real accessory application with a real window to drag. This is
/// the same mechanism, pinned so a regression is a red suite rather than a smoke step nobody ran.
///
/// ## The one global side effect in this suite, stated because it is unusual
///
/// `CFRunLoopAddCommonMode` cannot be undone, so the main run loop of the test process keeps
/// `.eventTracking` in its common set for the rest of the run. Nothing else in this package drives a
/// real run loop, and the change is monotonic — it can only cause *more* sources to be serviced.
@MainActor
final class MainRunLoopTimerTests: XCTestCase {

    /// The cadence these tests run at.
    ///
    /// Deliberately far below `WatchdogPolicy.pollInterval`: what is being measured is whether a
    /// timer is serviced at all in a given mode, not the shipped cadence, and a fast timer makes the
    /// window short enough that the suite stays quick. `SessionWatchdogTests` owns the cadence.
    private let cadence = Duration.milliseconds(20)

    /// Long enough for roughly twenty fires, short enough to be free.
    private let window: TimeInterval = 0.4

    override func setUp() {
        super.setUp()
        // What AppKit does when `NSApplication` is initialised. Without it, `.common` in a unit-test
        // process is `.default` alone, and both arms of the comparison below would agree for the
        // wrong reason.
        // Spelled from `RunLoop.Mode.eventTracking`'s own raw value rather than from a CoreFoundation
        // constant: `CFRunLoopMode` has no `.eventTracking` member — the name belongs to AppKit
        // (`NSEventTrackingRunLoopMode`), and Foundation's `RunLoop.Mode` is where Swift surfaces it.
        // Deriving it here is what keeps the mode this suite registers identical to the mode it then
        // runs the loop in, rather than two spellings of a string that could drift apart.
        CFRunLoopAddCommonMode(
            CFRunLoopGetMain(),
            CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
    }

    /// Drive the main run loop in `mode` for `window` seconds, in short turns so it is genuinely
    /// serviced rather than blocked.
    private func runMainLoop(in mode: RunLoop.Mode) {
        let deadline = Date().addingTimeInterval(window)
        while Date() < deadline {
            RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - The measurement

    /// **The shipped timer keeps firing through the gesture; the mutant stops dead.**
    ///
    /// Both run simultaneously under the identical window, which is what makes this a comparison
    /// rather than two anecdotes: any environmental reason the loop might not be serviced applies to
    /// both arms equally.
    func testATimerInCommonModesSurvivesEventTrackingAndOneInDefaultModeDoesNot() {
        let shipped = MainRunLoopTimer()
        let mutant = DefaultModeTimer()
        let common = FireCount()
        let deflt = FireCount()

        shipped.start(every: cadence) { common.increment() }
        mutant.start(every: cadence) { deflt.increment() }
        defer {
            shipped.stop()
            mutant.stop()
        }

        // The control, first and in the ordinary mode: both timers work when nothing is happening.
        // Without this, "the mutant never fired" would be satisfied by a mutant that never worked.
        runMainLoop(in: .default)
        XCTAssertGreaterThan(
            common.value, 0, "the shipped timer did not fire even in the default mode")
        XCTAssertGreaterThan(
            deflt.value, 0,
            """
            The default-mode control never fired at all, so its silence during the gesture below \
            would say nothing. Both timers must work before the comparison means anything.
            """)

        let commonBeforeTheGesture = common.value
        let defaultBeforeTheGesture = deflt.value

        // The gesture: the mode AppKit runs the main loop in for the whole of a window drag.
        runMainLoop(in: .eventTracking)

        let commonDuring = common.value - commonBeforeTheGesture
        let defaultDuring = deflt.value - defaultBeforeTheGesture

        XCTAssertGreaterThan(
            commonDuring, 0,
            """
            The shipped timer stopped firing while the run loop was in event-tracking mode — which \
            is every window drag and every open menu. A session running through such a gesture has \
            no 120 s ceiling and no physical-key poll for its duration, and the widget goes on \
            saying it is recording. This is H10, and it is the sentence PRODUCT_SPEC.md:11 exists to \
            defend.
            """)
        XCTAssertEqual(
            defaultDuring, 0,
            """
            A timer registered in `.default` alone was serviced during event tracking, which is the \
            thing that makes `.common` unnecessary. If this is genuinely true on this platform then \
            MainRunLoopTimer's justification is wrong and should be corrected rather than left \
            standing — but check first that the loop really entered event-tracking mode.
            """)
    }

    /// The gap the mutant leaves is the whole gesture, not one interval.
    ///
    /// Stated separately because a fire *count* understates it: the interesting number is how long
    /// the microphone can stay open past its ceiling, and that is the length of the drag. Twenty
    /// nominal intervals pass here with the mutant delivering nothing.
    func testTheGapTheDefaultModeLeavesIsTheWholeGestureAndNotOneInterval() {
        let mutant = DefaultModeTimer()
        let deflt = FireCount()
        mutant.start(every: cadence) { deflt.increment() }
        defer { mutant.stop() }

        runMainLoop(in: .default)
        let before = deflt.value
        XCTAssertGreaterThan(before, 0)

        let started = Date()
        runMainLoop(in: .eventTracking)
        let gesture = Date().timeIntervalSince(started)

        let missed = Int(gesture / 0.020)
        XCTAssertEqual(
            deflt.value - before, 0,
            """
            \(String(format: "%.0f", gesture * 1000)) ms of event tracking passed — about \(missed) \
            nominal intervals — and the default-mode timer delivered \(deflt.value - before) of \
            them. At the watchdog's real 150 ms cadence a ten-second drag is sixty-six missed \
            polls, and the ceiling is measured in those polls.
            """)
    }

    // MARK: - The contract

    /// `interval` is a question put to the timer, so a stopped one answers `nil` and there is no
    /// remembered cadence to disagree with what is installed. `ScheduledWatchdog` derives its entire
    /// behaviour from this one property.
    func testTheIntervalIsNilBeforeStartingAndAfterStopping() {
        let timer = MainRunLoopTimer()
        XCTAssertNil(timer.interval, "a timer that has never started reported a cadence")

        timer.start(every: cadence) {}
        XCTAssertEqual(timer.interval, cadence)

        timer.stop()
        XCTAssertNil(timer.interval, "a stopped timer still reports a cadence")

        timer.stop()
        XCTAssertNil(timer.interval, "stop must be idempotent")
    }

    /// A start on a running timer is a stop followed by a start.
    ///
    /// The failure it rules out is a second scheduled `Timer` firing into the same callback forever
    /// with no handle left to cancel it by — measured as a doubled fire rate, because the run loop
    /// would service both.
    func testStartingAgainReplacesTheTimerRatherThanAddingASecond() {
        let timer = MainRunLoopTimer()
        let first = FireCount()
        let second = FireCount()

        timer.start(every: cadence) { first.increment() }
        timer.start(every: cadence) { second.increment() }
        defer { timer.stop() }

        runMainLoop(in: .default)

        XCTAssertGreaterThan(second.value, 0, "the replacement timer never fired")
        XCTAssertEqual(
            first.value, 0,
            """
            The timer replaced by the second `start` is still scheduled and still firing. Nothing \
            holds a reference to it, so nothing can ever stop it.
            """)
    }

    /// It does not fire before `start` returns.
    ///
    /// The protocol forbids it, and the reason is re-entrancy: `ScheduledWatchdog` starts the timer
    /// from inside `reconsider()`, which is called from inside `receive(_:)` — so a synchronous first
    /// fire would run a session-ending wake on the tap callback's own stack.
    func testItDoesNotFireBeforeStartReturns() {
        let timer = MainRunLoopTimer()
        let fires = FireCount()
        timer.start(every: .milliseconds(1)) { fires.increment() }
        defer { timer.stop() }

        XCTAssertEqual(
            fires.value, 0,
            "the timer fired synchronously from `start`, which puts a session end on the caller's stack")
    }

    /// A dropped timer stops.
    ///
    /// The run loop retains a scheduled `Timer`, so nothing about the owner going away stops it on
    /// its own — that is what `deinit` is for. Without it, every `ScheduledWatchdog` ever released
    /// leaves a 150 ms timer running for the life of the process.
    func testAReleasedTimerStopsFiring() {
        let fires = FireCount()
        do {
            let timer = MainRunLoopTimer()
            timer.start(every: cadence) { fires.increment() }
        }

        runMainLoop(in: .default)

        XCTAssertEqual(
            fires.value, 0,
            """
            A MainRunLoopTimer that nobody holds is still firing \(fires.value) times. The run loop \
            retains the scheduled Timer, so there is no handle left to stop it by.
            """)
    }
}
