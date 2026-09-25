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

/// The intent seam's contract (`intent-layer` PRD R1, `intent-seam` spec acceptance 1-5): the
/// `IntentResolver` protocol as code, the `IntentResolution` vocabulary, and both concrete
/// resolvers.
///
/// The ``ReplySeamTests`` shape applied to the new seam: everything is read through the
/// existential (`any IntentResolver`) so the seam — not a concrete type — is what a caller
/// speaks, both implementations exist as types named `KeywordIntentResolver` and
/// `NullIntentResolver`, and each acceptance is pinned against the resolver it belongs to:
/// acceptance 1-4 belong to the keyword resolver, acceptance 5 to the null resolver. The
/// contract tests are the RED for this aspect: written against the protocol and both resolvers
/// before the keyword resolver existed, they failed on behaviour (the resolver was a stub that
/// resolved nothing) rather than on a compile error.
final class IntentResolverContractTests: XCTestCase {

    /// The two shipped audit tools — the catalog the seeded phrases resolve against.
    private static let auditClear = ToolReference(
        providerID: "dev.vocca.audit", toolID: "audit.clear",
        displayName: "Clear the audit log")
    private static let auditCount = ToolReference(
        providerID: "dev.vocca.audit", toolID: "audit.count",
        displayName: "Count the audit log")

    /// The args-carrying MCP-style tool the seeded "post a message" phrase targets.
    private static let postMessage = ToolReference(
        providerID: "dev.vocca.mcp.chat", toolID: "post_message",
        displayName: "Post a message")

    /// Reads the seam through the existential — the only shape a caller may use.
    private func requireResolver(_ resolver: any IntentResolver) -> any IntentResolver {
        resolver
    }

    /// Makes the `Sendable` conformance a compile obligation — the house's aversion to
    /// `@unchecked Sendable` is structural (`ReplySeamTests`).
    private func requireSendable<T: Sendable>(_ value: T) -> T { value }

    private func makeInvocation(
        providerID: String, toolID: String, arguments: String? = nil
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(providerID: providerID, toolID: toolID, arguments: arguments),
            "expected a constructible ActionInvocation")
    }

    // MARK: - The seam's shape

    /// The seam exists as a `Sendable` protocol with exactly one requirement, and both
    /// implementations exist as types — the compile pin `ReplySeamTests` applies: if the shape
    /// is weakened or renamed, this stops compiling rather than coercing.
    func testTheSeamIsASendableProtocolWithOneResolveRequirement() {
        let keyword: any IntentResolver = requireSendable(
            requireResolver(KeywordIntentResolver()))
        let null: any IntentResolver = requireSendable(requireResolver(NullIntentResolver()))

        let keywordResult = keyword.resolve(
            "clear the audit log", against: [Self.auditClear, Self.auditCount])
        let nullResult = null.resolve(
            "clear the audit log", against: [Self.auditClear, Self.auditCount])

        if case .toolCall(let invocation) = keywordResult {
            XCTAssertEqual(invocation.providerID, "dev.vocca.audit")
            XCTAssertEqual(invocation.toolID, "audit.clear")
        } else {
            XCTFail(
                "a seeded phrase must resolve to a tool call, got \(keywordResult) — the "
                    + "keyword resolver's contract is acceptance 1")
        }
        XCTAssertEqual(nullResult, .none, "the null resolver's contract is acceptance 5")
    }

    // MARK: - Acceptance 1 — a matched utterance resolves to a tool call

    /// The first seeded row: "clear the audit log" resolves to the exact invocation, with no
    /// arguments (the audit tools carry none — `nil` for a no-arg tool).
    func testAMatchedUtteranceResolvesToTheClearTool() throws {
        let resolver: any IntentResolver = requireSendable(
            requireResolver(KeywordIntentResolver()))
        let expected = try makeInvocation(
            providerID: "dev.vocca.audit", toolID: "audit.clear")

        XCTAssertEqual(
            resolver.resolve("clear the audit log", against: [Self.auditClear, Self.auditCount]),
            .toolCall(expected))
    }

    /// The second seeded row: "count the audit log" resolves to `audit.count`, not `audit.clear`.
    func testTheCountPhraseResolvesToTheCountTool() throws {
        let resolver: any IntentResolver = requireSendable(
            requireResolver(KeywordIntentResolver()))
        let expected = try makeInvocation(
            providerID: "dev.vocca.audit", toolID: "audit.count")

        XCTAssertEqual(
            resolver.resolve("count the audit log", against: [Self.auditClear, Self.auditCount]),
            .toolCall(expected))
    }

    /// A matched utterance carries the seeded **arguments text** — the invocation is the full
    /// `providerID`/`toolID`/`arguments` triple, asserted by equality so a wrong argument text
    /// fails loudly.
    func testAMatchedUtteranceCarriesTheSeededArgumentsText() throws {
        let resolver: any IntentResolver = requireSendable(
            requireResolver(KeywordIntentResolver()))
        let expected = try makeInvocation(
            providerID: "dev.vocca.mcp.chat", toolID: "post_message",
            arguments: #"{"text": "post a message"}"#)

        XCTAssertEqual(
            resolver.resolve("post a message", against: [Self.postMessage]),
            .toolCall(expected))
    }

    // MARK: - Acceptance 2 — below the threshold, the resolver asks

    /// "the audit log" matches both audit tools at the same score, which is below the seeded
    /// not-confident threshold — the resolution is `.ask`, naming both candidates from the
    /// resolver's own ranking in its deterministic (score, then lexical) order.
    func testAnUtteranceBelowTheThresholdAsksNamingCandidatesInOrder() {
        let resolver: any IntentResolver = requireSendable(
            requireResolver(KeywordIntentResolver()))

        XCTAssertEqual(
            resolver.resolve("the audit log", against: [Self.auditClear, Self.auditCount]),
            .ask(question: "Did you mean 'Clear the audit log' or 'Count the audit log'?"))
    }

    // MARK: - Acceptance 3 — nothing matched, nothing resolved

    /// An utterance sharing no token with any tool in the catalog resolves `.none`.
    func testAnUtteranceMatchingNothingResolvesNone() {
        let resolver: any IntentResolver = requireSendable(
            requireResolver(KeywordIntentResolver()))

        XCTAssertEqual(
            resolver.resolve("good morning", against: [Self.auditClear, Self.auditCount]),
            .none)
    }

    /// Empty and whitespace-only utterances resolve `.none` — nothing to match is not an ask and
    /// not a guess.
    func testEmptyAndWhitespaceUtterancesResolveNone() {
        let resolver: any IntentResolver = requireSendable(
            requireResolver(KeywordIntentResolver()))
        let catalog = [Self.auditClear, Self.auditCount]

        XCTAssertEqual(resolver.resolve("", against: catalog), .none)
        XCTAssertEqual(resolver.resolve("   ", against: catalog), .none)
        XCTAssertEqual(resolver.resolve("\n\t  ", against: catalog), .none)
    }

    // MARK: - Acceptance 4 — the resolver never invents a tool

    /// The seeded phrase "clear the audit log" targets `audit.clear`, but the catalog here holds
    /// only `audit.count` — the resolver must not resolve to a tool the caller never supplied. A
    /// `.toolCall` naming any tool outside the catalog is the failure this pins.
    func testTheResolverNeverInventsAToolOutsideTheCatalog() {
        let resolver: any IntentResolver = requireSendable(
            requireResolver(KeywordIntentResolver()))
        let catalogWithoutClear = [Self.auditCount]

        let resolution = resolver.resolve("clear the audit log", against: catalogWithoutClear)
        if case .toolCall(let invocation) = resolution {
            XCTFail(
                "resolved a tool the catalog never supplied: "
                    + "\(invocation.providerID)/\(invocation.toolID). The resolver may only "
                    + "resolve to what the caller's enablement catalog names (R3).")
        }
    }

    // MARK: - Acceptance 5 — the null resolver

    /// `NullIntentResolver` resolves `.none` for every utterance, even the seeded phrases and a
    /// non-empty catalog — the composed default that never acts (R7).
    func testNullIntentResolverResolvesNoneForEveryUtterance() {
        let resolver: any IntentResolver = requireSendable(
            requireResolver(NullIntentResolver()))
        let catalog = [Self.auditClear, Self.auditCount]

        for utterance in ["clear the audit log", "count the audit log", "good morning", "", "   "] {
            XCTAssertEqual(
                resolver.resolve(utterance, against: catalog), .none,
                "the null resolver must resolve '\(utterance)' to .none")
        }
    }

    // MARK: - Determinism

    /// Both resolvers are deterministic: the same utterance against the same catalog resolves the
    /// same way twice — the property the ask path's "deterministic order" and the seeded
    /// threshold's repeatability stand on.
    func testBothResolversAreDeterministic() {
        let keyword: any IntentResolver = requireSendable(
            requireResolver(KeywordIntentResolver()))
        let null: any IntentResolver = requireSendable(requireResolver(NullIntentResolver()))
        let catalog = [Self.auditClear, Self.auditCount, Self.postMessage]
        let utterances = ["clear the audit log", "the audit log", "good morning", "post a message"]

        let phrase: any IntentResolver = requireSendable(
            requireResolver(
                PhraseIntentResolver(rows: [
                    PhraseIntentRow(
                        phrase: "clear the audit log", providerID: "dev.vocca.audit",
                        toolID: "audit.clear")
                ])))

        for utterance in utterances {
            XCTAssertEqual(
                keyword.resolve(utterance, against: catalog),
                keyword.resolve(utterance, against: catalog))
            XCTAssertEqual(
                null.resolve(utterance, against: catalog),
                null.resolve(utterance, against: catalog))
            XCTAssertEqual(
                phrase.resolve(utterance, against: catalog),
                phrase.resolve(utterance, against: catalog))
        }
    }

    // MARK: - The second real classifier (`phrase-intent-resolver`)

    /// `PhraseIntentResolver` is a `Sendable` conformance read through the existential, and it
    /// holds the seam's shared promises: a matched phrase resolves to the catalog tool it
    /// names, and it never invents a tool outside the catalog (acceptance 4's row).
    func testThePhraseResolverHoldsTheSeamsSharedContract() throws {
        let resolver: any IntentResolver = requireSendable(
            requireResolver(
                PhraseIntentResolver(rows: [
                    PhraseIntentRow(
                        phrase: "clear the audit log", providerID: "dev.vocca.audit",
                        toolID: "audit.clear"),
                    PhraseIntentRow(
                        phrase: "post a message", providerID: "dev.vocca.mcp.chat",
                        toolID: "post_message"),
                ])))

        XCTAssertEqual(
            resolver.resolve("clear the audit log", against: [Self.auditClear, Self.auditCount]),
            .toolCall(try makeInvocation(providerID: "dev.vocca.audit", toolID: "audit.clear")))
        XCTAssertEqual(
            resolver.resolve("post a message", against: [Self.auditClear, Self.auditCount]),
            .none, "a row whose tool is outside the catalog must never resolve")
        XCTAssertEqual(resolver.resolve("", against: [Self.auditClear]), .none)
    }
}