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
import VoccaUI
import XCTest

/// **The Cleanup tab's decisions** — pure, clock-free, and holding no store of its own (the
/// `AppsTabReducer`/`SpeechTabReducer` shape). The page is executed by nothing in CI; everything
/// it decides is decided here.
///
/// ## The one rule the whole file is built around
///
/// ``CleanupTabState/selection`` is **always what is on disk**. It moves on `saveSucceeded` and on
/// nothing else — not on the click, not optimistically, not on a failure. That is what makes
/// "declining leaves the previous choice intact" true by construction rather than by a rollback
/// somebody has to remember to write, and on this tab the previous choice is a privacy setting.
final class CleanupTabReducerTests: XCTestCase {

    // MARK: - What the tab opens as

    /// **The initial state claims nothing.** No rung is reported as running, because nothing has
    /// been asked yet — the `SpeechTabInstall.unknown` posture, applied to the surface where a
    /// wrong claim is a privacy claim.
    func testTheInitialStateClaimsNothing() {
        let state = CleanupTabState.initial

        XCTAssertNil(state.summary, "nothing has resolved yet, so the tab says nothing about it")
        XCTAssertFalse(state.isLoaded)
        XCTAssertNil(state.message)
    }

    /// **A loaded config becomes the selection and the field values.** The radio points at what
    /// the file says, which is what the next launch will use.
    func testALoadedConfigBecomesTheSelectionAndTheFields() {
        let draft = CleanupConfigDraft(
            provider: .ollama,
            ollamaEndpoint: "http://localhost:11434",
            ollamaModel: "llama3.1",
            byokEndpoint: "https://api.example.com/v1",
            byokModel: "gpt-4o-mini")

        let state = CleanupTabReducer.reduce(.initial, .configLoaded(draft))

        XCTAssertEqual(state.selection, .ollama)
        XCTAssertEqual(state.draft, draft)
        XCTAssertTrue(state.isLoaded)
    }

    /// **The summary and the selection are two different facts, and the tab keeps them apart.**
    ///
    /// The selection is the file — what the *next* launch will use. The summary is the resolved
    /// provider — what is cleaning text *now*. They disagree exactly when the user has just
    /// changed the rung, and also when a hand-edited block degraded; collapsing them into one
    /// field is how a tab ends up reporting a provider Vocca is not using, which is the defect
    /// this whole aspect exists to fix.
    func testTheSummaryAndTheSelectionAreKeptApart() {
        var state = CleanupTabReducer.reduce(
            .initial, .configLoaded(CleanupConfigDraft(provider: .byok, byokEndpoint: "https://api.example.com/v1")))
        state = CleanupTabReducer.reduce(
            state,
            .summaryLoaded(
                CleanupSummary(name: "Deterministic rules", sendsTextOffTheMac: false, endpoint: nil)))

        XCTAssertEqual(state.selection, .byok, "the file says cloud")
        XCTAssertEqual(state.summary?.name, "Deterministic rules", "and rules is what is running")
        XCTAssertFalse(state.summary?.sendsTextOffTheMac ?? true)
    }

    // MARK: - Picking a rung

    /// **Picking a rung produces a write of exactly that rung, with the fields the user sees.**
    func testPickingARungPlansAWriteOfThatRung() {
        let state = CleanupTabReducer.reduce(
            .initial,
            .configLoaded(
                CleanupConfigDraft(
                    provider: .rules,
                    ollamaEndpoint: "http://localhost:11434",
                    ollamaModel: "llama3.1")))

        guard case .write(let draft) = CleanupTabReducer.plan(state, picking: .ollama) else {
            return XCTFail("a configured rung is written, not refused")
        }
        XCTAssertEqual(draft.provider, .ollama)
        XCTAssertEqual(draft.ollamaModel, "llama3.1")
    }

    /// **The selection does not move until the write lands.**
    ///
    /// The load-bearing rule. A radio that moved on the click would be telling the user their
    /// choice was made before anything reached the disk, and would have to be rolled back by hand
    /// on every failure path — including the one where the user declines the cloud dialog.
    func testTheSelectionDoesNotMoveUntilTheWriteLands() {
        let state = CleanupTabReducer.reduce(
            .initial,
            .configLoaded(
                CleanupConfigDraft(provider: .rules, ollamaEndpoint: "http://localhost:11434", ollamaModel: "llama3.1")))

        _ = CleanupTabReducer.plan(state, picking: .ollama)
        XCTAssertEqual(state.selection, .rules, "planning a write is not making one")

        let saved = CleanupTabReducer.reduce(state, .saveSucceeded(.ollama))
        XCTAssertEqual(saved.selection, .ollama)
        XCTAssertNil(saved.message, "a success clears whatever the last failure said")
    }

    /// **A failed write leaves the previous choice intact and says so.**
    ///
    /// The file is what the next launch reads, so a write that did not land means the rung did not
    /// change — and a tab that showed the new rung anyway would be claiming a privacy setting that
    /// is not in force.
    func testAFailedWriteLeavesThePreviousChoiceIntact() {
        var state = CleanupTabReducer.reduce(
            .initial, .configLoaded(CleanupConfigDraft(provider: .rules)))
        state = CleanupTabReducer.reduce(state, .saveFailed("the disk is full"))

        XCTAssertEqual(state.selection, .rules)
        XCTAssertEqual(state.message, CleanupTabCopy.saveFailed("the disk is full"))
    }

    /// **A rung whose required fields are blank is refused, not written.**
    ///
    /// An `ollama` block with no model does not decode (`CleanupConfig.decodeOllamaBlock`): the
    /// whole config degrades to rules with a loud log. Writing it would leave the radio on
    /// "Local AI" and Vocca on the built-in rules — a page and a product that disagree, which is
    /// the class of defect this aspect exists to end.
    func testARungWithBlankRequiredFieldsIsRefused() {
        let state = CleanupTabReducer.reduce(
            .initial, .configLoaded(CleanupConfigDraft(provider: .rules)))

        guard case .refuse(let message) = CleanupTabReducer.plan(state, picking: .ollama) else {
            return XCTFail("an unconfigured Ollama rung must be refused rather than written")
        }
        XCTAssertEqual(message, CleanupTabCopy.missingFields(.ollama))

        guard case .refuse = CleanupTabReducer.plan(state, picking: .byok) else {
            return XCTFail("a BYOK rung with no endpoint must be refused too")
        }
    }

    /// **Whitespace is not a value.** An endpoint of three spaces is a blank endpoint; treating it
    /// as configured would write a block that cannot decode.
    func testWhitespaceIsNotAConfiguredField() {
        let state = CleanupTabReducer.reduce(
            .initial,
            .configLoaded(
                CleanupConfigDraft(provider: .rules, ollamaEndpoint: "   ", ollamaModel: "  ")))

        guard case .refuse = CleanupTabReducer.plan(state, picking: .ollama) else {
            return XCTFail("whitespace is blank")
        }
    }

    /// **The rules rung is always available.** It requires no configuration and is the
    /// zero-network default — the way back from any other rung must never be refused.
    func testTheRulesRungIsAlwaysAvailable() {
        let state = CleanupTabReducer.reduce(
            .initial, .configLoaded(CleanupConfigDraft(provider: .byok, byokEndpoint: "https://api.example.com/v1")))

        guard case .write(let draft) = CleanupTabReducer.plan(state, picking: .rules) else {
            return XCTFail("the way back to the local default is never refused")
        }
        XCTAssertEqual(draft.provider, .rules)
        XCTAssertEqual(
            draft.byokEndpoint, "https://api.example.com/v1",
            "and leaving the cloud rung does not cost the endpoint the user typed")
    }

    /// **A refusal is a message, never a moved selection.**
    func testARefusalIsFoldedAsAMessageAndMovesNothing() {
        var state = CleanupTabReducer.reduce(
            .initial, .configLoaded(CleanupConfigDraft(provider: .rules)))
        state = CleanupTabReducer.reduce(
            state, .selectionRefused(CleanupTabCopy.missingFields(.ollama)))

        XCTAssertEqual(state.selection, .rules)
        XCTAssertEqual(state.message, CleanupTabCopy.missingFields(.ollama))
    }

    // MARK: - Editing the fields

    /// **Editing a field changes the draft and nothing else.** In particular it does not change
    /// the selection: typing an Ollama endpoint is not choosing Ollama.
    func testEditingAFieldChangesTheDraftAndNotTheSelection() {
        var state = CleanupTabReducer.reduce(
            .initial, .configLoaded(CleanupConfigDraft(provider: .rules)))
        state = CleanupTabReducer.reduce(state, .endpointEdited(.byok, "https://api.example.com/v1"))
        state = CleanupTabReducer.reduce(state, .modelEdited(.byok, "gpt-4o-mini"))

        XCTAssertEqual(state.draft.byokEndpoint, "https://api.example.com/v1")
        XCTAssertEqual(state.draft.byokModel, "gpt-4o-mini")
        XCTAssertEqual(state.selection, .rules, "typing an endpoint is not choosing the rung")
    }

    /// **Editing the Ollama fields never touches the BYOK ones**, and the other way round. One
    /// draft holds both blocks precisely so a switch back does not lose the other's values, which
    /// only works if the two are actually independent.
    func testTheTwoBlocksAreIndependent() {
        var state = CleanupTabReducer.reduce(
            .initial,
            .configLoaded(
                CleanupConfigDraft(
                    provider: .rules,
                    ollamaEndpoint: "http://localhost:11434", ollamaModel: "llama3.1",
                    byokEndpoint: "https://api.example.com/v1", byokModel: "gpt-4o-mini")))
        state = CleanupTabReducer.reduce(state, .endpointEdited(.ollama, "http://elsewhere:11434"))

        XCTAssertEqual(state.draft.ollamaEndpoint, "http://elsewhere:11434")
        XCTAssertEqual(state.draft.byokEndpoint, "https://api.example.com/v1")
        XCTAssertEqual(state.draft.byokModel, "gpt-4o-mini")
    }

    /// **Editing a field for the rules rung is a no-op.** `rules` has no endpoint and no model,
    /// and an action that silently invented one would be a field the file cannot hold.
    func testEditingTheRulesRungChangesNothing() {
        let loaded = CleanupTabReducer.reduce(
            .initial, .configLoaded(CleanupConfigDraft(provider: .rules)))

        let edited = CleanupTabReducer.reduce(loaded, .endpointEdited(.rules, "http://nowhere"))

        XCTAssertEqual(edited.draft, loaded.draft)
    }

    // MARK: - R4: the key is not here

    /// **The tab's state has no field that could hold a key.**
    ///
    /// Asserted structurally rather than trusted to review: the BYOK key lives in the Keychain
    /// behind the `KeyProvider` seam, and a `key` field added to this state would be one edit away
    /// from a plain-text file in Application Support. `Mirror` catches it the day it is added,
    /// which is the only day it is cheap to remove.
    func testTheTabStateHasNoFieldThatCouldHoldAKey() {
        let state = CleanupTabReducer.reduce(
            .initial,
            .configLoaded(
                CleanupConfigDraft(provider: .byok, byokEndpoint: "https://api.example.com/v1")))

        for label in Self.labels(of: state) {
            for forbidden in ["key", "token", "secret", "password", "credential"] {
                XCTAssertFalse(
                    label.lowercased().contains(forbidden),
                    "the Cleanup tab must never carry key material — found \"\(label)\"")
            }
        }
    }

    /// Every property label reachable from `value`, one level of nesting deep — enough to reach
    /// the draft's own fields, which is where a key would most plausibly be added.
    private static func labels(of value: Any) -> [String] {
        Mirror(reflecting: value).children.flatMap { child -> [String] in
            let own = child.label.map { [$0] } ?? []
            return own + Mirror(reflecting: child.value).children.compactMap(\.label)
        }
    }
}
