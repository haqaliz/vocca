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
@testable import VoccaBootstrap
import VoccaActions
import VoccaCore
import VoccaHotkey
import VoccaInject
import XCTest

/// **The composed action surface's contract** (`wiring` aspect, spec acceptances 1-3): the
/// recipe `configure` calls, driven over real temp-directory stores and the **real**
/// `AuditActionProvider` — the same composition the founder will arm `audit.clear` through.
///
/// What is pinned here is the wiring's own round trip: arm → the gate's sentence on the widget
/// card → confirm with the exact sentence shown → invoked → the audit entry reconstructing —
/// plus the binding-mismatch re-prompt (a sentence that changed between show and confirm is
/// refused by attempting the call, and a fresh card is presented), the in-flight arm refusal
/// (the C11 precedent, read lazily from a session-active closure — never at composition), the
/// decline path (the refused decision recorded, the card cleared), the dry-run path (zero
/// provider invocations), and the composed default's facts (`servers=0`, `spawnsSubprocess=false`).
///
/// Acceptances 4-7 (the G5 pin, the wiring-family lint, the zero-network probe line, the
/// transport lint) are the structural legs the other files own; this suite is the recipe's own
/// behaviour.
@MainActor
final class ActionWiringTests: XCTestCase {

    /// The destructive audit tool the founder's scenario arms — `audit.clear`, whose sentence
    /// names the count at describe time.
    private static let providerID = AuditActionProvider.providerID
    private static let toolID = AuditActionProvider.clearToolID

    /// The audit log's own sentence, rendered at a given entry count.
    private func clearSentence(entries: Int) -> String {
        "Permanently delete \(entries) \(entries == 1 ? "entry" : "entries") from the action "
            + "audit log. This cannot be undone."
    }

    // MARK: - Acceptance 1: arm → confirm → invoke → audit reconstruct

    /// **The whole round trip, through the composed recipe**: enable the tool, arm it, read the
    /// gate's exact sentence off the widget card, confirm with that sentence, and reconstruct the
    /// `confirmed` entry from the audit store — the R8 leg, asserted through the wiring rather
    /// than around it.
    func testArmConfirmInvokeAndAuditReconstructThroughTheComposedRecipe() async throws {
        let harness = ActionWiringHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.seedEntries(2)

        try await harness.wiring.setToolEnabled(Self.providerID, Self.toolID, true)

        try await harness.wiring.arm(Self.providerID, Self.toolID)
        let card = harness.root.widgetStore.state.confirmation?.signal
        XCTAssertEqual(
            card?.sentence, clearSentence(entries: 2),
            "the card carries the gate's sentence verbatim — the exact sentence the wiring will "
                + "bind the confirm to")
        XCTAssertEqual(card?.providerID, Self.providerID)
        XCTAssertEqual(card?.toolID, Self.toolID)

        await harness.wiring.confirm()
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
        XCTAssertEqual(entry.toolID, Self.toolID)
        XCTAssertEqual(entry.summary, clearSentence(entries: 2))
    }

    // MARK: - Acceptance 2: the binding mismatch re-presents a fresh card

    /// **The sentence changed between show and confirm**: the store gained an entry after the
    /// card was drawn, so the gate's fresh render differs from the shown sentence — the confirm
    /// is refused *by attempting the call* (the N2 binding live in the wiring's path), the
    /// refusal is recorded with the mismatch key, and a fresh card is presented with the gate's
    /// current sentence (the PRD review's re-prompt default). Confirming the fresh card invokes.
    func testTheBindingMismatchPathRePresentsAFreshCard() async throws {
        let harness = ActionWiringHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.seedEntries(2)
        try await harness.wiring.setToolEnabled(Self.providerID, Self.toolID, true)

        try await harness.wiring.arm(Self.providerID, Self.toolID)
        XCTAssertEqual(
            harness.root.widgetStore.state.confirmation?.signal.sentence,
            clearSentence(entries: 2))

        // The sentence drifts: a third entry lands before the human answers.
        try await harness.seedEntries(1)

        await harness.wiring.confirm()

        let refused = await harness.auditStore.load()
        XCTAssertTrue(
            refused.contains { $0.summary == "gate.approvedSentenceMismatch" },
            "the mismatch is a recorded refusal — the declined decision reaches the audit log "
                + "with the bounded key, never silently")

        let freshCard = harness.root.widgetStore.state.confirmation?.signal
        XCTAssertEqual(
            freshCard?.sentence, clearSentence(entries: 3),
            "the wiring re-presents a fresh card with the gate's current sentence — the binding "
                + "refusal is a re-prompt, never a dead end")

        await harness.wiring.confirm()
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(reloaded.count, 1, "the fresh confirm invoked the clear")
        XCTAssertEqual(reloaded.first?.decision, .confirmed)
        XCTAssertEqual(reloaded.first?.summary, clearSentence(entries: 3))
    }

    // MARK: - Acceptance 3: arming while a session is in flight is refused

    /// **The in-flight refusal** (the C11 precedent): with the session-active flag true, the arm
    /// is refused *by attempting the call* — it throws, no card appears, and no gate decision is
    /// recorded. The flag is read lazily at arm time, never at composition.
    func testArmWhileASessionIsInFlightIsRefused() async throws {
        let harness = ActionWiringHarness(sessionActive: { true })
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.seedEntries(2)
        try await harness.wiring.setToolEnabled(Self.providerID, Self.toolID, true)

        do {
            try await harness.wiring.arm(Self.providerID, Self.toolID)
            XCTFail("an arm while a session is in flight must be refused")
        } catch ActionWiringError.sessionInFlight {
            // The refusal, spoken.
        } catch {
            XCTFail("the in-flight arm refused with the wrong error: \(error)")
        }

        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "no card may appear mid-session — the confirmation cannot land on a dictation")
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.count, 0,
            "the refused arm records nothing — the gate was never reached")
    }

    // MARK: - The decline path

    /// **Decline records the refused decision and clears the card**: the wiring submits the
    /// withheld approval (the stop for want of a yes, recorded like any other decision) and the
    /// card goes away in the same path.
    func testDeclineRecordsTheRefusedDecisionAndClearsTheCard() async throws {
        let harness = ActionWiringHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.wiring.setToolEnabled(Self.providerID, Self.toolID, true)

        try await harness.wiring.arm(Self.providerID, Self.toolID)
        XCTAssertNotNil(harness.root.widgetStore.state.confirmation)

        await harness.wiring.decline()
        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "decline clears the card — dismiss and decline are the same fold, the semantic "
                + "difference lives in the wiring's executor call")

        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(reloaded.count, 2, "the arm's stop and the decline's stop, both recorded")
        XCTAssertTrue(
            reloaded.allSatisfy { $0.decision == .refused },
            "a destructive tool stopped for want of a yes is a refusal — recorded, never absent")
    }

    // MARK: - The composed default's facts

    /// **The composed default reports `servers=0`, `spawnsSubprocess=false`** — the D2 narrowed
    /// promise as a fact the probe line folds: no server is configured out of the box and the
    /// default configuration cannot create a child. The server count is the store's own answer
    /// (effect, not reference); `spawnsSubprocess` is the wiring's declared value, the
    /// `requiresNetwork` analogue.
    func testTheComposedDefaultReportsServersZeroAndNoSpawn() async {
        let harness = ActionWiringHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let config = await harness.wiring.loadConfig()
        XCTAssertTrue(config.servers.isEmpty, "no server is configured out of the box")
        XCTAssertTrue(config.enablement.isEmpty, "nothing is enabled out of the box")
        XCTAssertFalse(
            harness.wiring.spawnsSubprocess,
            "the composed default declares it spawns no child process — the D2 answer is "
                + "unreachable-by-default, never excepted")
    }

    // MARK: - The dry-run half

    /// **Preview renders the provider's sentence without acting** (M5): the destructive tool's
    /// sentence lands, and the audit log survives — the clear was never reached, and the only
    /// new entry is the dry-run's own record (every decision is recorded, the dry-run included).
    func testPreviewRendersTheSentenceWithoutActing() async throws {
        let harness = ActionWiringHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.seedEntries(2)
        try await harness.wiring.setToolEnabled(Self.providerID, Self.toolID, true)

        let sentence = await harness.wiring.preview(Self.providerID, Self.toolID)
        XCTAssertEqual(sentence, clearSentence(entries: 2))

        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.count, 3,
            "two seeded entries plus the dry-run's own record — nothing was cleared")
        XCTAssertTrue(
            reloaded.contains { $0.decision == .dryRun },
            "the preview's decision is recorded as a dry run — the R8 every-decision rule")
        XCTAssertFalse(
            reloaded.contains { $0.decision == .confirmed },
            "no invocation happened — a dry run reaches invoke zero times (M5)")
    }

    // MARK: - The gate's other refusals, through the wiring

    /// **A disabled tool arms nothing** (M7, absent is off): the gate declines before any
    /// describe, the refusal is recorded with the bounded key, and no card appears — the wiring
    /// never pre-checks, because the gate's answer is the decision.
    func testArmingADisabledToolDeclinesWithoutACard() async throws {
        let harness = ActionWiringHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.seedEntries(2)

        try await harness.wiring.arm(Self.providerID, Self.toolID)

        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(
            reloaded.first?.summary, "gate.toolNotEnabled",
            "the unenabled tool is declined before any describe — the M7 never-read rule, "
                + "recorded with its bounded key")
    }

    /// **A cleared card cannot confirm through the wiring**: after decline, the store refuses
    /// the stale confirm — no gate call is made, so no new entry appears (the store's generation
    /// guard, asserted at the only seam the wiring has).
    func testAClearedCardsConfirmMakesNoGateCall() async throws {
        let harness = ActionWiringHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.wiring.setToolEnabled(Self.providerID, Self.toolID, true)

        try await harness.wiring.arm(Self.providerID, Self.toolID)
        await harness.wiring.decline()
        let before = await harness.auditStore.load().count

        await harness.wiring.confirm()

        let after = await harness.auditStore.load().count
        XCTAssertEqual(
            after, before,
            "a confirm for a card that is gone is refused by the store — no executor call, no "
                + "gate call, no record")
    }

    // MARK: - Probe-safe by construction

    /// **The composition starts, reads and writes nothing** (the `ContextWiring` doc contract):
    /// constructing the recipe over the real stores touches no file, opens no microphone and
    /// presents no card — every read happens at call time, every write at user time.
    func testTheCompositionIsProbeSafeByConstruction() async throws {
        let harness = ActionWiringHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "no card exists at composition time")
        let listed = await harness.auditStore.list()
        XCTAssertEqual(
            listed.count, 0,
            "nothing was recorded at composition time")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.directory
                    .appendingPathComponent("config").appendingPathComponent("action-config.json")
                    .path),
            "the config file was not created at composition time — an absent file is the normal "
                + "first-launch state, and the recipe creates nothing")
        XCTAssertEqual(
            harness.holdToTalkSource.beginCount, 0,
            "no microphone was opened at composition time")
        XCTAssertEqual(harness.toggleSource.beginCount, 0)
        XCTAssertEqual(
            harness.wiring.spawnsSubprocess, false,
            "the fact is declared, and nothing at composition can contradict it")
    }
}

/// The wiring test's composition: the real stores over fresh temporary directories, the real
/// `AuditActionProvider`, a real root over the suite's shared fakes, and the recipe composed
/// exactly as `configure` will — the call itself is the compile pin over the parameter list.
@MainActor
private final class ActionWiringHarness {
    let directory: URL
    let configStore: ActionConfigStore
    let auditStore: FileSystemActionAuditStore
    let root: DictationLoopRoot
    let wiring: ActionWiring<AuditActionProvider>
    let holdToTalkSource: RecordingAudioSource
    let toggleSource: RecordingAudioSource

    init(sessionActive: @escaping () -> Bool = { false }) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-action-wiring-\(UUID().uuidString)")
        let configStore = ActionConfigStore(
            directory: directory.appendingPathComponent("config"))
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))

        let engine = StubEngine.parakeet()
        let holdToTalkSource = RecordingAudioSource()
        let toggleSource = RecordingAudioSource()
        let root = DictationLoopRoot(
            configuration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: TestClock(),
            audioSource: holdToTalkSource,
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
            toggleSource: toggleSource,
            toggleTimer: FakeTimer(),
            runningAppName: FakeRunningAppName(),
            widgetClock: FakeTimer(),
            liveLevel: QuietLevelSource(),
            sessionKind: .dictation)

        let wiring = AppBootstrap.composeActionWiring(
            configStore: configStore,
            auditStore: auditStore,
            provider: AuditActionProvider(store: auditStore),
            sessionActive: sessionActive,
            root: root)

        self.directory = directory
        self.configStore = configStore
        self.auditStore = auditStore
        self.root = root
        self.wiring = wiring
        self.holdToTalkSource = holdToTalkSource
        self.toggleSource = toggleSource
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