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
/// `A`. A key Vocca has no interest in, which is nearly every key the user presses.
private let letterA: UInt16 = 0

private let chord = HotkeyConfiguration(
    keyCode: space, modifiers: [.option], activation: .holdToTalk)

private func event(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet,
    autorepeat: Bool = false
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: autorepeat,
        // Deliberately constant, as in the other session suites: the machine reads its injected
        // clock and never an event's timestamp, and a test that could steer the ceiling by moving
        // this would have merged the two timebases.
        timestamp: .zero)
}

private typealias Effect = SessionEffect<RecordingSource.Buffer>

/// Where a session's effects go once they are out of the machine — the transcribing actor's place in
/// the pipeline, as a ledger.
///
/// **This is the only route by which a test in this file can observe an outcome**, and that is the
/// point. ``HotkeyEventSink/receive(_:)`` returns an ``EventPropagation`` and nothing else, so a sink
/// that dropped the ``SessionEffect`` would still answer the tap correctly and still swallow the
/// right keys — and would lose every transcript. Reading outcomes from here rather than from a return
/// value makes that failure visible.
private final class EffectLog {
    private(set) var effects: [Effect] = []

    func record(_ effect: Effect) { effects.append(effect) }

    var outcomes: [SessionOutcome<RecordingSource.Buffer>] {
        effects.compactMap { effect in
            switch effect {
            case .ended(let outcome): return outcome
            case .unchanged, .started, .captureUnavailable: return nil
            }
        }
    }

    var starts: Int {
        effects.filter { effect in
            switch effect {
            case .started: return true
            case .unchanged, .captureUnavailable, .ended: return false
            }
        }.count
    }
}

/// The whole pipeline, headlessly: **source → sink → watchdog → machine → microphone.**
///
/// Every element below the fake tap is the shipped one. The only substitution is the system call
/// itself, which is the substitution this aspect's seam exists to make possible.
private final class SeamHarness {
    let clock = TestClock()
    let source = RecordingSource()
    let keyboard = Keyboard()
    let effects = EffectLog()
    let tap = FakeHotkeyEventSource()
    let keyState: TruthfulKeyState
    let machine: SessionMachine<RecordingSource.Buffer>
    let watchdog: SessionWatchdog<RecordingSource.Buffer>
    let sink: SessionEventSink<RecordingSource.Buffer>
    let configuration: HotkeyConfiguration

    init(configuration: HotkeyConfiguration = chord, ceiling: Duration = SessionCeiling.default) {
        self.configuration = configuration
        let keyState = TruthfulKeyState(keyboard)
        self.keyState = keyState
        self.machine = SessionMachine(
            configuration: configuration, ceiling: ceiling, clock: clock, audioSource: source)
        self.watchdog = SessionWatchdog(machine: machine, keyState: keyState)
        self.sink = SessionEventSink(watchdog: watchdog) { [effects] effect in
            effects.record(effect)
        }
    }

    /// Create the tap and attach the session to it. Called explicitly rather than from `init` so
    /// that the state *before* it — no tap, no delivery — is a state a test can be in.
    @discardableResult
    func arm() -> HotkeyEventSourceStart {
        tap.start(delivering: sink)
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

    /// Any event at all. The tap delivers **every** key event, not only the hotkey's: stop rule (c)
    /// is "any event whose flags no longer carry the configured modifier", and the rules cannot
    /// apply it to events they never see.
    @discardableResult
    func feed(_ event: RawKeyEvent) -> EventPropagation {
        tap.deliver(event)
    }

    func advance(_ interval: Duration) { clock.now += interval }

    /// One turn of the owner's timer, with the effect routed where the owner would route it.
    func wake() { effects.record(watchdog.wake()) }
}

/// Which session's buffer an outcome carried, or `nil` if it discarded one.
extension SessionOutcome where Audio == RecordingSource.Buffer {
    fileprivate var sessionNumber: Int? {
        switch content {
        case .completed(_, let audio, _): return audio.session
        case .cancelled: return nil
        }
    }
}

/// A keyboard sequence with something of everything in it: a start, an autorepeat, keys Vocca has no
/// interest in, a modifier drop, a tap death, and the hotkey's own key-up.
///
/// Used by the transparency test, where the point is that **both** dispositions occur — a comparison
/// over a sequence that is swallowed end to end is satisfied by any constant.
private let aRepresentativeKeyboardSequence: [RawKeyEvent] = [
    event(.keyDown, letterA, []),
    event(.keyUp, letterA, []),
    event(.flagsChanged, space, [.option]),
    event(.keyDown, space, [.option]),
    event(.keyDown, space, [.option], autorepeat: true),
    event(.keyDown, letterA, [.option]),
    event(.keyUp, letterA, [.option]),
    event(.flagsChanged, space, []),
    event(.keyDown, space, [], autorepeat: true),
    event(.keyUp, space, []),
    event(.tapDisabled, 0, []),
    event(.keyDown, letterA, []),
]

/// **The `HotkeyEventSource` seam**: the boundary that puts every branch worth testing on the side a
/// CI runner can reach.
///
/// `CGEvent.tapCreate` returns `nil` without an Accessibility grant, and no hosted runner can be
/// granted one — there is no programmatic route to TCC short of disabling SIP. Anything phrased in
/// terms of `CGEvent` is therefore untestable *forever* rather than untested for now. This seam
/// yields plain ``RawKeyEvent`` values and takes back a plain ``EventPropagation``, so the tap below
/// it has nothing left to decide and everything above it runs here.
final class HotkeyEventSourceTests: XCTestCase {

    // MARK: - The acceptance, now over this seam

    /// **`CAPABILITY_ROADMAP.md:42`'s stated acceptance, driven through the seam the real tap will
    /// implement**: 100 synthetic key-down/key-up pairs at durations from 80 ms to 60 s — exactly
    /// 100 sessions started, 100 ended, zero overlapping, zero orphaned.
    ///
    /// `session-lifecycle` proved this by calling ``SessionMachine/observe(_:)-(RawKeyEvent)``
    /// directly. That was the right test for that aspect and it is not this one: the seam, the sink,
    /// the disposition's journey back out to the caller and the watchdog's timer are all in the path
    /// here, and each of them is a place a session can be lost that the earlier run could not reach.
    ///
    /// Every count is read off ``RecordingSource``'s ledger and ``FakeHotkeyEventSource``'s, never
    /// off the machine — a machine agreeing with itself is not evidence — and the outcomes are read
    /// out of the sink's effect handler, which is the only route they have.
    func testOneHundredSyntheticCyclesDrivenThroughTheSeamStartAndEndExactlyOnceEach() throws {
        let harness = SeamHarness()
        XCTAssertEqual(harness.arm(), .started)

        let cycles = 100
        var expectedPolls = 0

        for cycle in 0..<cycles {
            // 80 ms … 60 s, spread evenly. Both ends are the spec's, and both are well inside the
            // 120 s ceiling — a session ending for the ceiling here would be a defect, not a pass.
            let held = Duration.milliseconds(80 + (60_000 - 80) * cycle / (cycles - 1))

            XCTAssertEqual(
                harness.press(), .swallow,
                "cycle \(cycle): the hotkey press reached the focused application")

            // The watchdog runs for the whole hold, at the cadence its own policy names. A ceiling
            // that fired early, or a poll that misread a held key, shows up here and nowhere else.
            //
            // **The remainder is driven too, and that is not pedantry.** Advancing only inside the
            // wake loop makes each session `floor(held / 150 ms) × 150 ms` long rather than `held` —
            // and for cycle 0 that is *zero*: `wakes(covering: 80 ms)` is 0, so the 80 ms end of the
            // range the comment above claims would run as a 0 ms session with no wake at all. The
            // trailing partial interval is also the realistic shape, because a user releasing the
            // key does not wait for the next tick.
            let turns = wakes(covering: held)
            let whole = WatchdogPolicy.pollInterval * turns
            expectedPolls += turns
            var endedEarly = false
            for _ in 0..<turns {
                harness.advance(WatchdogPolicy.pollInterval)
                harness.wake()
                if harness.machine.state != .recording {
                    endedEarly = true
                    break
                }
            }
            if held > whole {
                harness.advance(held - whole)
                harness.wake()
                expectedPolls += 1
                if harness.machine.state != .recording { endedEarly = true }
            }
            XCTAssertFalse(endedEarly, "cycle \(cycle) ended before the user let go")
            XCTAssertEqual(
                harness.machine.elapsed, held,
                "cycle \(cycle) did not run for the hold duration this test claims to drive")

            XCTAssertEqual(
                harness.release(), .swallow,
                "cycle \(cycle): the hotkey's key-up reached the focused application")
            XCTAssertEqual(harness.machine.state, .idle, "cycle \(cycle) did not end")
        }

        // The microphone's own ledger: 100 started, 100 ended, 0 overlapping, 0 orphaned.
        XCTAssertEqual(harness.source.beginCount, cycles, "not exactly 100 sessions started")
        XCTAssertEqual(harness.source.endCount, cycles, "not exactly 100 sessions ended")
        XCTAssertEqual(harness.source.overlappingBegins, 0, "two sessions were open at once")
        XCTAssertEqual(
            harness.source.closesWithoutOpen, 0, "a session was closed that never opened")
        XCTAssertFalse(
            harness.source.isOpen, "the microphone was left open — an orphaned session")
        XCTAssertEqual(harness.machine.state, .idle)

        // It went through the seam, and the seam was armed once. Without this the whole test is
        // satisfiable by a harness that quietly drove the machine directly.
        XCTAssertEqual(harness.tap.startCount, 1)
        XCTAssertTrue(harness.tap.isDelivering)
        XCTAssertEqual(
            harness.tap.deliveredEvents.count, cycles * 2,
            "the seam did not carry 200 events — 100 presses and 100 releases")
        XCTAssertEqual(harness.tap.eventsArrivingWhileStopped, 0)

        // And the focused application heard none of it. 200 hotkey events, 0 delivered onward.
        XCTAssertEqual(
            harness.tap.applicationSaw, [],
            "the application received \(harness.tap.applicationSaw.count) of Vocca's own events")
        XCTAssertEqual(harness.tap.keysTheApplicationBelievesAreDown, [])

        // The watchdog genuinely polled, at the cadence, about the key this machine watches. "The
        // poll ran 20,000 times and ended nothing" and "the poll stopped running" are otherwise the
        // same green run.
        XCTAssertGreaterThan(expectedPolls, 0, "no wake was scheduled — the ceiling was never driven")
        XCTAssertEqual(harness.keyState.reads, expectedPolls, "the watchdog stopped polling")
        XCTAssertEqual(harness.keyState.keysAsked, [space])

        // Custody, read out of the sink's effect handler — the only route an outcome has.
        XCTAssertEqual(harness.effects.starts, cycles, "a `.started` was dropped crossing the seam")
        let outcomes = harness.effects.outcomes
        XCTAssertEqual(outcomes.count, cycles, "an outcome was dropped crossing the seam")
        for (index, outcome) in outcomes.enumerated() {
            switch outcome.content {
            case .completed(let reason, let audio, _):
                XCTAssertEqual(reason, .keyUp, "cycle \(index) ended for the wrong reason")
                XCTAssertEqual(audio, harness.source.handedOut[index], "cycle \(index)")
            case .cancelled:
                XCTFail("cycle \(index) discarded its audio")
            }
        }
        XCTAssertEqual(
            Set(outcomes.compactMap(\.sessionNumber)).count, cycles, "buffers were reused")
    }

    // MARK: - H6: propagation, pinned in both directions, at the far end of the seam

    /// **An event the machine passes through reaches the caller as pass-through — *via this
    /// seam*.**
    ///
    /// The direction with the blast radius, and the one a suite drifts away from. In the merged
    /// aspect a watchdog wrapper that hard-coded `.swallow` survived every test, because every
    /// propagation assertion covered the swallow direction only. That defect would have eaten the
    /// user's entire keyboard, in every application, for as long as Vocca ran.
    ///
    /// Asserted against ``FakeHotkeyEventSource/applicationSaw``, which is built from the value the
    /// *source* returns — not from the `SessionResponse` the watchdog produced. A source that
    /// ignored the disposition it was handed passes every assertion phrased against the response.
    func testAnEventTheMachinePassesThroughReachesTheApplicationAcrossTheSeam() throws {
        let harness = SeamHarness()
        XCTAssertEqual(harness.arm(), .started)

        // 1. Idle. The overwhelmingly common case: Vocca is a background app, and this is every key
        //    the user types all day.
        XCTAssertEqual(
            harness.feed(event(.keyDown, letterA, [])), .passThrough,
            "Vocca swallowed an unrelated keystroke while idle — every key the user types, gone.")
        XCTAssertEqual(harness.feed(event(.keyUp, letterA, [])), .passThrough)

        // 2. During a session, with the chord still held. The user is dictating, not typing — but
        //    the keyboard is still theirs.
        XCTAssertEqual(harness.press(), .swallow)
        XCTAssertEqual(
            harness.feed(event(.keyDown, letterA, [.option])), .passThrough,
            "Vocca swallowed an unrelated keystroke during a session.")
        XCTAssertEqual(
            harness.machine.state, .recording,
            "An unrelated keystroke that still carries the chord must not end the session.")

        // 3. The event that *does* end it — the configured modifier coming up — is a modifier
        //    event, and those are never claimed in either direction: swallowing one strands the
        //    focused application's idea of which modifiers are down.
        XCTAssertEqual(
            harness.feed(event(.flagsChanged, space, [])), .passThrough,
            "Vocca swallowed a modifier event, stranding the app's idea of what is held.")
        XCTAssertEqual(harness.machine.state, .idle)

        // Measured at the far end of the seam: this is the focused application's whole input.
        XCTAssertEqual(
            harness.tap.applicationSaw.map(\.kind), [.keyDown, .keyUp, .keyDown, .flagsChanged],
            "the application's input across the seam was not what the machine decided it should be")
        XCTAssertEqual(harness.tap.charactersTyped(for: letterA), 2)
        XCTAssertEqual(
            harness.tap.keyEventsSeen(for: space), 0,
            "an event for Vocca's own hotkey reached the focused application")

        let outcome = try endedOutcome(
            try XCTUnwrap(harness.effects.effects.last), "the configured modifier came up")
        switch outcome.content {
        case .completed(let reason, _, _): XCTAssertEqual(reason, .modifierReleased)
        case .cancelled: XCTFail("a released modifier discarded the user's audio")
        }
    }

    /// **And an event the machine claims is swallowed** — the other half of H6, at the same far end.
    ///
    /// The hotkey's press, its autorepeats and its key-up are all Vocca's. Letting the press through
    /// types U+00A0 NO-BREAK SPACE into the field the transcript is about to be injected into, on a
    /// US layout, invisibly; letting only the key-up through leaves the application an unpaired
    /// release.
    func testTheHotkeysOwnEventsAreSwallowedAndTheApplicationSeesNoneOfThem() throws {
        let harness = SeamHarness()
        XCTAssertEqual(harness.arm(), .started)

        XCTAssertEqual(harness.press(), .swallow, "the press that starts a session was typed")
        for repeatNumber in 0..<3 {
            XCTAssertEqual(
                harness.feed(event(.keyDown, space, [.option], autorepeat: true)), .swallow,
                "autorepeat \(repeatNumber) of the held hotkey reached the application")
        }
        XCTAssertEqual(harness.release(), .swallow, "the hotkey's key-up reached the application")

        XCTAssertEqual(harness.tap.deliveredEvents.count, 5)
        XCTAssertEqual(harness.tap.dispositions, Array(repeating: .swallow, count: 5))
        XCTAssertEqual(harness.tap.applicationSaw, [])
        XCTAssertEqual(harness.tap.keysTheApplicationBelievesAreDown, [])
        XCTAssertEqual(harness.source.beginCount, 1)
        XCTAssertEqual(harness.source.endCount, 1)
    }

    /// **The positive control for both of the above.**
    ///
    /// A propagation assertion that cannot tell the real sink from one that decides for itself is
    /// measuring nothing, and the merged aspect is the evidence: its suite was green at 119/119 with
    /// a hard-coded `.swallow` in the path. So both mutants are run here, over the same sequence,
    /// and the measurement is required to separate all three.
    func testTheFarEndMeasurementSeparatesTheRealSinkFromASinkThatDecidesForItself() {
        func applicationInput(from sink: any HotkeyEventSink) -> [RawKeyEvent] {
            let tap = FakeHotkeyEventSource()
            XCTAssertEqual(tap.start(delivering: sink), .started)
            for keyEvent in aRepresentativeKeyboardSequence { tap.deliver(keyEvent) }
            return tap.applicationSaw
        }

        let real = SeamHarness()
        XCTAssertEqual(real.arm(), .started)
        for keyEvent in aRepresentativeKeyboardSequence { real.feed(keyEvent) }

        let swallowsEverything = applicationInput(from: AlwaysSwallowingSink())
        let passesEverythingThrough = applicationInput(from: AlwaysPassingThroughSink())

        XCTAssertEqual(
            swallowsEverything, [],
            "the swallow-everything control did not swallow everything — the control is broken")
        XCTAssertEqual(
            passesEverythingThrough, aRepresentativeKeyboardSequence,
            "the pass-everything control did not pass everything — the control is broken")

        // The shipped sink is neither — and *what* it is, exactly, rather than only that it differs
        // from two things. `XCTAssertNotEqual` on its own is satisfied by any difference at all,
        // including a sink that got every single event wrong in some third way.
        //
        // The eight the user gets back: their two `A` keystrokes before the session, the modifier
        // press that armed the chord, the two during it, the modifier release that ended it, the
        // tap-disabled notification, and the `A` afterwards. The four Vocca keeps are the press that
        // started the session, its autorepeat, and the repeat and key-up still owed on the claim
        // after a rule-(b) stop left the key physically held.
        XCTAssertEqual(
            real.tap.applicationSaw,
            [0, 1, 2, 5, 6, 7, 10, 11].map { aRepresentativeKeyboardSequence[$0] },
            "the focused application's input across the seam was not what the rules decided")

        XCTAssertNotEqual(
            real.tap.applicationSaw, swallowsEverything,
            """
            The application received nothing at all across the seam — indistinguishable from a sink \
            that hard-codes `.swallow`, which eats the user's entire keyboard in every application \
            for as long as Vocca runs.
            """)
        XCTAssertNotEqual(
            real.tap.applicationSaw, passesEverythingThrough,
            """
            The application received every event across the seam — indistinguishable from a sink \
            that hard-codes `.passThrough`, which types the hotkey into the field the transcript is \
            about to be injected into.
            """)
    }

    /// **The seam returns the machine's answer unchanged, event for event.**
    ///
    /// The strongest form of inherited constraint 4, and the one no constant can satisfy: the same
    /// sequence is run twice, once across the seam and once straight into the watchdog, and the two
    /// answer arrays must be identical. An inverted, clamped, filtered or state-dependent
    /// disposition all diverge here.
    ///
    /// The final assertion is what stops the comparison being vacuous — the sequence must actually
    /// produce **both** dispositions, or an implementation returning a single constant would satisfy
    /// the equality above on both sides.
    func testTheSeamReturnsTheMachinesOwnAnswerForEveryEventUnchanged() {
        let acrossTheSeam = SeamHarness()
        XCTAssertEqual(acrossTheSeam.arm(), .started)
        // Deliberately not armed: this one is driven straight into the watchdog, which is what the
        // seam is being compared against.
        let straightToTheWatchdog = SeamHarness()

        var seamAnswers: [EventPropagation] = []
        var directAnswers: [EventPropagation] = []
        for keyEvent in aRepresentativeKeyboardSequence {
            seamAnswers.append(acrossTheSeam.feed(keyEvent))
            directAnswers.append(straightToTheWatchdog.watchdog.observe(keyEvent).eventPropagation)
        }

        XCTAssertEqual(
            seamAnswers, directAnswers,
            "the seam changed the machine's disposition for at least one event")
        XCTAssertEqual(
            seamAnswers.count, aRepresentativeKeyboardSequence.count,
            "the seam dropped an event rather than answering for it")
        XCTAssertEqual(
            Set(seamAnswers), Set(EventPropagation.allCases),
            """
            The sequence produced only one disposition, so the comparison above would be satisfied \
            by any constant. Both directions have to occur for this test to measure anything.
            """)
    }

    /// **Every kind of key event crosses the seam, not only the hotkey's.**
    ///
    /// Stop rule (c) is "any event whose modifiers no longer carry the configured set", so the
    /// machine has to see keys it has no interest in. A source that filtered to the configured key
    /// code before delivering — an optimisation that looks obviously correct — removes rules (b) and
    /// (c) entirely, and the session then runs to the ceiling every time the user releases Option
    /// before Space.
    func testEveryKindOfKeyEventCrossesTheSeamNotOnlyTheHotkeys() {
        let harness = SeamHarness()
        XCTAssertEqual(harness.arm(), .started)
        for keyEvent in aRepresentativeKeyboardSequence { harness.feed(keyEvent) }

        XCTAssertEqual(
            Set(harness.tap.deliveredEvents.map(\.kind)), Set(RawKeyEvent.Kind.allCases),
            """
            Not every kind of key event reached the session across the seam. A kind that never \
            arrives is a stop rule that never fires.
            """)

        // Counted rather than compared as a set of key codes, deliberately. `letterA` is key code 0
        // and a `.tapDisabled` event carries key code 0 too, so a set literal of the three distinct
        // *sources* of key code in this sequence collapses to two members and would be satisfied by
        // an implementation that delivered only some of them — the duplicate-admitting cardinality
        // guard this repository has now found twice.
        XCTAssertEqual(
            harness.tap.deliveredEvents.filter { $0.keyCode != space }.count, 6,
            "the seam filtered by key code, which removes stop rules (b) and (c)")
        XCTAssertEqual(harness.tap.deliveredEvents.count, aRepresentativeKeyboardSequence.count)
    }

    // MARK: - The seam's own lifecycle

    /// **A source that is not delivering starts no session, and costs the user nothing.**
    ///
    /// No tap means no swallowing: every keystroke reaches the focused application untouched. That
    /// is the correct behaviour and the safe one, and the direction of failure that matters — a
    /// Vocca that cannot hear the hotkey is an inconvenience, and one that eats keystrokes it never
    /// delivered is a broken keyboard.
    func testASourceThatIsNotDeliveringStartsNoSessionAndLeavesTheKeyboardIntact() {
        let harness = SeamHarness()

        XCTAssertFalse(harness.tap.isDelivering)
        XCTAssertEqual(harness.press(), .passThrough)
        XCTAssertEqual(harness.release(), .passThrough)

        XCTAssertEqual(harness.machine.state, .idle)
        XCTAssertEqual(harness.source.beginCount, 0, "a session began with no source delivering")
        XCTAssertEqual(harness.tap.deliveredEvents, [], "an event reached the session with no sink")
        XCTAssertEqual(harness.tap.eventsArrivingWhileStopped, 2)
        XCTAssertEqual(harness.tap.applicationSaw.count, 2, "the untapped keystrokes were eaten")
        XCTAssertEqual(harness.effects.effects, [], "an effect was produced with no source")

        // And the harness is not simply inert: arming it makes the same gesture work.
        XCTAssertEqual(harness.arm(), .started)
        XCTAssertEqual(harness.press(), .swallow)
        XCTAssertEqual(harness.machine.state, .recording)
        XCTAssertEqual(harness.source.beginCount, 1)
    }

    /// **A source that cannot start attaches no sink, and says so.**
    ///
    /// `CGEvent.tapCreate` returning `nil` is what a missing Accessibility grant looks like, and it
    /// is the reason ``HotkeyEventSourceStart`` has two cases rather than the method returning
    /// `Void`. What to *do* about it — surface it as "permission missing" rather than as silence
    /// (H5) — is the tap-health policy's, in the next phase. What is pinned here is only that the
    /// seam has somewhere to say it, and that saying it leaves nothing attached.
    func testASourceThatCannotStartAttachesNoSinkAndStartsNoSession() {
        let harness = SeamHarness()
        harness.tap.nextStart = .unavailable

        XCTAssertEqual(harness.arm(), .unavailable)
        XCTAssertEqual(harness.tap.startCount, 1, "the source was not asked to start")
        XCTAssertFalse(harness.tap.isDelivering, "a source that reported .unavailable is delivering")

        XCTAssertEqual(harness.press(), .passThrough)
        XCTAssertEqual(harness.machine.state, .idle)
        XCTAssertEqual(harness.source.beginCount, 0)

        // Distinguishable from a source that is simply broken: once it can start, it does.
        harness.tap.nextStart = .started
        XCTAssertEqual(harness.arm(), .started)
        XCTAssertEqual(harness.tap.startCount, 2)
        XCTAssertEqual(harness.press(), .swallow)
        XCTAssertEqual(harness.source.beginCount, 1)
    }

    /// **Stopping the source detaches the session from the keyboard, and does not end it.**
    ///
    /// Measured rather than argued, because it is the shape of the hazard the next phase owns. A tap
    /// that is torn down mid-session takes with it every event that could still stop that session —
    /// the key-up above all — and what is left bounding it is the ceiling, two minutes away.
    ///
    /// Nothing here decides what *should* happen; deciding that a re-created tap always ends the
    /// in-flight session is the tap-health policy's call (H3/H4). This records what the seam does
    /// today so that phase has a measured starting point rather than an assumption.
    func testStoppingTheSourceDetachesTheKeyboardAndLeavesTheCeilingBoundingTheSession() throws {
        let harness = SeamHarness()
        XCTAssertEqual(harness.arm(), .started)
        XCTAssertEqual(harness.press(), .swallow)
        XCTAssertEqual(harness.machine.state, .recording)

        harness.tap.stop()
        XCTAssertEqual(harness.tap.stopCount, 1)
        XCTAssertFalse(harness.tap.isDelivering)

        // The user lets go. The event reaches the focused application, because there is no tap —
        // and it reaches the session not at all.
        XCTAssertEqual(harness.release(), .passThrough)
        XCTAssertEqual(
            harness.machine.state, .recording,
            "the session ended without any event reaching it — from where?")
        XCTAssertTrue(harness.source.isOpen, "the microphone closed with nothing to close it")

        // The watchdog is still the owner's, and it is what recovers this: the physical key reads
        // up, so stop rule (f) ends the session on the very next wake — a poll interval, not the
        // ceiling. That is only true because the poll does not travel through the tap.
        harness.advance(WatchdogPolicy.pollInterval)
        harness.wake()
        XCTAssertEqual(harness.machine.state, .idle)
        XCTAssertFalse(harness.source.isOpen)

        let outcome = try endedOutcome(try XCTUnwrap(harness.effects.effects.last))
        switch outcome.content {
        case .completed(let reason, _, _): XCTAssertEqual(reason, .pollDetectedRelease)
        case .cancelled: XCTFail("a torn-down tap discarded the user's audio")
        }
    }

    /// **The seam's start vocabulary is exactly two answers, and both have to be decided about.**
    ///
    /// `HotkeyEventSourceStart` exists so that "the tap was not created" — a first run with no
    /// Accessibility grant, which is every user's first run — has somewhere to go other than
    /// silence. A third answer added without a decision about what it means is the failure this
    /// pins: the `switch` below has no `default:`, so a new case is a compile error here, and the
    /// set equality catches a case renamed or removed rather than added.
    ///
    /// It is deliberately a claim about the *vocabulary* and not about the policy. What Vocca does
    /// with `.unavailable` — surfacing it as "permission missing" rather than as a silent no-op,
    /// which is acceptance H5 — belongs to the tap-health phase, and pre-empting it here would put
    /// the decision somewhere nobody reviewing tap health would look for it.
    func testTheSeamsStartVocabularyIsExactlyTwoAnswersAndBothAreDecidedAbout() {
        XCTAssertEqual(
            Set(HotkeyEventSourceStart.allCases), [.started, .unavailable],
            """
            The seam's start vocabulary changed. A third answer is a decision — what does the owner \
            do about it, and what does the widget say — and it has to be made where the tap-health \
            policy can see it.
            """)

        for start in HotkeyEventSourceStart.allCases {
            let harness = SeamHarness()
            harness.tap.nextStart = start
            XCTAssertEqual(harness.arm(), start)

            switch start {
            case .started:
                XCTAssertTrue(harness.tap.isDelivering)
                XCTAssertEqual(harness.press(), .swallow)
                XCTAssertEqual(harness.source.beginCount, 1)
            case .unavailable:
                XCTAssertFalse(harness.tap.isDelivering)
                XCTAssertEqual(harness.press(), .passThrough)
                XCTAssertEqual(harness.source.beginCount, 0)
            }
        }
    }

    /// **A second `start` tears the first down rather than leaving two taps installed.**
    ///
    /// This is the call the tap-health policy will make: its charter is "if re-enable fails, tear
    /// down and re-create", and re-creating is calling `start` again. A source that merely
    /// overwrote its sink there would leak a `CFMachPort` and a run-loop source, and leave a second
    /// tap whose callback still points at the previous context — a use-after-free on the next
    /// keystroke, reached by a caller who did everything the protocol documents.
    ///
    /// Two distinct sinks, so "the replacement receives" and "the replaced one no longer does" are
    /// separate observations. One sink could not tell them apart.
    func testASecondStartTearsDownTheFirstRatherThanLeavingTwoTapsInstalled() {
        let harness = SeamHarness()
        let replaced = AlwaysSwallowingSink()

        XCTAssertEqual(harness.tap.start(delivering: replaced), .started)
        harness.tap.deliver(event(.keyDown, letterA, []))
        XCTAssertEqual(replaced.received, 1)
        XCTAssertEqual(harness.tap.stopCount, 0)

        // The re-create.
        XCTAssertEqual(harness.arm(), .started)
        XCTAssertEqual(
            harness.tap.stopCount, 1,
            "the second start did not tear the first down — two taps are now installed")
        XCTAssertEqual(harness.tap.startCount, 2)
        XCTAssertTrue(harness.tap.isDelivering)

        XCTAssertEqual(harness.press(), .swallow)
        XCTAssertEqual(
            harness.source.beginCount, 1, "the replacement sink is not the one receiving events")
        XCTAssertEqual(
            replaced.received, 1, "the replaced sink is still being delivered to")

        // And a re-create that **fails** leaves nothing attached. Deaf rather than double-tapped is
        // the safe direction, and it is the one the policy has to be able to detect.
        harness.tap.nextStart = .unavailable
        XCTAssertEqual(harness.tap.start(delivering: replaced), .unavailable)
        XCTAssertEqual(harness.tap.stopCount, 2, "the failed re-create left the old tap installed")
        XCTAssertFalse(harness.tap.isDelivering)
        XCTAssertEqual(harness.release(), .passThrough)
        XCTAssertEqual(replaced.received, 1)
    }

    /// **A transcript survives the crossing.**
    ///
    /// ``HotkeyEventSink/receive(_:)`` returns an ``EventPropagation`` and nothing else, so the
    /// session's ``SessionEffect`` — the only thing that ever carries a ``SessionOutcome`` — has to
    /// leave by a different door. A sink that dropped it would answer the tap correctly, swallow
    /// exactly the right keys, and lose every word the user said.
    func testTheOutcomeOfASessionLeavesTheSinkEvenThoughTheTapNeverSeesIt() throws {
        let harness = SeamHarness()
        XCTAssertEqual(harness.arm(), .started)

        XCTAssertEqual(harness.press(), .swallow)
        XCTAssertEqual(harness.release(), .swallow)

        XCTAssertEqual(harness.effects.starts, 1, "the `.started` never left the sink")
        let outcomes = harness.effects.outcomes
        XCTAssertEqual(outcomes.count, 1, "the outcome never left the sink — the transcript is gone")
        switch try XCTUnwrap(outcomes.first).content {
        case .completed(let reason, let audio, _):
            XCTAssertEqual(reason, .keyUp)
            XCTAssertEqual(
                audio, try XCTUnwrap(harness.source.handedOut.last),
                "the outcome carried a buffer that is not this session's")
        case .cancelled:
            XCTFail("a key-up is not a cancellation: the audio it captured is owed downstream")
        }
    }
}
