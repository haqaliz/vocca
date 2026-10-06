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
import VoccaUI
import XCTest

// MARK: - The doubles

/// The root accessor's box — the `configure` `WeakBox` shape, test-side: weak, so a released
/// root reads `nil` exactly as the shipped `{ rootBox.value }` does. Plain `@unchecked
/// Sendable`, written and read only on the main actor (the suite is `@MainActor`).
private final class TestRootBox: @unchecked Sendable {
    weak var value: DictationLoopRoot?

    init(_ root: DictationLoopRoot?) {
        self.value = root
    }
}

// MARK: - The suite

/// **The converse intent closures** (`converse-intent-wiring` / `intent-leg-wiring` B1-B7): the
/// two closures `AppBootstrap.composeConverseIntentClosures(root:)` builds for the converse
/// driver's intent slots, over the round-trip harness's real temp-directory stores, card and
/// audit log.
///
/// The provider is lazy (it reads `root.intentWiring` at call time, never at construction) and
/// maps the wiring's resolution through as-is (D3). The handler is `performAction` behind the D2
/// wrapper: a non-nil result is returned unchanged; a nil result becomes the fixed
/// `"Confirm on screen."` line **only** when a confirmation card is showing, and stays nil —
/// the driver's echo — otherwise.
///
/// The root slot is typed `IntentWiring<AuditActionProvider>`, so the counted-stub legs rehost
/// the stub wiring's two closures into that type (``rehosted(_:)``): the closures are the
/// stub's — the counts are real — and the rehost's executor field is never reached by the
/// static (it reads only `resolve` and `performAction`).
@MainActor
final class ConverseIntentClosuresTests: XCTestCase {

    private static let providerID = AuditActionProvider.providerID
    private static let clearToolID = AuditActionProvider.clearToolID
    private static let countToolID = AuditActionProvider.countToolID

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-converse-intent-closures-\(UUID().uuidString)")
    }

    private func toolCall(in resolution: IntentResolution?) -> ActionInvocation? {
        if case .toolCall(let invocation)? = resolution { return invocation }
        return nil
    }

    /// The stub wiring's closures in the root slot's concrete type — see the suite's note.
    private func rehosted<Provider>(
        _ wiring: IntentWiring<Provider>, auditStore: FileSystemActionAuditStore
    ) -> IntentWiring<AuditActionProvider> {
        // The static reads only `resolve`/`performAction` from the wiring, so this copied
        // executor is never reached.
        let unreached = AuditActionProvider(store: auditStore)
        return IntentWiring(
            resolve: wiring.resolve,
            performAction: wiring.performAction,
            executor: ActionExecutor(provider: unreached, store: auditStore),
            policy: wiring.policy,
            spawnsSubprocess: wiring.spawnsSubprocess)
    }

    private func closures(
        over box: TestRootBox
    ) -> (
        provider: @Sendable (String) async -> IntentResolution?,
        handler: @Sendable (ActionInvocation, String) async -> String?
    ) {
        AppBootstrap.composeConverseIntentClosures(root: { box.value })
    }

    // MARK: - B1: the provider's three answers

    /// **A released root answers nil from both closures** — the driver's existing fall-through
    /// (nil → echo), never a crash and never a stale wiring.
    func testAReleasedRootAnswersNilFromBothClosures() async throws {
        let box = TestRootBox(nil)
        let closures = closures(over: box)
        let invocation = try XCTUnwrap(
            ActionInvocation(providerID: Self.providerID, toolID: Self.clearToolID))

        let resolution = await closures.provider("clear the audit log")
        XCTAssertNil(resolution, "a released root resolves nothing — the driver echoes")
        let reply = await closures.handler(invocation, "clear the audit log")
        XCTAssertNil(reply, "a released root acts on nothing — the driver echoes")
    }

    /// **An absent wiring answers nil from both closures** — a root whose `intentWiring` slot
    /// was never filled is the unwired posture, byte-identical to today's echo.
    func testAnAbsentWiringAnswersNilFromBothClosures() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let harness = IntentRoundTripHarness(
            directory: directory, provider: AuditActionProvider(store: auditStore),
            auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)
        XCTAssertNil(harness.root.intentWiring, "the harness composes but never fills the slot")

        let closures = closures(over: TestRootBox(harness.root))
        let invocation = try XCTUnwrap(
            ActionInvocation(providerID: Self.providerID, toolID: Self.clearToolID))
        let resolution = await closures.provider("clear the audit log")
        XCTAssertNil(resolution, "no wiring → nil, even for a phrase an enabled tool matches")
        let reply = await closures.handler(invocation, "clear the audit log")
        XCTAssertNil(reply)
        XCTAssertNil(harness.root.widgetStore.state.confirmation, "nothing acted, no card")
        let entries = await harness.auditStore.load()
        XCTAssertTrue(entries.isEmpty, "no wiring → no submission → nothing recorded")
    }

    /// **A present wiring's resolution is returned as-is** (D3): a hit is the wiring's own
    /// `.toolCall`, and a miss is the wiring's `.none` — which the driver echoes exactly as it
    /// echoes nil.
    func testAPresentWiringsResolutionIsReturnedAsIs() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let harness = IntentRoundTripHarness(
            directory: directory, provider: AuditActionProvider(store: auditStore),
            auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)
        harness.root.intentWiring = harness.wiring

        let closures = closures(over: TestRootBox(harness.root))
        let hit = await closures.provider("clear the audit log")
        let direct = await harness.wiring.resolve("clear the audit log")
        XCTAssertEqual(hit, direct, "the closure is the wiring's resolution, unchanged")
        let invocation = try XCTUnwrap(toolCall(in: hit))
        XCTAssertEqual(invocation.providerID, Self.providerID)
        XCTAssertEqual(invocation.toolID, Self.clearToolID)

        let miss = await closures.provider("what a lovely afternoon")
        XCTAssertEqual(miss, IntentResolution.none, "a miss maps `.none` through unchanged")
    }

    // MARK: - B2: lazy

    /// **The ordering claim**: a closure built BEFORE `root.intentWiring` is assigned resolves
    /// through it AFTER — `configure` composes the intent wiring after the converse task is
    /// created, so a closure that captured the slot at construction would hold nil forever.
    func testAClosureBuiltBeforeTheWiringIsAssignedResolvesThroughItAfter() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let harness = IntentRoundTripHarness(
            directory: directory, provider: AuditActionProvider(store: auditStore),
            auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)

        let closures = closures(over: TestRootBox(harness.root))
        let before = await closures.provider("clear the audit log")
        XCTAssertNil(before, "the slot is empty at construction")

        harness.root.intentWiring = harness.wiring
        let after = await closures.provider("clear the audit log")
        XCTAssertNotNil(
            toolCall(in: after),
            "the closure reads the slot at call time — the wiring assigned later is the one used")
    }

    // MARK: - B3: read-only

    /// **A read-only tool runs and its ack is spoken**: the wiring's "Done." returned unchanged,
    /// audited `autoRanReadOnly`, no card, the provider invoked once.
    func testAReadOnlyToolReturnsTheWiringsAckAuditedAndNoCard() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.countToolID], describedRadius: .readOnly)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.countToolID, true)
        harness.root.intentWiring = rehosted(harness.wiring, auditStore: auditStore)

        let closures = closures(over: TestRootBox(harness.root))
        let resolution = await closures.provider("count the audit log")
        let invocation = try XCTUnwrap(toolCall(in: resolution))
        let reply = await closures.handler(invocation, "count the audit log")

        XCTAssertEqual(reply, "Done.", "the wiring's ack, unchanged")
        XCTAssertNil(harness.root.widgetStore.state.confirmation, "read-only runs, no card")
        XCTAssertEqual(provider.invokeCount, 1)
        let entries = await harness.auditStore.load()
        XCTAssertEqual(entries.map(\.decision), [.autoRanReadOnly])
    }

    // MARK: - B4: destructive

    /// **A destructive tool's card is spoken as the confirm line**: the wiring returns nil and
    /// presents the card, so the handler answers exactly `"Confirm on screen."` — never the
    /// echo of the user's words; the provider is never invoked and the stop is recorded.
    func testADestructiveToolSpeaksTheConfirmLineWithTheCardUpAndNothingInvoked() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .destructive)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)
        harness.root.intentWiring = rehosted(harness.wiring, auditStore: auditStore)

        let closures = closures(over: TestRootBox(harness.root))
        let resolution = await closures.provider("clear the audit log")
        let invocation = try XCTUnwrap(toolCall(in: resolution))
        let reply = await closures.handler(invocation, "clear the audit log")

        XCTAssertEqual(reply, "Confirm on screen.")
        XCTAssertEqual(AppBootstrap.confirmOnScreenReply, "Confirm on screen.")
        XCTAssertNotNil(harness.root.widgetStore.state.confirmation, "the card is the surface")
        XCTAssertEqual(provider.invokeCount, 0, "nothing runs without a human yes")
        let entries = await harness.auditStore.load()
        XCTAssertEqual(entries.map(\.decision), [.refused])
    }

    // MARK: - B5: a second action while a card is up

    /// **A second action while a card is up speaks the confirm line** (a card is waiting) —
    /// the existing card-up refusal is untouched: no second card, nothing recorded.
    func testASecondActionWhileACardIsUpSpeaksTheConfirmLineAndChangesNothing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .destructive)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)
        harness.root.intentWiring = rehosted(harness.wiring, auditStore: auditStore)

        let closures = closures(over: TestRootBox(harness.root))
        let firstResolution = await closures.provider("clear the audit log")
        let first = try XCTUnwrap(toolCall(in: firstResolution))
        _ = await closures.handler(first, "clear the audit log")
        let firstCard = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        let entriesBefore = await harness.auditStore.load()

        let secondResolution = await closures.provider("clear the audit log")
        let second = try XCTUnwrap(toolCall(in: secondResolution))
        let reply = await closures.handler(second, "clear the audit log")

        XCTAssertEqual(reply, "Confirm on screen.", "a card is waiting — say so")
        XCTAssertEqual(
            harness.root.widgetStore.state.confirmation?.signal.generation, firstCard.generation,
            "no second card — the first is untouched")
        let entriesAfter = await harness.auditStore.load()
        XCTAssertEqual(entriesAfter.map(\.decision), entriesBefore.map(\.decision))
        XCTAssertEqual(entriesAfter.map(\.decision), [.refused], "the refusal records nothing")
        XCTAssertEqual(provider.invokeCount, 0)
    }

    // MARK: - B6: nil with no card stays nil

    /// **A nil result with no card stays nil** — the driver echoes, unchanged: a read-only run
    /// whose outcome is `.notInvoked` is a nil from the wiring with nothing on screen, and the
    /// confirm line would be an instruction the user cannot act on.
    ///
    /// Counterfactual (checked, reverted): a wrapper that speaks the line unconditionally on nil
    /// fails this test.
    func testANilResultWithNoCardStaysNilSoTheDriverEchoes() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.countToolID], describedRadius: .readOnly,
            behavior: .executes(.notInvoked))
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.countToolID, true)
        harness.root.intentWiring = rehosted(harness.wiring, auditStore: auditStore)

        let closures = closures(over: TestRootBox(harness.root))
        let resolution = await closures.provider("count the audit log")
        let invocation = try XCTUnwrap(toolCall(in: resolution))
        let direct = await harness.wiring.performAction(invocation, "count the audit log")
        XCTAssertNil(direct, "precondition: the wiring answers `.notInvoked` with nil")
        XCTAssertNil(harness.root.widgetStore.state.confirmation, "precondition: no card")

        let invokesBefore = provider.invokeCount
        let entriesBefore = await harness.auditStore.load()

        let reply = await closures.handler(invocation, "count the audit log")
        XCTAssertNil(reply, "no card → nil → the driver's echo, never the confirm line")
        // The handler delegates to `performAction` exactly once (the precondition call above
        // is the only other run) and adds nothing of its own: one more invoke, one more
        // `autoRanReadOnly` record — never a refusal, never a card.
        XCTAssertEqual(
            provider.invokeCount, invokesBefore + 1, "one delegation, no retry, no extra invoke")
        let entriesAfter = await harness.auditStore.load()
        XCTAssertEqual(entriesAfter.count, entriesBefore.count + 1)
        XCTAssertEqual(
            entriesAfter.map(\.decision),
            entriesBefore.map(\.decision) + [.autoRanReadOnly],
            "the nil path records the read-only auto-run and nothing else")
        XCTAssertNil(harness.root.widgetStore.state.confirmation, "still no card afterwards")
    }

    // MARK: - B7: the failure copy is never replaced

    /// **The record-failure copy is returned verbatim, never the confirm line** — through the
    /// real wiring (`auditRecorded == false`, no card), and through a scripted wiring that
    /// answers non-nil **while a card is up**: the wrapper only ever fills a nil.
    ///
    /// Counterfactual (checked, reverted): a wrapper that returns the line whenever a card is
    /// up, whatever the result, fails the scripted leg.
    func testANonNilResultIsReturnedVerbatimEvenWithACardUp() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The real leg: the store cannot be written.
        let failingStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"),
            fileSystem: UncreatableDirectoryActionAuditFileSystem())
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .destructive)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: failingStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)
        harness.root.intentWiring = rehosted(harness.wiring, auditStore: failingStore)

        let closures = closures(over: TestRootBox(harness.root))
        let resolution = await closures.provider("clear the audit log")
        let invocation = try XCTUnwrap(toolCall(in: resolution))
        let reply = await closures.handler(invocation, "clear the audit log")
        XCTAssertEqual(reply, "Something went wrong — the action was not recorded.")
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        XCTAssertEqual(provider.invokeCount, 0)

        // The scripted leg: a card is up and the wiring still answers — each answer verbatim.
        harness.root.widgetStore.presentActionConfirmation(
            WidgetConfirmationSignal(
                sentence: "An earlier card.", providerID: Self.providerID,
                toolID: Self.clearToolID, generation: 1))
        XCTAssertNotNil(harness.root.widgetStore.state.confirmation, "precondition: a card")
        for answer in ["Something went wrong — the action was not recorded.", "Done.", "Cancelled."]
        {
            harness.root.intentWiring = IntentWiring(
                resolve: { _ in .none },
                performAction: { _, _ in answer },
                executor: ActionExecutor(
                    provider: AuditActionProvider(store: failingStore), store: failingStore),
                policy: .none,
                spawnsSubprocess: false)
            let scripted = await closures.handler(invocation, "clear the audit log")
            XCTAssertEqual(scripted, answer, "a non-nil answer is never replaced by the line")
        }
    }
}
