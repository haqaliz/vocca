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

import Carbon.HIToolbox
import CoreGraphics
import VoccaCore
import VoccaHotkey
import XCTest

// MARK: - Fixtures

/// A sink that records what it was handed and answers whatever it is told to.
///
/// **The answer is configurable, and that is the whole design of this suite.** A dispatch that
/// hard-coded a disposition would satisfy any test whose sink always says the same thing, so the sink
/// is driven to say both.
private final class ScriptedSink: HotkeyEventSink {
    var answer: EventPropagation = .passThrough
    private(set) var received: [RawKeyEvent] = []

    func receive(_ event: RawKeyEvent) -> EventPropagation {
        received.append(event)
        return answer
    }
}

private final class RecordingDisablementObserver: TapDisablementObserver {
    private(set) var reasons: [TapDisableReason] = []

    func tapWasDisabledOnTheCallback(_ reason: TapDisableReason) {
        reasons.append(reason)
    }
}

/// The dispatch, with everything a test does not care about defaulted.
private func dispatch(
    type: CGEventType,
    flags: CGEventFlags = [],
    keyCode: UInt16 = 49,
    isAutorepeat: Bool = false,
    at now: Duration = .milliseconds(1234),
    to sink: (any HotkeyEventSink)?,
    observer: (any TapDisablementObserver)? = nil
) -> EventPropagation {
    TapEventDispatch.dispatch(
        rawEventType: type.rawValue,
        rawFlags: flags.rawValue,
        keyCode: keyCode,
        isAutorepeat: isAutorepeat,
        at: now,
        to: sink,
        reportingDisablementTo: observer)
}

// MARK: -

/// **The body of the tap callback, measured — because the callback itself never runs here.**
///
/// `CGEvent.tapCreate` returns `nil` without an Accessibility grant, so `CGEventTapSource.swift` is
/// unreachable from CI forever. What that file does with an event was therefore lifted into
/// ``TapEventDispatch``, which takes five integers and its collaborators as parameters. This suite is
/// what that move bought: every claim the adapter's documentation makes about what happens to an
/// event is a claim asserted here.
///
/// The load-bearing one is H6 in **both** directions. `SessionEventSink` and the fake source pin it
/// further up; this pins it at the last point before the C ABI, where the only thing left is
/// `swallow → nil`. A dispatch that hard-coded either answer would leave every session test in this
/// package green and eat the user's whole keyboard.
final class TapEventDispatchTests: XCTestCase {

    // MARK: - What reaches the sink

    func testAKeyDownReachesTheSinkAsTheEventTheRulesRead() {
        let sink = ScriptedSink()

        _ = dispatch(
            type: .keyDown, flags: [.maskAlternate], keyCode: 49, isAutorepeat: true,
            at: .milliseconds(7), to: sink)

        XCTAssertEqual(
            sink.received,
            [
                RawKeyEvent(
                    kind: .keyDown, keyCode: 49, modifiers: [.option], isAutorepeat: true,
                    timestamp: .milliseconds(7))
            ],
            """
            The event handed to the session rules is not the event that arrived. Every field here is \
            read by a rule: the kind by all of them, the key code by the start rule, the modifiers \
            by stop rule (c), autorepeat by the rule that stops a held key restarting a session, and \
            the timestamp by nothing yet — but it is the caller's to supply and the core reads no \
            clock of its own.
            """)
    }

    func testEachKindReachesTheSinkAsItself() {
        for (type, kind): (CGEventType, RawKeyEvent.Kind) in [
            (.keyDown, .keyDown), (.keyUp, .keyUp), (.flagsChanged, .flagsChanged),
        ] {
            let sink = ScriptedSink()
            _ = dispatch(type: type, to: sink)
            XCTAssertEqual(
                sink.received.map(\.kind), [kind],
                "Event type \(type.rawValue) was delivered as the wrong kind.")
        }
    }

    /// **The founder's `fn` rule, applied to the event's own key code.**
    ///
    /// The rule itself is pinned exhaustively by `HotkeyFlagTranslationTests`; what is pinned here is
    /// that this path applies it *at all*, and with the right key code. Passing some other field
    /// where the key code goes — the event's type, say — compiles, and would leave `fn` on every
    /// arrow key: a binding on `↑` would then be configured `[]` while its events carry `[.function]`
    /// and never fire.
    func testTheFunctionBitIsStrippedForAKeyThatCarriesItImplicitly() {
        let arrowSink = ScriptedSink()
        _ = dispatch(
            type: .keyDown, flags: [.maskSecondaryFn], keyCode: UInt16(kVK_UpArrow), to: arrowSink)

        XCTAssertEqual(
            arrowSink.received.map(\.modifiers), [[]],
            """
            The implicit fn bit survived on kVK_UpArrow. macOS sets it with no user involvement, so \
            a binding on an arrow key could never match.
            """)

        let letterSink = ScriptedSink()
        _ = dispatch(type: .keyDown, flags: [.maskSecondaryFn], keyCode: 0, to: letterSink)

        XCTAssertEqual(
            letterSink.received.map(\.modifiers), [[.function]],
            """
            ...and a genuine fn held over a key that does not carry it implicitly must survive, or \
            the rule has been applied by stripping the bit unconditionally.
            """)
    }

    // MARK: - H6, at the last point before the C ABI

    func testTheSinksDispositionComesBackUnchangedInBothDirections() {
        for answer in EventPropagation.allCases {
            let sink = ScriptedSink()
            sink.answer = answer

            XCTAssertEqual(
                dispatch(type: .keyDown, to: sink), answer,
                """
                The sink answered \(answer) and the dispatch returned something else. This value \
                becomes the tap callback's return — swallow is `nil`, pass-through is the event — so \
                a constant here is either a hotkey that types into the user's document or the user's \
                entire keyboard eaten for as long as Vocca runs.
                """)
        }
    }

    /// The same claim stated as a distinction rather than as two equalities, which is the form the
    /// merged aspect's surviving mutant would have failed: a dispatch that always swallows satisfies
    /// every assertion made about the swallow direction alone.
    func testTheTwoDispositionsAreNotCollapsedIntoOne() {
        let sink = ScriptedSink()

        sink.answer = .swallow
        let swallowed = dispatch(type: .keyUp, to: sink)
        sink.answer = .passThrough
        let passed = dispatch(type: .keyUp, to: sink)

        XCTAssertNotEqual(
            swallowed, passed,
            "The dispatch returns the same value whatever the session decided.")
    }

    // MARK: - What does not reach the sink

    func testADisablementGoesToTheObserverAndNotToTheSink() {
        for (type, reason): (CGEventType, TapDisableReason) in [
            (.tapDisabledByTimeout, .timeout), (.tapDisabledByUserInput, .userInput),
        ] {
            let sink = ScriptedSink()
            sink.answer = .swallow
            let observer = RecordingDisablementObserver()

            let propagation = dispatch(type: type, to: sink, observer: observer)

            XCTAssertEqual(observer.reasons, [reason], "The disablement was reported wrongly.")
            XCTAssertEqual(
                sink.received, [],
                """
                A disablement was delivered to the sink as a key event. The synthetic end that ends \
                a stranded session is minted by TapHealthPolicy, with the fields stop rule (d) \
                requires; a second one from here is a second answer to a settled question.
                """)
            XCTAssertEqual(
                propagation, .passThrough,
                """
                A disablement is not a keystroke and there is no application waiting for it. \
                Answering with the sink's disposition — .swallow here — would mean the dispatch had \
                consulted a sink it must not consult.
                """)
        }
    }

    func testAnEventTypeVoccaNeverAskedForReachesNobodyAndPassesThrough() {
        let sink = ScriptedSink()
        sink.answer = .swallow
        let observer = RecordingDisablementObserver()

        let propagation = dispatch(type: .mouseMoved, to: sink, observer: observer)

        XCTAssertEqual(propagation, .passThrough, "An event Vocca never asked for was swallowed.")
        XCTAssertEqual(sink.received, [], "An event outside the mask reached the session rules.")
        XCTAssertEqual(observer.reasons, [], "An ordinary event was reported as a disablement.")
    }

    // MARK: - The two absent collaborators

    /// **No sink means no tap, and a source with nothing to ask claims nothing.**
    ///
    /// The other answer — swallow — is not a defensible alternative: it is every keystroke on the
    /// machine disappearing while Vocca is not even listening.
    func testWithNoSinkTheEventReachesTheApplicationUntouched() {
        XCTAssertEqual(
            dispatch(type: .keyDown, to: nil), .passThrough,
            "A dispatch with no sink swallowed the user's keystroke.")
    }

    /// No observer costs the recovery and not the ending — and, critically, does not cost the
    /// keyboard. An owner that forgot to hold the observer must still have a working callback.
    func testWithNoObserverADisablementIsSurvivedAndTheEventStillPassesThrough() {
        let sink = ScriptedSink()

        XCTAssertEqual(
            dispatch(type: .tapDisabledByTimeout, to: sink, observer: nil), .passThrough)
        XCTAssertEqual(sink.received, [], "The disablement leaked into the session rules.")
    }
}
