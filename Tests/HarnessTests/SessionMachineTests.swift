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
/// `A`. Any key that is not the configured one.
private let letterA: UInt16 = 0

private let chord = HotkeyConfiguration(
    keyCode: space, modifiers: [.option], activation: .holdToTalk)

private func event(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet,
    autorepeat: Bool = false
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: autorepeat,
        // Deliberately constant. The machine reads its injected clock and never an event's
        // timestamp; if a test could steer the ceiling by moving this, the two timebases would be
        // one, and mixing them is the defect this pins shut.
        timestamp: .zero)
}

/// A clock the test moves by hand. Instant, deterministic, and monotonic unless a test says
/// otherwise — one of them deliberately runs it backwards.
private final class TestClock: MonotonicClock {
    var now: Duration = .zero
}

/// The microphone, as the session machine is allowed to know it: open it, close it, take what it
/// captured.
///
/// It is a **ledger**, and that is the point. "The session ended" is not "the microphone was
/// released" — `project-skeleton`'s final review earned that distinction with a defect that shipped
/// past a green suite — so every assertion below about custody or about a hot mic is made against
/// what this recorded, never against a call the machine is believed to have made.
///
/// Each buffer it hands out is unique (`session:` is the close count), so an outcome carrying "a"
/// buffer and an outcome carrying **this session's** buffer are distinguishable. Without that, a
/// machine that swapped in a fresh empty buffer would pass every custody test in this file.
private final class RecordingSource: SessionAudioSource {
    struct Buffer: CapturedAudio, Equatable {
        let session: Int
        let frames: [Int]
    }

    private(set) var isOpen = false
    private(set) var beginCount = 0
    private(set) var endCount = 0
    /// `beginCapture()` while already open. B1's "0 overlapping", measured rather than assumed.
    private(set) var overlappingBegins = 0
    /// `endCapture()` while closed — a close with no open, which is the other half of "0 orphaned".
    private(set) var closesWithoutOpen = 0
    private(set) var handedOut: [Buffer] = []

    /// What the next `beginCapture()` reports. The microphone can genuinely refuse to open.
    var nextStart: CaptureStart = .opened

    /// Run from *inside* `endCapture()`, while the machine is mid-handoff. This is how re-entrancy
    /// is tested: stopping a real engine can pump a run loop and deliver a queued key event straight
    /// back into the machine.
    ///
    /// Fired once and then cleared, like ``duringBeginCapture``. Both hooks are one-shot for the
    /// same measured reason: a machine that honours a stop while `.ending` re-enters this method
    /// from inside itself, and with a repeating hook that is an unbounded recursion — the suite goes
    /// red with `signal 11` instead of naming the invariant that broke.
    var duringEndCapture: (() -> Void)?

    /// The same, for the other transition. `AVAudioEngine.start()` is the one that actually takes
    /// milliseconds, so it is the likelier of the two to have an event arrive underneath it. Fired
    /// once and then cleared, because a hook that re-enters the call it is inside of would recurse
    /// forever if the machine let it — which is the failure being tested, not a way to test it.
    var duringBeginCapture: (() -> Void)?

    func beginCapture() -> CaptureStart {
        if isOpen { overlappingBegins += 1 }
        guard nextStart == .opened else { return .unavailable }
        beginCount += 1
        isOpen = true
        let hook = duringBeginCapture
        duringBeginCapture = nil
        hook?()
        return .opened
    }

    func endCapture() -> Buffer {
        if !isOpen { closesWithoutOpen += 1 }
        endCount += 1
        isOpen = false
        let hook = duringEndCapture
        duringEndCapture = nil
        hook?()
        let buffer = Buffer(session: endCount, frames: Array(repeating: endCount, count: 3))
        handedOut.append(buffer)
        return buffer
    }
}

private typealias Effect = SessionEffect<RecordingSource.Buffer>

/// A machine, its clock, its microphone ledger — and a model of the focused application.
///
/// The application model is what makes the pass-through half of this aspect testable: it consumes
/// exactly the events the machine let through, so "a character reached the field the transcript is
/// about to be injected into" and "the app was left holding a key down" are both properties of
/// something observed, not of something argued.
private final class Harness {
    let clock: TestClock
    let source: RecordingSource
    let machine: SessionMachine<RecordingSource.Buffer>
    let configuration: HotkeyConfiguration

    /// Every event the machine passed through, in order — the focused application's whole input.
    private(set) var appSaw: [RawKeyEvent] = []

    init(configuration: HotkeyConfiguration = chord, ceiling: Duration = SessionCeiling.default) {
        let clock = TestClock()
        let source = RecordingSource()
        self.clock = clock
        self.source = source
        self.configuration = configuration
        self.machine = SessionMachine(
            configuration: configuration, ceiling: ceiling, clock: clock, audioSource: source)
    }

    @discardableResult
    func feed(_ event: RawKeyEvent) -> SessionResponse<RecordingSource.Buffer> {
        let response = machine.observe(event)
        switch response.eventPropagation {
        case .passThrough: appSaw.append(event)
        case .swallow: break
        }
        return response
    }

    // MARK: The ordinary gestures

    @discardableResult
    func pressHotkey() -> Effect {
        feed(event(.keyDown, configuration.keyCode, configuration.modifiers)).effect
    }

    @discardableResult
    func releaseHotkey() -> Effect {
        feed(event(.keyUp, configuration.keyCode, configuration.modifiers)).effect
    }

    /// The user lets go of Option while still resting on Space — stop rule (b), and the single
    /// likeliest cause of a stuck recording.
    @discardableResult
    func releaseModifier() -> Effect {
        feed(event(.flagsChanged, configuration.keyCode, [])).effect
    }

    /// One OS autorepeat of the held hotkey, carrying whatever modifiers are still down.
    @discardableResult
    func autorepeat(modifiers: ModifierSet) -> SessionResponse<RecordingSource.Buffer> {
        feed(event(.keyDown, configuration.keyCode, modifiers, autorepeat: true))
    }

    @discardableResult
    func tapDies() -> Effect {
        feed(event(.tapDisabled, 0, [])).effect
    }

    func advance(_ interval: Duration) {
        clock.now += interval
    }

    // MARK: The focused application, as it sees things

    /// The key codes the application believes are held: every key-down it saw, minus every key-up.
    ///
    /// A non-empty set at the end of a gesture is an **unpaired key-down** — a key the app thinks is
    /// still down, which is the worse half of the defect this phase exists to fix.
    var keysTheAppBelievesAreDown: Set<UInt16> {
        var down: Set<UInt16> = []
        for event in appSaw {
            switch event.kind {
            case .keyDown: down.insert(event.keyCode)
            case .keyUp: down.remove(event.keyCode)
            case .flagsChanged, .tapDisabled: break
            }
        }
        return down
    }

    /// Key-downs the application received for the hotkey's own key code. Each one is a character
    /// typed into the field the transcript is about to be injected into.
    var strayCharacters: Int {
        appSaw.filter { $0.kind == .keyDown && $0.keyCode == configuration.keyCode }.count
    }

    /// The microphone is open exactly when the machine says a session is recording.
    ///
    /// The whole hot-mic invariant in one predicate: `PRODUCT_SPEC.md:11` — "there is no state where
    /// Vocca is listening and doesn't look like it".
    var micAgreesWithState: Bool {
        switch machine.state {
        case .recording: return source.isOpen
        case .idle, .ending: return !source.isOpen
        }
    }
}

/// Unwraps the outcome of an effect that must have ended a session.
private func endedOutcome(
    _ effect: Effect, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) throws -> SessionOutcome<RecordingSource.Buffer> {
    switch effect {
    case .ended(let outcome):
        return outcome
    case .unchanged, .started, .captureUnavailable:
        XCTFail("Expected a session to end, got \(effect). \(message)", file: file, line: line)
        throw XCTSkip("no outcome")
    }
}

/// The state machine, and the two invariants it turns from types into behaviour.
///
/// 1. **A transcript is never lost.** Every terminal transition hands the buffer that session
///    captured downstream. Task 2 made discarding structurally hard; here it becomes a behaviour
///    that is measured against the microphone's own ledger.
/// 2. **A capture session never outlives the user's intent.** No path leaves the microphone open,
///    and no path leaves the focused application holding a key Vocca swallowed the press of.
final class SessionMachineTests: XCTestCase {

    // MARK: - The cycle

    func testAHoldCycleOpensAndClosesTheMicrophoneExactlyOnce() throws {
        let harness = Harness()

        XCTAssertEqual(harness.machine.state, .idle)
        XCTAssertEqual(harness.pressHotkey(), .started)
        XCTAssertEqual(harness.machine.state, .recording)
        XCTAssertTrue(harness.source.isOpen, "The hotkey went down and the microphone did not open.")

        let outcome = try endedOutcome(harness.releaseHotkey())
        XCTAssertEqual(harness.machine.state, .idle)
        XCTAssertFalse(harness.source.isOpen, "The key came up and the microphone stayed open.")
        XCTAssertEqual(harness.source.beginCount, 1)
        XCTAssertEqual(harness.source.endCount, 1)

        switch outcome.content {
        case .completed(let reason, let audio, _):
            XCTAssertEqual(reason, .keyUp)
            let carried: RecordingSource.Buffer = audio
            XCTAssertEqual(carried, try XCTUnwrap(harness.source.handedOut.last))
        case .cancelled:
            XCTFail("A key-up is not a cancellation: the audio it captured is owed downstream.")
        }
    }

    /// **B1**, and `CAPABILITY_ROADMAP.md:42`'s stated acceptance: 100 synthetic hold cycles at
    /// durations from 80 ms to 60 s — exactly 100 started, 100 ended, 0 overlapping, 0 orphaned.
    ///
    /// Realised over the seam rather than over a real event tap, because `CGEvent.tapCreate` returns
    /// `nil` without an Accessibility grant and no hosted runner can be granted one.
    ///
    /// Every count is read off ``RecordingSource``, not off the machine: the machine agreeing with
    /// itself is not evidence. The durations sweep the range because a ceiling that fired early
    /// would only show up on the long ones, and the interleaved `tick()` is what would let it.
    func testOneHundredSyntheticHoldCyclesEachStartAndEndExactlyOnce() throws {
        let harness = Harness()
        let cycles = 100
        var outcomes: [SessionOutcome<RecordingSource.Buffer>] = []

        for cycle in 0..<cycles {
            // 80 ms … 60 s, spread evenly. Both ends are the spec's, and both are well inside the
            // 120 s ceiling — a session ending for the ceiling here would be a defect, not a pass.
            let held = Duration.milliseconds(80 + (60_000 - 80) * cycle / (cycles - 1))

            XCTAssertEqual(harness.pressHotkey(), .started, "cycle \(cycle) did not start")
            XCTAssertTrue(harness.micAgreesWithState, "cycle \(cycle): mic out of step while held")

            harness.advance(held)
            XCTAssertEqual(harness.machine.tick(), .unchanged, "cycle \(cycle) ended early")

            outcomes.append(try endedOutcome(harness.releaseHotkey(), "cycle \(cycle)"))
            XCTAssertTrue(harness.micAgreesWithState, "cycle \(cycle): mic out of step after")
        }

        XCTAssertEqual(harness.source.beginCount, cycles, "not exactly 100 sessions started")
        XCTAssertEqual(harness.source.endCount, cycles, "not exactly 100 sessions ended")
        XCTAssertEqual(harness.source.overlappingBegins, 0, "two sessions were open at once")
        XCTAssertEqual(harness.source.closesWithoutOpen, 0, "a session was closed that never opened")
        XCTAssertFalse(harness.source.isOpen, "the microphone was left open — an orphaned session")
        XCTAssertEqual(harness.machine.state, .idle)

        // Each outcome carries *its own* session's buffer, in order. A machine that emitted the
        // same buffer 100 times, or a fresh empty one each time, fails here and nowhere else.
        XCTAssertEqual(outcomes.count, cycles)
        for (index, outcome) in outcomes.enumerated() {
            switch outcome.content {
            case .completed(let reason, let audio, _):
                XCTAssertEqual(reason, .keyUp)
                XCTAssertEqual(audio, harness.source.handedOut[index], "cycle \(index)")
            case .cancelled:
                XCTFail("cycle \(index) discarded its audio")
            }
        }
        XCTAssertEqual(Set(outcomes.map(\.hashOfSession)).count, cycles, "buffers were reused")
    }

    // MARK: - B8: the custody property

    /// **B8**, the load-bearing one: for every ``EndReason`` except `.userCancelled`, the audio that
    /// session captured is emitted **exactly once**, and it is *that* buffer.
    ///
    /// Two halves, and the second is the one that is easy to write uselessly:
    ///
    /// - *At least once*: the effect is `.ended`, its content is `.completed`, and the reason it
    ///   carries is the one the cause implies — a system trigger arriving as `.keyUp` is a lie in
    ///   the log, which is the only evidence anyone will have of a session that ended surprisingly.
    /// - *At most once, and the right buffer*: the payload is compared against the exact buffer the
    ///   microphone handed over for that session, and the microphone's close count is required to
    ///   move by exactly one. Asserting only `case .completed` passes for a machine that swaps in an
    ///   empty buffer, and asserting only the effect passes for one that closes the mic twice.
    ///
    /// Then the same input is delivered a second time and must change nothing: an outcome emitted
    /// twice is the same words injected twice.
    func testEveryEndReasonEmitsThatSessionsAudioExactlyOnce() throws {
        var driven: Set<EndReasonTag> = []

        for reason in EndReason.allCases {
            guard let drive = Self.driver(for: reason) else {
                XCTAssertEqual(
                    reason, .retained(.toggledOff),
                    "\(reason) has no way to be reached through the machine, and only toggle mode "
                        + "is allowed to be in that position.")
                continue
            }
            driven.insert(EndReasonTag(reason))

            let harness = Harness()
            XCTAssertEqual(harness.pressHotkey(), .started, "\(reason): no session to end")
            let closesBefore = harness.source.endCount

            let outcome = try endedOutcome(drive(harness), "\(reason)")

            XCTAssertEqual(
                harness.source.endCount, closesBefore + 1,
                "\(reason) closed the microphone \(harness.source.endCount - closesBefore) times.")
            XCTAssertFalse(harness.source.isOpen, "\(reason) left the microphone open.")
            XCTAssertEqual(harness.machine.state, .idle, "\(reason) left the machine mid-flight.")

            let captured = try XCTUnwrap(harness.source.handedOut.last, "\(reason)")
            switch (reason, outcome.content) {
            case (.retained(let expected), .completed(let carried, let audio, _)):
                XCTAssertEqual(carried, expected, "\(reason) was reported as \(carried).")
                let payload: RecordingSource.Buffer = audio
                XCTAssertEqual(
                    payload, captured,
                    """
                    \(reason) emitted a buffer that is not the one this session captured. \
                    Expected \(captured), got \(payload).
                    """)
            case (.userCancelled, .cancelled):
                break
            case (.retained, .cancelled):
                XCTFail("\(reason) discarded audio the user never asked to abandon.")
            case (.userCancelled, .completed):
                XCTFail("Cancellation handed audio downstream that the user asked to throw away.")
            }

            // Exactly once, from the other side: the same cause again is a no-op.
            let repeated = drive(harness)
            XCTAssertEqual(repeated, .unchanged, "\(reason) ended a second, non-existent session.")
            XCTAssertEqual(
                harness.source.endCount, closesBefore + 1,
                "\(reason) emitted its audio twice — the same words, injected twice.")
        }

        // The exclusion is deliberate and self-falsifying: `.toggledOff` is toggle mode's stop and
        // toggle mode does not exist yet (`HotkeyConfiguration.Activation` has one case). When it
        // arrives, this count fails until its driver is written above.
        XCTAssertEqual(
            driven.count, EndReason.allCases.count - 1,
            """
            \(EndReason.allCases.count - driven.count) reasons were not driven through the machine, \
            and exactly one — .toggledOff — is allowed to be. Add the new reason's cause to \
            `driver(for:)` rather than lowering this number.
            """)
    }

    /// Cancellation is the one path that discards — and it still has to close the microphone.
    ///
    /// This is a trap the type system sets: ``SessionOutcome/make(reason:audio:)`` takes its audio
    /// as an `@autoclosure` precisely so cancellation never materialises a buffer it will throw
    /// away. A funnel that closed the microphone *inside* that argument would therefore leave the
    /// microphone open on exactly the path where the user pressed Escape and the widget says
    /// nothing is happening. The mic ledger is what catches it; a test asserting only "the outcome
    /// was `.cancelled`" would not.
    func testCancellationDiscardsTheAudioAndStillClosesTheMicrophone() throws {
        let harness = Harness()
        XCTAssertEqual(harness.pressHotkey(), .started)
        XCTAssertTrue(harness.source.isOpen)

        let outcome = try endedOutcome(harness.machine.cancel())

        XCTAssertFalse(
            harness.source.isOpen,
            "Escape discarded the audio and left the microphone open — a hot mic the user believes "
                + "they just closed.")
        XCTAssertEqual(harness.source.endCount, 1)
        XCTAssertEqual(harness.machine.state, .idle)
        switch outcome.content {
        case .cancelled: break
        case .completed(let reason, _, _):
            XCTFail("Escape handed the audio on anyway, attributed to \(reason).")
        }
    }

    // MARK: - B5/B6/B7: the watchdog's mechanism

    /// **B5**: the ceiling fires at exactly the configured deadline, and not one tick earlier.
    func testTheCeilingFiresAtExactlyTheConfiguredDeadline() throws {
        let ceiling = Duration.seconds(120)
        let harness = Harness(ceiling: ceiling)

        XCTAssertEqual(harness.pressHotkey(), .started)

        harness.advance(ceiling - .nanoseconds(1))
        XCTAssertEqual(harness.machine.tick(), .unchanged, "The ceiling fired one nanosecond early.")
        XCTAssertTrue(harness.source.isOpen)

        harness.advance(.nanoseconds(1))
        let outcome = try endedOutcome(harness.machine.tick(), "at exactly the deadline")

        switch outcome.content {
        case .completed(let reason, let audio, _):
            XCTAssertEqual(reason, .ceilingReached)
            XCTAssertEqual(audio, try XCTUnwrap(harness.source.handedOut.last))
        case .cancelled:
            XCTFail("The ceiling threw away two minutes of speech the user did not abandon.")
        }
        XCTAssertFalse(harness.source.isOpen)
    }

    /// A clock that runs backwards must not extend a session.
    ///
    /// The obvious implementation — remember `start`, fire when `now >= start + ceiling` — extends
    /// the session by exactly the size of the jump, because the absolute deadline moves out of
    /// reach. Elapsed time is therefore **accumulated from the deltas between readings**, with a
    /// negative delta contributing nothing: the session then still ends after one ceiling's worth of
    /// forward time, which is what the user asked for.
    func testAClockThatJumpsBackwardsDoesNotExtendTheSession() throws {
        let ceiling = Duration.seconds(120)
        let harness = Harness(ceiling: ceiling)
        harness.clock.now = .seconds(1_000)

        XCTAssertEqual(harness.pressHotkey(), .started)

        harness.advance(.seconds(30))
        XCTAssertEqual(harness.machine.tick(), .unchanged)

        // The clock steps back to zero and stays there. 30 s of the session are already spent.
        harness.clock.now = .zero
        XCTAssertEqual(harness.machine.tick(), .unchanged, "A backwards step must not end a session.")

        harness.advance(.seconds(89))
        XCTAssertEqual(harness.machine.tick(), .unchanged, "119 s of forward time is not 120.")

        harness.advance(.seconds(1))
        let outcome = try endedOutcome(
            harness.machine.tick(),
            "120 s of forward time elapsed; the backwards step extended the session instead.")
        switch outcome.content {
        case .completed(let reason, _, _): XCTAssertEqual(reason, .ceilingReached)
        case .cancelled: XCTFail("The ceiling discarded its audio.")
        }
    }

    /// A tick with no session must neither open anything nor accumulate anything.
    func testTicksOutsideASessionChangeNothing() {
        let harness = Harness()
        harness.advance(.seconds(600))
        XCTAssertEqual(harness.machine.tick(), .unchanged)
        XCTAssertEqual(harness.source.beginCount, 0)
        XCTAssertEqual(harness.source.endCount, 0)

        // The 600 s that passed before the session belong to nobody: this one starts from zero.
        XCTAssertEqual(harness.pressHotkey(), .started)
        harness.advance(.seconds(119))
        XCTAssertEqual(harness.machine.tick(), .unchanged, "Idle time counted against the ceiling.")
    }

    /// **B6**: a poll reporting the key released ends the session — within one poll, by
    /// construction, since the poll is the input.
    func testAPollReportingReleaseEndsTheSessionAndOneReportingItHeldDoesNot() throws {
        let harness = Harness()
        XCTAssertEqual(harness.pressHotkey(), .started)

        XCTAssertEqual(
            harness.machine.observePhysicalKey(isDown: true), .unchanged,
            "A poll finding the key still held ended the session.")
        XCTAssertTrue(harness.source.isOpen)

        let outcome = try endedOutcome(harness.machine.observePhysicalKey(isDown: false))
        switch outcome.content {
        case .completed(let reason, let audio, _):
            XCTAssertEqual(reason, .pollDetectedRelease)
            XCTAssertEqual(audio, try XCTUnwrap(harness.source.handedOut.last))
        case .cancelled:
            XCTFail("A missed key-up discarded the words the user had already said.")
        }
        XCTAssertFalse(harness.source.isOpen)
    }

    /// **B7**: the tap died, so the key-up is never coming.
    func testTapDisabledEndsTheSession() throws {
        let harness = Harness()
        XCTAssertEqual(harness.pressHotkey(), .started)

        let outcome = try endedOutcome(harness.tapDies())
        switch outcome.content {
        case .completed(let reason, _, _): XCTAssertEqual(reason, .tapDisabled)
        case .cancelled: XCTFail("A dead tap discarded the session's audio.")
        }
        XCTAssertFalse(harness.source.isOpen)
    }

    /// Each ``SystemTrigger`` stops the session carrying **its own** reason, not a generic one.
    func testEverySystemTriggerStopsTheSessionCarryingItsOwnReason() throws {
        for trigger in SystemTrigger.allCases {
            let harness = Harness()
            XCTAssertEqual(harness.pressHotkey(), .started, "\(trigger)")

            let outcome = try endedOutcome(harness.machine.observe(trigger), "\(trigger)")
            switch outcome.content {
            case .completed(let reason, let audio, _):
                XCTAssertEqual(
                    reason, .systemEvent(trigger),
                    "\(trigger) was logged as \(reason) — the log is the only evidence anyone gets.")
                XCTAssertEqual(audio, try XCTUnwrap(harness.source.handedOut.last))
            case .cancelled:
                XCTFail("\(trigger) discarded audio the user never asked to abandon.")
            }
            XCTAssertFalse(harness.source.isOpen, "\(trigger) left the microphone open.")
        }
    }

    // MARK: - B9: idempotence

    /// **B9**: double-start, stop-without-start and stop-twice are all safe no-ops.
    func testDoubleStartStopWithoutStartAndStopTwiceAreSafeNoOps() throws {
        let harness = Harness()

        // Stop before any start: every stop input, against an idle machine.
        XCTAssertEqual(harness.releaseHotkey(), .unchanged)
        XCTAssertEqual(harness.releaseModifier(), .unchanged)
        XCTAssertEqual(harness.tapDies(), .unchanged)
        XCTAssertEqual(harness.machine.cancel(), .unchanged)
        XCTAssertEqual(harness.machine.tick(), .unchanged)
        XCTAssertEqual(harness.machine.observePhysicalKey(isDown: false), .unchanged)
        XCTAssertEqual(harness.machine.observe(.willSleep), .unchanged)
        XCTAssertEqual(harness.source.beginCount, 0)
        XCTAssertEqual(harness.source.endCount, 0)
        XCTAssertEqual(harness.source.closesWithoutOpen, 0)

        // Double start: a fresh press and an autorepeat, both while already recording.
        XCTAssertEqual(harness.pressHotkey(), .started)
        XCTAssertEqual(harness.pressHotkey(), .unchanged, "A second press started a second session.")
        XCTAssertEqual(
            harness.autorepeat(modifiers: chord.modifiers).effect, .unchanged,
            "An autorepeat started a session.")
        XCTAssertEqual(harness.source.beginCount, 1, "The microphone was opened twice.")
        XCTAssertEqual(harness.source.overlappingBegins, 0)

        // Stop twice, by two different causes.
        _ = try endedOutcome(harness.releaseHotkey())
        XCTAssertEqual(harness.releaseHotkey(), .unchanged, "The same key-up ended two sessions.")
        XCTAssertEqual(harness.tapDies(), .unchanged)
        XCTAssertEqual(harness.machine.cancel(), .unchanged)
        XCTAssertEqual(harness.source.endCount, 1, "The microphone was closed more than once.")
        XCTAssertEqual(harness.source.closesWithoutOpen, 0)
        XCTAssertEqual(harness.machine.state, .idle)
    }

    /// A microphone that will not open must not leave a session that believes it did.
    ///
    /// The key-down is still swallowed: the user pressed Vocca's hotkey, so a space must not appear
    /// in their document just because the capture failed — and the press is still Vocca's to
    /// account for until it comes back up.
    func testAMicrophoneThatCannotOpenStartsNoSessionButTheKeyIsStillSwallowed() {
        let harness = Harness()
        harness.source.nextStart = .unavailable

        let response = harness.feed(event(.keyDown, space, [.option]))
        XCTAssertEqual(response.effect, .captureUnavailable)
        XCTAssertEqual(response.eventPropagation, .swallow)
        XCTAssertEqual(harness.machine.state, .idle, "A session started with no microphone behind it.")
        XCTAssertFalse(harness.source.isOpen)
        XCTAssertEqual(harness.source.endCount, 0, "Nothing was opened, so nothing may be closed.")

        // And the machine is not wedged: the next press, with a working microphone, works.
        harness.source.nextStart = .opened
        XCTAssertEqual(harness.releaseHotkey(), .unchanged)
        XCTAssertEqual(harness.pressHotkey(), .started)
        XCTAssertTrue(harness.source.isOpen)
    }

    // MARK: - Vocabulary

    func testEverySessionEffectIsExhaustivelySwitchable() throws {
        let harness = Harness()
        XCTAssertEqual(harness.pressHotkey(), .started)
        let ended = harness.releaseHotkey()

        func label(for effect: Effect) -> String {
            switch effect {
            case .unchanged: return "unchanged"
            case .started: return "started"
            case .captureUnavailable: return "captureUnavailable"
            case .ended: return "ended"
            }
        }
        XCTAssertEqual(
            [Effect.unchanged, .started, .captureUnavailable, ended].map(label(for:)),
            ["unchanged", "started", "captureUnavailable", "ended"])

        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        XCTAssertEqual(requireSendable(ended), ended)
        let response = SessionResponse(effect: Effect.unchanged, eventPropagation: .swallow)
        XCTAssertEqual(requireSendable(response), response)
    }

    // MARK: - The key Vocca swallowed the press of

    /// The defect this phase exists to fix, in the sequence a user actually produces.
    ///
    /// ⌥Space held; Option comes up first; the session ends on rule (b) — and the key is *still
    /// physically down*, so macOS keeps autorepeating it. The chord is gone, so those repeats are no
    /// longer anyone's hotkey as far as ``decide(_:state:config:)`` can tell, and it passes them
    /// through: plain characters at the system repeat rate, landing in the very field the transcript
    /// is about to be injected into, unless the user releases within one repeat interval (~30–60 ms).
    ///
    /// A stateless function cannot fix it — knowing that a physically-held key is the tail of a
    /// press Vocca swallowed is a fact about the *session*, not about the event. The session carries
    /// it, and keeps swallowing that key code until it comes back up, regardless of chord.
    func testNoCharacterReachesTheAppAfterAModifierFirstStopWhileTheKeyIsHeld() throws {
        let harness = Harness()

        XCTAssertEqual(harness.pressHotkey(), .started)
        harness.autorepeat(modifiers: [.option])
        harness.autorepeat(modifiers: [.option])

        // Option comes up. The session ends here, with the key still down.
        let outcome = try endedOutcome(harness.releaseModifier())
        switch outcome.content {
        case .completed(let reason, _, _): XCTAssertEqual(reason, .modifierReleased)
        case .cancelled: XCTFail("Rule (b) discarded its audio.")
        }

        // The user's finger is still on Space for another few repeat intervals.
        for _ in 0..<12 {
            let response = harness.autorepeat(modifiers: [])
            XCTAssertEqual(
                response.effect, .unchanged, "A repeat of a held key restarted something.")
            XCTAssertEqual(
                response.eventPropagation, .swallow,
                """
                An autorepeat of the still-held hotkey passed through after a modifier-first stop. \
                That is a character typed into the field the transcript is about to be injected \
                into, repeating at the system rate until the user lets go.
                """)
        }
        XCTAssertEqual(
            harness.strayCharacters, 0,
            "\(harness.strayCharacters) characters reached the focused application.")

        // And the key-up that finally arrives is Vocca's to eat too: the app never saw the press.
        XCTAssertEqual(harness.releaseHotkey(), .unchanged)
        XCTAssertEqual(harness.strayCharacters, 0)
        XCTAssertTrue(
            harness.keysTheAppBelievesAreDown.isEmpty,
            "The application was left holding \(harness.keysTheAppBelievesAreDown).")
    }

    /// The other half: the application must never be left holding a key down.
    ///
    /// Swallowing is asymmetric in ``decide(_:state:config:)`` — a `.keyDown` is claimed only while
    /// the chord is held, a `.keyUp` whatever modifiers survive to report it — so a passed-through
    /// key-down followed by a swallowed key-up leaves the app a key it believes is held. That is
    /// worse than the reverse: a stuck modifier or a stuck Space changes the meaning of everything
    /// the user types next.
    ///
    /// The sequence below is the reachable one. The app receives a key-down for Space (pressed
    /// without the chord, so Vocca has no interest in it), the user then adds Option, and a
    /// key-down arrives that macOS did *not* mark as an autorepeat — which happens with remappers,
    /// and is exactly the input a machine must not be fragile about. Vocca starts a session and
    /// swallows that press; the key-up must then still reach the app, because the app is holding
    /// the first one.
    func testTheApplicationIsNeverLeftHoldingTheHotkeyKey() throws {
        let harness = Harness()

        harness.feed(event(.keyDown, space, []))
        XCTAssertEqual(
            harness.keysTheAppBelievesAreDown, [space],
            "A press with no chord is not Vocca's and must reach the app.")

        harness.feed(event(.flagsChanged, space, [.option]))
        XCTAssertEqual(
            harness.feed(event(.keyDown, space, [.option])).effect, .started,
            "The unrepeated key-down is a fresh press as far as the rules can tell.")

        let outcome = try endedOutcome(harness.releaseHotkey())
        switch outcome.content {
        case .completed(let reason, _, _): XCTAssertEqual(reason, .keyUp)
        case .cancelled: XCTFail("A key-up discarded its audio.")
        }

        XCTAssertTrue(
            harness.keysTheAppBelievesAreDown.isEmpty,
            """
            The focused application is holding \(harness.keysTheAppBelievesAreDown) — it saw the \
            key go down and never saw it come up, so every keystroke after this one carries a \
            modifier the user is not pressing.
            """)
    }

    /// The claim must not outlive the press, or Vocca has broken the user's keyboard.
    ///
    /// Two ways out, and both are needed. The ordinary one is the key-up. The other is a *fresh*
    /// press: a key-down that macOS did not mark as an autorepeat proves the key came back up while
    /// nobody was looking — the tap was disabled, the app lost focus — so a claim still standing at
    /// that point is stale and is dropped **before** the event is decided. Without that, a lost
    /// key-up would make the user's Space bar dead until they restarted Vocca.
    func testAClaimNeverOutlivesThePressAndAFreshPressClearsAStaleOne() throws {
        let ordinary = Harness()
        XCTAssertEqual(ordinary.pressHotkey(), .started)
        _ = try endedOutcome(ordinary.releaseHotkey())
        // Claim released *by the key-up itself*, which is why the probe is an autorepeat: a fresh
        // key-down would clear a stale claim on its own, and this test would then pass whether or
        // not the key-up ever released anything.
        XCTAssertEqual(
            ordinary.autorepeat(modifiers: []).eventPropagation, .passThrough,
            "The key came up and Vocca is still eating it.")
        XCTAssertEqual(ordinary.strayCharacters, 1, "Vocca kept eating a key it no longer owns.")

        // The tap dies mid-press, so the key-up is never observed and the claim stands.
        let stale = Harness()
        XCTAssertEqual(stale.pressHotkey(), .started)
        _ = try endedOutcome(stale.tapDies())
        XCTAssertEqual(
            stale.autorepeat(modifiers: [.option]).eventPropagation, .swallow,
            "The key is still held and Vocca swallowed its press; the repeats are still Vocca's.")

        // A fresh, unrepeated press can only mean the key came up unobserved.
        XCTAssertEqual(
            stale.feed(event(.keyDown, space, [])).eventPropagation, .passThrough,
            """
            A stale claim survived a fresh press of the key, so Vocca is eating a key the user is \
            typing — a dead Space bar with no way out but a restart.
            """)
    }

    /// A poll that finds the key up releases the claim too, for the same reason: after that report
    /// there is no held key whose repeats need swallowing, and the key-up may have been the event
    /// that went missing.
    func testAPollFindingTheKeyUpReleasesTheClaim() throws {
        let harness = Harness()
        XCTAssertEqual(harness.pressHotkey(), .started)
        _ = try endedOutcome(harness.machine.observePhysicalKey(isDown: false))

        // An autorepeat, deliberately: a fresh key-down clears a stale claim by itself, so probing
        // with one would pass whether or not the poll released anything.
        XCTAssertEqual(
            harness.autorepeat(modifiers: []).eventPropagation, .passThrough,
            "The poll reported the key up and Vocca went on swallowing it.")
    }

    /// A re-press during a session must leave the key claimed.
    ///
    /// The staleness valve drops the claim on any unrepeated key-down, and one *can* arrive
    /// mid-session: a key-up went missing and the user pressed again. The press is swallowed, so
    /// Vocca still owes its key-up — if the valve dropped the claim and nothing took it back, the
    /// repeats after the next modifier release would start typing into the document again, which is
    /// the original defect returning by a side door.
    func testARepressDuringASessionLeavesTheKeyClaimed() throws {
        let harness = Harness()
        XCTAssertEqual(harness.pressHotkey(), .started)

        let repress = harness.feed(event(.keyDown, space, [.option]))
        XCTAssertEqual(repress.effect, .unchanged, "A re-press restarted the session.")
        XCTAssertEqual(repress.eventPropagation, .swallow)

        _ = try endedOutcome(harness.releaseModifier())
        XCTAssertEqual(
            harness.autorepeat(modifiers: []).eventPropagation, .swallow,
            "The re-press dropped the claim and never took it back.")
        XCTAssertEqual(harness.strayCharacters, 0)
    }

    // MARK: - Re-entrancy

    /// An event arriving from *inside* the microphone opening must not open a second one.
    ///
    /// `AVAudioEngine.start()` is real work on a real run loop, and a queued `CGEvent` delivered
    /// underneath it re-enters this machine while it is neither idle nor recording. The state alone
    /// cannot classify that moment — which is exactly the "fail closed on unclassifiable input"
    /// case `project-skeleton` carried forward — so the input is refused rather than assumed
    /// harmless.
    func testAKeyEventArrivingInsideTheMicrophoneOpeningStartsNothing() {
        let harness = Harness()
        harness.source.duringBeginCapture = { [machine = harness.machine] in
            let reentrant = machine.observe(event(.keyDown, space, [.option]))
            XCTAssertEqual(
                reentrant.effect, .unchanged,
                "An event delivered inside beginCapture() started a second session.")
            XCTAssertEqual(
                reentrant.eventPropagation, .swallow,
                "The press Vocca is in the middle of claiming reached the app anyway.")
        }

        XCTAssertEqual(harness.pressHotkey(), .started)
        XCTAssertEqual(harness.source.beginCount, 1, "The microphone was opened twice.")
        XCTAssertEqual(harness.source.overlappingBegins, 0, "Two captures overlapped.")
        XCTAssertEqual(harness.machine.state, .recording)
    }

    /// The cost of refusing an event inside the opening, pinned rather than left to be discovered.
    ///
    /// A *stop* can arrive there too — the user's key-up landing in the milliseconds an engine takes
    /// to start — and refusing it means the session opens with the key already up. That is a hot mic
    /// the user did not ask for, and it is bounded by exactly one thing: the physical-key poll, which
    /// exists for missed key-ups and closes this one within one interval. The trade is deliberate;
    /// the alternative is a replay queue inside a module that has no queues, to cover an event the
    /// watchdog already covers.
    func testAStopArrivingInsideTheOpeningIsRefusedAndThePollRecoversIt() throws {
        let harness = Harness()
        harness.source.duringBeginCapture = { [machine = harness.machine] in
            XCTAssertEqual(
                machine.observe(event(.keyUp, space, [.option])).effect, .unchanged,
                "The key-up was honoured mid-opening, against a session that does not exist yet.")
        }

        XCTAssertEqual(harness.pressHotkey(), .started)
        XCTAssertTrue(
            harness.source.isOpen,
            "Documented behaviour: the session opens even though the key is already up.")

        let outcome = try endedOutcome(harness.machine.observePhysicalKey(isDown: false))
        switch outcome.content {
        case .completed(let reason, _, _): XCTAssertEqual(reason, .pollDetectedRelease)
        case .cancelled: XCTFail("The watchdog discarded what was captured.")
        }
        XCTAssertFalse(harness.source.isOpen, "The watchdog did not close the window it exists for.")
    }

    /// The same for the handoff. `.ending` exists for this moment: the previous session's audio is
    /// on its way downstream, and nothing may start or end a session from there.
    func testAKeyEventArrivingInsideTheHandoffProducesNoSecondOutcome() throws {
        let harness = Harness()
        XCTAssertEqual(harness.pressHotkey(), .started)

        var observedState: SessionState?
        harness.source.duringEndCapture = { [machine = harness.machine] in
            observedState = machine.state
            XCTAssertEqual(machine.observe(event(.keyDown, space, [.option])).effect, .unchanged)
            XCTAssertEqual(machine.observe(.willSleep), .unchanged)
            XCTAssertEqual(machine.cancel(), .unchanged)
            XCTAssertEqual(machine.tick(), .unchanged)
            XCTAssertEqual(machine.observePhysicalKey(isDown: false), .unchanged)
        }

        _ = try endedOutcome(harness.releaseHotkey())

        XCTAssertEqual(
            observedState, .ending,
            "The handoff is the one moment `.ending` describes, and the machine was not in it.")
        XCTAssertEqual(harness.source.endCount, 1, "The microphone was closed twice.")
        XCTAssertEqual(harness.source.beginCount, 1)
        XCTAssertEqual(harness.machine.state, .idle)
    }

    // MARK: - The whole input space

    /// Two thousand randomised sequences of every input the machine accepts, checked against
    /// invariants rather than against a copy of the rules.
    ///
    /// A reviewer trying to construct a sequence that leaves the microphone open, produces two
    /// outcomes for one capture, or strands a key in the focused application is enumerating this
    /// space by hand; it is cheaper to enumerate it here. Four invariants, checked after **every**
    /// input rather than at the end, so a failure names the step that caused it:
    ///
    /// 1. The microphone is open exactly when the machine says a session is recording.
    /// 2. No two captures overlap, and nothing is closed that was never opened.
    /// 3. Exactly one outcome per capture, carrying *that* capture's buffer.
    /// 4. After the key is released and the poll confirms it, the focused application is not left
    ///    holding it.
    ///
    /// Seeded, so a failure is replayable from the number in the message.
    func testNoRandomisedSequenceOfInputsBreaksTheInvariants() throws {
        for seed in UInt64(1)...2_000 {
            var random = SeededGenerator(seed: seed)
            let harness = Harness()
            var outcomes: [SessionOutcome<RecordingSource.Buffer>] = []

            func record(_ effect: Effect, _ step: Int) {
                switch effect {
                case .ended(let outcome): outcomes.append(outcome)
                case .unchanged, .started, .captureUnavailable: break
                }
                XCTAssertTrue(
                    harness.micAgreesWithState,
                    "seed \(seed) step \(step): the microphone and the machine disagree.")
                XCTAssertEqual(
                    harness.source.overlappingBegins, 0, "seed \(seed) step \(step): overlap")
                XCTAssertEqual(
                    harness.source.closesWithoutOpen, 0, "seed \(seed) step \(step): stray close")
                XCTAssertEqual(
                    outcomes.count, harness.source.endCount,
                    "seed \(seed) step \(step): outcomes and captures diverged.")
            }

            for step in 0..<24 {
                switch Int.random(in: 0..<10, using: &random) {
                case 0:
                    record(harness.machine.tick(), step)
                case 1:
                    harness.advance(.milliseconds(Int.random(in: 0..<20_000, using: &random)))
                case 2:
                    record(
                        harness.machine.observe(
                            SystemTrigger.allCases.randomElement(using: &random) ?? .willSleep),
                        step)
                case 3:
                    record(
                        harness.machine.observePhysicalKey(
                            isDown: Bool.random(using: &random)), step)
                case 4:
                    record(harness.machine.cancel(), step)
                default:
                    let kind = RawKeyEvent.Kind.allCases.randomElement(using: &random) ?? .keyDown
                    let modifiers: ModifierSet = [
                        [], [.option], [.option, .shift], [.shift], [.option, .capsLock],
                    ].randomElement(using: &random) ?? []
                    let response = harness.feed(
                        event(
                            kind, [space, letterA].randomElement(using: &random) ?? space,
                            modifiers, autorepeat: Bool.random(using: &random)))
                    record(response.effect, step)

                    // The claim covers key presses and nothing else. A swallowed `.flagsChanged`
                    // would strand the focused application's idea of which modifiers are down —
                    // and the fuzz does generate one carrying the hotkey's own key code, which is
                    // the only way this can go wrong.
                    switch kind {
                    case .flagsChanged, .tapDisabled:
                        XCTAssertEqual(
                            response.eventPropagation, .passThrough,
                            "seed \(seed) step \(step): a \(kind) event was swallowed.")
                    case .keyDown, .keyUp:
                        break
                    }
                }
            }

            // However the sequence ended: the user lets go, and the watchdog confirms it.
            record(harness.releaseHotkey(), 24)
            record(harness.machine.observePhysicalKey(isDown: false), 25)

            XCTAssertEqual(harness.machine.state, .idle, "seed \(seed): not idle after release")
            XCTAssertFalse(harness.source.isOpen, "seed \(seed): the microphone was left open")
            XCTAssertFalse(
                harness.keysTheAppBelievesAreDown.contains(space),
                """
                seed \(seed): the focused application is still holding the hotkey key. Vocca \
                swallowed a key-up the application was waiting for.
                """)

            // Every outcome carries the buffer of the capture it closed, in order. This is the
            // property that a machine emitting a fresh or reused buffer fails, and nothing above
            // would notice.
            for (index, outcome) in outcomes.enumerated() {
                switch outcome.content {
                case .completed(_, let audio, _):
                    XCTAssertEqual(audio, harness.source.handedOut[index], "seed \(seed)")
                case .cancelled:
                    break
                }
            }
        }
    }

    /// The positive control for the invariant above.
    ///
    /// "The microphone was never left open" is a zero-assertion in disguise: it cannot, on its own,
    /// tell a machine that closes properly from a harness that cannot see an open microphone. So the
    /// same predicate, over the same ledger, is shown a microphone that *is* stuck — opened behind
    /// the machine's back — and must say so.
    func testTheHarnessCanDetectAMicrophoneThatStayedOpen() {
        let harness = Harness()
        XCTAssertTrue(harness.micAgreesWithState, "Idle and closed must agree.")

        XCTAssertEqual(harness.source.beginCapture(), .opened)
        XCTAssertFalse(
            harness.micAgreesWithState,
            """
            The harness reports agreement while the microphone is open and the machine is idle — \
            which is precisely the hot mic every assertion in this file claims to rule out. Without \
            this control those assertions prove nothing.
            """)

        _ = harness.source.endCapture()
        XCTAssertTrue(harness.micAgreesWithState)
    }

    // MARK: - Drivers

    /// Every ``EndReason``, mapped to the input that causes it — switched exhaustively, with no
    /// `default:`, so a reason added later has no branch to inherit and fails to compile here.
    ///
    /// Deliberately keyed on *causes*, not on reasons. A public `stop(reason:)` would make this
    /// table trivial and would also let any caller attribute a session's end to whatever it liked;
    /// ``SessionOutcome`` calls that the one residual hole it cannot close, and a public API shaped
    /// like it would be an invitation to walk through.
    private static func driver(for reason: EndReason) -> ((Harness) -> Effect)? {
        switch reason {
        case .retained(.keyUp):
            return { $0.releaseHotkey() }
        case .retained(.modifierReleased):
            return { $0.releaseModifier() }
        case .retained(.tapDisabled):
            return { $0.tapDies() }
        case .retained(.ceilingReached):
            return {
                $0.advance(SessionCeiling.default)
                return $0.machine.tick()
            }
        case .retained(.pollDetectedRelease):
            return { $0.machine.observePhysicalKey(isDown: false) }
        case .retained(.systemEvent(let trigger)):
            return { $0.machine.observe(trigger) }
        case .retained(.toggledOff):
            // Toggle mode is a later unit of work and `HotkeyConfiguration.Activation` has one
            // case, so nothing the machine accepts today can produce this. The count assertion in
            // the property test is what stops that from being forgotten.
            return nil
        case .userCancelled:
            return { $0.machine.cancel() }
        }
    }
}

/// A hashable stand-in for ``EndReason``, so the property test can count what it drove.
private struct EndReasonTag: Hashable {
    private let description: String
    init(_ reason: EndReason) {
        self.description = "\(reason)"
    }
}

extension SessionOutcome where Audio == RecordingSource.Buffer {
    /// The session number of the buffer this outcome carries, or `nil` for a discard. Used only to
    /// prove 100 outcomes carry 100 distinct buffers.
    fileprivate var hashOfSession: Int? {
        switch content {
        case .completed(_, let audio, _): return audio.session
        case .cancelled: return nil
        }
    }
}
