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

/// Space. The configured key throughout, because Option+Space is the shipped default's shape and
/// "released Option before Space" is the sequence rule (b) exists for.
private let space: UInt16 = 49
/// `A`. Any key that is not the configured one.
private let letterA: UInt16 = 0
/// A third key code, used where a test needs "some other key" twice over.
private let letterB: UInt16 = 11

/// The ordinary case: a chord.
private let chord = HotkeyConfiguration(keyCode: space, modifiers: [.option], activation: .holdToTalk)

/// A hotkey with no modifiers at all — F13, or a bare function key. Included in the input space
/// because `isSuperset(of: [])` is always true, so every modifier rule below is vacuous for it, and
/// a rule that fires anyway would be a stop nobody asked for.
private let bareKey = HotkeyConfiguration(keyCode: 105, modifiers: [], activation: .holdToTalk)

private func event(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet,
    autorepeat: Bool = false, at milliseconds: Int = 0
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: autorepeat,
        timestamp: .milliseconds(milliseconds))
}

private let start = Decision(action: .start, eventPropagation: .swallow)
private let ignorePassing = Decision(action: .ignore, eventPropagation: .passThrough)
private let ignoreSwallowing = Decision(action: .ignore, eventPropagation: .swallow)
private func stop(_ reason: RetainedEndReason, _ propagation: EventPropagation) -> Decision {
    Decision(action: .stop(.retained(reason)), eventPropagation: propagation)
}

// MARK: - Sequencing

/// Applies a decider to a sequence of events and keeps the state in step, so the rules can be
/// tested *in combination* and not only one call at a time.
///
/// This is not task 4's state machine and must not become one: it holds no clock, no watchdog and
/// no buffer. It exists because "the session ended" is a property of a sequence, and `decide` is a
/// function of one event — the two are only connected by something that carries the state forward.
///
/// `handoffEvents` is how many further events the session lingers in `.ending` before returning to
/// `.idle`. Zero models an instantaneous handoff; one models a handoff that is still in flight when
/// the next key arrives, which is the case that makes `.ending` a state rather than a boolean.
private struct SessionDriver {
    let handoffEvents: Int

    private(set) var state: SessionState = .idle
    private(set) var starts = 0
    private(set) var stops: [EndReason] = []
    private(set) var decisions: [Decision] = []
    private var endingCountdown = 0

    init(handoffEvents: Int = 0) {
        self.handoffEvents = handoffEvents
    }

    /// `@discardableResult` is fine *here* and is lint-forbidden in `VoccaCore`: this returns a
    /// decision for the tests that want to assert on one, and most of them care only about where
    /// the sequence ended up. The prohibition is about the module whose returned decisions are
    /// instructions someone has to carry out.
    @discardableResult
    mutating func feed(
        _ event: RawKeyEvent, using decide: (RawKeyEvent, SessionState) -> Decision
    ) -> Decision {
        let decision = decide(event, state)
        decisions.append(decision)
        switch decision.action {
        case .start:
            starts += 1
            state = .recording
        case .stop(let reason):
            stops.append(reason)
            if handoffEvents == 0 {
                state = .idle
            } else {
                state = .ending
                endingCountdown = handoffEvents
            }
        case .ignore:
            switch state {
            case .ending:
                endingCountdown -= 1
                if endingCountdown <= 0 { state = .idle }
            case .idle, .recording:
                break
            }
        }
        return decision
    }

    mutating func feed(
        _ events: [RawKeyEvent], using decide: (RawKeyEvent, SessionState) -> Decision
    ) {
        for event in events { feed(event, using: decide) }
    }

    /// The microphone is open with nothing holding it there.
    var isStuck: Bool {
        switch state {
        case .recording: return true
        case .idle, .ending: return false
        }
    }
}

/// The [Handy #840](https://github.com/cjpais/Handy/issues/840) defect, implemented deliberately.
///
/// Identical to the shipped rules in every respect but one: modifier state is a running total kept
/// across events and updated on `flagsChanged`, rather than read from the event in hand. That is
/// the whole difference between v0.1.4, which worked, and v0.2.0, which left the microphone open.
///
/// It exists as a **positive control**. Every test below that asserts "the session ended" is a
/// zero-assertion in disguise — it cannot, on its own, tell "the rules handled the dropped event"
/// from "the driver cannot observe a session that failed to end". Running this through the same
/// driver and the same sequence proves the mechanism detects the failure it claims to rule out.
private final class AccumulatingDecider {
    private let config: HotkeyConfiguration
    private var held: ModifierSet = []

    init(config: HotkeyConfiguration) {
        self.config = config
    }

    func decide(_ event: RawKeyEvent, state: SessionState) -> Decision {
        switch event.kind {
        case .flagsChanged:
            held = event.modifiers
        case .keyDown, .keyUp, .tapDisabled:
            break
        }

        let matchesKey = event.keyCode == config.keyCode
        // The one line that differs: `held`, not `event.modifiers`.
        let carriesChord = held.isSuperset(of: config.modifiers)

        switch state {
        case .idle:
            switch event.kind {
            case .keyDown where matchesKey && carriesChord && !event.isAutorepeat:
                return start
            case .keyDown, .keyUp, .flagsChanged, .tapDisabled:
                return ignorePassing
            }
        case .recording:
            switch event.kind {
            case .tapDisabled:
                return stop(.tapDisabled, .passThrough)
            case .keyUp where matchesKey:
                return stop(.keyUp, .swallow)
            case .keyDown, .keyUp, .flagsChanged:
                return carriesChord ? ignorePassing : stop(.modifierReleased, .passThrough)
            }
        case .ending:
            return ignorePassing
        }
    }
}

// MARK: - Randomisation

/// SplitMix64. Seeded and reproducible, because a purity test that cannot be replayed reports a
/// failure nobody can reproduce — and `SystemRandomNumberGenerator` would make every run a
/// different test.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The rules that decide whether the microphone is open.
///
/// Structured in three layers, because they answer three different questions:
///
/// 1. **Golden rows** — every start and stop rule in isolation and in the combinations where two
///    fire at once, asserted as exact `Decision` values so a change to either field fails.
/// 2. **Sequences** — the same rules driven through ``SessionDriver``, because "the session ended"
///    is a property of a sequence and rule (b)'s second half ("a later unmatched `keyUp` does
///    nothing") cannot be expressed in a single call.
/// 3. **The whole input space** — every combination of kind, key, modifiers, autorepeat, state and
///    configuration, checked against invariants rather than against a copy of the table. A reviewer
///    trying to construct a sequence the table does not cover is enumerating this space by hand;
///    it is cheaper to enumerate it here.
final class SessionDecisionTests: XCTestCase {

    private func decideChord(_ event: RawKeyEvent, _ state: SessionState) -> Decision {
        decide(event, state: state, config: chord)
    }

    // MARK: - The start rule

    /// Every conjunct of the start rule, falsified one at a time.
    ///
    /// One assertion per condition, each varying a single field of a baseline that does start. That
    /// shape is what makes each condition independently load-bearing: deleting any one of them from
    /// the implementation fails exactly one assertion here, by name.
    func testStartFiresOnlyWhenEveryConditionHolds() {
        let baseline = event(.keyDown, space, [.option])
        XCTAssertEqual(
            decide(baseline, state: .idle, config: chord), start,
            "The baseline must start, or every negative case below is asserting nothing.")

        XCTAssertEqual(
            decide(event(.keyUp, space, [.option]), state: .idle, config: chord), ignorePassing,
            "Only a key-*down* starts a session.")
        XCTAssertEqual(
            decide(event(.flagsChanged, space, [.option]), state: .idle, config: chord),
            ignorePassing, "A flagsChanged carrying the chord is not a press of the key.")
        XCTAssertEqual(
            decide(event(.tapDisabled, space, [.option]), state: .idle, config: chord),
            ignorePassing, "A dead tap starts nothing.")
        XCTAssertEqual(
            decide(event(.keyDown, letterA, [.option]), state: .idle, config: chord), ignorePassing,
            "Option+A is not Option+Space.")
        XCTAssertEqual(
            decide(event(.keyDown, space, []), state: .idle, config: chord), ignorePassing,
            "Space without Option is a space, and must reach the app that wanted it.")
        XCTAssertEqual(
            decide(event(.keyDown, space, [.shift]), state: .idle, config: chord), ignorePassing,
            "A different modifier is not the configured one.")
        XCTAssertEqual(
            decide(event(.keyDown, space, [.option], autorepeat: true), state: .idle, config: chord),
            ignorePassing, "Autorepeat is the OS repeating a press, not the user making one.")
        XCTAssertEqual(
            decide(baseline, state: .recording, config: chord), ignoreSwallowing,
            "A session is already in flight — starting a second one is the double-start bug.")
        XCTAssertEqual(
            decide(baseline, state: .ending, config: chord), ignoreSwallowing,
            "The previous session is still handing off; .ending exists precisely to refuse this.")
    }

    /// Extra modifiers are tolerated. Caps lock being on must not stop a hotkey working, and the
    /// rule is `⊇`, not `==`, for exactly that reason.
    func testStartToleratesModifiersBeyondTheConfiguredChord() {
        XCTAssertEqual(
            decide(event(.keyDown, space, [.option, .capsLock]), state: .idle, config: chord), start)
        XCTAssertEqual(
            decide(
                event(.keyDown, space, [.option, .shift, .command, .capsLock, .function, .control]),
                state: .idle, config: chord), start)
    }

    // MARK: - Stop rule (a): key-up

    func testKeyUpOnTheConfiguredKeyEndsTheSession() {
        XCTAssertEqual(
            decide(event(.keyUp, space, [.option]), state: .recording, config: chord),
            stop(.keyUp, .swallow))

        // The app never saw the key-down — Vocca swallowed it — so it must not see the key-up.
        XCTAssertEqual(
            decide(event(.keyUp, letterA, [.option]), state: .recording, config: chord),
            ignorePassing, "A key-up for someone else's key ends nothing and belongs to them.")
    }

    // MARK: - Stop rule (b): the modifier goes first

    /// The single likeliest cause of a stuck recording, and both halves of it.
    ///
    /// Releasing Option before Space produces a `flagsChanged`, not a `keyUp` on Space. A matcher
    /// that waits for the key-up waits forever. And the key-up *does* eventually arrive — after the
    /// session has already ended — so the second half matters as much as the first: it must not
    /// start a session, and it must not end one that is no longer running.
    func testReleasingTheModifierFirstEndsTheSessionAndTheLaterKeyUpDoesNothing() {
        for handoffEvents in [0, 1, 3] {
            var driver = SessionDriver(handoffEvents: handoffEvents)
            driver.feed(
                [
                    event(.flagsChanged, 0, [.option], at: 0),
                    event(.keyDown, space, [.option], at: 10),
                    // Option released first. This is the event that ends the session.
                    event(.flagsChanged, 0, [], at: 900),
                    // ...and this is the one that arrives afterwards and must do nothing.
                    event(.keyUp, space, [], at: 950),
                    event(.keyUp, space, [], at: 1200),
                ], using: decideChord)

            XCTAssertEqual(
                driver.starts, 1, "handoff=\(handoffEvents): exactly one session should have begun.")
            XCTAssertEqual(
                driver.stops, [.retained(.modifierReleased)],
                """
                handoff=\(handoffEvents): the session must end once, on the flagsChanged that \
                dropped Option — and the key-ups that follow must not end it again. Got \
                \(driver.stops).
                """)
            XCTAssertFalse(
                driver.isStuck, "handoff=\(handoffEvents): the microphone was left open.")
        }
    }

    /// The same, one call at a time: a `flagsChanged` that no longer carries the chord is a stop,
    /// and one that still carries it is not.
    func testFlagsChangedIsAStopOnlyWhenTheChordIsGone() {
        XCTAssertEqual(
            decide(event(.flagsChanged, 0, []), state: .recording, config: chord),
            stop(.modifierReleased, .passThrough))
        XCTAssertEqual(
            decide(event(.flagsChanged, 0, [.shift]), state: .recording, config: chord),
            stop(.modifierReleased, .passThrough),
            "Swapping Option for Shift is still a release of Option.")
        XCTAssertEqual(
            decide(event(.flagsChanged, 0, [.option, .shift]), state: .recording, config: chord),
            ignorePassing, "Adding Shift while holding Option leaves the chord intact.")
    }

    // MARK: - Stop rule (c): any event that lost the chord

    /// Rule (c) is free, because every keyboard event already carries the full current modifier
    /// state. This asserts it across every kind that carries meaningful flags — which is what makes
    /// it *free* rather than merely *implemented for `flagsChanged`*.
    func testAnyEventThatLostTheConfiguredModifiersEndsTheSession() {
        let expected = stop(.modifierReleased, .passThrough)
        XCTAssertEqual(
            decide(event(.keyDown, letterA, []), state: .recording, config: chord), expected,
            "The user typed a letter with Option already released.")
        XCTAssertEqual(
            decide(event(.keyUp, letterA, []), state: .recording, config: chord), expected,
            "A key-up for another key still reports the current modifiers.")
        XCTAssertEqual(
            decide(event(.flagsChanged, 0, []), state: .recording, config: chord), expected)
        XCTAssertEqual(
            decide(event(.keyDown, letterB, [.command]), state: .recording, config: chord), expected,
            "Command+B is not Option-anything.")
    }

    // MARK: - Stop rule (d): the tap died

    /// The key-up is never coming, so nothing else can end this session.
    ///
    /// Also pins the attribution. A tap-disabled notification carries no meaningful modifier flags,
    /// so a rule order that tested the modifiers first would end the session for the right reason
    /// by accident and report the wrong one — and `.tapDisabled` is the reason that tells whoever
    /// reads the log that the tap needs re-enabling.
    func testTapDisabledEndsTheSessionAndIsAttributedToTheTap() {
        XCTAssertEqual(
            decide(event(.tapDisabled, 0, []), state: .recording, config: chord),
            stop(.tapDisabled, .passThrough))
        XCTAssertEqual(
            decide(event(.tapDisabled, space, [.option]), state: .recording, config: chord),
            stop(.tapDisabled, .passThrough),
            "Whatever flags a tap-disabled notification happens to carry, it is still the tap.")
        XCTAssertEqual(
            decide(event(.tapDisabled, 0, []), state: .idle, config: chord), ignorePassing,
            "A dead tap with no session in flight ends nothing.")
    }

    // MARK: - Autorepeat

    /// Held keys produce a stream of key-downs. Neither end of the session may move on one.
    ///
    /// Restarting would be the double-start bug; ending would cut the user off after the OS's
    /// repeat delay, which is roughly half a second into every sentence they speak.
    func testAutorepeatDuringRecordingNeitherRestartsNorEndsTheSession() {
        var driver = SessionDriver()
        driver.feed(event(.keyDown, space, [.option], at: 0), using: decideChord)
        for repeatIndex in 1...40 {
            let decision = driver.feed(
                event(.keyDown, space, [.option], autorepeat: true, at: 500 + repeatIndex * 30),
                using: decideChord)
            XCTAssertEqual(
                decision, ignoreSwallowing,
                """
                Autorepeat #\(repeatIndex) must change nothing about the session — and must not \
                reach the focused app, which never saw the key-down that Vocca swallowed.
                """)
        }
        driver.feed(event(.keyUp, space, [.option], at: 2000), using: decideChord)

        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.stops, [.retained(.keyUp)])
        XCTAssertFalse(driver.isStuck)
    }

    func testAutorepeatInIdleDoesNotStartASession() {
        var driver = SessionDriver()
        for repeatIndex in 0..<10 {
            driver.feed(
                event(.keyDown, space, [.option], autorepeat: true, at: repeatIndex * 30),
                using: decideChord)
        }
        XCTAssertEqual(
            driver.starts, 0,
            """
            A repeat with no session in flight is the tail of a press whose session already ended \
            — the ceiling fired, or the poll did. It must not open the microphone again.
            """)
        XCTAssertEqual(driver.stops, [])
    }

    // MARK: - Events that are not ours

    func testAKeyDownForADifferentKeyDuringRecordingDoesNotEndTheSession() {
        var driver = SessionDriver()
        driver.feed(event(.keyDown, space, [.option], at: 0), using: decideChord)
        for (index, key) in [letterA, letterB, UInt16(12), UInt16(13)].enumerated() {
            let decision = driver.feed(
                event(.keyDown, key, [.option], at: 100 + index * 50), using: decideChord)
            XCTAssertEqual(
                decision, ignorePassing,
                """
                A key that is not the hotkey, pressed while the chord is still held, is the user \
                typing. It ends nothing and it must reach the app.
                """)
        }
        XCTAssertEqual(driver.state, .recording)
        XCTAssertEqual(driver.stops, [])
    }

    /// `.ending` means the previous session's audio is still in flight. Everything is a no-op —
    /// including a fresh, fully valid press of the hotkey, which is the double-start bug.
    func testEveryEventArrivingWhileEndingIsASafeNoOp() {
        for kind in RawKeyEvent.Kind.allCases {
            for keyCode in [space, letterA] {
                for modifiers in [ModifierSet(), [.option], [.option, .shift], [.shift]] {
                    for autorepeat in [false, true] {
                        let decision = decide(
                            event(kind, keyCode, modifiers, autorepeat: autorepeat),
                            state: .ending, config: chord)
                        XCTAssertEqual(
                            decision.action, .ignore,
                            """
                            \(kind)/key \(keyCode)/\(modifiers.rawValue)/repeat=\(autorepeat) was \
                            acted on while a session was still handing off. Nothing may start a \
                            session from .ending, and nothing may end one that has already ended.
                            """)
                    }
                }
            }
        }
    }

    // MARK: - The accumulation trap

    /// A dropped `flagsChanged` must not leave the microphone open.
    ///
    /// The OS disables event taps under load without warning, so events *are* dropped. An
    /// implementation with a running modifier total that misses the release believes Option is
    /// still held forever after — which is [Handy #840](https://github.com/cjpais/Handy/issues/840)
    /// exactly. Deriving from the event in hand cannot desynchronise, because there is nothing to
    /// synchronise.
    func testADroppedFlagsChangedStillEndsTheSession() {
        var driver = SessionDriver()
        driver.feed(droppedReleaseSequence, using: decideChord)

        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(
            driver.stops, [.retained(.modifierReleased)],
            """
            The flagsChanged announcing Option's release never arrived. The next event still \
            carried the truth — no Option — and that has to be enough, because a stop that depends \
            on an event the OS may drop is a stuck recording waiting for load.
            """)
        XCTAssertFalse(driver.isStuck, "The microphone was left open after a dropped event.")
    }

    /// The positive control for the test above, sharing its driver and its sequence.
    ///
    /// Without this, "the session ended" cannot be told apart from "the driver cannot see a session
    /// that did not end". The accumulating decider is the defect written on purpose; if it ever
    /// stops looking stuck here, the test above has stopped proving anything.
    func testTheDriverCanObserveASessionThatFailsToEnd() {
        let accumulator = AccumulatingDecider(config: chord)
        var driver = SessionDriver()
        driver.feed(droppedReleaseSequence, using: accumulator.decide)

        XCTAssertEqual(driver.starts, 1, "The control must get as far as starting a session.")
        XCTAssertEqual(
            driver.stops, [],
            "The accumulating decider is supposed to miss the stop — that is what it is for.")
        XCTAssertTrue(
            driver.isStuck,
            """
            The control did not produce a stuck session, so the mechanism that asserts the real \
            rules avoid one has never been shown to detect the failure it rules out.
            """)
    }

    /// The other direction: a dropped `flagsChanged` that would *not* have ended anything must not
    /// produce a stop either. Deriving state per event is only correct if it is correct both ways —
    /// a rule that ends the session whenever it is unsure would pass the test above and cut the
    /// user off mid-sentence every time they pressed Shift.
    func testADroppedFlagsChangedThatStillCarriesTheChordDoesNotEndTheSession() {
        var driver = SessionDriver()
        driver.feed(
            [
                event(.flagsChanged, 0, [.option], at: 0),
                event(.keyDown, space, [.option], at: 10),
                // Dropped here: flagsChanged reporting [.option, .shift].
                event(.keyDown, letterA, [.option, .shift], at: 400),
                event(.keyUp, letterA, [.option, .shift], at: 450),
                event(.keyUp, space, [.option, .shift], at: 900),
            ], using: decideChord)

        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(
            driver.stops, [.retained(.keyUp)],
            "The chord was held throughout; the only stop is the key-up that really happened.")
    }

    private var droppedReleaseSequence: [RawKeyEvent] {
        [
            event(.flagsChanged, 0, [.option], at: 0),
            event(.keyDown, space, [.option], at: 10),
            event(.keyDown, space, [.option], autorepeat: true, at: 540),
            // Dropped here: the flagsChanged reporting that Option came up.
            event(.keyDown, letterA, [], at: 900),
        ]
    }

    // MARK: - Configurations without modifiers

    /// `isSuperset(of: [])` is always true, so rules (b) and (c) are vacuous for a bare hotkey.
    /// They must therefore never fire — a stop attributed to a modifier that was never configured
    /// is a session ended for a reason that does not exist.
    func testAConfigurationWithoutModifiersNeverEndsForAModifierRelease() {
        for kind in RawKeyEvent.Kind.allCases {
            for modifiers in [ModifierSet(), [.option], [.command, .shift]] {
                let decision = decide(
                    event(kind, letterA, modifiers), state: .recording, config: bareKey)
                if case .stop(let reason) = decision.action {
                    XCTAssertEqual(
                        reason, .retained(.tapDisabled),
                        """
                        \(kind) with modifiers \(modifiers.rawValue) ended a bare-key session for \
                        \(reason). The only stop available to an unrelated event under a hotkey \
                        with no modifiers is the dead tap.
                        """)
                }
            }
        }

        var driver = SessionDriver()
        driver.feed(
            [
                event(.keyDown, bareKey.keyCode, [], at: 0),
                event(.flagsChanged, 0, [.shift], at: 100),
                event(.flagsChanged, 0, [], at: 200),
                event(.keyDown, letterA, [.command], at: 300),
                event(.keyUp, bareKey.keyCode, [], at: 400),
            ], using: { decide($0, state: $1, config: bareKey) })
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.stops, [.retained(.keyUp)])
    }

    // MARK: - Combinations

    /// When two stop rules fire on the same event, which reason is reported is a decision, not an
    /// accident. Pinned here so a reordering of the branches shows up as a failure rather than as a
    /// misleading entry in a log.
    func testStopPrecedenceIsStableWhenSeveralRulesFireAtOnce() {
        // (a) and (c): the user released Option and Space close enough together that the key-up
        // already reports no modifiers. It is still the key-up that ended it.
        XCTAssertEqual(
            decide(event(.keyUp, space, []), state: .recording, config: chord),
            stop(.keyUp, .swallow))

        // (d) beats everything. The flags on a tap-disabled notification mean nothing.
        XCTAssertEqual(
            decide(event(.tapDisabled, space, []), state: .recording, config: chord),
            stop(.tapDisabled, .passThrough))

        // (c) on a key-down for the configured key with the chord already gone: the chord is not
        // held, so this is the user typing a space, and it must reach them.
        XCTAssertEqual(
            decide(event(.keyDown, space, []), state: .recording, config: chord),
            stop(.modifierReleased, .passThrough))

        // A fresh, non-repeat press of the whole chord while already recording. Hold-to-talk has
        // six stop rules and this is not one of them; a missed key-up is the ceiling's and the
        // poll's problem, and restarting here would be the double-start bug. Toggle mode (task 6)
        // is where this event becomes `.toggledOff`.
        XCTAssertEqual(
            decide(event(.keyDown, space, [.option]), state: .recording, config: chord),
            ignoreSwallowing)
    }

    // MARK: - Purity

    /// Same inputs, same output — across 10,000 randomised events, and independent of the order
    /// they are evaluated in.
    ///
    /// The order half is the one that matters. Calling `decide` twice in a row catches nothing that
    /// a stored modifier field would not survive; evaluating the whole batch forwards and then
    /// backwards catches any state carried between calls, which is the only way this function could
    /// accumulate anything. ``SessionDecisionTests/testTheDriverCanObserveASessionThatFailsToEnd``
    /// is the behavioural half of the same prohibition.
    func testDecideIsPureAcrossTenThousandRandomisedSequences() {
        var generator = SeededGenerator(seed: 0x5EED_0DEC_1DE0_0001)
        let cases = (0..<10_000).map { _ in randomCase(using: &generator) }

        let forward = cases.map { decide($0.event, state: $0.state, config: $0.config) }
        let backward = cases.reversed().map {
            decide($0.event, state: $0.state, config: $0.config)
        }.reversed()

        XCTAssertEqual(
            Array(forward), Array(backward),
            """
            decide returned different answers for the same inputs depending on the order the \
            inputs were evaluated in. Something is being carried between calls — which is the \
            defect this whole aspect exists to prevent.
            """)

        // A third pass, interleaved with unrelated calls, so that "the batch is deterministic"
        // cannot be satisfied by state that happens to cycle with the same period.
        for testCase in cases.prefix(2_000) {
            _ = decide(event(.tapDisabled, 7, [.command]), state: .recording, config: bareKey)
            XCTAssertEqual(
                decide(testCase.event, state: testCase.state, config: testCase.config),
                decide(testCase.event, state: testCase.state, config: testCase.config))
        }

        // The timestamp is carried for task 4's ceiling and is not an input to any rule here. If it
        // ever becomes one, this fails — which is the point: a clock-dependent `decide` is not pure.
        for testCase in cases.prefix(2_000) {
            let shifted = RawKeyEvent(
                kind: testCase.event.kind, keyCode: testCase.event.keyCode,
                modifiers: testCase.event.modifiers, isAutorepeat: testCase.event.isAutorepeat,
                timestamp: testCase.event.timestamp + .seconds(3_600))
            XCTAssertEqual(
                decide(shifted, state: testCase.state, config: testCase.config),
                decide(testCase.event, state: testCase.state, config: testCase.config),
                "The timestamp changed the decision. decide has no clock and must consult none.")
        }
    }

    /// Sequences, not just events: 500 randomised runs through the driver, twice, must produce
    /// identical traces — and must never leave a session open with no session ever started.
    func testRandomisedSequencesAreReproducibleAndNeverDoubleStart() {
        var generator = SeededGenerator(seed: 0x5EED_0DEC_1DE0_0002)
        var mismatches = 0
        var checkedStarts = 0

        for run in 0..<500 {
            let events = (0..<20).map { index -> RawKeyEvent in
                var testCase = randomCase(using: &generator)
                testCase.event = RawKeyEvent(
                    kind: testCase.event.kind, keyCode: testCase.event.keyCode,
                    modifiers: testCase.event.modifiers, isAutorepeat: testCase.event.isAutorepeat,
                    timestamp: .milliseconds(index * 40))
                return testCase.event
            }
            let config = run.isMultiple(of: 2) ? chord : bareKey
            let decider: (RawKeyEvent, SessionState) -> Decision = {
                decide($0, state: $1, config: config)
            }

            var first = SessionDriver(handoffEvents: run % 3)
            var second = SessionDriver(handoffEvents: run % 3)
            first.feed(events, using: decider)
            second.feed(events, using: decider)
            if first.decisions != second.decisions { mismatches += 1 }

            // No start may be issued while a session is in flight, and no stop while none is. The
            // driver's own state is the witness, and it moves only on the decisions themselves.
            var state = SessionState.idle
            for event in events {
                let decision = decider(event, state)
                switch decision.action {
                case .start:
                    XCTAssertEqual(state, .idle, "A start was issued from \(state).")
                    checkedStarts += 1
                    state = .recording
                case .stop:
                    XCTAssertEqual(state, .recording, "A stop was issued from \(state).")
                    state = .idle
                case .ignore:
                    break
                }
            }
        }

        XCTAssertEqual(mismatches, 0, "\(mismatches) of 500 sequences were not reproducible.")
        XCTAssertGreaterThan(
            checkedStarts, 0,
            "No randomised sequence ever started a session, so the invariants above checked nothing.")
    }

    // MARK: - The reasons this function does not own

    /// `decide` produces exactly three reasons, and the other five come from somewhere else.
    ///
    /// The ceiling (e) and the poll (f) have no `RawKeyEvent` representation at all — task 4 fires
    /// them from the clock and the physical-key read, and routes them through the same stop funnel.
    /// `.toggledOff` is task 6's. `.systemEvent` and `.userCancelled` arrive on their own paths.
    /// Asserting the vocabulary here is what keeps a future edit from inventing a key event that
    /// claims to be a ceiling expiry — which would put a timing decision inside a function with no
    /// clock, where it could never be tested.
    func testDecideNeverProducesAReasonItDoesNotOwn() {
        var produced: Set<RetainedEndReason> = []
        var cancellations = 0

        for testCase in Self.wholeInputSpace() {
            switch decide(testCase.event, state: testCase.state, config: testCase.config).action {
            case .stop(.retained(let reason)):
                produced.insert(reason)
            case .stop(.userCancelled):
                cancellations += 1
            case .start, .ignore:
                break
            }
        }

        XCTAssertEqual(
            produced, [.keyUp, .modifierReleased, .tapDisabled],
            """
            decide's reason vocabulary changed. It owns (a), (b)/(c) and (d); the ceiling, the \
            poll, toggle-off, the system triggers and cancellation are decided elsewhere and \
            merely travel through `Decision`.
            """)
        XCTAssertEqual(
            cancellations, 0,
            "A key event produced .userCancelled — the one reason permitted to discard audio.")

        // The other half of the claim: `Decision` does carry every reason, so routing one through
        // costs nothing. This is what "decide must accept it if routed through" amounts to for a
        // function whose only input is a key event.
        for reason in EndReason.allCases {
            let routed = Decision(action: .stop(reason), eventPropagation: .passThrough)
            guard case .stop(let carried) = routed.action else {
                return XCTFail("Decision.stop did not carry \(reason).")
            }
            XCTAssertEqual(carried, reason)
        }
    }

    // MARK: - The whole input space

    /// Every combination of kind, key, modifiers, autorepeat, state and configuration — checked
    /// against the invariants rather than against a second copy of the table.
    ///
    /// The golden rows above are exact and few. This is exhaustive and states properties, which is
    /// the pairing that survives someone asking "what about the sequence you did not think of":
    /// there is no such combination, because the space is enumerated.
    ///
    /// The load-bearing one is ``anyEventMeaningTheUserStoppedAsking``. If it holds for every cell,
    /// no single event can leave the microphone open.
    func testTheWholeInputSpaceSatisfiesTheSessionInvariants() {
        let inputSpace = Self.wholeInputSpace()
        XCTAssertEqual(
            inputSpace.count, 4 * 2 * 4 * 2 * 3 * 2,
            "The enumeration lost a dimension; it is no longer exhaustive over the inputs.")

        var starts = 0
        var stops = 0
        var swallows = 0
        for testCase in inputSpace {
            let event = testCase.event
            let config = testCase.config
            let decision = decide(event, state: testCase.state, config: config)
            let label =
                "\(event.kind)/key=\(event.keyCode)/mods=\(event.modifiers.rawValue)/"
                + "repeat=\(event.isAutorepeat)/state=\(testCase.state)/cfg=\(config.keyCode)"

            let matchesKey = event.keyCode == config.keyCode
            let carriesChord = event.modifiers.isSuperset(of: config.modifiers)
            let isKeyDown = event.kind == .keyDown
            let startRuleHolds =
                testCase.state == .idle && isKeyDown && matchesKey && carriesChord
                && !event.isAutorepeat
            let userStoppedAsking =
                testCase.state == .recording
                && (event.kind == .tapDisabled || (event.kind == .keyUp && matchesKey)
                    || !carriesChord)

            switch decision.action {
            case .start:
                starts += 1
                XCTAssertTrue(startRuleHolds, "\(label): started a session the rule does not allow.")
            case .stop(let reason):
                stops += 1
                XCTAssertEqual(
                    testCase.state, .recording, "\(label): stopped with no session in flight.")
                XCTAssertTrue(userStoppedAsking, "\(label): stopped for \(reason) with no rule met.")
                // The attribution, pinned in the same order the rules are applied.
                let expected: RetainedEndReason =
                    event.kind == .tapDisabled
                    ? .tapDisabled : (event.kind == .keyUp && matchesKey ? .keyUp : .modifierReleased)
                XCTAssertEqual(reason, .retained(expected), "\(label): wrong reason.")
            case .ignore:
                XCTAssertFalse(startRuleHolds, "\(label): the start rule held and nothing started.")
                XCTAssertFalse(
                    userStoppedAsking,
                    """
                    \(label): the user stopped asking and the session did not end. This is the \
                    stuck recording — a hot microphone with the widget showing nothing.
                    """)
            }

            // Propagation: Vocca swallows the press that starts a session, and thereafter the key
            // events for its own key while a session is in flight — the app never saw the key-down,
            // so it must not see the repeats or the key-up. It swallows nothing else, because a
            // tool that eats keystrokes it did not claim makes the whole machine feel broken.
            let sessionInFlight = testCase.state != .idle
            let claimsTheKey =
                sessionInFlight && matchesKey
                && (event.kind == .keyUp || (isKeyDown && carriesChord))
            let shouldSwallow = startRuleHolds || claimsTheKey
            if shouldSwallow { swallows += 1 }
            XCTAssertEqual(
                decision.eventPropagation, shouldSwallow ? .swallow : .passThrough, "\(label)")
        }

        // Positive controls for the three branches above: an invariant that no case ever reaches is
        // an invariant nobody has seen hold.
        XCTAssertGreaterThan(starts, 0, "No cell in the space started a session.")
        XCTAssertGreaterThan(stops, 0, "No cell in the space stopped one.")
        XCTAssertGreaterThan(swallows, 0, "No cell in the space was swallowed.")
    }

    /// A `.recording` cell must be a stop exactly when the user stopped asking — restated as its
    /// own test so the failure names the defect rather than one assertion among a dozen.
    func testNoSingleEventCanLeaveTheMicrophoneOpen() {
        var covered: Set<String> = []
        for testCase in Self.wholeInputSpace() where testCase.state == .recording {
            let event = testCase.event
            let matchesKey = event.keyCode == testCase.config.keyCode
            let carriesChord = event.modifiers.isSuperset(of: testCase.config.modifiers)

            let trigger: String?
            switch event.kind {
            case .tapDisabled: trigger = "d/tapDisabled"
            case .keyUp where matchesKey: trigger = "a/keyUp"
            case .flagsChanged where !carriesChord: trigger = "b/flagsChanged"
            case .keyDown, .keyUp, .flagsChanged: trigger = carriesChord ? nil : "c/anyEvent"
            }
            guard let trigger else { continue }
            covered.insert(trigger)

            guard case .stop = decide(event, state: .recording, config: testCase.config).action
            else {
                return XCTFail(
                    """
                    Stop rule (\(trigger)) did not end the session for \(event.kind), key \
                    \(event.keyCode), modifiers \(event.modifiers.rawValue). The microphone stays \
                    open with nothing holding it there.
                    """)
            }
        }
        XCTAssertEqual(
            covered, ["a/keyUp", "b/flagsChanged", "c/anyEvent", "d/tapDisabled"],
            "The input space stopped exercising one of the four rules decide owns.")
    }

    // MARK: - Space and randomisation helpers

    private struct InputCase {
        var config: HotkeyConfiguration
        var event: RawKeyEvent
        var state: SessionState
    }

    private static let modifierValues: [ModifierSet] = [
        [], [.option], [.option, .capsLock], [.shift],
    ]

    /// Every combination the rules can see: 4 kinds × 2 key codes × 4 modifier sets × 2 autorepeat
    /// values × 3 states × 2 configurations = 384 cells.
    private static func wholeInputSpace() -> [InputCase] {
        var cases: [InputCase] = []
        for config in [chord, bareKey] {
            for kind in RawKeyEvent.Kind.allCases {
                for keyCode in [config.keyCode, letterA] {
                    for modifiers in modifierValues {
                        for autorepeat in [false, true] {
                            cases.append(
                                InputCase(
                                    config: config,
                                    event: event(kind, keyCode, modifiers, autorepeat: autorepeat),
                                    state: .idle))
                            cases.append(
                                InputCase(
                                    config: config,
                                    event: event(kind, keyCode, modifiers, autorepeat: autorepeat),
                                    state: .recording))
                            cases.append(
                                InputCase(
                                    config: config,
                                    event: event(kind, keyCode, modifiers, autorepeat: autorepeat),
                                    state: .ending))
                        }
                    }
                }
            }
        }
        return cases
    }

    private func randomCase(using generator: inout SeededGenerator) -> InputCase {
        let kinds = RawKeyEvent.Kind.allCases
        let states = SessionState.allCases
        let config = Bool.random(using: &generator) ? chord : bareKey
        return InputCase(
            config: config,
            event: RawKeyEvent(
                kind: kinds[Int.random(in: 0..<kinds.count, using: &generator)],
                keyCode: [config.keyCode, letterA, letterB, 200][
                    Int.random(in: 0..<4, using: &generator)],
                modifiers: ModifierSet(rawValue: UInt16.random(in: 0...0b11_1111, using: &generator)),
                isAutorepeat: Bool.random(using: &generator),
                timestamp: .milliseconds(Int.random(in: 0...600_000, using: &generator))),
            state: states[Int.random(in: 0..<states.count, using: &generator)])
    }
}
