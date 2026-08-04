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

/// A payload-free mirror of ``RetainedEndReason``, existing only so that `CaseIterable` can be
/// *synthesised* for it.
///
/// This is what closes the loop on the hand-written `RetainedEndReason.allCases`. Naming each
/// reason in an exhaustive switch is not enough on its own — measured during this task: adding a
/// case, adding its branch to the switch, and leaving `allCases` alone left the suite green,
/// because both sides of the comparison were missing the new reason. Mapping to this mirror
/// instead makes the comparison asymmetric: the compiler forces a branch, the branch forces a tag,
/// and a *new* tag makes `Set(allCases.map(tag))` smaller than `Set(RetainedEndReasonTag.allCases)`
/// until `allCases` is updated too.
private enum RetainedEndReasonTag: Hashable, CaseIterable {
    case keyUp
    case modifierReleased
    case tapDisabled
    case ceilingReached
    case pollDetectedRelease
    /// One tag for all system triggers; that they are individually present in `allCases` is
    /// asserted separately against `SystemTrigger.allCases`, which *is* synthesised.
    case systemEvent
}

/// The same mirror for ``EndReason``'s two top-level cases.
private enum EndReasonTag: Hashable, CaseIterable {
    case retained
    case userCancelled
}

/// The session vocabulary: the types every later part of this aspect is written in.
///
/// There is no behaviour to test yet — the decision function and the state machine come next — so
/// what is tested here is the *shape*, and the shape is load-bearing. Three properties in
/// particular are what the rest of the aspect leans on:
///
/// - every enum is exhaustively switchable, so adding a case is a compile error at every decision
///   point rather than a silent inheritance of an existing branch;
/// - the types are `Sendable`, because they cross actor boundaries on every event;
/// - the audio-discarding path is reachable only from user cancellation.
final class SessionVocabularyTests: XCTestCase {

    // MARK: - Exhaustiveness

    /// Switches every reason with no `default:`, and proves the hand-written `allCases` is not
    /// stale.
    ///
    /// Both halves matter, and the second one is subtler than it looks. An exhaustive switch alone
    /// makes a new case a compile error here — but a developer who adds the case, adds the branch,
    /// and forgets `allCases` would have had a green suite, because the switch and the expected
    /// list would both be missing the same reason. Comparing against the synthesised
    /// ``RetainedEndReasonTag`` instead makes the two sides independent, so the omission has
    /// somewhere to show up. That matters because every later property test in this aspect —
    /// "for all reasons except `.userCancelled`, audio is emitted exactly once" among them —
    /// iterates `allCases` and would silently cover one reason less.
    func testEveryEndReasonAppearsInAllCases() {
        // Deliberately not `default:`. If this stops compiling, a stop rule was added: give it a
        // tag above, name it here, and add it to `RetainedEndReason.allCases`.
        func tag(for reason: RetainedEndReason) -> RetainedEndReasonTag {
            switch reason {
            case .keyUp: return .keyUp
            case .modifierReleased: return .modifierReleased
            case .tapDisabled: return .tapDisabled
            case .ceilingReached: return .ceilingReached
            case .pollDetectedRelease: return .pollDetectedRelease
            case .systemEvent: return .systemEvent
            }
        }
        func tag(for reason: EndReason) -> EndReasonTag {
            switch reason {
            case .retained: return .retained
            case .userCancelled: return .userCancelled
            }
        }

        XCTAssertEqual(
            Set(RetainedEndReason.allCases.map(tag(for:))), Set(RetainedEndReasonTag.allCases),
            """
            RetainedEndReason.allCases does not cover every stop rule. It is hand-written — the \
            systemEvent payload rules out synthesis — so it is the half of this pair that goes \
            stale, and every property test that iterates it then quietly covers less than it \
            claims.
            """)

        // The one tag that stands for many values. SystemTrigger's own CaseIterable *is*
        // synthesised, so this half needs no mirror.
        let triggersInAllCases = RetainedEndReason.allCases.compactMap { reason -> SystemTrigger? in
            if case .systemEvent(let trigger) = reason { return trigger }
            return nil
        }
        XCTAssertEqual(
            Set(triggersInAllCases), Set(SystemTrigger.allCases),
            "RetainedEndReason.allCases must enumerate every SystemTrigger, not just some of them.")

        XCTAssertEqual(Set(EndReason.allCases.map(tag(for:))), Set(EndReasonTag.allCases))
        XCTAssertEqual(
            EndReason.allCases.count, RetainedEndReason.allCases.count + 1,
            "EndReason.allCases must be every retaining reason plus cancellation, with none dropped."
        )
    }

    func testEverySessionStateIsExhaustivelySwitchable() {
        func label(for state: SessionState) -> String {
            switch state {
            case .idle: return "idle"
            case .recording: return "recording"
            case .ending: return "ending"
            }
        }
        XCTAssertEqual(SessionState.allCases.map(label(for:)), ["idle", "recording", "ending"])
    }

    func testEveryEventKindAndPropagationIsExhaustivelySwitchable() {
        func label(for kind: RawKeyEvent.Kind) -> String {
            switch kind {
            case .keyDown: return "keyDown"
            case .keyUp: return "keyUp"
            case .flagsChanged: return "flagsChanged"
            case .tapDisabled: return "tapDisabled"
            }
        }
        XCTAssertEqual(
            RawKeyEvent.Kind.allCases.map(label(for:)),
            ["keyDown", "keyUp", "flagsChanged", "tapDisabled"])

        func label(for propagation: EventPropagation) -> String {
            switch propagation {
            case .passThrough: return "passThrough"
            case .swallow: return "swallow"
            }
        }
        XCTAssertEqual(
            EventPropagation.allCases.map(label(for:)), ["passThrough", "swallow"])
    }

    /// Every ``Decision`` the spec names is constructible, distinct, and destructurable without a
    /// `default:`.
    func testEveryDecisionIsRepresentableAndExhaustivelySwitchable() {
        let start = Decision(action: .start, eventPropagation: .swallow)
        let stop = Decision(
            action: .stop(.retained(.keyUp)), eventPropagation: .swallow)
        let ignore = Decision(action: .ignore, eventPropagation: .passThrough)
        let swallowAndIgnore = Decision(action: .ignore, eventPropagation: .swallow)

        XCTAssertEqual(Set([start, stop, ignore, swallowAndIgnore]).count, 4)
        XCTAssertNotEqual(ignore, swallowAndIgnore)

        func label(for decision: Decision) -> String {
            let action: String
            switch decision.action {
            case .start: action = "start"
            case .stop(let reason): action = reason == .userCancelled ? "stop/cancel" : "stop"
            case .ignore: action = "ignore"
            }
            switch decision.eventPropagation {
            case .passThrough: return "\(action)+passThrough"
            case .swallow: return "\(action)+swallow"
            }
        }
        XCTAssertEqual(
            [start, stop, ignore, swallowAndIgnore].map(label(for:)),
            ["start+swallow", "stop+swallow", "ignore+passThrough", "ignore+swallow"])
    }

    // MARK: - Sendable

    /// Compile-time, not runtime. `requireSendable` constrains its parameter to `Sendable`, so a
    /// type that loses the conformance fails to build this file rather than failing an assertion —
    /// which is the only way to check `Sendable`, since it has no runtime representation.
    ///
    /// These types cross actor boundaries on every keystroke: the event tap's callback, the
    /// session actor, and the widget are three different isolation domains.
    func testTheVocabularyIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        let event = RawKeyEvent(
            kind: .keyDown, keyCode: 49, modifiers: [.option], isAutorepeat: false,
            timestamp: .milliseconds(0))
        XCTAssertEqual(requireSendable(event), event)
        XCTAssertEqual(requireSendable(ModifierSet.command), .command)
        XCTAssertEqual(requireSendable(SessionState.recording), .recording)
        XCTAssertEqual(requireSendable(SystemTrigger.willSleep), .willSleep)
        XCTAssertEqual(requireSendable(RetainedEndReason.ceilingReached), .ceilingReached)
        XCTAssertEqual(requireSendable(EndReason.userCancelled), .userCancelled)
        XCTAssertEqual(requireSendable(EventPropagation.swallow), .swallow)
        XCTAssertEqual(
            requireSendable(Decision(action: .start, eventPropagation: .swallow)),
            Decision(action: .start, eventPropagation: .swallow))
        XCTAssertEqual(
            requireSendable(SessionOutcome<[Int]>.completed(reason: .keyUp, audio: [1])),
            .completed(reason: .keyUp, audio: [1]))
    }

    // MARK: - ModifierSet

    func testModifierSetBehavesAsAnOptionSet() {
        let hotkey: ModifierSet = [.option, .shift]

        XCTAssertTrue(hotkey.contains(.option))
        XCTAssertTrue(hotkey.contains(.shift))
        XCTAssertFalse(hotkey.contains(.command))

        XCTAssertEqual(hotkey.union(.command), [.option, .shift, .command])
        XCTAssertEqual(hotkey.subtracting(.option), [.shift])
        XCTAssertEqual(hotkey.intersection([.shift, .command]), [.shift])

        XCTAssertTrue(ModifierSet([]).isEmpty)
        XCTAssertEqual(ModifierSet([]).rawValue, 0)
        XCTAssertFalse(hotkey.isEmpty)

        // The superset test the start rule is written in: flags ⊇ configured modifiers, with
        // extra modifiers tolerated (caps lock being on must not stop a hotkey working).
        XCTAssertTrue(ModifierSet([.option, .shift, .capsLock]).isSuperset(of: hotkey))
        XCTAssertFalse(ModifierSet([.option, .capsLock]).isSuperset(of: hotkey))

        var mutable = hotkey
        mutable.insert(.control)
        XCTAssertTrue(mutable.contains(.control))
        mutable.remove(.shift)
        XCTAssertEqual(mutable, [.option, .control])

        // Every modifier is a distinct bit. A duplicated raw value would make two modifiers
        // indistinguishable, and the hotkey comparison would accept the wrong chord.
        let all: [ModifierSet] = [
            .control, .option, .shift, .command, .function, .capsLock,
        ]
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
    }

    /// `ModifierSet` must never be interchangeable with `CGEventFlags`, and the cheapest guard is
    /// that its bit positions are not CoreGraphics'. This test cannot import CoreGraphics to
    /// compare (that is the boundary), so it pins the raw values literally: they are this
    /// package's own, and the adapter in `VoccaHotkey` must translate case by case rather than
    /// bit-casting.
    func testModifierSetRawValuesAreVoccasOwnAndNotCoreGraphics() {
        XCTAssertEqual(ModifierSet.control.rawValue, 1 << 0)
        XCTAssertEqual(ModifierSet.option.rawValue, 1 << 1)
        XCTAssertEqual(ModifierSet.shift.rawValue, 1 << 2)
        XCTAssertEqual(ModifierSet.command.rawValue, 1 << 3)
        XCTAssertEqual(ModifierSet.function.rawValue, 1 << 4)
        XCTAssertEqual(ModifierSet.capsLock.rawValue, 1 << 5)

        // CGEventFlags puts its modifiers at bits 16-23 (`maskShift` is 1 << 17, and so on) in a
        // 64-bit word. Every value above occupies one of the low six bits of a 16-bit word, so
        // there is no overlap at all: a bit-cast or rawValue round-trip between the two types
        // yields an obviously empty set rather than a plausible wrong one.
        let occupied = [ModifierSet.control, .option, .shift, .command, .function, .capsLock]
            .reduce(into: ModifierSet()) { $0.formUnion($1) }
        XCTAssertEqual(occupied.rawValue, 0b11_1111)
    }

    // MARK: - The discard path

    /// The structural claim about `.userCancelled`, stated as a test so it is not merely a comment.
    ///
    /// `SessionOutcome.completed` requires an `Audio` value, so no stop rule can end a session
    /// without handing its audio on; `SessionOutcome.cancelled` carries no `RetainedEndReason`, so
    /// no stop rule can be routed down the one path that discards. The compiler enforces both —
    /// what this test adds is the record of *which* property is being relied on, so that a future
    /// change to `SessionOutcome` that quietly removes it has something to break.
    func testOnlyCancellationYieldsAnOutcomeWithoutAudio() {
        for reason in RetainedEndReason.allCases {
            let outcome = SessionOutcome.completed(reason: reason, audio: [1, 2, 3])
            switch outcome {
            case .completed(let carried, let audio):
                XCTAssertEqual(carried, reason)
                XCTAssertEqual(audio, [1, 2, 3])
            case .cancelled:
                XCTFail("A retaining reason produced a cancelled outcome: \(reason)")
            }
        }

        let cancelled = SessionOutcome<[Int]>.cancelled
        switch cancelled {
        case .completed(let reason, _):
            XCTFail("Cancellation produced audio to hand on, attributed to \(reason)")
        case .cancelled:
            break
        }
    }
}
