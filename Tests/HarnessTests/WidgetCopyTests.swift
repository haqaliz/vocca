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
import VoccaUI
import XCTest

/// **The live widget's user-visible copy — every string, rendered from the reducer's structured
/// state and pinned to the spec.**
///
/// The views are window-server code executed by nothing in CI (the `FailsafeCopy`/`EnginePickerCopy`
/// precedent); this file is that copy made testable — a pure function of the widget's data with no
/// AppKit anywhere near it, so the `PRODUCT_SPEC.md:24-68` states and the `:129` cancel instruction
/// run headlessly.
///
/// The strings pinned here are the widget's honesty surface: the target indicator (`PRODUCT_SPEC.md:70`
/// — the two-word label that prevents the most embarrassing failure), the `esc to cancel` instruction
/// (`:129`), the subtle ceiling warning (`:90`), the indeterminate transcribing progress (`:47`),
/// and the delivered confirmation (`:52`). The elapsed timer is a formatted reading of the reducer's
/// `WidgetReducerState/elapsed` — display-only, anchored at mic-open on the same clock the machine
/// measures (`WidgetReducerState`'s header states the anchoring caveat).
final class WidgetCopyTests: XCTestCase {

    // MARK: - The target indicator

    /// OPENING names the target (`PRODUCT_SPEC.md:35`): the "→ Slack"-style label. An unresolved
    /// name renders nothing — the router folds the OPENING state with an empty name before the
    /// resolution lands (`AppBootstrap.swift`'s router), so the label must never read "→ " alone.
    func testTheOpeningLabelNamesTheTarget() {
        XCTAssertEqual(WidgetCopy.openingLabel(targetAppName: "Slack"), "→ Slack")
        XCTAssertEqual(
            WidgetCopy.openingLabel(targetAppName: ""), "",
            "an unresolved target name must render no label at all, never a dangling '→ '")
    }

    /// DELIVERED confirms the target (`PRODUCT_SPEC.md:52`): "✓ → Slack". With no name the ✓ alone
    /// is still an honest confirmation — the text landed — but the arrow must not dangle.
    func testTheDeliveredLabelConfirmsTheTarget() {
        XCTAssertEqual(WidgetCopy.deliveredLabel(targetAppName: "Slack"), "✓ → Slack")
        XCTAssertEqual(WidgetCopy.deliveredLabel(targetAppName: ""), "✓")
    }

    // MARK: - The recording surfaces

    /// The elapsed timer renders as minutes:seconds (`PRODUCT_SPEC.md:42` shows `0:04`). The
    /// reducer's `elapsed` is a `Duration`; the text is its whole-second reading, so the display
    /// ticks once per second rather than jittering on sub-second components.
    func testTheElapsedTimerFormatsAsMinutesAndSeconds() {
        XCTAssertEqual(WidgetCopy.elapsedText(.seconds(0)), "0:00")
        XCTAssertEqual(WidgetCopy.elapsedText(.seconds(4)), "0:04")
        XCTAssertEqual(WidgetCopy.elapsedText(.seconds(65)), "1:05")
        XCTAssertEqual(WidgetCopy.elapsedText(.seconds(600)), "10:00")
    }

    /// The escape instruction (`PRODUCT_SPEC.md:129`): the widget shows `esc to cancel` after two
    /// seconds of recording. The user needs an obvious way out of a dictation they've thought
    /// better of — this is that way, verbatim.
    func testTheEscapeHintIsTheSpecsCancelInstruction() {
        XCTAssertEqual(WidgetCopy.escapeHint, "esc to cancel")
    }

    /// The subtle ceiling warning (`PRODUCT_SPEC.md:90`): at the derived warning threshold the
    /// widget warns that the recording limit approaches. The copy is deliberately ceiling-agnostic —
    /// the threshold itself is derived from the configured ceiling via `WatchdogPolicy`
    /// (`WidgetStateReducer.swift`), so the text cannot hard-code the shipped 120 s.
    func testTheCeilingWarningCopyIsPresentAndDoesNotNameANumber() {
        XCTAssertFalse(WidgetCopy.ceilingWarning.isEmpty)
        XCTAssertFalse(
            WidgetCopy.ceilingWarning.contains("120"),
            "the ceiling is configured, not fixed — the copy must not hard-code the shipped value")
    }

    // MARK: - The pipeline surfaces

    /// TRANSCRIBING's indeterminate progress (`PRODUCT_SPEC.md:47`): the waveform freezes and the
    /// glyphs show work in flight with no endpoint claimed.
    func testTheTranscribingProgressIsIndeterminate() {
        XCTAssertEqual(WidgetCopy.transcribingProgress, "○○○")
    }

    // MARK: - The notice

    /// The `captureUnavailable` notice (`WidgetProjection.swift`): the hotkey was pressed and the
    /// microphone did not open — the widget says the cause out loud instead of letting the press
    /// appear to do nothing at all.
    func testTheNoticeCopySaysTheMicrophoneDidNotOpen() {
        XCTAssertEqual(
            WidgetCopy.noticeText(.captureUnavailable), "The microphone didn't open — try again.")
    }
}
