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

private let chord = HotkeyConfiguration(
    keyCode: space, modifiers: [.option], activation: .holdToTalk)
private let bareKey = HotkeyConfiguration(
    keyCode: functionKey, modifiers: [], activation: .holdToTalk)

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

/// The physical keyboard, as a **fact**.
///
/// The distinction this whole file turns on: what the hardware is doing is one thing, what Vocca has
/// been *told* is another, and the gap between them is the defect. The hot-mic meter reads this; the
/// watchdog only ever reads it through the injected seam. That is what lets a test hand the watchdog
/// a seam that lies and still measure the truth.
private final class Keyboard {
    private(set) var held: Set<UInt16> = []

    func press(_ keyCode: UInt16) { held.insert(keyCode) }
    func release(_ keyCode: UInt16) { held.remove(keyCode) }
    func isHeld(_ keyCode: UInt16) -> Bool { held.contains(keyCode) }
}

/// A reader that counts, so that "the poll ran and ended nothing" is distinguishable from "the poll
/// stopped running" — which are the same green suite otherwise.
private protocol CountingKeyStateReader: PhysicalKeyStateReader {
    var reads: Int { get }
    var keysAsked: Set<UInt16> { get }
}

/// The seam, reading the keyboard truthfully. What `hotkey-source` will implement over
/// `CGEventSourceKeyState`.
private final class TruthfulKeyState: CountingKeyStateReader {
    private let keyboard: Keyboard
    private(set) var reads = 0
    private(set) var keysAsked: Set<UInt16> = []

    init(_ keyboard: Keyboard) { self.keyboard = keyboard }

    func isKeyDown(_ keyCode: UInt16) -> Bool {
        reads += 1
        keysAsked.insert(keyCode)
        return keyboard.isHeld(keyCode)
    }
}

/// A seam that never reports a release — **the world before this task**, and the positive control.
///
/// Not a straw man: it is exactly what a poll that is never run, run against the wrong key code, or
/// answered from a stale event log looks like from the machine's side. Everything else about a
/// harness built on it is identical, so a measurement that cannot tell the two apart is measuring
/// nothing.
private final class KeyAlwaysReportedDown: CountingKeyStateReader {
    private(set) var reads = 0
    private(set) var keysAsked: Set<UInt16> = []

    func isKeyDown(_ keyCode: UInt16) -> Bool {
        reads += 1
        keysAsked.insert(keyCode)
        return true
    }
}

/// Milliseconds, for arithmetic `Duration` will not do directly.
private func milliseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
}

/// How many wakes it takes to cover `duration` at the watchdog's cadence, rounded down.
private func wakes(covering duration: Duration) -> Int {
    Int(milliseconds(duration) / milliseconds(WatchdogPolicy.pollInterval))
}

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
    /// hotkey was not physically held.
    ///
    /// `PRODUCT_SPEC.md:11` — "there is no state where Vocca is listening and doesn't look like it"
    /// — in a number. Measured against the ``Keyboard`` and the ``RecordingSource`` ledger, never
    /// against anything the machine or the watchdog reports about itself.
    private(set) var hotMicWindow: Duration = .zero

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

    /// The user presses the hotkey, and the tap delivers it.
    @discardableResult
    func pressHotkey() -> Effect {
        keyboard.press(configuration.keyCode)
        return machine.observe(
            event(.keyDown, configuration.keyCode, configuration.modifiers)
        ).effect
    }

    /// The user lets go **and the key-up is delivered**. The ordinary ending.
    @discardableResult
    func releaseHotkey() -> Effect {
        keyboard.release(configuration.keyCode)
        return machine.observe(event(.keyUp, configuration.keyCode, configuration.modifiers)).effect
    }

    /// The user lets go and **no event ever arrives**: the hotkey was stolen, the tap stalled,
    /// focus moved mid-press, the OS dropped it.
    ///
    /// This is the shape nothing else in this aspect can see. Every other stop rule is driven by an
    /// event, and there is no event.
    func releaseHotkeyUnobserved() {
        keyboard.release(configuration.keyCode)
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
        let hot = source.isOpen && !keyboard.isHeld(configuration.keyCode)
        let elapsing = interval
        clock.now += elapsing
        forwardTime += elapsing
        if hot { hotMicWindow += elapsing }

        let effect = watchdog.wake()
        switch effect {
        case .ended(let outcome): outcomes.append(outcome)
        case .unchanged, .started, .captureUnavailable: break
        }
        return effect
    }

    func run(steps: Int) {
        for _ in 0..<steps { _ = step() }
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
            case .unchanged, .started, .captureUnavailable: break
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
            case .unchanged, .started, .captureUnavailable: break
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
        let machine = harness.machine
        let keyboard = harness.keyboard

        keyboard.press(space)
        harness.source.duringBeginCapture = {
            // The key comes back up while `AVAudioEngine.start()` is still working, and the queued
            // event is delivered underneath it.
            keyboard.release(space)
            _ = machine.observe(event(.keyUp, space, [.option]))
        }

        let effect = machine.observe(event(.keyDown, space, [.option])).effect
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
