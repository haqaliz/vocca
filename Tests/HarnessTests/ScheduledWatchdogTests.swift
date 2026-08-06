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
import VoccaHotkey
import XCTest

// MARK: - Fixtures

private let space: UInt16 = 49

private let chord = HotkeyConfiguration(
    keyCode: space, modifiers: [.option], activation: .holdToTalk)

private let toggleChord = HotkeyConfiguration(
    keyCode: space, modifiers: [.option], activation: .toggle)

private let bothActivationModes = [chord, toggleChord]

private func event(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet,
    autorepeat: Bool = false
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: autorepeat,
        timestamp: .zero)
}

/// The pipeline with the clock in it:
/// **tap → ScheduledWatchdog → SessionEventSink → watchdog → machine → microphone**, with the timer
/// injected and turned by hand.
private final class ClockHarness {
    let clock = TestClock()
    let microphone = RecordingSource()
    let keyboard = Keyboard()
    let effects = EffectLog()
    let timer = FakeTimer()
    let tap = FakeHotkeyEventSource()
    let keyState: TruthfulKeyState
    let machine: SessionMachine<RecordingSource.Buffer>
    let watchdog: SessionWatchdog<RecordingSource.Buffer>
    let scheduled: ScheduledWatchdog<RecordingSource.Buffer>
    let configuration: HotkeyConfiguration

    init(configuration: HotkeyConfiguration = chord) {
        self.configuration = configuration
        let keyState = TruthfulKeyState(keyboard)
        self.keyState = keyState
        self.machine = SessionMachine(
            configuration: configuration, ceiling: SessionCeiling.default, clock: clock,
            audioSource: microphone)
        self.watchdog = SessionWatchdog(machine: machine, keyState: keyState)
        self.scheduled = ScheduledWatchdog(watchdog: watchdog, timer: timer) { [effects] effect in
            effects.record(effect)
        }
    }

    func arm() {
        XCTAssertEqual(tap.start(delivering: scheduled), .started)
    }

    @discardableResult
    func press() -> EventPropagation {
        keyboard.hold(configuration)
        return tap.deliver(event(.keyDown, configuration.keyCode, configuration.modifiers))
    }

    @discardableResult
    func autorepeat() -> EventPropagation {
        tap.deliver(
            event(.keyDown, configuration.keyCode, configuration.modifiers, autorepeat: true))
    }

    @discardableResult
    func release() -> EventPropagation {
        keyboard.release(configuration.keyCode)
        return tap.deliver(event(.keyUp, configuration.keyCode, configuration.modifiers))
    }

    /// One turn of the clock, with time actually passing — the two are separate facts and a test
    /// that only turned the clock would never reach the ceiling.
    func tick(_ times: Int = 1) {
        for _ in 0..<times {
            clock.now += WatchdogPolicy.pollInterval
            timer.tick()
        }
    }
}

final class ScheduledWatchdogTests: XCTestCase {

    // MARK: - The timer follows the schedule

    /// The whole contract in one gesture, in both modes: nothing before, running during, nothing
    /// after — and at the cadence `WatchdogPolicy` names rather than one this class invented.
    func testTheTimerRunsForExactlyTheLifeOfASession() {
        for configuration in bothActivationModes {
            let harness = ClockHarness(configuration: configuration)
            harness.arm()

            XCTAssertFalse(
                harness.timer.isRunning,
                """
                \(configuration.activation): a timer was running before any session existed. That is \
                battery spent to learn nothing — `wake()` answers `.unchanged` in `.idle`.
                """)

            harness.press()
            XCTAssertTrue(
                harness.timer.isRunning,
                """
                \(configuration.activation): the session started and no timer did. Nothing is now \
                polling the physical key and nothing is advancing the machine towards its 120 s \
                ceiling — both of those are this timer, and only this timer.
                """)
            XCTAssertEqual(
                harness.timer.interval, WatchdogPolicy.pollInterval,
                "\(configuration.activation): the cadence came from somewhere other than WatchdogPolicy.")

            // Toggle ends on the next matching press; hold-to-talk on the release.
            switch configuration.activation {
            case .holdToTalk: harness.release()
            case .toggle:
                harness.release()
                harness.press()
            }

            XCTAssertFalse(
                harness.timer.isRunning,
                """
                \(configuration.activation): the session ended and the timer kept running. It ends \
                nothing — `wake()` is `.unchanged` in `.idle` — so this is battery, not a hot mic; \
                but a timer nobody stops is a timer nobody notices either.
                """)
        }
    }

    /// **The defect that would make the ceiling unreachable, and it is one line away.**
    ///
    /// `reconsider()` compares against the timer's own interval and leaves a correct one alone. The
    /// obvious alternative — restart it whenever the schedule says `.wake` — reads as harmless and is
    /// not: macOS autorepeats a held key every 30–90 ms, each autorepeat is a `.keyDown` through the
    /// sink, and the cadence is 150 ms. A timer restarted from zero on each of those never reaches
    /// its deadline at all.
    ///
    /// So the assertion is `startCount == 1` across a whole autorepeat train, and it is measured
    /// rather than argued: with the guard removed this test reports 41.
    func testAnAutorepeatTrainDoesNotRestartTheTimer() {
        let harness = ClockHarness()
        harness.arm()
        harness.press()

        XCTAssertEqual(harness.timer.startCount, 1, "the press should have started exactly one timer")

        for _ in 0..<40 { harness.autorepeat() }

        XCTAssertEqual(
            harness.timer.startCount, 1,
            """
            Forty autorepeats restarted the watchdog's timer \(harness.timer.startCount) times. On a \
            real run loop each restart resets the deadline, and macOS autorepeats faster \
            (30–90 ms) than the watchdog's 150 ms cadence — so the timer would never fire, the \
            physical-key poll would never run, and the 120 s ceiling would never be reached, for \
            every hold-to-talk session there is.
            """)
        XCTAssertEqual(
            harness.timer.stopCount, 0,
            "and nothing should have been stopped either — the session never ended.")
    }

    /// A cadence that genuinely changed is a genuine restart. Nothing changes it today, which is
    /// exactly why this is pinned now: a later configurable cadence must take effect, and the
    /// cheapest wrong version of the guard above — `if timer.isRunning { return }` — would silently
    /// leave the old one running forever.
    func testAChangedCadenceRestartsTheTimer() {
        let harness = ClockHarness()
        harness.arm()
        harness.press()
        XCTAssertEqual(harness.timer.cadencesRequested, [WatchdogPolicy.pollInterval])

        // Stand in for a re-configured cadence by moving the timer out from under the object, which
        // is the state a schedule change leaves it in.
        harness.timer.start(every: .milliseconds(500)) {}
        harness.scheduled.reconsider()

        XCTAssertEqual(
            harness.timer.interval, WatchdogPolicy.pollInterval,
            """
            A timer running at a cadence the schedule does not ask for was left alone. `reconsider()` \
            compares intervals rather than testing for nil precisely so that this is a restart.
            """)
        XCTAssertEqual(
            harness.timer.cadencesRequested,
            [WatchdogPolicy.pollInterval, .milliseconds(500), WatchdogPolicy.pollInterval])
    }

    /// A stopped timer is not stopped again, and a running one at the right cadence is not
    /// restarted — so `reconsider()` can be called as often as anything likes.
    ///
    /// That is what makes it safe to hang off every key event the user types all day.
    func testReconsideringChangesNothingWhenTheTimerAlreadyMatches() {
        let harness = ClockHarness()
        harness.arm()

        for _ in 0..<100 { harness.scheduled.reconsider() }
        XCTAssertEqual(harness.timer.startCount, 0)
        XCTAssertEqual(harness.timer.stopCount, 0, "an idle schedule stopped an already-stopped timer")

        harness.press()
        for _ in 0..<100 { harness.scheduled.reconsider() }
        XCTAssertEqual(harness.timer.startCount, 1)
        XCTAssertEqual(harness.timer.stopCount, 0)
    }

    // MARK: - What the timer's own fires do

    /// The wake reaches the machine: the clock advances and the ceiling is eventually reached, with
    /// nothing but timer turns driving it.
    ///
    /// This is the end-to-end claim the whole phase is about — **the ceiling is reachable through the
    /// shipped wiring**, not only through a test calling `watchdog.wake()` by hand.
    func testTheCeilingIsReachedByTurningNothingButThisTimer() throws {
        for configuration in bothActivationModes {
            let harness = ClockHarness(configuration: configuration)
            harness.arm()
            harness.press()

            let turnsToTheCeiling = wakes(covering: SessionCeiling.default)
            harness.tick(turnsToTheCeiling)

            let outcome = try endedOutcome(
                harness.effects.effects.last ?? .unchanged,
                """
                \(configuration.activation): \(turnsToTheCeiling) turns of the timer did not reach \
                the 120 s ceiling. Every backstop in this product that is phrased as a duration is \
                this timer.
                """)
            switch outcome.content {
            case .completed(let reason, _, _):
                XCTAssertEqual(reason, .ceilingReached)
            case .cancelled:
                XCTFail("\(configuration.activation): the ceiling discarded the user's audio")
            }
            XCTAssertFalse(harness.microphone.isOpen, "\(configuration.activation): hot mic")
            XCTAssertFalse(
                harness.timer.isRunning,
                """
                \(configuration.activation): the wake that ended the session left its own timer \
                running. Nothing else was going to stop it — the key events are over by definition.
                """)
        }
    }

    /// A wake's effect leaves by the same door a key event's does.
    ///
    /// The failure this rules out is the quiet one: a `ScheduledWatchdog` that turned the timer
    /// correctly and dropped what came back would end sessions on time and lose every transcript that
    /// ended by the ceiling or by a missed release. `SessionEventSink` exists because that shape
    /// compiles; this is the same guard one layer out, where the effect has a second route.
    func testAWakeThatEndsASessionDeliversItsAudio() throws {
        let harness = ClockHarness()
        harness.arm()
        harness.press()

        // The key comes up with nobody told — the case stop rule (f) exists for.
        harness.keyboard.release(space)
        harness.tick()

        let outcome = try endedOutcome(harness.effects.effects.last ?? .unchanged)
        switch outcome.content {
        case .completed(let reason, let audio, _):
            XCTAssertEqual(reason, .pollDetectedRelease)
            XCTAssertEqual(
                audio, harness.microphone.handedOut.last,
                "the outcome carried a buffer this capture did not produce")
        case .cancelled:
            XCTFail("a missed release discarded the user's audio")
        }
    }

    /// The synthetic `.tapDisabled` a `TapHealthPolicy` mints travels through this object, so a tap
    /// death settles the timer without the policy knowing this class exists.
    ///
    /// That is the structural claim `ScheduledWatchdog` is built on — *every* route into a session
    /// passes through the sink — and it is the one that makes six `TapHealthPolicy` entry points and
    /// a health poll all correct for free.
    func testATapDeathThroughTheSinkStopsTheTimer() {
        for configuration in bothActivationModes {
            let harness = ClockHarness(configuration: configuration)
            harness.arm()
            harness.press()
            XCTAssertTrue(harness.timer.isRunning)

            _ = harness.scheduled.receive(
                RawKeyEvent(
                    kind: .tapDisabled, keyCode: 0, modifiers: [], isAutorepeat: false,
                    timestamp: .zero))

            XCTAssertFalse(harness.microphone.isOpen, "\(configuration.activation): hot mic")
            XCTAssertFalse(
                harness.timer.isRunning,
                """
                \(configuration.activation): the tap died, the session ended, and the timer kept \
                running over an idle machine. The policy has no idea this object exists — the sink \
                is the only thing that connects them, which is why it has to be this object.
                """)
        }
    }

    // MARK: - H6, at this seam too

    /// The disposition is returned unchanged, in **both** directions.
    ///
    /// This object sits on the path every keystroke takes, so a hard-coded answer here is the user's
    /// whole keyboard. Both directions, because the merged aspect's version of this assertion covered
    /// the swallow direction only and the pass-through mutation survived a green suite.
    func testTheDispositionIsReturnedUnchangedInBothDirections() {
        let harness = ClockHarness()
        harness.arm()

        XCTAssertEqual(
            harness.press(), .swallow,
            "the press that starts a session must not reach the focused application")
        XCTAssertEqual(
            harness.tap.deliver(event(.keyDown, 4, [.option])),
            .passThrough,
            """
            An ordinary keystroke was swallowed. This path sees nearly every key the user types, in \
            every application, all day.
            """)
        XCTAssertEqual(harness.release(), .swallow)
        XCTAssertEqual(
            harness.tap.deliver(event(.keyDown, 4, [])), .passThrough,
            "and it is still not eating keys once the session is over")
    }

    /// The schedule is read **after** the event, not before.
    ///
    /// Off by exactly one event in each direction: read first, and the press starts no timer while
    /// the release stops none — so a session runs with no ceiling and then a dead one is polled
    /// forever. The assertion is the timer's state immediately after the call that changed it.
    func testTheScheduleIsReadAfterTheEventAndNotBefore() {
        let harness = ClockHarness()
        harness.arm()

        XCTAssertFalse(harness.timer.isRunning)
        harness.press()
        XCTAssertTrue(
            harness.timer.isRunning,
            """
            The timer was not running immediately after the press. A schedule read *before* the \
            event is derived from a machine the event has not reached yet, so it is `.idle` and the \
            timer starts one event late — which for the last event of a session means never.
            """)

        harness.release()
        XCTAssertFalse(
            harness.timer.isRunning,
            "and not running immediately after the release, for the same reason in reverse.")
    }

    // MARK: - Ownership

    /// **The timer must not keep this object alive, and this object must stop the timer.**
    ///
    /// Both halves of one cycle, and getting either wrong is silent. A strong capture in the fire
    /// closure means `ScheduledWatchdog` never deallocates, so the timer runs for the life of the
    /// process holding a whole session graph alive. Forgetting the `deinit` means a dropped object
    /// leaves a timer firing into a closure whose `self` is `nil` — harmless per fire and permanent.
    func testTheTimerNeitherRetainsThisObjectNorOutlivesIt() {
        let timer = FakeTimer()
        weak var released: ScheduledWatchdog<RecordingSource.Buffer>?

        do {
            let clock = TestClock()
            let keyboard = Keyboard()
            let machine = SessionMachine(
                configuration: chord, ceiling: SessionCeiling.default, clock: clock,
                audioSource: RecordingSource())
            let watchdog = SessionWatchdog(
                machine: machine, keyState: TruthfulKeyState(keyboard))
            let scheduled = ScheduledWatchdog(watchdog: watchdog, timer: timer) { _ in }
            released = scheduled

            keyboard.hold(chord)
            _ = scheduled.receive(event(.keyDown, chord.keyCode, chord.modifiers))
            XCTAssertTrue(timer.isRunning, "the session must be running for this to mean anything")
        }

        XCTAssertNil(
            released,
            """
            The ScheduledWatchdog outlived its only owner. The fire closure captures it strongly, so \
            the timer — which the run loop retains — now holds the watchdog, the session machine and \
            the microphone for the life of the process.
            """)
        XCTAssertFalse(
            timer.isRunning,
            """
            The timer is still running with its owner deallocated. On the main run loop that is a \
            timer firing every 150 ms, forever, that nothing can reach to stop.
            """)
    }
}
