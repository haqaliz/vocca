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
import Synchronization
import VoccaActions
import VoccaBootstrap
import VoccaCore
import XCTest

/// **The composed phrase leg** (`phrase-intent-resolver` PRD R5-R7; `wiring` spec acceptance
/// 1-6): the intent recipe composed the way the shipped default now is — a resolver
/// *provider* consulted once per turn over a real `intent-phrases.json` — and the safety spine
/// holding over a phrase-resolved call.
///
/// The ``IntentRoundTripHarness`` composition (real temp-directory stores, a real root, the
/// action surface's own enablement writes and card closures), given the per-turn provider.
@MainActor
final class PhraseIntentWiringTests: XCTestCase {

    private static let auditProviderID = AuditActionProvider.providerID
    private static let clearToolID = AuditActionProvider.clearToolID
    private static let countToolID = AuditActionProvider.countToolID

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-phrase-wiring-\(UUID().uuidString)")
    }

    /// The composed default's recipe, verbatim in shape: load the table, build the resolver.
    private static func phraseProvider(
        _ store: IntentPhraseStore
    ) -> @Sendable @MainActor () async -> any IntentResolver {
        { PhraseIntentResolver(rows: await store.load().phrases) }
    }

    private func toolCall(in resolution: IntentResolution) -> ActionInvocation? {
        if case .toolCall(let invocation) = resolution { return invocation }
        return nil
    }

    // MARK: - Acceptance 1 — probe-safe

    /// Composing the recipe consults the resolver provider **zero** times — nothing is read at
    /// composition — and each resolution consults it exactly once.
    func testComposingTheRecipeReadsThePhraseStoreZeroTimes() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .destructive)
        let consulted = CallCounter()

        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore,
            resolverProvider: {
                consulted.increment()
                return PhraseIntentResolver(rows: [])
            })

        XCTAssertEqual(consulted.count, 0, "composition must never consult the resolver")
        _ = await harness.wiring.resolve("clear the audit log")
        XCTAssertEqual(consulted.count, 1, "one resolution consults the resolver once")
    }

    // MARK: - Acceptance 2 — no relaunch

    /// An edit to the phrase file takes effect on the next turn, on the same composed wiring:
    /// the phrase resolves while the row exists and resolves nothing once it is gone.
    func testAnEditedPhraseFileTakesEffectOnTheNextTurnWithoutRecomposing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.countToolID], describedRadius: .readOnly)
        let phraseStore = IntentPhraseStore(
            directory: directory.appendingPathComponent("phrases"), log: { _ in })
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore,
            resolverProvider: Self.phraseProvider(phraseStore))
        try await harness.surface.setToolEnabled(Self.auditProviderID, Self.countToolID, true)

        try await phraseStore.save(
            IntentPhraseFile(phrases: [
                PhraseIntentRow(
                    phrase: "how big is the log", providerID: Self.auditProviderID,
                    toolID: Self.countToolID)
            ]))
        let before = await harness.wiring.resolve("How big is the log?")
        XCTAssertEqual(
            toolCall(in: before),
            ActionInvocation(providerID: Self.auditProviderID, toolID: Self.countToolID))

        try await phraseStore.save(IntentPhraseFile(phrases: []))
        let after = await harness.wiring.resolve("How big is the log?")
        XCTAssertEqual(after, .none, "the removed phrase must stop resolving on the next turn")
    }

    // MARK: - Acceptance 3 — the load-bearing refusal

    /// **A phrase-resolved destructive call is refused by attempting it**: the user's own
    /// phrase names an enabled destructive tool, the voice leg submits it withheld, the card
    /// is presented, the refusal is recorded — and the acting half is never reached.
    func testAPhraseResolvedDestructiveToolIsRefusedByAttemptingTheCall() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .destructive)
        let phraseStore = IntentPhraseStore(
            directory: directory.appendingPathComponent("phrases"), log: { _ in })
        try await phraseStore.save(
            IntentPhraseFile(phrases: [
                PhraseIntentRow(
                    phrase: "wipe the log", providerID: Self.auditProviderID,
                    toolID: Self.clearToolID)
            ]))
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore,
            resolverProvider: Self.phraseProvider(phraseStore))
        try await harness.surface.setToolEnabled(Self.auditProviderID, Self.clearToolID, true)

        let resolution = await harness.wiring.resolve("Wipe the log.")
        let invocation = try XCTUnwrap(toolCall(in: resolution))
        let reply = await harness.wiring.performAction(invocation)

        XCTAssertNil(reply, "the card is the answer — no spoken ack stands in for it")
        XCTAssertNotNil(
            harness.root.widgetStore.state.confirmation,
            "the phrase-resolved destructive call must reach the card")
        XCTAssertEqual(
            provider.invokeCount, 0,
            "the acting half is never reached without a human yes — attempted, refused")
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(reloaded.map(\.decision), [.refused], "the stop is recorded")
    }

    // MARK: - Acceptance 5 — the catalog is the enablement

    /// A phrase naming a tool with no enablement row resolves nothing, and the provider is
    /// neither described nor invoked.
    func testAPhraseNamingAToolWithNoEnablementRowResolvesNoneAndTouchesNothing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .destructive)
        let phraseStore = IntentPhraseStore(
            directory: directory.appendingPathComponent("phrases"), log: { _ in })
        try await phraseStore.save(
            IntentPhraseFile(phrases: [
                PhraseIntentRow(
                    phrase: "wipe the log", providerID: Self.auditProviderID,
                    toolID: Self.clearToolID)
            ]))
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore,
            resolverProvider: Self.phraseProvider(phraseStore))

        let resolution = await harness.wiring.resolve("wipe the log")

        XCTAssertEqual(resolution, .none)
        XCTAssertEqual(provider.describeCount, 0)
        XCTAssertEqual(provider.invokeCount, 0)
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
    }

    // MARK: - Acceptance 6 — shell is never reachable by voice

    /// A hand-edited phrase naming a shell command resolves nothing **even with that shell
    /// command enabled** — the refusal is at load, so the resolver never holds the row.
    func testAShellPhraseResolvesNoneEvenWithTheShellCommandEnabled() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: ["empty-downloads"], describedRadius: .destructive)
        let phraseDirectory = directory.appendingPathComponent("phrases")
        try FileManager.default.createDirectory(
            at: phraseDirectory, withIntermediateDirectories: true)
        try Data(
            #"{"version": 1, "phrases": [{"phrase": "empty my downloads", "providerID": "\#(ShellProvider.providerID)", "toolID": "empty-downloads"}]}"#
                .utf8
        ).write(to: phraseDirectory.appendingPathComponent("intent-phrases.json"))
        let phraseStore = IntentPhraseStore(directory: phraseDirectory, log: { _ in })
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore,
            resolverProvider: Self.phraseProvider(phraseStore))
        try await harness.surface.setToolEnabled(
            ShellProvider.providerID, "empty-downloads", true)

        let resolution = await harness.wiring.resolve("empty my downloads")

        XCTAssertEqual(resolution, .none, "a shell command must never be reachable by voice")
        XCTAssertEqual(provider.describeCount, 0)
        XCTAssertEqual(provider.invokeCount, 0)
    }
}

/// A main-actor call counter — `Sendable` by a `Mutex`, so the provider closure may capture it.
private final class CallCounter: Sendable {
    private let value = Mutex(0)

    var count: Int { value.withLock { $0 } }

    func increment() { value.withLock { $0 += 1 } }
}
