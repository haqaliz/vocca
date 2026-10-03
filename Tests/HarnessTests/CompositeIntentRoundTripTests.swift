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

/// **A keyword hit goes through the card and the audit** (`composite-intent-resolver`
/// `resolver-chain` spec acceptances A2, A3, A4): the composite resolver the composition root
/// builds — ``AppBootstrap/composeIntentResolver(file:)`` with the switch on — driven through
/// the `IntentRoundTripHarness`, the same intent recipe and action surface the shipped
/// configuration composes.
///
/// The composite changes **what resolves**, never what a resolution may do: a keyword
/// `.toolCall` is submitted withheld like a phrase hit, so an outward-facing tool reaches the
/// card and the acting half waits for a human yes; a read-only keyword hit auto-runs and is
/// audited `autoRanReadOnly` with no marker of its own (plan decision D1); a sub-threshold
/// keyword score is the spoken ask, which executes nothing; and an enabled shell tool is never
/// reached. Switch off is today's behavior — the same keyword-style utterance resolves nothing.
///
/// Each closing assertion carries its counterfactual where one exists (the bare keyword
/// resolver over the same catalog), so "never resolves" cannot pass for want of a match.
@MainActor
final class CompositeIntentRoundTripTests: XCTestCase {

    private static let auditProviderID = AuditActionProvider.providerID
    private static let clearToolID = AuditActionProvider.clearToolID
    private static let countToolID = "audit.count"

    /// A shell row whose id tokens overlap the audit vocabulary — the keyword resolver alone
    /// ranks it alongside (or above) the audit tools, so only the exclusion keeps it out.
    private static let shellToolID = "audit-log-wipe"

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-composite-round-trip-\(UUID().uuidString)")
    }

    /// The composition root's own recipe over a fixed file — the per-turn provider's body
    /// without the store.
    private static func composedProvider(
        keywordFallback: Bool
    ) -> @Sendable @MainActor () async -> any IntentResolver {
        {
            AppBootstrap.composeIntentResolver(
                file: IntentPhraseFile(phrases: [], keywordFallback: keywordFallback))
        }
    }

    private func toolCall(in resolution: IntentResolution) -> ActionInvocation? {
        if case .toolCall(let invocation) = resolution { return invocation }
        return nil
    }

    private func question(in resolution: IntentResolution) -> String? {
        if case .ask(let question) = resolution { return question }
        return nil
    }

    /// The candidate names an ask carries — each one is single-quoted by the resolver's copy.
    private func quotedNames(in question: String) -> Int {
        question.filter { $0 == "'" }.count / 2
    }

    // MARK: - A2 — a confident keyword hit reaches the card, withheld

    /// A phrase miss with a confident keyword hit on an enabled destructive tool: the card is
    /// presented, the acting half is untouched, the withheld stop is recorded — and only the
    /// existing confirm closure runs the tool, recorded `confirmed`.
    func testAKeywordHitOnAnOutwardFacingToolPresentsTheCardAndRunsOnlyOnConfirm() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .destructive)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore,
            resolverProvider: Self.composedProvider(keywordFallback: true))
        try await harness.surface.setToolEnabled(Self.auditProviderID, Self.clearToolID, true)

        // The phrase table is empty, so the hit is the keyword leg's.
        let resolution = await harness.wiring.resolve("clear the audit log")
        let invocation = try XCTUnwrap(
            toolCall(in: resolution), "the keyword fallback must resolve the phrase miss")
        XCTAssertEqual(
            invocation, ActionInvocation(providerID: Self.auditProviderID, toolID: Self.clearToolID))

        let reply = await harness.wiring.performAction(invocation, "clear the audit log")
        XCTAssertNil(reply, "the card is the answer — no spoken ack stands in for it")
        let card = try XCTUnwrap(
            harness.root.widgetStore.state.confirmation?.signal,
            "a keyword-resolved destructive call must reach the card")
        XCTAssertEqual(card.providerID, Self.auditProviderID)
        XCTAssertEqual(card.toolID, Self.clearToolID)
        XCTAssertEqual(
            provider.invokeCount, 0,
            "approval is withheld on the voice leg — the acting half waits for the human yes")
        let stopped = await harness.auditStore.load()
        XCTAssertEqual(
            stopped.map(\.decision), [.refused],
            "the withheld stop is recorded before any card is answered")

        await harness.surface.confirm()
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        XCTAssertEqual(provider.invokeCount, 1, "the confirm path is the only path that runs it")
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.map(\.decision), [.refused, .confirmed],
            "the human yes is recorded after the stop — the trail reconstructs")
        XCTAssertEqual(reloaded.last?.summary, card.sentence, "the card's sentence is the record")
    }

    /// The decline path over a keyword-presented card: both stops recorded, nothing invoked.
    func testAKeywordPresentedCardDeclinedRecordsTheRefusalAndNeverInvokes() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .outwardFacing)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore,
            resolverProvider: Self.composedProvider(keywordFallback: true))
        try await harness.surface.setToolEnabled(Self.auditProviderID, Self.clearToolID, true)

        let resolution = await harness.wiring.resolve("clear the audit log")
        let invocation = try XCTUnwrap(toolCall(in: resolution))
        _ = await harness.wiring.performAction(invocation, "clear the audit log")
        XCTAssertNotNil(
            harness.root.widgetStore.state.confirmation,
            "an outward-facing keyword hit must reach the card")

        await harness.surface.decline()
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.map(\.decision), [.refused, .refused],
            "the voice action's stop and the decline's stop, both recorded")
        XCTAssertEqual(provider.invokeCount, 0, "declining never reaches the acting half")
    }

    /// **D1, pinned**: a read-only keyword hit auto-runs, exactly as a phrase hit would, and is
    /// audited `autoRanReadOnly` — no card, and no marker distinguishing the keyword leg.
    func testAReadOnlyKeywordHitAutoRunsAndIsAuditedWithoutADistinctMarker() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.countToolID], describedRadius: .readOnly)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore,
            resolverProvider: Self.composedProvider(keywordFallback: true))
        try await harness.surface.setToolEnabled(Self.auditProviderID, Self.countToolID, true)

        let resolution = await harness.wiring.resolve("count the audit log")
        let invocation = try XCTUnwrap(toolCall(in: resolution))
        let reply = await harness.wiring.performAction(invocation, "count the audit log")

        XCTAssertEqual(reply, "Done.", "a read-only run speaks the outcome's ack")
        XCTAssertNil(harness.root.widgetStore.state.confirmation, "read-only needs no card")
        XCTAssertEqual(provider.invokeCount, 1)
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(reloaded.count, 1)
        let entry = try XCTUnwrap(reloaded.first)
        XCTAssertEqual(entry.decision, .autoRanReadOnly)
        XCTAssertEqual(entry.providerID, Self.auditProviderID)
        XCTAssertEqual(entry.toolID, Self.countToolID)
        XCTAssertEqual(
            entry.summary, "Stub would run \(Self.countToolID) on \(Self.auditProviderID).",
            "the record is the provider's own sentence — the keyword leg adds no marker (D1)")
    }

    // MARK: - A3 — a sub-threshold keyword score is the ask, and nothing executes

    /// Four enabled tools all partially matched: the composite returns the spoken ask naming at
    /// most three of them, and nothing is described, invoked or carded.
    func testABelowThresholdKeywordHitAsksNamingAtMostThreeAndExecutesNothing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let toolIDs = [Self.clearToolID, Self.countToolID, "audit.export", "audit.list"]
        let provider = RecordingActionProvider(toolIDs: toolIDs, describedRadius: .destructive)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore,
            resolverProvider: Self.composedProvider(keywordFallback: true))
        for toolID in toolIDs {
            try await harness.surface.setToolEnabled(Self.auditProviderID, toolID, true)
        }

        let resolution = await harness.wiring.resolve("audit log")
        let asked = try XCTUnwrap(
            question(in: resolution), "a sub-threshold score must ask, got \(resolution)")
        let names = quotedNames(in: asked)
        XCTAssertGreaterThan(names, 0, "the ask names the resolver's own candidates")
        XCTAssertLessThanOrEqual(names, 3, "the ask names at most three candidates: \(asked)")

        XCTAssertEqual(provider.describeCount, 0, "an ask describes nothing")
        XCTAssertEqual(provider.invokeCount, 0, "an ask executes nothing")
        XCTAssertNil(harness.root.widgetStore.state.confirmation, "an ask presents no card")
        let reloaded = await harness.auditStore.load()
        XCTAssertTrue(reloaded.isEmpty, "an ask submits nothing, so nothing is recorded")
    }

    // MARK: - A4 — an enabled shell tool never resolves

    /// An enabled `dev.vocca.shell` tool whose id tokens are the utterance: the bare keyword
    /// resolver reaches it through the same wiring (the counterfactual), the composite never
    /// does — no card, no description, no invocation.
    func testAnEnabledShellToolNeverResolvesThroughTheComposite() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: ["empty-downloads"], describedRadius: .destructive)

        let bare = IntentRoundTripHarness(
            directory: directory.appendingPathComponent("bare"), provider: provider,
            auditStore: auditStore, resolverProvider: { KeywordIntentResolver() })
        try await bare.surface.setToolEnabled(ShellProvider.providerID, "empty-downloads", true)
        let reached = await bare.wiring.resolve("empty downloads")
        XCTAssertEqual(
            toolCall(in: reached)?.providerID, ShellProvider.providerID,
            "counterfactual: the keyword resolver alone must reach the enabled shell row")

        let harness = IntentRoundTripHarness(
            directory: directory.appendingPathComponent("composite"), provider: provider,
            auditStore: auditStore,
            resolverProvider: Self.composedProvider(keywordFallback: true))
        try await harness.surface.setToolEnabled(
            ShellProvider.providerID, "empty-downloads", true)

        let resolution = await harness.wiring.resolve("empty downloads")
        XCTAssertEqual(resolution, .none, "a shell command must never be reachable by voice")
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        XCTAssertEqual(provider.describeCount, 0)
        XCTAssertEqual(provider.invokeCount, 0)
    }

    /// **The controller's ruling**: the real keyword resolver, through the composite, over a
    /// catalog holding a shell row whose id tokens overlap the utterances — the result never
    /// names the shell row, as a tool call, as an ask candidate, or anywhere in the ask text.
    /// Each utterance's counterfactual (the bare keyword resolver) does name it.
    func testTheCompositeNeverNamesTheShellRowInAToolCallOrAnAsk() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID, Self.shellToolID], describedRadius: .destructive)

        let bare = IntentRoundTripHarness(
            directory: directory.appendingPathComponent("bare"), provider: provider,
            auditStore: auditStore, resolverProvider: { KeywordIntentResolver() })
        let harness = IntentRoundTripHarness(
            directory: directory.appendingPathComponent("composite"), provider: provider,
            auditStore: auditStore,
            resolverProvider: Self.composedProvider(keywordFallback: true))
        for surface in [bare.surface, harness.surface] {
            try await surface.setToolEnabled(Self.auditProviderID, Self.clearToolID, true)
            try await surface.setToolEnabled(ShellProvider.providerID, Self.shellToolID, true)
        }

        func namesShell(_ resolution: IntentResolution) -> Bool {
            switch resolution {
            case .toolCall(let invocation):
                return invocation.providerID == ShellProvider.providerID
                    || invocation.toolID == Self.shellToolID
            case .ask(let question):
                return question.contains(ShellProvider.providerID)
                    || question.contains(Self.shellToolID)
            case .none:
                return false
            }
        }

        // "wipe audit log": the shell row is the bare resolver's confident hit; "audit log":
        // the shell row is one of the bare resolver's ask candidates.
        for utterance in ["wipe audit log", "audit log"] {
            let reached = await bare.wiring.resolve(utterance)
            XCTAssertTrue(
                namesShell(reached),
                "counterfactual: the bare resolver must name the shell row for '\(utterance)', "
                    + "got \(reached)")
        }

        for utterance in ["wipe audit log", "audit log", "clear the audit log", "audit-log-wipe"] {
            let resolution = await harness.wiring.resolve(utterance)
            XCTAssertFalse(
                namesShell(resolution),
                "the composite must never name the shell row for '\(utterance)', got \(resolution)")
        }

        // The surviving answers are the audit tool's: the ask for the partial match, the call
        // for the full one.
        let partial = await harness.wiring.resolve("wipe audit log")
        XCTAssertNotNil(question(in: partial), "the filtered catalog leaves an ask, got \(partial)")
        let full = await harness.wiring.resolve("clear the audit log")
        XCTAssertEqual(
            toolCall(in: full),
            ActionInvocation(providerID: Self.auditProviderID, toolID: Self.clearToolID))

        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        XCTAssertEqual(provider.describeCount, 0)
        XCTAssertEqual(provider.invokeCount, 0)
    }

    // MARK: - Switch off — today's behavior

    /// With the switch off, the same keyword-style utterance over the same enabled tool resolves
    /// nothing end to end — the default is unchanged.
    func testSwitchOffTheSameKeywordUtteranceResolvesNothing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .destructive)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore,
            resolverProvider: Self.composedProvider(keywordFallback: false))
        try await harness.surface.setToolEnabled(Self.auditProviderID, Self.clearToolID, true)

        for utterance in ["clear the audit log", "audit log"] {
            let resolution = await harness.wiring.resolve(utterance)
            XCTAssertEqual(
                resolution, .none,
                "switch off is a bare phrase resolver — '\(utterance)' must resolve nothing")
        }
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        XCTAssertEqual(provider.describeCount, 0)
        XCTAssertEqual(provider.invokeCount, 0)
        let reloaded = await harness.auditStore.load()
        XCTAssertTrue(reloaded.isEmpty)
    }
}
