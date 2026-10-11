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

/// The Conversation tab's words (`turn-history` `conversation-surface`) — the
/// ``UsageTabCopyTests`` shape: every string the page renders lives here, so a word is a
/// decision pinned by exact equality, never a literal sitting free in a view.
///
/// The bound disclosure is the one line whose number must stay attached to the store's actual
/// window: `VoccaUI` may not name `VoccaConversation` (`ModuleBoundaryTests`), so 50 is decided
/// copy here and pinned — the day the store's cap moves, this line and its test move with it.
final class ConversationTabCopyTests: XCTestCase {

    /// Before the file has been read. Distinct from ``ConversationTabCopy/empty`` on purpose: a
    /// store that failed to load must never present itself as "no conversation" to a user who
    /// conversed an hour ago.
    func testTheLoadingStateIsPinned() {
        XCTAssertEqual(ConversationTabCopy.loading, "Reading the conversation…")
    }

    /// Read, and holding nothing — the honest empty state (S2): a fresh install has never
    /// conversed, and the page says so rather than drawing a blank area.
    func testTheEmptyStateIsPinned() {
        XCTAssertEqual(ConversationTabCopy.empty, "No conversation yet.")
    }

    /// The interrupted marker (S2) — the word a barge-in'd turn earns, attached to the row the
    /// driver marked rather than to a guess.
    func testTheInterruptedMarkerIsPinned() {
        XCTAssertEqual(ConversationTabCopy.interruptedMarker, "Interrupted")
    }

    /// The Forget control's button. Names what goes, not what happens to a screen.
    func testTheForgetButtonIsPinned() {
        XCTAssertEqual(ConversationTabCopy.forgetButton, "Forget conversation")
    }

    /// What it does, and the part that earns the confirmation: this deletes bytes rather than
    /// resetting something derived — the Speech removal treatment, the ``UsageTabCopy`` Clear's
    /// own argument.
    func testTheForgetExplanationIsPinned() {
        XCTAssertEqual(
            ConversationTabCopy.forgetExplanation,
            "Deletes the file the conversation is kept in. It can't be undone.")
    }

    /// The confirmation's question, the destructive choice and the way out — the
    /// ``UsageTabCopy`` clear-dialog trio, asked about everything because that is what goes.
    func testTheForgetConfirmationTrioIsPinned() {
        XCTAssertEqual(ConversationTabCopy.forgetConfirmationTitle, "Forget the whole conversation?")
        XCTAssertEqual(ConversationTabCopy.forgetConfirmButton, "Forget it")
        XCTAssertEqual(ConversationTabCopy.forgetCancelButton, "Keep it")
    }

    /// The disclosed window (`prd.md` R2, D3): the bound is said out loud, so eviction is never
    /// a surprise — and the sentence names the actual 50-turn window the store applies.
    func testTheBoundDisclosureIsPinnedAndNamesTheWindow() {
        XCTAssertEqual(
            ConversationTabCopy.boundDisclosure,
            "Vocca keeps the last 50 turns; when the window is full, the oldest are dropped.")
        XCTAssertTrue(
            ConversationTabCopy.boundDisclosure.contains("keeps the last 50 turns"),
            "the disclosure no longer names the bound the store actually applies")
    }

    /// The privacy line (the ``UsageTabCopy/localOnly`` sentence, reused — one claim, one
    /// vocabulary): this tab is the first screen that shows what the user *said*, and the line
    /// that it never left the machine is the whole reason the window exists.
    func testTheLocalOnlyLineIsPinned() {
        XCTAssertEqual(
            ConversationTabCopy.localOnly,
            "All of this is read from a file on this Mac. None of it has ever left it.")
    }

    /// No word on the page reads as a browser's: `PRODUCT_SPEC.md` §12's "No transcript history
    /// browser" stands — this is a bounded window of recent turns, never an archive with a
    /// search and a pager. The empty state and the disclosure both say "conversation", never
    /// "history", and the count of what is kept is the window, never a total.
    func testNoWordClaimsABrowserOrATotal() {
        for line in [
            ConversationTabCopy.empty,
            ConversationTabCopy.boundDisclosure,
            ConversationTabCopy.loading,
        ] {
            XCTAssertFalse(line.lowercased().contains("archive"))
            XCTAssertFalse(line.lowercased().contains("search"))
        }
    }
}