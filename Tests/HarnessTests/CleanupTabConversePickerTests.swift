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

/// **D3 — the Cleanup tab's converse picker contract**: one control, the "While conversing"
/// section, reusing the same rung rows, the same field editors and the same byok confirmation
/// dialog as the dictate picker — nothing about the existing picker changes.
///
/// The tab keeps the two-selections doctrine in parallel: ``CleanupTabState/converseSelection``
/// is always what the file names for conversations, and it moves on
/// ``CleanupTabAction/converseSaveSucceeded(_:)`` and on nothing else — the dictate doctrine
/// (`CleanupTabState.swift:47-53`), applied to the converse half.
final class CleanupTabConversePickerTests: XCTestCase {

    // MARK: - Loading

    /// **A loaded config moves both selections from the draft** — the file's two halves land in
    /// `selection` and `converseSelection` together.
    func testConfigLoadedMovesBothSelectionsFromTheDraft() {
        let draft = CleanupConfigDraft(
            provider: .ollama, converseProvider: .byok,
            ollamaEndpoint: "http://localhost:11434", ollamaModel: "llama3.1",
            byokEndpoint: "https://api.example.com/v1", byokModel: "gpt-4o-mini")

        let state = CleanupTabReducer.reduce(.initial, .configLoaded(draft))

        XCTAssertEqual(state.selection, .ollama, "the dictate selection moves as before")
        XCTAssertEqual(state.converseSelection, .byok, "and the converse selection moves with it")
        XCTAssertEqual(state.draft, draft)
    }

    // MARK: - Planning for the converse mode

    /// **Picking a converse rung with blank required fields is refused, not written** — the same
    /// refusal as the dictate picker, for the converse half.
    func testPickingForTheConverseModeRefusesAnUnconfiguredRung() {
        let state = CleanupTabReducer.reduce(
            .initial, .configLoaded(CleanupConfigDraft(provider: .rules)))

        guard case .refuse(let message) = CleanupTabReducer.plan(
            state, picking: .byok, mode: .conversing)
        else {
            return XCTFail("an unconfigured converse BYOK rung must be refused")
        }
        XCTAssertEqual(message, CleanupTabCopy.missingFields(.byok))
        XCTAssertEqual(state.converseSelection, .rules, "a refusal moves nothing")
    }

    /// **Picking the converse cloud rung asks the same confirmation first** — an unacknowledged
    /// cloud rung is a confirmation, not a write, whichever picker asked.
    func testPickingForTheConverseModeConfirmsByokBeforeWriting() {
        let state = Self.loaded(converse: .rules)

        guard case .confirm(let kind) = CleanupTabReducer.plan(
            state, picking: .byok, mode: .conversing)
        else {
            return XCTFail("the converse cloud rung must be confirmed before anything is written")
        }
        XCTAssertEqual(kind, .byok)
    }

    /// **Picking a converse rung writes the draft with only the converse half moved** — the
    /// dictate half is byte-for-byte what it was.
    func testPickingForTheConverseModeWritesTheDraftWithOnlyTheConverseHalfMoved() {
        let state = Self.loaded(converse: .rules)

        guard case .write(let draft) = CleanupTabReducer.plan(
            state, picking: .ollama, mode: .conversing)
        else {
            return XCTFail("a configured converse ollama rung is written")
        }
        XCTAssertEqual(draft.converseProvider, .ollama, "the converse half moves")
        XCTAssertEqual(
            draft.provider, state.draft.provider,
            "the dictate half is untouched by a converse pick")
    }

    // MARK: - The only movers

    /// **`converseSaveSucceeded` moves only the converse selection** — the one action that does,
    /// and the dictate selection never moves from it.
    func testConverseSaveSucceededMovesOnlyTheConverseSelection() {
        var state = Self.loaded(converse: .rules)
        state = CleanupTabReducer.reduce(state, .converseSaveSucceeded(.ollama))

        XCTAssertEqual(state.converseSelection, .ollama)
        XCTAssertEqual(
            state.selection, state.draft.provider,
            "the dictate selection never moves from the converse action")
        XCTAssertEqual(state.draft.converseProvider, .ollama, "the draft's converse half follows")
    }

    /// **`saveSucceeded` still moves only the dictation selection** — the existing doctrine,
    /// pinned against the new field.
    func testSaveSucceededStillMovesOnlyTheDictationSelection() {
        var state = Self.loaded(converse: .byok)
        state = CleanupTabReducer.reduce(state, .saveSucceeded(.ollama))

        XCTAssertEqual(state.selection, .ollama)
        XCTAssertEqual(
            state.converseSelection, .byok,
            "the converse selection never moves from the dictate action")
    }

    /// **The no-mode plan still defaults to dictation** — every existing call site compiles and
    /// behaves exactly as today.
    func testTheDictationPickerPlanStillDefaultsToDictation() {
        let state = Self.loaded(converse: .byok)

        guard case .write(let draft) = CleanupTabReducer.plan(state, picking: .ollama) else {
            return XCTFail("no mode means dictation — a configured ollama rung is written")
        }
        XCTAssertEqual(draft.provider, .ollama)
        XCTAssertEqual(
            draft.converseProvider, .byok,
            "a dictation pick never touches the converse half")
    }

    // MARK: - The confirmation flow carries the mode

    /// **`.confirmationRequested` stores the pending pair** — kind and mode — and
    /// `.confirmationAccepted` clears it.
    func testConfirmationRequestedCarriesThePendingMode() {
        var state = Self.loaded(converse: .rules)
        state = CleanupTabReducer.reduce(state, .confirmationRequested(.byok, for: .conversing))

        XCTAssertEqual(state.pendingConfirmation?.kind, .byok)
        XCTAssertEqual(
            state.pendingConfirmation?.mode, .conversing,
            "the confirmation must know which picker asked — the accept re-plans the same mode")

        state = CleanupTabReducer.reduce(state, .confirmationAccepted)
        XCTAssertNil(state.pendingConfirmation)
    }

    // MARK: - The rows

    /// **`converseRows` derive from the converse selection** via the shared rows function — the
    /// same rows, the same order, the same configured answers, each list selected by its own
    /// selection.
    func testConverseRowsReflectTheConverseSelection() {
        var state = Self.loaded(converse: .rules)
        state = CleanupTabReducer.reduce(state, .converseSaveSucceeded(.ollama))

        XCTAssertEqual(
            state.converseRows.map(\.kind), state.rows.map(\.kind),
            "both pickers enumerate the same rungs, in the same order")
        XCTAssertEqual(
            state.converseRows.map(\.isConfigured), state.rows.map(\.isConfigured),
            "both pickers share the one draft's configured answers")
        XCTAssertEqual(
            state.converseRows.first { $0.kind == .ollama }?.isSelected, true,
            "the converse rows point at the converse selection")
        XCTAssertEqual(
            state.rows.first { $0.kind == .ollama }?.isSelected, false,
            "and the dictate rows are their own fact")
    }

    // MARK: - Fixtures

    /// A loaded tab with both blocks configured so the rung under test is never refused for the
    /// wrong reason — the `CleanupCloudConfirmationTests.loaded` shape.
    private static func loaded(converse: CleanupProviderKind) -> CleanupTabState {
        CleanupTabReducer.reduce(
            .initial,
            .configLoaded(
                CleanupConfigDraft(
                    provider: .rules, converseProvider: converse,
                    ollamaEndpoint: "http://localhost:11434",
                    ollamaModel: "llama3.1",
                    byokEndpoint: "https://api.example.com/v1",
                    byokModel: "gpt-4o-mini")))
    }
}