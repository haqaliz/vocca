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

/// **The MCP intent-and-surface contract** (`intent-and-surface` spec acceptances A1-A6): the
/// router's third arm, the composite's prefix exclusion, and the Actions tab's discovery wiring
/// — driven over real temp-directory stores, a **scripted in-memory transport factory** and the
/// **real** `MCPProvider` discovered through it. Nothing here spawns a child, and nothing names
/// `StdioMCPTransport` (the D2 pin's whole point: the composition names a factory).
@MainActor
final class MCPIntentAndSurfaceTests: XCTestCase {

    // MARK: - Scripted frames (the `MCPWiringTests` shape, file-local)

    private func frame(_ text: String) -> Data { Data(text.utf8) }

    private func initializeReply(name: String) -> Data {
        frame(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\""
                + MCPSession.protocolVersion
                + "\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"\(name)\","
                + "\"version\":\"2.1\"}}}")
    }

    private func toolsListReply(_ tools: String) -> Data {
        frame("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[\(tools)]}}")
    }

    private func toolCallReply(text: String) -> Data {
        frame(
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":"
                + "\"\(text)\"}],\"isError\":false}}")
    }

    private func tool(_ name: String) -> String {
        "{\"name\":\"\(name)\",\"description\":\"does something\"}"
    }

    private func server(id: String, name: String = "scripted-server") -> MCPServerConfiguration {
        MCPServerConfiguration(id: id, name: name, executablePath: "/usr/bin/echo")
    }

    private func invocation(
        _ providerID: String, _ toolID: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(providerID: providerID, toolID: toolID),
            "the invocation under test must construct", file: file, line: line)
    }

    // MARK: - A1: the router arm reaches the MCP card; Confirm runs once

    /// **A phrase naming an enabled `dev.vocca.mcp.<serverID>` tool resolves through the router to
    /// the sentence-bound card; Confirm records exactly one invocation** over the in-memory
    /// transport (G1). And **no click across many turns runs nothing** (G2): the second voice
    /// action while a card is up refuses to present — the wire sees no `tools/call`.
    func testAPhraseResolvesThroughTheRouterToTheCardAndConfirmRunsOnce() async throws {
        let scripted = server(id: "s")
        let transport = InMemoryMCPTransport(
            replies: [
                initializeReply(name: "scripted-server"), toolsListReply(tool("ping")),
                toolCallReply(text: "pong"),
            ])
        let factory = ScriptedFactory(transports: ["s": transport])
        let harness = await MCPIntentHarness(servers: [scripted], factory: factory.make)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let providerID = MCPProvider.providerID(forServer: scripted)
        try await harness.enable(providerID: providerID, toolID: "ping")

        let router = harness.router(phrase: "ping it", providerID: providerID, toolID: "ping")

        let resolution = await router.resolve("ping it")
        guard case .toolCall(let resolved) = resolution else {
            return XCTFail("the phrase row must resolve to the MCP tool, got \(resolution)")
        }
        XCTAssertEqual(resolved.providerID, providerID)

        let reply = await router.performAction(resolved, "ping it")
        XCTAssertNil(reply, "a card is up — the card is the answer")

        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            card.sentence,
            "Run the MCP tool 'ping' on the server 'scripted-server', with no arguments.",
            "the card carries the provider's sentence verbatim")
        XCTAssertEqual(card.providerID, providerID)

        // G2: a second (and third) voice action while the card is up runs nothing.
        _ = await router.performAction(resolved, "ping it")
        _ = await router.performAction(resolved, "ping it")
        let beforeConfirm = await transport.sentMethods
        XCTAssertEqual(
            beforeConfirm, ["initialize", "tools/list"],
            "no click means no run — the discovery frames only")

        let lookedUp = await harness.mcpWiring.lookup(providerID)
        let serverWiring = try XCTUnwrap(lookedUp)
        await serverWiring.confirm()
        XCTAssertNil(harness.root.widgetStore.state.confirmation, "the confirm clears the card")

        let audit = await harness.auditStore.load()
        XCTAssertEqual(
            audit.map(\.decision), [.refused, .confirmed],
            "the arm's stop and the confirm's run, both recorded")
        let sent = await transport.sentMethods
        XCTAssertEqual(
            sent, ["initialize", "tools/list", "tools/call"],
            "the confirmed tool ran exactly once — discovery once, call once")
    }

    // MARK: - A2: a disabled tool is inert, refused by attempting the call

    /// **A disabled MCP tool is refused by attempting the call** (G3): the gate's enablement
    /// decline records the decision, the provider is never reached (the wire carries no
    /// `tools/call`).
    func testADisabledToolIsRefusedByAttemptingTheCall() async throws {
        let scripted = server(id: "s")
        let transport = InMemoryMCPTransport(
            replies: [initializeReply(name: "scripted-server"), toolsListReply(tool("ping"))])
        let factory = ScriptedFactory(transports: ["s": transport])
        let harness = await MCPIntentHarness(servers: [scripted], factory: factory.make)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let providerID = MCPProvider.providerID(forServer: scripted)
        // No enablement row: the tool exists but is off.

        let router = harness.router(phrase: "ping it", providerID: providerID, toolID: "ping")
        let action = try invocation(providerID, "ping")
        let reply = await router.performAction(action, "ping it")

        XCTAssertEqual(reply, "Cancelled.", "the gate's enablement decline is spoken")
        let audit = await harness.auditStore.load()
        XCTAssertEqual(audit.map(\.decision), [.refused], "the refusal is recorded")
        let sent = await transport.sentMethods
        XCTAssertEqual(
            sent, ["initialize", "tools/list"],
            "the provider was never reached — no tools/call on the wire")
    }

    // MARK: - A3: a foreign providerID is refused, the MCP provider untouched

    /// **An MCP tool id under a non-MCP providerID is refused** (G4): the router sends it to the
    /// audit side (whose provider does not serve it), no MCP factory call is made.
    func testAForeignProviderIDNeverReachesTheMCPProvider() async throws {
        let scripted = server(id: "s")
        let transport = InMemoryMCPTransport(
            replies: [initializeReply(name: "scripted-server"), toolsListReply(tool("ping"))])
        let factory = ScriptedFactory(transports: ["s": transport])
        let harness = await MCPIntentHarness(servers: [scripted], factory: factory.make)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let router = harness.router(phrase: "", providerID: MCPProvider.providerID(forServer: scripted), toolID: "ping")
        // The MCP tool's name under a non-MCP provider id.
        let action = try invocation("dev.example.notmcp", "ping")
        _ = await router.performAction(action, "ping it")

        XCTAssertEqual(
            factory.calledIDs, [],
            "a non-MCP providerID never launches a server — the arm is prefix-gated")
        let sent = await transport.sentMethods
        XCTAssertEqual(sent, [], "the MCP transport is untouched")
    }

    // MARK: - A4: the keyword fallback never resolves to an MCP row

    /// **With the prefix exclusion in place the fallback never sees or returns an MCP row; the
    /// counterfactual (no prefix) does** — the `-UNFILTERED` shape, at the type's own seam (A4).
    func testTheCompositeExcludesMCPRowsByPrefix() throws {
        let providerID = MCPProvider.providerID(forServer: server(id: "s"))
        let row = ToolReference(providerID: providerID, toolID: "ping", displayName: "")
        let catalog = [row]
        let call = try invocation(providerID, "ping")

        // The lying fallback: returns the MCP call regardless of its catalog — the discard half.
        let lying = FixedIntentResolver(resolution: .toolCall(call))
        let filtered = CompositeIntentResolver(
            primary: NullIntentResolver(), fallback: lying,
            excludedProviderIDs: [], excludedProviderIDPrefixes: [MCPProvider.providerIDPrefix])
        XCTAssertEqual(
            filtered.resolve("anything", against: catalog), .none,
            "a fallback result naming an excluded prefix is discarded to `.none`")

        let unfiltered = CompositeIntentResolver(
            primary: NullIntentResolver(), fallback: lying,
            excludedProviderIDs: [], excludedProviderIDPrefixes: [])
        XCTAssertEqual(
            unfiltered.resolve("anything", against: catalog), .toolCall(call),
            "the counterfactual — without the prefix, the excluded result survives")

        // The filter half: the fallback's catalog never carries the MCP row.
        let spy = CatalogSpyIntentResolver()
        let filteredSpy = CompositeIntentResolver(
            primary: NullIntentResolver(), fallback: spy,
            excludedProviderIDs: [], excludedProviderIDPrefixes: [MCPProvider.providerIDPrefix])
        _ = filteredSpy.resolve("anything", against: catalog)
        XCTAssertEqual(spy.lastCatalog, [], "the excluded row never reached the fallback")

        let unfilteredSpy = CompositeIntentResolver(
            primary: NullIntentResolver(), fallback: spy,
            excludedProviderIDs: [], excludedProviderIDPrefixes: [])
        _ = unfilteredSpy.resolve("anything", against: catalog)
        XCTAssertEqual(
            spy.lastCatalog, [row], "the counterfactual — without the prefix, the row reaches it")
    }

    // MARK: - A5: discovery returns per-server rows; enablement is keyed by them

    /// **Discovery for a configured server returns its tools with per-server providerIDs** (G6),
    /// and the enablement row the surface writes is keyed by the identical `providerID` + toolID.
    func testDiscoveryReturnsPerServerRowsAndEnablementIsKeyedByThem() async throws {
        let scripted = server(id: "s")
        let transport = InMemoryMCPTransport(
            replies: [initializeReply(name: "scripted-server"), toolsListReply(tool("ping"))])
        let factory = ScriptedFactory(transports: ["s": transport])
        let harness = await MCPIntentHarness(servers: [scripted], factory: factory.make)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let providerID = MCPProvider.providerID(forServer: scripted)
        let result = await harness.mcpWiring.discoverTools(scripted.id)
        guard case .succeeded(let rows) = result else {
            return XCTFail("a configured server discovers its tools, got \(result)")
        }
        XCTAssertEqual(rows.map(\.providerID), [providerID])
        XCTAssertEqual(rows.map(\.toolID), ["ping"])
        XCTAssertEqual(rows.map(\.radius), [.outwardFacing], "no readOnlyHint means unsafe")

        // The surface's discover binding, wired to the MCP factory.
        let viaSurface = await harness.actionWiring.discoverTools(scripted.id)
        XCTAssertEqual(viaSurface, result, "the surface's binding is the MCP discovery")

        // Default off, then the toggle writes the enablement row keyed by the same pair.
        let config = await harness.configStore.load()
        XCTAssertTrue(config.enablement.isEmpty, "nothing is enabled by default")
        try await harness.actionWiring.setToolEnabled(providerID, "ping", true)
        let enabled = await harness.configStore.load()
        XCTAssertEqual(
            enabled.enablement,
            [ActionConfigEnablementRow(providerID: providerID, toolID: "ping")],
            "the toggle persists the row the router matches")
    }

    // MARK: - A6: a discovery failure fails closed with a key, nothing enabled

    /// **A failed discovery surfaces `.failed(key)` and nothing is enabled** (A6); an unconfigured
    /// server id fails closed too, and neither launches a child.
    func testDiscoveryFailureFailsClosedWithAKeyAndEnablesNothing() async throws {
        let dead = server(id: "dead")
        let transport = InMemoryMCPTransport(replies: [], isAvailable: false)
        let factory = ScriptedFactory(transports: ["dead": transport])
        let harness = await MCPIntentHarness(servers: [dead], factory: factory.make)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let failed = await harness.mcpWiring.discoverTools(dead.id)
        XCTAssertEqual(failed, .failed(MCPWiring.discoveryFailedReasonKey))

        let unknown = await harness.mcpWiring.discoverTools("never-configured")
        XCTAssertEqual(unknown, .failed(MCPWiring.unknownServerReasonKey))

        let config = await harness.configStore.load()
        XCTAssertTrue(config.enablement.isEmpty, "a failed discovery enables nothing")
    }
}

// MARK: - The resolvers A4 drives

/// A resolver that always returns the same resolution — the lying-fallback shape A4 needs.
private struct FixedIntentResolver: IntentResolver {
    let resolution: IntentResolution

    func resolve(_ utterance: String, against catalog: [ToolReference]) -> IntentResolution {
        resolution
    }
}

/// A resolver that records the catalog it was handed and resolves nothing — the filter-half spy.
private final class CatalogSpyIntentResolver: IntentResolver, @unchecked Sendable {
    private let lock = Mutex<[ToolReference]>([])

    var lastCatalog: [ToolReference] { lock.withLock { $0 } }

    func resolve(_ utterance: String, against catalog: [ToolReference]) -> IntentResolution {
        lock.withLock { $0 = catalog }
        return .none
    }
}

// MARK: - The harness

/// The intent-and-surface test's composition: the real stores over fresh temporary directories,
/// the real `MCPProvider` discovered over an injected in-memory transport, a real root over the
/// suite's shared fakes, the MCP wiring, the audit intent wiring and the router — assembled
/// exactly as `configure` will, so the call sites are the compile pins.
@MainActor
private final class MCPIntentHarness {
    let directory: URL
    let configStore: ActionConfigStore
    let auditStore: FileSystemActionAuditStore
    let root: DictationLoopRoot
    let mcpWiring: MCPWiring
    let actionWiring: ActionWiring<AuditActionProvider>

    init(
        servers: [MCPServerConfiguration],
        factory: @escaping @Sendable (MCPServerConfiguration) async -> MCPTransportLaunch,
        sessionActive: @escaping @Sendable @MainActor () -> Bool = { false }
    ) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-mcp-intent-\(UUID().uuidString)")
        let configStore = ActionConfigStore(
            directory: directory.appendingPathComponent("config"))
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        if !servers.isEmpty {
            try? await configStore.save(ActionConfig(servers: servers, enablement: []))
        }

        let root = Self.makeRoot()

        let mcpWiring = AppBootstrap.composeMCPWiring(
            configStore: configStore,
            auditStore: auditStore,
            transportFactory: factory,
            sessionActive: sessionActive,
            root: root)
        root.mcpWiring = mcpWiring

        let actionWiring = AppBootstrap.composeActionWiring(
            configStore: configStore,
            auditStore: auditStore,
            provider: AuditActionProvider(store: auditStore),
            sessionActive: sessionActive,
            root: root,
            toolDiscovery: mcpWiring.discoverTools)

        self.directory = directory
        self.configStore = configStore
        self.auditStore = auditStore
        self.root = root
        self.mcpWiring = mcpWiring
        self.actionWiring = actionWiring
    }

    /// The router over an audit intent wiring whose resolver is a phrase resolver naming one MCP
    /// row — the composed default's shape, minus the launch tasks.
    func router(phrase: String, providerID: String, toolID: String) -> IntentWiring<AuditActionProvider> {
        let provider = AuditActionProvider(store: auditStore)
        let resolver = PhraseIntentResolver(
            rows: [PhraseIntentRow(phrase: phrase, providerID: providerID, toolID: toolID)])
        let audit = AppBootstrap.composeIntentWiring(
            configStore: configStore,
            provider: provider,
            executor: ActionExecutor(provider: provider, store: auditStore),
            resolver: resolver,
            root: root)
        let mcp = mcpWiring
        return AppBootstrap.routeIntentWiring(
            audit: audit, agent: { nil },
            mcp: { providerID in await mcp.lookup(providerID) })
    }

    func enable(providerID: String, toolID: String) async throws {
        let config = await configStore.load()
        try await configStore.save(
            ActionConfig(
                servers: config.servers,
                enablement: config.enablement
                    + [ActionConfigEnablementRow(providerID: providerID, toolID: toolID)]))
    }

    private static func makeRoot() -> DictationLoopRoot {
        let engine = StubEngine.parakeet()
        return DictationLoopRoot(
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
    }
}

/// A scripted transport factory: a transport per server id, and a log of which servers were
/// launched — the count that proves a foreign providerID launches nothing.
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

    var calledIDs: [String] { calls.withLock { $0 } }
}

/// A level source that never moves — this suite's `QuietLevelSource` (each file owns its
/// spelling).
private struct QuietLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}
