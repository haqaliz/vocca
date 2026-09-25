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

/// The phrase resolver's contract (`phrase-intent-resolver` PRD R1-R2; `phrase-resolver` spec
/// acceptance 1-9): the second real ``IntentResolver`` — an exact, normalized phrase table.
///
/// Everything is read through the existential, the ``IntentResolverContractTests`` shape. The
/// resolver's one behavioural promise is narrower than the keyword resolver's on purpose: a
/// phrase either equals the utterance after normalization and names a catalog tool, or the
/// resolution is `.none`. There is no confidence gradient, so there is no ask — brittleness
/// fails to *nothing*, never to a wrong tool.
final class PhraseIntentResolverTests: XCTestCase {

    private static let auditClear = ToolReference(
        providerID: "dev.vocca.audit", toolID: "audit.clear", displayName: "")
    private static let auditCount = ToolReference(
        providerID: "dev.vocca.audit", toolID: "audit.count", displayName: "")

    private static let clearRow = PhraseIntentRow(
        phrase: "clear the audit log", providerID: "dev.vocca.audit", toolID: "audit.clear")
    private static let countRow = PhraseIntentRow(
        phrase: "how big is the log", providerID: "dev.vocca.audit", toolID: "audit.count")

    private func resolver(_ rows: [PhraseIntentRow]) -> any IntentResolver {
        PhraseIntentResolver(rows: rows)
    }

    private func invocation(_ providerID: String, _ toolID: String) throws -> ActionInvocation {
        try XCTUnwrap(ActionInvocation(providerID: providerID, toolID: toolID, arguments: nil))
    }

    // MARK: - Acceptance 1 — an exact phrase resolves

    /// A phrase that equals the utterance and names a catalog tool resolves to that tool, with
    /// no arguments — phrase rows carry none (PRD R1).
    func testAnExactPhraseForACatalogToolResolvesToAToolCallWithNoArguments() throws {
        let sut = resolver([Self.clearRow, Self.countRow])

        XCTAssertEqual(
            sut.resolve("how big is the log", against: [Self.auditClear, Self.auditCount]),
            .toolCall(try invocation("dev.vocca.audit", "audit.count")))
    }

    // MARK: - Acceptance 2 — normalization

    /// Case, punctuation and whitespace are folded on both sides: what cleanup adds (a
    /// capital, a full stop) or ASR splits (a hyphen) never costs a match.
    func testNormalizationFoldsCasePunctuationAndWhitespace() throws {
        let sut = resolver([Self.clearRow])
        let expected = IntentResolution.toolCall(try invocation("dev.vocca.audit", "audit.clear"))

        for utterance in ["Clear the audit log.", "  clear   THE audit-log ", "CLEAR the audit, log!"] {
            XCTAssertEqual(
                sut.resolve(utterance, against: [Self.auditClear]), expected,
                "'\(utterance)' must normalize to the row's phrase")
        }
    }

    /// A near miss is not a match: a dropped word is a different phrase, and the answer is
    /// nothing rather than a guess.
    func testANearMissResolvesNone() {
        let sut = resolver([Self.clearRow])

        XCTAssertEqual(sut.resolve("clear audit log", against: [Self.auditClear]), .none)
        XCTAssertEqual(
            sut.resolve("please clear the audit log", against: [Self.auditClear]), .none)
    }

    // MARK: - Acceptance 3-4 — the catalog is the enablement

    /// A row whose target is not in the caller's catalog is inert: the resolver never invents
    /// a tool the catalog does not name (the seam's R3).
    func testARowTargetingAToolOutsideTheCatalogIsInert() {
        let sut = resolver([Self.clearRow])

        XCTAssertEqual(sut.resolve("clear the audit log", against: [Self.auditCount]), .none)
    }

    /// With nothing enabled, nothing resolves — every phrase is inert.
    func testAnEmptyCatalogResolvesNoneForEveryUtterance() {
        let sut = resolver([Self.clearRow, Self.countRow])

        for utterance in ["clear the audit log", "how big is the log", "good morning"] {
            XCTAssertEqual(sut.resolve(utterance, against: []), .none)
        }
    }

    // MARK: - Acceptance 5 — table order

    /// Two rows with the same normalized phrase, both targets enabled: the first row in table
    /// order wins, so the answer never depends on anything but the file's own order.
    func testTheFirstRowInTableOrderWinsOnADuplicatePhrase() throws {
        let first = PhraseIntentRow(
            phrase: "the log", providerID: "dev.vocca.audit", toolID: "audit.count")
        let second = PhraseIntentRow(
            phrase: "The log!", providerID: "dev.vocca.audit", toolID: "audit.clear")
        let catalog = [Self.auditClear, Self.auditCount]

        XCTAssertEqual(
            resolver([first, second]).resolve("the log", against: catalog),
            .toolCall(try invocation("dev.vocca.audit", "audit.count")))
        XCTAssertEqual(
            resolver([second, first]).resolve("the log", against: catalog),
            .toolCall(try invocation("dev.vocca.audit", "audit.clear")))
    }

    // MARK: - Acceptance 6 — never asks

    /// An exact matcher has no confidence gradient, so it never asks: over matches, near
    /// misses and noise alike, no resolution is `.ask`.
    func testThePhraseResolverNeverAsks() {
        let sut = resolver([Self.clearRow, Self.countRow])
        let catalog = [Self.auditClear, Self.auditCount]
        let utterances = [
            "clear the audit log", "clear the audit", "audit", "log", "the log", "how big",
            "how big is the log", "how big is the log please", "count the audit log",
            "Clear.", "", " ", "?", "clear the audit log clear the audit log",
            "audit.clear", "dev.vocca.audit", "is the log big", "big log", "clear", "the",
        ]

        for utterance in utterances {
            if case .ask = sut.resolve(utterance, against: catalog) {
                XCTFail("the phrase resolver asked for '\(utterance)'")
            }
        }
    }

    // MARK: - Acceptance 7 — empty utterances

    /// Empty, whitespace-only and punctuation-only utterances normalize to nothing and resolve
    /// `.none` — even against a row whose phrase is itself only punctuation.
    func testEmptyWhitespaceAndPunctuationOnlyUtterancesResolveNone() {
        let punctuationRow = PhraseIntentRow(
            phrase: "...", providerID: "dev.vocca.audit", toolID: "audit.clear")
        let sut = resolver([punctuationRow, Self.clearRow])

        for utterance in ["", "   ", "\n\t", "...", "?!"] {
            XCTAssertEqual(sut.resolve(utterance, against: [Self.auditClear]), .none)
        }
    }

    // MARK: - Acceptance 8 — determinism

    /// The same utterance against the same catalog resolves the same way every time.
    func testThePhraseResolverIsDeterministic() {
        let sut = resolver([Self.clearRow, Self.countRow])
        let catalog = [Self.auditClear, Self.auditCount]
        let first = sut.resolve("Clear the audit log.", against: catalog)

        for _ in 0..<100 {
            XCTAssertEqual(sut.resolve("Clear the audit log.", against: catalog), first)
        }
    }

    // MARK: - The one normalization

    /// `normalized(_:)` is public and exact — the phrase store's duplicate and empty checks
    /// reuse it, so the store and the resolver cannot disagree about what a phrase is.
    func testNormalizedIsPublicAndStable() {
        XCTAssertEqual(PhraseIntentResolver.normalized("A--b  C!"), "a b c")
        XCTAssertEqual(PhraseIntentResolver.normalized("  Clear the audit-log. "), "clear the audit log")
        XCTAssertEqual(PhraseIntentResolver.normalized("!!!"), "")
        XCTAssertEqual(PhraseIntentResolver.normalized(""), "")
    }
}
