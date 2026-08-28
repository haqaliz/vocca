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

import VoccaUI
import XCTest

/// The menu bar's decision table: which condition wins when several are true at once.
///
/// The surface itself — `NSStatusItem`, its image, its menu — is glue executed by nothing in CI
/// (the window-server precedent). What is testable, and what actually decides whether the icon
/// tells the truth, is the reduction below.
final class MenuBarStateTests: XCTestCase {

    private let hotkey = "⌥Space"

    // MARK: - One condition at a time

    func testEachConditionResolvesToItsOwnState() {
        XCTAssertEqual(MenuBarStateReducer.state(for: MenuBarConditions()), .ready)
        XCTAssertEqual(
            MenuBarStateReducer.state(for: MenuBarConditions(isCapturing: true)), .listening)
        XCTAssertEqual(
            MenuBarStateReducer.state(for: MenuBarConditions(isTranscribing: true)), .transcribing)
        XCTAssertEqual(
            MenuBarStateReducer.state(for: MenuBarConditions(isHotkeyDeafForPermission: true)),
            .noAccessibility)
        XCTAssertEqual(
            MenuBarStateReducer.state(for: MenuBarConditions(isMicrophoneAvailable: false)),
            .noMicrophone)
        XCTAssertEqual(
            MenuBarStateReducer.state(for: MenuBarConditions(isDownloadingModel: true)),
            .downloadingModel)
        XCTAssertEqual(
            MenuBarStateReducer.state(for: MenuBarConditions(isBlockedBySecureInput: true)),
            .secureInput)
    }

    /// An engine that never prepared reads as "getting ready" rather than as a fault: from the
    /// user's side the wait is the same whether bytes are moving or a load is retrying, and the
    /// remedy — wait — is identical.
    func testAnUnpreparedEngineReadsAsGettingReady() {
        XCTAssertEqual(
            MenuBarStateReducer.state(for: MenuBarConditions(isEnginePrepared: false)),
            .downloadingModel)
    }

    /// **R4 (PRD M11).** An engine that is *warming* reads as its own state, not as the one an
    /// engine that never arrived reads as.
    ///
    /// The two are the same sentence from the icon's side — "you cannot dictate yet" — and
    /// completely different from the user's. After an engine switch the model is already on disk
    /// and the only true thing to say is "a moment"; an icon that reported the same thing it
    /// reports for a model that is missing would tell the user their switch broke something. M11
    /// makes this a must-have rather than polish, because "no window may look identical to
    /// working" is this repository's dominant bug class and it has the same shape.
    func testAPreparingEngineIsItsOwnStateAndNotTheUnavailableOne() {
        XCTAssertEqual(
            MenuBarStateReducer.state(
                for: MenuBarConditions(isEnginePrepared: false, isPreparingEngine: true)),
            .preparingEngine)
        XCTAssertNotEqual(
            MenuBarStateReducer.state(
                for: MenuBarConditions(isEnginePrepared: false, isPreparingEngine: true)),
            MenuBarStateReducer.state(
                for: MenuBarConditions(isEnginePrepared: false, isPreparingEngine: false)),
            "preparing and unavailable must not render as one icon")
    }

    /// A model that is genuinely downloading outranks a warm-up: the download is the longer wait
    /// and the one with progress worth showing, so it is what the icon reports when both are true.
    func testADownloadOutranksAWarmUp() {
        XCTAssertEqual(
            MenuBarStateReducer.state(
                for: MenuBarConditions(
                    isEnginePrepared: false, isDownloadingModel: true, isPreparingEngine: true)),
            .downloadingModel)
    }

    /// Warming is blocked — a press really is refused — but there is nothing to press: a warm-up
    /// has no progress window and ends on its own, exactly as Secure Input does.
    func testAPreparingEngineIsBlockedButOffersNoButton() {
        XCTAssertTrue(MenuBarState.preparingEngine.isBlocked)
        XCTAssertNil(
            MenuBarCopy.actionTitle(for: .preparingEngine),
            "a warm-up has no progress to show and no setting to open — it just finishes")
    }

    // MARK: - Precedence, which is the whole point

    /// Activity outranks housekeeping: a download running for the *other* engine must not take the
    /// icon away from a user who is mid-sentence.
    func testCaptureOutranksABackgroundDownload() {
        XCTAssertEqual(
            MenuBarStateReducer.state(
                for: MenuBarConditions(isCapturing: true, isDownloadingModel: true)),
            .listening)
    }

    /// Capture outranks transcription when both read true — the states overlap for an instant at
    /// the hand-off, and the icon should follow the microphone, which is the part the user can
    /// still affect.
    func testCaptureOutranksTranscription() {
        XCTAssertEqual(
            MenuBarStateReducer.state(
                for: MenuBarConditions(isCapturing: true, isTranscribing: true)),
            .listening)
    }

    /// No Accessibility outranks every other blocker, because it makes them moot: a deaf hotkey
    /// means no dictation whatever the microphone or the model is doing.
    func testMissingAccessibilityOutranksEveryOtherBlocker() {
        let everythingWrong = MenuBarConditions(
            isHotkeyDeafForPermission: true,
            isEnginePrepared: false,
            isDownloadingModel: true,
            isMicrophoneAvailable: false,
            isBlockedBySecureInput: true)
        XCTAssertEqual(MenuBarStateReducer.state(for: everythingWrong), .noAccessibility)
    }

    /// Secure Input is last of the four blockers: it is the only one that needs no action and ends
    /// on its own, so a condition that outlasts a password field is reported first.
    func testSecureInputYieldsToBlockersThatOutlastIt() {
        XCTAssertEqual(
            MenuBarStateReducer.state(
                for: MenuBarConditions(isMicrophoneAvailable: false, isBlockedBySecureInput: true)),
            .noMicrophone)
        XCTAssertEqual(
            MenuBarStateReducer.state(
                for: MenuBarConditions(isDownloadingModel: true, isBlockedBySecureInput: true)),
            .downloadingModel)
    }

    // MARK: - The classifications the icon and menu read

    func testBlockedAndActiveArePartitionedCorrectly() {
        for state in MenuBarState.allCases {
            XCTAssertFalse(
                state.isBlocked && state.isActive,
                "\(state) cannot be both blocked and active")
        }
        XCTAssertEqual(
            Set(MenuBarState.allCases.filter(\.isActive)), [.listening, .transcribing])
        XCTAssertEqual(
            Set(MenuBarState.allCases.filter(\.isBlocked)),
            [.noAccessibility, .noMicrophone, .downloadingModel, .preparingEngine, .secureInput])
    }

    /// Secure Input counts as blocked even though it needs no action: the hotkey genuinely will
    /// not fire, and an icon that claimed readiness would be lying about the only thing it exists
    /// to report.
    func testSecureInputCountsAsBlocked() {
        XCTAssertTrue(MenuBarState.secureInput.isBlocked)
    }

    // MARK: - Copy

    /// Every state has a distinct symbol: the icon is a template image, so shape is the *only*
    /// channel available, and two states sharing one would be indistinguishable rather than merely
    /// similar.
    func testEverySymbolIsDistinct() {
        let symbols = MenuBarState.allCases.map(MenuBarCopy.symbolName(for:))
        XCTAssertEqual(
            Set(symbols).count, MenuBarState.allCases.count,
            "shape is the only channel a template image has; duplicates erase a state")
    }

    /// Every state has a distinct title, for the same reason applied to the words.
    func testEveryTitleIsDistinct() {
        let titles = MenuBarState.allCases.map(MenuBarCopy.statusTitle(for:))
        XCTAssertEqual(Set(titles).count, MenuBarState.allCases.count)
    }

    /// Every state says something, and the ready and blocked states name the hotkey they are
    /// talking about rather than assuming the user remembers it.
    func testDetailIsAlwaysPresentAndNamesTheHotkey() {
        for state in MenuBarState.allCases {
            let detail = MenuBarCopy.statusDetail(for: state, hotkey: hotkey)
            XCTAssertFalse(detail.isEmpty, "\(state) must explain itself")
        }
        XCTAssertTrue(MenuBarCopy.statusDetail(for: .ready, hotkey: hotkey).contains(hotkey))
        XCTAssertTrue(
            MenuBarCopy.statusDetail(for: .noAccessibility, hotkey: hotkey).contains(hotkey))
    }

    /// Only the states with somewhere useful to send the user offer a button — and Secure Input
    /// deliberately does not, because leaving the password field is the remedy and a button would
    /// be an action that does nothing.
    func testOnlyActionableBlockersOfferAButton() {
        XCTAssertNotNil(MenuBarCopy.actionTitle(for: .noAccessibility))
        XCTAssertNotNil(MenuBarCopy.actionTitle(for: .noMicrophone))
        XCTAssertNotNil(MenuBarCopy.actionTitle(for: .downloadingModel))
        XCTAssertNil(
            MenuBarCopy.actionTitle(for: .secureInput),
            "there is nothing to press — it clears when the password field loses focus")
        for state in MenuBarState.allCases where !state.isBlocked {
            XCTAssertNil(MenuBarCopy.actionTitle(for: state), "\(state) is not blocked")
        }
    }

    /// The VoiceOver label carries the whole state in one utterance, because the status item is a
    /// single element whose icon says nothing to a screen reader.
    func testTheAccessibilityLabelCarriesTitleAndDetail() {
        for state in MenuBarState.allCases {
            let label = MenuBarCopy.accessibilityLabel(for: state, hotkey: hotkey)
            XCTAssertTrue(label.hasPrefix("Vocca."), "the label names the app first")
            XCTAssertTrue(label.contains(MenuBarCopy.statusTitle(for: state)))
            XCTAssertTrue(label.contains(MenuBarCopy.statusDetail(for: state, hotkey: hotkey)))
        }
    }
}
