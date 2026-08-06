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

// **The capture start, off the tap callback.**
//
// `AVAudioEngine.start()` was measured at a 114 ms median and a 119 ms p99 over 120 verified
// sessions (`Scripts/measure-engine-start.sh`; the table is on `CaptureStartTiming`). Two aspects
// had shipped on the estimate "milliseconds". This suite pins the resolution that number forced.
//
// It is written against `session-lifecycle`'s three guarantees, because those are what a hop is most
// likely to break and none of them is negotiable:
//
//   1. a stop arriving during the opening is applied the instant the session exists;
//   2. ending a session is never deferred;
//   3. no path may leave a session recording with no way to end it.
//
// The whole of the machine's old behaviour is still pinned by the 388 tests that were written before
// this change and are untouched by it — `CaptureStartTiming.immediately` is the default precisely so
// that they keep exercising the identical transition. What is new here is the other timing, and the
// one thing above the machine that the hop made load-bearing: the watchdog's timer is now started by
// the *completed opening* rather than by the key event, and a session with no timer has no ceiling.

private let chord = HotkeyConfiguration(
    keyCode: 49, modifiers: [.option], activation: .holdToTalk)

private let toggleChord = HotkeyConfiguration(
    keyCode: 49, modifiers: [.option], activation: .toggle)

private func event(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet,
    autorepeat: Bool = false
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: autorepeat,
        timestamp: .zero)
}

/// The shipped pipeline, with the run loop as a queue the test turns by hand:
/// **tap → ScheduledWatchdog → SessionEventSink → watchdog → machine → microphone**.
///
/// Built here rather than borrowed from `ScheduledWatchdogTests` because that suite's harness is
/// file-private and — more to the point — this one must never drain the run loop for a test. The gap
/// between the callback returning and the microphone opening is the subject.
private final class SinkHarness {
    let clock = TestClock()
    let microphone = RecordingSource()
    let keyboard = Keyboard()
    let effects = EffectLog()
    let timer = FakeTimer()
    let runLoop = DeferralQueue()
    let tap = FakeHotkeyEventSource()
    let machine: SessionMachine<RecordingSource.Buffer>
    let scheduled: ScheduledWatchdog<RecordingSource.Buffer>
    let configuration: HotkeyConfiguration

    init(
        configuration: HotkeyConfiguration = chord,
        timing: CaptureStartTiming = .whenTheOwnerAsks
    ) {
        self.configuration = configuration
        self.machine = SessionMachine(
            configuration: configuration, ceiling: SessionCeiling.default, clock: clock,
            audioSource: microphone, captureStartTiming: timing)
        let watchdog = SessionWatchdog(
            machine: machine, keyState: TruthfulKeyState(keyboard))
        self.scheduled = ScheduledWatchdog(
            watchdog: watchdog, timer: timer, deferOpening: runLoop.schedule
        ) { [effects] effect in
            effects.record(effect)
        }
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

    /// One turn of the clock, with time actually passing — the two are separate facts, and a test
    /// that only turned the clock would never reach the ceiling.
    func tick(_ times: Int = 1) {
        for _ in 0..<times {
            clock.now += WatchdogPolicy.pollInterval
            timer.tick()
        }
    }
}

/// The machine alone, with the opening left pending for the test to perform.
///
/// No watchdog, no timer, no run loop: the point of this half is that the *machine* is correct with
/// a 114 ms hole in the middle of a press, and a harness that drained the hole automatically could
/// not see the hole.
private final class MachineHarness {
    let clock = TestClock()
    let microphone = RecordingSource()
    let machine: SessionMachine<RecordingSource.Buffer>
    let configuration: HotkeyConfiguration

    init(
        configuration: HotkeyConfiguration = chord,
        timing: CaptureStartTiming = .whenTheOwnerAsks
    ) {
        self.configuration = configuration
        self.machine = SessionMachine(
            configuration: configuration, ceiling: SessionCeiling.default, clock: clock,
            audioSource: microphone, captureStartTiming: timing)
    }

    @discardableResult
    func press() -> SessionResponse<RecordingSource.Buffer> {
        machine.observe(event(.keyDown, configuration.keyCode, configuration.modifiers))
    }

    @discardableResult
    func release() -> SessionResponse<RecordingSource.Buffer> {
        machine.observe(event(.keyUp, configuration.keyCode, configuration.modifiers))
    }

    @discardableResult
    func autorepeat() -> SessionResponse<RecordingSource.Buffer> {
        machine.observe(
            event(.keyDown, configuration.keyCode, configuration.modifiers, autorepeat: true))
    }
}

final class DeferredCaptureStartTests: XCTestCase {

    // MARK: - The callback returns without opening a microphone

    /// **The decision this phase exists to make, as one assertion.**
    ///
    /// The event is decided, the key is claimed and swallowed, and `beginCapture()` has not been
    /// called — so the ~114 ms is not on this call. Every clause matters: a version that returned
    /// fast by declining to decide would satisfy the timing and break the keyboard.
    func testTheDecidingEventReturnsWithoutOpeningTheMicrophone() {
        for configuration in [chord, toggleChord] {
            let harness = MachineHarness(configuration: configuration)

            let response = harness.press()

            XCTAssertEqual(response.effect, .opening, "\(configuration.activation)")
            XCTAssertEqual(
                response.eventPropagation, .swallow,
                "the hotkey's own press must not reach the focused application")
            XCTAssertFalse(
                harness.microphone.isOpen, "the microphone must not open on the callback")
            XCTAssertEqual(
                harness.microphone.beginCount, 0,
                "`beginCapture()` is the 114 ms call and it must not have happened yet")
            XCTAssertEqual(harness.machine.state, .idle)
            XCTAssertTrue(harness.machine.hasPendingOpening)
        }
    }

    /// And then the owner performs it, and the session exists.
    func testCompletingThePendingOpeningStartsTheSession() {
        let harness = MachineHarness()
        harness.press()

        let effect = harness.machine.completePendingOpening()

        XCTAssertEqual(effect, .started)
        XCTAssertTrue(harness.microphone.isOpen)
        XCTAssertEqual(harness.microphone.beginCount, 1)
        XCTAssertEqual(harness.machine.state, .recording)
        XCTAssertFalse(
            harness.machine.hasPendingOpening, "the debt is discharged, not merely paid once")
    }

    /// A microphone that refuses leaves no session — and **keeps the claim**, because the user
    /// pressed Vocca's hotkey and the repeats are Vocca's to eat whether or not the hardware agreed.
    func testAnUnavailableMicrophoneLeavesNoSessionAndKeepsTheClaim() {
        let harness = MachineHarness()
        harness.microphone.nextStart = .unavailable
        harness.press()

        XCTAssertEqual(harness.machine.completePendingOpening(), .captureUnavailable)
        XCTAssertEqual(harness.machine.state, .idle)
        XCTAssertFalse(harness.microphone.isOpen)
        XCTAssertEqual(
            harness.autorepeat().eventPropagation, .swallow,
            "the press was claimed before the microphone was asked, and stays claimed")
    }

    // MARK: - Guarantee 1: a stop in the window is applied the instant the session exists

    /// **A hotkey tapped for less than 114 ms.** At the measured cost that is not an edge case — it
    /// is an ordinary tap — so the session must open and close on the owner's single turn, with
    /// whatever the opening caught, and the reason must be the user's own key-up.
    func testAKeyUpDuringThePendingOpeningEndsTheSessionTheInstantItExists() {
        let harness = MachineHarness()
        harness.press()

        let duringTheWindow = harness.release()
        XCTAssertEqual(
            duringTheWindow.effect, .unchanged,
            "there is no session yet, so nothing has ended — but the stop must be held, not dropped")
        XCTAssertEqual(harness.microphone.endCount, 0)

        let effect = harness.machine.completePendingOpening()

        guard case .ended(let outcome) = effect else {
            return XCTFail("the held stop must be applied the instant the session exists: \(effect)")
        }
        guard case .completed(let reason, _, _) = outcome.content else {
            return XCTFail("a key-up retains its audio")
        }
        XCTAssertEqual(reason, .keyUp)
        XCTAssertFalse(harness.microphone.isOpen, "the microphone must not be left open")
        XCTAssertEqual(harness.microphone.beginCount, 1)
        XCTAssertEqual(harness.microphone.endCount, 1)
        XCTAssertEqual(harness.machine.state, .idle)
    }

    /// Escape inside the window. The audio is discarded and the microphone is **not** — those are
    /// different things, and only the first was ever the user's instruction.
    func testACancellationDuringThePendingOpeningStillClosesTheMicrophone() {
        let harness = MachineHarness()
        harness.press()

        XCTAssertEqual(harness.machine.cancel(), .unchanged)

        guard case .ended(let outcome) = harness.machine.completePendingOpening() else {
            return XCTFail("the cancellation must reach the session it was meant for")
        }
        guard case .cancelled = outcome.content else {
            return XCTFail("Escape discards the transcript")
        }
        XCTAssertFalse(harness.microphone.isOpen)
        XCTAssertEqual(harness.microphone.endCount, 1)
    }

    /// A tap death inside the window — the case `SessionMachine`'s own table calls the worst of the
    /// three, because no key event can ever arrive again and the poll reports the key **down**.
    func testATapDeathDuringThePendingOpeningEndsTheSession() {
        let harness = MachineHarness()
        harness.press()

        _ = harness.machine.observe(event(.tapDisabled, 0, []))

        guard case .ended(let outcome) = harness.machine.completePendingOpening(),
            case .completed(let reason, _, _) = outcome.content
        else {
            return XCTFail("a tap that died during the opening must not leave a session running")
        }
        XCTAssertEqual(reason, .tapDisabled)
        XCTAssertFalse(harness.microphone.isOpen)
    }

    /// A system trigger inside the window, which is the route
    /// `AVAudioEngineConfigurationChangeNotification` will take in Phase 4.
    func testASystemTriggerDuringThePendingOpeningEndsTheSession() {
        let harness = MachineHarness()
        harness.press()

        XCTAssertEqual(harness.machine.observe(SystemTrigger.willSleep), .unchanged)

        guard case .ended(let outcome) = harness.machine.completePendingOpening(),
            case .completed(let reason, _, _) = outcome.content
        else {
            return XCTFail("a system trigger during the opening must end the session it precedes")
        }
        XCTAssertEqual(reason, .systemEvent(.willSleep))
        XCTAssertFalse(harness.microphone.isOpen)
    }

    /// **First one wins.** The key-up is the user's own gesture and the more specific fact, and the
    /// log is the only evidence anyone gets about a session that ended surprisingly.
    func testTheFirstStopWinsWhenTwoArriveDuringTheSameOpening() {
        let harness = MachineHarness()
        harness.press()

        harness.release()
        _ = harness.machine.observe(event(.tapDisabled, 0, []))

        guard case .ended(let outcome) = harness.machine.completePendingOpening(),
            case .completed(let reason, _, _) = outcome.content
        else {
            return XCTFail("one of the two stops must have been applied")
        }
        XCTAssertEqual(reason, .keyUp, "the user's own release outranks the tap's death")
        XCTAssertEqual(harness.microphone.endCount, 1, "and only one session ended")
    }

    // MARK: - Guarantee 2: no second microphone, and no second opening

    /// A second press inside the window is refused, which is the fail-closed rule
    /// `isOpeningTheMicrophone` was invented for — reached now on every press rather than in a race.
    ///
    /// **The two activation modes diverge here, and the divergence is correct.** In hold-to-talk a
    /// second `.keyDown` at `.recording` is an unconditional `.ignore`, so the session opens
    /// normally. In toggle it is `.toggledOff` — a stop — so it is *held* and applied the instant the
    /// session exists, and the user's double-tap ends the session it started. Both are asserted
    /// rather than one, because "opens nothing" is true of both and is not the whole of either.
    func testASecondPressDuringThePendingOpeningOpensNoSecondMicrophone() {
        for configuration in [chord, toggleChord] {
            let harness = MachineHarness(configuration: configuration)
            harness.press()

            XCTAssertEqual(
                harness.press().effect, .unchanged,
                "\(configuration.activation): no second session may begin inside the first's opening")

            let completed = harness.machine.completePendingOpening()
            switch configuration.activation {
            case .holdToTalk:
                XCTAssertEqual(completed, .started)
                XCTAssertTrue(harness.microphone.isOpen)
            case .toggle:
                guard case .ended(let outcome) = completed,
                    case .completed(let reason, _, _) = outcome.content
                else {
                    return XCTFail("toggle: the second press is a toggle-off and must end it")
                }
                XCTAssertEqual(reason, .toggledOff)
                XCTAssertFalse(harness.microphone.isOpen)
            }

            XCTAssertEqual(
                harness.microphone.beginCount, 1,
                "\(configuration.activation): one press, one microphone")
            XCTAssertEqual(harness.microphone.overlappingBegins, 0, "\(configuration.activation)")
        }
    }

    /// **The autorepeat train, which the measurement turned from a curiosity into the norm.** macOS
    /// repeats a held key every 30–90 ms, so a 114 ms opening contains one to four of them on every
    /// single press. They must be swallowed — a repeat that reached the focused application types
    /// the character the claim exists to eat — and none of them may start anything.
    func testAutorepeatsDuringThePendingOpeningAreSwallowedAndStartNothing() {
        let harness = MachineHarness()
        harness.press()

        for _ in 0..<4 {
            XCTAssertEqual(harness.autorepeat().eventPropagation, .swallow)
        }

        XCTAssertEqual(harness.machine.completePendingOpening(), .started)
        XCTAssertEqual(harness.microphone.beginCount, 1)
    }

    /// **Inherited constraint 4, at the new window width.** The opening is now ~114 ms of real
    /// typing, and everything the user types in it that is not Vocca's must reach the application
    /// untouched. This is the mutation with the largest blast radius in the package — a hard-coded
    /// `.swallow` on this path is the user's whole keyboard, gone, for an eighth of a second on every
    /// press.
    func testOtherKeystrokesDuringThePendingOpeningReachTheApplication() {
        let harness = MachineHarness()
        harness.press()

        for keyCode: UInt16 in [4, 11, 38, 45] {
            XCTAssertEqual(
                harness.machine.observe(event(.keyDown, keyCode, [.option])).eventPropagation,
                .passThrough, "key code \(keyCode) is not Vocca's")
            XCTAssertEqual(
                harness.machine.observe(event(.keyUp, keyCode, [.option])).eventPropagation,
                .passThrough)
        }

        XCTAssertEqual(harness.machine.completePendingOpening(), .started)
        XCTAssertEqual(harness.microphone.beginCount, 1)
    }

    /// A key event delivered from *inside* `beginCapture()` — a real engine start pumps a run loop —
    /// must not find a second opening to schedule. `openingAwaitsTheOwner` is cleared before the call
    /// rather than after it, and this is what that ordering is for.
    func testAnEventArrivingInsideTheOpeningFindsNothingPending() {
        let harness = MachineHarness()
        var pendingSeenFromInside: Bool?

        harness.microphone.duringBeginCapture = { [machine = harness.machine] in
            pendingSeenFromInside = machine.hasPendingOpening
            _ = machine.observe(event(.keyDown, chord.keyCode, chord.modifiers, autorepeat: true))
        }

        harness.press()
        XCTAssertEqual(harness.machine.completePendingOpening(), .started)

        XCTAssertEqual(
            pendingSeenFromInside, false,
            "an opening that is being performed is not an opening that is owed")
        XCTAssertEqual(harness.microphone.beginCount, 1)
        XCTAssertEqual(harness.microphone.overlappingBegins, 0)
    }

    /// Asking twice is a no-op rather than a second microphone.
    func testCompletingAnOpeningThatIsNotPendingChangesNothing() {
        let harness = MachineHarness()
        harness.press()
        XCTAssertEqual(harness.machine.completePendingOpening(), .started)

        XCTAssertEqual(harness.machine.completePendingOpening(), .unchanged)
        XCTAssertEqual(harness.microphone.beginCount, 1)
        XCTAssertEqual(harness.machine.state, .recording)
    }

    /// And on an untouched machine, before anything has been pressed at all.
    func testCompletingAnOpeningOnAnIdleMachineChangesNothing() {
        let harness = MachineHarness()

        XCTAssertEqual(harness.machine.completePendingOpening(), .unchanged)
        XCTAssertEqual(harness.microphone.beginCount, 0)
        XCTAssertEqual(harness.machine.state, .idle)
    }

    // MARK: - The two timings agree

    /// Under `.immediately` the machine opens the microphone itself, exactly as it did before this
    /// change — and `hasPendingOpening` is `false` throughout, so an owner may ask unconditionally
    /// without ever reaching the deferred path by accident.
    func testTheImmediateTimingOpensOnTheCallAndOwesTheOwnerNothing() {
        let harness = MachineHarness(timing: .immediately)

        XCTAssertEqual(harness.press().effect, .started)
        XCTAssertTrue(harness.microphone.isOpen)
        XCTAssertFalse(harness.machine.hasPendingOpening)
        XCTAssertEqual(
            harness.machine.completePendingOpening(), .unchanged,
            "an owner that asks anyway must not get a second microphone")
        XCTAssertEqual(harness.microphone.beginCount, 1)
    }

    /// **The differential test.** The same gesture through both timings must reach the same place:
    /// the same outcome content, the same end reason, the same ledger. If the hop changed *what*
    /// happens rather than only *when*, this is what says so — and it is checked across the four
    /// gestures whose stop lands in different places.
    ///
    /// **It is anchored, because a differential comparison alone proves only agreement.** Every
    /// `deferred == immediate` clause below is satisfied by a mutation that breaks *both* timings
    /// identically — which is not hypothetical: "the deferred timing silently behaves like
    /// `.immediately`" is one of the mutations this suite is measured against, and a purely
    /// differential test is exactly what it walks past. So each gesture also asserts absolutely that
    /// one microphone was opened, and the two that retain audio assert that a buffer reached custody.
    func testBothTimingsReachTheSameOutcomeForTheSameGesture() {
        let gestures: [(String, retainsAudio: Bool, (MachineHarness) -> Void)] = [
            ("press, complete, release", true, { $0.press(); _ = $0.machine.completePendingOpening(); $0.release() }),
            ("press, release, complete", true, { $0.press(); $0.release(); _ = $0.machine.completePendingOpening() }),
            ("press, complete, cancel", false, { $0.press(); _ = $0.machine.completePendingOpening(); _ = $0.machine.cancel() }),
            ("press, cancel, complete", false, { $0.press(); _ = $0.machine.cancel(); _ = $0.machine.completePendingOpening() }),
        ]

        for (name, retainsAudio, gesture) in gestures {
            let deferred = MachineHarness(timing: .whenTheOwnerAsks)
            let immediate = MachineHarness(timing: .immediately)
            gesture(deferred)
            gesture(immediate)

            XCTAssertEqual(
                deferred.microphone.handedOut, immediate.microphone.handedOut,
                "\(name): the same buffers must reach custody")
            XCTAssertEqual(deferred.microphone.beginCount, immediate.microphone.beginCount, name)
            XCTAssertEqual(deferred.microphone.endCount, immediate.microphone.endCount, name)
            XCTAssertEqual(deferred.microphone.isOpen, immediate.microphone.isOpen, name)
            XCTAssertEqual(deferred.microphone.overlappingBegins, 0, name)
            XCTAssertEqual(deferred.microphone.closesWithoutOpen, 0, name)
            XCTAssertEqual(deferred.machine.state, immediate.machine.state, name)

            // The anchors. Absolute, not comparative.
            for (label, harness) in [("deferred", deferred), ("immediate", immediate)] {
                XCTAssertEqual(
                    harness.microphone.beginCount, 1,
                    "\(name)/\(label): the gesture must have opened exactly one microphone")
                XCTAssertEqual(
                    harness.microphone.endCount, 1,
                    "\(name)/\(label): and closed it exactly once")
                XCTAssertFalse(harness.microphone.isOpen, "\(name)/\(label)")
                XCTAssertEqual(harness.machine.state, .idle, "\(name)/\(label)")
            }
            if retainsAudio {
                XCTAssertFalse(
                    deferred.microphone.handedOut.isEmpty,
                    "\(name): a retaining gesture must carry a buffer into custody")
            }
        }
    }

    // MARK: - The hop itself: ScheduledWatchdog

    /// **What the tap callback actually experiences.** The disposition comes back with the run loop
    /// not yet turned and the microphone still shut — which is the whole of the decision, measured at
    /// the object that owns it.
    func testTheSinkAnswersTheCallbackBeforeTheMicrophoneOpens() {
        let harness = SinkHarness()

        XCTAssertEqual(harness.press(), .swallow)

        XCTAssertFalse(harness.microphone.isOpen, "114 ms of engine start is not on this callback")
        XCTAssertEqual(harness.runLoop.scheduled, 1, "and it was handed to a later turn")
        XCTAssertTrue(harness.runLoop.hasPendingWork)

        harness.runLoop.drain()

        XCTAssertTrue(harness.microphone.isOpen)
        XCTAssertEqual(harness.machine.state, .recording)
    }

    /// **The hazard the hop introduces, pinned.** The watchdog's timer is derived from the machine's
    /// state, and the state now changes on a *later* turn than the event. An owner that settled the
    /// clock only after the event would leave a recording session with no 120 s ceiling and no
    /// physical-key poll — a hot mic with nothing watching it, which is guarantee 3.
    func testTheWatchdogTimerStartsWhenTheOpeningCompletesRatherThanWhenTheKeyIsPressed() {
        let harness = SinkHarness()

        harness.press()
        XCTAssertFalse(harness.timer.isRunning, "there is no session yet, so nothing to watch")

        harness.runLoop.drain()

        XCTAssertTrue(harness.timer.isRunning, "the session exists now and must be watched")
        XCTAssertEqual(harness.timer.cadencesRequested, [WatchdogPolicy.pollInterval])
    }

    /// And the ceiling really does end it — the end-to-end form of guarantee 3, driven through the
    /// deferred path from the tap all the way to custody.
    func testTheCeilingStillEndsASessionThatStartedThroughTheHop() {
        let harness = SinkHarness()
        harness.press()
        harness.runLoop.drain()

        // The key is never released; only the clock moves.
        harness.tick(Int(SessionCeiling.default / WatchdogPolicy.pollInterval) + 1)

        XCTAssertEqual(harness.effects.endReasons, [.ceilingReached])
        XCTAssertFalse(harness.microphone.isOpen)
        XCTAssertFalse(harness.timer.isRunning)
    }

    /// The effect a completed opening produces is **delivered**, not returned into a void. It is the
    /// only announcement a session started this way ever gets.
    func testTheEffectOfACompletedOpeningIsDelivered() {
        let harness = SinkHarness()

        harness.press()
        XCTAssertEqual(harness.effects.effects, [.opening])

        harness.runLoop.drain()
        XCTAssertEqual(harness.effects.effects, [.opening, .started])
    }

    /// A press shorter than the opening: the outcome arrives on the drained turn, carrying the
    /// user's audio, and the timer is stopped rather than left running over an idle machine.
    func testASessionThatEndedInsideTheOpeningDeliversItsOutcomeOnTheDrainedTurn() {
        let harness = SinkHarness()

        harness.press()
        harness.release()
        XCTAssertTrue(harness.effects.outcomes.isEmpty, "nothing has opened, so nothing has ended")

        harness.runLoop.drain()

        XCTAssertEqual(harness.effects.endReasons, [.keyUp])
        XCTAssertEqual(harness.microphone.handedOut.count, 1)
        XCTAssertFalse(harness.microphone.isOpen)
        XCTAssertFalse(harness.timer.isRunning)
    }

    /// One press, one opening — not one per event delivered while it is pending.
    func testOnlyOneOpeningIsScheduledPerPress() {
        let harness = SinkHarness()

        harness.press()
        harness.autorepeat()
        harness.autorepeat()

        XCTAssertEqual(harness.runLoop.scheduled, 1)
        harness.runLoop.drain()
        XCTAssertEqual(harness.microphone.beginCount, 1)
    }

    /// Under the immediate timing the hop is never used at all, so a machine that does not defer
    /// cannot be slowed down by an owner that is prepared to.
    func testNothingIsScheduledWhenTheMachineOpensImmediately() {
        let harness = SinkHarness(timing: .immediately)

        harness.press()

        XCTAssertEqual(harness.runLoop.scheduled, 0)
        XCTAssertTrue(harness.microphone.isOpen)
        XCTAssertTrue(harness.timer.isRunning)
    }

    /// **The weak capture, and it is the opposite choice to `CallbackSafeTapDisablement`'s.**
    ///
    /// That class captures strongly, because a disarm racing a disablement would otherwise leave a
    /// tap nothing re-enables. Here a strong capture would open a microphone owned by nobody — no
    /// timer, no watchdog, no route to the funnel — which is a hot mic with the widget showing
    /// nothing. So the microphone must simply never open, and no session is lost because none began.
    func testAReleasedScheduledWatchdogNeverOpensTheMicrophone() {
        let microphone = RecordingSource()
        let keyboard = Keyboard()
        let runLoop = DeferralQueue()
        let tap = FakeHotkeyEventSource()

        do {
            let machine = SessionMachine(
                configuration: chord, ceiling: SessionCeiling.default, clock: TestClock(),
                audioSource: microphone, captureStartTiming: .whenTheOwnerAsks)
            let watchdog = SessionWatchdog(
                machine: machine, keyState: TruthfulKeyState(keyboard))
            let scheduled = ScheduledWatchdog(
                watchdog: watchdog, timer: FakeTimer(), deferOpening: runLoop.schedule
            ) { _ in }
            XCTAssertEqual(tap.start(delivering: scheduled), .started)

            keyboard.hold(chord)
            tap.deliver(event(.keyDown, chord.keyCode, chord.modifiers))
            XCTAssertEqual(runLoop.scheduled, 1)

            tap.stop()
        }

        runLoop.drain()

        XCTAssertFalse(
            microphone.isOpen,
            "a microphone opened for an owner that no longer exists could never be closed")
        XCTAssertEqual(microphone.beginCount, 0)
    }
}
