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

/// The same binding in toggle mode. Same key, same chord — so every difference these tests find is
/// a difference of mode.
private let toggleChord = HotkeyConfiguration(
    keyCode: space, modifiers: [.option], activation: .toggle)

/// The configuration this suite uses for an activation mode.
///
/// Written as an exhaustive switch rather than a dictionary so that a third mode fails to compile
/// here: the property tests below iterate `Activation.allCases`, and a mode with no configuration
/// would otherwise be skipped by whatever `nil` handling the lookup happened to have.
private func configuration(for activation: HotkeyConfiguration.Activation) -> HotkeyConfiguration {
    switch activation {
    case .holdToTalk: return chord
    case .toggle: return toggleChord
    }
}

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

// `TestClock` and `RecordingSource` live in `SessionTestDoubles.swift`, shared with
// `SessionWatchdogTests` — the watchdog drives this same machine through this same microphone, and
// a second copy of the ledger that drifted from this one would let its tests pass against a
// microphone that behaves differently from the one these tests use.

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

    /// **The toggle gesture: the key goes down and comes straight back up, and both events are
    /// delivered.**
    ///
    /// The key-up is not incidental — it is the event that would end the session if toggle had
    /// inherited stop rule (a), so it is asserted here rather than left to the caller to remember.
    /// Every toggle test in this file goes through this method, so a mode that cannot survive its
    /// own key-up fails all of them at once and by name.
    ///
    /// Returns the key-*down*'s effect, which is the one that starts or stops the session.
    @discardableResult
    func tapHotkey(file: StaticString = #filePath, line: UInt = #line) -> Effect {
        let down = pressHotkey()
        XCTAssertEqual(
            releaseHotkey(), .unchanged,
            """
            The key-up of a toggle press changed the session. In toggle mode the user's finger comes \
            off the key immediately and stays off for the whole session; a mode whose own key-up \
            ends it lasts about sixty milliseconds.
            """,
            file: file, line: line)
        return down
    }

    /// Starts a session with **this harness's own mode's** gesture: a press that stays down, or a
    /// tap.
    ///
    /// Switched without a `default:`, so a third activation mode has to say how a session begins in
    /// it before the property tests below can run — rather than silently starting none and passing.
    @discardableResult
    func startSession(file: StaticString = #filePath, line: UInt = #line) -> Effect {
        switch configuration.activation {
        case .holdToTalk: return pressHotkey()
        case .toggle: return tapHotkey(file: file, line: line)
        }
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

    /// Key-downs **and key-ups** the application received for `keyCode`.
    ///
    /// Separate from ``strayCharacters`` because that one counts presses, and a key-up let through
    /// is invisible to it — which is how a whole branch of the claim went unpinned. A key-up types
    /// nothing, so it is not a stray character; it is still an event for a gesture the app never
    /// saw begin.
    func keyEventsTheAppSaw(for keyCode: UInt16) -> Int {
        appSaw.filter {
            $0.keyCode == keyCode && ($0.kind == .keyDown || $0.kind == .keyUp)
        }.count
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
        var driven: Set<String> = []
        var unreachable: Set<String> = []

        for activation in HotkeyConfiguration.Activation.allCases {
            for reason in EndReason.allCases {
                let label = "\(activation) × \(reason)"
                guard let drive = Self.driver(for: reason, in: activation) else {
                    unreachable.insert(label)
                    continue
                }
                driven.insert(label)

                let harness = Harness(configuration: configuration(for: activation))
                XCTAssertEqual(harness.startSession(), .started, "\(label): no session to end")
                let closesBefore = harness.source.endCount

                let outcome = try endedOutcome(drive(harness), label)

                XCTAssertEqual(
                    harness.source.endCount, closesBefore + 1,
                    "\(label) closed the microphone \(harness.source.endCount - closesBefore) times.")
                XCTAssertFalse(harness.source.isOpen, "\(label) left the microphone open.")
                XCTAssertEqual(harness.machine.state, .idle, "\(label) left the machine mid-flight.")

                let captured = try XCTUnwrap(harness.source.handedOut.last, label)
                switch (reason, outcome.content) {
                case (.retained(let expected), .completed(let carried, let audio, _)):
                    XCTAssertEqual(carried, expected, "\(label) was reported as \(carried).")
                    let payload: RecordingSource.Buffer = audio
                    XCTAssertEqual(
                        payload, captured,
                        """
                        \(label) emitted a buffer that is not the one this session captured. \
                        Expected \(captured), got \(payload).
                        """)
                case (.userCancelled, .cancelled):
                    break
                case (.retained, .cancelled):
                    XCTFail("\(label) discarded audio the user never asked to abandon.")
                case (.userCancelled, .completed):
                    XCTFail("Cancellation handed audio downstream the user asked to throw away.")
                }

                // Exactly once, from the other side: the same cause again produces no second
                // outcome. There is one cause for which "again" is not a no-op, and it is the
                // mode's defining property rather than an exception — toggle's stop *is* a press,
                // and a press against an idle machine starts the next session. Named exactly, so
                // that any other cause reporting `.started` here still fails.
                let repeatStartsAFreshSession =
                    activation == .toggle && reason == .retained(.toggledOff)
                let repeated = drive(harness)
                XCTAssertEqual(
                    repeated, repeatStartsAFreshSession ? .started : .unchanged,
                    "\(label): the repeated cause did not do what this mode says it should.")
                XCTAssertEqual(
                    harness.source.endCount, closesBefore + 1,
                    "\(label) emitted its audio twice — the same words, injected twice.")
            }
        }

        // **Which pairs have no cause, named rather than counted.** A count says how many holes
        // there are; this says which, so a reason that quietly becomes unreachable in a mode — or
        // one that quietly becomes reachable in a mode whose policy says it is not — fails here.
        //
        // `pollDetectedRelease` in toggle is the one worth reading twice. The *machine* would
        // honour `observePhysicalKey(isDown:)` in either mode; what makes it unreachable is that
        // `SessionWatchdog.wake()` never asks in toggle mode, because the key is released for the
        // whole session and rule (f) would end it on the first wake. That is a policy, it lives in
        // exactly one place, and `SessionWatchdogTests` is where it is pinned — this line records
        // the consequence rather than the mechanism.
        XCTAssertEqual(
            unreachable,
            [
                "holdToTalk × retained(VoccaCore.RetainedEndReason.toggledOff)",
                "toggle × retained(VoccaCore.RetainedEndReason.keyUp)",
                "toggle × retained(VoccaCore.RetainedEndReason.modifierReleased)",
                "toggle × retained(VoccaCore.RetainedEndReason.pollDetectedRelease)",
            ],
            """
            The set of (mode, reason) pairs with no cause has changed. Add the new pair's cause to \
            `driver(for:in:)` rather than adding it to this list — and if a pair belongs on this \
            list, say in its comment which mode's policy puts it there.
            """)
        XCTAssertEqual(
            driven.count + unreachable.count,
            EndReason.allCases.count * HotkeyConfiguration.Activation.allCases.count,
            "Some (mode, reason) pair was neither driven nor declared unreachable.")
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
        //
        // Asserted on the **propagation**, not on the effect and not on `strayCharacters`. Both of
        // those are blind here and were: `strayCharacters` counts key-*downs*, and
        // `keysTheAppBelievesAreDown` removes from an already-empty set, so a key-up let through
        // changes neither. The claim's key-*up* branch only bites in `.idle` — which is exactly the
        // state a modifier-first stop leaves behind — so this line is the only thing standing
        // between it and a later refactor deleting it with CI green.
        let finalUp = harness.feed(event(.keyUp, space, []))
        XCTAssertEqual(finalUp.effect, .unchanged)
        XCTAssertEqual(
            finalUp.eventPropagation, .swallow,
            "The key-up of a press Vocca swallowed reached the app unpaired.")
        XCTAssertEqual(harness.strayCharacters, 0)
        XCTAssertEqual(
            harness.keyEventsTheAppSaw(for: space), 0,
            """
            The focused application received an event for a press it never saw begin. Vocca \
            swallowed the key-down; it owes the whole gesture — the repeats and the key-up.
            """)
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

    /// The bookkeeping runs on the re-entrant path too, or the app gets a key-up twice.
    ///
    /// The early return taken inside the microphone opening used to skip
    /// `account(for:propagatedAs:)`, so a key-up **forced through** on that path — because the app
    /// was waiting for it — never cleared the flag that forced it. The next release then delivered a
    /// second key-up for a key the application no longer believed was down. Exactly one duplicate,
    /// and inert, but an unexplained asymmetry in the one piece of bookkeeping the pass-through fix
    /// rests on.
    func testTheBookkeepingRunsOnTheReentrantPathToo() throws {
        let harness = Harness()

        // The app is holding Space: it was pressed without the chord, so Vocca had no interest.
        harness.feed(event(.keyDown, space, []))
        harness.feed(event(.flagsChanged, space, [.option]))
        XCTAssertEqual(harness.keysTheAppBelievesAreDown, [space])

        // A press Vocca does claim — and the key-up lands inside the opening, where it is forced
        // through (the app is waiting for it) and ends the session as soon as there is one.
        // Delivered through `feed`, not straight to the machine: the application model only sees
        // what the harness forwarded, and this test is about what the application receives.
        harness.source.duringBeginCapture = { [weak harness] in
            _ = harness?.feed(event(.keyUp, space, [.option]))
        }
        _ = try endedOutcome(harness.feed(event(.keyDown, space, [.option])).effect)
        XCTAssertTrue(
            harness.keysTheAppBelievesAreDown.isEmpty, "The forced key-up did not reach the app.")

        let eventsSoFar = harness.keyEventsTheAppSaw(for: space)

        // A second, ordinary press. Vocca swallowed its key-down, so it owes the key-up nothing:
        // the app must hear neither.
        XCTAssertEqual(harness.pressHotkey(), .started)
        _ = try endedOutcome(harness.releaseHotkey())

        XCTAssertEqual(
            harness.keyEventsTheAppSaw(for: space), eventsSoFar,
            """
            The focused application received a duplicate key-up for a key it does not believe is \
            down. The re-entrant path forced a key-up through and never recorded that it had.
            """)
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

    /// A stop that lands inside the microphone opening is applied the moment the session exists —
    /// not left to the watchdog, and not left to the ceiling.
    ///
    /// Refusing a *start* there is right; refusing a *stop* was not. The three shapes below have
    /// three different recoveries if the stop is dropped, and only the first is the poll:
    ///
    /// - **the key-up** — the poll reports the key up, one interval later;
    /// - **Escape** — the poll reports the key still **down**, so it recovers nothing; the key-up or
    ///   the ceiling does;
    /// - **`.tapDisabled`** — no key event can ever arrive again and the key is still held, so
    ///   nothing short of the tap being re-armed or the **120 s ceiling** closes it. A two-minute
    ///   hot mic in a tool whose whole promise is that the microphone is not open when the widget
    ///   says nothing is happening.
    ///
    /// Each is now ended immediately, carrying its own reason and the few milliseconds it captured.
    func testAStopArrivingInsideTheOpeningIsAppliedTheMomentTheSessionExists() throws {
        // The stop, the reason it must be reported under, and how it is delivered mid-opening.
        let shapes: [(String, RetainedEndReason?, (SessionMachine<RecordingSource.Buffer>) -> Void)] =
            [
                ("the user's key-up", .keyUp, { _ = $0.observe(event(.keyUp, space, [.option])) }),
                ("a dead tap", .tapDisabled, { _ = $0.observe(event(.tapDisabled, 0, [])) }),
                ("a system trigger", .systemEvent(.willSleep), { _ = $0.observe(.willSleep) }),
                ("Escape", nil, { _ = $0.cancel() }),
            ]

        for (label, expected, deliver) in shapes {
            let harness = Harness()
            harness.source.duringBeginCapture = { [machine = harness.machine] in deliver(machine) }

            // Not `endedOutcome`, which throws: this loop must report **every** shape that broke,
            // not stop at the first. The three recoveries differ, so which shapes fail is the
            // finding — a run that aborts on the key-up says nothing about the dead tap.
            let effect = harness.pressHotkey()
            guard case .ended(let outcome) = effect else {
                XCTFail(
                    """
                    \(label) inside the opening was dropped: got \(effect). The session is now \
                    running with nothing holding it there, and what recovers it is not the poll.
                    """)
                continue
            }

            XCTAssertFalse(
                harness.source.isOpen,
                "\(label) inside the opening left the microphone running to the ceiling.")
            XCTAssertEqual(harness.machine.state, .idle, label)
            XCTAssertEqual(harness.source.beginCount, 1, label)
            XCTAssertEqual(harness.source.endCount, 1, label)

            switch (expected, outcome.content) {
            case (let expected?, .completed(let reason, let audio, _)):
                XCTAssertEqual(reason, expected, "\(label) was reported as \(reason).")
                XCTAssertEqual(
                    audio, try XCTUnwrap(harness.source.handedOut.last),
                    "\(label) lost what those milliseconds captured.")
            case (nil, .cancelled):
                break
            case (_?, .cancelled):
                XCTFail("\(label) discarded audio the user never asked to abandon.")
            case (nil, .completed):
                XCTFail("Escape handed on audio the user asked to throw away.")
            }
        }

        // Two stops in one opening: the **first** is the one reported. The key-up is the user's own
        // gesture and the more specific fact, and the log is the only evidence anyone gets of a
        // session that ended surprisingly — the same precedence the stop rules already apply.
        let both = Harness()
        both.source.duringBeginCapture = { [machine = both.machine] in
            _ = machine.observe(event(.keyUp, space, [.option]))
            _ = machine.observe(event(.tapDisabled, 0, []))
        }
        switch try endedOutcome(both.pressHotkey()).content {
        case .completed(let reason, _, _):
            XCTAssertEqual(
                reason, .keyUp,
                "The second stop to arrive in the opening overwrote the first, which is the cause.")
        case .cancelled:
            XCTFail("A key-up discarded its audio.")
        }
    }

    /// The stop belongs to the session it was aimed at, and to no other.
    ///
    /// A deferred reason that outlived its opening would end the *next* session — one the user is
    /// still holding the key for — which is the same hot-mic bug wearing the opposite sign. Two
    /// cases: a microphone that refuses to open (there is no session for the deferred stop to end),
    /// and the ordinary press that follows.
    func testADeferredStopNeverLeaksIntoTheNextSession() throws {
        let harness = Harness()
        harness.source.nextStart = .unavailable
        harness.source.duringBeginCapture = { [machine = harness.machine] in
            _ = machine.observe(event(.keyUp, space, [.option]))
        }

        // The stop is deferred inside an opening that then fails. There is no session for it to end,
        // so it must be discarded rather than kept.
        XCTAssertEqual(harness.pressHotkey(), .captureUnavailable)
        XCTAssertEqual(harness.source.endCount, 0, "Nothing opened, so nothing may be closed.")

        harness.source.nextStart = .opened
        XCTAssertEqual(
            harness.pressHotkey(), .started,
            """
            A stop deferred by an earlier opening ended a session the user had just begun — the \
            same hot-mic bug with the opposite sign, and the user's finger is still on the key.
            """)
        XCTAssertTrue(harness.source.isOpen)

        _ = try endedOutcome(harness.releaseHotkey())
        XCTAssertEqual(harness.source.endCount, 1)
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

    // MARK: - Toggle mode

    /// The cycle a user who cannot hold a key actually performs: tap, talk, tap.
    ///
    /// Everything is read off ``RecordingSource``, not off the machine — the machine agreeing with
    /// itself is not evidence — and the second tap's outcome must carry `.toggledOff` with *that*
    /// session's buffer. `.keyUp` would be a false statement about a key-*down* in the one log
    /// anybody gets to read.
    func testAToggleCycleOpensAndClosesTheMicrophoneOnSuccessivePresses() throws {
        let harness = Harness(configuration: toggleChord)

        XCTAssertEqual(harness.tapHotkey(), .started)
        XCTAssertEqual(harness.machine.state, .recording)
        XCTAssertTrue(harness.source.isOpen, "The hotkey was tapped and the microphone did not open.")

        // Twenty seconds of speech with nothing held at all.
        for second in 1...20 {
            harness.advance(.seconds(1))
            XCTAssertEqual(
                harness.machine.tick(), .unchanged, "The session ended at second \(second).")
            XCTAssertTrue(harness.source.isOpen)
        }

        let outcome = try endedOutcome(harness.tapHotkey(), "the second tap")
        XCTAssertEqual(harness.machine.state, .idle)
        XCTAssertFalse(harness.source.isOpen, "The second tap left the microphone open.")
        XCTAssertEqual(harness.source.beginCount, 1)
        XCTAssertEqual(harness.source.endCount, 1)
        XCTAssertEqual(harness.source.overlappingBegins, 0)

        switch outcome.content {
        case .completed(let reason, let audio, _):
            XCTAssertEqual(reason, .toggledOff)
            XCTAssertEqual(audio, try XCTUnwrap(harness.source.handedOut.last))
        case .cancelled:
            XCTFail("Toggling off discarded twenty seconds the user never asked to abandon.")
        }
    }

    /// **B1 for toggle**: 100 tap-talk-tap cycles, exactly 100 started, 100 ended, 0 overlapping,
    /// 0 orphaned.
    ///
    /// The durations sweep 80 ms to 60 s with a `tick()` inside each, as the hold-to-talk twin does.
    /// The long ones matter more here: hold-to-talk's poll ends a stray session within 150 ms, so a
    /// leak there shows up as a wrong *reason*; in toggle a session that fails to end at the second
    /// tap runs to the ceiling, and the sweep's 60 s cases are where the two become distinguishable.
    func testOneHundredSyntheticToggleCyclesEachStartAndEndExactlyOnce() throws {
        let harness = Harness(configuration: toggleChord)
        let cycles = 100
        var outcomes: [SessionOutcome<RecordingSource.Buffer>] = []

        for cycle in 0..<cycles {
            let spoken = Duration.milliseconds(80 + (60_000 - 80) * cycle / (cycles - 1))

            XCTAssertEqual(harness.tapHotkey(), .started, "cycle \(cycle) did not start")
            XCTAssertTrue(harness.micAgreesWithState, "cycle \(cycle): mic out of step while open")

            harness.advance(spoken)
            XCTAssertEqual(harness.machine.tick(), .unchanged, "cycle \(cycle) ended early")

            outcomes.append(try endedOutcome(harness.tapHotkey(), "cycle \(cycle)"))
            XCTAssertTrue(harness.micAgreesWithState, "cycle \(cycle): mic out of step after")
        }

        XCTAssertEqual(harness.source.beginCount, cycles, "not exactly 100 toggle sessions started")
        XCTAssertEqual(harness.source.endCount, cycles, "not exactly 100 toggle sessions ended")
        XCTAssertEqual(harness.source.overlappingBegins, 0, "two sessions were open at once")
        XCTAssertEqual(harness.source.closesWithoutOpen, 0, "a session was closed that never opened")
        XCTAssertFalse(harness.source.isOpen, "the microphone was left open — an orphaned session")
        XCTAssertEqual(harness.machine.state, .idle)

        for (index, outcome) in outcomes.enumerated() {
            switch outcome.content {
            case .completed(let reason, let audio, _):
                XCTAssertEqual(reason, .toggledOff, "cycle \(index)")
                XCTAssertEqual(audio, harness.source.handedOut[index], "cycle \(index)")
            case .cancelled:
                XCTFail("cycle \(index) discarded its audio")
            }
        }
        XCTAssertEqual(Set(outcomes.map(\.hashOfSession)).count, cycles, "buffers were reused")

        // 200 presses and 200 releases, and the focused application heard none of them.
        XCTAssertEqual(
            harness.keyEventsTheAppSaw(for: space), 0,
            """
            The application received \(harness.keyEventsTheAppSaw(for: space)) events for the \
            hotkey across 100 toggle cycles. Vocca swallowed each press, so it owes each key-up too.
            """)
    }

    /// **The claim is scoped to the press, not to the session — and in toggle those are different.**
    ///
    /// In hold-to-talk the two coincide: the key is physically down for the whole session, so
    /// "Vocca owns this key until it comes up" and "Vocca owns this key until the session ends" are
    /// the same sentence. In toggle they are not, and picking the wrong one is the failure this
    /// mode invites — a claim held for the session leaves the user with a dead Space bar for up to
    /// two minutes at a stretch, in every application, and it would look correct in every test that
    /// only ever pressed the hotkey.
    ///
    /// So: the two presses are swallowed whole, and between them the key is the user's.
    func testInToggleModeTheHotkeyKeyBelongsToTheUserBetweenTheTwoPresses() throws {
        let harness = Harness(configuration: toggleChord)
        XCTAssertEqual(harness.tapHotkey(), .started)

        // The user types three spaces into the field they are dictating into. Bare Space is not the
        // binding, so each one is theirs — and none of them may end the session.
        for index in 0..<3 {
            let down = harness.feed(event(.keyDown, space, []))
            XCTAssertEqual(down.effect, .unchanged, "space #\(index) ended the toggle session")
            XCTAssertEqual(
                down.eventPropagation, .passThrough,
                """
                Vocca ate the user's space bar during a toggle session. The hotkey is ⌥Space; a \
                bare Space is a space, and the claim on the press ended when that press did.
                """)
            XCTAssertEqual(harness.feed(event(.keyUp, space, [])).eventPropagation, .passThrough)
        }
        XCTAssertEqual(
            harness.strayCharacters, 3, "The three spaces the user typed did not reach the app.")
        XCTAssertTrue(
            harness.keysTheAppBelievesAreDown.isEmpty,
            "The application is holding \(harness.keysTheAppBelievesAreDown) after three complete "
                + "key presses of its own.")
        XCTAssertEqual(harness.machine.state, .recording)

        // An unrelated key, and a modifier event, are equally the user's.
        XCTAssertEqual(
            harness.feed(event(.keyDown, letterA, [])).eventPropagation, .passThrough)
        XCTAssertEqual(
            harness.feed(event(.flagsChanged, 0, [.option])).eventPropagation, .passThrough,
            "A swallowed modifier event strands the app's idea of which modifiers are down.")
        XCTAssertEqual(harness.machine.state, .recording)

        // And the session still ends on the real gesture, with the app hearing nothing of it.
        let eventsBefore = harness.keyEventsTheAppSaw(for: space)
        let outcome = try endedOutcome(harness.tapHotkey())
        switch outcome.content {
        case .completed(let reason, _, _): XCTAssertEqual(reason, .toggledOff)
        case .cancelled: XCTFail("Toggling off discarded its audio.")
        }
        XCTAssertEqual(
            harness.keyEventsTheAppSaw(for: space), eventsBefore,
            "The toggle-off press or its key-up reached the focused application.")
    }

    /// **The key-up of the starting press, delivered from inside the microphone opening.**
    ///
    /// This is the sequence toggle mode produces most often and hold-to-talk almost never does: a
    /// tap is 60 ms, `AVAudioEngine.start()` is milliseconds of real work on a real run loop, so the
    /// key-up genuinely arrives underneath it. In hold-to-talk that key-up is a stop, and the
    /// machine defers it and applies it the instant the session exists — which is right there and
    /// catastrophic here. A toggle session that inherited it would end inside its own opening, every
    /// time, and the user would see the widget flicker and get nothing.
    ///
    /// The stop that *is* deferred correctly in toggle is a second press landing in the same window,
    /// and the second half of this test drives that: the two behaviours are one line apart and only
    /// asserting both distinguishes "toggle ignores the key-up" from "toggle drops everything".
    func testAToggleSessionSurvivesTheKeyUpOfItsOwnStartingPressInsideTheOpening() throws {
        let survives = Harness(configuration: toggleChord)
        survives.source.duringBeginCapture = { [weak survives] in
            _ = survives?.feed(event(.keyUp, space, [.option]))
        }

        XCTAssertEqual(
            survives.pressHotkey(), .started,
            """
            The key-up of the starting press ended the toggle session from inside the microphone \
            opening. Every tap shorter than the engine's start-up time would produce a session the \
            user never got.
            """)
        XCTAssertEqual(survives.machine.state, .recording)
        XCTAssertTrue(survives.source.isOpen)
        XCTAssertEqual(survives.source.endCount, 0)
        XCTAssertEqual(
            survives.keyEventsTheAppSaw(for: space), 0,
            "The re-entrant key-up reached the app for a press it never saw begin.")

        // And the session is a real one: the next tap ends it, as `.toggledOff`.
        let outcome = try endedOutcome(survives.tapHotkey())
        switch outcome.content {
        case .completed(let reason, _, _): XCTAssertEqual(reason, .toggledOff)
        case .cancelled: XCTFail("Toggling off discarded its audio.")
        }

        // The other half: a *press* arriving in the opening is a genuine toggle-off and must not be
        // dropped. Without this, "ignores the key-up" and "ignores everything re-entrant" are the
        // same green suite — and the second leaves a session running that the user has ended.
        let toggledOffImmediately = Harness(configuration: toggleChord)
        toggledOffImmediately.source.duringBeginCapture = { [weak toggledOffImmediately] in
            _ = toggledOffImmediately?.feed(event(.keyDown, space, [.option]))
        }
        let immediate = try endedOutcome(
            toggledOffImmediately.pressHotkey(),
            "A second press inside the opening was dropped. Nothing recovers it in toggle mode "
                + "except the 120 s ceiling — there is no poll here.")
        switch immediate.content {
        case .completed(let reason, let audio, _):
            XCTAssertEqual(reason, .toggledOff)
            XCTAssertEqual(
                audio, try XCTUnwrap(toggledOffImmediately.source.handedOut.last),
                "The milliseconds captured during the opening were lost.")
        case .cancelled:
            XCTFail("A second press discarded audio the user never asked to abandon.")
        }
        XCTAssertFalse(toggledOffImmediately.source.isOpen)
        XCTAssertEqual(toggledOffImmediately.machine.state, .idle)
    }

    /// **The stale-claim valve, in the mode where it is the only thing that can fire.**
    ///
    /// A claim goes stale when the key-up that would release it never arrives — a focus race, a
    /// stalled tap, a hotkey stolen mid-press. Until it is released, Vocca swallows every press of
    /// that key code, so the user's Space bar is dead.
    ///
    /// In hold-to-talk a stale claim lives at most one poll interval, because
    /// `observePhysicalKey(isDown: false)` clears it. **In toggle there is no poll**, so the *only*
    /// thing that ever clears it is this valve — a key-down macOS did not mark as an autorepeat,
    /// which can only mean the key came back up while nobody was looking. The valve is therefore
    /// strictly more load-bearing here than in the mode whose tests already cover it
    /// (`testAClaimNeverOutlivesThePressAndAFreshPressClearsAStaleOne`), and two mutations that
    /// skipped it in toggle survived the whole suite until this test existed.
    ///
    /// The probe is deliberately a **bare** press — no chord — so it is the user typing a space
    /// rather than a toggle-off, and the assertion is that it reaches them.
    func testAStaleClaimIsReleasedByAFreshPressInToggleModeWhereNoPollCanReleaseIt() throws {
        let harness = Harness(configuration: toggleChord)

        // The toggle-on press is swallowed and claimed — and its key-up never arrives.
        XCTAssertEqual(harness.pressHotkey(), .started)
        XCTAssertEqual(harness.machine.state, .recording)

        // Premise: while the key is still believed held, its repeats are still Vocca's. Without
        // this the test would pass against a machine that never claims anything at all.
        XCTAssertEqual(
            harness.autorepeat(modifiers: [.option]).eventPropagation, .swallow,
            "The starting press was not claimed, so there is no stale claim to release below.")

        // A fresh, unrepeated press of the bare key: the key must have come up unobserved, so the
        // claim standing is stale and this keystroke is the user's.
        let fresh = harness.feed(event(.keyDown, space, []))
        XCTAssertEqual(
            fresh.eventPropagation, .passThrough,
            """
            A stale claim survived a fresh press in toggle mode, so Vocca is eating a key the user \
            is typing. Hold-to-talk recovers from this in one poll interval; toggle has no poll, so \
            it recovers only when this valve fires.
            """)
        XCTAssertEqual(
            fresh.effect, .unchanged, "A bare press is not the chord and must not toggle anything.")
        XCTAssertEqual(harness.machine.state, .recording)

        // And the claim is genuinely gone, not merely bypassed for this one event: the repeats of
        // the press the user is now holding reach them too.
        XCTAssertEqual(
            harness.autorepeat(modifiers: []).eventPropagation, .passThrough,
            "The valve let one keystroke through and took the claim straight back.")
        XCTAssertEqual(
            harness.feed(event(.keyUp, space, [])).eventPropagation, .passThrough,
            "The user's own key-up was swallowed, leaving the app holding a key it saw go down.")
        XCTAssertTrue(harness.keysTheAppBelievesAreDown.isEmpty)

        // The session is untouched by all of it, and still ends on the real gesture.
        let outcome = try endedOutcome(harness.tapHotkey())
        switch outcome.content {
        case .completed(let reason, _, _): XCTAssertEqual(reason, .toggledOff)
        case .cancelled: XCTFail("Toggling off discarded its audio.")
        }
    }

    /// Cancellation is still the one path that discards, and in toggle it still closes the
    /// microphone.
    ///
    /// Worth its own toggle case rather than leaving it to the property test: Escape is the only
    /// input a toggle user has that ends a session *without* pressing the hotkey again, so it is
    /// their only escape from a session whose stopping press is not being seen.
    func testEscapeStillCancelsAToggleSessionAndStillClosesTheMicrophone() throws {
        let harness = Harness(configuration: toggleChord)
        XCTAssertEqual(harness.tapHotkey(), .started)
        harness.advance(.seconds(5))

        let outcome = try endedOutcome(harness.machine.cancel())
        switch outcome.content {
        case .cancelled: break
        case .completed(let reason, _, _):
            XCTFail("Escape handed the audio on anyway, attributed to \(reason).")
        }
        XCTAssertFalse(
            harness.source.isOpen,
            "Escape discarded the transcript and left the microphone open — and in toggle mode "
                + "nothing but the ceiling would have closed it.")
        XCTAssertEqual(harness.source.endCount, 1)
        XCTAssertEqual(harness.machine.state, .idle)

        // Not wedged: the next tap starts a session, and the one after ends it.
        XCTAssertEqual(harness.tapHotkey(), .started)
        _ = try endedOutcome(harness.tapHotkey())
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
    /// 4. After the sequence is wound up by the route the mode actually gives the user, the
    ///    focused application is not left holding the hotkey key.
    ///
    /// Run over **both activation modes**, because every one of those invariants is a property of
    /// the machine rather than of hold-to-talk, and the machine is mode-blind everywhere except the
    /// rules it consults. Seeded, so a failure is replayable from the mode and number in the
    /// message.
    func testNoRandomisedSequenceOfInputsBreaksTheInvariants() throws {
        // Both modes, 2,000 seeds each. Flattened rather than nested so the body below keeps its
        // indentation — and so that a mode added later is 2,000 more runs rather than a copy.
        let runs = HotkeyConfiguration.Activation.allCases.flatMap { activation in
            (UInt64(1)...2_000).map { (activation, $0) }
        }
        for (activation, seed) in runs {
            let run = "\(activation) seed \(seed)"
            var random = SeededGenerator(seed: seed)
            let harness = Harness(configuration: configuration(for: activation))
            var outcomes: [SessionOutcome<RecordingSource.Buffer>] = []

            func record(_ effect: Effect, _ step: Int) {
                switch effect {
                case .ended(let outcome): outcomes.append(outcome)
                case .unchanged, .started, .captureUnavailable: break
                }
                XCTAssertTrue(
                    harness.micAgreesWithState,
                    "\(run) step \(step): the microphone and the machine disagree.")
                XCTAssertEqual(
                    harness.source.overlappingBegins, 0, "\(run) step \(step): overlap")
                XCTAssertEqual(
                    harness.source.closesWithoutOpen, 0, "\(run) step \(step): stray close")
                XCTAssertEqual(
                    outcomes.count, harness.source.endCount,
                    "\(run) step \(step): outcomes and captures diverged.")
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
                            "\(run) step \(step): a \(kind) event was swallowed.")
                    case .keyDown, .keyUp:
                        break
                    }
                }
            }

            // However the sequence ended, the user gets out of it — by the route their own mode
            // actually gives them. Switched without a `default:`: a mode whose tail was wrong would
            // otherwise leave every assertion below asserting something about a session that was
            // still running.
            record(harness.releaseHotkey(), 24)
            switch activation {
            case .holdToTalk:
                // The key is up and the watchdog's poll confirms it.
                record(harness.machine.observePhysicalKey(isDown: false), 25)
            case .toggle:
                // Neither the key-up nor a poll ends a toggle session, and this tail must not
                // pretend otherwise — using the poll here would quietly assert the opposite of the
                // policy in `SessionWatchdog.wake()`. What a toggle user actually has left is a
                // system trigger or the ceiling; the machine sleeping is the shorter of the two.
                record(harness.machine.observe(.willSleep), 25)
            }

            XCTAssertEqual(harness.machine.state, .idle, "\(run): not idle after the tail")
            XCTAssertFalse(harness.source.isOpen, "\(run): the microphone was left open")
            XCTAssertFalse(
                harness.keysTheAppBelievesAreDown.contains(space),
                """
                \(run): the focused application is still holding the hotkey key. Vocca \
                swallowed a key-up the application was waiting for.
                """)

            // Every outcome carries the buffer of the capture it closed, in order. This is the
            // property that a machine emitting a fresh or reused buffer fails, and nothing above
            // would notice.
            for (index, outcome) in outcomes.enumerated() {
                switch outcome.content {
                case .completed(_, let audio, _):
                    XCTAssertEqual(audio, harness.source.handedOut[index], run)
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
    private static func driver(
        for reason: EndReason, in activation: HotkeyConfiguration.Activation
    ) -> ((Harness) -> Effect)? {
        // Two nested exhaustive switches rather than one over a tuple, because the shape *is* two
        // policies: each mode's list can be read straight through against `spec.md`'s rule table,
        // and a third mode is a compile error with nowhere to inherit a branch from.
        switch activation {
        case .holdToTalk:
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
                // Toggle's stop. A fresh press while recording is `.ignore` in hold-to-talk — a
                // missed key-up is what the ceiling and the poll are for, and restarting would be
                // the double-start bug.
                return nil
            case .userCancelled:
                return { $0.machine.cancel() }
            }

        case .toggle:
            switch reason {
            case .retained(.toggledOff):
                return { $0.tapHotkey() }
            case .retained(.tapDisabled):
                return { $0.tapDies() }
            case .retained(.ceilingReached):
                return {
                    $0.advance(SessionCeiling.default)
                    return $0.machine.tick()
                }
            case .retained(.systemEvent(let trigger)):
                return { $0.machine.observe(trigger) }
            case .userCancelled:
                return { $0.machine.cancel() }
            case .retained(.keyUp), .retained(.modifierReleased):
                // Stop rules (a), (b) and (c), replaced rather than inherited. The key is up for
                // the whole session, so either of these would end it in the first few milliseconds.
                return nil
            case .retained(.pollDetectedRelease):
                // Stop rule (f). Not a rule in this mode at all — see `SessionWatchdog.wake()`,
                // which is the one place that decides not to ask.
                return nil
            }
        }
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
