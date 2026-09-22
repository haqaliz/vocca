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
import VoccaHotkey
import VoccaInject
import XCTest

// MARK: - The doubles

/// The catalog-recording resolver — the ``RecordingStateSink`` shape: a plain `@unchecked
/// Sendable` box, written and read only on the main actor (the wiring's `resolve` closure is
/// `@MainActor`), never concurrently.
///
/// The R3 never-read leg is asserted on **what the resolver actually received**: every catalog
/// the wiring hands over is recorded, so "a disabled tool is never resolved to" is a claim about
/// the seam's input rather than about the wiring's intentions.
private final class RecordingIntentResolver: IntentResolver, @unchecked Sendable {
    private(set) var catalogs: [[ToolReference]] = []
    private let wrapped: KeywordIntentResolver

    init(wrapped: KeywordIntentResolver = KeywordIntentResolver()) {
        self.wrapped = wrapped
    }

    func resolve(_ utterance: String, against catalog: [ToolReference]) -> IntentResolution {
        catalogs.append(catalog)
        return wrapped.resolve(utterance, against: catalog)
    }
}

// MARK: - The harness

/// The round-trip composition: real temp-directory stores, a real root over the suite's shared
/// fakes, **both** recipes composed over the same provider instance — the intent recipe under
/// test, and the action surface whose existing confirm/decline closures and enablement writes
/// the human leg reuses (the composition the probe aspect will make; the shared widget store is
/// what lets an intent-presented card be answered by the surface's own closures).
@MainActor
private final class IntentRoundTripHarness<Provider: ActionProvider> {
    let directory: URL
    let configStore: ActionConfigStore
    let auditStore: FileSystemActionAuditStore
    let root: DictationLoopRoot
    let resolver: RecordingIntentResolver
    /// The intent recipe under test.
    let wiring: IntentWiring<Provider>
    /// The action surface — `setToolEnabled`, `confirm` and `decline` (the existing closures).
    let surface: ActionWiring<Provider>

    init(
        directory: URL,
        provider: Provider,
        auditStore: FileSystemActionAuditStore,
        resolver: RecordingIntentResolver = RecordingIntentResolver()
    ) {
        let configStore = ActionConfigStore(
            directory: directory.appendingPathComponent("config"))

        let engine = StubEngine.parakeet()
        let root = DictationLoopRoot(
            configuration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: TestClock(),
            audioSource: RecordingAudioSource(),
            keyState: TruthfulKeyState(Keyboard()),
            watchdogTimer: FakeTimer(),
            healthTimer: FakeTimer(),
            deferOpening: { $0() },
            tap: FakeHotkeyEventSource(),
            secureInput: FakeSecureInputState(),
            resolver: DictationEngineResolver(selection: .defaultSelection) { _ in engine },
            targetResolution: TargetResolution(
                focusedApp: FakeFocusedApp(
                    identity: FocusedAppIdentity(
                        bundleID: "com.apple.Notes", windowTitle: "The Draft")),
                secureInput: FakeSecureInput(),
                frontmost: FakeFrontmostApp()),
            panel: RecordingPanel(holder: LedgerHolder()),
            toggleConfiguration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .toggle),
            toggleSource: RecordingAudioSource(),
            toggleTimer: FakeTimer(),
            runningAppName: FakeRunningAppName(),
            widgetClock: FakeTimer(),
            liveLevel: QuietLevelSource(),
            sessionKind: .dictation)

        let wiring = AppBootstrap.composeIntentWiring(
            configStore: configStore,
            auditStore: auditStore,
            provider: provider,
            resolver: resolver,
            root: root)
        let surface = AppBootstrap.composeActionWiring(
            configStore: configStore,
            auditStore: auditStore,
            provider: provider,
            sessionActive: { false },
            root: root)

        self.directory = directory
        self.configStore = configStore
        self.auditStore = auditStore
        self.root = root
        self.resolver = resolver
        self.wiring = wiring
        self.surface = surface
    }

    /// Commits `count` ordinary entries so `audit.clear`'s sentence has content to name.
    func seedEntries(_ count: Int) async throws {
        for _ in 0..<count {
            try await auditStore.record(
                ActionInvocation(providerID: "seed", toolID: "seed")!,
                decision: .confirmationRequired(
                    ActionSummary(sentence: "seeded", blastRadius: .readOnly)),
                at: .zero)
        }
    }
}

/// A level source that never moves — this suite's `QuietLevelSource` (each file owns its
/// spelling).
private struct QuietLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}

// MARK: - The suite

/// **The voice round trip** (`intent-layer` PRD R5; `action-round-trip` spec acceptances 1-5):
/// the `IntentWiring` recipe's closures over real temp-directory stores and a stub provider with
/// a call log — utterance → resolve → gate → `.confirmationRequired` → card (the gate's sentence
/// verbatim, re-rendered after the record, with a fresh generation token) → the **existing**
/// confirm/decline closures complete the human leg (generation guard, `.granted` with the shown
/// sentence, mismatch re-prompt) → the audit row reconstructs.
///
/// The first test runs the founder's scenario over the **real** `AuditActionProvider` — the
/// same composition the Actions tab arms through — so the count-bearing sentence, the post-record
/// re-render and the reconstruct are the real ones. The refusal legs use the executing stub so
/// "no `invoke` call" is a counted fact rather than an inference from the log's shape.
@MainActor
final class IntentRoundTripTests: XCTestCase {

    private static let providerID = AuditActionProvider.providerID
    private static let clearToolID = AuditActionProvider.clearToolID

    private func clearSentence(entries: Int) -> String {
        "Permanently delete \(entries) \(entries == 1 ? "entry" : "entries") from the action "
            + "audit log. This cannot be undone."
    }

    private func toolCall(in resolution: IntentResolution) -> ActionInvocation? {
        if case .toolCall(let invocation) = resolution { return invocation }
        return nil
    }

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-intent-round-trip-\(UUID().uuidString)")
    }

    // MARK: - Acceptances 1 + 2: the round trip through the real recipe

    /// **The whole round trip, through the composed intent recipe and the existing confirm
    /// closure**: "clear the audit log" → `.toolCall` → the card with the gate's sentence
    /// verbatim (the post-record re-render — the count the confirm will face) → confirm → the
    /// clear runs and its own record reconstructs with `approvedSentence` matched. A second
    /// utterance mints a fresh generation token.
    func testTheVoiceRoundTripResolvesPresentsConfirmsAndReconstructs() async throws {
        let directory = Self.tempDirectory()
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = AuditActionProvider(store: auditStore)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await harness.seedEntries(2)
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)

        let resolution = await harness.wiring.resolve("clear the audit log")
        let invocation = try XCTUnwrap(toolCall(in: resolution))
        XCTAssertEqual(
            invocation, ActionInvocation(providerID: Self.providerID, toolID: Self.clearToolID),
            "the seeded synonym resolves to the enabled tool's invocation, arguments nil")

        let reply = await harness.wiring.performAction(invocation)
        XCTAssertNil(
            reply,
            "a card is up — the card is the answer, and no spoken ack stands in for it")

        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            card.sentence, clearSentence(entries: 3),
            "the card carries the gate's sentence verbatim, **re-rendered after the record** — "
                + "the record lands between the gate's describe and the card, so the shown "
                + "sentence is the post-record count the confirm's own render will match")
        XCTAssertEqual(card.providerID, Self.providerID)
        XCTAssertEqual(card.toolID, Self.clearToolID)
        let firstGeneration = card.generation
        XCTAssertGreaterThan(firstGeneration, 0, "the mint's first token is a real token")

        // The human leg — the existing confirm closure, over the intent-presented card.
        await harness.surface.confirm()
        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "an accepted confirm clears the card in the same fold")

        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.count, 1,
            "audit.clear ran: the log holds only the clear's own record — everything before it "
                + "was removed, and the clear is itself auditable (the record lands after)")
        let entry = try XCTUnwrap(reloaded.first)
        XCTAssertEqual(entry.decision, .confirmed, "the invoked action reconstructs as confirmed")
        XCTAssertEqual(entry.providerID, Self.providerID)
        XCTAssertEqual(entry.toolID, Self.clearToolID)
        XCTAssertEqual(
            entry.summary, clearSentence(entries: 3),
            "approvedSentence matched — the sentence the card showed is the sentence the gate "
                + "acted on and the log recorded")

        // A fresh utterance mints a fresh generation token.
        let again = try XCTUnwrap(toolCall(in: await harness.wiring.resolve("clear the audit log")))
        _ = await harness.wiring.performAction(again)
        let secondCard = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            secondCard.sentence, clearSentence(entries: 2),
            "the re-render reads the post-clear log — the count-bearing sentence is current truth")
        XCTAssertNotEqual(
            secondCard.generation, firstGeneration,
            "each presentation mints a fresh generation token — the store compares, the wiring "
                + "mints")
    }

    /// **The binding mismatch re-prompt, over an intent-presented card**: the count drifts
    /// between show and confirm, the confirm is refused *by attempting the call*, the refusal
    /// is recorded with the bounded key, a fresh card is presented with the gate's current
    /// sentence and a fresh generation token, and confirming the fresh card invokes.
    func testTheBindingMismatchRePromptsWithAFreshGenerationAndTheFreshConfirmInvokes() async throws
    {
        let directory = Self.tempDirectory()
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = AuditActionProvider(store: auditStore)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await harness.seedEntries(2)
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)

        let invocation = try XCTUnwrap(
            toolCall(in: await harness.wiring.resolve("clear the audit log")))
        _ = await harness.wiring.performAction(invocation)
        let firstCard = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(firstCard.sentence, clearSentence(entries: 3))

        // The sentence drifts: a fourth entry lands before the human answers.
        try await harness.seedEntries(1)

        await harness.surface.confirm()

        let refused = await harness.auditStore.load()
        XCTAssertTrue(
            refused.contains { $0.summary == "gate.approvedSentenceMismatch" },
            "the mismatch is a recorded refusal — the declined decision reaches the audit log "
                + "with the bounded key, never silently")

        let freshCard = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            freshCard.sentence, clearSentence(entries: 4),
            "the wiring re-presents a fresh card with the gate's current sentence — the binding "
                + "refusal is a re-prompt, never a dead end")
        XCTAssertNotEqual(
            freshCard.generation, firstCard.generation,
            "the re-prompt mints a fresh generation token — a stale card cannot confirm through "
                + "the store's guard")

        await harness.surface.confirm()
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(reloaded.count, 1, "the fresh confirm invoked the clear")
        XCTAssertEqual(reloaded.first?.decision, .confirmed)
        XCTAssertEqual(reloaded.first?.summary, clearSentence(entries: 4))
    }

    // MARK: - Acceptance 3: the decline path

    /// **Decline records the refused decision and never invokes**: the voice action's stop and
    /// the decline's own withheld submission are both recorded as refusals, the card clears,
    /// and the provider's call log shows zero invocations.
    func testDeclineRecordsTheRefusedDecisionAndNeverInvokes() async throws {
        let directory = Self.tempDirectory()
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .destructive)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)

        let invocation = try XCTUnwrap(
            toolCall(in: await harness.wiring.resolve("clear the audit log")))
        _ = await harness.wiring.performAction(invocation)
        XCTAssertNotNil(harness.root.widgetStore.state.confirmation)

        await harness.surface.decline()
        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "decline clears the card — dismiss and decline are the same fold, the semantic "
                + "difference lives in the executor call")

        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.count, 2,
            "the voice action's stop and the decline's stop, both recorded")
        XCTAssertTrue(
            reloaded.allSatisfy { $0.decision == .refused },
            "a destructive tool stopped for want of a yes is a refusal — recorded, never absent")
        XCTAssertEqual(
            provider.invokeCount, 0,
            "declining never reaches the acting half of the seam")
    }

    // MARK: - Acceptance 4: the disabled tool, never-read

    /// **A disabled tool is never resolved to, never described, never called** (M7, R3): the
    /// catalog the resolver actually receives never contains it (the recording resolver's
    /// input, not the wiring's claim), resolving the seeded phrase yields `.none`, and a direct
    /// attempt to act on it is declined by the gate with the bounded key and zero invocations.
    /// The 4 KB argument bound is refused the same way: `.none`, never a crash.
    func testADisabledToolIsNeverResolvedToNorCalled() async throws {
        let directory = Self.tempDirectory()
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID, "post_message"], describedRadius: .destructive)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Nothing is enabled — absent is off (M7).
        let resolution = await harness.wiring.resolve("clear the audit log")
        XCTAssertEqual(
            resolution, .none,
            "the seeded phrase resolves to nothing while its tool is disabled")
        XCTAssertEqual(
            harness.resolver.catalogs.last, [],
            "the resolver received the empty catalog — never the disabled tool")

        // A direct attempt to act on the disabled tool: the gate declines before any describe,
        // the refusal is recorded with the bounded key, and nothing is invoked.
        let direct = try XCTUnwrap(
            ActionInvocation(providerID: Self.providerID, toolID: Self.clearToolID))
        let reply = await harness.wiring.performAction(direct)
        XCTAssertEqual(
            reply, "Cancelled.",
            "the declined voice action speaks the refused ack — the decision was recorded")
        XCTAssertNil(harness.root.widgetStore.state.confirmation, "no card for a refusal")
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(reloaded.count, 1, "the declined attempt is recorded like any decision")
        XCTAssertEqual(reloaded.first?.summary, "gate.toolNotEnabled")
        XCTAssertEqual(
            provider.invokeCount, 0,
            "a disabled tool is never called — the never-read property, counted")
        XCTAssertEqual(
            provider.describeCount, 0,
            "a disabled tool is never described — the gate declines before the first await")

        // The 4 KB argument bound: an oversized utterance would build arguments past the bound,
        // so the invocation is refused at construction — .none, never a crash, never truncated
        // arguments (truncated arguments are a different action).
        try await harness.surface.setToolEnabled("dev.vocca.mcp.chat", "post_message", true)
        let oversized = "post a message " + String(repeating: "x", count: 5000)
        XCTAssertEqual(
            await harness.wiring.resolve(oversized), .none,
            "an invocation whose arguments exceed the 4 KB bound is refused at construction — "
                + "the wiring turns it into .none, never a crash")
        XCTAssertFalse(
            harness.resolver.catalogs.allSatisfy { $0.isEmpty },
            "the second resolution saw the mcp catalog — the recording leg is live")
        XCTAssertTrue(
            harness.resolver.catalogs.allSatisfy {
                !$0.contains(
                    ToolReference(
                        providerID: Self.providerID, toolID: Self.clearToolID, displayName: ""))
            },
            "no catalog the resolver ever received contained the disabled tool — never-read, "
                + "measured on the seam's actual input")
        XCTAssertEqual(provider.invokeCount, 0)
    }

    // MARK: - Acceptance 5: the card-up guard

    /// **One card at a time**: while the store's confirmation is non-nil, a second voice action
    /// refuses to present — no replacement card, no executor submission, no record. And after
    /// the human declines, a fresh utterance mints a fresh generation token (each presentation
    /// is a new card, never a replay).
    func testTheCardUpGuardRefusesASecondPresentationAndMintsFreshTokens() async throws {
        let directory = Self.tempDirectory()
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .destructive)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)

        let first = try XCTUnwrap(
            toolCall(in: await harness.wiring.resolve("clear the audit log")))
        _ = await harness.wiring.performAction(first)
        let firstCard = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        let entriesBefore = await harness.auditStore.list().count

        // The second voice action while the card is up: refused.
        let second = try XCTUnwrap(
            toolCall(in: await harness.wiring.resolve("clear the audit log")))
        let secondReply = await harness.wiring.performAction(second)
        XCTAssertNil(secondReply, "the refusal is silent — the card is the surface")
        XCTAssertEqual(
            await harness.auditStore.list().count, entriesBefore,
            "the refused presentation makes no executor submission and records nothing — the "
                + "replacement-card hazard is refused before the gate")
        XCTAssertEqual(
            harness.root.widgetStore.state.confirmation?.signal.generation, firstCard.generation,
            "the first card is untouched — a refused presentation replaces nothing")

        // After the human declines, a fresh utterance presents a fresh card with a fresh token.
        await harness.surface.decline()
        let third = try XCTUnwrap(
            toolCall(in: await harness.wiring.resolve("clear the audit log")))
        _ = await harness.wiring.performAction(third)
        let thirdCard = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertNotEqual(
            thirdCard.generation, firstCard.generation,
            "each presentation mints a fresh generation token")
        XCTAssertEqual(
            provider.invokeCount, 0,
            "no voice action ever reached the acting half without a human yes")
    }

    // MARK: - The recording-failure ack

    /// **A decision whose record failed yields the bounded failure ack, never a success ack and
    /// never a card** (`ActionExecutor`'s `auditRecorded == false`, surfaced by the voice leg):
    /// the store cannot be written, the executor returns the loud fact, and the wiring answers
    /// with the honest copy — the card is not presented for a decision the log does not hold.
    func testARecordingFailureYieldsTheBoundedFailureAckAndNoCard() async throws {
        let directory = Self.tempDirectory()
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"),
            fileSystem: UncreatableDirectoryActionAuditFileSystem())
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .destructive)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)

        let invocation = try XCTUnwrap(
            toolCall(in: await harness.wiring.resolve("clear the audit log")))
        let reply = await harness.wiring.performAction(invocation)
        XCTAssertEqual(
            reply, "Something went wrong — the action was not recorded.",
            "auditRecorded == false is the loud fact, spoken — never a success ack")
        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "no card for a decision the log does not hold — the failure ack is the answer")
        XCTAssertEqual(
            provider.invokeCount, 0,
            "the failed record is a lost record, never an unrun action — and the voice leg "
                + "refuses to present rather than approve through a hole")
    }
}