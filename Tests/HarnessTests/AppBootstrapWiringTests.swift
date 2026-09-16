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
import VoccaASR
@testable import VoccaBootstrap
import VoccaCore
@testable import VoccaInject
import VoccaText
import VoccaUI
import XCTest

/// The composition root's cleanup wiring contract (spec B4) — the piece of `root-wiring` the
/// suite can drive headlessly: the resolver selects the provider once, and the root folds the
/// egress badge from the resolved provider's `requiresNetwork` + endpoint into the widget store.
///
/// `AppBootstrap.configure` itself needs an `NSApplication` and a run loop, so the fold is
/// extracted into the testable shape the root uses — `WidgetEgressState.fromResolvedProvider(
/// requiresNetwork:end point:)` plus the store's `setEgress` — and this suite asserts that
/// shape against a real resolver over real temp directories (absent config ⇒ rules ⇒ `.none`;
/// an `ollama` config ⇒ a `requiresNetwork == true` provider whose endpoint is the configured
/// one ⇒ `.active(endpoint:)`).
final class AppBootstrapWiringTests: XCTestCase {

    // MARK: - B4: the fold helper

    /// **B4 — a `requiresNetwork == true` provider folds `.active(endpoint:)`.**
    func testTheWiringFoldsAnActiveBadgeForANetworkProvider() {
        XCTAssertEqual(
            WidgetEgressState.fromResolvedProvider(
                requiresNetwork: true, endpoint: "http://localhost:11434"),
            .active(endpoint: "http://localhost:11434"))
    }

    /// **B4 — an offline provider folds `.none`.** The default (rules) path is byte-for-byte
    /// today: no network provider, no badge.
    func testTheWiringFoldsNoBadgeForAnOfflineProvider() {
        XCTAssertEqual(
            WidgetEgressState.fromResolvedProvider(requiresNetwork: false, endpoint: nil),
            .none)
    }

    // MARK: - B4: the resolver + fold through the store

    /// **B4 — an absent config resolves to rules and folds `.none` into the store.** The probe
    /// report's `egress=none` is this fold's byte-for-byte surface on the default path.
    @MainActor
    func testTheAbsentConfigFoldsNoEgressIntoTheWidgetStore() async throws {
        let resolver = Self.makeResolver(over: Self.tempDirectory(), configJSON: nil)
        let cleanup = try await resolver.resolve()
        XCTAssertEqual(cleanup.identity.id, "rules-cleanup")
        XCTAssertFalse(cleanup.requiresNetwork)

        let egress = WidgetEgressState.fromResolvedProvider(
            requiresNetwork: cleanup.requiresNetwork, endpoint: await resolver.egressEndpoint())
        XCTAssertEqual(egress, .none)

        let store = WidgetStateStore(clock: TestClock())
        store.setEgress(egress)
        XCTAssertEqual(store.state.egress, .none)
    }

    /// **B4 — an `ollama` config resolves to a `requiresNetwork == true` provider whose endpoint
    /// is the configured one, and folds `.active(endpoint:)` into the store.**
    @MainActor
    func testAnOllamaConfigFoldsActiveEgressIntoTheWidgetStore() async throws {
        let resolver = Self.makeResolver(
            over: Self.tempDirectory(),
            configJSON: #"{"provider":"ollama","ollama":{"endpoint":"http://localhost:11434","model":"llama3.1"}}"#)
        let cleanup = try await resolver.resolve()
        XCTAssertTrue(
            cleanup.requiresNetwork,
            "the resolved Ollama chain must declare the network — the badge keys on it")
        let endpointValue = await resolver.egressEndpoint()
        let endpoint = try XCTUnwrap(endpointValue)
        XCTAssertEqual(endpoint, "http://localhost:11434")
        let egress = WidgetEgressState.fromResolvedProvider(
            requiresNetwork: cleanup.requiresNetwork, endpoint: endpoint)
        XCTAssertEqual(egress, .active(endpoint: "http://localhost:11434"))

        let store = WidgetStateStore(clock: TestClock())
        store.setEgress(egress)
        XCTAssertEqual(store.state.egress, .active(endpoint: "http://localhost:11434"))
    }

    // MARK: - T17: the custody chain assembles the memory before the ladder

    /// **The ladder the loop gets is built over what the store held**, in that order: the store
    /// is read, the snapshot becomes the memory, the memory becomes the ladder. Asserted through
    /// the extracted assembly rather than through `configure`, which needs an `NSApplication` and
    /// a run loop; the root calls exactly this function.
    ///
    /// A demotion written to the file before the assembly must reach the order the ladder
    /// consults — an assembly that built the ladder first and loaded afterwards would answer the
    /// unlearned order for the first dictation after every launch, which is precisely the cost
    /// C8 exists to stop paying.
    @MainActor
    func testConfigureAssemblesMemoryBeforeTheInjector() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seeding = PersistentInjectionStrategyStore(directory: directory)
        _ = try await seeding.update(
            InjectionStrategy(
                bundleID: "com.apple.Notes",
                demotedRungs: [.accessibility],
                reprobeWindows: [.accessibility: .max]))

        let assembled = await AppBootstrap.assembleShippingLadder(
            store: PersistentInjectionStrategyStore(directory: directory),
            handoff: RecordingFailsafeHandoff(),
            clock: TestClock(),
            now: { 0 })

        let memory = try XCTUnwrap(
            assembled.ladder.order as? MemoryBackedInjectionStrategyOrder,
            "The assembled ladder does not consult the strategy memory at all.")
        XCTAssertTrue(
            assembled.memory === memory,
            "The memory handed back is not the one the ladder consults — the Apps tab would "
            + "write through to an object no dictation reads.")
        XCTAssertEqual(
            memory.orderedRungs(for: "com.apple.Notes"),
            [.clipboardPaste, .keystrokeSynthesis],
            """
            What the store held did not reach the ladder. Either the load happened after the \
            ladder was built, or its result was dropped — and the first dictation after every \
            launch would re-try the rung that is already known to fail.
            """)
    }

    /// **An absent file is silent**, which is what a fresh install has and what the zero-network
    /// probe drives: no throw, no file created by the load, and the shipped C4 order.
    @MainActor
    func testTheAssemblyOverAnAbsentFileIsSilentAndDefaultsToTheC4Order() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let assembled = await AppBootstrap.assembleShippingLadder(
            store: PersistentInjectionStrategyStore(directory: directory),
            handoff: RecordingFailsafeHandoff(),
            clock: TestClock(),
            now: { 0 })

        let memory = try XCTUnwrap(
            assembled.ladder.order as? MemoryBackedInjectionStrategyOrder)
        XCTAssertEqual(
            memory.orderedRungs(for: "com.apple.Notes"),
            [.accessibility, .clipboardPaste, .keystrokeSynthesis])
        XCTAssertEqual(
            memory.orderedRungs(for: "com.example.Editor"),
            [.clipboardPaste, .keystrokeSynthesis])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("strategies.json").path),
            "The launch load created the strategies file. A load must never write.")
    }

    // MARK: - The converse composition (C11, R6)

    /// **The converse wiring is probe-safe and attached** (`converse-wiring` Phase 3): the recipe
    /// constructs the driver over the real adapters, attaches nothing that starts, and never
    /// provisions a model. Whether the machine's graph opens or refuses, the test stays honest:
    /// it never calls the driver's `start()` (on a machine with audio hardware that would open
    /// the real microphone), and the refusal path — the composition's answer when the graph
    /// refuses, which is the CI runner's shape — is asserted on the type itself. The
    /// headless-executable half is the delivery: driving the driver's own loop delivers every
    /// state transition into the root's state sink.
    @MainActor
    func testTheConverseCompositionIsProbeSafeAndAttached() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

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

        let store = ModelStore(rootURL: directory)
        let cleanupResolver = Self.makeResolver(over: directory, configJSON: nil)

        let driver = await AppBootstrap.composeConverseWiring(
            clock: ContinuousMonotonicClock(), store: store, resolver: root.resolver,
            cleanupResolver: cleanupResolver, root: root)

        // Constructed, not started: the recipe opens nothing — the driver's loop is idle and
        // the dictation microphones stayed closed.
        XCTAssertEqual(driver.loop.state, .idle, "the recipe constructs; nothing starts")
        XCTAssertEqual(holdToTalkSource.beginCount, 0, "the dictation mic stayed closed")
        XCTAssertEqual(toggleSource.beginCount, 0, "the toggle mic stayed closed")

        // The refusal path answers honestly: a machine whose graph refuses (every hosted CI
        // runner) gets the honest `.unavailable` from the composition's capture.
        let refusing = AppBootstrap.RefusingContinuousCapture()
        XCTAssertThrowsError(try refusing.start()) { error in
            XCTAssertEqual(error as? ContinuousAudioSourceError, .unavailable)
        }
        refusing.stop()

        // Attach the slots the way configure does, then drive the driver's own loop: the N1
        // hook's states reach the root's state sink — the delivery is headless-executable.
        root.converseDriver = driver
        let states = ConverseStateBox()
        root.converseStateSink = { state in states.values.append(state) }
        driver.loop.start()
        for _ in 0..<2_000 {
            if states.values == [.listening] { break }
            await Task.yield()
        }
        XCTAssertEqual(states.values, [.listening], "the loop's state reaches the root's sink")
        driver.loop.stop()

        // Never provisioned: the recipe reads presence, never downloads — the store stayed empty.
        let manifest = try SileroVadModelManifest.load()
        let present = await store.isPresent(engineID: manifest.engineID, version: manifest.version)
        XCTAssertFalse(present, "the recipe must not provision a model")
    }

    // MARK: - Fixtures

    /// Builds a resolver over a temp directory, writing `configJSON` when non-nil, with stub
    /// transport/key factories.
    private static func makeResolver(
        over directory: URL,
        configJSON: String?
    ) -> CleanupResolver {
        if let configJSON {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? configJSON.write(
                to: directory.appendingPathComponent("cleanup-config.json"),
                atomically: true, encoding: .utf8)
        }
        return CleanupResolver(
            store: CleanupConfigStore(directory: directory, log: { _ in }),
            transport: {
                StubLLMTransport(mode: .happyPath(response: LLMResponse(statusCode: 200, body: Data())))
            },
            keyProvider: { StubWiringKeyProvider() },
            log: { _ in })
    }

    /// A fresh throwaway directory for one test.
    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-wiring-\(UUID().uuidString)")
    }
}

/// A key-seam double for the wiring tests — never a real Keychain.
private struct StubWiringKeyProvider: KeyProvider {
    func key() throws -> String? {
        "stub-key"
    }
}

/// The state-sink recording box — `@unchecked Sendable` because the `@Sendable` sink closure
/// captures it; single-writer (the main actor, via the recipe's hop).
private final class ConverseStateBox: @unchecked Sendable {
    var values: [TurnState] = []
}

/// A level source that never moves — the wiring test's `SilentLevelSource` (the shared double
/// is file-private to its own suites).
private struct QuietLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}
