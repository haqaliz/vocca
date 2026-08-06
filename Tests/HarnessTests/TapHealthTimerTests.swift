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
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: false, timestamp: .zero)
}

/// **The whole shipped graph, with both clocks injected.**
///
/// `tap → ScheduledWatchdog → SessionEventSink → watchdog → machine → microphone`, with a
/// `TapHealthPolicy` over the tap and a `TapHealthTimer` over the policy. The only substitutions are
/// the two timers and the tap itself — everything between them is what runs in the product.
///
/// It exists as one harness rather than two because the claim worth measuring here spans both: a
/// health poll ends a session by handing the sink a synthetic event, the sink is the
/// `ScheduledWatchdog`, and *that* is what settles the watchdog's timer. Two harnesses could each be
/// green with the join missing.
private final class RuntimeHarness {
    let clock = TestClock()
    let microphone = RecordingSource()
    let keyboard = Keyboard()
    let effects = EffectLog()
    let tap = FakeHotkeyEventSource()
    let secureInput = FakeSecureInputState()
    let watchdogTimer = FakeTimer()
    let healthTimer = FakeTimer()

    /// Present so the pipeline is the shipped one; never fires here, because this harness's machine
    /// uses ``CaptureStartTiming/immediately`` and therefore never has an opening pending.
    let runLoop = DeferralQueue()
    let keyState: TruthfulKeyState
    let machine: SessionMachine<RecordingSource.Buffer>
    let watchdog: SessionWatchdog<RecordingSource.Buffer>
    let scheduled: ScheduledWatchdog<RecordingSource.Buffer>
    let policy: TapHealthPolicy
    let runtime: TapHealthTimer
    let configuration: HotkeyConfiguration

    private(set) var notes: [TapHealthNote] = []
    private(set) var reportedHealth: [TapHealth] = []

    init(configuration: HotkeyConfiguration = chord) {
        self.configuration = configuration
        let keyState = TruthfulKeyState(keyboard)
        self.keyState = keyState
        self.machine = SessionMachine(
            configuration: configuration, ceiling: SessionCeiling.default, clock: clock,
            audioSource: microphone)
        self.watchdog = SessionWatchdog(machine: machine, keyState: keyState)
        let scheduled = ScheduledWatchdog(
            watchdog: watchdog, timer: watchdogTimer, deferOpening: runLoop.schedule
        ) { [effects] effect in
            effects.record(effect)
        }
        self.scheduled = scheduled

        // Two-phase, because the note and health closures need `self` and `self` is not ready yet.
        let noteBox = Box<[TapHealthNote]>([])
        let healthBox = Box<[TapHealth]>([])
        let policy = TapHealthPolicy(
            source: tap, sink: scheduled, clock: clock, secureInput: secureInput
        ) { note in
            noteBox.value.append(note)
        }
        self.policy = policy
        self.runtime = TapHealthTimer(policy: policy, timer: healthTimer) { health in
            healthBox.value.append(health)
        }
        self.noteBox = noteBox
        self.healthBox = healthBox
    }

    private let noteBox: Box<[TapHealthNote]>
    private let healthBox: Box<[TapHealth]>

    var recordedNotes: [TapHealthNote] { noteBox.value }
    var recordedHealth: [TapHealth] { healthBox.value }

    @discardableResult
    func press() -> EventPropagation {
        keyboard.hold(configuration)
        return tap.deliver(event(.keyDown, configuration.keyCode, configuration.modifiers))
    }
}

/// A reference cell, so a closure built before `self` exists can still write somewhere the test can
/// read. Two lines, and the alternative is an implicitly-unwrapped optional whose failure mode is a
/// crash in a constructor.
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

final class TapHealthTimerTests: XCTestCase {

    // MARK: - The poll cannot be left unwired

    /// Arming starts the poll, at the interval `TapHealthPolling` names.
    ///
    /// The whole reason this class exists: `pollTapHealth()` is *the only thing* that catches a tap
    /// which dies with no notification, and it catches nothing until something calls it. An owner who
    /// armed the policy and forgot the clock would get a Vocca that passes every test, works
    /// perfectly, and has no backstop at all — which in toggle mode is a two-minute hot mic, because
    /// `SessionRules.swift:357-359` records that rule (d) is then the only stop a dead tap can
    /// deliver.
    func testArmingStartsThePollAndDisarmingStopsIt() {
        let harness = RuntimeHarness()

        XCTAssertFalse(harness.healthTimer.isRunning, "nothing should poll before Vocca is armed")

        XCTAssertEqual(harness.runtime.arm(), .delivering)
        XCTAssertTrue(
            harness.healthTimer.isRunning,
            """
            Vocca is armed and nothing is polling the tap's health. A tap that dies silently — no \
            disable event, no error — is then invisible for as long as the process runs.
            """)
        XCTAssertEqual(
            harness.healthTimer.interval, TapHealthPolling.interval,
            "the cadence came from somewhere other than TapHealthPolling.")

        harness.runtime.disarm()
        XCTAssertFalse(
            harness.healthTimer.isRunning,
            "a disarmed Vocca has no tap to ask after and should not be asking.")
    }

    /// **`disarm()` closes the microphone and tears the tap down — the half of it that was pinned by
    /// nothing.**
    ///
    /// Measured before this test existed: `disarm()` reduced to `timer.stop()` alone passed the whole
    /// 306-test suite, and so did a `disarm()` that forwarded to `policy.arm()` — a build in which
    /// **disarming Vocca re-creates the tap**. Only the clock half was held, by
    /// `testArmingStartsThePollAndDisarmingStopsIt` above, which never presses a key.
    ///
    /// That is exactly the failure this class was written to make impossible, arrived at from the
    /// other side. `TapHealthPolicyTests` drives all eight of the policy's entry points and asserts
    /// every one ends an in-flight session; then the wrapper that is *the only object an owner holds*
    /// forwarded one of them through code no test executed. A harness is not a substitute for
    /// pressing the key.
    ///
    /// Both modes, because a session that outlives its tap is a hot mic in both — and in toggle there
    /// is no physical-key poll behind it and no key-up can arrive, so the residual would be the whole
    /// 120 s ceiling.
    func testDisarmingClosesTheMicrophoneAndTearsTheTapDown() {
        for configuration in bothActivationModes {
            let harness = RuntimeHarness(configuration: configuration)
            harness.runtime.arm()
            harness.press()
            XCTAssertTrue(
                harness.microphone.isOpen,
                "\(configuration.activation): no session, so the disarm below proves nothing")
            let startsBeforeDisarming = harness.tap.startCount

            harness.runtime.disarm()

            XCTAssertFalse(
                harness.microphone.isOpen,
                """
                \(configuration.activation): Vocca was disarmed with the microphone still open. \
                Nothing can ever close it — the thing that delivered key events is gone, and the \
                poll that would have caught it has been stopped by this same call.
                """)
            XCTAssertEqual(
                harness.effects.endReasons, [.tapDisabled],
                "\(configuration.activation): the session did not end through the custody funnel")
            XCTAssertFalse(
                harness.tap.isAttached,
                """
                \(configuration.activation): the tap is still installed after a disarm. It goes on \
                seeing every keystroke on the machine and swallowing the ones it claims.
                """)
            XCTAssertEqual(
                harness.tap.startCount, startsBeforeDisarming,
                """
                \(configuration.activation): disarming created a tap. This is the mutant that \
                survives when only the clock half of `disarm()` is pinned — a build in which \
                disarming Vocca re-creates the very thing it was asked to tear down.
                """)
            XCTAssertEqual(harness.recordedNotes.last, .disarmed)
        }
    }

    /// **The first run, which is the ordinary one.** No Accessibility grant, so `arm()` reports
    /// `.permissionMissing` — and the poll must start anyway, because it is one of the two things
    /// that turns that into a working hotkey later.
    ///
    /// The other is `accessibilityGrantChanged()`, whose notification `DistributedNotificationCenter`
    /// can drop. A poll started only on success would leave a user who granted permission with a
    /// Vocca that never noticed.
    func testThePollStartsEvenWhenTheTapCouldNotBeCreated() {
        let harness = RuntimeHarness()
        harness.tap.nextStart = .unavailable

        XCTAssertEqual(harness.runtime.arm(), .permissionMissing)
        XCTAssertTrue(
            harness.healthTimer.isRunning,
            """
            Arming failed on permission and no poll was started. That is the state every first run \
            is in, and the poll is what recovers it when the grant notification is dropped.
            """)

        // The grant arrives, and the poll is what finds it — with the retry gate satisfied, since a
        // policy that has never polled has never attempted a recovery.
        harness.tap.nextStart = .started
        harness.healthTimer.tick()
        XCTAssertEqual(harness.recordedHealth, [.delivering])
    }

    // MARK: - What each turn does

    /// Every turn reports, including the ~sixty a minute that find nothing wrong.
    ///
    /// Deliberate: a channel that only spoke up on failure could not show that a tap has been
    /// re-created eleven times in a minute, which is the shape of defect this reporting exists to
    /// make visible. An owner that wants only the changes compares against the last answer it saw.
    func testEveryTurnReportsWhereTheTapStands() {
        let harness = RuntimeHarness()
        harness.runtime.arm()

        harness.healthTimer.tick(5)
        XCTAssertEqual(
            harness.recordedHealth, Array(repeating: .delivering, count: 5),
            "a poll that finds nothing wrong still has to say so, or a stalled poll is invisible.")
    }

    /// **Secure Input reaches the owner through the clock, and the clock keeps running.**
    ///
    /// The policy's answer is only useful if something asks for it once a second without being told
    /// to, which is this class's whole reason for existing. The two halves asserted together are the
    /// ones that would fail separately: the widget is handed `.blockedBySecureInput` on every turn
    /// while a password field is focused — so it can say *the hotkey is blocked* rather than showing
    /// nothing — and the poll is still running afterwards to notice that the field was closed.
    ///
    /// The session half matters more than the report: in toggle there is no key-up rule and no
    /// physical-key poll, so the second press that would have stopped this session is an event the
    /// tap can never receive.
    func testABlockedTapIsReportedOnEveryTurnAndTheSessionIsClosed() {
        for configuration in bothActivationModes {
            let harness = RuntimeHarness(configuration: configuration)
            harness.runtime.arm()
            harness.press()
            XCTAssertTrue(harness.microphone.isOpen, "\(configuration.activation): no session")

            harness.secureInput.isActive = true
            harness.healthTimer.tick(3)

            XCTAssertEqual(
                harness.recordedHealth,
                [.blockedBySecureInput, .blockedBySecureInput, .blockedBySecureInput],
                """
                \(configuration.activation): an owner is told where the tap stands on every turn, \
                and "another application is holding the keyboard" is a different answer from both \
                "delivering" and "not delivering". Reported as the first it is a widget saying \
                ready while nothing works; as the second it is a healthy tap rebuilt once per rate \
                limit for as long as the password field is open.
                """)
            XCTAssertFalse(
                harness.microphone.isOpen,
                "\(configuration.activation): no key event can reach this session to end it")
            XCTAssertEqual(harness.effects.endReasons, [.tapDisabled])
            XCTAssertEqual(harness.tap.startCount, 1, "and the tap itself was left alone")

            harness.secureInput.isActive = false
            harness.healthTimer.tick()
            XCTAssertEqual(
                harness.recordedHealth.last, .delivering,
                "the clock was still running, which is how the block is noticed to have passed")
        }
    }

    /// **The join this harness exists for.** A poll finds the tap silently dead, ends the session by
    /// minting a `.tapDisabled` through the sink — and *that* stops the watchdog's timer, because the
    /// sink is a `ScheduledWatchdog`.
    ///
    /// Neither object knows the other exists. If they were wired any other way — the policy holding a
    /// bare `SessionEventSink`, say — every assertion below except the last would still pass and a
    /// 150 ms timer would run over an idle machine for the rest of the process's life.
    func testAPollThatFindsADeadTapClosesTheMicrophoneAndBothClocksSettle() {
        for configuration in bothActivationModes {
            let harness = RuntimeHarness(configuration: configuration)
            harness.runtime.arm()
            harness.press()
            XCTAssertTrue(harness.microphone.isOpen, "\(configuration.activation): no session")
            XCTAssertTrue(harness.watchdogTimer.isRunning)

            // The tap dies with nobody told: no disable event, no error. The only route left is the
            // poll asking.
            harness.tap.systemDisablesTheTap()
            harness.healthTimer.tick()

            XCTAssertFalse(
                harness.microphone.isOpen,
                """
                \(configuration.activation): the tap is dead and the microphone is open. In toggle \
                there is no physical-key poll behind this and no key-up can arrive, so what is left \
                is the 120 s ceiling.
                """)
            XCTAssertEqual(harness.effects.endReasons, [.tapDisabled])
            XCTAssertFalse(
                harness.watchdogTimer.isRunning,
                """
                \(configuration.activation): the poll ended the session and the watchdog's timer \
                kept running. The two clocks are settled by different objects that have never heard \
                of each other — the sink is the only thing joining them.
                """)
            XCTAssertTrue(
                harness.healthTimer.isRunning,
                """
                \(configuration.activation): the health poll stopped itself. Its cadence never \
                changes — it runs for as long as Vocca is armed, in every state, because the case it \
                exists for is precisely the one where nothing else is happening.
                """)
        }
    }

    /// The poll keeps running at one cadence for as long as Vocca is armed, whatever is happening.
    ///
    /// Stated as its own test because ``ScheduledWatchdog`` does the opposite and the asymmetry is a
    /// decision: one clock follows a schedule derived from a session, the other has no such schedule
    /// to derive.
    func testThePollsCadenceNeverChanges() {
        let harness = RuntimeHarness()
        harness.runtime.arm()
        harness.press()
        harness.healthTimer.tick(10)

        XCTAssertEqual(
            harness.healthTimer.cadencesRequested, [TapHealthPolling.interval],
            "the poll's clock was restarted, which it never has cause to be.")
        XCTAssertEqual(harness.healthTimer.startCount, 1)
    }

    // MARK: - The two notifications the owner delivers

    /// Both forwards reach the policy and re-create the tap, and neither disturbs the clock.
    ///
    /// They are here at all because an owner has to wire `NSWorkspace.didWakeNotification` and
    /// `com.apple.accessibility.api` to something, and the policy is private — so if they were not
    /// forwarded, an owner would have to hold the policy separately and the poll could be forgotten
    /// again by the same route this class closes.
    func testTheWakeAndGrantNotificationsReachThePolicyWithoutDisturbingTheClock() {
        let harness = RuntimeHarness()
        harness.runtime.arm()
        let startsAfterArming = harness.tap.startCount

        XCTAssertEqual(harness.runtime.systemDidWake(), .delivering)
        XCTAssertEqual(harness.runtime.accessibilityGrantChanged(), .delivering)

        XCTAssertEqual(
            harness.tap.startCount, startsAfterArming + 2,
            """
            One or both notifications did not reach the policy. A tap dies silently across sleep and \
            a tap created before the grant has its mask cleared at creation — neither can be \
            recovered by re-enabling, so both must be a re-creation.
            """)
        XCTAssertEqual(
            harness.recordedNotes.suffix(2),
            [.recreated(.systemDidWake), .recreated(.accessibilityGrantChanged)])
        XCTAssertEqual(
            harness.healthTimer.startCount, 1, "neither notification should restart the poll's clock")
    }

    // MARK: - Ownership

    /// **The `TapHealthTimer` is the policy's only owner, and it must keep it alive.**
    ///
    /// One of the four sole-owner edges phase 4's review measured as unpinned by any test. It is not
    /// idle: an author breaking the observer cycle at the wrong edge gets a green suite and a
    /// product whose tap-health policy has been deallocated — no poll, no recovery, no hotkey after
    /// the first disablement. `unowned let policy` here is that edit, and this test is what fails.
    func testThePolicyOutlivesEveryOtherHandleOnIt() {
        weak var policyAfterwards: TapHealthPolicy?
        let timer = FakeTimer()
        var runtime: TapHealthTimer?

        do {
            let clock = TestClock()
            let tap = FakeHotkeyEventSource()
            let sink = AlwaysPassingThroughSink()
            let policy = TapHealthPolicy(
                source: tap, sink: sink, clock: clock, secureInput: FakeSecureInputState()
            ) { _ in }
            policyAfterwards = policy
            runtime = TapHealthTimer(policy: policy, timer: timer) { _ in }
        }

        XCTAssertNotNil(
            policyAfterwards,
            """
            The TapHealthPolicy was deallocated while its TapHealthTimer still holds it. Every poll \
            and every recovery from here on reaches nothing; the hotkey stops working after the \
            first disablement and there is no error anywhere.
            """)
        XCTAssertNotNil(runtime)
    }

    /// The clock is stopped when the runtime goes away, and the clock does not keep the runtime
    /// alive. Same pair, same reasons, as `ScheduledWatchdog`'s.
    func testTheClockNeitherRetainsTheRuntimeNorOutlivesIt() {
        let timer = FakeTimer()
        weak var released: TapHealthTimer?

        do {
            let clock = TestClock()
            let tap = FakeHotkeyEventSource()
            let sink = AlwaysPassingThroughSink()
            let policy = TapHealthPolicy(
                source: tap, sink: sink, clock: clock, secureInput: FakeSecureInputState()
            ) { _ in }
            let runtime = TapHealthTimer(policy: policy, timer: timer) { _ in }
            released = runtime
            runtime.arm()
            XCTAssertTrue(timer.isRunning)
        }

        XCTAssertNil(released, "the poll's closure retains its owner, so nothing is ever released")
        XCTAssertFalse(
            timer.isRunning,
            "a 1 Hz timer is still scheduled on the main run loop with nothing left to stop it")
    }
}
