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

/// A **two-modifier** chord, and the reason it exists is that with 0 or 1 configured modifiers
/// `⊇` is indistinguishable from "any configured modifier is still held".
///
/// A suite testing only ⌥Space and a bare key stays green while the chord predicate means
/// *intersects* rather than *contains all* — measured, on this suite, at 75/75. Shipped, that is
/// two defects at once, both of the class this aspect exists to prevent: a user who configured
/// ⌃⌥Space releases Control but leaves Option resting on the key and the microphone never closes
/// (Handy #840's user-visible failure, reached by a different route), and ⌥Space alone steals the
/// hotkey. ⌃⌥Space, ⌘⇧Space and ⌃⌘Space are all ordinary bindings, and `PRODUCT_SPEC.md:127` names
/// a two-modifier chord as the converse-mode default.
private let twoModifier = HotkeyConfiguration(
    keyCode: space, modifiers: [.control, .option], activation: .holdToTalk)

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

    /// A chord is matched **as a whole**, not in part — on both the start and the stop side.
    ///
    /// Every other test here configures one modifier or none, and for those `⊇` cannot be told
    /// apart from "any configured modifier is present". This is the test that separates them, and
    /// each half names a real defect:
    ///
    /// - **Hotkey theft.** ⌥Space starting a session configured as ⌃⌥Space.
    /// - **Stuck microphone.** Control released while Option stays resting on the key: half the
    ///   chord is gone, the session must end, and an `intersects` reading leaves the mic open with
    ///   the widget showing nothing.
    func testAMultiModifierChordIsMatchedAsAWholeNotInPart() {
        // Start: exact.
        XCTAssertEqual(
            decide(event(.keyDown, space, [.control, .option]), state: .idle, config: twoModifier),
            start, "The exact configured chord must start a session.")

        // Start: a superset. An extra modifier resting on the keyboard must not block the hotkey.
        XCTAssertEqual(
            decide(
                event(.keyDown, space, [.control, .option, .capsLock]), state: .idle,
                config: twoModifier), start)
        XCTAssertEqual(
            decide(
                event(.keyDown, space, [.control, .option, .shift, .command]), state: .idle,
                config: twoModifier), start)

        // No start: any strict subset. Both halves, because a predicate that is wrong in one
        // direction is usually wrong in only one.
        for partial: ModifierSet in [[], [.option], [.control], [.shift], [.option, .shift]] {
            XCTAssertEqual(
                decide(event(.keyDown, space, partial), state: .idle, config: twoModifier),
                ignorePassing,
                """
                Modifiers \(partial.rawValue) started a session configured as Control+Option. Part \
                of a chord is not the chord — this is the hotkey being stolen from the user's \
                actual binding, and the keystroke being eaten from the app that wanted it.
                """)
        }

        // Stop: releasing ONE of the two required modifiers ends it. This is the one that matters.
        XCTAssertEqual(
            decide(event(.flagsChanged, 0, [.option]), state: .recording, config: twoModifier),
            stop(.modifierReleased, .passThrough),
            "Half a chord is not the chord. Control came up; the microphone must close.")
        XCTAssertEqual(
            decide(event(.flagsChanged, 0, [.control]), state: .recording, config: twoModifier),
            stop(.modifierReleased, .passThrough),
            "The other half, released on its own.")

        // ...and rule (c): the same partial chord observed on any other kind of event.
        for kind in [RawKeyEvent.Kind.keyDown, .keyUp] {
            XCTAssertEqual(
                decide(event(kind, letterA, [.option]), state: .recording, config: twoModifier),
                stop(.modifierReleased, .passThrough),
                "A \(kind) reporting half the chord is still a released modifier.")
        }

        // No spurious stop while the whole chord is genuinely held.
        XCTAssertEqual(
            decide(
                event(.flagsChanged, 0, [.control, .option, .shift]), state: .recording,
                config: twoModifier), ignorePassing,
            "Adding Shift to a held chord is not releasing any part of it.")

        // The whole gesture, in sequence: press both, release one, and the later key-up does
        // nothing — B3 for a chord rather than for a single modifier.
        var driver = SessionDriver(handoffEvents: 1)
        driver.feed(
            [
                event(.flagsChanged, 0, [.control], at: 0),
                event(.flagsChanged, 0, [.control, .option], at: 30),
                event(.keyDown, space, [.control, .option], at: 60),
                event(.keyDown, space, [.control, .option], autorepeat: true, at: 600),
                // Control released; Option still resting on the key.
                event(.flagsChanged, 0, [.option], at: 900),
                event(.keyUp, space, [.option], at: 950),
                event(.flagsChanged, 0, [], at: 980),
            ], using: { decide($0, state: $1, config: twoModifier) })
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(
            driver.stops, [.retained(.modifierReleased)],
            "Exactly one stop, on the half-chord release — not on the key-up that follows it.")
        XCTAssertFalse(driver.isStuck)
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

    /// Sequences, not just events: 10,000 randomised runs through the driver, twice, must produce
    /// identical traces — and must never leave a session open with no session ever started.
    ///
    /// Ten thousand because B11 says *sequences*. The test above runs 10,000 randomised **events**,
    /// which is the stronger check for purity but is not what the criterion's text asks for; this
    /// one meets it literally, at 20 events each.
    func testRandomisedSequencesAreReproducibleAndNeverDoubleStart() {
        var generator = SeededGenerator(seed: 0x5EED_0DEC_1DE0_0002)
        var mismatches = 0
        var checkedStarts = 0

        for run in 0..<10_000 {
            let events = (0..<20).map { index -> RawKeyEvent in
                var testCase = randomCase(using: &generator)
                testCase.event = RawKeyEvent(
                    kind: testCase.event.kind, keyCode: testCase.event.keyCode,
                    modifiers: testCase.event.modifiers, isAutorepeat: testCase.event.isAutorepeat,
                    timestamp: .milliseconds(index * 40))
                return testCase.event
            }
            let config = Self.configurations[run % Self.configurations.count]
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

        XCTAssertEqual(mismatches, 0, "\(mismatches) of 10,000 sequences were not reproducible.")
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

        // The complement, named rather than implied: exactly which reasons must come from
        // somewhere else. Derived from `RetainedEndReason.allCases`, so it fails from either side
        // — if `decide` starts producing one of these, or if a reason is dropped from the
        // vocabulary and silently stops being anybody's responsibility.
        //
        // (The previous version of this block constructed `Decision(action: .stop(reason))` and
        // asserted the same reason came back out. That tests that `Decision` is a storage struct;
        // it cannot fail while `Action.stop` has an associated value. That `Decision` carries every
        // reason — "decide must accept it if routed through" — is a compile-time fact, and
        // `SessionVocabularyTests` is where the vocabulary's completeness is asserted.)
        let ownedElsewhere = Set(RetainedEndReason.allCases).subtracting(produced)
        XCTAssertEqual(
            ownedElsewhere,
            Set(
                [.ceilingReached, .pollDetectedRelease, .toggledOff]
                    + SystemTrigger.allCases.map(RetainedEndReason.systemEvent)),
            """
            The split between the reasons decide owns and the reasons it does not has moved. \
            (e) ceiling and (f) poll are task 4's — one is a clock reading and the other a \
            physical-key read, and neither has a RawKeyEvent to be decided from. .toggledOff is \
            task 6's. The system triggers arrive on their own path.
            """)
    }

    // MARK: - The whole input space

    /// Every combination of kind, key, modifiers, autorepeat, state and configuration, checked
    /// against a **literal truth table** written out by hand.
    ///
    /// ## Which layer is which
    ///
    /// The suite makes three different kinds of claim, and reading one as another overstates it:
    ///
    /// - The **golden rows** above are independently derived from the spec, one behaviour each, and
    ///   are what carries the suite.
    /// - **This** is exhaustive over the input space. Its expectations live in
    ///   ``truthTable`` — 96 literal rows in a different *representation* from the implementation's
    ///   chain of conditionals, so a precedence or ordering mistake cannot be shared between them,
    ///   and changing the policy costs a visible table edit. The earlier version of this test
    ///   recomputed the expectation with the same expressions the production code uses, which
    ///   catches drift but cannot catch a shared misconception.
    /// - Exhaustive means **over one event**. It says nothing about sequences — the driver tests do
    ///   that — and the table encodes propagation decisions that are known trade-offs rather than
    ///   settled truths. The `.ending` key-up rows are the live example: see `SessionRules.swift`,
    ///   "What gets swallowed", and the plan's Phase 4.
    func testTheWholeInputSpaceMatchesTheTruthTable() {
        let inputSpace = Self.wholeInputSpace()
        XCTAssertEqual(
            inputSpace.count, 4 * 2 * 7 * 2 * 3 * 3,
            "The enumeration lost a dimension; it is no longer exhaustive over the inputs.")

        let table = Self.parsedTruthTable()
        XCTAssertEqual(
            table.count, 96,
            """
            The truth table is not 3 states × 4 kinds × 2 key matches × 2 chord states × 2 \
            autorepeat values = 96 rows. A missing row is a cell with no expectation; a duplicate \
            is two expectations for one cell.
            """)

        // The six modifiers the independent derivation below sweeps must be every modifier there
        // is, or "every configured modifier is held" silently means "every modifier I remembered".
        let sweep: [ModifierSet] = [.control, .option, .shift, .command, .function, .capsLock]
        XCTAssertEqual(
            sweep.reduce(into: ModifierSet()) { $0.formUnion($1) }.rawValue, 0b11_1111,
            "ModifierSet gained a modifier the chord derivation does not check.")

        var exercised: Set<Cell> = []
        var starts = 0
        var stops = 0
        var swallows = 0

        for testCase in inputSpace {
            let event = testCase.event
            let config = testCase.config
            let cell = Cell(
                state: testCase.state, kind: event.kind,
                keyMatches: event.keyCode == config.keyCode,
                chordHeld: Self.everyConfiguredModifierIsHeld(event: event, config: config),
                isAutorepeat: event.isAutorepeat)
            exercised.insert(cell)

            guard let expected = table[cell] else {
                return XCTFail("No truth-table row for \(cell).")
            }
            let actual = decide(event, state: testCase.state, config: config)
            XCTAssertEqual(
                actual, expected,
                """
                \(cell), config modifiers \(config.modifiers.rawValue), event modifiers \
                \(event.modifiers.rawValue): expected \(expected), got \(actual).
                """)

            switch actual.action {
            case .start: starts += 1
            case .stop: stops += 1
            case .ignore: break
            }
            if actual.eventPropagation == .swallow { swallows += 1 }
        }

        // Both directions. A table row no cell reaches is an expectation nobody has seen hold, and
        // a cell with no row would have failed above — together they make "exhaustive" mean it.
        XCTAssertEqual(
            exercised.count, 96,
            """
            The input space reaches only \(exercised.count) of the 96 descriptor cells, so the \
            table's other rows assert nothing. Missing: \
            \(Set(table.keys).subtracting(exercised).map(String.init(describing:)).sorted())
            """)

        // Positive controls: an assertion loop that never sees an outcome cannot fail on it.
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
            // The independent derivation, not the implementation's set operation — otherwise a
            // chord predicate meaning *intersects* would classify the cells the same wrong way it
            // decides them, and this test would agree with the defect.
            let carriesChord = Self.everyConfiguredModifierIsHeld(
                event: event, config: testCase.config)

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

    // MARK: - The truth table

    /// One cell of the decision space: everything `decide` is allowed to consult, and nothing else.
    ///
    /// The timestamp is deliberately absent — it is not an input to any rule, and the purity test
    /// asserts that separately.
    private struct Cell: Hashable, CustomStringConvertible {
        let state: SessionState
        let kind: RawKeyEvent.Kind
        let keyMatches: Bool
        let chordHeld: Bool
        let isAutorepeat: Bool

        var description: String {
            "\(state)/\(kind)/key=\(keyMatches)/chord=\(chordHeld)/repeat=\(isAutorepeat)"
        }
    }

    /// **Does the event carry every configured modifier?** — derived from the meaning of the rule,
    /// one modifier at a time, rather than from the set operation the implementation calls.
    ///
    /// This is the point of Finding 1. `event.modifiers.isSuperset(of: config.modifiers)` as an
    /// expectation is a transcription: it agrees with the code by construction, including when the
    /// code is wrong. Asking instead "for each modifier the user configured, is that modifier
    /// present in this event's own flags?" is the same question posed independently, and it
    /// separates `⊇` from `==` and from *intersects* — which a suite configured with 0 or 1
    /// modifiers cannot do at all.
    private static func everyConfiguredModifierIsHeld(
        event: RawKeyEvent, config: HotkeyConfiguration
    ) -> Bool {
        let everyModifier: [ModifierSet] = [
            .control, .option, .shift, .command, .function, .capsLock,
        ]
        return everyModifier.allSatisfy { modifier in
            !config.modifiers.contains(modifier) || event.modifiers.contains(modifier)
        }
    }

    /// The complete policy, as a table rather than as code.
    ///
    /// 96 rows: 3 states × 4 kinds × key-matches × chord-held × autorepeat. Written out in full on
    /// purpose — the whole policy is visible in one screen and can be read against `spec.md`'s rule
    /// table by eye, which is not true of a chain of conditionals.
    ///
    /// Reading the columns: `key` is "this event's key code is the configured one"; `chord` is
    /// "every configured modifier is present in this event's flags"; `rep` is autorepeat.
    ///
    /// Three groups of rows are worth arguing about before changing them:
    ///
    /// - `recording`/`keyUp`/`key=yes`/`chord=no` → `stop:keyUp`. Rule (a) beats (c): the user's own
    ///   gesture is the more specific fact when a key-up happens to report no modifiers.
    /// - `recording`/`tapDisabled` → `stop:tapDisabled` for every chord and key value. Rule (d) is
    ///   applied first because such an event's modifier flags mean nothing.
    /// - `ending`/`keyUp`/`key=yes` → `swallow`, while `ending`/`keyDown`/`key=yes`/`chord=no`
    ///   passes through. That asymmetry is a **known trade, not a settled truth**: it can leave the
    ///   focused app an unpaired key-down. A stateless function cannot do better, and Phase 4 of
    ///   the plan owns the fix. Pinned here so it changes on purpose.
    private static let truthTable = """
        # state      kind          key  chord  rep  action                  propagation
        idle         keyDown       yes  yes    no   start                   swallow
        idle         keyDown       yes  yes    yes  ignore                  passThrough
        idle         keyDown       yes  no     no   ignore                  passThrough
        idle         keyDown       yes  no     yes  ignore                  passThrough
        idle         keyDown       no   yes    no   ignore                  passThrough
        idle         keyDown       no   yes    yes  ignore                  passThrough
        idle         keyDown       no   no     no   ignore                  passThrough
        idle         keyDown       no   no     yes  ignore                  passThrough
        idle         keyUp         yes  yes    no   ignore                  passThrough
        idle         keyUp         yes  yes    yes  ignore                  passThrough
        idle         keyUp         yes  no     no   ignore                  passThrough
        idle         keyUp         yes  no     yes  ignore                  passThrough
        idle         keyUp         no   yes    no   ignore                  passThrough
        idle         keyUp         no   yes    yes  ignore                  passThrough
        idle         keyUp         no   no     no   ignore                  passThrough
        idle         keyUp         no   no     yes  ignore                  passThrough
        idle         flagsChanged  yes  yes    no   ignore                  passThrough
        idle         flagsChanged  yes  yes    yes  ignore                  passThrough
        idle         flagsChanged  yes  no     no   ignore                  passThrough
        idle         flagsChanged  yes  no     yes  ignore                  passThrough
        idle         flagsChanged  no   yes    no   ignore                  passThrough
        idle         flagsChanged  no   yes    yes  ignore                  passThrough
        idle         flagsChanged  no   no     no   ignore                  passThrough
        idle         flagsChanged  no   no     yes  ignore                  passThrough
        idle         tapDisabled   yes  yes    no   ignore                  passThrough
        idle         tapDisabled   yes  yes    yes  ignore                  passThrough
        idle         tapDisabled   yes  no     no   ignore                  passThrough
        idle         tapDisabled   yes  no     yes  ignore                  passThrough
        idle         tapDisabled   no   yes    no   ignore                  passThrough
        idle         tapDisabled   no   yes    yes  ignore                  passThrough
        idle         tapDisabled   no   no     no   ignore                  passThrough
        idle         tapDisabled   no   no     yes  ignore                  passThrough
        recording    keyDown       yes  yes    no   ignore                  swallow
        recording    keyDown       yes  yes    yes  ignore                  swallow
        recording    keyDown       yes  no     no   stop:modifierReleased   passThrough
        recording    keyDown       yes  no     yes  stop:modifierReleased   passThrough
        recording    keyDown       no   yes    no   ignore                  passThrough
        recording    keyDown       no   yes    yes  ignore                  passThrough
        recording    keyDown       no   no     no   stop:modifierReleased   passThrough
        recording    keyDown       no   no     yes  stop:modifierReleased   passThrough
        recording    keyUp         yes  yes    no   stop:keyUp              swallow
        recording    keyUp         yes  yes    yes  stop:keyUp              swallow
        recording    keyUp         yes  no     no   stop:keyUp              swallow
        recording    keyUp         yes  no     yes  stop:keyUp              swallow
        recording    keyUp         no   yes    no   ignore                  passThrough
        recording    keyUp         no   yes    yes  ignore                  passThrough
        recording    keyUp         no   no     no   stop:modifierReleased   passThrough
        recording    keyUp         no   no     yes  stop:modifierReleased   passThrough
        recording    flagsChanged  yes  yes    no   ignore                  passThrough
        recording    flagsChanged  yes  yes    yes  ignore                  passThrough
        recording    flagsChanged  yes  no     no   stop:modifierReleased   passThrough
        recording    flagsChanged  yes  no     yes  stop:modifierReleased   passThrough
        recording    flagsChanged  no   yes    no   ignore                  passThrough
        recording    flagsChanged  no   yes    yes  ignore                  passThrough
        recording    flagsChanged  no   no     no   stop:modifierReleased   passThrough
        recording    flagsChanged  no   no     yes  stop:modifierReleased   passThrough
        recording    tapDisabled   yes  yes    no   stop:tapDisabled        passThrough
        recording    tapDisabled   yes  yes    yes  stop:tapDisabled        passThrough
        recording    tapDisabled   yes  no     no   stop:tapDisabled        passThrough
        recording    tapDisabled   yes  no     yes  stop:tapDisabled        passThrough
        recording    tapDisabled   no   yes    no   stop:tapDisabled        passThrough
        recording    tapDisabled   no   yes    yes  stop:tapDisabled        passThrough
        recording    tapDisabled   no   no     no   stop:tapDisabled        passThrough
        recording    tapDisabled   no   no     yes  stop:tapDisabled        passThrough
        ending       keyDown       yes  yes    no   ignore                  swallow
        ending       keyDown       yes  yes    yes  ignore                  swallow
        ending       keyDown       yes  no     no   ignore                  passThrough
        ending       keyDown       yes  no     yes  ignore                  passThrough
        ending       keyDown       no   yes    no   ignore                  passThrough
        ending       keyDown       no   yes    yes  ignore                  passThrough
        ending       keyDown       no   no     no   ignore                  passThrough
        ending       keyDown       no   no     yes  ignore                  passThrough
        ending       keyUp         yes  yes    no   ignore                  swallow
        ending       keyUp         yes  yes    yes  ignore                  swallow
        ending       keyUp         yes  no     no   ignore                  swallow
        ending       keyUp         yes  no     yes  ignore                  swallow
        ending       keyUp         no   yes    no   ignore                  passThrough
        ending       keyUp         no   yes    yes  ignore                  passThrough
        ending       keyUp         no   no     no   ignore                  passThrough
        ending       keyUp         no   no     yes  ignore                  passThrough
        ending       flagsChanged  yes  yes    no   ignore                  passThrough
        ending       flagsChanged  yes  yes    yes  ignore                  passThrough
        ending       flagsChanged  yes  no     no   ignore                  passThrough
        ending       flagsChanged  yes  no     yes  ignore                  passThrough
        ending       flagsChanged  no   yes    no   ignore                  passThrough
        ending       flagsChanged  no   yes    yes  ignore                  passThrough
        ending       flagsChanged  no   no     no   ignore                  passThrough
        ending       flagsChanged  no   no     yes  ignore                  passThrough
        ending       tapDisabled   yes  yes    no   ignore                  passThrough
        ending       tapDisabled   yes  yes    yes  ignore                  passThrough
        ending       tapDisabled   yes  no     no   ignore                  passThrough
        ending       tapDisabled   yes  no     yes  ignore                  passThrough
        ending       tapDisabled   no   yes    no   ignore                  passThrough
        ending       tapDisabled   no   yes    yes  ignore                  passThrough
        ending       tapDisabled   no   no     no   ignore                  passThrough
        ending       tapDisabled   no   no     yes  ignore                  passThrough
        """

    /// Parses ``truthTable``, failing loudly on anything it does not recognise.
    ///
    /// A parser that skipped a malformed row would silently shrink the table, and the count
    /// assertion in the test is what would then be measuring the typo rather than the policy.
    private static func parsedTruthTable() -> [Cell: Decision] {
        var table: [Cell: Decision] = [:]
        for line in truthTable.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            guard let first = fields.first, !first.hasPrefix("#") else { continue }
            precondition(fields.count == 7, "Malformed truth-table row: \(line)")

            let state: SessionState
            switch fields[0] {
            case "idle": state = .idle
            case "recording": state = .recording
            case "ending": state = .ending
            default: preconditionFailure("Unknown state in truth table: \(fields[0])")
            }

            let kind: RawKeyEvent.Kind
            switch fields[1] {
            case "keyDown": kind = .keyDown
            case "keyUp": kind = .keyUp
            case "flagsChanged": kind = .flagsChanged
            case "tapDisabled": kind = .tapDisabled
            default: preconditionFailure("Unknown kind in truth table: \(fields[1])")
            }

            func flag(_ field: String) -> Bool {
                switch field {
                case "yes": return true
                case "no": return false
                default: preconditionFailure("Unknown flag in truth table: \(field)")
                }
            }

            let action: Decision.Action
            switch fields[5] {
            case "start": action = .start
            case "ignore": action = .ignore
            case "stop:keyUp": action = .stop(.retained(.keyUp))
            case "stop:modifierReleased": action = .stop(.retained(.modifierReleased))
            case "stop:tapDisabled": action = .stop(.retained(.tapDisabled))
            default: preconditionFailure("Unknown action in truth table: \(fields[5])")
            }

            let propagation: EventPropagation
            switch fields[6] {
            case "swallow": propagation = .swallow
            case "passThrough": propagation = .passThrough
            default: preconditionFailure("Unknown propagation in truth table: \(fields[6])")
            }

            let cell = Cell(
                state: state, kind: kind, keyMatches: flag(fields[2]), chordHeld: flag(fields[3]),
                isAutorepeat: flag(fields[4]))
            precondition(table[cell] == nil, "Duplicate truth-table row for \(cell)")
            table[cell] = Decision(action: action, eventPropagation: propagation)
        }
        return table
    }

    // MARK: - Space and randomisation helpers

    private struct InputCase {
        var config: HotkeyConfiguration
        var event: RawKeyEvent
        var state: SessionState
    }

    /// The modifier states the space is swept over.
    ///
    /// Chosen so that **every configuration below sees all four relationships** to its own chord:
    /// exact, strict superset, partial, and disjoint. The last two entries are what make the
    /// two-modifier configuration meaningful — `[.control]` and `[.option]` are each *half* of
    /// `twoModifier`'s chord, which is the only shape that distinguishes "contains all of" from
    /// "intersects".
    private static let modifierValues: [ModifierSet] = [
        [], [.option], [.option, .capsLock], [.shift], [.control], [.control, .option],
        [.control, .option, .capsLock],
    ]

    /// Every configuration the space is swept over: no modifiers, one, and two.
    ///
    /// The arity matters, not the identity. With 0 or 1 configured modifiers, a chord predicate
    /// meaning *intersects* behaves identically to one meaning *contains all*, so a space swept
    /// over only those two hides the difference — measured, at 75/75 green.
    private static let configurations: [HotkeyConfiguration] = [chord, bareKey, twoModifier]

    /// Every combination the rules can see: 4 kinds × 2 key codes × 7 modifier sets × 2 autorepeat
    /// values × 3 states × 3 configurations = 1,008 cells.
    private static func wholeInputSpace() -> [InputCase] {
        var cases: [InputCase] = []
        for config in configurations {
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
        let configurations = Self.configurations
        let config = configurations[Int.random(in: 0..<configurations.count, using: &generator)]
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
