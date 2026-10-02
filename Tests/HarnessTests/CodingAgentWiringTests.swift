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
@testable import VoccaBootstrap
import VoccaActions
import VoccaCore
import VoccaHotkey
import VoccaInject
import XCTest

/// **The composed coding-agent wiring's contract** (`wiring` aspect, spec acceptances 1-6):
/// the recipe `configure` calls, driven over real temp-directory stores, the **real**
/// `CodingAgentRegistry` and the **real** `CodingAgentProvider` over a counting engine
/// closure — nothing in this suite ever spawns a child.
///
/// What is pinned here is the wiring's own round trip over the shared spine: arm → the
/// argv-derived sentence on the widget card → confirm with the exact sentence shown → the
/// engine runs (counted) → the audit entry reconstructs — plus the composed default's facts
/// (`agents=0`, `spawnsSubprocess=false`), the in-flight refusal, the binding-mismatch
/// re-prompt, the voice leg (a phrase row naming `vocca.agent` resolves only when
/// enabled, and the intent store refuses only `dev.vocca.shell`) and the stale-row reconcile
/// (the surface reads the registry per call; the provider's tool list is fixed at
/// construction, and a late row describes as the read-only refusal, never a trap).
///
/// The sentence is the provider's own argv-derived rendering (`CodingAgentSentences`) —
/// this suite asserts it through the wiring, never around it, so the card a user sees is the
/// card this suite read.
///
/// The structural legs (the G5 pin, the wiring-family lint rows, the zero-network probe) are
/// the other files' acceptances; this suite is the recipe's own behaviour.
@MainActor
final class CodingAgentWiringTests: XCTestCase {

    /// The agent the founder's scenario arms — a benign fixture; the engine is a counting
    /// closure, so nothing here spawns a child.
    private static let toolID = "fix-agent"
    private static let fixture = CodingAgentDefinition(
        id: toolID,
        executablePath: "/usr/bin/agent-fix",
        arguments: ["--project", "/tmp/work"],
        projectDirectory: "/tmp/work",
        timeoutSeconds: nil,
        environment: nil,
        clause: nil)!

    /// The argv-derived sentence the provider renders for the fixture — the card's exact words.
    private static let sentence =
        "Run the coding agent 'fix-agent': /usr/bin/agent-fix --project /tmp/work in /tmp/work."

    /// The row summary the surface shows for the fixture — the fixed argv, never authored prose.
    private static let rowSummary = "/usr/bin/agent-fix --project /tmp/work"

    // MARK: - Acceptance 1: the composed default's facts

    /// **The composed default reports `agents=0`, `spawnsSubprocess=false`** — the D2
    /// narrowed promise as a fact the probe line folds: no agent is configured out of the
    /// box (an absent `coding-agents.json` is the empty registry), and the composed default
    /// cannot create a child. The agent count is the registry's own answer (effect, not
    /// reference); `spawnsSubprocess` is the wiring's declared value, the `requiresNetwork`
    /// analogue, declared for the **configuration** — nothing is wired, so nothing can spawn.
    func testTheComposedDefaultReportsAgentsZeroAndNoSpawn() async {
        let runner = CountingAgentRunner()
        let harness = await CodingAgentWiringHarness(
            agents: [],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            })
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let agents = await harness.wiring.listAgents()
        XCTAssertTrue(
            agents.isEmpty,
            "no agent is configured out of the box — an absent file is the empty registry")
        XCTAssertFalse(
            harness.wiring.spawnsSubprocess,
            "the composed default declares it spawns no child process — the D2 answer is "
                + "unreachable-by-default, never excepted")
        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "no card exists at composition time — the recipe presents nothing")
    }

    // MARK: - Acceptance 2: arm → confirm → invoke → audit reconstruct

    /// **The whole round trip, through the composed recipe over the real provider and a
    /// counting engine**: seed the registry, enable the agent, list the rows (the fixed argv
    /// as summary, outwardFacing by construction — an agent is never read-only — off until
    /// enabled), arm it, read the gate's exact sentence off the widget card, confirm with
    /// that sentence, and reconstruct the entries from the audit store — the arm's stop and
    /// the confirm's run, in ordinal order, the run carrying the card's sentence (the binding
    /// matched) — with the engine run counted on the engine's own log.
    func testArmConfirmInvokeAndAuditReconstructThroughTheComposedRecipe() async throws {
        let runner = CountingAgentRunner()
        let harness = await CodingAgentWiringHarness(
            agents: [Self.fixture],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            })
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let before = await harness.wiring.listAgents()
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(
            before[0].summary, Self.rowSummary,
            "the row's summary is the fixed argv, never authored prose")
        XCTAssertEqual(
            before[0].radius, .outwardFacing,
            "an agent is never read-only — the radius is outwardFacing by construction")
        XCTAssertFalse(before[0].isEnabled, "default off (M7) — absent is off")

        try await harness.enable(Self.toolID)
        let after = await harness.wiring.listAgents()
        XCTAssertTrue(after[0].isEnabled, "the persisted enablement folds into the row")

        try await harness.wiring.arm(CodingAgentProvider.providerID, Self.toolID)
        let card = harness.root.widgetStore.state.confirmation?.signal
        XCTAssertEqual(
            card?.sentence, Self.sentence,
            "the card carries the provider's argv-derived sentence verbatim — the gate's "
                + "render, re-presented after its own record")
        XCTAssertEqual(card?.providerID, CodingAgentProvider.providerID)
        XCTAssertEqual(card?.toolID, Self.toolID)

        await harness.wiring.confirm()
        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "an accepted confirm clears the card in the same fold")

        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.count, 2,
            "the arm's stop and the confirm's run, both recorded — the R8 every-decision rule")
        XCTAssertEqual(
            reloaded[0].decision, .refused,
            "the arm's withheld approval is recorded as refused — the stop for want of a yes")
        XCTAssertEqual(
            reloaded[1].decision, .confirmed,
            "the confirmed run reconstructs as confirmed — a human's yes was had")
        XCTAssertEqual(reloaded[1].providerID, CodingAgentProvider.providerID)
        XCTAssertEqual(reloaded[1].toolID, Self.toolID)
        XCTAssertEqual(
            reloaded[1].summary, Self.sentence,
            "the recorded summary is the sentence the card showed — the binding matched, so "
                + "the audit reconstructs exactly what the human approved")
        XCTAssertEqual(reloaded[0].id, 1, "the arm's stop is the first ordinal")
        XCTAssertEqual(reloaded[1].id, 2, "the confirm's run is the second ordinal")
        XCTAssertEqual(
            runner.callCount, 1,
            "the engine ran exactly once — the confirm's invoke, counted on the engine's own log")
        XCTAssertEqual(runner.calls.first?.executablePath, "/usr/bin/agent-fix")
        XCTAssertEqual(runner.calls.first?.arguments, ["--project", "/tmp/work"])
    }

    // MARK: - Acceptance 3: the in-flight refusal

    /// **The arm is refused while a session is in flight** — the flag is read lazily at arm
    /// time, the refusal throws the wiring's own error, no submission reaches the gate (the
    /// audit store stays empty) and no card can appear.
    func testTheInFlightRefusalHolds() async throws {
        let runner = CountingAgentRunner()
        let harness = await CodingAgentWiringHarness(
            agents: [Self.fixture],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            },
            sessionActive: { true })
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable(Self.toolID)

        do {
            try await harness.wiring.arm(CodingAgentProvider.providerID, Self.toolID)
            XCTFail("arming while a session is in flight must refuse")
        } catch let error as CodingAgentWiringError {
            XCTAssertEqual(error, .sessionInFlight)
        }

        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        let reloaded = await harness.auditStore.load()
        XCTAssertTrue(
            reloaded.isEmpty,
            "the refused arm records nothing — the refusal happens before any submission")
        XCTAssertEqual(runner.callCount, 0)
    }

    // MARK: - Acceptance 4: the binding mismatch re-prompt

    /// **A sentence that drifts between show and confirm is refused by attempting the call
    /// and re-prompts with a fresh render**: the mismatch is recorded with the bounded key,
    /// a fresh card appears with the provider's current sentence and a fresh generation
    /// token, and confirming the fresh card invokes — the binding's refusal is a re-prompt,
    /// never a dead end.
    func testTheBindingMismatchRePromptsWithAFreshRender() async throws {
        let provider = DriftingActionProvider(
            toolID: "drift",
            sentence: "Run the coding agent 'drift': /usr/bin/drift in /tmp/work.")
        let harness = await CodingAgentWiringHarness(
            agents: [], provider: { _ in provider })
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable("drift")

        try await harness.wiring.arm(CodingAgentProvider.providerID, "drift")
        let firstCard = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            firstCard.sentence, "Run the coding agent 'drift': /usr/bin/drift in /tmp/work.")

        // The sentence drifts between show and confirm — the edit lands after the arm.
        provider.setSentence(
            "Run the coding agent 'drift': /usr/bin/drift --force in /tmp/work.")
        await harness.wiring.confirm()

        let refused = await harness.auditStore.load()
        XCTAssertTrue(
            refused.contains { $0.summary == "gate.approvedSentenceMismatch" },
            "the mismatch is a recorded refusal — the declined decision reaches the audit log "
                + "with the bounded key, never silently")

        let freshCard = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            freshCard.sentence,
            "Run the coding agent 'drift': /usr/bin/drift --force in /tmp/work.",
            "the wiring re-presents a fresh card with the provider's current sentence — the "
                + "re-prompt is a render, never a dead end")
        XCTAssertNotEqual(
            freshCard.generation, firstCard.generation,
            "each presentation mints a fresh generation token")
        XCTAssertEqual(
            provider.runCount, 0,
            "the refused confirm never reached the acting half — refused by attempting the call")

        await harness.wiring.confirm()
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        XCTAssertEqual(
            provider.runCount, 1,
            "the fresh confirm invokes — the re-prompt is a re-ask, never a dead end")
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(reloaded.last?.decision, .confirmed)
        XCTAssertEqual(
            reloaded.last?.summary,
            "Run the coding agent 'drift': /usr/bin/drift --force in /tmp/work.")
    }

    // MARK: - Acceptance 5: the voice leg

    /// **A phrase row naming `vocca.agent` resolves `.toolCall` only for an enabled
    /// tool**: while the tool is disabled the phrase resolves to nothing and the provider is
    /// never reached (a direct action attempt is declined by the gate with the bounded key
    /// before any describe, and the engine's log stays empty); once enabled, the phrase
    /// resolves to the agent's invocation, the card carries the provider's sentence, and the
    /// agent wiring's confirm runs the engine exactly once.
    func testTheVoiceLegResolvesOnlyAnEnabledAgentAndNeverReachesADisabledOne() async throws {
        let runner = CountingAgentRunner()
        let harness = await CodingAgentWiringHarness(
            agents: [Self.fixture],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            })
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let phraseStore = IntentPhraseStore(
            directory: harness.directory.appendingPathComponent("phrases"))
        try await phraseStore.save(
            IntentPhraseFile(
                phrases: [
                    PhraseIntentRow(
                        phrase: "run the fix agent",
                        providerID: CodingAgentProvider.providerID,
                        toolID: Self.toolID)
                ]))
        let intentWiring = AppBootstrap.composeIntentWiring(
            configStore: harness.configStore,
            provider: harness.provider,
            executor: harness.wiring.executor,
            resolverProvider: {
                PhraseIntentResolver(rows: await phraseStore.load().phrases)
            },
            root: harness.root)

        // Disabled: the phrase resolves to nothing, and the provider is never reached.
        let resolution = await intentWiring.resolve("run the fix agent")
        XCTAssertEqual(
            resolution, .none,
            "the seeded phrase resolves to nothing while its tool is disabled")
        let direct = try XCTUnwrap(
            ActionInvocation(providerID: CodingAgentProvider.providerID, toolID: Self.toolID))
        let reply = await intentWiring.performAction(direct, "")
        XCTAssertEqual(reply, "Cancelled.", "the declined voice action speaks the refused ack")
        let declined = await harness.auditStore.load()
        XCTAssertEqual(
            declined.last?.summary, "gate.toolNotEnabled",
            "a disabled agent is declined before any describe — the M7 never-read rule, "
                + "recorded with its bounded key")
        XCTAssertEqual(
            runner.callCount, 0,
            "the disabled agent never reached the engine — never-read, counted")

        // Enabled: the same phrase resolves to the agent's invocation, the card appears with
        // the provider's sentence, and the agent wiring's confirm runs the engine.
        try await harness.enable(Self.toolID)
        let enabledResolution = await intentWiring.resolve("run the fix agent")
        guard case .toolCall(let invocation) = enabledResolution else {
            return XCTFail(
                "the enabled agent's phrase must resolve to a tool call, got "
                    + "\(enabledResolution)")
        }
        XCTAssertEqual(invocation.providerID, CodingAgentProvider.providerID)
        XCTAssertEqual(invocation.toolID, Self.toolID)

        let cardReply = await intentWiring.performAction(invocation, "")
        XCTAssertNil(
            cardReply,
            "a card is up — the card is the answer, and no spoken ack stands in for it")
        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(card.sentence, Self.sentence)
        XCTAssertEqual(card.providerID, CodingAgentProvider.providerID)

        await harness.wiring.confirm()
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        XCTAssertEqual(
            runner.callCount, 1,
            "the voice-confirmed agent ran exactly once — counted on the engine's own log")
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(reloaded.last?.decision, .confirmed)
        XCTAssertEqual(
            reloaded.last?.summary, Self.sentence,
            "the binding matched — the sentence the card showed is the sentence the gate "
                + "acted on and the log recorded")
    }

    /// **The intent store refuses only `dev.vocca.shell`** — a phrase row naming
    /// `vocca.agent` is accepted at load (the voice leg can reach an enabled agent), and
    /// the shell refusal is the store's one loud refusal.
    func testTheIntentStoreRefusesOnlyTheShellProvider() throws {
        let refusals = RefusalRecorder()
        let agentRow = PhraseIntentRow(
            phrase: "run the fix agent",
            providerID: CodingAgentProvider.providerID,
            toolID: "fix-agent")
        let shellRow = PhraseIntentRow(
            phrase: "wipe the log",
            providerID: ShellProvider.providerID,
            toolID: "wipe")
        let auditRow = PhraseIntentRow(
            phrase: "clear the audit log",
            providerID: "dev.vocca.audit",
            toolID: "audit.clear")
        let data = try IntentPhraseStore.encode(
            IntentPhraseFile(phrases: [agentRow, shellRow, auditRow]))

        let file = IntentPhraseStore.decode(data, onInvalid: refusals.record)

        XCTAssertEqual(
            file.phrases, [agentRow, auditRow],
            "the agent row and the audit row load — the agent id is NOT refused")
        XCTAssertEqual(
            refusals.recorded.count, 1,
            "exactly one refusal — the shell row, and only the shell row")
        XCTAssertTrue(
            refusals.recorded[0].contains("a shell command cannot be reached by voice"),
            "the refusal names the shell rule")
    }

    // MARK: - Acceptance 6: the stale-row reconcile

    /// **A registry row edited after the provider's construction shows on the tab and
    /// resolves to the read-only refusal, never a trap**: the surface reads the registry per
    /// call (a new agent appears on the tab without a relaunch, its enablement tolerated like
    /// every stale row), while the provider's tool list is fixed at construction — the late
    /// row describes as the read-only refusal and previews as the same sentence, and the
    /// engine is never reached.
    func testAStaleRegistryRowShowsOnTheTabAndAnswersTheReadOnlyRefusal() async throws {
        let runner = CountingAgentRunner()
        let harness = await CodingAgentWiringHarness(
            agents: [Self.fixture],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            })
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        // The registry is edited after the provider's construction: a second agent appears.
        let late = CodingAgentDefinition(
            id: "late-agent",
            executablePath: "/usr/bin/late-agent",
            arguments: ["--dry"],
            projectDirectory: "/tmp/late")!
        try await harness.registry.save(CodingAgentFile(agents: [Self.fixture, late]))

        let rows = await harness.wiring.listAgents()
        XCTAssertEqual(
            rows.map(\.toolID), [Self.toolID, "late-agent"],
            "the surface reads the registry per call — an edit shows on the tab, no relaunch")
        XCTAssertEqual(rows[1].summary, "/usr/bin/late-agent --dry")
        XCTAssertEqual(rows[1].radius, .outwardFacing)
        XCTAssertFalse(rows[1].isEnabled)

        // The surface's enablement tolerates the stale row (the MCP precedent — never pruned).
        try await harness.enable("late-agent")
        let afterEnable = await harness.wiring.listAgents()
        XCTAssertTrue(
            afterEnable[1].isEnabled,
            "the enablement row for a row the provider does not serve is tolerated, never pruned")

        // The provider's tool list is fixed at construction: the late row describes as the
        // read-only refusal — nothing will happen, so nothing needs confirming — never a trap.
        let summary = await harness.provider.describe(
            ActionInvocation(providerID: CodingAgentProvider.providerID, toolID: "late-agent")!)
        XCTAssertEqual(summary.blastRadius, .readOnly)
        XCTAssertTrue(
            summary.sentence.contains("does not serve the agent 'late-agent'"),
            "the refusal names the unserved agent and says nothing will happen")

        let preview = await harness.wiring.preview(
            CodingAgentProvider.providerID, "late-agent")
        XCTAssertEqual(
            preview, summary.sentence,
            "the dry-run renders the same refusal — the surface never traps on a stale row")
        XCTAssertEqual(
            runner.callCount, 0,
            "no engine run — the refusal is a refusal, never an invocation")
    }
}

/// The wiring test's composition: the real stores over fresh temporary directories, the real
/// `CodingAgentRegistry` (seeded per test), the injected provider (the real
/// `CodingAgentProvider` over a counting engine closure in the default shape), a real root
/// over the suite's shared fakes, and the recipe composed exactly as `configure` will — the
/// call itself is the compile pin over the parameter list.
@MainActor
private final class CodingAgentWiringHarness<Provider: ActionProvider> {
    let directory: URL
    let configStore: ActionConfigStore
    let auditStore: FileSystemActionAuditStore
    let registry: CodingAgentRegistry
    let root: DictationLoopRoot
    let wiring: CodingAgentWiring<Provider>
    let provider: Provider

    /// - Parameters:
    ///   - agents: The agents seeded into the registry's temp directory. `[]` seeds
    ///     nothing — the absent file, the true first-launch default.
    ///   - provider: The provider the wiring submits through — the real
    ///     `CodingAgentProvider.load` over the seeded registry in the default shape; a test
    ///     injects its own when it must drift the sentence.
    ///   - sessionActive: The in-flight read the wiring consults lazily at arm time.
    init(
        agents: [CodingAgentDefinition],
        provider: @escaping (CodingAgentRegistry) async -> Provider,
        sessionActive: @escaping @Sendable @MainActor () -> Bool = { false }
    ) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-agent-wiring-\(UUID().uuidString)")
        let configStore = ActionConfigStore(
            directory: directory.appendingPathComponent("config"))
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let registry = CodingAgentRegistry(
            directory: directory.appendingPathComponent("agents"))
        if !agents.isEmpty {
            try? await registry.save(CodingAgentFile(agents: agents))
        }

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

        let provider = await provider(registry)
        let wiring = AppBootstrap.composeCodingAgentWiring(
            configStore: configStore,
            auditStore: auditStore,
            registry: registry,
            provider: provider,
            sessionActive: sessionActive,
            root: root)

        self.directory = directory
        self.configStore = configStore
        self.auditStore = auditStore
        self.registry = registry
        self.root = root
        self.provider = provider
        self.wiring = wiring
    }

    /// Persists the enablement row for one agent — membership in the shared config store,
    /// the same rows the Actions tab's toggles write.
    func enable(_ toolID: String) async throws {
        let config = await configStore.load()
        let row = ActionConfigEnablementRow(
            providerID: CodingAgentProvider.providerID, toolID: toolID)
        try await configStore.save(
            ActionConfig(servers: config.servers, enablement: config.enablement + [row]))
    }
}

/// The engine's call log — the counted "the agent ran exactly once" fact, and the exact
/// configurations the runs asked for. A class because the `Mutex` it owns is non-`Copyable` —
/// the `FailsTheTestIfInvokedRunner` shape, without the failing half: this suite counts.
private final class CountingAgentRunner: Sendable {
    private let log = Mutex<[ShellExecutor.Configuration]>([])

    func run(_ configuration: ShellExecutor.Configuration) async -> ShellExecutionResult {
        log.withLock { $0.append(configuration) }
        return ShellExecutionResult(
            status: .succeeded(exitCode: 0),
            standardOutput: Data(),
            standardError: Data(),
            outputWasTruncated: false)
    }

    var callCount: Int {
        log.withLock(\.count)
    }

    var calls: [ShellExecutor.Configuration] {
        log.withLock { $0 }
    }
}

/// A provider whose sentence the test can drift between the arm and the confirm — the
/// binding-mismatch re-prompt's driver. The acting half counts runs; nothing spawns.
private final class DriftingActionProvider: ActionProvider {
    let toolIDs: [String]
    private let sentence: Mutex<String>
    private let runs = Mutex(0)

    init(toolID: String, sentence: String) {
        self.toolIDs = [toolID]
        self.sentence = Mutex(sentence)
    }

    func setSentence(_ new: String) {
        sentence.withLock { $0 = new }
    }

    func describe(_ invocation: ActionInvocation) async -> ActionSummary {
        ActionSummary(sentence: sentence.withLock { $0 }, blastRadius: .outwardFacing)
    }

    func invoke(_ invocation: ActionInvocation, confirmation: ActionConfirmation) async
        -> ActionOutcome
    {
        runs.withLock { $0 += 1 }
        return .succeeded
    }

    var runCount: Int {
        runs.withLock { $0 }
    }
}

/// The intent store's refusal log — the loudness asserted rather than hoped.
private final class RefusalRecorder {
    private let messages = Mutex<[String]>([])

    func record(_ message: String) {
        messages.withLock { $0.append(message) }
    }

    var recorded: [String] {
        messages.withLock { $0 }
    }
}

/// A level source that never moves — this suite's `QuietLevelSource` (each file owns its
/// spelling).
private struct QuietLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}