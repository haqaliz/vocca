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

import Synchronization
import VoccaCore
import XCTest

/// The composite resolver's contract (`composite-intent-resolver` PRD must-haves 1, 3, 4;
/// `resolver-chain` spec acceptances A1, A3, A4): phrase first, keyword second, the excluded
/// providers closed on both sides of the fallback.
///
/// The fallback is observed through ``SpyIntentResolver`` — it counts its calls and records
/// every catalog it received, so "never consulted" and "the excluded rows never reached it" are
/// claims about what the fallback actually saw, never about the composite's intentions. The
/// excluded provider is spelled as a literal here: `VoccaCore` cannot name `ShellProvider`, so
/// the caller supplies the identifier and so does this suite.
final class CompositeIntentResolverTests: XCTestCase {

    private static let shellProviderID = "dev.vocca.shell"

    private static let auditClear = ToolReference(
        providerID: "dev.vocca.audit", toolID: "audit.clear",
        displayName: "Clear the audit log")
    private static let auditCount = ToolReference(
        providerID: "dev.vocca.audit", toolID: "audit.count",
        displayName: "Count the audit log")
    private static let logViewer = ToolReference(
        providerID: "dev.vocca.logs", toolID: "open_log", displayName: "Open the log viewer")
    private static let shellCommand = ToolReference(
        providerID: shellProviderID, toolID: "empty-downloads", displayName: "Empty downloads")

    private func makeInvocation(providerID: String, toolID: String) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(providerID: providerID, toolID: toolID, arguments: nil),
            "expected a constructible ActionInvocation")
    }

    private func composite(
        primary: any IntentResolver, fallback: any IntentResolver,
        excluded: Set<String> = [shellProviderID]
    ) -> CompositeIntentResolver {
        CompositeIntentResolver(
            primary: primary, fallback: fallback, excludedProviderIDs: excluded)
    }

    // MARK: - A1 — a phrase hit short-circuits

    /// A phrase hit returns the phrase resolver's call, and the fallback is never consulted —
    /// spy count 0, no catalog recorded.
    func testAPhraseHitShortCircuitsAndNeverConsultsTheFallback() throws {
        let fallback = SpyIntentResolver(returning: .none)
        let resolver = composite(
            primary: PhraseIntentResolver(rows: [
                PhraseIntentRow(
                    phrase: "wipe the log", providerID: "dev.vocca.audit", toolID: "audit.clear")
            ]),
            fallback: fallback)

        XCTAssertEqual(
            resolver.resolve("wipe the log", against: [Self.auditClear, Self.auditCount]),
            .toolCall(try makeInvocation(providerID: "dev.vocca.audit", toolID: "audit.clear")))
        XCTAssertEqual(fallback.callCount, 0, "a phrase hit must never consult the fallback")
        XCTAssertTrue(fallback.catalogs.isEmpty)
    }

    /// A primary `.toolCall` is returned unchanged — even one the fallback would contradict.
    func testAPrimaryToolCallIsReturnedUnchanged() throws {
        let call = try makeInvocation(providerID: "dev.vocca.audit", toolID: "audit.count")
        let fallback = SpyIntentResolver(
            returning: .toolCall(
                try makeInvocation(providerID: "dev.vocca.audit", toolID: "audit.clear")))
        let resolver = composite(primary: StubIntentResolver(.toolCall(call)), fallback: fallback)

        XCTAssertEqual(resolver.resolve("anything", against: [Self.auditCount]), .toolCall(call))
        XCTAssertEqual(fallback.callCount, 0)
    }

    /// A primary `.ask` passes through as-is (the phrase leg never asks, but the composite does
    /// not rewrite a resolution it did not produce), and the fallback is not consulted.
    func testAPrimaryAskPassesThroughWithoutConsultingTheFallback() {
        let fallback = SpyIntentResolver(returning: .none)
        let resolver = composite(
            primary: StubIntentResolver(.ask(question: "Did you mean 'X'?")), fallback: fallback)

        XCTAssertEqual(
            resolver.resolve("anything", against: [Self.auditCount]),
            .ask(question: "Did you mean 'X'?"))
        XCTAssertEqual(fallback.callCount, 0)
    }

    /// Phrase `.none` falls through to the fallback, whose answer is the composite's.
    func testAPhraseMissFallsThroughToTheFallback() throws {
        let call = try makeInvocation(providerID: "dev.vocca.audit", toolID: "audit.count")
        let fallback = SpyIntentResolver(returning: .toolCall(call))
        let resolver = composite(primary: PhraseIntentResolver(rows: []), fallback: fallback)

        XCTAssertEqual(
            resolver.resolve("count the audit log", against: [Self.auditCount]), .toolCall(call))
        XCTAssertEqual(fallback.callCount, 1)
    }

    // MARK: - A3 — below the threshold the composite only asks

    /// The real keyword resolver behind a missing phrase: a below-threshold utterance stays an
    /// `.ask` naming at most three candidates — nothing resolves to a call.
    func testABelowThresholdKeywordResultStaysAnAskWithAtMostThreeCandidates() {
        let resolver = composite(
            primary: PhraseIntentResolver(rows: [
                PhraseIntentRow(
                    phrase: "wipe the log", providerID: "dev.vocca.audit", toolID: "audit.clear")
            ]),
            fallback: KeywordIntentResolver())
        let catalog = [Self.auditClear, Self.auditCount, Self.logViewer]

        let resolution = resolver.resolve("the log", against: catalog)

        XCTAssertEqual(
            resolution,
            .ask(
                question: "Did you mean 'Clear the audit log', 'Count the audit log' or "
                    + "'Open the log viewer'?"))
        guard case .ask(let question) = resolution else {
            return XCTFail("expected an ask, got \(resolution)")
        }
        XCTAssertLessThanOrEqual(
            question.filter { $0 == "'" }.count / 2, 3, "the ask names at most three candidates")
    }

    // MARK: - A4 — an excluded provider never resolves (each half on its own)

    /// The filter half: the fallback never *sees* an excluded row. The spy returns `.none`, so
    /// the discard half cannot be what passes this test.
    func testTheFallbackNeverReceivesAnExcludedProviderRow() {
        let fallback = SpyIntentResolver(returning: .none)
        let resolver = composite(primary: PhraseIntentResolver(rows: []), fallback: fallback)

        _ = resolver.resolve(
            "empty my downloads", against: [Self.auditCount, Self.shellCommand, Self.auditClear])

        XCTAssertEqual(fallback.catalogs, [[Self.auditCount, Self.auditClear]])
    }

    /// The discard half: a fallback that ignores its catalog and names an excluded provider is
    /// overruled to `.none`. The stub never reads the catalog, so the filter half cannot be what
    /// passes this test.
    func testAFallbackToolCallNamingAnExcludedProviderIsDiscarded() throws {
        let shellCall = try makeInvocation(
            providerID: Self.shellProviderID, toolID: "empty-downloads")
        let resolver = composite(
            primary: PhraseIntentResolver(rows: []),
            fallback: StubIntentResolver(.toolCall(shellCall)))

        XCTAssertEqual(
            resolver.resolve("empty my downloads", against: [Self.shellCommand]), .none)
    }

    /// The discard half's counterfactual: with nothing excluded the same stub's call goes
    /// through — so the test above fails for the reason it names, not because the stub is inert.
    func testTheDiscardCounterfactualPassesTheCallWhenNothingIsExcluded() throws {
        let shellCall = try makeInvocation(
            providerID: Self.shellProviderID, toolID: "empty-downloads")
        let resolver = composite(
            primary: PhraseIntentResolver(rows: []),
            fallback: StubIntentResolver(.toolCall(shellCall)), excluded: [])

        XCTAssertEqual(
            resolver.resolve("empty my downloads", against: [Self.shellCommand]),
            .toolCall(shellCall))
    }

    /// Both halves together over the real keyword resolver seeded with a shell synonym: an
    /// enabled shell row in the catalog never resolves.
    func testAnEnabledShellRowNeverResolvesThroughTheRealKeywordResolver() {
        let keyword = KeywordIntentResolver(synonyms: [
            KeywordSynonym(
                phrase: "empty my downloads", providerID: Self.shellProviderID,
                toolID: "empty-downloads")
        ])
        let resolver = composite(primary: PhraseIntentResolver(rows: []), fallback: keyword)

        XCTAssertEqual(
            resolver.resolve("empty my downloads", against: [Self.shellCommand]), .none)
    }

    // MARK: - Edges

    /// An empty catalog resolves to nothing through the real legs.
    func testAnEmptyCatalogResolvesNone() {
        let resolver = composite(
            primary: PhraseIntentResolver(rows: [
                PhraseIntentRow(
                    phrase: "clear the audit log", providerID: "dev.vocca.audit",
                    toolID: "audit.clear")
            ]),
            fallback: KeywordIntentResolver())

        XCTAssertEqual(resolver.resolve("clear the audit log", against: []), .none)
    }

    /// Deterministic: the same utterance and catalog resolve identically every time, read
    /// through the existential (the seam's `Sendable` conformance).
    func testResolutionIsDeterministicThroughTheExistential() {
        let resolver: any IntentResolver = composite(
            primary: PhraseIntentResolver(rows: []), fallback: KeywordIntentResolver())
        let catalog = [Self.auditClear, Self.auditCount, Self.shellCommand]

        for utterance in ["clear the audit log", "the audit log", "empty my downloads", ""] {
            let first = resolver.resolve(utterance, against: catalog)
            for _ in 0..<5 {
                XCTAssertEqual(resolver.resolve(utterance, against: catalog), first, utterance)
            }
        }
    }
}

// MARK: - The doubles

/// A resolver that returns one fixed resolution and never reads its catalog.
private struct StubIntentResolver: IntentResolver {
    let resolution: IntentResolution

    init(_ resolution: IntentResolution) { self.resolution = resolution }

    func resolve(_ utterance: String, against catalog: [ToolReference]) -> IntentResolution {
        resolution
    }
}

/// A fixed-answer resolver that counts its calls and records every catalog it received —
/// `Sendable` by a `Mutex`, the `CallCounter` shape (`PhraseIntentWiringTests`).
private final class SpyIntentResolver: IntentResolver, Sendable {
    private let resolution: IntentResolution
    private let received = Mutex<[[ToolReference]]>([])

    init(returning resolution: IntentResolution) { self.resolution = resolution }

    var callCount: Int { received.withLock { $0.count } }

    var catalogs: [[ToolReference]] { received.withLock { $0 } }

    func resolve(_ utterance: String, against catalog: [ToolReference]) -> IntentResolution {
        received.withLock { $0.append(catalog) }
        return resolution
    }
}
