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

/// Space, as in ⌥Space — the shipped default's shape.
private let space: UInt16 = 49
/// `A`. Key code **0**, which is also the key code the policy stamps on its synthetic end — the
/// collision is deliberate, and `testTheSyntheticEndIsATapDeathAndNotAKeyUp` is what makes it safe.
private let letterA: UInt16 = 0

private let chord = HotkeyConfiguration(
    keyCode: space, modifiers: [.option], activation: .holdToTalk)

/// The same binding on key code 0 — the value the synthetic end carries. If any rule ever read that
/// field, this configuration is the one it would read it wrongly for.
private let chordOnKeyCodeZero = HotkeyConfiguration(
    keyCode: letterA, modifiers: [.option], activation: .holdToTalk)

private func event(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet,
    autorepeat: Bool = false
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: autorepeat,
        // Deliberately constant, as in every other session suite: the machine reads its injected
        // clock and never an event's timestamp. The synthetic end is the one event in this file
        // whose timestamp is asserted, and it is minted by the policy rather than built here.
        timestamp: .zero)
}

/// The health channel, as a ledger.
///
/// Separate from ``EffectLog`` because they are separate doors and the whole design turns on that:
/// what the session did leaves through the sink's effect handler, and what happened to the tap
/// leaves through here. A test that read the diagnosis and called it evidence of the session ending
/// would be reading the policy's own account of itself.
private final class NoteLog {
    private(set) var notes: [TapHealthNote] = []

    func record(_ note: TapHealthNote) { notes.append(note) }
}

/// The whole pipeline with the policy in it:
/// **policy → source → observing sink → session sink → watchdog → machine → microphone.**
///
/// Everything below the fake tap is the shipped code. The two substitutions are the system call
/// itself — which is the substitution this aspect's seam exists to make possible — and an
/// ``ObservingSink`` interposed so the event the policy *synthesises* is visible, since that one
/// never travels through the source.
private final class PolicyHarness {
    let clock = TestClock()
    let microphone = RecordingSource()
    let keyboard = Keyboard()
    let effects = EffectLog()
    let health = NoteLog()
    let tap = FakeHotkeyEventSource()
    let keyState: TruthfulKeyState
    let machine: SessionMachine<RecordingSource.Buffer>
    let watchdog: SessionWatchdog<RecordingSource.Buffer>
    let sink: ObservingSink
    let policy: TapHealthPolicy
    let configuration: HotkeyConfiguration

    init(configuration: HotkeyConfiguration = chord) {
        self.configuration = configuration
        let keyState = TruthfulKeyState(keyboard)
        self.keyState = keyState
        self.machine = SessionMachine(
            configuration: configuration, ceiling: SessionCeiling.default, clock: clock,
            audioSource: microphone)
        self.watchdog = SessionWatchdog(machine: machine, keyState: keyState)
        let session = SessionEventSink(watchdog: watchdog) { [effects] effect in
            effects.record(effect)
        }
        let sink = ObservingSink(forwardingTo: session)
        self.sink = sink
        self.policy = TapHealthPolicy(source: tap, sink: sink, clock: clock) { [health] note in
            health.record(note)
        }
    }

    // MARK: The gestures, all of them through the seam

    @discardableResult
    func press() -> EventPropagation {
        keyboard.press(configuration.keyCode)
        return tap.deliver(event(.keyDown, configuration.keyCode, configuration.modifiers))
    }

    @discardableResult
    func release() -> EventPropagation {
        keyboard.release(configuration.keyCode)
        return tap.deliver(event(.keyUp, configuration.keyCode, configuration.modifiers))
    }

    @discardableResult
    func feed(_ event: RawKeyEvent) -> EventPropagation {
        tap.deliver(event)
    }

    var notes: [TapHealthNote] { health.notes }

    /// The events the policy minted itself: everything that reached the sink without having reached
    /// the source first.
    var syntheticEvents: [RawKeyEvent] {
        sink.received.filter { !tap.deliveredEvents.contains($0) }
    }
}

// MARK: - The entry points, as a closed set

/// Every way the outside world tells the policy something.
///
/// A `CaseIterable` rather than six repeated test bodies, because the rule under test — *every one
/// of them ends an in-flight session* — is a claim about the **set**, and a claim about a set that
/// is written out one member at a time is a claim that quietly stops covering the member somebody
/// adds next.
///
/// It cannot make a new public method a compile error; nothing can. What it does is make the set an
/// object with a count, so the count can be asserted and the omission argued about in review rather
/// than never noticed.
private enum PolicyEntryPoint: CaseIterable {
    case arm
    case disabledByTimeout
    case disabledByUserInput
    case systemDidWake
    case accessibilityGrantChanged
    case disarm

    /// A name per case, so the count below cannot be satisfied by a set that collapsed two of them —
    /// the defect that has now bitten this aspect twice, once as a superset bit constant and once as
    /// an array literal with a duplicate key code in it.
    var name: String {
        switch self {
        case .arm: return "arm"
        case .disabledByTimeout: return "tapWasDisabled(.timeout)"
        case .disabledByUserInput: return "tapWasDisabled(.userInput)"
        case .systemDidWake: return "systemDidWake"
        case .accessibilityGrantChanged: return "accessibilityGrantChanged"
        case .disarm: return "disarm"
        }
    }

    func invoke(on policy: TapHealthPolicy) {
        switch self {
        case .arm: _ = policy.arm()
        case .disabledByTimeout: _ = policy.tapWasDisabled(.timeout)
        case .disabledByUserInput: _ = policy.tapWasDisabled(.userInput)
        case .systemDidWake: _ = policy.systemDidWake()
        case .accessibilityGrantChanged: _ = policy.accessibilityGrantChanged()
        case .disarm: policy.disarm()
        }
    }
}

/// Every route back from a dead tap to a live one. Each is exercised end to end by
/// `testEveryRecoveryRouteLeavesATapThatCanRunAWholeSessionAgain`.
private enum RecoveryRoute: CaseIterable {
    /// The tap was switched back on in place.
    case reenabled
    /// Switching it back on did not take, so it was re-created — acceptance H4.
    case recreatedAfterAFailedReEnable
    /// It died silently across sleep and was re-created on wake.
    case recreatedOnWake
    /// The Accessibility grant arrived, so the cleared mask was replaced by a new tap.
    case recreatedAfterAGrant

    var name: String {
        switch self {
        case .reenabled: return "reenabled"
        case .recreatedAfterAFailedReEnable: return "recreatedAfterAFailedReEnable"
        case .recreatedOnWake: return "recreatedOnWake"
        case .recreatedAfterAGrant: return "recreatedAfterAGrant"
        }
    }

    /// Puts the harness's tap in the broken state this route recovers from, and recovers it.
    @discardableResult
    func drive(_ harness: PolicyHarness) -> TapHealth {
        switch self {
        case .reenabled:
            harness.tap.systemDisablesTheTap()
            return harness.policy.tapWasDisabled(.timeout)
        case .recreatedAfterAFailedReEnable:
            harness.tap.systemDisablesTheTap()
            harness.tap.nextResume = .failed
            return harness.policy.tapWasDisabled(.userInput)
        case .recreatedOnWake:
            harness.tap.systemDisablesTheTap()
            return harness.policy.systemDidWake()
        case .recreatedAfterAGrant:
            harness.tap.systemDisablesTheTap()
            return harness.policy.accessibilityGrantChanged()
        }
    }
}

// MARK: -

final class TapHealthPolicyTests: XCTestCase {

    // MARK: - The vocabulary

    /// The two disablements are opposite verdicts on whose defect it is, and a caller can tell.
    ///
    /// Both halves matter: the mapping, and that the two answers **differ**. A property hard-coded to
    /// either constant satisfies one assertion apiece and is caught only by the third.
    func testTheTwoDisableReasonsAreOppositeVerdictsOnWhoseDefectItIs() {
        XCTAssertEqual(TapDisableReason.allCases.count, 2)
        XCTAssertEqual(Set(TapDisableReason.allCases).count, 2, "two cases, not one written twice")

        XCTAssertTrue(
            TapDisableReason.timeout.isVoccasOwnDefect,
            "kCGEventTapDisabledByTimeout means our own callback was too slow. That is a defect with "
                + "a suspect already named in HotkeyEventSink.receive(_:).")
        XCTAssertFalse(
            TapDisableReason.userInput.isVoccasOwnDefect,
            "kCGEventTapDisabledByUserInput is the system or the user switching taps off. Nothing "
                + "in the callback caused it.")

        XCTAssertEqual(
            Set(TapDisableReason.allCases.map(\.isVoccasOwnDefect)).count, 2,
            "A verdict that answers the same for both reasons has flattened the one distinction "
                + "this type exists to carry.")
    }

    /// Three answers to "where does the tap stand", and no two of them are the same answer.
    ///
    /// The third case is the one under pressure: `.notArmed` is easy to collapse into
    /// `.permissionMissing`, and doing so would send a user who simply turned the hotkey off through
    /// a permission dialog for a grant they already have.
    func testEveryTapHealthCaseIsADistinctAnswer() {
        XCTAssertEqual(TapHealth.allCases.count, 3)
        XCTAssertEqual(Set(TapHealth.allCases).count, 3)
        XCTAssertEqual(
            Set(TapHealth.allCases), [.delivering, .permissionMissing, .notArmed],
            "A case added here needs a decision at every call site that switches on it, which is "
                + "what this assertion exists to force.")
    }

    func testEveryRecreationCauseAndResumeAnswerIsDistinct() {
        XCTAssertEqual(Set(TapRecreationCause.allCases).count, TapRecreationCause.allCases.count)
        XCTAssertEqual(
            Set(TapRecreationCause.allCases),
            [.reenableFailed, .systemDidWake, .accessibilityGrantChanged])

        XCTAssertEqual(Set(TapResume.allCases).count, 2)
        XCTAssertEqual(Set(TapResume.allCases), [.resumed, .failed])
    }

    func testTheEntryPointTableCoversEveryPublicMethodExactlyOnce() {
        XCTAssertEqual(
            PolicyEntryPoint.allCases.count, 6,
            "TapHealthPolicy has six public entry points: arm, tapWasDisabled for each of the two "
                + "reasons, systemDidWake, accessibilityGrantChanged, disarm.")
        XCTAssertEqual(
            Set(PolicyEntryPoint.allCases.map(\.name)).count, PolicyEntryPoint.allCases.count,
            "Two cases naming the same entry point would leave one method covered twice and "
                + "another not at all, while the count still read six.")
    }

    // MARK: - H5: a tap that cannot be created

    /// `CGEvent.tapCreate` returning `nil` **is** the permission check. It leaves as a report.
    func testAFailedTapCreationIsReportedAsPermissionMissing() {
        let harness = PolicyHarness()
        harness.tap.nextStart = .unavailable

        XCTAssertEqual(harness.policy.arm(), .permissionMissing)
        XCTAssertEqual(harness.notes, [.permissionMissing])
        XCTAssertFalse(harness.tap.isAttached, "a tap that was not created is not holding a sink")
        XCTAssertEqual(harness.tap.startCount, 1, "it was attempted exactly once")
    }

    /// The other half of H5, and the half that is easy to lose: it must not be a *silent* no-op
    /// either. A press after a failed arm reaches the application untouched and starts nothing —
    /// which is the safe behaviour, and is asserted rather than assumed.
    func testAFailedTapCreationLeavesTheKeyboardUntouchedRatherThanSilentlyDead() {
        let harness = PolicyHarness()
        harness.tap.nextStart = .unavailable
        XCTAssertEqual(harness.policy.arm(), .permissionMissing)

        harness.press()
        harness.release()

        XCTAssertEqual(harness.effects.starts, 0, "no tap, no session")
        XCTAssertEqual(harness.tap.deliveredEvents.count, 0, "nothing reached Vocca")
        XCTAssertEqual(
            harness.tap.applicationSaw.count, 2,
            "a Vocca that cannot hear the keyboard must not eat it either")
        XCTAssertEqual(harness.tap.eventsArrivingWhileStopped, 2)
        XCTAssertFalse(harness.microphone.isOpen)
    }

    /// The grant arrives thirty seconds later, and the tap has to be **re-created** — the whole
    /// reason `arm()` remembers that it was asked even when it failed.
    func testAnAccessibilityGrantAfterAFailedCreationArmsTheTap() throws {
        let harness = PolicyHarness()
        harness.tap.nextStart = .unavailable
        XCTAssertEqual(harness.policy.arm(), .permissionMissing)

        harness.tap.nextStart = .started
        XCTAssertEqual(harness.policy.accessibilityGrantChanged(), .delivering)
        XCTAssertEqual(
            harness.notes, [.permissionMissing, .recreated(.accessibilityGrantChanged)])

        harness.press()
        harness.release()

        XCTAssertEqual(harness.effects.starts, 1)
        XCTAssertEqual(harness.effects.endReasons, [.keyUp])
        XCTAssertFalse(harness.microphone.isOpen)
    }

    // MARK: - H3: a disabled tap ends the session and is switched back on

    func testATapDisabledByTimeoutEndsTheSessionAndReEnablesTheTap() throws {
        try assertADisabledTapEndsTheSessionAndRecovers(.timeout)
    }

    func testATapDisabledByUserInputEndsTheSessionAndReEnablesTheTap() throws {
        try assertADisabledTapEndsTheSessionAndRecovers(.userInput)
    }

    private func assertADisabledTapEndsTheSessionAndRecovers(
        _ reason: TapDisableReason, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let harness = PolicyHarness()
        XCTAssertEqual(harness.policy.arm(), .delivering, file: file, line: line)
        harness.press()
        XCTAssertTrue(harness.microphone.isOpen, "precondition", file: file, line: line)

        harness.tap.systemDisablesTheTap()
        XCTAssertEqual(harness.policy.tapWasDisabled(reason), .delivering, file: file, line: line)

        // The session, ended, with its audio — read off the microphone's ledger and the effect log,
        // never off the policy's own account of itself.
        XCTAssertFalse(harness.microphone.isOpen, "a hot mic", file: file, line: line)
        XCTAssertEqual(harness.machine.state, .idle, file: file, line: line)
        XCTAssertEqual(
            harness.effects.endReasons, [.tapDisabled],
            "the key-up is never coming, and .tapDisabled is why", file: file, line: line)
        XCTAssertEqual(harness.microphone.handedOut.count, 1, "audio kept", file: file, line: line)

        // And the tap, alive again — in place, without a new one being created.
        XCTAssertEqual(harness.tap.resumeCount, 1, file: file, line: line)
        XCTAssertEqual(
            harness.tap.startCount, 1,
            "a re-enable that took needs no re-creation", file: file, line: line)
        XCTAssertTrue(harness.tap.isDelivering, file: file, line: line)
        XCTAssertEqual(
            harness.notes, [.armed, .disabled(reason), .reenabled], file: file, line: line)
    }

    /// The two reasons recover identically and diagnose completely differently. **That is the whole
    /// argument for the separate channel**, so it is measured: same return value, different note.
    func testTheTwoDisableReasonsAreReportedDistinctlyThoughRecoveredIdentically() {
        let afterTimeout = PolicyHarness()
        XCTAssertEqual(afterTimeout.policy.arm(), .delivering)
        afterTimeout.tap.systemDisablesTheTap()
        let timeoutHealth = afterTimeout.policy.tapWasDisabled(.timeout)

        let afterUserInput = PolicyHarness()
        XCTAssertEqual(afterUserInput.policy.arm(), .delivering)
        afterUserInput.tap.systemDisablesTheTap()
        let userInputHealth = afterUserInput.policy.tapWasDisabled(.userInput)

        XCTAssertEqual(timeoutHealth, userInputHealth, "the recovery is the same")
        XCTAssertEqual(afterTimeout.tap.resumeCount, afterUserInput.tap.resumeCount)

        XCTAssertNotEqual(
            afterTimeout.notes, afterUserInput.notes,
            "and the diagnosis is not. One of these is our own callback being too slow and the "
                + "other is not; a log that reads the same for both costs a debugging session.")
        XCTAssertEqual(afterTimeout.notes, [.armed, .disabled(.timeout), .reenabled])
        XCTAssertEqual(afterUserInput.notes, [.armed, .disabled(.userInput), .reenabled])
    }

    // MARK: - H4: when switching it back on does not take

    func testAReEnableThatDoesNotTakeIsFollowedByAReCreation() throws {
        let harness = PolicyHarness()
        XCTAssertEqual(harness.policy.arm(), .delivering)
        harness.press()

        harness.tap.systemDisablesTheTap()
        harness.tap.nextResume = .failed
        XCTAssertEqual(harness.policy.tapWasDisabled(.timeout), .delivering)

        XCTAssertEqual(harness.tap.resumeCount, 1, "the cheap recovery is tried first")
        XCTAssertEqual(harness.tap.startCount, 2, "and when it fails, a new tap is created")
        XCTAssertEqual(harness.tap.stopCount, 1, "the old one is torn down rather than leaked")
        XCTAssertTrue(harness.tap.isDelivering)
        XCTAssertEqual(harness.notes, [.armed, .disabled(.timeout), .recreated(.reenableFailed)])

        XCTAssertEqual(harness.effects.endReasons, [.tapDisabled])
        XCTAssertFalse(harness.microphone.isOpen)
    }

    /// **The ordering test.** Both recoveries fail, so anything that ended the session *after* them
    /// — or gated ending on them succeeding — leaves the microphone open.
    func testWhenBothTheReEnableAndTheReCreationFailTheSessionHasStillEnded() throws {
        let harness = PolicyHarness()
        XCTAssertEqual(harness.policy.arm(), .delivering)
        harness.press()
        XCTAssertTrue(harness.microphone.isOpen, "precondition")

        harness.tap.systemDisablesTheTap()
        harness.tap.nextResume = .failed
        harness.tap.nextStart = .unavailable
        XCTAssertEqual(harness.policy.tapWasDisabled(.userInput), .permissionMissing)

        XCTAssertFalse(
            harness.microphone.isOpen,
            "the session must end before anything that can fail, not after it")
        XCTAssertEqual(harness.effects.endReasons, [.tapDisabled])
        XCTAssertEqual(harness.machine.state, .idle)
        XCTAssertEqual(harness.microphone.handedOut.count, 1, "and its audio survives")

        XCTAssertFalse(harness.tap.isAttached, "deaf rather than double-tapped")
        XCTAssertEqual(
            harness.notes, [.armed, .disabled(.userInput), .recreationFailed(.reenableFailed)])
    }

    // MARK: - The rule the class is arranged around

    /// **Every entry point ends an in-flight session.** Not the re-creating ones; every one.
    ///
    /// Driven over the closed set above, one fresh harness per member, and asserted against the
    /// microphone's ledger and the effect log rather than against anything the policy says.
    func testEveryEntryPointEndsAnInFlightSession() {
        for entryPoint in PolicyEntryPoint.allCases {
            let harness = PolicyHarness()
            XCTAssertEqual(harness.policy.arm(), .delivering, entryPoint.name)
            harness.press()
            XCTAssertTrue(harness.microphone.isOpen, "precondition for \(entryPoint.name)")
            harness.tap.systemDisablesTheTap()

            entryPoint.invoke(on: harness.policy)

            XCTAssertFalse(
                harness.microphone.isOpen,
                """
                \(entryPoint.name) left the microphone open. A tap that died may have dropped the \
                key-up, so a session that survives one is a hot mic with the widget insisting it is \
                closed.
                """)
            XCTAssertEqual(harness.machine.state, .idle, entryPoint.name)
            XCTAssertEqual(
                harness.effects.endReasons, [.tapDisabled],
                "\(entryPoint.name) ended the session for the wrong reason, or ended it twice")
            XCTAssertEqual(
                harness.microphone.handedOut.count, 1,
                "\(entryPoint.name) must not lose the audio it captured")
            XCTAssertEqual(
                harness.syntheticEvents.count, 2,
                """
                \(entryPoint.name): two entry points were called — the arming and this one — and \
                each must have minted exactly one end. A count of one here is an entry point that \
                reached its recovery without ending anything; a count above two is an end applied \
                more than once for a single event.
                """)
        }
    }

    /// The synthetic end is a **tap death**, not a key-up and not a modifier release.
    ///
    /// Run against two bindings, one of them on key code 0 — the value the synthetic event carries.
    /// A policy that minted a `.keyUp` instead would still end both sessions, and would file both of
    /// them under a reason that never happened; on key code 0 it would file `.keyUp` and on `Space`
    /// it would file `.modifierReleased`, which is how a wrong reason hides behind a right outcome.
    func testTheSyntheticEndIsATapDeathAndNotAKeyUp() {
        for configuration in [chord, chordOnKeyCodeZero] {
            let harness = PolicyHarness(configuration: configuration)
            XCTAssertEqual(harness.policy.arm(), .delivering)
            harness.press()
            harness.tap.systemDisablesTheTap()
            _ = harness.policy.tapWasDisabled(.timeout)

            XCTAssertEqual(
                harness.effects.endReasons, [.tapDisabled],
                """
                key code \(configuration.keyCode): the session ended under the wrong name. The log \
                is the only evidence anyone gets of a session that ended surprisingly.
                """)
        }
    }

    /// The exact events the policy mints, pinned in full — kind, key code, modifiers, autorepeat and
    /// the reading of the injected clock at the moment each was minted.
    ///
    /// **There are two of them, and that is the invariant rather than a leak.** `arm()` ends an
    /// in-flight session like every other entry point does, unconditionally and before any guard, so
    /// arming mints one at `t = 0` even though there was nothing to end. What it costs is one
    /// `.ignore` through rules that answer `.ignore` for a `.tapDisabled` event while idle in both
    /// activation modes. What it buys is that there is no guard, no ordering and no early return
    /// anywhere in this class that a mutation could make the ending skip.
    func testEverySyntheticEndCarriesTheClockReadingAndNothingInvented() {
        let harness = PolicyHarness()
        XCTAssertEqual(harness.policy.arm(), .delivering)
        harness.press()
        harness.clock.now = .seconds(5)

        harness.tap.systemDisablesTheTap()
        _ = harness.policy.tapWasDisabled(.timeout)

        XCTAssertEqual(
            harness.syntheticEvents,
            [
                RawKeyEvent(
                    kind: .tapDisabled, keyCode: 0, modifiers: [], isAutorepeat: false,
                    timestamp: .zero),
                RawKeyEvent(
                    kind: .tapDisabled, keyCode: 0, modifiers: [], isAutorepeat: false,
                    timestamp: .seconds(5)),
            ],
            """
            One synthetic event per entry point, of the kind the rules check before any other, each \
            stamped with the time it happened. RawKeyEvent.timestamp is documented as the caller's \
            to supply because VoccaCore reads no clock; this is the caller, and a hard-coded .zero \
            would be the first false timestamp in the system.
            """)
    }

    /// The synthetic end is not a keystroke, so nothing downstream of the tap may see it.
    func testTheSyntheticEndNeverReachesTheFocusedApplication() {
        let harness = PolicyHarness()
        XCTAssertEqual(harness.policy.arm(), .delivering)
        harness.press()
        harness.tap.systemDisablesTheTap()
        _ = harness.policy.tapWasDisabled(.timeout)

        XCTAssertEqual(
            harness.tap.deliveredEvents.filter { $0.kind == .tapDisabled }, [],
            "the policy's own event must not be pushed back through the source")
        XCTAssertEqual(
            harness.tap.applicationSaw.filter { $0.kind == .tapDisabled }, [],
            "and the focused application must never see an event that had no key behind it")
        XCTAssertEqual(
            harness.syntheticEvents.count, 2,
            "one per entry point — the arming and the tap death — and both reached the sink")
    }

    // MARK: - Sleep, wake, and the grant

    func testAWakeReCreatesTheTapRatherThanTryingToReEnableIt() {
        let harness = PolicyHarness()
        XCTAssertEqual(harness.policy.arm(), .delivering)

        XCTAssertEqual(harness.policy.systemDidWake(), .delivering)

        XCTAssertEqual(
            harness.tap.resumeCount, 0,
            """
            A tap that died across sleep/wake did so silently: there is no disable event and no \
            reason to believe CGEventTapEnable has anything left to enable.
            """)
        XCTAssertEqual(harness.tap.startCount, 2)
        XCTAssertEqual(harness.tap.stopCount, 1)
        XCTAssertEqual(harness.notes, [.armed, .recreated(.systemDidWake)])
    }

    func testAnAccessibilityGrantChangeReCreatesRatherThanTryingToReEnable() {
        let harness = PolicyHarness()
        XCTAssertEqual(harness.policy.arm(), .delivering)

        XCTAssertEqual(harness.policy.accessibilityGrantChanged(), .delivering)

        XCTAssertEqual(
            harness.tap.resumeCount, 0,
            """
            CGEventTapEnable cannot resurrect a tap whose mask was cleared at creation, which is \
            precisely the tap that exists before a grant. Only re-creation works.
            """)
        XCTAssertEqual(harness.tap.startCount, 2)
        XCTAssertEqual(harness.notes, [.armed, .recreated(.accessibilityGrantChanged)])
    }

    /// A revoked grant is the same notification as a granted one, and the honest answer is the one
    /// the re-creation gives.
    func testAGrantChangeThatRevokesPermissionIsReportedAsPermissionMissing() {
        let harness = PolicyHarness()
        XCTAssertEqual(harness.policy.arm(), .delivering)

        harness.tap.nextStart = .unavailable
        XCTAssertEqual(harness.policy.accessibilityGrantChanged(), .permissionMissing)

        XCTAssertFalse(harness.tap.isAttached)
        XCTAssertEqual(
            harness.notes, [.armed, .recreationFailed(.accessibilityGrantChanged)])
    }

    /// Nothing is done to a tap the owner has not asked for. A wake must not silently arm a hotkey
    /// the user turned off.
    func testNothingIsDoneToATapTheOwnerHasNotAskedFor() {
        let neverArmed = PolicyHarness()
        XCTAssertEqual(neverArmed.policy.systemDidWake(), .notArmed)
        XCTAssertEqual(neverArmed.policy.accessibilityGrantChanged(), .notArmed)
        XCTAssertEqual(neverArmed.policy.tapWasDisabled(.timeout), .notArmed)
        XCTAssertEqual(neverArmed.tap.startCount, 0)
        XCTAssertEqual(neverArmed.tap.resumeCount, 0)

        let disarmed = PolicyHarness()
        XCTAssertEqual(disarmed.policy.arm(), .delivering)
        disarmed.policy.disarm()
        XCTAssertEqual(disarmed.policy.systemDidWake(), .notArmed)
        XCTAssertEqual(disarmed.policy.accessibilityGrantChanged(), .notArmed)
        XCTAssertEqual(
            disarmed.tap.startCount, 1, "one arm, and nothing re-armed it behind the owner's back")
    }

    func testDisarmStopsTheSourceAndEndsAnyInFlightSession() {
        let harness = PolicyHarness()
        XCTAssertEqual(harness.policy.arm(), .delivering)
        harness.press()
        XCTAssertTrue(harness.microphone.isOpen, "precondition")

        harness.policy.disarm()

        XCTAssertFalse(
            harness.microphone.isOpen,
            """
            HotkeyEventSource.stop() deliberately does not end anything — the doc comment says the \
            answer belongs to the owner, above the seam. This is the owner.
            """)
        XCTAssertEqual(harness.effects.endReasons, [.tapDisabled])
        XCTAssertFalse(harness.tap.isAttached)
        XCTAssertEqual(harness.tap.stopCount, 1)
        XCTAssertEqual(harness.notes, [.armed, .disarmed])
    }

    // MARK: - The recovery has to be worth having

    /// Every route back from a dead tap ends with a tap that runs a whole session again.
    ///
    /// The mutation this exists for: a policy that reports a clean recovery having left the sink
    /// detached passes every count assertion in this file and hears nothing ever again.
    func testEveryRecoveryRouteLeavesATapThatCanRunAWholeSessionAgain() {
        XCTAssertEqual(
            Set(RecoveryRoute.allCases.map(\.name)).count, RecoveryRoute.allCases.count,
            "four distinct routes, not one written four times")

        for route in RecoveryRoute.allCases {
            let harness = PolicyHarness()
            XCTAssertEqual(harness.policy.arm(), .delivering, route.name)

            XCTAssertEqual(route.drive(harness), .delivering, route.name)

            harness.press()
            harness.release()

            XCTAssertEqual(
                harness.effects.starts, 1,
                "\(route.name): the tap reported healthy and delivered nothing")
            XCTAssertEqual(
                harness.effects.endReasons, [.keyUp],
                "\(route.name): a whole session, ended by the user's own gesture")
            XCTAssertFalse(harness.microphone.isOpen, route.name)
            XCTAssertEqual(
                harness.tap.keysTheApplicationBelievesAreDown, [],
                "\(route.name): and the hotkey was still swallowed in both directions")
        }
    }

    /// The hazard itself, demonstrated rather than described: **a disabled tap delivers nothing, so
    /// nothing the keyboard does can end the session.** This is why the policy has to.
    func testADisabledTapEatsNoKeystrokesAndCanEndNoSession() {
        let harness = PolicyHarness()
        XCTAssertEqual(harness.policy.arm(), .delivering)
        harness.press()

        harness.tap.systemDisablesTheTap()
        harness.release()
        harness.feed(event(.keyDown, letterA, []))

        XCTAssertEqual(harness.tap.eventsArrivingWhileDisabled, 2)
        XCTAssertEqual(
            harness.tap.applicationSaw.count, 2,
            "a switched-off tap swallows nothing — the user's keyboard is their own again")
        XCTAssertTrue(
            harness.microphone.isOpen,
            """
            The key-up happened and Vocca never saw it. This is the hot mic the policy exists to \
            close, and it is measured here rather than asserted so that the closing below means \
            something. The physical-key poll is the *other* backstop and would also catch this — \
            but only in hold-to-talk, only if the owner's timer is still firing, and only after up \
            to one poll interval. The policy's end depends on none of the three.
            """)

        XCTAssertEqual(harness.policy.tapWasDisabled(.timeout), .delivering)
        XCTAssertFalse(harness.microphone.isOpen)
        XCTAssertEqual(harness.effects.endReasons, [.tapDisabled])
    }

    /// **The ordering, measured rather than argued.**
    ///
    /// The session is ended *before* the recovery, and the difference only shows when something
    /// arrives during the recovery — which is not a contrived case: switching a tap back on and
    /// creating one both run through CoreFoundation, CoreFoundation pumps the run loop, and the event
    /// queued behind the disablement is delivered right there. `RecordingSource` models the identical
    /// hazard on the audio seam for the identical reason.
    ///
    /// What ending first buys is that the stale key-up arrives at a session that is already over, and
    /// is ignored. Ending afterwards lets an event that came through a tap Vocca has just declared
    /// untrustworthy end the session under the user's own name — a `.keyUp` in the log for a release
    /// nobody made at a time nobody chose, and the log is the only evidence anyone gets.
    func testAKeyEventArrivingDuringTheRecoveryCannotEndASessionTheTapDeathAlreadyEnded() {
        for route in [RecoveryRoute.reenabled, .recreatedAfterAFailedReEnable] {
            let harness = PolicyHarness()
            XCTAssertEqual(harness.policy.arm(), .delivering, route.name)
            harness.press()

            // The key-up that was queued behind the disablement, delivered from inside whichever
            // call this route recovers through.
            harness.tap.duringResume = { [weak harness] in harness?.release() }
            harness.tap.duringStart = { [weak harness] in harness?.release() }

            XCTAssertEqual(route.drive(harness), .delivering, route.name)

            XCTAssertEqual(
                harness.effects.endReasons, [.tapDisabled],
                """
                \(route.name): the session was ended by a key event that arrived during the \
                recovery, which means it had not been ended before the recovery began.
                """)
            XCTAssertFalse(harness.microphone.isOpen, route.name)
            XCTAssertEqual(
                harness.microphone.handedOut.count, 1,
                "\(route.name): exactly one session, ended exactly once")
        }
    }

    // MARK: - The adversarial drive

    /// **No sequence of tap deaths leaves a session running.**
    ///
    /// Two hundred rounds of: arm if needed, press, some noise, then a randomly chosen health event.
    /// After every health event the microphone must be shut and the machine idle. Seeded, so a
    /// failure is replayable.
    func testNoSequenceOfTapDeathsLeavesASessionRunning() {
        var generator = SeededGenerator(seed: 0x5EED_7A97)
        let harness = PolicyHarness()
        var healthEventsDriven = 0

        for round in 0..<200 {
            if !harness.tap.isDelivering {
                XCTAssertEqual(harness.policy.arm(), .delivering, "round \(round)")
            }

            harness.press()
            if Bool.random(using: &generator) {
                harness.feed(
                    event(.keyDown, harness.configuration.keyCode, [.option], autorepeat: true))
            }
            if Bool.random(using: &generator) {
                harness.feed(event(.keyDown, letterA, [.option]))
            }
            if Bool.random(using: &generator) {
                harness.tap.systemDisablesTheTap()
            }

            guard let entryPoint = PolicyEntryPoint.allCases.randomElement(using: &generator) else {
                return XCTFail("the entry-point table is empty")
            }
            entryPoint.invoke(on: harness.policy)
            healthEventsDriven += 1

            XCTAssertFalse(
                harness.microphone.isOpen,
                "round \(round): \(entryPoint.name) left the microphone open")
            XCTAssertEqual(
                harness.machine.state, .idle, "round \(round): \(entryPoint.name)")

            harness.keyboard.release(harness.configuration.keyCode)
        }

        XCTAssertEqual(healthEventsDriven, 200)
        XCTAssertGreaterThan(
            harness.microphone.beginCount, 100,
            "a drive in which few sessions ever started would prove nothing about ending them")
        XCTAssertEqual(
            harness.microphone.beginCount, harness.microphone.endCount,
            "every session that opened the microphone closed it")
        XCTAssertEqual(harness.microphone.overlappingBegins, 0)
        XCTAssertEqual(harness.microphone.closesWithoutOpen, 0)
    }

    // MARK: - The diagnostic channel, end to end

    /// One harness through everything that can happen to a tap, with the exact log asserted.
    ///
    /// The distinctness check is the point: seven things happened and the log has seven different
    /// things to say about them. A channel that reported `.disabled` without its reason, or one note
    /// for both re-creation outcomes, fails here rather than in production at 2 a.m.
    func testTheHealthLogTellsApartEverythingThatCanHappenToTheTap() {
        let harness = PolicyHarness()

        harness.tap.nextStart = .unavailable
        XCTAssertEqual(harness.policy.arm(), .permissionMissing)

        harness.tap.nextStart = .started
        XCTAssertEqual(harness.policy.accessibilityGrantChanged(), .delivering)

        harness.tap.systemDisablesTheTap()
        XCTAssertEqual(harness.policy.tapWasDisabled(.timeout), .delivering)

        harness.tap.systemDisablesTheTap()
        harness.tap.nextResume = .failed
        XCTAssertEqual(harness.policy.tapWasDisabled(.userInput), .delivering)

        XCTAssertEqual(harness.policy.systemDidWake(), .delivering)

        harness.tap.nextStart = .unavailable
        XCTAssertEqual(harness.policy.systemDidWake(), .permissionMissing)

        harness.policy.disarm()

        let expected: [TapHealthNote] = [
            .permissionMissing,
            .recreated(.accessibilityGrantChanged),
            .disabled(.timeout),
            .reenabled,
            .disabled(.userInput),
            .recreated(.reenableFailed),
            .recreated(.systemDidWake),
            .recreationFailed(.systemDidWake),
            .disarmed,
        ]
        XCTAssertEqual(harness.notes, expected)
        XCTAssertEqual(
            Set(harness.notes).count, expected.count,
            "nine events, nine distinguishable notes — no two of them collapse")
    }

    /// The first arming reports itself, so a health log begins with the tap being created rather
    /// than with the first thing that went wrong.
    func testASuccessfulArmingIsReported() {
        let harness = PolicyHarness()

        XCTAssertEqual(harness.policy.arm(), .delivering)

        XCTAssertEqual(harness.notes, [.armed])
        XCTAssertTrue(harness.tap.isDelivering)
        XCTAssertEqual(harness.tap.startCount, 1)
        XCTAssertEqual(harness.tap.stopCount, 0, "nothing to tear down on a first arming")
    }
}
