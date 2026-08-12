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
import XCTest

// MARK: - Fixtures

/// Space, as in ⌥Space — the shipped default's shape.
private let space: UInt16 = 49
/// F13, bound bare. A second binding, so that "the poll asks about the key this machine watches"
/// is a claim with two data points rather than one that a hard-coded 49 would also satisfy.
private let functionKey: UInt16 = 105
/// `A`. A key Vocca has no interest in — which is nearly every key the user presses, and the
/// direction of propagation that a wrapper hard-coding `.swallow` would destroy.
private let letterA: UInt16 = 0

private let chord = HotkeyConfiguration(
    keyCode: space, modifiers: [.option], activation: .holdToTalk)
private let bareKey = HotkeyConfiguration(
    keyCode: functionKey, modifiers: [], activation: .holdToTalk)
/// The same binding as `chord`, in toggle mode — so every difference the tests below find between
/// the two is a difference of *mode*, not of key or chord.
private let toggleChord = HotkeyConfiguration(
    keyCode: space, modifiers: [.option], activation: .toggle)

private func event(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: false,
        // Deliberately constant, as in `SessionMachineTests`: the machine reads its injected clock
        // and never an event's timestamp, and a test that could steer the ceiling by moving this
        // would have merged the two timebases.
        timestamp: .zero)
}

private typealias Effect = SessionEffect<RecordingSource.Buffer>

// `Keyboard`, `CountingKeyStateReader`, `TruthfulKeyState`, `KeyAlwaysReportedDown`,
// `milliseconds(_:)` and `wakes(covering:)` moved to `SessionTestDoubles.swift` when
// `HotkeyEventSourceTests` needed the same physical keyboard behind the same seam. They are the
// `PhysicalKeyStateReader` half of the pair that file already shares, and a second copy that
// drifted from this one would let a seam test poll a keyboard that behaves differently from the
// one the watchdog's own tests use.

/// The machine, its microphone ledger, the physical keyboard, and the watchdog driving all three.
///
/// The harness plays the part `hotkey-source` will: it owns the timer, and it does what
/// ``SessionWatchdog/schedule`` tells it to.
private final class WatchdogHarness {
    /// Which seam the watchdog is given. The only difference between a run of the shipped policy
    /// and a run of the positive control.
    enum Poll {
        /// Reads the keyboard.
        case truthful
        /// Never reports a release.
        case blindToReleases
    }

    let clock = TestClock()
    let source = RecordingSource()
    let keyboard = Keyboard()
    let keyState: any CountingKeyStateReader
    let machine: SessionMachine<RecordingSource.Buffer>
    let watchdog: SessionWatchdog<RecordingSource.Buffer>
    let configuration: HotkeyConfiguration

    /// **The hot-mic meter.** Forward clock time during which the microphone was open while the
    /// user was not asking for it.
    ///
    /// `PRODUCT_SPEC.md:11` — "there is no state where Vocca is listening and doesn't look like it"
    /// — in a number. Measured against the ``Keyboard``, ``userIsAskingToRecord`` and the
    /// ``RecordingSource`` ledger, never against anything the machine or the watchdog reports about
    /// itself.
    private(set) var hotMicWindow: Duration = .zero

    /// Whether the user, right now, is asking to be recorded.
    ///
    /// **The two modes answer this differently, and that difference is the whole of this task.** In
    /// hold-to-talk it is a fact about the world — the key is physically held — which is why
    /// `CGEventSourceKeyState` can read it out of band and stop rule (f) can close a missed key-up
    /// within one interval. In toggle there is no such fact: the answer is a model of the user's
    /// intent, maintained *here in the test*, because nothing in the running system can observe it.
    /// A poll has nothing to read.
    ///
    /// Switched without a `default:`, so a third mode has to say what asking means in it before the
    /// meter will compile — and a meter that guessed would be a hot-mic measurement of the wrong
    /// thing, which is worse than none.
    private var userIsAskingToRecord: Bool {
        switch configuration.activation {
        case .holdToTalk:
            // **The binding, not the key.** A user holding Space with Option released is not
            // pressing ⌥Space, and a meter that counted them as asking would score the seconds
            // between a released modifier and a released key as consent. Phase 5 gave the poll the
            // second read; this is the same correction to the yardstick, and it has to be the same
            // predicate or the meter grades the poll against a different question.
            return keyboard.isHeld(configuration.keyCode)
                && keyboard.heldModifiers.subtracting(.locking)
                    .isSuperset(of: configuration.modifiers.subtracting(.locking))
        case .toggle: return userHasToggledOn
        }
    }

    /// The toggle half of ``userIsAskingToRecord``: flipped by the gestures, including the gesture
    /// Vocca never sees.
    private var userHasToggledOn = false

    /// Forward clock time this harness has run, which is **not** the clock's reading: a test that
    /// steps the clock backwards makes those two different, and the difference is the point.
    private(set) var forwardTime: Duration = .zero

    private(set) var outcomes: [SessionOutcome<RecordingSource.Buffer>] = []

    init(
        configuration: HotkeyConfiguration = chord,
        ceiling: Duration = SessionCeiling.default,
        poll: Poll = .truthful
    ) {
        self.configuration = configuration
        let keyboard = self.keyboard
        switch poll {
        case .truthful: self.keyState = TruthfulKeyState(keyboard)
        case .blindToReleases: self.keyState = KeyAlwaysReportedDown()
        }
        self.machine = SessionMachine(
            configuration: configuration, ceiling: ceiling, clock: clock, audioSource: source)
        self.watchdog = SessionWatchdog(machine: machine, keyState: keyState)
    }

    // MARK: The gestures

    /// Every gesture below goes through the **watchdog**, not the machine, because that is the call
    /// shape `hotkey-source` will use: the owner holds one object for every input a session has. A
    /// harness that reached past it would leave the shipped arming path untested — which is what
    /// the first round of this task did.
    ///
    /// The user presses the hotkey, and the tap delivers it.
    @discardableResult
    func pressHotkey() -> Effect {
        pressHotkeyObservingPropagation().effect
    }

    /// The same press, with the focused application's half of the answer kept.
    @discardableResult
    func pressHotkeyObservingPropagation() -> SessionResponse<RecordingSource.Buffer> {
        keyboard.hold(configuration)
        return watchdog.observe(event(.keyDown, configuration.keyCode, configuration.modifiers))
    }

    /// Any event at all, through the watchdog — which is where `hotkey-source`'s tap delivers
    /// **every** key event, not only the hotkey's: stop rule (c) is "any event whose flags no longer
    /// carry the configured modifier", so the machine has to see the whole keyboard.
    @discardableResult
    func feed(_ event: RawKeyEvent) -> SessionResponse<RecordingSource.Buffer> {
        watchdog.observe(event)
    }

    /// The user lets go **and the key-up is delivered**. The ordinary ending.
    @discardableResult
    func releaseHotkey() -> Effect {
        keyboard.release(configuration.keyCode)
        return watchdog.observe(event(.keyUp, configuration.keyCode, configuration.modifiers)).effect
    }

    /// The user lets go and **no event ever arrives**: the hotkey was stolen, the tap stalled,
    /// focus moved mid-press, the OS dropped it.
    ///
    /// This is the shape nothing else in this aspect can see. Every other stop rule is driven by an
    /// event, and there is no event.
    func releaseHotkeyUnobserved() {
        keyboard.release(configuration.keyCode)
    }

    /// **The toggle gesture**: the key goes down and comes straight back up, and both events are
    /// delivered through the watchdog.
    ///
    /// The key-up is asserted here rather than left to each caller, because it is the event that
    /// would end the session if toggle had inherited stop rule (a) — so every toggle test in this
    /// file pins it, by construction.
    ///
    /// Returns the key-*down*'s effect, which is the one that starts or stops the session.
    @discardableResult
    func tapHotkey(file: StaticString = #filePath, line: UInt = #line) -> Effect {
        userHasToggledOn.toggle()
        keyboard.hold(configuration)
        let down = watchdog.observe(event(.keyDown, configuration.keyCode, configuration.modifiers))
        keyboard.release(configuration.keyCode)
        let up = watchdog.observe(event(.keyUp, configuration.keyCode, configuration.modifiers))
        XCTAssertEqual(
            up.effect, .unchanged,
            "The key-up of a toggle press changed the session; the mode lasts about sixty "
                + "milliseconds if it does.",
            file: file, line: line)
        record(down.effect)
        return down.effect
    }

    /// **The user taps the hotkey to stop, and Vocca never sees it.**
    ///
    /// The toggle twin of ``releaseHotkeyUnobserved()``, and the reason this file has to measure two
    /// different numbers. In hold-to-talk the same shape is recovered by the physical-key poll one
    /// interval later; here nothing recovers it, because what went missing is an *event* and the
    /// thing it was evidence of — "the user has pressed again" — leaves no trace in the world for a
    /// poll to find.
    func tapHotkeyUnobserved() {
        userHasToggledOn.toggle()
    }

    // MARK: The owner's timer

    /// The interval the watchdog has asked for.
    ///
    /// A stopped schedule still names one, because a real timer told to stop can have a wake
    /// already queued, and that wake still has to be harmless.
    private var interval: Duration {
        switch watchdog.schedule {
        case .wake(let every): return every
        case .stopped: return WatchdogPolicy.pollInterval
        }
    }

    /// One turn of the timer.
    ///
    /// The meter samples **before** the interval elapses: what was true when it began was true for
    /// its whole length, whether or not the wake at its end puts a stop to it. Sampling afterwards
    /// would credit the watchdog with the interval it took to notice.
    @discardableResult
    func step() -> Effect {
        let hot = source.isOpen && !userIsAskingToRecord
        let elapsing = interval
        clock.now += elapsing
        forwardTime += elapsing
        if hot { hotMicWindow += elapsing }

        let effect = watchdog.wake()
        record(effect)
        return effect
    }

    func run(steps: Int) {
        for _ in 0..<steps { _ = step() }
    }

    /// Keeps the outcome ledger, for whichever input produced this effect.
    ///
    /// One copy, because three sites produce outcomes — the timer's two shapes and the toggle
    /// gesture — and a copy that drifted would let a test count outcomes from one path and miss
    /// them from another.
    private func record(_ effect: Effect) {
        switch effect {
        case .ended(let outcome): outcomes.append(outcome)
        case .unchanged, .started, .captureUnavailable, .opening: break
        }
    }

    /// A turn of the timer during which **real time passes and the clock does not say so.**
    ///
    /// The distinction the frozen-clock test is about: the owner's timer is firing on schedule, the
    /// poll is being asked and answering, and the only thing that has stopped is the one reading the
    /// ceiling is measured against. `forwardTime` still advances, because it is real time;
    /// `clock.now` does not, because that is the defect.
    @discardableResult
    func stepWithoutTheClockAdvancing() -> Effect {
        let hot = source.isOpen && !userIsAskingToRecord
        forwardTime += interval
        if hot { hotMicWindow += interval }

        let effect = watchdog.wake()
        record(effect)
        return effect
    }
}

/// The reason an outcome carries, having first checked that it carries **this session's** audio.
///
/// Both halves matter, and the second is the one a machine that swapped in a fresh empty buffer
/// would pass without: `handedOut.last` is unique per close, so "an outcome with a buffer" and "the
/// outcome with the buffer this session captured" are different assertions.
private func reasonCarryingTheAudio(
    _ outcome: SessionOutcome<RecordingSource.Buffer>, from source: RecordingSource,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) throws -> RetainedEndReason {
    switch outcome.content {
    case .completed(let reason, let audio, _):
        XCTAssertEqual(
            audio, try XCTUnwrap(source.handedOut.last, file: file, line: line),
            "The outcome carried a buffer that is not this session's. \(message)",
            file: file, line: line)
        return reason
    case .cancelled:
        XCTFail(
            "The session discarded audio the user never asked to abandon. \(message)",
            file: file, line: line)
        throw XCTSkip("no reason")
    }
}

/// **The hot-mic guarantee.** Everything before this made losing the user's words impossible; this
/// is what makes an unnoticed open microphone impossible.
///
/// Every assertion here is made against two ledgers the production code cannot write to — the
/// ``Keyboard`` and the ``RecordingSource`` — because the claim being tested is precisely that the
/// machine's own account of itself is not enough.
final class SessionWatchdogTests: XCTestCase {

    // MARK: - When to look

    /// The timer runs at the reviewed cadence, and **only while a session is recording**.
    ///
    /// The second half is the battery half of `spec.md` open question 2 and the reason the interval
    /// can afford to be as short as it is: it is not a timer the application runs, it is a timer a
    /// *session* runs.
    func testTheTimerRunsAtThePolledCadenceAndOnlyWhileRecording() throws {
        // A reviewed constant, inside the 100–250 ms `spec.md` researched. Pinned by value because
        // it is the worst-case hot-mic window, and a silent change to it is a silent change to that.
        XCTAssertEqual(WatchdogPolicy.pollInterval, .milliseconds(150))
        XCTAssertGreaterThanOrEqual(WatchdogPolicy.pollInterval, .milliseconds(100))
        XCTAssertLessThanOrEqual(WatchdogPolicy.pollInterval, .milliseconds(250))

        let harness = WatchdogHarness()
        XCTAssertEqual(harness.watchdog.schedule, .stopped, "A timer was asked for with no session.")

        // A wake against an idle machine: harmless, and it costs no system call.
        XCTAssertEqual(harness.step(), .unchanged)
        XCTAssertEqual(
            harness.keyState.reads, 0,
            "The physical key was read with no session running — a system call for an answer about "
                + "somebody else's press.")

        XCTAssertEqual(harness.pressHotkey(), .started)
        XCTAssertEqual(harness.watchdog.schedule, .wake(every: .milliseconds(150)))
        harness.run(steps: 3)
        XCTAssertEqual(harness.keyState.reads, 3, "The poll stopped asking while a session ran.")

        _ = try endedOutcome(harness.releaseHotkey())
        XCTAssertEqual(
            harness.watchdog.schedule, .stopped,
            "The timer kept running after the session ended.")
        harness.run(steps: 3)
        XCTAssertEqual(
            harness.keyState.reads, 3, "The poll kept reading the key after the session ended.")
        XCTAssertEqual(harness.hotMicWindow, .zero)
    }

    // MARK: - The ceiling

    /// The ceiling ends the session on the wake that reaches the deadline, not one earlier, and
    /// hands over what it captured.
    func testTheCeilingEndsTheSessionAtExactlyTheDeadlineAndHandsOverTheAudio() throws {
        let harness = WatchdogHarness()
        let deadline = wakes(covering: SessionCeiling.default)
        XCTAssertEqual(deadline, 800, "120 s at 150 ms is 800 wakes; the arithmetic moved.")

        XCTAssertEqual(harness.pressHotkey(), .started)
        for wake in 1..<deadline {
            XCTAssertEqual(
                harness.step(), .unchanged,
                "The ceiling fired at wake \(wake) of \(deadline) — early, on a user mid-sentence.")
        }
        XCTAssertTrue(harness.source.isOpen)
        XCTAssertEqual(harness.machine.elapsed, SessionCeiling.default - WatchdogPolicy.pollInterval)

        let outcome = try endedOutcome(harness.step(), "at exactly the deadline")
        XCTAssertEqual(try reasonCarryingTheAudio(outcome, from: harness.source), .ceilingReached)
        XCTAssertFalse(harness.source.isOpen, "The ceiling fired and the microphone stayed open.")
        XCTAssertEqual(harness.machine.elapsed, SessionCeiling.default)
        XCTAssertEqual(harness.watchdog.schedule, .stopped)
        XCTAssertEqual(
            harness.hotMicWindow, .zero, "The key was held for the whole session; nothing was hot.")
        XCTAssertEqual(
            harness.keyState.reads, deadline, "The poll ran on every wake of the session.")
        XCTAssertEqual(harness.keyState.keysAsked, [space])
    }

    /// The 110 s warning is **derived** from the ceiling. It is nowhere written down.
    ///
    /// `PRODUCT_SPEC.md:79-80` asks for it at 110 s against the shipped 120 s ceiling. A literal
    /// 110 satisfies that sentence and breaks every other ceiling: a user who lowered theirs to
    /// 60 s would be warned ten seconds after being cut off.
    func testTheCeilingWarningIsDerivedFromTheCeilingAndMovesWithIt() throws {
        XCTAssertEqual(
            WatchdogPolicy.warningThreshold(before: SessionCeiling.default), .seconds(110),
            "PRODUCT_SPEC.md:79-80 wants the warning at 110 s for the shipped 120 s ceiling.")

        // A fixed lead, not a proportion. 110/120 of 60 s is 55 s; this must be 50.
        XCTAssertEqual(WatchdogPolicy.warningThreshold(before: .seconds(60)), .seconds(50))
        for ceiling in [Duration.seconds(30), .seconds(60), .seconds(120), .seconds(600)] {
            XCTAssertEqual(
                ceiling - WatchdogPolicy.warningThreshold(before: ceiling),
                WatchdogPolicy.warningLeadTime,
                "The user got a different amount of notice at a \(ceiling) ceiling.")
        }
        // Shorter than the lead: inside the window from the first instant, not a negative threshold.
        XCTAssertEqual(WatchdogPolicy.warningThreshold(before: .seconds(4)), .zero)

        // And the value the widget actually reads, at three different ceilings. The 40 s one is
        // there because its threshold falls on a wake **exactly** — 30 s is 200 intervals — which
        // is the only arrangement that can tell `>=` from `>` at the boundary.
        for ceiling in [Duration.seconds(120), .seconds(60), .seconds(40)] {
            let harness = WatchdogHarness(ceiling: ceiling)
            let threshold = WatchdogPolicy.warningThreshold(before: ceiling)
            XCTAssertEqual(harness.watchdog.warningThreshold, threshold)
            XCTAssertFalse(
                harness.watchdog.ceilingIsNear, "The widget warned with no session running.")

            let covering = wakes(covering: threshold)
            let landsOnAWake = WatchdogPolicy.pollInterval * covering == threshold

            XCTAssertEqual(harness.pressHotkey(), .started)
            harness.run(steps: landsOnAWake ? covering - 1 : covering)
            XCTAssertLessThan(harness.machine.elapsed, threshold)
            XCTAssertFalse(
                harness.watchdog.ceilingIsNear,
                "Warned at \(harness.machine.elapsed) against a \(ceiling) ceiling.")

            harness.run(steps: 1)
            XCTAssertGreaterThanOrEqual(harness.machine.elapsed, threshold)
            XCTAssertTrue(
                harness.watchdog.ceilingIsNear,
                "No warning at \(harness.machine.elapsed) against a \(ceiling) ceiling.")

            // A warning is not a stop. The user is being told, not cut off.
            XCTAssertEqual(harness.machine.state, .recording)
            XCTAssertTrue(harness.source.isOpen)
            XCTAssertTrue(harness.outcomes.isEmpty)
        }
    }

    // MARK: - The poll

    /// **A key released with no event ends the session within one poll interval**, with its audio.
    ///
    /// The shape only this poll can see: every other stop rule is driven by an event, and here
    /// there is none — the hotkey was stolen, the tap stalled, focus moved mid-press.
    func testAKeyReleasedWithNoEventEndsTheSessionWithinOnePollInterval() throws {
        let harness = WatchdogHarness()
        XCTAssertEqual(harness.pressHotkey(), .started)
        harness.run(steps: 20)
        XCTAssertTrue(harness.source.isOpen)

        harness.releaseHotkeyUnobserved()
        XCTAssertTrue(
            harness.source.isOpen,
            "Premise of this test: nothing has told the machine, so it cannot yet have acted.")
        XCTAssertEqual(harness.machine.state, .recording)

        let outcome = try endedOutcome(harness.step(), "one interval after the key came up")
        XCTAssertEqual(
            try reasonCarryingTheAudio(outcome, from: harness.source), .pollDetectedRelease)
        XCTAssertFalse(harness.source.isOpen)
        XCTAssertEqual(
            harness.hotMicWindow, WatchdogPolicy.pollInterval,
            "The microphone was open without a held key for longer than one poll interval.")
        XCTAssertEqual(harness.watchdog.schedule, .stopped)

        // The same, against a different binding: the poll asks about **this machine's** key.
        let bare = WatchdogHarness(configuration: bareKey)
        XCTAssertEqual(bare.pressHotkey(), .started)
        bare.releaseHotkeyUnobserved()
        let bareOutcome = try endedOutcome(bare.step())
        XCTAssertEqual(
            try reasonCarryingTheAudio(bareOutcome, from: bare.source), .pollDetectedRelease)
        XCTAssertEqual(
            bare.keyState.keysAsked, [functionKey],
            "The poll read a key code other than the one this machine is configured for.")
    }

    /// A poll that keeps finding the key held ends nothing — however many times it runs.
    func testAKeyThatStaysHeldIsPolledForeverAndEndsNothing() throws {
        let harness = WatchdogHarness()
        XCTAssertEqual(harness.pressHotkey(), .started)
        harness.run(steps: 100)

        XCTAssertEqual(harness.keyState.reads, 100, "The poll stopped asking.")
        XCTAssertEqual(harness.keyState.keysAsked, [space])
        XCTAssertEqual(harness.machine.state, .recording, "A held key ended the session.")
        XCTAssertTrue(harness.source.isOpen)
        XCTAssertEqual(harness.source.endCount, 0)
        XCTAssertTrue(harness.outcomes.isEmpty)
        XCTAssertEqual(harness.hotMicWindow, .zero)
        XCTAssertEqual(harness.machine.elapsed, WatchdogPolicy.pollInterval * 100)
    }

    /// **The positive control.** The meter that says "the microphone did not stay open" must be
    /// able to say the opposite.
    ///
    /// `spec.md:161-163`, carried forward from `project-skeleton`: every zero-assertion needs a
    /// positive control sharing its mechanism. Six checks in this repository have passed while
    /// measuring nothing; "the mic did not stay open" against a meter that cannot see a hot mic
    /// would be the seventh.
    ///
    /// The two runs differ in exactly one thing — what the seam reports — and both are metered by
    /// the same code against the same keyboard.
    func testTheHotMicMeterDetectsASessionThatDidStayOpen() throws {
        let honest = WatchdogHarness(poll: .truthful)
        let blind = WatchdogHarness(poll: .blindToReleases)
        let run = 40  // 6 s of forward time, far short of the 120 s ceiling.

        for harness in [honest, blind] {
            XCTAssertEqual(harness.pressHotkey(), .started)
            harness.run(steps: 1)  // One interval with the key genuinely held.
            harness.releaseHotkeyUnobserved()
            harness.run(steps: run)
        }

        // The control. A microphone that stayed open for the whole run, and a meter that says so.
        XCTAssertTrue(
            blind.source.isOpen,
            "The control did not produce a hot mic, so it controls for nothing.")
        XCTAssertEqual(blind.machine.state, .recording)
        XCTAssertEqual(
            blind.hotMicWindow, WatchdogPolicy.pollInterval * run,
            "The meter did not measure a microphone that was open for the whole run.")
        XCTAssertGreaterThan(blind.hotMicWindow, WatchdogPolicy.pollInterval)
        XCTAssertEqual(
            blind.keyState.reads, run + 1,
            "The control must have been polled and lied to, not left unpolled.")

        // So the same meter reading one interval for the shipped policy is a measurement.
        XCTAssertFalse(honest.source.isOpen)
        XCTAssertEqual(honest.machine.state, .idle)
        XCTAssertEqual(honest.hotMicWindow, WatchdogPolicy.pollInterval)
        XCTAssertEqual(honest.outcomes.count, 1)
        XCTAssertEqual(
            try reasonCarryingTheAudio(try XCTUnwrap(honest.outcomes.first), from: honest.source),
            .pollDetectedRelease)
    }

    /// When the ceiling and a missed release fall on the **same** wake, the release is what gets
    /// logged.
    ///
    /// Both are true, so the order inside ``SessionWatchdog/wake()`` decides which reason reaches
    /// the log, and the log is the only evidence anyone gets. "The user talked for two minutes" and
    /// "the user let go and Vocca had to find out by asking" are different incidents.
    ///
    /// That the wake in question really is the ceiling's is established by the twin run, not
    /// asserted: the poll ends the session before the tick, so this harness's own elapsed time
    /// never reaches the deadline.
    func testWhenTheCeilingAndAMissedReleaseFallOnTheSameWakeTheReleaseIsLogged() throws {
        let deadline = wakes(covering: SessionCeiling.default)

        // The twin, whose seam never reports the release: it runs to the ceiling, at wake 800.
        let twin = WatchdogHarness(poll: .blindToReleases)
        XCTAssertEqual(twin.pressHotkey(), .started)
        twin.run(steps: deadline - 1)
        XCTAssertTrue(twin.source.isOpen)
        let twinOutcome = try endedOutcome(twin.step(), "the ceiling's own wake")
        XCTAssertEqual(try reasonCarryingTheAudio(twinOutcome, from: twin.source), .ceilingReached)

        // The same run, with the key coming up unobserved inside the final interval.
        let harness = WatchdogHarness()
        XCTAssertEqual(harness.pressHotkey(), .started)
        harness.run(steps: deadline - 1)
        harness.releaseHotkeyUnobserved()

        let outcome = try endedOutcome(harness.step(), "on the wake where both were due")
        XCTAssertEqual(
            try reasonCarryingTheAudio(outcome, from: harness.source), .pollDetectedRelease,
            "A missed key-up was filed as two minutes of speech.")
        XCTAssertFalse(harness.source.isOpen)
    }

    // MARK: - The clock

    /// **Each backward step costs at most one interval — and N of them cost N.**
    ///
    /// The bound is per jump, not per session. `MonotonicClock.swift:48-50` says "at most one tick
    /// interval", which is right for a single jump and was on its way to being read as a
    /// per-session guarantee by this task. Measured here rather than restated: the loss is
    /// `forward time − the machine's own accumulated elapsed`, and three jumps of five seconds cost
    /// three intervals, not fifteen seconds and not one interval.
    func testThreeBackwardClockStepsCostExactlyThreePollIntervals() throws {
        let harness = WatchdogHarness()
        let deadline = wakes(covering: SessionCeiling.default)
        let jumpsAt: Set<Int> = [100, 400, 700]
        let jump = Duration.seconds(5)

        XCTAssertEqual(harness.pressHotkey(), .started)
        var wake = 0
        var ended: SessionOutcome<RecordingSource.Buffer>?
        // Bounded, and the bound is a `while` condition rather than an assertion inside the loop.
        // XCTAssert records a failure and carries on, so a policy that never ends the session would
        // spin here forever — which is not a red suite, it is a hung one. Found by running this
        // file's own mutation battery.
        while ended == nil && wake <= deadline + jumpsAt.count {
            wake += 1
            // The jump lands inside the interval that this wake closes, so that tick's whole
            // interval of forward time is what gets lost.
            if jumpsAt.contains(wake) { harness.clock.now -= jump }
            switch harness.step() {
            case .ended(let outcome): ended = outcome
            case .unchanged, .started, .captureUnavailable, .opening: break
            }
        }
        XCTAssertNotNil(
            ended,
            "The session outlived the bound: a backward clock cost it more than one interval per "
                + "jump, which is a hot microphone for as long as the clock misbehaves.")

        XCTAssertEqual(
            wake, deadline + jumpsAt.count,
            "The session ended at wake \(wake) instead of \(deadline + jumpsAt.count). An "
                + "absolute deadline would have ended it at \(deadline + wakes(covering: jump * jumpsAt.count)).")
        XCTAssertEqual(
            try reasonCarryingTheAudio(try XCTUnwrap(ended), from: harness.source), .ceilingReached)
        XCTAssertEqual(
            harness.forwardTime - harness.machine.elapsed,
            WatchdogPolicy.pollInterval * jumpsAt.count,
            "Three backward steps cost more or less than three intervals of forward time.")
        XCTAssertEqual(harness.machine.elapsed, SessionCeiling.default)
    }

    /// A backward step **smaller** than the interval costs only its own size.
    ///
    /// The arithmetic is `min(jump, that tick's interval)`, and a fix that clamped every jump to a
    /// whole interval would pass the test above while being wrong here.
    func testABackwardStepSmallerThanThePollIntervalCostsOnlyItsOwnSize() throws {
        let harness = WatchdogHarness()
        let deadline = wakes(covering: SessionCeiling.default)
        let jump = Duration.milliseconds(50)
        XCTAssertLessThan(jump, WatchdogPolicy.pollInterval)

        XCTAssertEqual(harness.pressHotkey(), .started)
        var wake = 0
        var ended: SessionOutcome<RecordingSource.Buffer>?
        while ended == nil && wake <= deadline + 1 {
            wake += 1
            if wake == 100 { harness.clock.now -= jump }
            switch harness.step() {
            case .ended(let outcome): ended = outcome
            case .unchanged, .started, .captureUnavailable, .opening: break
            }
        }
        XCTAssertNotNil(ended, "The session outlived the bound.")
        XCTAssertEqual(wake, deadline + 1)

        XCTAssertEqual(
            harness.forwardTime - harness.machine.elapsed, jump,
            "A 50 ms backward step cost something other than 50 ms of the session.")
        XCTAssertLessThan(harness.forwardTime - harness.machine.elapsed, WatchdogPolicy.pollInterval)

        // The other half of the overrun, and the one that is the poll interval's own doing: the
        // ceiling fires on the first wake at or past the deadline, so a session can run up to one
        // interval long *in its own elapsed time* before it is cut off. Stated as a bound and
        // measured, because the report of this task states it.
        XCTAssertGreaterThan(harness.machine.elapsed, SessionCeiling.default)
        XCTAssertLessThan(
            harness.machine.elapsed - SessionCeiling.default, WatchdogPolicy.pollInterval)
        XCTAssertEqual(
            try reasonCarryingTheAudio(try XCTUnwrap(ended), from: harness.source), .ceilingReached)
    }

    /// **A clock that never advances disables the ceiling — and nothing else.**
    ///
    /// Monotonicity is satisfied by a clock that never moves, and `MonotonicClock`'s contract did
    /// not require advancement until this round. It has to, because `elapsed` accumulates deltas:
    /// readings that stall do not delay the ceiling, they remove it, while every other mechanism
    /// goes on looking healthy.
    ///
    /// Both halves are measured here, and the second is the load-bearing one — it is what makes the
    /// residual *precisely* the physically-held-key case (§5(b)/(c) of the task report) rather than
    /// a total loss of the guarantee.
    func testAClockThatNeverAdvancesDisablesTheCeilingButNotThePoll() throws {
        let harness = WatchdogHarness()
        XCTAssertEqual(harness.pressHotkey(), .started)

        // Ten thousand wakes at the policy cadence — twenty-five minutes of real time, more than
        // twelve times the ceiling.
        let wakes = 10_000
        for _ in 0..<wakes { _ = harness.stepWithoutTheClockAdvancing() }

        XCTAssertEqual(harness.forwardTime, WatchdogPolicy.pollInterval * wakes)
        XCTAssertGreaterThan(harness.forwardTime, SessionCeiling.default)
        XCTAssertEqual(
            harness.machine.elapsed, .zero,
            "The clock never moved, so no forward time can have been accumulated.")
        XCTAssertEqual(
            harness.machine.state, .recording,
            "The ceiling ended a session against a stalled clock — then this test's premise is "
                + "gone and MonotonicClock's new requirement is not the one that matters.")
        XCTAssertTrue(harness.source.isOpen, "Twenty-five minutes, and the microphone is open.")
        XCTAssertTrue(harness.outcomes.isEmpty)

        // The poll is untouched: it reads no clock. So the session still ends the moment the key
        // comes up, and what a stalled clock costs is exactly the *held-key* bound, not the poll.
        XCTAssertEqual(
            harness.keyState.reads, wakes, "The poll stopped running against a stalled clock.")
        harness.releaseHotkeyUnobserved()
        let outcome = try endedOutcome(
            harness.stepWithoutTheClockAdvancing(), "the poll reads no clock and must still fire")
        XCTAssertEqual(
            try reasonCarryingTheAudio(outcome, from: harness.source), .pollDetectedRelease)
        XCTAssertFalse(harness.source.isOpen)
    }

    // MARK: - System triggers

    /// Each ``SystemTrigger`` ends the session with **its own** reason, hands over the audio, and
    /// leaves no timer running.
    func testEverySystemTriggerEndsTheSessionWithItsOwnReasonAndStopsTheTimer() throws {
        for trigger in SystemTrigger.allCases {
            let harness = WatchdogHarness()
            XCTAssertEqual(harness.pressHotkey(), .started, "\(trigger)")
            XCTAssertEqual(harness.watchdog.schedule, .wake(every: WatchdogPolicy.pollInterval))
            harness.run(steps: 10)

            let outcome = try endedOutcome(harness.watchdog.observe(trigger), "\(trigger)")
            XCTAssertEqual(
                try reasonCarryingTheAudio(outcome, from: harness.source, "\(trigger)"),
                .systemEvent(trigger),
                "\(trigger) was logged as something else — the log is the only evidence anyone gets.")
            XCTAssertFalse(harness.source.isOpen, "\(trigger) left the microphone open.")
            XCTAssertEqual(
                harness.watchdog.schedule, .stopped,
                "\(trigger) ended the session and left the timer running.")

            let readsBefore = harness.keyState.reads
            harness.run(steps: 5)
            XCTAssertEqual(
                harness.keyState.reads, readsBefore,
                "The poll kept reading the key after \(trigger) ended the session.")
            XCTAssertEqual(harness.hotMicWindow, .zero, "\(trigger)")
            XCTAssertEqual(harness.outcomes.count, 0, "\(trigger) produced a second outcome.")
        }
    }

    /// A trigger arriving with no session is a safe no-op.
    ///
    /// These are broadcasts. They arrive whether or not Vocca is recording, and a machine going to
    /// sleep owes nobody an outcome.
    func testASystemTriggerWithNoSessionIsASafeNoOp() throws {
        for trigger in SystemTrigger.allCases {
            let harness = WatchdogHarness()
            XCTAssertEqual(harness.watchdog.observe(trigger), .unchanged, "\(trigger)")
            XCTAssertEqual(harness.machine.state, .idle)
            XCTAssertEqual(harness.source.beginCount, 0, "\(trigger) opened a microphone.")
            XCTAssertEqual(harness.source.endCount, 0, "\(trigger) closed a microphone that was "
                + "never opened, which is an outcome with no session behind it.")
            XCTAssertEqual(harness.source.closesWithoutOpen, 0)
            XCTAssertEqual(harness.watchdog.schedule, .stopped)
            XCTAssertFalse(harness.watchdog.ceilingIsNear)
            XCTAssertEqual(harness.keyState.reads, 0)

            // And it did not wedge anything: the next press still works.
            XCTAssertEqual(harness.pressHotkey(), .started, "\(trigger)")
            XCTAssertEqual(harness.watchdog.schedule, .wake(every: WatchdogPolicy.pollInterval))
        }
    }

    /// A timer fire delivered from **inside the handoff** changes nothing and reads no key.
    ///
    /// Not a hypothetical: stopping a real `AVAudioEngine` pumps a run loop, and a run loop that
    /// can deliver a queued key event can deliver a queued timer fire just as easily — the machine's
    /// own tests already drive the key-event half of this through the same hook. `.ending` describes
    /// the handoff exactly, so the answer is the same as for an idle machine: nothing to watch, and
    /// no system call to make finding that out.
    func testAWakeDeliveredFromInsideTheHandoffChangesNothing() throws {
        let harness = WatchdogHarness()
        XCTAssertEqual(harness.pressHotkey(), .started)
        harness.run(steps: 4)
        let readsBeforeTheHandoff = harness.keyState.reads

        var scheduleDuringHandoff: WatchdogSchedule?
        var effectDuringHandoff: Effect?
        var readsDuringHandoff: Int?
        harness.source.duringEndCapture = { [watchdog = harness.watchdog, key = harness.keyState] in
            scheduleDuringHandoff = watchdog.schedule
            effectDuringHandoff = watchdog.wake()
            readsDuringHandoff = key.reads
        }

        _ = try endedOutcome(harness.releaseHotkey())
        XCTAssertEqual(scheduleDuringHandoff, .stopped, "A timer was asked for from inside `.ending`.")
        XCTAssertEqual(effectDuringHandoff, .unchanged)
        XCTAssertEqual(
            readsDuringHandoff, readsBeforeTheHandoff,
            "The physical key was read from inside the handoff, for a session that is already over.")
        XCTAssertEqual(harness.source.endCount, 1, "The microphone was closed twice.")
        XCTAssertEqual(harness.source.closesWithoutOpen, 0)
    }

    /// **Every input a session owner has arrives through the watchdog, and the timer settles after
    /// each one.**
    ///
    /// The key-event path is the one that *arms* the watchdog — it is the only input that can move
    /// the machine into `.recording` — and in the first round of this task it was the one input that
    /// did not go through it. Wrapping it does not force an owner to re-read ``schedule`` (nothing
    /// in a module with no run loop could), but it removes the second door: an owner never needs to
    /// hold the machine, so no input can arrive by a route the schedule is not read after.
    ///
    /// `cancel()` is here for the same reason. Wrapping three of four inputs is the state in which
    /// someone keeps a machine reference for the fourth and then uses it for the others.
    func testEveryOwnerInputArrivesThroughTheWatchdogAndSettlesItsTimer() throws {
        // 1. A key-down arms it — and the press is still swallowed. A wrapper that fabricated its
        //    own answer instead of returning the machine's would type a space into the user's
        //    document.
        let arming = WatchdogHarness()
        XCTAssertEqual(arming.watchdog.schedule, .stopped)
        let press = arming.pressHotkeyObservingPropagation()
        XCTAssertEqual(press.effect, .started)
        XCTAssertEqual(
            press.eventPropagation, .swallow,
            "The watchdog's key-event path returned a propagation the machine did not decide.")
        XCTAssertEqual(arming.watchdog.schedule, .wake(every: WatchdogPolicy.pollInterval))

        // 2. A key-up disarms it.
        _ = try endedOutcome(arming.releaseHotkey())
        XCTAssertEqual(arming.watchdog.schedule, .stopped)

        // 3. Escape, through the watchdog: the audio is discarded — that is what the user asked for
        //    — the microphone is not, and the timer stops.
        let cancelled = WatchdogHarness()
        XCTAssertEqual(cancelled.pressHotkey(), .started)
        cancelled.run(steps: 3)
        let outcome = try endedOutcome(cancelled.watchdog.cancel())
        switch outcome.content {
        case .completed:
            XCTFail("Escape is the one path that discards, and it did not.")
        case .cancelled:
            break
        }
        XCTAssertFalse(
            cancelled.source.isOpen,
            "Escape discarded the transcript and left the microphone open. Those are different "
                + "things and only the first was asked for.")
        XCTAssertEqual(cancelled.source.endCount, 1)
        XCTAssertEqual(cancelled.watchdog.schedule, .stopped)
        XCTAssertFalse(cancelled.watchdog.ceilingIsNear)

        let readsAfterCancelling = cancelled.keyState.reads
        cancelled.run(steps: 5)
        XCTAssertEqual(
            cancelled.keyState.reads, readsAfterCancelling,
            "The poll kept reading the key after the user cancelled.")

        // 4. And a cancelled machine is not wedged: the next press arms it again.
        XCTAssertEqual(cancelled.pressHotkey(), .started)
        XCTAssertEqual(cancelled.watchdog.schedule, .wake(every: WatchdogPolicy.pollInterval))
    }

    /// **An event the machine passes through still reaches the application — through the wrapper.**
    ///
    /// The other direction, and the one with the blast radius. `hotkey-source`'s tap delivers
    /// *every* key event to this object, because stop rule (c) is "any event whose flags no longer
    /// carry the configured modifier" (`spec.md:47`) and the machine cannot apply that to events it
    /// never sees. So a wrapper that hard-coded `.swallow` would not mishandle an edge case: it
    /// would eat the user's entire keyboard, in every application, for as long as Vocca is running.
    ///
    /// The round-1 test pinned propagation in one direction only — the harmless one, where a key
    /// that is supposed to be swallowed is. Every other `.passThrough` assertion in the repository
    /// goes through `machine.observe` directly, where this wrapper is not in the path, so the whole
    /// class was unpinned across the seam it was added to.
    func testAnEventTheMachinePassesThroughStillReachesTheApplication() throws {
        let harness = WatchdogHarness()

        // 1. An ordinary keystroke with no session running. The overwhelmingly common case: Vocca
        //    is a background app and this is every key the user types all day.
        let idle = harness.feed(event(.keyDown, letterA, []))
        XCTAssertEqual(idle.effect, .unchanged)
        XCTAssertEqual(
            idle.eventPropagation, .passThrough,
            "Vocca swallowed an unrelated keystroke while idle — every key the user types, gone.")
        XCTAssertEqual(harness.feed(event(.keyUp, letterA, [])).eventPropagation, .passThrough)

        // 2. And while a session is recording, with the chord still held: the user is dictating,
        //    not typing, but the keyboard is still theirs.
        XCTAssertEqual(harness.pressHotkey(), .started)
        let recording = harness.feed(event(.keyDown, letterA, [.option]))
        XCTAssertEqual(
            recording.eventPropagation, .passThrough,
            "Vocca swallowed an unrelated keystroke during a session.")
        XCTAssertEqual(
            harness.machine.state, .recording,
            "An unrelated keystroke that still carries the chord must not end the session.")

        // 3. The event that *does* end it — stop rule (b)/(c), the modifier coming up — is a
        //    modifier event, and those are never claimed in either direction: swallowing one would
        //    strand the focused application's idea of which modifiers are down.
        let dropped = harness.feed(event(.flagsChanged, harness.configuration.keyCode, []))
        XCTAssertEqual(
            dropped.eventPropagation, .passThrough,
            "Vocca swallowed a modifier event, stranding the app's idea of what is held.")
        let outcome = try endedOutcome(dropped.effect, "the configured modifier came up")
        XCTAssertEqual(
            try reasonCarryingTheAudio(outcome, from: harness.source), .modifierReleased)
        XCTAssertFalse(harness.source.isOpen)
    }

    /// A key event delivered **from inside the handoff** gets the machine's own answer, not the
    /// wrapper's.
    ///
    /// `.ending` is the one state in which a wrapper could plausibly justify a guard of its own —
    /// and it must not have one, because the machine already answers correctly there and a second
    /// opinion about propagation is the F-A1 defect in a narrower window. Two events go through in
    /// the same handoff, and they must come back with *different* answers, so no fabricated constant
    /// can satisfy both.
    func testAKeyEventDeliveredFromInsideTheHandoffGetsTheMachinesOwnAnswer() throws {
        let harness = WatchdogHarness()
        XCTAssertEqual(harness.pressHotkey(), .started)

        var unrelated: SessionResponse<RecordingSource.Buffer>?
        var claimed: SessionResponse<RecordingSource.Buffer>?
        harness.source.duringEndCapture = { [watchdog = harness.watchdog] in
            unrelated = watchdog.observe(event(.keyDown, letterA, []))
            claimed = watchdog.observe(event(.keyDown, space, [.option]))
        }

        _ = try endedOutcome(harness.releaseHotkey())

        XCTAssertEqual(
            try XCTUnwrap(unrelated).eventPropagation, .passThrough,
            "An unrelated keystroke was eaten because it arrived during the handoff.")
        XCTAssertEqual(try XCTUnwrap(unrelated).effect, .unchanged)
        XCTAssertEqual(
            try XCTUnwrap(claimed).eventPropagation, .swallow,
            "The hotkey Vocca swallowed the press of came back through as the app's to type.")
        XCTAssertEqual(
            try XCTUnwrap(claimed).effect, .unchanged,
            "A key event arriving inside the handoff started or ended something.")
        XCTAssertEqual(harness.source.endCount, 1, "The microphone was closed twice.")
        XCTAssertEqual(harness.source.closesWithoutOpen, 0)
    }

    // MARK: - Toggle mode: the ceiling is the whole backstop

    /// **The ceiling still fires in toggle mode, through the watchdog** — and this is the hot-mic
    /// guarantee for a mode with no finger behind it.
    ///
    /// Driven wake by wake through ``SessionWatchdog/wake()``, not through `machine.tick()`, because
    /// the mutation this exists to kill lives in `wake()`: a toggle branch that returns `.unchanged`
    /// instead of ticking compiles, passes every rules test, passes every machine test that ticks
    /// directly, and leaves a toggle session running until the process exits.
    ///
    /// The elapsed assertion at wake 799 is the other half. Without it, a branch that ticked only on
    /// the last wake — or one whose clock never advanced — would reach the same ending.
    func testTheCeilingStillEndsAToggleSessionAndDoesSoThroughTheWatchdog() throws {
        let harness = WatchdogHarness(configuration: toggleChord)
        let deadline = wakes(covering: SessionCeiling.default)
        XCTAssertEqual(deadline, 800, "120 s at 150 ms is 800 wakes; the arithmetic moved.")

        XCTAssertEqual(harness.tapHotkey(), .started)
        XCTAssertEqual(
            harness.watchdog.schedule, .wake(every: WatchdogPolicy.pollInterval),
            "A toggle session asked for no timer. The ceiling is the only unconditional thing "
                + "bounding it, and the timer is what drives the ceiling.")

        for wake in 1..<deadline {
            XCTAssertEqual(
                harness.step(), .unchanged,
                "The ceiling fired at wake \(wake) of \(deadline) — early, on a user mid-sentence.")
        }
        XCTAssertTrue(harness.source.isOpen)
        XCTAssertEqual(
            harness.machine.elapsed, SessionCeiling.default - WatchdogPolicy.pollInterval,
            "The wakes ran but the session's clock did not advance with them, so the ceiling below "
                + "is being reached by something other than elapsed time.")

        let outcome = try endedOutcome(harness.step(), "at exactly the deadline")
        XCTAssertEqual(try reasonCarryingTheAudio(outcome, from: harness.source), .ceilingReached)
        XCTAssertFalse(harness.source.isOpen, "The ceiling fired and the microphone stayed open.")
        XCTAssertEqual(harness.machine.elapsed, SessionCeiling.default)
        XCTAssertEqual(harness.watchdog.schedule, .stopped)

        // Nothing was hot: the user never stopped asking, they were cut off. And the poll was never
        // run — 800 wakes and not one system call.
        XCTAssertEqual(harness.hotMicWindow, .zero)
        XCTAssertEqual(harness.keyState.reads, 0)
    }

    /// **The physical key is never read in toggle mode — and is read on every wake in
    /// hold-to-talk.**
    ///
    /// Both halves in one test, because `reads == 0` on its own is satisfied by a harness that never
    /// wakes, by a watchdog that returns early, and by a mode that does not exist. The hold-to-talk
    /// run is the positive control: same harness, same number of wakes, same seam, one read each.
    ///
    /// And the toggle run must still be *doing* something with each wake, or "no reads" is being
    /// bought by a branch that returns before the tick — which is the mutation that removes the
    /// ceiling. `elapsed` moving at the poll cadence is what says the wake did its remaining job.
    func testThePhysicalKeyIsNeverReadInToggleModeAndIsReadOnEveryWakeInHoldToTalk() {
        let wakeCount = 200

        let held = WatchdogHarness(configuration: chord)
        XCTAssertEqual(held.pressHotkey(), .started)
        held.run(steps: wakeCount)
        XCTAssertEqual(
            held.keyState.reads, wakeCount,
            "The control did not poll, so `reads == 0` below is not evidence of anything.")
        XCTAssertEqual(held.keyState.keysAsked, [space])
        XCTAssertEqual(held.machine.state, .recording)

        let toggled = WatchdogHarness(configuration: toggleChord)
        XCTAssertEqual(toggled.tapHotkey(), .started)
        toggled.run(steps: wakeCount)

        XCTAssertEqual(
            toggled.keyState.reads, 0,
            """
            The physical key was read \(toggled.keyState.reads) times during a toggle session. The \
            key is up for the whole session, so the first of those readings ends it — toggle mode \
            lasts one poll interval if rule (f) is applied to it.
            """)
        XCTAssertEqual(toggled.keyState.keysAsked, [])
        XCTAssertEqual(toggled.machine.state, .recording, "The toggle session ended on its own.")
        XCTAssertTrue(toggled.source.isOpen)
        XCTAssertEqual(
            toggled.machine.elapsed, WatchdogPolicy.pollInterval * wakeCount,
            """
            The toggle wake made no system call and also advanced nothing, so it is returning \
            before the tick — which is not "rule (f) does not apply here", it is "the ceiling does \
            not apply here either", and the ceiling is all this mode has.
            """)
        XCTAssertEqual(toggled.hotMicWindow, .zero, "The user is still asking; nothing is hot.")
    }

    // MARK: - The other half of the binding

    /// **The chord is polled too, and it is polled exactly where the key is.**
    ///
    /// Stop rule (f) asks *is the user still holding the binding?* and a binding is a key code and a
    /// chord. `hotkey-source` phase 5 added the second read (`CGEventSourceFlagsState`); this is the
    /// count that says it is actually made, in the mode that has the rule and not in the mode that
    /// does not.
    func testTheChordIsPolledWhereverTheKeyIs() {
        let wakeCount = 200

        let held = WatchdogHarness(configuration: chord)
        XCTAssertEqual(held.pressHotkey(), .started)
        held.run(steps: wakeCount)

        XCTAssertEqual(
            held.keyState.modifierReads, wakeCount,
            """
            The chord was read \(held.keyState.modifierReads) times across \(wakeCount) wakes. Every \
            wake that reads the key must read the chord too, or a modifier release whose \
            `.flagsChanged` never arrived stays invisible until the key itself comes up.
            """)
        XCTAssertEqual(held.machine.state, .recording, "nothing should have ended — the user is holding it")

        let toggled = WatchdogHarness(configuration: toggleChord)
        XCTAssertEqual(toggled.tapHotkey(), .started)
        toggled.run(steps: wakeCount)
        XCTAssertEqual(
            toggled.keyState.modifierReads, 0,
            """
            The chord was read during a toggle session. The key is up and the chord is released for \
            the whole of one — that is the mode — so a poll of either ends it on the first wake.
            """)
    }

    /// **The case the second read exists for, with the number it costs when it is missing.**
    ///
    /// The user lifts Option while Space is still down, and the `.flagsChanged` that would have
    /// applied stop rule (b) never arrives — `spec.md:35` names a dropped event as an ordinary
    /// occurrence, and `SessionRules.swift:39-42` records the same fact as the reason modifier state
    /// is derived rather than accumulated. The chord read closes it within one poll interval.
    ///
    /// The control is the same run with the key read alone doing the work: the session then survives
    /// every one of 700 wakes, because `isKeyDown(Space)` goes on answering `true` for as long as the
    /// finger is on the key. That is the measurement — **150 ms against 105 s** — and it is why this
    /// is a correctness fix with a bounded residual rather than an unbounded hot mic: the session
    /// would still have ended when Space came up.
    func testAChordReleasedWithNoEventEndsTheSessionWithinOnePollInterval() throws {
        let harness = WatchdogHarness(configuration: chord)
        XCTAssertEqual(harness.pressHotkey(), .started)
        harness.run(steps: 10)
        XCTAssertEqual(harness.machine.state, .recording)

        // Option comes up. The key stays down, and the tap never delivers the flagsChanged.
        harness.keyboard.heldModifiers = []

        harness.run(steps: 1)

        XCTAssertEqual(
            harness.machine.state, .idle,
            """
            The chord was released with no event and the session is still recording. Until phase 5 \
            this ran until the key itself came up — for as long as the user kept their finger down, \
            with Vocca recording a chord nobody is holding.
            """)
        XCTAssertFalse(harness.source.isOpen, "hot mic")
        XCTAssertEqual(
            harness.outcomes.compactMap { outcome -> RetainedEndReason? in
                switch outcome.content {
                case .completed(let reason, _, _): return reason
                case .cancelled: return nil
                }
            },
            [.pollDetectedRelease],
            """
            The reason is `.pollDetectedRelease` and deliberately not `.modifierReleased`: those two \
            mean *Vocca was told* and *Vocca had to ask*, and the log is the only evidence anyone \
            ever gets that events are being dropped.
            """)
        XCTAssertEqual(
            harness.hotMicWindow, WatchdogPolicy.pollInterval,
            """
            The microphone stayed open past the user's release for \
            \(milliseconds(harness.hotMicWindow)) ms. One poll interval is the bound rule (f) buys; \
            anything more means the chord is not being read.
            """)
    }

    /// The second read is skipped once the key is already up — and the skip is deliberate.
    ///
    /// `theBindingIsStillHeld` short-circuits, because a released key ends the session on its own and
    /// `CGEventSourceFlagsState` is a system call that would otherwise be made 800 times a session
    /// for an answer that changes nothing. Pinned so that the asymmetry between the two counters
    /// reads as the design rather than as a gap in the assertions.
    func testTheChordIsNotReadOnceTheKeyIsAlreadyUp() {
        let harness = WatchdogHarness(configuration: chord)
        XCTAssertEqual(harness.pressHotkey(), .started)
        harness.run(steps: 4)
        XCTAssertEqual(harness.keyState.reads, 4)
        XCTAssertEqual(harness.keyState.modifierReads, 4)

        harness.keyboard.release(space)
        harness.run(steps: 1)

        XCTAssertEqual(harness.keyState.reads, 5, "the key must still be read on the ending wake")
        XCTAssertEqual(
            harness.keyState.modifierReads, 4,
            """
            The chord was read on a wake where the key was already up. The answer cannot change the \
            outcome there, and in production that is a `CGEventSourceFlagsState` call per wake spent \
            for nothing.
            """)
    }

    /// **Containment, not equality, and locks masked from both sides** — the same comparison
    /// `SessionRules` makes for stop rules (b)/(c), because it is the same question.
    ///
    /// Both halves have a user-visible failure. Equality ends the session because someone reached for
    /// Shift mid-sentence. An unmasked comparison ends it the moment Caps Lock comes on, which is the
    /// one extra modifier `ModifierSet.locking` exists to forgive.
    func testAnExtraModifierAndCapsLockDoNotEndTheSession() {
        for extra: ModifierSet in [[.shift], [.capsLock], [.shift, .capsLock], [.command]] {
            let harness = WatchdogHarness(configuration: chord)
            XCTAssertEqual(harness.pressHotkey(), .started)

            harness.keyboard.heldModifiers = chord.modifiers.union(extra)
            harness.run(steps: 3)

            XCTAssertEqual(
                harness.machine.state, .recording,
                """
                Holding \(extra) as well as the binding ended the session. The poll asks whether the \
                user is *still holding what they pressed*, which is containment — an added modifier \
                is not a release, and reporting one as `.pollDetectedRelease` would be false about \
                what happened as well as unwelcome.
                """)
            XCTAssertTrue(harness.source.isOpen)
        }
    }

    /// **The lock mask, in the direction that actually needs it** — the configuration's side.
    ///
    /// Measured as a surviving mutant first: dropping `.subtracting(.locking)` from *both* sides of
    /// the poll's comparison passed the whole suite, because every test held the chord plus at most
    /// an extra lock, and an extra bit is invisible to containment. The mask only bites when the
    /// **binding** names a lock and the hardware does not report it — which is exactly the case
    /// `ModifierSet.locking` documents: *"A configuration naming Caps Lock is then simply ignored
    /// rather than becoming a hotkey that only works with Caps Lock on."*
    ///
    /// Unmasked, such a session ends on its very first wake, 150 ms after the user started talking,
    /// reported as `.pollDetectedRelease` for a key nobody released.
    func testABindingThatNamesALockIsNotEndedByTheLockBeingOff() throws {
        let bindingNamingALock = HotkeyConfiguration(
            keyCode: space, modifiers: [.option, .capsLock], activation: .holdToTalk)
        let harness = WatchdogHarness(configuration: bindingNamingALock)

        XCTAssertEqual(harness.pressHotkey(), .started)
        // The user is holding Option and Space. Caps Lock is off, as it usually is.
        harness.keyboard.heldModifiers = [.option]
        harness.run(steps: 3)

        XCTAssertEqual(
            harness.machine.state, .recording,
            """
            A binding naming Caps Lock was ended by the poll because Caps Lock is off. Locks are \
            masked from *both* sides before the comparison — the configuration's as well as the \
            hardware's — or a user who configured one has a hotkey that starts and then dies within \
            one poll interval, every time.
            """)
        XCTAssertTrue(harness.source.isOpen)
        XCTAssertEqual(harness.hotMicWindow, .zero)
    }

    /// **What rule (f) is worth, measured in both modes side by side.**
    ///
    /// The same accident in each: the user asks for the session to end and Vocca never hears it.
    /// In hold-to-talk the key is physically up afterwards, so the poll finds it within one
    /// interval. In toggle the world looks *identical* before and after the press — that is what a
    /// press is — so nothing finds it, and the microphone stays open until the ceiling.
    ///
    /// The numbers are the deliverable of this task and are asserted exactly, not as inequalities:
    /// **one poll interval (150 ms) against 700 of them (105 s)**, with the session started at the
    /// same wake in both runs. An implementation that quietly polls in toggle fails here; so does
    /// one that quietly drops the ceiling.
    func testALostStoppingGestureCostsOneIntervalInHoldToTalkAndTheRestOfTheCeilingInToggle() throws {
        let deadline = wakes(covering: SessionCeiling.default)
        let lostAt = 100

        // Hold-to-talk: the key comes up and no event arrives.
        let held = WatchdogHarness(configuration: chord)
        XCTAssertEqual(held.pressHotkey(), .started)
        held.run(steps: lostAt)
        held.releaseHotkeyUnobserved()
        let heldOutcome = try endedOutcome(held.step(), "one interval after the key came up")
        XCTAssertEqual(
            try reasonCarryingTheAudio(heldOutcome, from: held.source), .pollDetectedRelease)
        XCTAssertEqual(
            held.hotMicWindow, WatchdogPolicy.pollInterval,
            "Hold-to-talk's bound is one poll interval, and it moved.")

        // Toggle: the user presses again and Vocca never sees it. Nothing about the world differs
        // from a user who is still talking.
        let toggled = WatchdogHarness(configuration: toggleChord)
        XCTAssertEqual(toggled.tapHotkey(), .started)
        toggled.run(steps: lostAt)
        toggled.tapHotkeyUnobserved()
        XCTAssertTrue(
            toggled.source.isOpen,
            "Premise: nothing has told Vocca, so it cannot yet have acted.")

        var wake = lostAt
        var ended: SessionOutcome<RecordingSource.Buffer>?
        // Bounded by a `while` condition rather than an assertion inside the loop: XCTAssert records
        // and carries on, so a policy that never ends the session would hang rather than fail.
        while ended == nil && wake <= deadline + 1 {
            wake += 1
            switch toggled.step() {
            case .ended(let outcome): ended = outcome
            case .unchanged, .started, .captureUnavailable, .opening: break
            }
        }
        XCTAssertNotNil(
            ended,
            """
            A toggle session whose stopping press was lost never ended at all. The ceiling is the \
            only unconditional backstop this mode has; without it the microphone is open until the \
            process exits.
            """)
        XCTAssertEqual(
            wake, deadline,
            "The toggle session ended at wake \(wake) rather than at the ceiling's \(deadline).")
        XCTAssertEqual(
            try reasonCarryingTheAudio(try XCTUnwrap(ended), from: toggled.source), .ceilingReached)
        XCTAssertFalse(toggled.source.isOpen)

        // The number, exactly: from the lost press to the ceiling.
        XCTAssertEqual(
            toggled.hotMicWindow, WatchdogPolicy.pollInterval * (deadline - lostAt),
            "Toggle's worst-case hot mic is the ceiling minus however long the user had already "
                + "been talking, and it moved.")
        XCTAssertEqual(toggled.hotMicWindow, .seconds(105))
        XCTAssertEqual(
            milliseconds(toggled.hotMicWindow) / milliseconds(held.hotMicWindow), 700,
            """
            The gap between the two modes' worst cases is 700 poll intervals. This is not a bug in \
            either of them — it is the price of a mode with no physical fact behind it, and it is \
            asserted so that a later change which appears to close it has to say how.
            """)
    }

    /// **A stalled clock costs hold-to-talk one poll interval and costs toggle everything.**
    ///
    /// Task 5 established that a `MonotonicClock` whose readings stop advancing does not delay the
    /// ceiling, it removes it — while every other mechanism goes on looking healthy — and bounded
    /// the damage by measuring the half that still works: the poll reads no clock, so hold-to-talk
    /// still ends the session the moment the key comes up.
    ///
    /// **Toggle has no such half.** With rule (f) gone, the ceiling is the only unconditional
    /// backstop, and a stalled clock is precisely the failure that removes it. So this is the one
    /// residual worth naming out loud rather than leaving to a report: two things in the layer
    /// outside this module — the owner's timer firing, and the injected clock advancing — carry a
    /// toggle session's entire guarantee, and if either gives way nothing inside `VoccaCore`
    /// notices.
    ///
    /// Both runs here share the same stall and differ only in mode, so the difference is measured.
    /// The end of the test is what a toggle user is actually left with: a system trigger, or Escape.
    func testAStalledClockCostsHoldToTalkOneIntervalAndCostsToggleItsOnlyBackstop() throws {
        let stalled = 10_000  // 25 minutes of real time at the policy cadence, twelve ceilings.

        // Hold-to-talk under the stall: the poll still ends it one interval after the key comes up.
        let held = WatchdogHarness(configuration: chord)
        XCTAssertEqual(held.pressHotkey(), .started)
        for _ in 0..<stalled { _ = held.stepWithoutTheClockAdvancing() }
        XCTAssertEqual(held.machine.elapsed, .zero, "The clock stalled; nothing may accumulate.")
        XCTAssertEqual(held.machine.state, .recording, "Premise: the ceiling is gone in both runs.")
        held.releaseHotkeyUnobserved()
        let heldOutcome = try endedOutcome(
            held.stepWithoutTheClockAdvancing(), "the poll reads no clock and must still fire")
        XCTAssertEqual(
            try reasonCarryingTheAudio(heldOutcome, from: held.source), .pollDetectedRelease)
        XCTAssertEqual(held.hotMicWindow, WatchdogPolicy.pollInterval)

        // Toggle under the same stall: nothing recovers it, however long it runs.
        let toggled = WatchdogHarness(configuration: toggleChord)
        XCTAssertEqual(toggled.tapHotkey(), .started)
        for _ in 0..<stalled { _ = toggled.stepWithoutTheClockAdvancing() }
        XCTAssertEqual(toggled.machine.elapsed, .zero)
        XCTAssertEqual(toggled.machine.state, .recording)
        XCTAssertEqual(toggled.keyState.reads, 0, "The toggle wake made a system call after all.")

        toggled.tapHotkeyUnobserved()
        for _ in 0..<stalled { _ = toggled.stepWithoutTheClockAdvancing() }
        XCTAssertTrue(
            toggled.source.isOpen,
            """
            The premise of this test is gone — something other than the ceiling ended a toggle \
            session under a stalled clock. That would be good news, and it would mean the residual \
            named here has a mechanism behind it that should be documented rather than discovered.
            """)
        XCTAssertEqual(toggled.machine.state, .recording)
        XCTAssertEqual(
            toggled.hotMicWindow, WatchdogPolicy.pollInterval * stalled,
            "Twenty-five minutes of microphone after the user asked for it to stop.")
        XCTAssertGreaterThan(toggled.hotMicWindow, SessionCeiling.default)
        XCTAssertGreaterThan(
            milliseconds(toggled.hotMicWindow) / milliseconds(held.hotMicWindow), 9_000,
            "The gap between the two modes under a stalled clock is at least four orders of "
                + "magnitude, and it is unbounded rather than merely large.")

        // What the toggle user is left with. Both of these read no clock, so both still work — and
        // they are the whole list.
        let outcome = try endedOutcome(toggled.watchdog.observe(.willSleep))
        XCTAssertEqual(
            try reasonCarryingTheAudio(outcome, from: toggled.source), .systemEvent(.willSleep))
        XCTAssertFalse(toggled.source.isOpen)

        let escaped = WatchdogHarness(configuration: toggleChord)
        XCTAssertEqual(escaped.tapHotkey(), .started)
        for _ in 0..<100 { _ = escaped.stepWithoutTheClockAdvancing() }
        switch try endedOutcome(escaped.watchdog.cancel()).content {
        case .cancelled: break
        case .completed: XCTFail("Escape is the one path that discards, and it did not.")
        }
        XCTAssertFalse(escaped.source.isOpen, "Escape left the microphone open under a stalled clock.")
    }

    /// The widget's ceiling warning fires in toggle mode too — and it is the only warning this mode
    /// gives before its only backstop.
    ///
    /// In hold-to-talk the warning is a courtesy: the user is holding a key and knows they are
    /// recording. In toggle it is the compensating control for everything above — a user who
    /// pressed to stop and was not heard has ten seconds of it before the session is cut off,
    /// and that is the whole of their warning.
    func testTheCeilingWarningStillFiresInToggleMode() throws {
        let harness = WatchdogHarness(configuration: toggleChord)
        let threshold = WatchdogPolicy.warningThreshold(before: SessionCeiling.default)
        XCTAssertEqual(harness.watchdog.warningThreshold, threshold)
        XCTAssertFalse(harness.watchdog.ceilingIsNear, "Warned with no session running.")

        XCTAssertEqual(harness.tapHotkey(), .started)
        // 110 s is not a whole number of 150 ms intervals, so the last wake below the threshold is
        // the `covering`th. Computed rather than written as a literal, exactly as the hold-to-talk
        // twin does, so a changed cadence moves both together instead of failing here.
        let covering = wakes(covering: threshold)
        let landsOnAWake = WatchdogPolicy.pollInterval * covering == threshold
        harness.run(steps: landsOnAWake ? covering - 1 : covering)
        XCTAssertLessThan(harness.machine.elapsed, threshold)
        XCTAssertFalse(
            harness.watchdog.ceilingIsNear, "Warned at \(harness.machine.elapsed) of a 120 s ceiling.")

        harness.run(steps: 1)
        XCTAssertGreaterThanOrEqual(harness.machine.elapsed, threshold)
        XCTAssertTrue(
            harness.watchdog.ceilingIsNear,
            "No warning at \(harness.machine.elapsed) — the user gets no notice at all before the "
                + "one backstop this mode has ends their session.")

        // A warning is not a stop.
        XCTAssertEqual(harness.machine.state, .recording)
        XCTAssertTrue(harness.source.isOpen)
        XCTAssertTrue(harness.outcomes.isEmpty)

        // And it clears when the user toggles off.
        _ = try endedOutcome(harness.tapHotkey())
        XCTAssertFalse(harness.watchdog.ceilingIsNear)
        XCTAssertEqual(harness.watchdog.schedule, .stopped)
    }

    /// The stops toggle **does** keep, through the watchdog: a dead tap, each system trigger, and
    /// Escape — each ending the session with its own reason and settling the timer.
    ///
    /// Worth driving through the watchdog rather than trusting the machine's own tests: with rule
    /// (f) gone these are, together with the user's next press, the entire list of things that can
    /// end a toggle session before the ceiling. If one of them stopped working in this mode the
    /// list would be the ceiling alone.
    func testTheStopsToggleKeepsAllStillWorkThroughTheWatchdog() throws {
        // (d), the tap dying — which in toggle is the only stop a *dead tap* can still deliver,
        // since every other event-driven rule left in this mode needs an event that cannot arrive.
        let deadTap = WatchdogHarness(configuration: toggleChord)
        XCTAssertEqual(deadTap.tapHotkey(), .started)
        deadTap.run(steps: 10)
        let tapOutcome = try endedOutcome(deadTap.feed(event(.tapDisabled, 0, [])).effect)
        XCTAssertEqual(
            try reasonCarryingTheAudio(tapOutcome, from: deadTap.source), .tapDisabled)
        XCTAssertFalse(deadTap.source.isOpen)
        XCTAssertEqual(deadTap.watchdog.schedule, .stopped)

        // Every system trigger.
        for trigger in SystemTrigger.allCases {
            let harness = WatchdogHarness(configuration: toggleChord)
            XCTAssertEqual(harness.tapHotkey(), .started, "\(trigger)")
            harness.run(steps: 10)

            let outcome = try endedOutcome(harness.watchdog.observe(trigger), "\(trigger)")
            XCTAssertEqual(
                try reasonCarryingTheAudio(outcome, from: harness.source, "\(trigger)"),
                .systemEvent(trigger),
                "\(trigger) was logged as something else — the log is the only evidence anyone gets.")
            XCTAssertFalse(harness.source.isOpen, "\(trigger) left the microphone open.")
            XCTAssertEqual(
                harness.watchdog.schedule, .stopped,
                "\(trigger) ended the toggle session and left the timer running.")

            let readsBefore = harness.keyState.reads
            harness.run(steps: 5)
            XCTAssertEqual(
                harness.outcomes.count, 0,
                "\(trigger) produced a second outcome from the timer after ending the session.")
            XCTAssertEqual(harness.keyState.reads, readsBefore)
            XCTAssertEqual(harness.hotMicWindow, .zero, "\(trigger)")
        }

        // Escape: the audio is discarded, which is what the user asked for; the microphone is not.
        let cancelled = WatchdogHarness(configuration: toggleChord)
        XCTAssertEqual(cancelled.tapHotkey(), .started)
        cancelled.run(steps: 3)
        switch try endedOutcome(cancelled.watchdog.cancel()).content {
        case .completed: XCTFail("Escape is the one path that discards, and it did not.")
        case .cancelled: break
        }
        XCTAssertFalse(
            cancelled.source.isOpen,
            "Escape discarded the transcript and left the microphone open — and in toggle mode "
                + "nothing but the ceiling would have closed it.")
        XCTAssertEqual(cancelled.watchdog.schedule, .stopped)

        // And a cancelled toggle machine is not wedged: the next tap arms it again.
        XCTAssertEqual(cancelled.tapHotkey(), .started)
        XCTAssertEqual(cancelled.watchdog.schedule, .wake(every: WatchdogPolicy.pollInterval))
    }

    /// **An event the machine passes through still reaches the application — in toggle, through the
    /// wrapper.**
    ///
    /// The same blast radius as the hold-to-talk twin above, and a fresh chance to get it wrong:
    /// this is new code on the same seam, and toggle is the mode where the tempting mistake —
    /// "Vocca owns its hotkey while a session is in flight" — costs the user their space bar for
    /// two minutes at a time rather than for as long as a finger rests on it.
    func testAnEventTheMachinePassesThroughStillReachesTheApplicationInToggleMode() throws {
        let harness = WatchdogHarness(configuration: toggleChord)

        // Idle: every key the user types all day.
        XCTAssertEqual(
            harness.feed(event(.keyDown, letterA, [])).eventPropagation, .passThrough,
            "Vocca swallowed an unrelated keystroke while idle — every key the user types, gone.")

        // The gesture itself is swallowed, in both directions of the toggle.
        let on = harness.tapHotkey()
        XCTAssertEqual(on, .started)

        // Recording, with nothing held: the user's whole keyboard is still theirs, *including* the
        // hotkey's own key code without its chord.
        XCTAssertEqual(
            harness.feed(event(.keyDown, letterA, [])).eventPropagation, .passThrough,
            "Vocca swallowed an unrelated keystroke during a toggle session.")
        XCTAssertEqual(
            harness.feed(event(.keyDown, space, [])).eventPropagation, .passThrough,
            "Vocca ate the user's space bar for the length of a toggle session.")
        XCTAssertEqual(
            harness.feed(event(.keyUp, space, [])).eventPropagation, .passThrough)
        XCTAssertEqual(
            harness.feed(event(.flagsChanged, space, [.option])).eventPropagation, .passThrough,
            "Vocca swallowed a modifier event, stranding the app's idea of what is held.")
        XCTAssertEqual(
            harness.machine.state, .recording,
            "One of those events ended a toggle session that only a press may end.")

        // And the press that does end it is Vocca's, so the application hears nothing of it.
        let press = harness.watchdog.observe(event(.keyDown, space, [.option]))
        XCTAssertEqual(
            press.eventPropagation, .swallow,
            "The toggle-off press reached the application — a character typed into the field the "
                + "transcript is about to be injected into.")
        let outcome = try endedOutcome(press.effect)
        XCTAssertEqual(try reasonCarryingTheAudio(outcome, from: harness.source), .toggledOff)
        XCTAssertEqual(
            harness.watchdog.observe(event(.keyUp, space, [.option])).eventPropagation, .swallow,
            "The key-up of a press Vocca swallowed reached the app unpaired.")
    }

    // MARK: - The machine's strangest legal behaviour

    /// A session that lived and died **inside one key-down** leaves the watchdog nothing to watch.
    ///
    /// The stop that arrives while the microphone is opening is applied before `beginSession`
    /// returns, so the caller sees `.ended` from the key-down and that session's `.started` is
    /// never observed by anybody. A watchdog that armed on `.started` and disarmed on `.ended`
    /// would have to handle that on purpose; this one derives everything from the machine's state,
    /// so there is nothing to handle.
    func testASessionThatLivedAndDiedInsideOneKeyDownLeavesNothingToWatch() throws {
        let harness = WatchdogHarness()
        let watchdog = harness.watchdog
        let keyboard = harness.keyboard

        keyboard.hold(harness.configuration)
        harness.source.duringBeginCapture = {
            // The key comes back up while `AVAudioEngine.start()` is still working, and the queued
            // event is delivered underneath it — through the watchdog, because that is where the
            // owner's tap callback delivers everything, re-entrant or not.
            keyboard.release(space)
            _ = watchdog.observe(event(.keyUp, space, [.option]))
        }

        let effect = watchdog.observe(event(.keyDown, space, [.option])).effect
        let outcome = try endedOutcome(
            effect,
            "The premise of this test is gone: a key-down no longer reports `.ended` directly, so "
                + "the case the watchdog must not assume away no longer exists.")
        XCTAssertEqual(try reasonCarryingTheAudio(outcome, from: harness.source), .keyUp)
        XCTAssertEqual(harness.machine.state, .idle)
        XCTAssertFalse(harness.source.isOpen)
        XCTAssertEqual(harness.source.endCount, 1)

        XCTAssertEqual(
            harness.watchdog.schedule, .stopped,
            "The watchdog is watching a session that never visibly started and has already ended.")
        XCTAssertFalse(harness.watchdog.ceilingIsNear)

        harness.run(steps: 20)
        XCTAssertEqual(harness.keyState.reads, 0, "The poll ran against a session that is over.")
        XCTAssertTrue(harness.outcomes.isEmpty, "A second outcome came out of a dead session.")
        XCTAssertEqual(harness.hotMicWindow, .zero)
        XCTAssertEqual(harness.source.endCount, 1, "The microphone was closed twice.")

        // And nothing is wedged: the next session is ordinary, and its poll works.
        XCTAssertEqual(harness.pressHotkey(), .started)
        XCTAssertEqual(harness.watchdog.schedule, .wake(every: WatchdogPolicy.pollInterval))
        harness.releaseHotkeyUnobserved()
        let second = try endedOutcome(harness.step())
        XCTAssertEqual(
            try reasonCarryingTheAudio(second, from: harness.source), .pollDetectedRelease)
        XCTAssertEqual(harness.hotMicWindow, WatchdogPolicy.pollInterval)
    }
}
