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

import Foundation
import VoccaCore

/// The live widget's copy — every user-visible string, rendered from the reducer's structured
/// state.
///
/// The pill's views are window-server glue executed by nothing in CI, so this file is the tested
/// half (`WidgetCopyTests`): the `PRODUCT_SPEC.md:24-68` states' labels, the `:129` cancel
/// instruction, the `:90` ceiling warning, and the `:47` transcribing glyphs are all pure functions
/// of the widget's data, with no AppKit anywhere near them — the ``DownloadState`` shape
/// (Foundation + `VoccaCore` only), exactly as ``FailsafeCopy`` renders the FAILSAFE surface.
///
/// The widget's honesty rules shape the strings as much as the spec does:
///
/// - **A dangling arrow is a lie about a destination.** The router folds the OPENING state with an
///   empty name before the target resolution lands (`AppBootstrap.swift`'s router folds
///   `.opening` with `""`, then re-folds when the display name resolves), so a label built from an
///   empty name must render nothing rather than "→ ". DELIVERED keeps the ✓ alone — the text
///   landed, even if the name never resolved — but never an arrow without a name after it.
/// - **The ceiling copy names no number.** The warning threshold is derived from the *configured*
///   ceiling (`WidgetStateReducer.swift`'s `WidgetTiming` header: `WatchdogPolicy.warningThreshold`
///   against `WidgetReducerState/ceiling`), so "approaching the 120 s ceiling" would be a lie the
///   moment a settings surface moves the ceiling.
public enum WidgetCopy {

    /// The OPENING target indicator (`PRODUCT_SPEC.md:35`): "→ Slack". Empty when the target name
    /// has not resolved — the spec's two-word label exists to confirm the destination *before* the
    /// user speaks, and a dangling arrow confirms nothing.
    public static func openingLabel(targetAppName: String) -> String {
        targetAppName.isEmpty ? "" : "→ \(targetAppName)"
    }

    /// The DELIVERED confirmation (`PRODUCT_SPEC.md:52`): "✓ → Slack", or the ✓ alone when no name
    /// resolved — the text landed either way, and the checkmark is the honest part.
    public static func deliveredLabel(targetAppName: String) -> String {
        targetAppName.isEmpty ? "✓" : "✓ → \(targetAppName)"
    }

    /// The elapsed timer (`PRODUCT_SPEC.md:42` shows `0:04`): the reducer's whole-second reading of
    /// `now − recordingStartedAt`, as minutes:seconds. Display-only, anchored at mic-open on the
    /// same clock the machine measures — the `WidgetReducerState` header states that caveat.
    public static func elapsedText(_ elapsed: Duration) -> String {
        let seconds = max(0, Int(elapsed.components.seconds))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The escape instruction (`PRODUCT_SPEC.md:129`, verbatim): the widget shows `esc to cancel`
    /// after 2 s of recording — the user needs an obvious way out of a dictation they've thought
    /// better of.
    public static let escapeHint = "esc to cancel"

    /// The subtle ceiling warning (`PRODUCT_SPEC.md:90`): shown at the derived warning threshold,
    /// naming no number — the threshold moves with the configured ceiling.
    public static let ceilingWarning = "approaching the recording limit"

    /// TRANSCRIBING's indeterminate progress (`PRODUCT_SPEC.md:47`): work in flight, no endpoint
    /// claimed.
    public static let transcribingProgress = "○○○"

    /// The `captureUnavailable` notice (`WidgetProjection.swift`): the hotkey was pressed and the
    /// microphone did not open — the cause said out loud rather than a press that appears to do
    /// nothing at all. Terminal, exactly as ``WidgetNotice`` is.
    public static func noticeText(_ notice: WidgetNotice) -> String {
        switch notice {
        case .captureUnavailable:
            return "The microphone didn't open — try again."
        }
    }
}
