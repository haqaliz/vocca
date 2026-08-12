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

/// The same binding in toggle mode — the mode with no key-up rule, no modifier rule and no
/// physical-key poll, where rule (d) is the only stop a dead tap can still deliver.
private let toggleChord = HotkeyConfiguration(
    keyCode: space, modifiers: [.option], activation: .toggle)

private let bothActivationModes = [chord, toggleChord]

private func event(_ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet)
    -> RawKeyEvent
{
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: false, timestamp: .zero)
}

private final class NoteLog {
    private(set) var notes: [TapHealthNote] = []
    func record(_ note: TapHealthNote) { notes.append(note) }
}

/// The shipped pipeline with the disablement observer on the front of it:
/// **observer → policy → source → observing sink → session sink → watchdog → machine → microphone.**
///
/// The same composition `TapHealthPolicyTests` drives, plus the object phase 4 added and the queue
/// that stands in for the run loop. Everything below the fake tap is production code.
private final class DisablementHarness {
    let clock = TestClock()
    let microphone = RecordingSource()
    let keyboard = Keyboard()
    let effects = EffectLog()
    let health = NoteLog()
    let tap = FakeHotkeyEventSource()
    let runLoop = DeferralQueue()
    let machine: SessionMachine<RecordingSource.Buffer>
    let watchdog: SessionWatchdog<RecordingSource.Buffer>
    let sink: ObservingSink
    let policy: TapHealthPolicy
    var observer: CallbackSafeTapDisablement?
    let configuration: HotkeyConfiguration

    init(configuration: HotkeyConfiguration = chord) {
        self.configuration = configuration
        self.machine = SessionMachine(
            configuration: configuration, ceiling: SessionCeiling.default, clock: clock,
            audioSource: microphone)
        self.watchdog = SessionWatchdog(machine: machine, keyState: TruthfulKeyState(keyboard))
        let session = SessionEventSink(watchdog: watchdog) { [effects] effect in
            effects.record(effect)
        }
        let sink = ObservingSink(forwardingTo: session)
        self.sink = sink
        let policy = TapHealthPolicy(
            source: tap, sink: sink, clock: clock, secureInput: FakeSecureInputState()
        ) { [health] note in
            health.record(note)
        }
        self.policy = policy
        self.observer = CallbackSafeTapDisablement(policy: policy) { [runLoop] work in
            runLoop.schedule(work)
        }
    }

    /// Arm, press, and let the operating system switch the tap off — the state every test here
    /// starts from, and the one the adapter's callback is entered in.
    func armAndStartASessionThenLoseTheTap() {
        XCTAssertEqual(policy.arm(), .delivering)
        keyboard.hold(configuration)
        tap.deliver(event(.keyDown, configuration.keyCode, configuration.modifiers))
        XCTAssertTrue(microphone.isOpen, "the session must be recording before the tap dies")
        tap.systemDisablesTheTap()
    }

    /// What the tap's callback does. The one call the adapter makes, made the way the adapter makes
    /// it — through the protocol, with no return value to inspect.
    func theCallbackReportsADisablement(_ reason: TapDisableReason) {
        observer?.tapWasDisabledOnTheCallback(reason)
    }

    var notes: [TapHealthNote] { health.notes }
}

// MARK: -

/// **Decision A, measured: which half of a disablement happens on the tap's own callback.**
///
/// The adapter cannot be run here — `CGEvent.tapCreate` returns `nil` without an Accessibility
/// grant — so what is asserted is the object the adapter delegates to. That is the whole design:
/// the callback's only line about a disablement is `observer?.tapWasDisabledOnTheCallback(reason)`,
/// and everything that line means is here, where a test can put the run loop on pause and look at
/// the state in between.
///
/// The hazard being designed around is concrete. ``TapHealthPolicy/tapWasDisabled(_:)`` ends in a
/// re-creation, a re-creation is `HotkeyEventSource.start(delivering:)`, and that is documented as a
/// `stop()` followed by a `start` — so running it on the callback invalidates the `CFMachPort` whose
/// callback is on the stack and removes the run-loop source currently dispatching it. The split puts
/// that after the callback has returned, and keeps the one thing that must not wait — the
/// microphone — on the near side.
final class CallbackSafeTapDisablementTests: XCTestCase {

    // MARK: - The near half

    /// The claim, in one run: **the microphone closes before the call returns, and nothing else
    /// does.**
    func testTheMicrophoneClosesOnTheCallbackAndTheRecoveryDoesNot() {
        let harness = DisablementHarness()
        harness.armAndStartASessionThenLoseTheTap()
        let startsBefore = harness.tap.startCount

        harness.theCallbackReportsADisablement(.timeout)

        XCTAssertFalse(
            harness.microphone.isOpen,
            """
            The microphone is still open with the callback returned. The key-up that would have \
            ended this session is never coming — a disabled tap delivers nothing — so a run-loop \
            turn is not a bound on how long it stays open, and on the .timeout route the main thread \
            being busy is exactly what earned the disablement.
            """)
        XCTAssertEqual(
            harness.effects.endReasons, [.tapDisabled],
            "The session must end as a tap death, which is the true cause and retains its audio.")

        XCTAssertEqual(
            harness.tap.resumeCount, 0,
            "The tap was re-enabled on the callback. That is the half that must wait.")
        XCTAssertEqual(
            harness.tap.startCount, startsBefore,
            """
            The tap was torn down and re-created from inside its own callback: `start` is a `stop()` \
            followed by a `start`, and that `stop()` invalidates the port this callback belongs to.
            """)
        XCTAssertEqual(
            harness.notes, [.armed],
            """
            A health note about the disablement arrived on the callback — `.armed` is all that has \
            happened so far. The diagnosis travels with the recovery deliberately, so that the log \
            reads in the order things actually happened.
            """)
    }

    /// The same claim in **toggle mode**, where it is worth the most.
    ///
    /// Toggle has no key-up rule, no modifier rule and no physical-key poll, so the synthetic end
    /// this observer triggers is the only thing between a dead tap and a session bounded solely by
    /// the 120 s ceiling.
    func testTheMicrophoneClosesOnTheCallbackInBothActivationModes() {
        for configuration in bothActivationModes {
            let harness = DisablementHarness(configuration: configuration)
            harness.armAndStartASessionThenLoseTheTap()

            harness.theCallbackReportsADisablement(.userInput)

            XCTAssertFalse(
                harness.microphone.isOpen,
                "\(configuration.activation): the microphone outlived the tap.")
            XCTAssertEqual(
                harness.effects.endReasons, [.tapDisabled],
                "\(configuration.activation): the session did not end as a tap death.")
        }
    }

    // MARK: - The far half

    func testTheRecoveryIsScheduledExactlyOnceAndRunsOnTheNextTurn() {
        let harness = DisablementHarness()
        harness.armAndStartASessionThenLoseTheTap()

        harness.theCallbackReportsADisablement(.timeout)

        XCTAssertEqual(
            harness.runLoop.scheduled, 1,
            "One disablement must schedule exactly one recovery.")
        XCTAssertTrue(harness.runLoop.hasPendingWork, "The recovery was not deferred at all.")

        harness.runLoop.drain()

        XCTAssertEqual(
            harness.tap.resumeCount, 1,
            "The deferred half must perform the cheap recovery — acceptance H3's second clause.")
        XCTAssertTrue(harness.tap.isDelivering, "The tap is still off after a full recovery.")
        XCTAssertEqual(
            harness.notes, [.armed, .disabled(.timeout), .reenabled],
            "The diagnosis must arrive with the recovery, and in that order.")
    }

    /// Acceptance **H4**, reached through the callback: when re-enabling does not take, the deferred
    /// half tears the tap down and builds a new one — which is precisely the work that must not
    /// happen while the callback is on the stack.
    func testAFailedReEnableRecreatesTheTapAndOnlyAfterTheCallbackHasReturned() {
        let harness = DisablementHarness()
        harness.armAndStartASessionThenLoseTheTap()
        harness.tap.nextResume = .failed
        let startsBefore = harness.tap.startCount
        let stopsBefore = harness.tap.stopCount

        harness.theCallbackReportsADisablement(.timeout)

        XCTAssertEqual(
            harness.tap.stopCount, stopsBefore,
            """
            The port was invalidated from inside its own callback. This is the concrete hazard the \
            split exists for, and it is a use-after-free rather than an untidiness.
            """)

        harness.runLoop.drain()

        XCTAssertEqual(
            harness.tap.startCount, startsBefore + 1, "The tap was not re-created after the turn.")
        XCTAssertGreaterThan(
            harness.tap.stopCount, stopsBefore, "A re-creation is a teardown followed by a start.")
        XCTAssertEqual(
            harness.notes, [.armed, .disabled(.timeout), .recreated(.reenableFailed)],
            "The log must name the re-creation and why it was needed.")
    }

    /// **A run loop that never turns.** The deferral promises scheduling, not execution, and the
    /// design is arranged so that what is lost when it never runs is the tap and never the
    /// microphone.
    func testARunLoopThatNeverTurnsLeavesTheTapDeadAndTheMicrophoneClosed() {
        let harness = DisablementHarness()
        harness.armAndStartASessionThenLoseTheTap()

        harness.theCallbackReportsADisablement(.timeout)
        // ...and the run loop is never drained.

        XCTAssertFalse(harness.microphone.isOpen, "The one thing that must not wait, waited.")
        XCTAssertEqual(harness.effects.endReasons, [.tapDisabled])
        XCTAssertFalse(harness.tap.isDelivering, "Nothing recovered the tap, as expected.")

        // And the state this leaves is one the ~1 s health poll is built for: a tap that is present
        // and mute, with nobody having been told.
        XCTAssertEqual(
            harness.policy.pollTapHealth(), .delivering,
            "The poll is the backstop for a recovery that never ran, and it must reach the tap.")
        XCTAssertTrue(harness.tap.isDelivering, "The poll did not recover the abandoned tap.")
    }

    /// **The deferred block must survive the observer.**
    ///
    /// It captures the policy strongly on purpose. An owner that releases the observer between the
    /// callback and the next run-loop turn — a disarm racing a disablement — must not thereby leave
    /// a tap that nothing ever re-enables, and a `[weak policy]` capture there would do exactly that,
    /// silently, on a path no other test in this package visits.
    ///
    /// ## Why this test does not use ``DisablementHarness``, which is the finding it was rewritten on
    ///
    /// The first version did, and **it did not measure this at all**: `DisablementHarness` holds
    /// `let policy`, so releasing the observer left the policy alive anyway and the recovery ran
    /// whatever the capture list said. `[weak policy]` passed the entire suite, including this test,
    /// with a doc comment naming that exact mutant.
    ///
    /// The defect was in the harness's *ownership graph*, not in its assertions. Production is
    /// `root → observer → policy → source ─weak→ observer`: the observer really is the policy's only
    /// strong owner. A harness that owns more than production does cannot reproduce a lifetime bug,
    /// however precisely its comment describes one — so the graph is built by hand here, with **no
    /// strong handle on the policy anywhere in this scope**, and the liveness probe below is what says
    /// so rather than assuming it.
    func testTheDeferredRecoveryStillRunsIfTheObserverIsReleasedFirst() {
        let clock = TestClock()
        let microphone = RecordingSource()
        let keyboard = Keyboard()
        let effects = EffectLog()
        let tap = FakeHotkeyEventSource()
        var notes: [TapHealthNote] = []
        var pending: [() -> Void] = []

        let machine = SessionMachine(
            configuration: chord, ceiling: SessionCeiling.default, clock: clock,
            audioSource: microphone)
        let watchdog = SessionWatchdog(machine: machine, keyState: TruthfulKeyState(keyboard))
        let sink = SessionEventSink(watchdog: watchdog) { effects.record($0) }

        // The only handle on the policy that survives this scope, and it is deliberately weak.
        weak var policyAfterTheObserverIsReleased: TapHealthPolicy?

        // Built inside a closure so the strong `policy` binding dies with the closure's scope. From
        // the next line on, the observer is the policy's sole owner — which is what production looks
        // like, and what the first version of this test did not reproduce.
        var observer: CallbackSafeTapDisablement? = {
            let policy = TapHealthPolicy(
                source: tap, sink: sink, clock: clock, secureInput: FakeSecureInputState()
            ) { notes.append($0) }
            policyAfterTheObserverIsReleased = policy
            XCTAssertEqual(policy.arm(), .delivering)
            return CallbackSafeTapDisablement(policy: policy) { pending.append($0) }
        }()

        keyboard.hold(chord)
        tap.deliver(event(.keyDown, chord.keyCode, chord.modifiers))
        XCTAssertTrue(microphone.isOpen, "the session must be recording before the tap dies")
        tap.systemDisablesTheTap()

        observer?.tapWasDisabledOnTheCallback(.userInput)
        observer = nil

        // **The load-bearing line.** Without it this test is satisfiable by any harness that happens
        // to retain the policy some other way, which is exactly how the previous version came to pass
        // against the mutation it was written to kill.
        XCTAssertNotNil(
            policyAfterTheObserverIsReleased,
            """
            The deferred block is not keeping the policy alive, so it is not the policy's remaining \
            owner. A `[weak policy]` capture drops the recovery here — and a disarm racing a \
            disablement then leaves a tap that nothing ever re-enables, in the one file no CI run can \
            execute.
            """)

        for work in pending { work() }

        XCTAssertEqual(tap.resumeCount, 1, "The recovery was dropped with the observer.")
        XCTAssertEqual(notes, [.armed, .disabled(.userInput), .reenabled])
        XCTAssertFalse(microphone.isOpen, "And the near half ran regardless, as it always does.")
    }

    // MARK: - The split changes when, and nothing else

    /// **Equivalence.** With the deferral collapsed to an immediate call, the observer's observable
    /// effect is exactly ``TapHealthPolicy/tapWasDisabled(_:)``'s.
    ///
    /// That is the check that the split is a decision about *timing* and not a second policy growing
    /// beside the first. If it ever diverges, there are two answers to "what happens when the tap is
    /// disabled" and only one of them is the one four review rounds went into.
    func testWithAnImmediateDeferralTheOutcomeIsTheSameAsCallingThePolicyDirectly() {
        for reason in TapDisableReason.allCases {
            let throughTheObserver = DisablementHarness()
            throughTheObserver.armAndStartASessionThenLoseTheTap()
            throughTheObserver.observer = CallbackSafeTapDisablement(
                policy: throughTheObserver.policy
            ) { work in
                work()
            }
            throughTheObserver.theCallbackReportsADisablement(reason)

            let directly = DisablementHarness()
            directly.armAndStartASessionThenLoseTheTap()
            _ = directly.policy.tapWasDisabled(reason)

            XCTAssertEqual(
                throughTheObserver.notes, directly.notes,
                "\(reason): the two paths disagree about what happened.")
            XCTAssertEqual(
                throughTheObserver.effects.endReasons, directly.effects.endReasons,
                "\(reason): the two paths disagree about how the session ended.")
            XCTAssertEqual(
                throughTheObserver.microphone.isOpen, directly.microphone.isOpen,
                "\(reason): the two paths disagree about the microphone.")
            XCTAssertEqual(
                throughTheObserver.tap.isDelivering, directly.tap.isDelivering,
                "\(reason): the two paths disagree about the tap.")
        }
    }

    /// **The second ending is not a defect, and it is load-bearing.**
    ///
    /// The near half ends the session and the deferred ``TapHealthPolicy/tapWasDisabled(_:)`` ends
    /// it again — unconditionally, as every entry point in that class does. It must stay that way:
    /// the deferred half runs a turn later, and the class's whole argument is that a guard justified
    /// by a claim about what cannot be in flight is the shape this file has been bitten by four
    /// times. What it costs when nothing is in flight is one switch through an idle machine.
    func testTheSecondEndingCostsNothingWhenThereIsNoSessionLeft() {
        let harness = DisablementHarness()
        harness.armAndStartASessionThenLoseTheTap()

        harness.theCallbackReportsADisablement(.timeout)
        harness.runLoop.drain()

        XCTAssertEqual(
            harness.microphone.endCount, 1,
            "The microphone was closed twice — the second ending must be a no-op, not a second end.")
        XCTAssertEqual(
            harness.effects.endReasons, [.tapDisabled], "Two outcomes were produced for one session.")
        XCTAssertEqual(
            harness.microphone.closesWithoutOpen, 0,
            "A close with no open reached the audio source.")
    }

    /// A disablement with no session in flight — the ordinary case, since a tap is far more likely to
    /// be switched off while the user is not talking. Nothing to end, and the recovery still happens.
    func testADisablementWithNoSessionRecoversAndEndsNothing() {
        let harness = DisablementHarness()
        XCTAssertEqual(harness.policy.arm(), .delivering)
        harness.tap.systemDisablesTheTap()

        harness.theCallbackReportsADisablement(.userInput)
        harness.runLoop.drain()

        XCTAssertEqual(harness.microphone.beginCount, 0, "No session was ever started.")
        XCTAssertEqual(harness.effects.endReasons, [], "An outcome was produced for no session.")
        XCTAssertTrue(harness.tap.isDelivering, "The tap was not recovered.")
        XCTAssertEqual(harness.notes, [.armed, .disabled(.userInput), .reenabled])
    }

    /// The near half, called on its own, is exactly what it says: it closes the microphone and does
    /// nothing about the tap.
    ///
    /// Asserted directly against ``TapHealthPolicy/endAnyInFlightSessionWithoutRecovering()`` rather
    /// than only through the observer, because it is now public API and its contract is the reason
    /// the split can exist without the ending being reconstructed somewhere else.
    func testTheNearHalfClosesTheMicrophoneAndTouchesNothingElse() {
        let harness = DisablementHarness()
        harness.armAndStartASessionThenLoseTheTap()
        let startsBefore = harness.tap.startCount

        harness.policy.endAnyInFlightSessionWithoutRecovering()

        XCTAssertFalse(harness.microphone.isOpen)
        XCTAssertEqual(harness.effects.endReasons, [.tapDisabled])
        XCTAssertEqual(harness.tap.resumeCount, 0, "It must not re-enable.")
        XCTAssertEqual(harness.tap.startCount, startsBefore, "It must not re-create.")
        XCTAssertEqual(harness.notes, [.armed], "It must say nothing about the tap's health.")
        XCTAssertFalse(harness.tap.isDelivering, "The tap is left exactly as it was found: dead.")
    }
}
