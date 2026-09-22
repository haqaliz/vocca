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

/// The keyword resolver's own acceptance table (`intent-seam` spec acceptance 1-4), on top of
/// the contract suite: matched → `.toolCall`, below the threshold → `.ask`, nothing → `.none`,
/// never a tool the catalog does not name — plus the two failure modes the table is written to
/// catch first: a **planted wrong-synonym row** that must not resolve to a wrong tool, and an
/// **argument text over the 4 KB bound** that must be refused, never truncated.
final class KeywordIntentResolverTests: XCTestCase {

    private static let auditClear = ToolReference(
        providerID: "dev.vocca.audit", toolID: "audit.clear",
        displayName: "Clear the audit log")
    private static let auditCount = ToolReference(
        providerID: "dev.vocca.audit", toolID: "audit.count",
        displayName: "Count the audit log")
    private static let postMessage = ToolReference(
        providerID: "dev.vocca.mcp.chat", toolID: "post_message",
        displayName: "Post a message")

    private func makeInvocation(
        providerID: String, toolID: String, arguments: String? = nil
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(providerID: providerID, toolID: toolID, arguments: arguments),
            "expected a constructible ActionInvocation")
    }

    // MARK: - Acceptance 1 — a matched utterance resolves to a tool call

    /// The seeded rows, resolved exactly: each phrase lands on its own tool, never the sibling.
    func testSeededPhrasesResolveToTheirOwnTools() throws {
        let resolver = KeywordIntentResolver()
        let catalog = [Self.auditClear, Self.auditCount]

        XCTAssertEqual(
            resolver.resolve("clear the audit log", against: catalog),
            .toolCall(try makeInvocation(providerID: "dev.vocca.audit", toolID: "audit.clear")))
        XCTAssertEqual(
            resolver.resolve("count the audit log", against: catalog),
            .toolCall(try makeInvocation(providerID: "dev.vocca.audit", toolID: "audit.count")))
    }

    /// Matching is lowercase-normalised and stop words are glue, not signal: a shouted phrase and
    /// a phrase padded with "please" and "for me" resolve the same way.
    func testMatchingIsCaseInsensitiveAndIgnoresStopWords() throws {
        let resolver = KeywordIntentResolver()
        let catalog = [Self.auditClear, Self.auditCount]

        XCTAssertEqual(
            resolver.resolve("CLEAR THE AUDIT LOG", against: catalog),
            .toolCall(try makeInvocation(providerID: "dev.vocca.audit", toolID: "audit.clear")))
        XCTAssertEqual(
            resolver.resolve("please clear the audit log for me", against: catalog),
            .toolCall(try makeInvocation(providerID: "dev.vocca.audit", toolID: "audit.clear")))
    }

    /// The arguments row: the resolver builds the JSON text the seed declares, with the whole
    /// cleaned utterance substituted into the placeholder — a longer utterance is carried whole,
    /// not cut down to the phrase.
    func testTheArgumentsRowBuildsTheUtteranceIntoTheJSONText() throws {
        let resolver = KeywordIntentResolver()
        let catalog = [Self.postMessage]

        XCTAssertEqual(
            resolver.resolve("post a message", against: catalog),
            .toolCall(
                try makeInvocation(
                    providerID: "dev.vocca.mcp.chat", toolID: "post_message",
                    arguments: #"{"text": "post a message"}"#)))
        XCTAssertEqual(
            resolver.resolve("post a message to the team", against: catalog),
            .toolCall(
                try makeInvocation(
                    providerID: "dev.vocca.mcp.chat", toolID: "post_message",
                    arguments: #"{"text": "post a message to the team"}"#)))
    }

    // MARK: - Acceptance 2 — below the threshold, the resolver asks

    /// "the audit log" matches both audit tools at the same score, below the threshold — the
    /// resolution names both, in deterministic (score, then lexical) order.
    func testAnAmbiguousUtteranceAsksNamingBothCandidatesInOrder() {
        let resolver = KeywordIntentResolver()
        let catalog = [Self.auditClear, Self.auditCount]

        XCTAssertEqual(
            resolver.resolve("the audit log", against: catalog),
            .ask(question: "Did you mean 'Clear the audit log' or 'Count the audit log'?"))
    }

    /// The ask is bounded: a three-way tie below the threshold names all three, capped at three.
    func testTheAskNamesAtMostThreeCandidatesInDeterministicOrder() {
        let resolver = KeywordIntentResolver()
        let logViewer = ToolReference(
            providerID: "dev.vocca.logs", toolID: "open_log", displayName: "Open the log viewer")
        let catalog = [Self.auditClear, Self.auditCount, logViewer]

        XCTAssertEqual(
            resolver.resolve("the log", against: catalog),
            .ask(
                question: "Did you mean 'Clear the audit log', 'Count the audit log' or "
                    + "'Open the log viewer'?"))
    }

    // MARK: - Acceptance 3 — nothing matched, nothing resolved

    /// An utterance sharing no token with the catalog resolves `.none`; so do empty and
    /// whitespace-only utterances — nothing to match is not an ask and not a guess.
    func testUtterancesMatchingNothingResolveNone() {
        let resolver = KeywordIntentResolver()
        let catalog = [Self.auditClear, Self.auditCount]

        XCTAssertEqual(resolver.resolve("good morning", against: catalog), .none)
        XCTAssertEqual(resolver.resolve("", against: catalog), .none)
        XCTAssertEqual(resolver.resolve("   ", against: catalog), .none)
        XCTAssertEqual(resolver.resolve("please do the", against: catalog), .none)
    }

    // MARK: - Acceptance 4 — never a wrong tool, never an invented tool

    /// The planted wrong-synonym row: a table that adds "count the audit log" → `audit.clear` on
    /// top of the correct rows must still resolve the count phrase to `audit.count` — and the
    /// clear phrase to `audit.clear`. The wrong row dilutes `audit.clear`'s candidate set, so the
    /// correct tool's full match out-scores it. A classifier a wrong seed can hijack is the
    /// failure this table exists to refuse.
    func testAPlantedWrongSynonymDoesNotResolveToTheWrongTool() throws {
        let planted = KeywordIntentResolver(synonyms: [
            KeywordSynonym(phrase: "clear the audit log", providerID: "dev.vocca.audit", toolID: "audit.clear"),
            KeywordSynonym(phrase: "count the audit log", providerID: "dev.vocca.audit", toolID: "audit.count"),
            KeywordSynonym(phrase: "count the audit log", providerID: "dev.vocca.audit", toolID: "audit.clear"),
        ])
        let catalog = [Self.auditClear, Self.auditCount]

        XCTAssertEqual(
            planted.resolve("count the audit log", against: catalog),
            .toolCall(try makeInvocation(providerID: "dev.vocca.audit", toolID: "audit.count")),
            "a wrong synonym planted on audit.clear must not steal the count phrase")
        XCTAssertEqual(
            planted.resolve("clear the audit log", against: catalog),
            .toolCall(try makeInvocation(providerID: "dev.vocca.audit", toolID: "audit.clear")),
            "and the clear phrase must stay on audit.clear")
    }

    /// The reverse planted row, for the same reason in the other direction.
    func testAPlantedWrongSynonymInTheOtherDirectionStillLoses() throws {
        let planted = KeywordIntentResolver(synonyms: [
            KeywordSynonym(phrase: "clear the audit log", providerID: "dev.vocca.audit", toolID: "audit.clear"),
            KeywordSynonym(phrase: "count the audit log", providerID: "dev.vocca.audit", toolID: "audit.count"),
            KeywordSynonym(phrase: "clear the audit log", providerID: "dev.vocca.audit", toolID: "audit.count"),
        ])
        let catalog = [Self.auditClear, Self.auditCount]

        XCTAssertEqual(
            planted.resolve("clear the audit log", against: catalog),
            .toolCall(try makeInvocation(providerID: "dev.vocca.audit", toolID: "audit.clear")))
        XCTAssertEqual(
            planted.resolve("count the audit log", against: catalog),
            .toolCall(try makeInvocation(providerID: "dev.vocca.audit", toolID: "audit.count")))
    }

    /// The resolver never resolves to a tool the catalog does not contain — the seeded phrase
    /// targets `audit.clear`, but a catalog holding only the message tool matches nothing at all.
    func testItNeverResolvesToAToolTheCatalogDoesNotContain() {
        let resolver = KeywordIntentResolver()

        XCTAssertEqual(resolver.resolve("clear the audit log", against: [Self.postMessage]), .none)
    }

    // MARK: - The deterministic tiebreak

    /// Two tools with identical display names both match "clear the audit log" at the same score
    /// above the threshold — the resolution is deterministic, the lexically-first provider wins.
    func testAnEqualTopScoreResolvesDeterministically() throws {
        let resolver = KeywordIntentResolver()
        let later = ToolReference(
            providerID: "dev.vocca.b", toolID: "tool", displayName: "Clear the audit log")
        let earlier = ToolReference(
            providerID: "dev.vocca.a", toolID: "tool", displayName: "Clear the audit log")
        let catalog = [later, earlier]

        XCTAssertEqual(
            resolver.resolve("clear the audit log", against: catalog),
            .toolCall(try makeInvocation(providerID: "dev.vocca.a", toolID: "tool")),
            "the tiebreak is (score, then providerID, then toolID) — deterministic by construction")
    }

    // MARK: - The arguments bound

    /// An invocation whose arguments text would exceed ``ActionInvocation/maximumArgumentsUTF8Bytes``
    /// is **refused, never truncated** — the difference `ActionInvocation` itself pins: truncated
    /// arguments are a different action, silently. Inside the bound the full text is carried.
    func testAnInvocationWhoseArgumentsWouldExceedTheBoundIsRefusedNeverTruncated() throws {
        let resolver = KeywordIntentResolver()
        let catalog = [Self.postMessage]

        let under = "post a message " + String(repeating: "x", count: 3000)
        XCTAssertLessThan(under.utf8.count, ActionInvocation.maximumArgumentsUTF8Bytes)
        let expectedUnder = try makeInvocation(
            providerID: "dev.vocca.mcp.chat", toolID: "post_message",
            arguments: "{\"text\": \"\(under)\"}")
        XCTAssertEqual(resolver.resolve(under, against: catalog), .toolCall(expectedUnder))

        let over = "post a message " + String(repeating: "x", count: 10_000)
        XCTAssertGreaterThan(over.utf8.count, ActionInvocation.maximumArgumentsUTF8Bytes)
        let resolution = resolver.resolve(over, against: catalog)
        if case .toolCall(let invocation) = resolution {
            XCTFail(
                "a resolution over the arguments bound must be refused, never truncated — got a "
                    + "toolCall carrying \(invocation.arguments?.utf8.count ?? 0) bytes of arguments")
        }
    }

    // MARK: - The seeded defaults are the shipped defaults

    /// A resolver built without arguments uses the shipped table and the seeded threshold —
    /// the explicit spelling resolves identically, so the shipped configuration is the seed.
    func testTheDefaultResolverUsesTheShippedTableAndThreshold() {
        let defaulted = KeywordIntentResolver()
        let explicit = KeywordIntentResolver(
            synonyms: KeywordIntentResolver.shippedSynonyms,
            threshold: KeywordIntentResolver.notConfidentThreshold)
        let catalog = [Self.auditClear, Self.auditCount, Self.postMessage]

        for utterance in [
            "clear the audit log", "count the audit log", "post a message", "the audit log",
            "good morning", "",
        ] {
            XCTAssertEqual(
                defaulted.resolve(utterance, against: catalog),
                explicit.resolve(utterance, against: catalog),
                "the default init must resolve '\(utterance)' exactly as the explicit seed does")
        }
    }
}