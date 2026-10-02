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

/// **The arm-time working-directory resolution's wiring contract** (`agent-wiring-cwd`,
/// spec acceptances 1-6): the injected `activeProjectDirectory` closure threaded through the
/// composed agent wiring's arm → card → confirm round trip, the intent leg's S2 enrichment,
/// the explicit-wins rule, the one-resolution contract, and the editor caption — driven over
/// real temp-directory stores and the **real** `CodingAgentProvider` over a counting engine
/// closure (nothing here spawns a child).
///
/// ## The nil-directory row's fixture — constructed, and reachable through the registry
///
/// A row whose `projectDirectory` is nil is the shipped spelling of the editor's empty field
/// (the caption's contract — "leave empty to detect the focused app's project"): valid at
/// construction, valid in the file (the key absent, or blank reading as nil), and served by
/// the registry's own validation pass. So the fixture is a plain constructed row, the registry
/// file holds it, and the provider is loaded **from that registry** — the reachable path, not
/// a double's opinion of it. The closure's answer is a recording fake — a fixed path, a
/// settable answer, a counted call log.
///
/// ## The contract, acceptance by acceptance
///
/// 1. A **nil-directory** row: arm → the card shows the resolved directory verbatim (the fake's
///    fixed path, in the provider's own argv-derived sentence); confirm runs the engine in
///    it (`currentDirectoryURL`); the audit record shows the sentence.
/// 2. An **explicit** row: detection is never consulted — the recording fake proves zero
///    calls (explicit wins, G2).
/// 3. **One resolution per arm**: the fake counts exactly one call across the whole
///    arm → post-record re-render → confirm round trip — the four renders share the
///    carried value (G3).
/// 4. A detection change **mid-card** cannot move the run: the confirmation carries the
///    arm-time value, and a fake whose answer changed confirms in the original directory.
/// 5. The **voice leg** (S2): a phrase-armed nil-directory row resolves and runs in the
///    detected directory through the composed intent wiring; without the closure wired, the
///    same row renders the clause-less sentence (S1 — the child runs in Vocca's cwd, visible in
///    the sentence, never hidden). Without **detection**, the direct arm is clause-less too,
///    and the confirmed run carries no `currentDirectoryURL`.
/// 6. The **composed default** facts are unchanged (`agents=0 spawnsSubprocess=false` —
///    the nil-shaped default composes byte-identically), and the editor caption shipped.
@MainActor
final class AgentWiringCwdTests: XCTestCase {

    // MARK: - Fixtures

    /// The nil-directory row fixture's id — the row the editor would spell with an empty
    /// directory.
    private static let detectID = "detect-me"

    /// The recording fake's fixed answer — the "detected project" the arm resolves to.
    private static let detectedPath = "/tmp/detected-project"

    /// The mid-card change's answer — must never reach the run (acceptance 4).
    private static let changedPath = "/tmp/other-project"

    /// The explicit row — the pinned agent the fixture row mirrors (acceptance 2's row).
    private static let pinnedRow = CodingAgentDefinition(
        id: "pinned",
        executablePath: "/usr/bin/agent-fix",
        arguments: ["--project", "/tmp/work"],
        projectDirectory: "/tmp/work",
        timeoutSeconds: nil,
        environment: nil,
        clause: nil)!

    /// The explicit row's argv-derived sentence — the card's exact words.
    private static let pinnedSentence =
        "Run the coding agent 'pinned': /usr/bin/agent-fix --project /tmp/work in /tmp/work."

    /// **The nil-directory row — constructed, never decoded**: the editor's empty Project
    /// directory field is this row (the caption's contract), valid at construction and
    /// served by the registry's own validation pass — the reachable shape, not the
    /// shape-tolerant decode of a skipped row.
    private static let emptyRow = CodingAgentDefinition(
        id: "detect-me",
        executablePath: "/usr/bin/true",
        arguments: [],
        projectDirectory: nil,
        timeoutSeconds: 30,
        environment: nil,
        clause: nil)!

    /// The nil-directory row's sentence once the detection resolved it — the `in <dir>` clause
    /// renders the fake's path verbatim.
    private static let detectedSentence =
        "Run the coding agent 'detect-me': /usr/bin/true in /tmp/detected-project."

    /// The nil-directory row's sentence when no detection is available — clause-less (S1).
    private static let clauseLessSentence =
        "Run the coding agent 'detect-me': /usr/bin/true."

    // MARK: - Acceptance 1: the empty row resolves at arm and runs in the detection

    /// **A nil-directory row: arm → the sentence shows the resolved directory verbatim; confirm
    /// runs in it; the audit record shows the sentence.**
    ///
    /// The fake's fixed path appears in the provider's own argv-derived sentence — the
    /// card a user sees — and the confirmed run's configuration carries the same path as
    /// `currentDirectoryURL`, so the child starts where the sentence said it would; the
    /// audit entry reconstructs the same sentence (the binding matched). The row is served
    /// through the **registry** — the reachable shape, the one the editor's empty field
    /// saves.
    func testAnEmptyRowResolvesAtArmAndRunsInTheDetectedDirectory() async throws {
        let runner = CountingAgentRunner()
        let detection = RecordingDetection(answer: Self.detectedPath)
        let harness = await AgentWiringCwdHarness(
            agents: [Self.emptyRow],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            },
            detection: detection)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable(Self.detectID)

        let loaded = await harness.registry.load()
        XCTAssertEqual(
            loaded.agents.map(\.id), [Self.detectID],
            "the registry serves the nil-directory row — the reachable shape, not a skipped one")
        XCTAssertNil(
            loaded.agents[0].projectDirectory,
            "and the served row is the nil-directory row")

        try await harness.wiring.arm(CodingAgentProvider.providerID, Self.detectID)
        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            card.sentence, Self.detectedSentence,
            "the card carries the resolved directory verbatim — the fake's path, in the "
                + "provider's own sentence")
        XCTAssertEqual(
            card.resolvedDirectory, Self.detectedPath,
            "the card carries the arm-time resolution for the confirm path's rebuild")

        await harness.wiring.confirm()
        XCTAssertNil(harness.root.widgetStore.state.confirmation)

        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.last?.summary, Self.detectedSentence,
            "the audit record shows the sentence the human approved — the resolved "
                + "directory is visible inside it, never as a raw path beside it")
        XCTAssertEqual(
            runner.callCount, 1,
            "the engine ran exactly once — the confirmed invoke, counted on the engine's log")
        XCTAssertEqual(
            runner.calls.first?.currentDirectoryURL,
            URL(fileURLWithPath: Self.detectedPath),
            "the child starts where the sentence said it would — the detected directory")
    }

    // MARK: - Acceptance 2: explicit wins — detection is never consulted

    /// **An explicit row never consults detection** — the recording fake proves zero calls:
    /// the row's own directory is the one resolution, deterministically (G2).
    func testAnExplicitRowNeverConsultsDetection() async throws {
        let runner = CountingAgentRunner()
        let detection = RecordingDetection(answer: Self.detectedPath)
        let harness = await AgentWiringCwdHarness(
            agents: [Self.pinnedRow],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            },
            detection: detection)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable("pinned")

        try await harness.wiring.arm(CodingAgentProvider.providerID, "pinned")
        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            card.sentence, Self.pinnedSentence,
            "the explicit row's own directory renders — byte-identical to the pre-detection "
                + "card")
        XCTAssertNil(
            card.resolvedDirectory,
            "an explicit row carries no resolution — the row's directory is the value")

        await harness.wiring.confirm()
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.last?.summary, Self.pinnedSentence,
            "the confirmed run records the row's own sentence")
        XCTAssertEqual(
            runner.calls.first?.currentDirectoryURL,
            URL(fileURLWithPath: "/tmp/work"),
            "the explicit row runs in its own directory")
        XCTAssertEqual(
            detection.callCount, 0,
            "detection is never consulted for an explicit row — explicit wins, counted")
    }

    // MARK: - Acceptance 3: one resolution per arm

    /// **Exactly one resolution per arm** — the fake counts one call across the whole
    /// arm → post-record re-render → confirm round trip: the card, the confirm's gate
    /// render and the run all share the arm-time value (G3), and nothing re-resolves.
    func testExactlyOneResolutionPerArmAcrossTheWholeCardRoundTrip() async throws {
        let runner = CountingAgentRunner()
        let detection = RecordingDetection(answer: Self.detectedPath)
        let harness = await AgentWiringCwdHarness(
            agents: [Self.emptyRow],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            },
            detection: detection)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable(Self.detectID)

        try await harness.wiring.arm(CodingAgentProvider.providerID, Self.detectID)
        XCTAssertEqual(
            detection.callCount, 1,
            "the arm resolved exactly once — the fake's one call before the card is up")
        await harness.wiring.confirm()
        XCTAssertEqual(
            detection.callCount, 1,
            "the confirm rebuilds from the card's carried value — the fake is never called "
                + "again across the round trip")
        XCTAssertEqual(
            runner.calls.first?.currentDirectoryURL,
            URL(fileURLWithPath: Self.detectedPath),
            "the run used the arm-time resolution — the one resolution, four identical renders")
    }

    // MARK: - Acceptance 4: a mid-card change cannot move the run

    /// **A focus change mid-card cannot change the run directory** — after the card is up,
    /// the fake's answer changes; the confirm still runs in the arm-time value, because the
    /// invocation carries it (R-B of the PRD: the confirmed sentence is the contract).
    func testAChangeOfDetectionMidCardCannotMoveTheRunDirectory() async throws {
        let runner = CountingAgentRunner()
        let detection = RecordingDetection(answer: Self.detectedPath)
        let harness = await AgentWiringCwdHarness(
            agents: [Self.emptyRow],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            },
            detection: detection)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable(Self.detectID)

        try await harness.wiring.arm(CodingAgentProvider.providerID, Self.detectID)
        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(card.sentence, Self.detectedSentence)

        // The focus moved — the answer the next resolution would give is a different path.
        detection.setAnswer(Self.changedPath)
        await harness.wiring.confirm()

        XCTAssertEqual(
            runner.callCount, 1,
            "the confirmed run happened — the card was answered, not dropped")
        XCTAssertEqual(
            runner.calls.first?.currentDirectoryURL,
            URL(fileURLWithPath: Self.detectedPath),
            "the run uses the arm-time value — the changed detection never reaches the child")
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.last?.summary, Self.detectedSentence,
            "the audit shows the sentence the human approved — the arm-time directory")
        XCTAssertEqual(
            detection.callCount, 1,
            "the mid-card change provoked no second resolution — the carried value is the value")
    }

    // MARK: - Acceptance 5: the voice leg (S2)

    /// **A phrase-armed row with an empty directory resolves and runs in the detected
    /// directory through the composed intent wiring** — the intent leg enriches the
    /// invocation with the same resolution (one per turn), the card shows the detected
    /// path, and the agent wiring's confirm runs the engine in it.
    func testTheVoiceLegResolvesAnEmptyRowAndRunsInTheDetectedDirectory() async throws {
        let runner = CountingAgentRunner()
        let detection = RecordingDetection(answer: Self.detectedPath)
        let harness = await AgentWiringCwdHarness(
            agents: [Self.emptyRow],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            },
            detection: detection)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable(Self.detectID)

        let phraseStore = IntentPhraseStore(
            directory: harness.directory.appendingPathComponent("phrases"))
        try await phraseStore.save(
            IntentPhraseFile(
                phrases: [
                    PhraseIntentRow(
                        phrase: "run the detect agent",
                        providerID: CodingAgentProvider.providerID,
                        toolID: Self.detectID)
                ]))
        let intentWiring = AppBootstrap.composeIntentWiring(
            configStore: harness.configStore,
            provider: harness.provider,
            executor: harness.wiring.executor,
            resolverProvider: {
                PhraseIntentResolver(rows: await phraseStore.load().phrases)
            },
            root: harness.root,
            activeProjectDirectory: { await detection.resolve() })

        let resolution = await intentWiring.resolve("run the detect agent")
        guard case .toolCall(let invocation) = resolution else {
            return XCTFail("the enabled empty row's phrase must resolve to a tool call")
        }
        XCTAssertNil(
            invocation.resolvedDirectory,
            "the resolver builds the plain invocation — the enrichment is the intent leg's")

        let reply = await intentWiring.performAction(invocation)
        XCTAssertNil(reply, "a card is up — the card is the answer, not a spoken ack")
        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            card.sentence, Self.detectedSentence,
            "the voice-armed empty row's card shows the detected directory verbatim")
        XCTAssertEqual(
            card.resolvedDirectory, Self.detectedPath,
            "the card carries the intent leg's resolution for the confirm path")

        await harness.wiring.confirm()
        XCTAssertEqual(
            runner.calls.first?.currentDirectoryURL,
            URL(fileURLWithPath: Self.detectedPath),
            "the voice-confirmed agent runs in the detected directory")
        XCTAssertEqual(
            detection.callCount, 1,
            "one resolution per turn — the intent leg resolved once, the confirm re-used it")
    }

    /// **Without detection wired, the empty row renders the clause-less sentence (S1)** —
    /// the intent wiring composed with the nil-shaped default enriches nothing, and the
    /// card honestly shows no directory: the child runs in Vocca's own cwd, visible in the
    /// sentence, never hidden.
    func testTheVoiceLegWithoutDetectionRendersTheClauseLessSentence() async throws {
        let runner = CountingAgentRunner()
        let harness = await AgentWiringCwdHarness(
            agents: [Self.emptyRow],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            },
            detection: RecordingDetection(answer: Self.detectedPath))
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable(Self.detectID)

        let phraseStore = IntentPhraseStore(
            directory: harness.directory.appendingPathComponent("phrases"))
        try await phraseStore.save(
            IntentPhraseFile(
                phrases: [
                    PhraseIntentRow(
                        phrase: "run the detect agent",
                        providerID: CodingAgentProvider.providerID,
                        toolID: Self.detectID)
                ]))
        // The default composition — no `activeProjectDirectory` wired: the nil-shaped
        // default, byte-identical to today's intent wiring.
        let intentWiring = AppBootstrap.composeIntentWiring(
            configStore: harness.configStore,
            provider: harness.provider,
            executor: harness.wiring.executor,
            resolverProvider: {
                PhraseIntentResolver(rows: await phraseStore.load().phrases)
            },
            root: harness.root)

        let resolution = await intentWiring.resolve("run the detect agent")
        guard case .toolCall(let invocation) = resolution else {
            return XCTFail("the enabled empty row's phrase must resolve to a tool call")
        }
        _ = await intentWiring.performAction(invocation)
        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            card.sentence, Self.clauseLessSentence,
            "no detection available → the clause-less sentence — the child runs in Vocca's "
                + "own cwd, visible in the sentence, never hidden")
        XCTAssertNil(
            card.resolvedDirectory,
            "the unwired composition carries no resolution")
        XCTAssertEqual(
            runner.callCount, 0,
            "nothing ran — the card is up, the confirm is the only route to the engine")
    }

    /// **Without detection, the direct arm of a nil-directory row is clause-less, and the
    /// confirmed run carries no `currentDirectoryURL`** — the detection closure answers nil,
    /// the card honestly shows no directory (S1: the child runs in Vocca's own cwd, visible
    /// in the sentence, never hidden), and the configuration the confirm builds omits the
    /// field entirely — the executor's own run-in-cwd fallback.
    func testANilDirectoryRowWithoutDetectionIsClauseLessAndRunsWithoutACurrentDirectoryURL() async throws {
        let runner = CountingAgentRunner()
        let harness = await AgentWiringCwdHarness(
            agents: [Self.emptyRow],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            },
            detection: RecordingDetection(answer: nil))
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable(Self.detectID)

        try await harness.wiring.arm(CodingAgentProvider.providerID, Self.detectID)
        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            card.sentence, Self.clauseLessSentence,
            "no detection → the clause-less sentence — the child runs in Vocca's own cwd, "
                + "visible in the sentence, never hidden")
        XCTAssertNil(
            card.resolvedDirectory,
            "the nil answer carries no resolution")

        await harness.wiring.confirm()
        XCTAssertEqual(runner.callCount, 1, "the confirmed run happened")
        XCTAssertNil(
            runner.calls.first?.currentDirectoryURL,
            "the nil resolution builds the configuration without a currentDirectoryURL — "
                + "Foundation's default, exactly what the clause-less sentence says")
    }

    // MARK: - Acceptance 6: the composed default and the caption

    /// **The composed default facts are unchanged and the editor caption shipped** — the
    /// wiring over an empty registry still answers `agents=0 spawnsSubprocess=false`, the
    /// nil-shaped default composes (the unwired arm path is byte-identical to today), and
    /// the Project directory field's caption names the detection contract (R4).
    func testTheComposedDefaultFactsAreUnchangedAndTheCaptionShipped() async throws {
        let runner = CountingAgentRunner()
        let harness = await AgentWiringCwdHarness(
            agents: [],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            },
            detection: RecordingDetection(answer: Self.detectedPath))
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let agents = await harness.wiring.listAgents()
        XCTAssertTrue(
            agents.isEmpty,
            "no agent is configured out of the box — an absent file is the empty registry")
        XCTAssertFalse(
            harness.wiring.spawnsSubprocess,
            "the composed default declares it spawns no child process — the D2 answer, "
                + "unchanged with the resolution composed")

        // The nil-shaped default: a composition that does not wire the closure compiles
        // and behaves byte-identically — its declared facts are the same wiring's.
        let defaultWiring = AppBootstrap.composeCodingAgentWiring(
            configStore: harness.configStore,
            auditStore: harness.auditStore,
            registry: harness.registry,
            provider: harness.provider,
            sessionActive: { false },
            root: harness.root)
        XCTAssertFalse(
            defaultWiring.spawnsSubprocess,
            "the unwired composition declares the same no-spawn fact")
        let defaultAgents = await defaultWiring.listAgents()
        XCTAssertTrue(
            defaultAgents.isEmpty,
            "the unwired composition reads the same empty registry")

        XCTAssertEqual(
            ActionsTabCopy.agentProjectDirectoryCaption,
            "leave empty to detect the focused app's project",
            "the editor's Project directory caption ships the R4 copy")
    }
}

/// The wiring test's composition: the real stores over fresh temporary directories, the
/// real `CodingAgentRegistry` (seeded per test), the injected provider (the real
/// `CodingAgentProvider` over a counting engine closure in the default shape), the
/// recording detection closure, a real root over the suite's shared fakes — with the
/// root's `agentRegistry` slot filled (the intent leg's row source) — and the recipe
/// composed with the detection wired.
@MainActor
private final class AgentWiringCwdHarness<Provider: ActionProvider> {
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
    ///     `CodingAgentProvider.load` over the seeded registry in the default shape (the
    ///     nil-directory row is served by the registry's own validation pass — the
    ///     reachable shape, the one the editor's empty field saves).
    ///   - detection: The recording fake the wiring's `activeProjectDirectory` closure
    ///     rides — the counted, settable answer.
    init(
        agents: [CodingAgentDefinition],
        provider: @escaping (CodingAgentRegistry) async -> Provider,
        detection: RecordingDetection,
        sessionActive: @escaping @Sendable @MainActor () -> Bool = { false }
    ) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-agent-cwd-\(UUID().uuidString)")
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
        // The intent leg's row source — the shipped composition fills this slot in
        // `configure`; the harness fills it with its own temp registry.
        root.agentRegistry = registry

        let provider = await provider(registry)
        let wiring = AppBootstrap.composeCodingAgentWiring(
            configStore: configStore,
            auditStore: auditStore,
            registry: registry,
            provider: provider,
            sessionActive: sessionActive,
            root: root,
            activeProjectDirectory: { await detection.resolve() })

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

/// The recording detection — the injected `activeProjectDirectory` closure's fake: a
/// settable answer and a counted call log. The count is the one-resolution contract's
/// witness, and the settable answer drives the mid-card stability acceptance.
private final class RecordingDetection: Sendable {
    private let state = Mutex<(answer: String?, calls: Int)>((nil, 0))

    init(answer: String?) {
        state.withLock { $0.answer = answer }
    }

    func setAnswer(_ answer: String?) {
        state.withLock { $0.answer = answer }
    }

    func resolve() async -> String? {
        state.withLock { $0.calls += 1; return $0.answer }
    }

    var callCount: Int {
        state.withLock(\.calls)
    }
}

/// The engine's call log — the counted "the agent ran in this directory" fact. A class
/// because the `Mutex` it owns is non-`Copyable` — the `FailsTheTestIfInvokedRunner`
/// shape, without the failing half: this suite counts and records.
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

/// A level source that never moves — this suite's `QuietLevelSource` (each file owns its
/// spelling).
private struct QuietLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}