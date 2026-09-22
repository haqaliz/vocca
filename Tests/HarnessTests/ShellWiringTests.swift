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

/// **The composed shell wiring's contract** (`wiring` aspect, spec acceptances 1-3, 6): the
/// recipe `configure` calls, driven over real temp-directory stores and the **real**
/// `ShellProvider` over the **real** engine (`ShellExecutor` — benign `/bin/echo` children),
/// the same composition a user's armed command runs through.
///
/// What is pinned here is the wiring's own round trip over the shared spine: arm → the
/// argv-derived sentence on the widget card → confirm with the exact sentence shown → the
/// child runs → the audit entry reconstructs — plus the decline path (the refused decision
/// recorded), the dry-run path (the engine reached zero times, asserted on the engine's own
/// call log), the enablement-first gate order (a disabled command is declined before any
/// describe — the bounded key is the proof), and the composed default's facts
/// (`commands=0`, `spawnsSubprocess=false`).
///
/// The sentence is the provider's own argv-derived rendering (`ShellProviderSentences`) —
/// this suite asserts it through the wiring, never around it, so the card a user sees is the
/// card this suite read.
///
/// The structural legs (the G5 pin, the wiring-family lint rows, the zero-network probe) are
/// the other files' acceptances; this suite is the recipe's own behaviour.
@MainActor
final class ShellWiringTests: XCTestCase {

    /// The command the founder's scenario arms — a **benign** `/bin/echo` argv, destructive by
    /// default (the file declares no `readOnly`, R2), so the gate demands the card before
    /// anything runs.
    private static let toolID = "echo-hello"
    private static let fixture = ShellCommandDefinition(
        id: toolID,
        command: ["/bin/echo", "vocca-shell-round-trip"],
        readOnly: false)

    /// The argv-derived sentence the provider renders for the fixture — the card's exact words.
    private static let sentence =
        "Run the shell command 'echo-hello': /bin/echo vocca-shell-round-trip."

    // MARK: - Acceptance 2: arm → confirm → invoke → audit reconstruct

    /// **The whole round trip, through the composed recipe over the real engine**: seed the
    /// registry, enable the command, arm it, read the gate's exact sentence off the widget
    /// card, confirm with that sentence, and reconstruct the entries from the audit store —
    /// the arm's stop and the confirm's run, in ordinal order, the run carrying the card's
    /// sentence (the binding matched).
    func testArmConfirmInvokeAndAuditReconstructThroughTheComposedRecipe() async throws {
        let harness = await ShellWiringHarness(commands: [Self.fixture])
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable(Self.toolID)

        try await harness.wiring.arm(ShellProvider.providerID, Self.toolID)
        let card = harness.root.widgetStore.state.confirmation?.signal
        XCTAssertEqual(
            card?.sentence, Self.sentence,
            "the card carries the provider's argv-derived sentence verbatim — the gate's "
                + "render, re-presented after its own record")
        XCTAssertEqual(card?.providerID, ShellProvider.providerID)
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
        XCTAssertEqual(reloaded[1].providerID, ShellProvider.providerID)
        XCTAssertEqual(reloaded[1].toolID, Self.toolID)
        XCTAssertEqual(
            reloaded[1].summary, Self.sentence,
            "the recorded summary is the sentence the card showed — the binding matched, so "
                + "the audit reconstructs exactly what the human approved")
    }

    // MARK: - Acceptance 2: the decline path

    /// **Decline records the refused decision and clears the card**: the wiring submits the
    /// withheld approval (the stop for want of a yes, recorded like any other decision) and
    /// the card goes away in the same path.
    func testDeclineRecordsTheRefusedDecisionAndClearsTheCard() async throws {
        let harness = await ShellWiringHarness(commands: [Self.fixture])
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable(Self.toolID)

        try await harness.wiring.arm(ShellProvider.providerID, Self.toolID)
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
            "a destructive command stopped for want of a yes is a refusal — recorded, never "
                + "absent, and nothing ran")
    }

    // MARK: - Acceptance 2: the dry-run half

    /// **Preview renders the provider's sentence without acting** (M5): the destructive
    /// command's sentence lands, the dry-run's own record lands, and the engine is reached
    /// **zero times** — asserted on the engine's own call log (the `failsTheTestIfInvoked`
    /// shape), never only on the audit.
    func testPreviewRecordsTheDryRunAndNeverInvokes() async throws {
        let runner = FailsTheTestIfInvokedRunner()
        let harness = await ShellWiringHarness(
            commands: [Self.fixture],
            provider: { registry in
                let file = await registry.load()
                return ShellProvider(commands: file.commands) { configuration in
                    await runner.run(configuration)
                }
            })
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.enable(Self.toolID)

        let sentence = await harness.wiring.preview(ShellProvider.providerID, Self.toolID)
        XCTAssertEqual(sentence, Self.sentence)

        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.count, 1,
            "the dry-run's own record is the whole of the log — nothing else was submitted")
        XCTAssertTrue(
            reloaded.contains { $0.decision == .dryRun },
            "the preview's decision is recorded as a dry run — the R8 every-decision rule")
        XCTAssertFalse(
            reloaded.contains { $0.decision == .confirmed }
                || reloaded.contains { $0.decision == .autoRanReadOnly },
            "no invocation happened — a dry run reaches invoke zero times (M5)")
        XCTAssertEqual(
            runner.callCount, 0,
            "the engine's own log is empty — the dry run never reached the acting half, "
                + "proven on the seam the audit cannot see")
    }

    // MARK: - Acceptance 3: the enablement-first gate order

    /// **A disabled command is declined before any `describe`** (M7, absent is off): arming
    /// without an enablement row records the bounded `gate.toolNotEnabled` key — the
    /// never-read proof, since a described destructive command would have answered with a
    /// confirmation request instead — and no card appears.
    func testArmingADisabledCommandIsDeclinedBeforeAnyDescribe() async throws {
        let runner = FailsTheTestIfInvokedRunner()
        let harness = await ShellWiringHarness(
            commands: [Self.fixture],
            provider: { registry in
                let file = await registry.load()
                return ShellProvider(commands: file.commands) { configuration in
                    await runner.run(configuration)
                }
            })
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        try await harness.wiring.arm(ShellProvider.providerID, Self.toolID)

        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "a disabled command arms nothing — no card may appear")
        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.count, 1,
            "the declined arm's own record is the whole of the log")
        XCTAssertEqual(
            reloaded.last?.summary, "gate.toolNotEnabled",
            "the unenabled command is declined before any describe — the M7 never-read rule, "
                + "recorded with its bounded key")
        XCTAssertEqual(
            runner.callCount, 0,
            "nothing ran and nothing was even described — the engine's log stays empty")
    }

    // MARK: - Acceptance 1: the composed default's facts

    /// **The composed default reports `commands=0`, `spawnsSubprocess=false`** — the D2
    /// narrowed promise as a fact the probe line folds: no command is configured out of the
    /// box (an absent `shell-commands.json` is the empty registry), and the composed default
    /// cannot create a child. The command count is the registry's own answer (effect, not
    /// reference); `spawnsSubprocess` is the wiring's declared value, the `requiresNetwork`
    /// analogue, declared for the configuration — nothing is wired, so nothing can spawn.
    func testTheComposedDefaultReportsCommandsZeroAndNoSpawn() async {
        let harness = await ShellWiringHarness(commands: [])
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let commands = await harness.wiring.listCommands()
        XCTAssertTrue(
            commands.isEmpty,
            "no command is configured out of the box — an absent file is the empty registry")
        XCTAssertFalse(
            harness.wiring.spawnsSubprocess,
            "the composed default declares it spawns no child process — the D2 answer is "
                + "unreachable-by-default, never excepted")
        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "no card exists at composition time — the recipe presents nothing")
    }
}

/// The wiring test's composition: the real stores over fresh temporary directories, the real
/// `ShellProvider` over the real engine (`ShellExecutor`, benign children), a real root over
/// the suite's shared fakes, and the recipe composed exactly as `configure` will — the call
/// itself is the compile pin over the parameter list.
@MainActor
private final class ShellWiringHarness {
    let directory: URL
    let configStore: ActionConfigStore
    let auditStore: FileSystemActionAuditStore
    let registry: ShellCommandRegistry
    let root: DictationLoopRoot
    let wiring: ShellWiring<ShellProvider>

    /// - Parameters:
    ///   - commands: The commands seeded into the registry's temp directory. `[]` seeds
    ///     nothing — the absent file, the true first-launch default.
    ///   - provider: The provider the wiring submits through — by default the real
    ///     `ShellProvider.load` over the seeded registry and the real `ShellExecutor`; a test
    ///     injects its own engine when it must observe what never happened.
    init(
        commands: [ShellCommandDefinition],
        sessionActive: @escaping @Sendable @MainActor () -> Bool = { false },
        provider: @escaping (ShellCommandRegistry) async -> ShellProvider = { registry in
            await ShellProvider.load(registry: registry)
        }
    ) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-shell-wiring-\(UUID().uuidString)")
        let configStore = ActionConfigStore(
            directory: directory.appendingPathComponent("config"))
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let registry = ShellCommandRegistry(
            directory: directory.appendingPathComponent("commands"))
        if !commands.isEmpty {
            try? await registry.save(ShellCommandFile(commands: commands))
        }

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

        let wiring = AppBootstrap.composeShellWiring(
            configStore: configStore,
            auditStore: auditStore,
            registry: registry,
            provider: await provider(registry),
            sessionActive: sessionActive,
            root: root)

        self.directory = directory
        self.configStore = configStore
        self.auditStore = auditStore
        self.registry = registry
        self.root = root
        self.wiring = wiring
    }

    /// Persists the enablement row for one command — membership in the shared config store,
    /// the same rows the Actions tab's toggles write.
    func enable(_ toolID: String) async throws {
        let config = await configStore.load()
        let row = ActionConfigEnablementRow(providerID: ShellProvider.providerID, toolID: toolID)
        try await configStore.save(
            ActionConfig(servers: config.servers, enablement: config.enablement + [row]))
    }
}

/// The dry-run's witness: an engine that records every call and answers, so a test can prove
/// the acting half was reached zero times on the engine's own log — the `failsTheTestIfInvoked`
/// shape (every call recorded, the caller asserts the empty log). A class because the
/// `Mutex` it owns is non-`Copyable` — the `ActionGeneration` shape.
private final class FailsTheTestIfInvokedRunner: Sendable {
    private let calls = Mutex<[ShellExecutor.Configuration]>([])

    func run(_ configuration: ShellExecutor.Configuration) async -> ShellExecutionResult {
        calls.withLock { $0.append(configuration) }
        return ShellExecutionResult(
            status: .succeeded(exitCode: 0),
            standardOutput: Data(),
            standardError: Data(),
            outputWasTruncated: false)
    }

    var callCount: Int {
        calls.withLock(\.count)
    }
}

/// A level source that never moves — this suite's `QuietLevelSource` (each file owns its
/// spelling).
private struct QuietLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}