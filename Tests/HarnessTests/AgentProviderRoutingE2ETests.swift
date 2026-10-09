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
import VoccaUI
import XCTest

/// **The routed intent leg, end to end** (`intent-provider-routing` / `provider-dispatch` E1,
/// E2, E3): a spoken phrase naming an enabled `vocca.agent` row reaches the agent provider
/// through the router `configure` composes — card first, a run only after Confirm.
///
/// The harness assembles the chain **exactly as `configure` does** (the G1 pin in
/// `AppBootstrapWiringTests` carries the "configure assembles it this way" claim): the REAL
/// audit wiring over `AuditActionProvider`, the router in `root.intentWiring` built over it
/// with the lazy weak-root lookup of `root.agentIntentWiring`, and — landing **after** the
/// router, the agent launch task's order — the REAL `CodingAgentWiring` over the real
/// `CodingAgentProvider` and its intent wiring over the **same** executor, stored in the
/// root's new slot. One audit store, one config store, one per-turn resolver provider, as in
/// `configure`. The engine is a counting closure: nothing here spawns a child.
@MainActor
final class AgentProviderRoutingE2ETests: XCTestCase {

    // MARK: - Fixtures

    /// The placeholder row's id.
    private static let claudeID = "claude"

    /// The full utterance — trigger words and all; the phrase row matches it exactly.
    private static let utterance = "ask claude to summarize the open PRs"

    /// The detection's fixed answer — the "focused app's project" the blank row resolves to.
    private static let detectedPath = "/tmp/routed-project"

    /// **The placeholder row with a blank directory**: the argv carries `<task>` (the full
    /// utterance fills it) and the directory resolves through detection, so the card carries
    /// both enrichments of the agent leg.
    private static let claude = CodingAgentDefinition(
        id: claudeID,
        executablePath: "/opt/homebrew/bin/claude",
        arguments: ["-p", KnownAgentPresets.taskPlaceholder],
        projectDirectory: nil,
        timeoutSeconds: 30,
        environment: nil,
        clause: nil)!

    /// The card's exact words: the argv with the full utterance, in the detected directory.
    private static let cardSentence =
        "Run the coding agent 'claude': /opt/homebrew/bin/claude -p ask claude to summarize "
        + "the open PRs in /tmp/routed-project."

    // MARK: - E1: phrase → agent card → Confirm runs it once

    /// **A phrase naming the agent row reaches the agent card; only Confirm runs it** — the
    /// card shows the argv-derived sentence with the full utterance as `<task>` and the
    /// resolved directory; nothing ran and the record is `[.refused]` (a withheld
    /// submission); the agent wiring's confirm — the call `actionConfirm` makes for a
    /// `vocca.agent` card — runs the engine exactly once with the card's argv and directory,
    /// and the record becomes `[.refused, .confirmed]`, every entry the agent's.
    func testAPhraseReachesTheAgentCardAndOnlyConfirmRunsIt() async throws {
        let harness = try await RoutingHarness(agents: [Self.claude])
        defer { harness.tearDown() }
        try await harness.enable(CodingAgentProvider.providerID, Self.claudeID)
        try await harness.phrase(Self.utterance, CodingAgentProvider.providerID, Self.claudeID)
        let router = try XCTUnwrap(harness.root.intentWiring)

        let resolution = await router.resolve(Self.utterance)
        guard case .toolCall(let invocation) = resolution else {
            return XCTFail("the enabled agent row's phrase must resolve, got \(resolution)")
        }
        XCTAssertEqual(invocation.providerID, CodingAgentProvider.providerID)
        XCTAssertEqual(invocation.toolID, Self.claudeID)

        let reply = await router.performAction(invocation, Self.utterance)
        // First, before the card is even read: nothing ran before the click.
        XCTAssertEqual(harness.runner.callCount, 0, "nothing runs before the click")
        XCTAssertNil(reply, "a card is up — the card is the answer")
        let card = try XCTUnwrap(
            harness.root.widgetStore.state.confirmation?.signal,
            "the router must reach the agent wiring — the audit wiring presents no agent card")
        XCTAssertEqual(card.providerID, CodingAgentProvider.providerID)
        XCTAssertEqual(card.sentence, Self.cardSentence, "the argv-derived sentence, verbatim")
        XCTAssertEqual(card.taskText, Self.utterance, "the FULL utterance fills <task>")
        XCTAssertEqual(card.resolvedDirectory, Self.detectedPath, "the resolved directory")
        let armed = await harness.auditStore.load()
        XCTAssertEqual(armed.map(\.decision), [.refused], "the withheld submission's record")

        await harness.agentWiring.confirm()

        XCTAssertNil(harness.root.widgetStore.state.confirmation, "the confirm cleared the card")
        XCTAssertEqual(harness.runner.callCount, 1, "the confirmed run happened exactly once")
        XCTAssertEqual(
            harness.runner.calls.first?.arguments, ["-p", Self.utterance],
            "the argv that ran is the argv the card showed")
        XCTAssertEqual(
            harness.runner.calls.first?.currentDirectoryURL,
            URL(fileURLWithPath: Self.detectedPath),
            "the child starts where the card said")
        let confirmed = await harness.auditStore.load()
        XCTAssertEqual(confirmed.map(\.decision), [.refused, .confirmed])
        XCTAssertEqual(
            confirmed.last?.summary, card.sentence,
            "the confirmed record carries exactly the card's sentence")
        XCTAssertEqual(
            Set(confirmed.map(\.providerID)), [CodingAgentProvider.providerID],
            "the whole chain is the agent executor's — nothing went through the audit wiring")
    }

    /// **Decline runs nothing** — the agent wiring's decline records the second refusal and
    /// clears the card; the engine is never reached.
    func testDeclineRunsNothing() async throws {
        let harness = try await RoutingHarness(agents: [Self.claude])
        defer { harness.tearDown() }
        try await harness.enable(CodingAgentProvider.providerID, Self.claudeID)
        try await harness.phrase(Self.utterance, CodingAgentProvider.providerID, Self.claudeID)
        let router = try XCTUnwrap(harness.root.intentWiring)

        guard case .toolCall(let invocation) = await router.resolve(Self.utterance) else {
            return XCTFail("the enabled agent row's phrase must resolve")
        }
        _ = await router.performAction(invocation, Self.utterance)
        XCTAssertNotNil(harness.root.widgetStore.state.confirmation)

        await harness.agentWiring.decline()

        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        XCTAssertEqual(harness.runner.callCount, 0, "a declined card never runs")
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(reloaded.map(\.decision), [.refused, .refused])
    }

    /// **The audit wiring's confirm never runs an agent card** — the router's `executor` and
    /// `policy` are the audit wiring's, so the agent card must be answered through the agent
    /// chain; answering it through the audit wiring's confirm reaches the audit provider,
    /// which does not serve `vocca.agent`, and the engine is never reached.
    func testTheAuditWiringsConfirmNeverRunsAnAgentCard() async throws {
        let harness = try await RoutingHarness(agents: [Self.claude])
        defer { harness.tearDown() }
        try await harness.enable(CodingAgentProvider.providerID, Self.claudeID)
        try await harness.phrase(Self.utterance, CodingAgentProvider.providerID, Self.claudeID)
        let router = try XCTUnwrap(harness.root.intentWiring)

        guard case .toolCall(let invocation) = await router.resolve(Self.utterance) else {
            return XCTFail("the enabled agent row's phrase must resolve")
        }
        _ = await router.performAction(invocation, Self.utterance)
        XCTAssertNotNil(harness.root.widgetStore.state.confirmation)

        await harness.actionWiring.confirm()

        XCTAssertEqual(
            harness.runner.callCount, 0,
            "the audit wiring's confirm cannot run the agent — only the agent chain can")
        let reloaded = await harness.auditStore.load()
        XCTAssertFalse(
            reloaded.contains { $0.decision == .confirmed },
            "nothing was confirmed through the audit provider")
    }

    /// **A placeholder row reached with an empty utterance is refused before the card** —
    /// "Cancelled.", no card, no run, the refusal recorded.
    func testAnEmptyUtteranceOnAPlaceholderRowIsCancelledWithNoCard() async throws {
        let harness = try await RoutingHarness(agents: [Self.claude])
        defer { harness.tearDown() }
        try await harness.enable(CodingAgentProvider.providerID, Self.claudeID)
        try await harness.phrase(Self.utterance, CodingAgentProvider.providerID, Self.claudeID)
        let router = try XCTUnwrap(harness.root.intentWiring)

        guard case .toolCall(let invocation) = await router.resolve(Self.utterance) else {
            return XCTFail("the enabled agent row's phrase must resolve")
        }
        let reply = await router.performAction(invocation, "")

        XCTAssertEqual(reply, "Cancelled.", "the agent wiring's pre-card refusal")
        XCTAssertNil(harness.root.widgetStore.state.confirmation, "never a card")
        XCTAssertEqual(harness.runner.callCount, 0, "never a run")
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(reloaded.map(\.decision), [.refused])
        XCTAssertEqual(reloaded.first?.providerID, CodingAgentProvider.providerID)
    }

    /// **Through the real converse closures: the agent card answers "Confirm on screen.",
    /// and a second voice action while it is up is refused — still one card.** The closures
    /// read `root.intentWiring` (the router) at call time; the agent wiring's card-up guard
    /// answers nil, which the converse wrapper turns into the confirm line.
    func testTheConverseClosuresSpeakConfirmOnScreenAndKeepOneCard() async throws {
        let harness = try await RoutingHarness(agents: [Self.claude])
        defer { harness.tearDown() }
        try await harness.enable(CodingAgentProvider.providerID, Self.claudeID)
        try await harness.phrase(Self.utterance, CodingAgentProvider.providerID, Self.claudeID)
        let closures = harness.converseClosures()

        let resolution = await closures.provider(Self.utterance)
        guard case .toolCall(let invocation) = resolution else {
            return XCTFail("the converse provider must resolve through the router")
        }
        let first = await closures.handler(invocation, Self.utterance)
        XCTAssertEqual(first, AppBootstrap.confirmOnScreenReply)
        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(card.providerID, CodingAgentProvider.providerID)

        let second = await closures.handler(invocation, Self.utterance)
        XCTAssertEqual(
            second, AppBootstrap.confirmOnScreenReply,
            "the card-up refusal answers nil, spoken as the confirm line")
        let still = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(still.generation, card.generation, "still ONE card — never swapped")
        XCTAssertEqual(still.sentence, card.sentence)
        XCTAssertEqual(harness.runner.callCount, 0)
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.map(\.decision), [.refused],
            "the second action was refused before any submission — no second record")

        await harness.agentWiring.confirm()
        XCTAssertEqual(harness.runner.callCount, 1, "one card, one run")
    }

    // MARK: - E2: the default posture

    /// **Agent rows enabled and phrases present, but no click across N voice turns → the
    /// engine never runs** — the card is the only route, and nobody pressed it; a decline in
    /// the middle and further turns change nothing.
    func testNoClickAcrossManyVoiceTurnsNeverRuns() async throws {
        let harness = try await RoutingHarness(agents: [Self.claude])
        defer { harness.tearDown() }
        try await harness.enable(CodingAgentProvider.providerID, Self.claudeID)
        try await harness.phrase(Self.utterance, CodingAgentProvider.providerID, Self.claudeID)
        let closures = harness.converseClosures()

        for turn in 1...5 {
            if turn == 3 { await harness.agentWiring.decline() }
            guard case .toolCall(let invocation) = await closures.provider(Self.utterance)
            else {
                return XCTFail("turn \(turn) must resolve")
            }
            let reply = await closures.handler(invocation, Self.utterance)
            XCTAssertEqual(reply, AppBootstrap.confirmOnScreenReply, "turn \(turn)")
            XCTAssertEqual(harness.runner.callCount, 0, "no click, no run — turn \(turn)")
        }
        XCTAssertEqual(harness.runner.callCount, 0)
    }

    /// **No phrase file → nothing resolves** — the router's resolution is the audit wiring's
    /// over the absent file: `.none`, the converse driver's echo.
    func testNoPhraseFileResolvesNothing() async throws {
        let harness = try await RoutingHarness(agents: [Self.claude])
        defer { harness.tearDown() }
        try await harness.enable(CodingAgentProvider.providerID, Self.claudeID)
        let closures = harness.converseClosures()

        let routed = await harness.root.intentWiring?.resolve(Self.utterance)
        XCTAssertEqual(routed, IntentResolution.none)
        let spoken = await closures.provider(Self.utterance)
        XCTAssertEqual(spoken, IntentResolution.none, "the converse driver echoes")
        XCTAssertEqual(harness.runner.callCount, 0)
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
    }

    /// **The composed default spawns no child** — an empty registry: no agents, and every
    /// wiring on the chain declares `spawnsSubprocess == false`.
    func testTheComposedDefaultSpawnsNoSubprocess() async throws {
        let harness = try await RoutingHarness(agents: [])
        defer { harness.tearDown() }

        let agents = await harness.agentWiring.listAgents()
        XCTAssertTrue(agents.isEmpty, "agents=0 — an absent file is the empty registry")
        XCTAssertEqual(harness.root.intentWiring?.spawnsSubprocess, false)
        XCTAssertEqual(harness.root.agentIntentWiring?.spawnsSubprocess, false)
        XCTAssertFalse(harness.agentWiring.spawnsSubprocess)
    }

    // MARK: - E3: a foreign audit.clear never deletes

    /// **A foreign `audit.clear` row under `vocca.agent` never deletes audit entries** — end
    /// to end through the router, with the agent side composed (the agent provider does not
    /// know the tool) and absent (the audit wiring's provider does not serve `vocca.agent`):
    /// every seeded entry survives and nothing runs.
    func testAForeignAuditClearUnderTheAgentProviderNeverDeletes() async throws {
        for agentSideComposed in [true, false] {
            let harness = try await RoutingHarness(agents: [Self.claude])
            defer { harness.tearDown() }
            let foreignTool = AuditActionProvider.clearToolID
            try await harness.enable(CodingAgentProvider.providerID, foreignTool)
            try await harness.phrase(
                "clear the log", CodingAgentProvider.providerID, foreignTool)
            let seeded = try await harness.seedAudit(3)
            if !agentSideComposed { harness.root.agentIntentWiring = nil }
            let router = try XCTUnwrap(harness.root.intentWiring)

            guard case .toolCall(let invocation) = await router.resolve("clear the log") else {
                return XCTFail("the foreign row's phrase must resolve (\(agentSideComposed))")
            }
            XCTAssertEqual(invocation.providerID, CodingAgentProvider.providerID)
            XCTAssertEqual(invocation.toolID, foreignTool)
            _ = await router.performAction(invocation, "clear the log")
            if let card = harness.root.widgetStore.state.confirmation?.signal {
                // Whatever card appears is answered through the chain the shell would pick.
                if card.providerID == CodingAgentProvider.providerID {
                    await harness.agentWiring.confirm()
                } else {
                    await harness.actionWiring.confirm()
                }
            }

            let after = await harness.auditStore.load()
            for entry in seeded {
                XCTAssertTrue(
                    after.contains(entry),
                    "seeded entry \(entry.id) survives (agent side composed: \(agentSideComposed))")
            }
            XCTAssertEqual(harness.runner.callCount, 0, "nothing ran (\(agentSideComposed))")
        }
    }
}

// MARK: - The harness

/// The routed chain, assembled as `configure` assembles it: the synchronous half (the audit
/// wiring, its intent wiring, the router in `root.intentWiring` with the weak-root lookup),
/// then the launch-task half (the agent wiring and its intent wiring over the same executor,
/// stored in `root.agentIntentWiring`) — built in that order so a router that captured the
/// agent slot eagerly would hold nil.
@MainActor
private final class RoutingHarness {
    let directory: URL
    let configStore: ActionConfigStore
    let auditStore: FileSystemActionAuditStore
    let registry: CodingAgentRegistry
    let phraseStore: IntentPhraseStore
    let root: DictationLoopRoot
    let actionWiring: ActionWiring<AuditActionProvider>
    let agentWiring: CodingAgentWiring<CodingAgentProvider>
    let runner = CountingAgentRunner()

    init(agents: [CodingAgentDefinition]) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-agent-routing-\(UUID().uuidString)")
        let configStore = ActionConfigStore(
            directory: directory.appendingPathComponent("config"))
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let registry = CodingAgentRegistry(
            directory: directory.appendingPathComponent("agents"))
        if !agents.isEmpty {
            try await registry.save(CodingAgentFile(agents: agents))
        }
        let phraseStore = IntentPhraseStore(
            directory: directory.appendingPathComponent("phrases"))

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
            liveLevel: RoutingQuietLevelSource(),
            sessionKind: .dictation)
        root.agentRegistry = registry

        let detectedPath = "/tmp/routed-project"
        let activeProjectDirectory: @Sendable () async -> String? = { detectedPath }
        let sessionActive: @Sendable @MainActor () -> Bool = { false }
        let intentResolverProvider = AppBootstrap.composeIntentResolverProvider(
            store: phraseStore)

        // configure's synchronous half.
        let actionProvider = AuditActionProvider(store: auditStore)
        let actionWiring = AppBootstrap.composeActionWiring(
            configStore: configStore,
            auditStore: auditStore,
            provider: actionProvider,
            sessionActive: sessionActive,
            root: root)
        let intentWiring = AppBootstrap.composeIntentWiring(
            configStore: configStore,
            provider: actionProvider,
            executor: actionWiring.executor,
            resolverProvider: intentResolverProvider,
            root: root,
            activeProjectDirectory: activeProjectDirectory)
        root.intentWiring = AppBootstrap.routeIntentWiring(
            audit: intentWiring, agent: { [weak root] in root?.agentIntentWiring })

        // configure's agent launch task — landing after the router.
        let agentFile = await registry.load()
        let agentProvider = CodingAgentProvider(agents: agentFile.agents, run: runner.run)
        let agentWiring = AppBootstrap.composeCodingAgentWiring(
            configStore: configStore,
            auditStore: auditStore,
            registry: registry,
            provider: agentProvider,
            sessionActive: sessionActive,
            root: root,
            activeProjectDirectory: activeProjectDirectory)
        root.agentWiring = agentWiring
        root.agentExecutor = agentWiring.executor
        root.agentIntentWiring = AppBootstrap.composeIntentWiring(
            configStore: configStore,
            provider: agentProvider,
            executor: agentWiring.executor,
            resolverProvider: intentResolverProvider,
            root: root,
            activeProjectDirectory: activeProjectDirectory)

        self.directory = directory
        self.configStore = configStore
        self.auditStore = auditStore
        self.registry = registry
        self.phraseStore = phraseStore
        self.root = root
        self.actionWiring = actionWiring
        self.agentWiring = agentWiring
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The converse driver's two intent slots, over this root — `configure`'s closures.
    func converseClosures() -> (
        provider: @Sendable (String) async -> IntentResolution?,
        handler: @Sendable (ActionInvocation, String) async -> String?
    ) {
        let box = RoutingRootBox(root)
        return AppBootstrap.composeConverseIntentClosures(root: { box.value })
    }

    /// Persists one enablement row — the Actions tab's toggle.
    func enable(_ providerID: String, _ toolID: String) async throws {
        let config = await configStore.load()
        try await configStore.save(
            ActionConfig(
                servers: config.servers,
                enablement: config.enablement + [
                    ActionConfigEnablementRow(providerID: providerID, toolID: toolID)
                ]))
    }

    /// Appends one phrase row to the phrase file.
    func phrase(_ phrase: String, _ providerID: String, _ toolID: String) async throws {
        let file = await phraseStore.load()
        try await phraseStore.save(
            IntentPhraseFile(
                phrases: file.phrases + [
                    PhraseIntentRow(phrase: phrase, providerID: providerID, toolID: toolID)
                ]))
    }

    /// Seeds `count` real audit entries — refusals, a real event needing no provider.
    func seedAudit(_ count: Int) async throws -> [ActionAuditEntry] {
        let seed = try XCTUnwrap(ActionInvocation(providerID: "dev.vocca.seed", toolID: "seed"))
        var entries: [ActionAuditEntry] = []
        for index in 1...count {
            entries.append(
                try await auditStore.record(
                    seed, decision: .declined(.toolNotEnabled), at: .seconds(index)))
        }
        return entries
    }
}

/// The weak root the converse closures' accessor reads — `configure`'s weak box shape.
private final class RoutingRootBox: @unchecked Sendable {
    weak var value: DictationLoopRoot?
    init(_ value: DictationLoopRoot) { self.value = value }
}

/// The engine's call log — the counted "the agent ran" fact (the `AgentWiringCwdTests`
/// shape: each file owns its spelling).
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

/// A level source that never moves.
private struct RoutingQuietLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}
