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

/// The honest-drop vocabulary's contract (`dual-mode` PRD O10, `prd.md:248`): a failed
/// `.conversing` turn is not owed — no injection, no hang, one notice, and the loop stays
/// listening. Written first, against a type that does not exist yet — compile-time RED is
/// the right reason for a new seam (the reply-seam precedent).
final class ConverseTurnFailureTests: XCTestCase {

    /// The vocabulary is exactly the three cases — the exhaustive switch is the compile pin: a
    /// fourth case stops every caller's switch from building, so a new failure has to be given
    /// a meaning at every delivery site before it can exist.
    func testTheFailureVocabularyIsExactlyTheThreeCases() {
        func describe(_ failure: ConverseTurnFailure) -> String {
            switch failure {
            case .asrFailed: return "asrFailed"
            case .replyFailed: return "replyFailed"
            case .captureFailed: return "captureFailed"
            }
        }
        XCTAssertEqual(describe(.asrFailed), "asrFailed")
        XCTAssertEqual(describe(.replyFailed), "replyFailed")
        XCTAssertEqual(describe(.captureFailed), "captureFailed")
    }

    /// The vocabulary crosses to the owner's surface (the widget's notice) and is compared —
    /// `Sendable + Equatable`, the `TurnState` shape.
    func testTheVocabularyIsSendableAndEquatable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        func requireEquatable<T: Equatable>(_ value: T) -> T { value }

        let a = requireSendable(ConverseTurnFailure.asrFailed)
        let b = requireEquatable(ConverseTurnFailure.asrFailed)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(ConverseTurnFailure.asrFailed, ConverseTurnFailure.replyFailed)
        XCTAssertNotEqual(ConverseTurnFailure.replyFailed, ConverseTurnFailure.captureFailed)
    }

    /// The doc-comment contract is the honest-drop rule, pinned here as a scan so the
    /// vocabulary's documentation cannot silently stop saying what the behavior tests enforce:
    /// the notice is **one-shot** (fires exactly once per failed turn) and **terminal-per-turn**
    /// (the turn is not owed — nothing is injected, the loop stays listening).
    func testTheDocCommentCarriesTheOneShotTerminalPerTurnContract() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/VoccaCore/TurnTaking/ConverseTurnFailure.swift"),
            encoding: .utf8)

        XCTAssertTrue(
            source.contains("once"), "the doc comment must say the notice fires exactly once")
        XCTAssertTrue(
            source.contains("not owed"),
            "the doc comment must say the turn is not owed (the loop's capture-failure rationale)")
    }
}