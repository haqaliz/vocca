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

import CoreGraphics
import VoccaCore
import VoccaHotkey
import XCTest

/// **The transcription check for the tap's other table of magic numbers.**
///
/// `TapEventTranslation` writes out `CGEventType`'s raw values by hand, for the two reasons
/// `HotkeyFlagTranslation` gives: the seam's forbidden types must not reach a file that is not the
/// adapter, and a module inside the zero-network guard should not link a framework it does not need.
/// The cost is that a wrong number compiles.
///
/// So this suite is the payment. It imports CoreGraphics — a *test* may, the H7 lint scans `Sources/`
/// only — and drives the translation with `CGEventType`'s own values, so a transcription error is a
/// red suite rather than a bug report.
///
/// **What makes it worth more than a table-copying exercise** is the mask. Both of its failure modes
/// are silent in production and invisible to any other test in this package:
///
/// - Drop `flagsChanged` and `⌥Space` still starts a session, while stop rules (b) and (c) quietly
///   stop existing — releasing Option before Space no longer ends anything, so every session runs to
///   the 120 s ceiling with the microphone open.
/// - Add a mouse type and every mouse move on the machine is adjudicated by the session rules, on
///   the tap callback, with the `kCGEventTapDisabledByTimeout` that earns.
///
/// Neither is reachable from the adapter, because no hosted runner can create a tap. Here it is one
/// integer comparison.
final class TapEventClassificationTests: XCTestCase {

    // MARK: - The three key types

    func testEachKeyEventTypeClassifiesAsItsOwnKind() {
        XCTAssertEqual(
            TapEventTranslation.classify(rawEventType: CGEventType.keyDown.rawValue),
            .key(.keyDown),
            "kCGEventKeyDown is transcribed wrongly, or is mapped to the wrong kind.")

        XCTAssertEqual(
            TapEventTranslation.classify(rawEventType: CGEventType.keyUp.rawValue),
            .key(.keyUp),
            """
            kCGEventKeyUp is transcribed wrongly. In hold-to-talk this is the stop — every session \
            would run to the ceiling.
            """)

        XCTAssertEqual(
            TapEventTranslation.classify(rawEventType: CGEventType.flagsChanged.rawValue),
            .key(.flagsChanged),
            """
            kCGEventFlagsChanged is transcribed wrongly. This is the event stop rules (b) and (c) \
            are made of, and the one that arms a modifier-only binding.
            """)
    }

    /// The three, checked to be *distinct* as well as individually right.
    ///
    /// A table whose three entries all mapped to `.keyDown` — one copy-paste — satisfies nothing
    /// above on its own if each assertion is read in isolation, and produces a Vocca that starts a
    /// session on every keystroke and never ends one.
    func testTheThreeKeyKindsAreDistinct() {
        let kinds = [CGEventType.keyDown, .keyUp, .flagsChanged].map {
            TapEventTranslation.classify(rawEventType: $0.rawValue)
        }
        XCTAssertEqual(Set(kinds).count, 3, "Two event types classify as the same kind: \(kinds).")
    }

    // MARK: - The two disablements

    func testEachDisablementClassifiesAsItsOwnReason() {
        XCTAssertEqual(
            TapEventTranslation.classify(rawEventType: CGEventType.tapDisabledByTimeout.rawValue),
            .disabled(.timeout),
            """
            kCGEventTapDisabledByTimeout is transcribed wrongly, or reported as the wrong reason. \
            The two recover identically, so the only thing that would notice is a human reading a \
            health log — and they would be sent after the wrong defect.
            """)

        XCTAssertEqual(
            TapEventTranslation.classify(rawEventType: CGEventType.tapDisabledByUserInput.rawValue),
            .disabled(.userInput),
            "kCGEventTapDisabledByUserInput is transcribed wrongly, or reported as the wrong reason.")
    }

    /// The distinction the reasons exist for, carried end to end from the SDK's own number.
    ///
    /// `TapDisableReason.isVoccasOwnDefect` is the one bit that separates *fix the callback* from
    /// *there is nothing to fix here*. A swapped pair of constants would invert it, and would do so
    /// silently: both recoveries are identical.
    func testTheReasonCarriesWhoseDefectItIs() {
        func blame(_ type: CGEventType) -> Bool? {
            switch TapEventTranslation.classify(rawEventType: type.rawValue) {
            case .disabled(let reason): return reason.isVoccasOwnDefect
            case .key, .notOfInterest: return nil
            }
        }

        XCTAssertEqual(blame(.tapDisabledByTimeout), true, "A timeout is Vocca's own slow callback.")
        XCTAssertEqual(blame(.tapDisabledByUserInput), false, "User input is not Vocca's defect.")
    }

    // MARK: - The mask

    func testTheMaskIsExactlyTheThreeKeyTypesAndNothingElse() {
        let expected: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        XCTAssertEqual(
            TapEventTranslation.eventsOfInterestMask, UInt64(expected),
            """
            The tap would ask the window server for the wrong set of events. Too narrow is a hotkey \
            that is deaf or a session that never ends; too wide is every mouse move on the machine \
            routed through the session rules on the tap callback.
            """)

        XCTAssertEqual(
            TapEventTranslation.eventsOfInterestMask.nonzeroBitCount, 3,
            "The mask must request three event types and no others.")
    }

    /// The bit that is easiest to lose and hardest to notice, named on its own.
    ///
    /// A mask of `keyDown | keyUp` looks like a working hotkey: press starts, release ends. What it
    /// deletes is every modifier event, and with it stop rules (b) and (c) — so releasing Option
    /// before Space leaves the microphone open to the ceiling, every time.
    func testTheMaskRequestsFlagsChanged() {
        XCTAssertNotEqual(
            TapEventTranslation.eventsOfInterestMask
                & (1 << UInt64(CGEventType.flagsChanged.rawValue)),
            0,
            "flagsChanged is absent from the mask: stop rules (b) and (c) can never fire.")
    }

    /// **The mask and the classifier are the same list read twice, and this is what says so.**
    ///
    /// Two ways to be wrong, and each is a live hazard rather than a hypothetical: an event type the
    /// mask requests that the classifier calls `notOfInterest` is a keystroke delivered to a callback
    /// that shrugs at it; an event type the classifier handles that the mask never requests is a
    /// branch nothing can reach, which is how a rule comes to be believed in without ever running.
    func testTheMaskAndTheClassificationAgreeExactly() {
        for bit in 0..<UInt32(64) {
            let isRequested = TapEventTranslation.eventsOfInterestMask & (1 << UInt64(bit)) != 0
            let isAKeyEvent: Bool
            switch TapEventTranslation.classify(rawEventType: bit) {
            case .key: isAKeyEvent = true
            case .disabled, .notOfInterest: isAKeyEvent = false
            }

            XCTAssertEqual(
                isRequested, isAKeyEvent,
                """
                Event type \(bit): the mask \(isRequested ? "requests" : "does not request") it and \
                the classifier \(isAKeyEvent ? "treats" : "does not treat") it as a key event. The \
                two are built from one table so that they cannot disagree.
                """)
        }
    }

    // MARK: - Everything else

    /// A handful of real event types Vocca has no interest in, named rather than swept, because a
    /// sweep proves the range and a name proves the case somebody would actually hit.
    func testOrdinaryEventTypesVoccaDidNotAskForAreNotOfInterest() {
        for type: CGEventType in [
            .null, .leftMouseDown, .leftMouseUp, .rightMouseDown, .mouseMoved, .scrollWheel,
            .leftMouseDragged, .otherMouseDown,
        ] {
            XCTAssertEqual(
                TapEventTranslation.classify(rawEventType: type.rawValue), .notOfInterest,
                "Event type \(type.rawValue) was claimed by Vocca. The mask never asked for it.")
        }
    }

    /// The whole low range, so that a stray constant landing on a neighbouring number is caught.
    ///
    /// `kCGEventKeyDown` is 10 and its neighbours are mouse events, so an off-by-one in the
    /// transcription is not an inert number — it is Vocca adjudicating every right-mouse-down on the
    /// machine while never seeing a keystroke.
    func testNoOtherEventTypeInTheLowRangeIsClaimed() {
        let claimed: Set<UInt32> = [
            CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue,
            CGEventType.flagsChanged.rawValue,
        ]

        for rawType in UInt32(0)...UInt32(64) where !claimed.contains(rawType) {
            XCTAssertEqual(
                TapEventTranslation.classify(rawEventType: rawType), .notOfInterest,
                "Event type \(rawType) is claimed, and the mask never asked for it.")
        }
    }

    /// **No macOS event type may become the synthetic kind.**
    ///
    /// `RawKeyEvent.Kind.tapDisabled` is minted by ``TapHealthPolicy`` when it ends a stranded
    /// session, and stop rule (d) is checked *before* every other rule precisely because such an
    /// event's modifiers and key code mean nothing. A classifier that produced it from a real event
    /// would hand the rules an event whose fields are real and whose kind says to ignore them —
    /// ending a session on a keystroke that was never Vocca's.
    func testNoEventTypeClassifiesAsTheSyntheticKind() {
        var rawTypes = Array(UInt32(0)...UInt32(4096))
        rawTypes.append(contentsOf: [
            CGEventType.tapDisabledByTimeout.rawValue, CGEventType.tapDisabledByUserInput.rawValue,
            UInt32.max, UInt32.max - 1, UInt32.max / 2,
        ])

        for rawType in rawTypes {
            XCTAssertNotEqual(
                TapEventTranslation.classify(rawEventType: rawType), .key(.tapDisabled),
                "Event type \(rawType) classifies as the kind only the health policy may mint.")
        }
    }
}
