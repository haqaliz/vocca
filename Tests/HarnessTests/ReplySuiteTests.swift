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

/// The CI legs of the `ReplyFixtureSuite`: the committed fixture cases run over both shipped
/// implementations — `EchoReplyGenerator` (the wired default) and
/// `AcknowledgmentReplyGenerator` (the second implementation) — one leg per implementation
/// (`reply-seam` plan D3: stub-free, both implementations are headless and real).
///
/// Each implementation's table is committed here with its expected replies written by hand —
/// the difference between pinning a contract and restating an implementation. The
/// acknowledgment table's expected column is the same fixed copy in every row:
/// input-independence is the fixture table made visible.
final class ReplySuiteTests: XCTestCase {

    /// The echo's committed fixture table (`reply-seam` plan §Testing strategy): the identity
    /// function, every row a verbatim expectation — including the empty row, the
    /// whitespace-verbatim row and the punctuation-verbatim row.
    func testTheCommittedEchoFixtureCasesReplyVerbatim() throws {
        let cases: [ReplyFixtureCase] = [
            ReplyFixtureCase(name: "echo-short-phrase", input: "hello vocca", expected: "hello vocca"),
            ReplyFixtureCase(name: "echo-sentence", input: "What time is it?", expected: "What time is it?"),
            ReplyFixtureCase(
                name: "echo-cleanup-polish", input: "Set a reminder for nine am",
                expected: "Set a reminder for nine am"),
            ReplyFixtureCase(name: "echo-empty", input: "", expected: ""),
            ReplyFixtureCase(name: "echo-whitespace-verbatim", input: "  ", expected: "  "),
            ReplyFixtureCase(
                name: "echo-punctuation-verbatim", input: "It's — really?",
                expected: "It's — really?"),
        ]

        let results = ReplyFixtureSuite.evaluate(EchoReplyGenerator(), cases: cases)

        XCTAssertEqual(
            results.count, cases.count,
            "the suite records one result per fixture — a missing result would hide a fixture")
        for (result, fixture) in zip(results, cases) {
            XCTAssertEqual(
                result.reply, fixture.expected,
                "fixture \(result.name) replied off its hand-written expectation")
        }
    }

    /// The acknowledgment's committed fixture table: the fixed copy `"Vocca is listening."`
    /// for every input — the long multi-sentence utterance included. A copy edit anywhere
    /// fails the exact-equality comparisons here (and the exact-copy pin in
    /// ``ReplySeamTests``).
    func testTheCommittedAcknowledgmentFixtureCasesReplyTheFixedCopy() throws {
        let cases: [ReplyFixtureCase] = [
            ReplyFixtureCase(
                name: "ack-short-phrase", input: "hello vocca", expected: "Vocca is listening."),
            ReplyFixtureCase(
                name: "ack-question", input: "What time is it?", expected: "Vocca is listening."),
            ReplyFixtureCase(name: "ack-empty", input: "", expected: "Vocca is listening."),
            ReplyFixtureCase(name: "ack-whitespace", input: "  ", expected: "Vocca is listening."),
            ReplyFixtureCase(
                name: "ack-long-text",
                input: "The meeting is at three and I need to prepare the slides before then, "
                    + "so please remind me an hour early, and also check whether the projector "
                    + "is booked.",
                expected: "Vocca is listening."),
        ]

        let results = ReplyFixtureSuite.evaluate(AcknowledgmentReplyGenerator(), cases: cases)

        XCTAssertEqual(
            results.count, cases.count,
            "the suite records one result per fixture — a missing result would hide a fixture")
        for (result, fixture) in zip(results, cases) {
            XCTAssertEqual(
                result.reply, fixture.expected,
                "fixture \(result.name) replied off its hand-written expectation")
        }
    }
}