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

/// **The composed MCP wiring's contract** (`mcp-composition` spec acceptances A1-A6): the recipe
/// the later `intent-and-surface` aspect will compose into the root, driven over real
/// temp-directory stores, a **scripted in-memory transport factory** and the **real**
/// `MCPProvider` discovered through it — nothing in this suite ever spawns a child, and nothing
/// here names `StdioMCPTransport` (the D2 pin's whole point: the composition names a factory).
///
/// What is pinned here is the per-server lookup's round trip over the shared spine — a
/// configured server's providerID → discovery once (cached) → arm → the gate's sentence on the
/// widget card → confirm with the exact sentence shown → the audit entry reconstructs — plus the
/// composed default's facts (zero servers, `spawnsSubprocess == false`, no factory call), the
/// per-server providerID helper (one rule for discovery and enablement), two servers coexisting
/// without cross-talk, a launch/discovery failure failing closed to `nil`, and the in-flight
/// refusal at arm.
///
/// The structural legs (the G5 pin, the wiring-family lint rows, the zero-network probe) are the
/// other files' acceptances; this suite is the recipe's own behaviour.
@MainActor
final class MCPWiringTests: XCTestCase {

    // MARK: - Scripted frames

    private func frame(_ text: String) -> Data { Data(text.utf8) }

    /// The server's answer to `initialize` — request id 1, the first id a session mints.
    private func initializeReply(name: String) -> Data {
        frame(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\""
                + MCPSession.protocolVersion
                + "\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"\(name)\","
                + "\"version\":\"2.1\"}}}")
    }

    /// A `tools/list` answer carrying `tools` verbatim — request id 2.
    private func toolsListReply(_ tools: String) -> Data {
        frame("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[\(tools)]}}")
    }

    /// A `tools/call` answer — request id 3, the first call after discovery.
    private func toolCallReply(text: String) -> Data {
        frame(
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":"
                + "\"\(text)\"}],\"isError\":false}}")
    }

    /// One tool with no annotation — not read-only, so it reaches the card (the fail-safe
    /// default).
    private func tool(_ name: String) -> String {
        "{\"name\":\"\(name)\",\"description\":\"does something\"}"
    }

    private func server(id: String, name: String) -> MCPServerConfiguration {
        MCPServerConfiguration(id: id, name: name, executablePath: "/usr/bin/echo")
    }

    private func invocation(
        providerID: String, toolID: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(providerID: providerID, toolID: toolID),
            "the invocation under test must construct", file: file, line: line)
    }

    // MARK: - A1: one providerID helper for discovery and enablement

    /// **`dev.vocca.mcp.<serverID>` is computed by one helper, and the discovered provider and the
    /// enablement row are keyed by the identical value** — the per-server id that keeps two
    /// servers' enablement rows from colliding.
    func testThePerServerProviderIDHelperIsTheSameForDiscoveryAndEnablement() async throws {
        let files = server(id: "files", name: "files-server")
        XCTAssertEqual(
            MCPProvider.providerIDPrefix, "dev.vocca.mcp.",
            "the prefix constant is the one the per-server helper is built from")
        XCTAssertEqual(
            MCPProvider.providerID(forServer: files), "dev.vocca.mcp.files",
            "the helper is `prefix + server.id`")

        let transport = InMemoryMCPTransport(
            replies: [initializeReply(name: "files-server"), toolsListReply(tool("ping"))])
        let factory = ScriptedFactory(transports: ["files": transport])
        let harness = await MCPWiringHarness(servers: [files], factory: factory.make)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let expected = MCPProvider.providerID(forServer: files)
        let lookedUp = await harness.wiring.lookup(expected)
        let wiring = try XCTUnwrap(
            lookedUp, "the configured server's providerID resolves to a wiring")

        XCTAssertEqual(
            wiring.providerID, expected,
            "discovery hands the provider the helper's id — the same value the lookup matched on")

        // Enablement matching: the row the gate folds is keyed by the same helper value.
        try await harness.enable(providerID: expected, toolID: "ping")
        let rows = await harness.configStore.load().enablement
        XCTAssertEqual(rows.map(\.providerID), [expected])
    }

    // MARK: - A2: the card, the confirm, exactly one invocation, discovery cached

    /// **`performAction` on an enabled tool presents the sentence-bound card; Confirm records
    /// exactly one invocation (`[.refused, .confirmed]`)** — and discovery runs **once** for the
    /// server across repeated lookups (the process-lifetime cache).
    func testPerformActionPresentsTheCardAndConfirmRecordsExactlyOneInvocation() async throws {
        let scripted = server(id: "s", name: "scripted-server")
        let transport = InMemoryMCPTransport(
            replies: [
                initializeReply(name: "scripted-server"), toolsListReply(tool("ping")),
                toolCallReply(text: "pong"),
            ])
        let factory = ScriptedFactory(transports: ["s": transport])
        let harness = await MCPWiringHarness(servers: [scripted], factory: factory.make)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let providerID = MCPProvider.providerID(forServer: scripted)
        try await harness.enable(providerID: providerID, toolID: "ping")

        let lookedUp = await harness.wiring.lookup(providerID)
        let wiring = try XCTUnwrap(lookedUp)
        // A second lookup must reuse the cache — at most one discovery per server per process.
        _ = await harness.wiring.lookup(providerID)
        XCTAssertEqual(
            factory.calledIDs, ["s"],
            "discovery runs once per server per process; Confirm reuses the cache, no second spawn")

        let action = try invocation(providerID: providerID, toolID: "ping")
        let reply = await wiring.performAction(action, "")
        XCTAssertNil(reply, "a card is up — the card is the answer, no spoken ack stands in for it")

        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            card.sentence,
            "Run the MCP tool 'ping' on the server 'scripted-server', with no arguments.",
            "the card carries the provider's sentence verbatim")
        XCTAssertEqual(card.providerID, providerID)
        XCTAssertEqual(card.toolID, "ping")

        await wiring.confirm()
        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "an accepted confirm clears the card in the same fold")

        let audit = await harness.auditStore.load()
        XCTAssertEqual(
            audit.map(\.decision), [.refused, .confirmed],
            "the arm's stop and the confirm's run, both recorded — the R8 every-decision rule")
        XCTAssertEqual(audit.last?.summary, card.sentence, "the binding matched")
        let sent = await transport.sentMethods
        XCTAssertEqual(
            sent, ["initialize", "tools/list", "tools/call"],
            "the confirmed tool ran exactly once — the wire is the count")
    }

    // MARK: - A3: two servers, no cross-talk

    /// **Two configured servers coexist without cross-talk**: each providerID reaches only its
    /// own server's transport and sentence, and neither server's frames appear on the other's
    /// wire.
    func testTwoConfiguredServersCoexistWithoutCrossTalk() async throws {
        let alpha = server(id: "alpha", name: "alpha-server")
        let beta = server(id: "beta", name: "beta-server")
        let alphaTransport = InMemoryMCPTransport(
            replies: [initializeReply(name: "alpha-server"), toolsListReply(tool("ping-alpha"))])
        let betaTransport = InMemoryMCPTransport(
            replies: [initializeReply(name: "beta-server"), toolsListReply(tool("ping-beta"))])
        let factory = ScriptedFactory(transports: ["alpha": alphaTransport, "beta": betaTransport])
        let harness = await MCPWiringHarness(servers: [alpha, beta], factory: factory.make)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let alphaID = MCPProvider.providerID(forServer: alpha)
        let betaID = MCPProvider.providerID(forServer: beta)
        XCTAssertNotEqual(alphaID, betaID, "distinct servers carry distinct providerIDs")

        try await harness.enable(providerID: alphaID, toolID: "ping-alpha")
        try await harness.enable(providerID: betaID, toolID: "ping-beta")

        let alphaLookedUp = await harness.wiring.lookup(alphaID)
        let betaLookedUp = await harness.wiring.lookup(betaID)
        let alphaWiring = try XCTUnwrap(alphaLookedUp)
        let betaWiring = try XCTUnwrap(betaLookedUp)

        _ = await alphaWiring.performAction(
            try invocation(providerID: alphaID, toolID: "ping-alpha"), "")
        let alphaCard = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertTrue(
            alphaCard.sentence.contains("alpha-server"),
            "A's card names A's server: \(alphaCard.sentence)")
        XCTAssertEqual(alphaCard.providerID, alphaID)

        await alphaWiring.decline()
        XCTAssertNil(harness.root.widgetStore.state.confirmation)

        _ = await betaWiring.performAction(
            try invocation(providerID: betaID, toolID: "ping-beta"), "")
        let betaCard = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertTrue(
            betaCard.sentence.contains("beta-server"),
            "B's card names B's server: \(betaCard.sentence)")
        XCTAssertEqual(betaCard.providerID, betaID)

        let alphaSent = await alphaTransport.sentMethods
        let betaSent = await betaTransport.sentMethods
        XCTAssertEqual(
            alphaSent, ["initialize", "tools/list"],
            "A's transport saw only A's discovery")
        XCTAssertEqual(
            betaSent, ["initialize", "tools/list"],
            "B's transport saw only B's discovery")
    }

    // MARK: - A4: a failure fails closed

    /// **A discovery failure yields `nil` from the lookup** — the caller fails closed, no wiring
    /// and no provider is produced.
    func testAFailedDiscoveryYieldsNil() async throws {
        let unreachable = server(id: "dead", name: "dead-server")
        // A peer that is not there: initialize fails, discovery yields no provider.
        let transport = InMemoryMCPTransport(replies: [], isAvailable: false)
        let factory = ScriptedFactory(transports: ["dead": transport])
        let harness = await MCPWiringHarness(servers: [unreachable], factory: factory.make)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let result = await harness.wiring.lookup(MCPProvider.providerID(forServer: unreachable))
        XCTAssertNil(result, "a discovery that cannot negotiate produces no wiring")
    }

    /// **A launch failure yields `nil`** as well — the factory's own `.failed` fails closed.
    func testAFailedLaunchYieldsNil() async throws {
        let broken = server(id: "broken", name: "broken-server")
        let harness = await MCPWiringHarness(
            servers: [broken],
            factory: { _ in .failed("test.launchRefused") })
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let result = await harness.wiring.lookup(MCPProvider.providerID(forServer: broken))
        XCTAssertNil(result, "a refused launch produces no wiring")
    }

    // MARK: - A5: the composed default cannot spawn

    /// **Zero configured servers → the factory is never called and `spawnsSubprocess == false`** —
    /// the D2 narrowed promise as a computed fact about the configuration.
    func testTheComposedDefaultBuildsNoProviderAndDeclaresNoSpawn() async {
        let factory = ScriptedFactory(transports: [:])
        let harness = await MCPWiringHarness(servers: [], factory: factory.make)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let spawns = await harness.wiring.spawnsSubprocess()
        XCTAssertFalse(
            spawns,
            "no server is configured, so the composed default cannot create a child")
        XCTAssertEqual(factory.calledIDs, [], "nothing was launched")

        let unmatched = await harness.wiring.lookup("dev.vocca.mcp.anything")
        XCTAssertNil(
            unmatched,
            "an unconfigured providerID resolves to nothing — no server matches")
        XCTAssertEqual(factory.calledIDs, [], "an unmatched lookup launches nothing")
        XCTAssertNil(
            harness.root.widgetStore.state.confirmation,
            "no card exists at composition time — the recipe presents nothing")
    }

    // MARK: - A6: the in-flight refusal

    /// **The arm is refused while a session is in flight** — the flag is read lazily at arm time,
    /// no submission reaches the gate (the audit store stays empty) and no card can appear.
    func testTheInFlightRefusalHoldsAtArm() async throws {
        let scripted = server(id: "s", name: "scripted-server")
        let transport = InMemoryMCPTransport(
            replies: [initializeReply(name: "scripted-server"), toolsListReply(tool("ping"))])
        let factory = ScriptedFactory(transports: ["s": transport])
        let harness = await MCPWiringHarness(
            servers: [scripted], factory: factory.make, sessionActive: { true })
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let providerID = MCPProvider.providerID(forServer: scripted)
        try await harness.enable(providerID: providerID, toolID: "ping")
        let lookedUp = await harness.wiring.lookup(providerID)
        let wiring = try XCTUnwrap(lookedUp)

        do {
            try await wiring.arm("ping")
            XCTFail("arming while a session is in flight must refuse")
        } catch let error as MCPWiringError {
            XCTAssertEqual(error, .sessionInFlight)
        }

        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        let audit = await harness.auditStore.load()
        XCTAssertTrue(
            audit.isEmpty,
            "the refused arm records nothing — the refusal happens before any submission")
    }
}

// MARK: - The harness

/// The wiring test's composition: the real stores over fresh temporary directories, the real
/// `MCPProvider` discovered over an injected in-memory transport, a real root over the suite's
/// shared fakes, and the recipe composed exactly as `intent-and-surface` will — the call itself
/// is the compile pin over the parameter list.
@MainActor
private final class MCPWiringHarness {
    let directory: URL
    let configStore: ActionConfigStore
    let auditStore: FileSystemActionAuditStore
    let root: DictationLoopRoot
    let wiring: MCPWiring

    /// - Parameters:
    ///   - servers: The servers seeded into the config store. `[]` seeds nothing — the absent
    ///     file, the true first-launch default.
    ///   - factory: The transport factory the recipe launches through — a scripted
    ///     `InMemoryMCPTransport` per server in the default shape; a test injects its own when it
    ///     must fail a launch.
    ///   - sessionActive: The in-flight read the wiring consults lazily at arm time.
    init(
        servers: [MCPServerConfiguration],
        factory: @escaping @Sendable (MCPServerConfiguration) async -> MCPTransportLaunch,
        sessionActive: @escaping @Sendable @MainActor () -> Bool = { false }
    ) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-mcp-wiring-\(UUID().uuidString)")
        let configStore = ActionConfigStore(
            directory: directory.appendingPathComponent("config"))
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        if !servers.isEmpty {
            try? await configStore.save(ActionConfig(servers: servers, enablement: []))
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

        let wiring = AppBootstrap.composeMCPWiring(
            configStore: configStore,
            auditStore: auditStore,
            transportFactory: factory,
            sessionActive: sessionActive,
            root: root)

        self.directory = directory
        self.configStore = configStore
        self.auditStore = auditStore
        self.root = root
        self.wiring = wiring
    }

    /// Persists the enablement row for one tool — membership in the shared config store, the same
    /// rows the Actions tab's toggles write.
    func enable(providerID: String, toolID: String) async throws {
        let config = await configStore.load()
        let row = ActionConfigEnablementRow(providerID: providerID, toolID: toolID)
        try await configStore.save(
            ActionConfig(servers: config.servers, enablement: config.enablement + [row]))
    }
}

/// A scripted transport factory: a transport per server id, and a log of which servers were
/// launched — the count that proves discovery runs once and that the composed default launches
/// nothing.
private final class ScriptedFactory: Sendable {
    private let transports: [String: InMemoryMCPTransport]
    private let calls = Mutex<[String]>([])

    init(transports: [String: InMemoryMCPTransport]) {
        self.transports = transports
    }

    func make(_ server: MCPServerConfiguration) async -> MCPTransportLaunch {
        calls.withLock { $0.append(server.id) }
        guard let transport = transports[server.id] else {
            return .failed("test.noTransport")
        }
        return .launched(transport)
    }

    var calledIDs: [String] {
        calls.withLock { $0 }
    }
}

/// A level source that never moves — this suite's `QuietLevelSource` (each file owns its
/// spelling).
private struct QuietLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}
