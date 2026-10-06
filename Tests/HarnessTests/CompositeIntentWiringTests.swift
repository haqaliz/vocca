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
import VoccaActions
import VoccaBootstrap
import VoccaCore
import XCTest

/// **The composed per-turn provider honors the switch** (`composite-intent-resolver`
/// `resolver-chain` spec acceptance A6): the composition root's own recipe —
/// ``AppBootstrap/composeIntentResolver(file:)`` and the per-turn
/// ``AppBootstrap/composeIntentResolverProvider(store:)`` that `configure` wires — driven
/// without the full root.
///
/// Switch off is today's composed default, byte for byte in shape: a bare
/// `PhraseIntentResolver`, the composite **not on the path** (the dynamic type is pinned).
/// Switch on is the chain — phrase first, keyword second, the shell provider closed.
@MainActor
final class CompositeIntentWiringTests: XCTestCase {

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-composite-wiring-\(UUID().uuidString)")
    }

    /// A shell row whose id and display-name tokens the utterance below matches exactly — the
    /// keyword resolver alone resolves it (the counterfactual), so only the exclusion closes it.
    private static let shellRow = ToolReference(
        providerID: ShellProvider.providerID, toolID: "empty-downloads",
        displayName: "empty downloads")
    private static let shellUtterance = "empty downloads"

    /// An enabled coding-agent row whose id and display-name tokens the utterance below matches
    /// exactly — the keyword resolver alone resolves it, so only the exclusion closes it.
    private static let agentRow = ToolReference(
        providerID: CodingAgentProvider.providerID, toolID: "claude-review",
        displayName: "claude review")
    private static let agentUtterance = "claude review"

    // MARK: - A6 — the switch picks the type

    /// Switch off: the composed resolver is exactly a `PhraseIntentResolver` — the composite is
    /// not on the path.
    func testSwitchOffComposesABarePhraseResolver() {
        let resolver = AppBootstrap.composeIntentResolver(
            file: IntentPhraseFile(phrases: [], keywordFallback: false))

        XCTAssertTrue(
            type(of: resolver) == PhraseIntentResolver.self,
            "switch off must compose a bare PhraseIntentResolver, got \(type(of: resolver))")
    }

    /// Switch on: the composed resolver is the chain, phrase primary and keyword fallback, with
    /// the shell **and** coding-agent providers excluded — exactly those two, no more.
    func testSwitchOnComposesTheCompositeWithShellAndAgentProvidersExcluded() throws {
        let resolver = AppBootstrap.composeIntentResolver(
            file: IntentPhraseFile(phrases: [], keywordFallback: true))

        let composite = try XCTUnwrap(
            resolver as? CompositeIntentResolver,
            "switch on must compose a CompositeIntentResolver, got \(type(of: resolver))")
        XCTAssertTrue(type(of: composite.primary) == PhraseIntentResolver.self)
        XCTAssertTrue(type(of: composite.fallback) == KeywordIntentResolver.self)
        XCTAssertEqual(
            composite.excludedProviderIDs,
            [ShellProvider.providerID, CodingAgentProvider.providerID])
    }

    // MARK: - A6 — the shell leg stays closed with the switch on

    /// The composed resolver with the switch on never resolves to an enabled shell tool, even
    /// for an utterance that is the shell row's own tokens — while the keyword resolver alone
    /// would (the counterfactual that keeps the assertion from passing vacuously).
    func testSwitchOnNeverResolvesToAnEnabledShellTool() {
        let catalog = [Self.shellRow]

        let bare = KeywordIntentResolver().resolve(Self.shellUtterance, against: catalog)
        guard case .toolCall(let reached) = bare else {
            return XCTFail("counterfactual: the keyword resolver alone must reach the shell row")
        }
        XCTAssertEqual(reached.providerID, ShellProvider.providerID)
        XCTAssertEqual(reached.toolID, Self.shellRow.toolID)

        let composed = AppBootstrap.composeIntentResolver(
            file: IntentPhraseFile(phrases: [], keywordFallback: true))
        let resolution = composed.resolve(Self.shellUtterance, against: catalog)

        if case .toolCall(let invocation) = resolution {
            XCTAssertNotEqual(
                invocation.providerID, ShellProvider.providerID,
                "a shell tool must never be reachable through the keyword fallback")
        }
        XCTAssertEqual(resolution, IntentResolution.none)
    }

    // MARK: - The coding-agent leg stays closed to the keyword fallback

    /// The composed resolver with the switch on never selects an enabled coding agent by
    /// keyword, even for an utterance that is the agent row's own tokens — while the keyword
    /// resolver alone would (the counterfactual). A child-spawning, egress-unprovable provider
    /// is reachable only by an explicitly authored phrase row.
    func testSwitchOnNeverResolvesToAnEnabledCodingAgentByKeyword() {
        let catalog = [Self.agentRow]

        let bare = KeywordIntentResolver().resolve(Self.agentUtterance, against: catalog)
        guard case .toolCall(let reached) = bare else {
            return XCTFail("counterfactual: the keyword resolver alone must reach the agent row")
        }
        XCTAssertEqual(reached.providerID, CodingAgentProvider.providerID)
        XCTAssertEqual(reached.toolID, Self.agentRow.toolID)

        let composed = AppBootstrap.composeIntentResolver(
            file: IntentPhraseFile(phrases: [], keywordFallback: true))
        let resolution = composed.resolve(Self.agentUtterance, against: catalog)

        if case .toolCall(let invocation) = resolution {
            XCTAssertNotEqual(
                invocation.providerID, CodingAgentProvider.providerID,
                "a coding agent must never be reachable through the keyword fallback")
        }
        XCTAssertEqual(resolution, IntentResolution.none)
    }

    /// A phrase row naming `vocca.agent` still resolves with the switch on: the exclusion closes
    /// the keyword leg only — the phrase leg is the user's explicit authoring.
    func testSwitchOnStillResolvesAPhraseRowNamingACodingAgent() {
        let catalog = [Self.agentRow]
        let composed = AppBootstrap.composeIntentResolver(
            file: IntentPhraseFile(
                phrases: [
                    PhraseIntentRow(
                        phrase: "review my branch", providerID: CodingAgentProvider.providerID,
                        toolID: Self.agentRow.toolID)
                ],
                keywordFallback: true))

        guard case .toolCall(let invocation) = composed.resolve(
            "review my branch", against: catalog)
        else {
            return XCTFail("a phrase row naming a coding agent must still resolve")
        }
        XCTAssertEqual(invocation.providerID, CodingAgentProvider.providerID)
        XCTAssertEqual(invocation.toolID, Self.agentRow.toolID)
    }

    // MARK: - A6 — re-read per turn

    /// The provider reads the file each turn: flipping the switch between two calls of the
    /// **same** provider changes the composed type, with no recomposition.
    func testTheProviderReReadsTheSwitchEachTurnWithoutRecomposing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IntentPhraseStore(directory: directory, log: { _ in })
        let provider = AppBootstrap.composeIntentResolverProvider(store: store)

        let absent = await provider()
        XCTAssertTrue(
            type(of: absent) == PhraseIntentResolver.self,
            "an absent file is switch off — got \(type(of: absent))")

        try await store.save(IntentPhraseFile(phrases: [], keywordFallback: true))
        let on = await provider()
        XCTAssertTrue(
            type(of: on) == CompositeIntentResolver.self,
            "the flipped switch must take effect on the next turn — got \(type(of: on))")

        try await store.save(IntentPhraseFile(phrases: [], keywordFallback: false))
        let off = await provider()
        XCTAssertTrue(
            type(of: off) == PhraseIntentResolver.self,
            "flipping back must take effect on the next turn — got \(type(of: off))")
    }
}
