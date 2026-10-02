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

/// **The utterance's path to the invocation** (`utterance-threading`, spec acceptances 1-6):
/// the driver's widened intent-action handler carries the utterance, the wiring enriches a
/// placeholder row's invocation with it (the FULL utterance — the trigger words stay in the
/// task, the audit records exactly what was said), the pre-card refusal stops a placeholder
/// row reached without an utterance before any card, and the Actions-tab arm of a placeholder
/// row refuses loudly — driven over real temp-directory stores and the **real**
/// `CodingAgentProvider` over a counting engine closure (nothing here spawns a child).
///
/// ## The contract, acceptance by acceptance
///
/// 1. A **phrase row naming a placeholder-row agent**: converse → the card shows the
///    substituted argv with the FULL utterance; confirm → the run's arguments contain it;
///    the audit sentence shows it — one row, any task (G1).
/// 2. A **non-placeholder agent**: `taskText` nil, byte-identical to today — the enrichment
///    only fires for a row whose argv carries the placeholder.
/// 3. A **placeholder row reached without an utterance**: refused before the card — the
///    declined ack is spoken, the refusal is recorded (the R8 every-decision rule), no card
///    is ever presented, and the engine is never reached (critique gap 2).
/// 4. The **Actions-tab arm** of a placeholder row: the loud refusal (the pinned copy),
///    nothing recorded as a run, never a card.
/// 5. The **driver's widened handler**: the intent step passes the full cleaned utterance to
///    the action handler — the utterance is in scope at the call site — and the widened
///    default (which ignores the utterance) still falls through to the reply generator
///    byte-identically.
/// 6. The **composed default facts** are unchanged (`agents=0 spawnsSubprocess=false`).
@MainActor
final class UtteranceThreadingTests: XCTestCase {

    // MARK: - Fixtures

    /// The placeholder row's id — the row whose argv the spoken task fills.
    private static let claudeID = "claude"

    /// The full utterance the founder's scenario speaks — the PRD's own sentence, trigger
    /// words and all: the task is exactly what was said, never a trimmed remainder.
    private static let utterance = "ask claude to summarize the open PRs"

    /// **The placeholder row** — the PRD's primary persona: a hand-edited `coding-agents.json`
    /// row whose argv carries the preset template's `<task>` placeholder. Explicit project
    /// directory, so the arm-time detection is never consulted (the fixture stays about the
    /// utterance, not the directory).
    private static let claude = CodingAgentDefinition(
        id: claudeID,
        executablePath: "/opt/homebrew/bin/claude",
        arguments: ["-p", KnownAgentPresets.taskPlaceholder],
        projectDirectory: "/Users/aliz/dev/at/vocca",
        timeoutSeconds: 30,
        environment: nil,
        clause: nil)!

    /// The placeholder row's substituted sentence — the card's exact words once the full
    /// utterance fills the placeholder.
    private static let substitutedSentence =
        "Run the coding agent 'claude': /opt/homebrew/bin/claude -p ask claude to summarize "
        + "the open PRs in /Users/aliz/dev/at/vocca."

    /// The non-placeholder row — acceptance 2's subject: a fixed-argv row with no `<task>` in
    /// its arguments, byte-identical to today whatever the utterance says.
    private static let plainRow = CodingAgentDefinition(
        id: "commit-helper",
        executablePath: "/usr/bin/true",
        arguments: ["--commit"],
        projectDirectory: "/Users/aliz/dev/at/vocca",
        timeoutSeconds: 120,
        environment: nil,
        clause: "Runs the commit helper.")!

    /// The non-placeholder row's sentence — the pre-threading render, asserted byte-for-byte.
    private static let plainSentence =
        "Run the coding agent 'commit-helper': /usr/bin/true --commit in /Users/aliz/dev/at/vocca. "
        + "Runs the commit helper."

    /// The fixture invocation a confident resolution carries (the driver test's).
    private static let fixtureInvocation = ActionInvocation(
        providerID: "probe-intent", toolID: "clear-audit")!

    // MARK: - Acceptance 5: the driver's widened handler

    /// The fixture VAD configuration, shared with the turn-taking suites.
    private static let configuration = VADConfiguration(
        onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)

    /// The fixture utterance tone: 880 Hz, orthogonal to the reply reference's 440 Hz.
    private static let userSpeech = TurnLoopFixtures.tone()

    /// The scripted commit detector: a one-frame pause keeps listening, the eighth frame
    /// commits.
    private static let commitments = [TurnCommitment](repeating: .keepListening, count: 7)
        + [.commit]

    /// One committed turn's VAD script: listening silence, the 4-frame utterance, the
    /// 8-frame pause (commit).
    private static func turnScript() -> [SpeechActivity] {
        [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
            + [SpeechActivity](repeating: .silence, count: 8)
    }

    /// The stub the reply renders: one 440 Hz chunk — the known-output reference.
    nonisolated private static let replyChunk = TurnLoopFixtures.chunk(
        amplitude: 0.4, frequency: 440, samples: 4000)

    nonisolated private static func makeStubSynthesizer() -> StubSynthesizer {
        StubSynthesizer(
            identity: VoiceIdentity(engineID: "utterance-threading-stub-synth", voiceName: nil),
            chunks: [replyChunk])
    }

    /// The shared stub instance the `@Sendable` provider closures capture — an actor, so
    /// the capture is honest.
    nonisolated private static let stubSynthesizer = makeStubSynthesizer()

    /// Bounded main-actor polling: yields until `condition` holds or the bound is
    /// exhausted — the ``ConverseIntentStepTests`` shape.
    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<5_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("the condition never became true", file: file, line: line)
    }

    /// The `.speakReply` texts in the ledger, in order.
    nonisolated private static func spokenReplies(in effects: [TurnEffect]) -> [String] {
        effects.compactMap { effect in
            if case .speakReply(let text) = effect { return text } else { return nil }
        }
    }

    /// **The intent step's call site passes the full cleaned utterance to the action
    /// handler** — the widened handler's contract: the utterance is in scope where the
    /// `.toolCall` is acted on, so the handler receives the invocation **and** the words
    /// that resolved to it. The widened default (which ignores the utterance) still falls
    /// through to the reply generator, byte-identical.
    func testTheDriverPassesTheFullUtteranceToTheIntentActionHandler() async throws {
        let utterance = Self.utterance
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: [utterance])
        let provider = ScriptedUtteranceProvider(resolutions: [.toolCall(Self.fixtureInvocation)])
        let handler = RecordingUtteranceHandler()
        let playback = FakePlaybackEngine()
        let failures = RecordingUtteranceFailureSink()

        let driver = ConverseLoopDriver(
            vad: ScriptedVAD(configuration: Self.configuration, script: Self.turnScript()),
            turnDetector: ScriptedTurnDetector(script: Self.commitments),
            clock: UtteranceThreadingTestClock(),
            gate: EchoGate(),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { nil },
            intentProvider: { await provider.resolve($0) },
            intentActionHandler: { invocation, utterance in
                await handler.handle(invocation, utterance: utterance)
            },
            replyGenerator: EchoReplyGenerator(),
            synthesizer: { Self.stubSynthesizer },
            playback: playback,
            onStateChange: { _ in },
            failureSink: { failures.record($0) })

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        await driver.stop()

        XCTAssertEqual(
            handler.calls.count, 1,
            "the handler was consulted exactly once")
        XCTAssertEqual(
            handler.calls.first?.invocation, Self.fixtureInvocation,
            "the handler received the resolution's invocation, verbatim")
        XCTAssertEqual(
            handler.calls.first?.utterance, utterance,
            "the intent step passes the full cleaned utterance to the action handler — the "
                + "widened handler's call site, exactly what was resolved")
        XCTAssertEqual(
            Self.spokenReplies(in: driver.effects), [utterance],
            "the handler's nil answer falls through to the reply generator — the echo, "
                + "byte-identical")
        XCTAssertTrue(
            failures.values.isEmpty,
            "the widened handler changes no failure shape")

        // The widened default's leg: a driver built with the default handler (which ignores
        // the utterance) compiles and falls through to the echo — the unwired driver is
        // today's driver.
        let defaultCapture = ScriptedContinuousCapture()
        let defaultAsr = ScriptedASR(transcripts: [utterance])
        let defaultProvider = ScriptedUtteranceProvider(
            resolutions: [.toolCall(Self.fixtureInvocation)])
        let defaultPlayback = FakePlaybackEngine()

        let defaultDriver = ConverseLoopDriver(
            vad: ScriptedVAD(configuration: Self.configuration, script: Self.turnScript()),
            turnDetector: ScriptedTurnDetector(script: Self.commitments),
            clock: UtteranceThreadingTestClock(),
            gate: EchoGate(),
            capture: defaultCapture,
            asrProvider: { defaultAsr },
            cleanupProvider: { nil },
            intentProvider: { await defaultProvider.resolve($0) },
            replyGenerator: EchoReplyGenerator(),
            synthesizer: { Self.stubSynthesizer },
            playback: defaultPlayback,
            onStateChange: { _ in },
            failureSink: { _ in })

        try defaultDriver.start()
        defaultCapture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        defaultCapture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { defaultCapture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await defaultPlayback.playCount == 1 }
        await defaultDriver.stop()

        XCTAssertEqual(
            Self.spokenReplies(in: defaultDriver.effects), [utterance],
            "the widened default ignores the utterance and falls through to the reply "
                + "generator — the unwired driver is byte-identical to today")
    }

    // MARK: - Acceptance 1: the phrase-armed placeholder row seeds the full utterance

    /// **A phrase row naming a placeholder-row agent: converse → the card shows the
    /// substituted argv with the FULL utterance; confirm → the run's arguments contain it;
    /// the audit sentence shows it.**
    ///
    /// The trigger words stay in the task — "ask claude to summarize the open PRs" fills the
    /// placeholder whole, never a trimmed remainder — so the card, the engine's argv and the
    /// audit record all carry exactly what was said. The confirm path rebuilds the identical
    /// invocation from the card's carried `taskText` (one resolution, four identical
    /// renders).
    func testAPhraseArmedPlaceholderRowSeedsTheFullUtteranceThroughCardConfirmAndAudit() async throws {
        let runner = CountingAgentRunner()
        let harness = await UtteranceThreadingHarness(
            agents: [Self.claude],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            })
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable(Self.claudeID)

        let intentWiring = await harness.makeIntentWiring(
            phrase: Self.utterance, toolID: Self.claudeID)
        let resolution = await intentWiring.resolve(Self.utterance)
        guard case .toolCall(let invocation) = resolution else {
            return XCTFail(
                "the enabled placeholder row's phrase must resolve to a tool call, got "
                    + "\(resolution)")
        }
        XCTAssertNil(
            invocation.taskText,
            "the resolver builds the plain invocation — the enrichment is the intent leg's")

        let reply = await intentWiring.performAction(invocation, Self.utterance)
        XCTAssertNil(reply, "a card is up — the card is the answer, not a spoken ack")
        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            card.sentence, Self.substitutedSentence,
            "the card shows the substituted argv with the FULL utterance — the trigger words "
                + "stay in the task, verbatim")
        XCTAssertEqual(
            card.taskText, Self.utterance,
            "the signal carries the full utterance for the confirm path's rebuild")

        await harness.wiring.confirm()
        XCTAssertNil(harness.root.widgetStore.state.confirmation)

        XCTAssertEqual(
            runner.callCount, 1,
            "the engine ran exactly once — the confirmed invoke, counted on the engine's log")
        XCTAssertEqual(
            runner.calls.first?.arguments, ["-p", Self.utterance],
            "the run's arguments contain the full utterance — the argv that runs is the argv "
                + "the sentence showed")

        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.last?.summary, Self.substitutedSentence,
            "the audit sentence shows the full utterance — the audit records exactly what "
                + "was said")
        XCTAssertEqual(
            reloaded.last?.decision, .confirmed,
            "the confirmed run reconstructs as confirmed — a human's yes was had")
    }

    // MARK: - Acceptance 2: the non-placeholder row is byte-identical

    /// **A phrase row naming a non-placeholder agent: `taskText` nil, byte-identical to
    /// today** — the enrichment fires only for a row whose argv carries the placeholder, so
    /// the plain row's invocation is untouched: the card renders the pre-threading sentence
    /// byte-for-byte, the signal carries no task text, and the confirmed run passes the
    /// row's own argv unchanged.
    func testANonPlaceholderRowIsByteIdenticalWithTaskTextNil() async throws {
        let runner = CountingAgentRunner()
        let harness = await UtteranceThreadingHarness(
            agents: [Self.plainRow],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            })
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable("commit-helper")

        let utterance = "run the commit helper"
        let intentWiring = await harness.makeIntentWiring(
            phrase: utterance, toolID: "commit-helper")
        let resolution = await intentWiring.resolve(utterance)
        guard case .toolCall(let invocation) = resolution else {
            return XCTFail(
                "the enabled plain row's phrase must resolve to a tool call, got "
                    + "\(resolution)")
        }

        let reply = await intentWiring.performAction(invocation, utterance)
        XCTAssertNil(reply, "a card is up — the card is the answer, not a spoken ack")
        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            card.sentence, Self.plainSentence,
            "the non-placeholder row's card is byte-identical to the pre-threading render — "
                + "the utterance changed nothing")
        XCTAssertNil(
            card.taskText,
            "the non-placeholder row carries no task text — the enrichment fires only for a "
                + "placeholder row")

        await harness.wiring.confirm()
        XCTAssertEqual(
            runner.calls.first?.arguments, ["--commit"],
            "the run's arguments are the row's own, byte-identical — no substitution, no "
                + "placeholder, nothing filled")
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.last?.summary, Self.plainSentence,
            "the audit sentence is the pre-threading render")
    }

    // MARK: - Acceptance 3: the pre-card refusal

    /// **A placeholder row reached without an utterance is refused before the card** — the
    /// wiring's own stop, distinct from the provider's refusal (which would ask a human to
    /// approve a refusal): the declined ack is spoken, the withheld submission records the
    /// refused decision (the R8 every-decision rule), no card is ever presented, and the
    /// engine is never reached (critique gap 2).
    func testAPlaceholderRowReachedWithoutAnUtteranceIsRefusedBeforeTheCard() async throws {
        let runner = CountingAgentRunner()
        let harness = await UtteranceThreadingHarness(
            agents: [Self.claude],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            })
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable(Self.claudeID)

        let intentWiring = await harness.makeIntentWiring(
            phrase: Self.utterance, toolID: Self.claudeID)
        let resolution = await intentWiring.resolve(Self.utterance)
        guard case .toolCall(let invocation) = resolution else {
            return XCTFail(
                "the enabled placeholder row's phrase must resolve to a tool call, got "
                    + "\(resolution)")
        }

        // A hand-built call with no utterance — the empty spelling, the shape only a direct
        // call can produce (the driver always passes the non-empty cleaned utterance).
        let reply = await intentWiring.performAction(invocation, "")
        XCTAssertEqual(
            reply, "Cancelled.",
            "the refused turn is answered with the declined ack — never a silent drop")
        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "never a card — the wiring refuses before the card, the critique-gap-2 stop")
        XCTAssertEqual(
            runner.callCount, 0,
            "never a run — the engine is never reached")

        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.count, 1,
            "the refusal is recorded — the R8 every-decision rule, the withheld submission's "
                + "one entry")
        XCTAssertEqual(
            reloaded.last?.decision, .refused,
            "the refusal reconstructs as refused — the audit log's honest history of a call "
                + "that was stopped on purpose")
        XCTAssertEqual(
            reloaded.last?.toolID, Self.claudeID,
            "the record names the row that was refused")
    }

    // MARK: - Acceptance 4: the surface-arm refusal

    /// **The Actions-tab arm of a placeholder row refuses loudly** — the wiring's own error,
    /// the pinned copy naming why, nothing recorded as a run, never a card: the tab cannot
    /// arm a row whose task would be a meaningless literal, because the tab has no utterance
    /// to fill it with (R4 — the voice leg is the only path that fills a placeholder row).
    func testTheSurfaceArmOfAPlaceholderRowRefusesLoudlyAndRecordsNothing() async throws {
        let runner = CountingAgentRunner()
        let harness = await UtteranceThreadingHarness(
            agents: [Self.claude],
            provider: { registry in
                await CodingAgentProvider.load(registry: registry, run: runner.run)
            })
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable(Self.claudeID)

        do {
            try await harness.wiring.arm(CodingAgentProvider.providerID, Self.claudeID)
            XCTFail("arming a placeholder row must refuse")
        } catch let error as CodingAgentWiringError {
            XCTAssertEqual(
                error, .placeholderRow(Self.claudeID),
                "the wiring refuses with its own error, naming the row")
        }

        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "never a card — the refusal happens before any submission")
        let reloaded = await harness.auditStore.load()
        XCTAssertTrue(
            reloaded.isEmpty,
            "nothing recorded as a run — the refusal happens before any submission")
        XCTAssertEqual(
            runner.callCount, 0,
            "the engine is never reached")

        XCTAssertEqual(
            ActionsTabCopy.agentPlaceholderArmRefusal,
            "Arm refused: the arguments still contain " + KnownAgentPresets.taskPlaceholder
                + ". A placeholder row cannot run from the tab — its task is filled by your "
                + "spoken words in conversation. Replace " + KnownAgentPresets.taskPlaceholder
                + " with a concrete task in the arguments, or remove it.",
            "the surface refusal copy ships, pinned — the loud words the arm refuses with")
    }

    // MARK: - Acceptance 6: the composed default facts

    /// **The composed default facts are unchanged** — the wiring over an empty registry still
    /// answers `agents=0 spawnsSubprocess=false` on both halves (the arm surface's and the
    /// voice leg's), so a default configuration still spawns no child process and the
    /// threading changed nothing for the skeptical user (the PRD's second persona).
    func testTheComposedDefaultFactsAreUnchanged() async throws {
        let runner = CountingAgentRunner()
        let harness = await UtteranceThreadingHarness(
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
            "the agent wiring's composed default declares it spawns no child process")

        let intentWiring = AppBootstrap.composeIntentWiring(
            configStore: harness.configStore,
            provider: harness.provider,
            executor: harness.wiring.executor,
            resolverProvider: { PhraseIntentResolver(rows: []) },
            root: harness.root)
        XCTAssertFalse(
            intentWiring.spawnsSubprocess,
            "the intent wiring's composed default declares the same no-spawn fact — the "
                + "threading composes byte-identically")
    }
}

/// The wiring test's composition: the real stores over fresh temporary directories, the
/// real `CodingAgentRegistry` (seeded per test), the injected provider (the real
/// `CodingAgentProvider` over a counting engine closure), a real root over the suite's
/// shared fakes — with the root's `agentRegistry` slot filled (the intent leg's row source)
/// — and the recipe composed with the default nil-shaped directory closure.
@MainActor
private final class UtteranceThreadingHarness<Provider: ActionProvider> {
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
    ///     `CodingAgentProvider.load` over the seeded registry.
    init(
        agents: [CodingAgentDefinition],
        provider: @escaping (CodingAgentRegistry) async -> Provider
    ) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-utterance-threading-\(UUID().uuidString)")
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
            sessionActive: { false },
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

    /// The voice leg over this harness — the composed intent wiring over the shared stores
    /// and executor, with the phrase store seeded for one phrase row.
    func makeIntentWiring(phrase: String, toolID: String) async -> IntentWiring<Provider> {
        let phraseStore = IntentPhraseStore(
            directory: directory.appendingPathComponent("phrases"))
        try? await phraseStore.save(
            IntentPhraseFile(
                phrases: [
                    PhraseIntentRow(
                        phrase: phrase,
                        providerID: CodingAgentProvider.providerID,
                        toolID: toolID)
                ]))
        return AppBootstrap.composeIntentWiring(
            configStore: configStore,
            provider: provider,
            executor: wiring.executor,
            resolverProvider: {
                PhraseIntentResolver(rows: await phraseStore.load().phrases)
            },
            root: root)
    }
}

/// The engine's call log — the counted "the agent ran with these arguments" fact. A class
/// because the `Mutex` it owns is non-`Copyable` — the ``CountingAgentRunner`` shape from
/// the cwd suite, spelled here.
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

/// The scripted intent provider — a scripted resolution per call, with a call log (the
/// ``ScriptedIntentProvider`` shape, spelled here). A plain `@unchecked Sendable` box: the
/// driver's `intentProvider` closure is `@Sendable`, and the box is written and read only
/// on the main actor (the driver's one isolation domain), never concurrently.
private final class ScriptedUtteranceProvider: @unchecked Sendable {
    private(set) var calls: [String] = []
    private var resolutions: [IntentResolution]

    init(resolutions: [IntentResolution]) {
        self.resolutions = resolutions
    }

    func resolve(_ utterance: String) async -> IntentResolution? {
        calls.append(utterance)
        return resolutions.isEmpty ? nil : resolutions.removeFirst()
    }
}

/// The recording action handler — a scripted reply per call, with a call log carrying the
/// invocation **and the utterance** it was handed (the widened handler's witness).
private final class RecordingUtteranceHandler: @unchecked Sendable {
    private(set) var calls: [(invocation: ActionInvocation, utterance: String)] = []

    func handle(_ invocation: ActionInvocation, utterance: String) async -> String? {
        calls.append((invocation, utterance))
        return nil
    }
}

/// The failure-sink recorder — the same single-threaded box shape as the intent doubles.
private final class RecordingUtteranceFailureSink: @unchecked Sendable {
    private(set) var values: [ConverseTurnFailure] = []
    func record(_ failure: ConverseTurnFailure) {
        values.append(failure)
    }
}

/// The hand-moved clock, as a **struct** — the driver's init requires `MonotonicClock &
/// Sendable`, and these tests never advance it (the loop's own copy freezing at `.zero`
/// changes nothing the assertions read).
private struct UtteranceThreadingTestClock: MonotonicClock {
    var now: Duration = .zero
}

/// A level source that never moves — this suite's `QuietLevelSource` (each file owns its
/// spelling).
private struct QuietLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}