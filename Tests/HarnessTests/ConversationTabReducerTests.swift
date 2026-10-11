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

/// The Conversation tab's decisions (`turn-history` `conversation-surface` S2) — the
/// ``UsageTabReducer`` split: the page is glue, the words are ``ConversationTabCopy``'s, and
/// what is left here is the mapping from the snapshot the wiring handed in to the rows the
/// page renders, plus the one transition the Forget control folds.
///
/// The store is never named here: `VoccaUI` imports only `VoccaCore` (`ModuleBoundaryTests`),
/// so the snapshot is the adapter's answer and the mapping from the store's turns to these rows
/// lives at the composition root — the `UsageSnapshot`/`SettingsBindings` precedent.
final class ConversationTabReducerTests: XCTestCase {

    /// The window opens unread: no rows and `isLoaded == false` — the state the page shows
    /// before its `.task` lands, which must not render as the empty state (the
    /// ``UsageTabState/initial`` contract).
    func testTheDefaultStateIsNotLoadedAndHoldsNothing() {
        XCTAssertEqual(ConversationTabState.initial.rows, [])
        XCTAssertFalse(ConversationTabState.initial.isLoaded)
    }

    /// A loaded, empty window is not the unread state: the page read the store and the store
    /// holds nothing, which is "No conversation yet." rather than "we haven't looked".
    func testALoadedEmptyWindowIsNotEqualToTheUnreadState() {
        let loaded = ConversationTabReducer.reduce(
            ConversationTabState.initial,
            .snapshotLoaded(ConversationSnapshot(turns: [])))
        XCTAssertNotEqual(loaded, ConversationTabState.initial)
        XCTAssertTrue(loaded.isLoaded, "the load must mark the page read")
        XCTAssertTrue(loaded.rows.isEmpty)
    }

    /// A snapshot's turns render as rows, newest first — the ``UsageDayRow`` ordering argument:
    /// a person opening this tab is looking for the latest exchange, and a 50-turn window
    /// scrolled from the oldest is the same finding-the-newest walk for every single visit.
    func testRowsRenderNewestFirst() {
        let snapshot = ConversationSnapshot(turns: [
            Self.row(0, utterance: "first", reply: "first answer"),
            Self.row(1, utterance: "second", reply: "second answer"),
            Self.row(2, utterance: "third", reply: "third answer"),
        ])
        let state = ConversationTabReducer.reduce(
            ConversationTabState.initial, .snapshotLoaded(snapshot))
        XCTAssertEqual(state.rows.map(\.utterance), ["third", "second", "first"])
        XCTAssertTrue(state.isLoaded)
    }

    /// The interrupted flag rides the row, untouched — the page's marker (S2) reads exactly
    /// what the driver's barge-in mark wrote, never a re-derivation.
    func testTheInterruptedFlagRidesTheRow() {
        let snapshot = ConversationSnapshot(turns: [
            Self.row(0, utterance: "hello", reply: "hi", interrupted: false),
            Self.row(1, utterance: "wait", reply: "long answer", interrupted: true),
        ])
        let state = ConversationTabReducer.reduce(
            ConversationTabState.initial, .snapshotLoaded(snapshot))
        XCTAssertEqual(state.rows.first?.interrupted, true)
        XCTAssertEqual(state.rows.last?.interrupted, false)
    }

    /// A row's identity is its append position — the only stable answer a store with no IDs
    /// can give, and the one thing ordering needs (`prd.md` R1: "no IDs beyond what ordering
    /// needs").
    func testARowIsIdentifiedByItsAppendPosition() {
        let snapshot = ConversationSnapshot(turns: [
            Self.row(0, utterance: "a", reply: "b"),
            Self.row(1, utterance: "c", reply: "d"),
        ])
        let state = ConversationTabReducer.reduce(
            ConversationTabState.initial, .snapshotLoaded(snapshot))
        XCTAssertEqual(Set(state.rows.map(\.id)).count, 2, "position identity is unique per row")
        XCTAssertEqual(state.rows.first?.id, 1, "the first rendered row is the newest stored one")
    }

    /// Forget empties the window but keeps it read — the ``UsageTabReducer`` `.cleared` shape:
    /// the user just watched it empty, and dropping back to "we haven't looked yet" would be a
    /// second false claim on top of the first.
    func testClearedEmptiesTheStateButKeepsItRead() {
        let loaded = ConversationTabReducer.reduce(
            ConversationTabState.initial,
            .snapshotLoaded(
                ConversationSnapshot(turns: [Self.row(0, utterance: "a", reply: "b")])))
        let cleared = ConversationTabReducer.reduce(loaded, .cleared)
        XCTAssertTrue(cleared.rows.isEmpty)
        XCTAssertTrue(
            cleared.isLoaded,
            "still read: the user watched the conversation empty, so 'we haven't looked yet' "
                + "would be a second false claim on top of the first")
    }

    /// State equality distinguishes the two fields — the ``UsageTabState`` shape, so a test
    /// that relies on whole-state equality cannot pass two states that render differently.
    func testStateEqualityDistinguishesEveryField() {
        XCTAssertNotEqual(
            ConversationTabState(rows: [], isLoaded: false),
            ConversationTabState(rows: [], isLoaded: true))
        XCTAssertNotEqual(
            ConversationTabState(rows: [Self.row(0, utterance: "a", reply: "b")], isLoaded: true),
            ConversationTabState(rows: [], isLoaded: true))
    }

    /// Row equality distinguishes every field — the interrupted flag especially: a row that
    /// lost its marker and a row that kept it are different renderings.
    func testRowEqualityDistinguishesEveryField() {
        XCTAssertNotEqual(Self.row(0, utterance: "a", reply: "b"), Self.row(1, utterance: "a", reply: "b"))
        XCTAssertNotEqual(Self.row(0, utterance: "a", reply: "b"), Self.row(0, utterance: "c", reply: "b"))
        XCTAssertNotEqual(Self.row(0, utterance: "a", reply: "b"), Self.row(0, utterance: "a", reply: "c"))
        XCTAssertNotEqual(
            Self.row(0, utterance: "a", reply: "b", interrupted: true),
            Self.row(0, utterance: "a", reply: "b", interrupted: false))
        XCTAssertNotEqual(
            ConversationSnapshot(turns: [Self.row(0, utterance: "a", reply: "b")]),
            ConversationSnapshot(turns: []))
    }

    /// A fixture row at append position `position`.
    private static func row(
        _ position: Int, utterance: String, reply: String, interrupted: Bool = false
    ) -> ConversationTurnRow {
        ConversationTurnRow(
            position: position, utterance: utterance, reply: reply, interrupted: interrupted)
    }
}