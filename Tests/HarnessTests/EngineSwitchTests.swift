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
import VoccaBootstrap
import VoccaCore
import VoccaInject
import VoccaUI
import XCTest

/// **Switching engines at the next session boundary** — `CAPABILITY_ROADMAP.md:81`'s "without
/// restart", driven through the real composition root over fakes, the `WarmStartLaunchTests` shape.
///
/// `DictationEngineResolver` resolves once and its `selection` is a `let` with no reset, by design:
/// a process runs one engine, and `isPrepared` describes *that* engine. So a switch does not mutate
/// a resolver — it **replaces** one, and the root holds the current one in a slot every caller reads
/// at call time rather than captures.
///
/// ## The three promises pinned here
///
/// - **A running session is never swapped.** A change while either machine has a session in flight
///   is refused and logged, exactly as `setActiveMode` refuses a mode change: the user gets the
///   change on their next press rather than a broken session.
/// - **The next session uses the new engine, with no restart**, and the new engine's `prepare()`
///   starts *immediately* — the eager preparation of PRD M10, so the first press afterwards is not
///   refused by a readiness gate for a model that is already on disk.
/// - **A stale preparation never opens the gate.** This is the sharpest hazard in the aspect and
///   the reason ``testAStalePreparationCompletingAfterASwitchNeverOpensTheGate`` exists: an
///   in-flight `prepareIfNeeded()` for the *replaced* resolver can finish after the swap, and
///   before this aspect it would have called `markEnginePrepared()` — opening the microphone for an
///   engine the user no longer selected. Replacing the resolver does not by itself prevent that;
///   the preparation has to notice that it is no longer the current one.
///
/// `@MainActor` because the root is.
@MainActor
final class EngineSwitchTests: XCTestCase {

    // MARK: - The shipped configurations

    private static let configuration = HotkeyConfiguration(
        keyCode: 49, modifiers: [.option], activation: .holdToTalk)
    private static let toggleConfiguration = HotkeyConfiguration(
        keyCode: 49, modifiers: [.option], activation: .toggle)

    /// The engine a switch moves *to* in every test below — a different engine, not merely a
    /// different tier, so the identity at the boundary really does change.
    private static let whisper = EngineSelection(tier: .whisperTurbo)

    // MARK: - The composed harness

    /// One composed root over fakes, with the two engines a switch moves between and a recording
    /// pipeline assembly — the assembly is what proves *which* engine the installed pipeline was
    /// built over, which is the question a swapped resolver makes worth asking.
    @MainActor
    private struct Harness {
        let clock: TestClock
        let keyboard: Keyboard
        let source: RecordingAudioSource
        let timer: FakeTimer
        let tap: FakeHotkeyEventSource
        let injector: LedgerInjector
        let holder: LedgerHolder
        let settings: any SettingsStore
        let assembled: AssemblyLedger
        let root: DictationLoopRoot

        init(
            parakeet: any ASREngine,
            whisper: any ASREngine,
            settings: any SettingsStore = EphemeralSettingsStore()
        ) {
            let clock = TestClock()
            let keyboard = Keyboard()
            let source = RecordingAudioSource()
            source.nextSamples = [1, 2, 3]
            let timer = FakeTimer()
            let tap = FakeHotkeyEventSource()
            let holder = LedgerHolder()
            let injector = LedgerInjector(
                result: InjectionResult(
                    rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                    elapsed: .zero))
            let panel = RecordingPanel(holder: holder)
            let targetResolution = TargetResolution(
                focusedApp: FakeFocusedApp(
                    identity: FocusedAppIdentity(
                        bundleID: "com.apple.Notes", windowTitle: "The Draft")),
                secureInput: FakeSecureInput())
            let assembled = AssemblyLedger()

            // The recipe both the launch resolver and every switch are built from — the shipped
            // shape, where `AppBootstrap.makeResolver` plays this part.
            let makeResolver: @Sendable (EngineSelection) -> DictationEngineResolver = {
                selection in
                DictationEngineResolver(selection: selection) { selection in
                    selection.tier.engine == .parakeetV3 ? parakeet : whisper
                }
            }

            let root = DictationLoopRoot(
                configuration: EngineSwitchTests.configuration,
                ceiling: SessionCeiling.default,
                clock: clock,
                audioSource: source,
                keyState: TruthfulKeyState(keyboard),
                watchdogTimer: timer,
                healthTimer: FakeTimer(),
                deferOpening: { $0() },
                tap: tap,
                secureInput: FakeSecureInputState(),
                resolver: makeResolver(settings.engineSelection()),
                targetResolution: targetResolution,
                panel: panel,
                pipelineAssembly: { engine in
                    assembled.record(engine)
                    return DictationPipeline(
                        engine: engine, injector: injector, holder: holder)
                },
                makeResolver: makeResolver,
                settings: settings,
                toggleConfiguration: EngineSwitchTests.toggleConfiguration,
                toggleSource: RecordingAudioSource(),
                toggleTimer: FakeTimer(),
                runningAppName: FakeRunningAppName(),
                widgetClock: FakeTimer(),
                liveLevel: QuietLevelSource())

            self.clock = clock
            self.keyboard = keyboard
            self.source = source
            self.timer = timer
            self.tap = tap
            self.injector = injector
            self.holder = holder
            self.settings = settings
            self.assembled = assembled
            self.root = root
        }

        /// One full hold-to-talk cycle, driven at the wiring the tests use.
        func oneCycle() {
            keyboard.hold(EngineSwitchTests.configuration)
            _ = root.holdToTalk.scheduledWatchdog.receive(
                keyEvent(.keyDown, EngineSwitchTests.configuration.keyCode, [.option]))
            _ = root.holdToTalk.scheduledWatchdog.receive(
                keyEvent(.keyUp, EngineSwitchTests.configuration.keyCode, [.option]))
            keyboard.release(EngineSwitchTests.configuration.keyCode)
        }

        /// Key-down only: the session is left recording, so a switch meets a machine in flight.
        func beginSession() {
            keyboard.hold(EngineSwitchTests.configuration)
            _ = root.holdToTalk.scheduledWatchdog.receive(
                keyEvent(.keyDown, EngineSwitchTests.configuration.keyCode, [.option]))
        }

        /// The `DictationLoopTests` drain: yield until the condition holds, then assert it.
        func drain(until condition: @escaping () async -> Bool, _ message: String) async {
            var attempts = 0
            while !(await condition()) && attempts < 1_000 {
                await Task.yield()
                attempts += 1
            }
            let held = await condition()
            XCTAssertTrue(held, message)
        }

        /// Yield a fixed number of times without asserting — used where the point is that
        /// something must *not* have happened, so there is no condition to wait for.
        func settle() async {
            for _ in 0..<200 { await Task.yield() }
        }
    }

    // MARK: - R2: never swapped under a running session

    /// **R2.** A selection change while a session is in flight is refused: the resolver is
    /// untouched, so the running session keeps the engine it started with, and the readiness gate
    /// is left open rather than being closed under a live microphone.
    ///
    /// Refused *and logged* — the log is `setActiveMode`'s `logger.error`, which no headless test
    /// can read; what is asserted is the half that can be, which is that nothing moved.
    func testASelectionChangeDuringASessionIsRefusedAndLeavesTheResolverAlone() async {
        let parakeet = StubEngine.parakeet()
        let harness = Harness(parakeet: parakeet, whisper: StubEngine.whisper())
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared },
            "the launch preload must complete before the session")
        let launchResolver = harness.root.resolver

        harness.beginSession()
        XCTAssertEqual(harness.source.beginCount, 1, "the session really is in flight")

        harness.root.setEngineSelection(Self.whisper)
        await harness.settle()

        XCTAssertTrue(
            harness.root.resolver === launchResolver,
            "a switch mid-session must be refused — the running session keeps its engine")
        XCTAssertEqual(
            harness.root.resolver.selection, EngineSelection.defaultSelection,
            "and the selection is unchanged, so the next press is not silently re-pointed either")
        XCTAssertTrue(
            harness.root.menuBarConditions.isEnginePrepared,
            "the gate must not be closed under a live microphone")
        let whisperPrepares = harness.assembled.engines.count
        XCTAssertEqual(
            whisperPrepares, 1,
            "and no second pipeline was assembled — the refusal happened before anything moved")
    }

    // MARK: - R2: the next session uses the new engine

    /// **R2 / C3's acceptance (`CAPABILITY_ROADMAP.md:81`).** A session started *after* a change
    /// runs the new engine — no restart. The proof is the transcription: the whisper stub is the
    /// engine that was asked to transcribe, and the Parakeet stub was not asked a second time.
    func testASessionStartedAfterASwitchTranscribesThroughTheNewEngine() async {
        let parakeet = StubEngine.parakeet()
        let whisper = StubEngine.whisper()
        let harness = Harness(parakeet: parakeet, whisper: whisper)
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared }, "the launch preload must complete")

        harness.oneCycle()
        await harness.drain(
            until: { await parakeet.transcribeCalls == 1 },
            "the first session runs the launched engine")

        harness.root.setEngineSelection(Self.whisper)
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared },
            "the switch's eager preparation must open the gate again")

        harness.oneCycle()
        await harness.drain(
            until: { await whisper.transcribeCalls == 1 },
            "the session after the switch must run the newly selected engine")

        let parakeetCalls = await parakeet.transcribeCalls
        XCTAssertEqual(
            parakeetCalls, 1,
            "the replaced engine must not be asked again — the switch is real, not cosmetic")
        XCTAssertEqual(
            harness.root.resolver.selection, Self.whisper,
            "the root reports the selection it is actually running")
    }

    // MARK: - R3 / M10: eager preparation

    /// **R3 (PRD M10).** A switch starts the new engine's `prepare()` immediately — exactly once,
    /// with no press in between. The count is asserted rather than the fact, because "it happened"
    /// is also true of a preparation started twice, and a double warm-up is a minute of the user's
    /// battery for nothing.
    func testASwitchPreparesTheNewlySelectedEngineExactlyOnceWithoutAPress() async {
        let parakeet = StubEngine.parakeet()
        let whisper = StubEngine.whisper()
        let harness = Harness(parakeet: parakeet, whisper: whisper)
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared }, "the launch preload must complete")

        let before = await whisper.prepareCount
        XCTAssertEqual(before, 0, "the engine nobody selected has not been warmed")

        harness.root.setEngineSelection(Self.whisper)
        await harness.drain(
            until: { await whisper.prepareCount == 1 },
            "selecting an engine warms it at once — the first press afterwards must not be refused "
                + "for a model that is already on disk")
        await harness.settle()

        let after = await whisper.prepareCount
        XCTAssertEqual(after, 1, "exactly once — an eager preparation is not two preparations")
        XCTAssertEqual(
            harness.source.beginCount, 0, "and no press was needed to trigger it")
    }

    /// The gate closes the instant a switch is accepted and re-opens only when the new engine is
    /// ready. Between the two, a press is refused honestly — the microphone never opens for an
    /// engine that cannot transcribe.
    func testTheGateClosesOnTheSwitchAndReopensOnlyWhenTheNewEngineIsReady() async {
        let whisper = GatedEngine.whisper()
        let harness = Harness(parakeet: StubEngine.parakeet(), whisper: whisper)
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared }, "the launch preload must complete")

        harness.root.setEngineSelection(Self.whisper)
        XCTAssertFalse(
            harness.root.menuBarConditions.isEnginePrepared,
            "the gate closes synchronously with the switch — never a window where a press opens "
                + "the microphone for an engine that has not been prepared")

        harness.oneCycle()
        XCTAssertEqual(
            harness.source.beginCount, 0,
            "a press while the new engine prepares is refused before the microphone is asked")

        await whisper.release()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared },
            "the new engine's successful preparation re-opens the gate")
    }

    // MARK: - The assembly reads the current resolver

    /// **Phase 3, row 4.** The pipeline installed after a switch is built over the **new** engine.
    ///
    /// The composition root hands its assembly the engine rather than the resolver, so there is no
    /// resolver instance for a long-lived closure to capture and go stale against — the hazard is
    /// removed rather than guarded. This is the pin that says so: the ledger records every engine
    /// the assembly was handed, in order, and the second one is whisper's.
    func testThePipelineIsAssembledOverTheNewlySelectedEngine() async {
        let parakeet = StubEngine.parakeet()
        let whisper = StubEngine.whisper()
        let harness = Harness(parakeet: parakeet, whisper: whisper)
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared }, "the launch preload must complete")

        harness.root.setEngineSelection(Self.whisper)
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared },
            "the switch must finish assembling and open the gate")

        let identities = harness.assembled.identities
        XCTAssertEqual(
            identities, ["parakeet-tdt-0.6b-v3", "whisper-large-v3-turbo"],
            """
            the pipeline must be assembled over the engine the *current* resolver answered. A \
            pipeline built over the replaced engine would transcribe with an engine the user no \
            longer selected and attribute the transcript to it.
            """)
    }

    // MARK: - The switch persists

    /// **Phase 3, row 5.** A switch is written through the settings store, so a simulated relaunch
    /// — a fresh store over the same defaults domain — reads the new selection. Driven over the
    /// real `UserDefaults` adapter on a scoped suite, never the developer's own settings.
    func testASwitchIsPersistedAndSurvivesASimulatedRelaunch() async {
        let name = "dev.vocca.tests.engine-switch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let harness = Harness(
            parakeet: StubEngine.parakeet(), whisper: StubEngine.whisper(),
            settings: UserDefaultsSettingsStore(defaults: defaults))
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared }, "the launch preload must complete")

        harness.root.setEngineSelection(Self.whisper)
        await harness.settle()

        let relaunched = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(
            relaunched.engineSelection(), Self.whisper,
            "the next launch must start in the engine the user chose — a switch that is not "
                + "written is a choice the user makes twice")
    }

    /// Selecting what is already selected changes nothing: no new resolver, no second preparation,
    /// and above all no gate close. Without this guard, opening Settings and clicking the engine
    /// already in use would refuse the next press for as long as a re-warm takes.
    func testSelectingTheAlreadySelectedEngineIsANoOp() async {
        let parakeet = StubEngine.parakeet()
        let harness = Harness(parakeet: parakeet, whisper: StubEngine.whisper())
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared }, "the launch preload must complete")
        let launchResolver = harness.root.resolver

        harness.root.setEngineSelection(EngineSelection.defaultSelection)
        XCTAssertTrue(
            harness.root.menuBarConditions.isEnginePrepared,
            "re-choosing the running engine must not close the gate")
        await harness.settle()

        XCTAssertTrue(
            harness.root.resolver === launchResolver, "and must not mint a second resolver")
        let prepares = await parakeet.prepareCount
        XCTAssertEqual(prepares, 1, "nor warm the engine a second time")
    }

    // MARK: - R4 (PRD M11): preparing is not unavailable

    /// **R4.** While the newly selected engine warms, the root reports **preparing** — a state of
    /// its own, distinct from the unavailable it reports when no preparation is under way.
    ///
    /// PRD M11's rule is that no in-between window may look identical to a failure, and this is the
    /// window it was written for: the model is sitting on disk, nothing is wrong, and the only true
    /// thing to say is "a moment". Reporting the same state as "there is no model" would tell the
    /// user their switch broke something.
    func testASwitchInFlightReportsPreparingRatherThanUnavailable() async {
        let whisper = GatedEngine.whisper()
        let harness = Harness(parakeet: StubEngine.parakeet(), whisper: whisper)
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.engineReadinessState == .ready },
            "the launch preload must complete")

        harness.root.setEngineSelection(Self.whisper)
        XCTAssertEqual(
            harness.root.engineReadinessState, .preparing,
            "a switch in flight is a wait, not a failure")
        XCTAssertTrue(
            harness.root.menuBarConditions.isPreparingEngine,
            "and the menu bar's own projection carries it — the icon must not read as broken")
        XCTAssertNotEqual(
            MenuBarStateReducer.state(for: harness.root.menuBarConditions),
            MenuBarStateReducer.state(
                for: MenuBarConditions(isEnginePrepared: false, isPreparingEngine: false)),
            "preparing and unavailable must not render as the same icon")

        await whisper.release()
        await harness.drain(
            until: { harness.root.engineReadinessState == .ready },
            "and the state resolves to ready when the engine is warm")
        XCTAssertFalse(
            harness.root.menuBarConditions.isPreparingEngine,
            "the preparing flag is cleared with it")
    }

    /// **R4, the other side.** A preparation that *fails* reports unavailable, not preparing: there
    /// is nothing in flight and waiting will not help. The selection stays switched — the user
    /// asked for this engine, and silently reverting would be deciding for them — so the honest
    /// report is "this engine is not available", which is exactly what the next press is told.
    func testAFailedPreparationReportsUnavailableRatherThanPreparing() async {
        let harness = Harness(parakeet: StubEngine.parakeet(), whisper: FailingEngine.whisper())
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.engineReadinessState == .ready },
            "the launch preload must complete")

        harness.root.setEngineSelection(Self.whisper)
        await harness.drain(
            until: { harness.root.engineReadinessState == .unavailable },
            "a failed preparation is not a wait — it is a state the user can act on")
        XCTAssertFalse(harness.root.menuBarConditions.isEnginePrepared)
        XCTAssertFalse(
            harness.root.menuBarConditions.isPreparingEngine,
            "nothing is in flight, so nothing may claim to be")
        XCTAssertEqual(
            harness.root.resolver.selection, Self.whisper,
            "and the selection stays switched — the user asked for this engine")
    }

    // MARK: - The stale-preparation race

    /// **The sharpest hazard in this aspect.** A preparation already in flight for the *replaced*
    /// resolver must never open the readiness gate when it finishes.
    ///
    /// The sequence is entirely ordinary: the launch preload is still warming Parakeet (a cold
    /// CoreML load is seconds, and the model may be downloading) when the user opens Settings and
    /// picks Whisper. The switch replaces the resolver and closes the gate, and Whisper starts
    /// warming. Then Parakeet's `prepare()` returns — succeeding, on a resolver nobody is using.
    ///
    /// Replacing the resolver does not by itself stop that completion from calling
    /// `markEnginePrepared()`. If it does, the gate is open, the pipeline is Parakeet's, and the
    /// next press opens the microphone for an engine the user did not choose — the one thing the
    /// readiness gate exists to prevent. So the preparation checks, after every suspension, that it
    /// is still the current one, and abandons itself if it is not.
    func testAStalePreparationCompletingAfterASwitchNeverOpensTheGate() async {
        let parakeet = GatedEngine.parakeet()
        let whisper = GatedEngine.whisper()
        let harness = Harness(parakeet: parakeet, whisper: whisper)

        harness.root.startEnginePreparation()
        await harness.drain(
            until: { await parakeet.prepareCount == 1 },
            "the launch preload must be in flight — and blocked inside prepare()")
        XCTAssertFalse(
            harness.root.menuBarConditions.isEnginePrepared, "it has not finished yet")

        // The user switches while that preparation is still running.
        harness.root.setEngineSelection(Self.whisper)
        await harness.drain(
            until: { await whisper.prepareCount == 1 },
            "the switch starts the new engine's preparation")

        // ...and only now does the replaced engine's preparation succeed.
        await parakeet.release()
        await harness.settle()

        XCTAssertFalse(
            harness.root.menuBarConditions.isEnginePrepared,
            """
            a preparation for the replaced resolver opened the readiness gate. The gate would then \
            be open over Whisper — which has not been prepared — and the next press would open the \
            microphone for an engine that cannot transcribe.
            """)

        harness.oneCycle()
        XCTAssertEqual(
            harness.source.beginCount, 0,
            "and a press in that window must still be refused before the microphone is asked")

        let identities = harness.assembled.identities
        XCTAssertFalse(
            identities.contains("parakeet-tdt-0.6b-v3"),
            "no pipeline may be installed over the replaced engine either; got \(identities)")

        // The new engine finishing is what actually opens the gate.
        await whisper.release()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared },
            "the selected engine's own preparation is the only thing that opens the gate")
    }
}

// MARK: - The doubles

/// The engines the pipeline assembly was handed, in order — the ledger that answers "which engine
/// is the installed pipeline built over?".
private final class AssemblyLedger: @unchecked Sendable {
    private var recorded: [EngineIdentity] = []

    @MainActor
    func record(_ engine: any ASREngine) {
        recorded.append(engine.identity)
    }

    @MainActor
    var engines: [EngineIdentity] { recorded }

    @MainActor
    var identities: [String] { recorded.map(\.id) }
}

/// A settings store with no disk behind it — the headless default for tests that care about the
/// switch rather than about persistence. The persistence row uses the real adapter instead.
private final class EphemeralSettingsStore: SettingsStore, @unchecked Sendable {
    private var selection = EngineSelection.defaultSelection
    private var activation = PersistedSettings.defaultActivation

    init(
        selection: EngineSelection = .defaultSelection,
        activation: HotkeyConfiguration.Activation = PersistedSettings.defaultActivation
    ) {
        self.selection = selection
        self.activation = activation
    }

    func engineSelection() -> EngineSelection { selection }
    func setEngineSelection(_ selection: EngineSelection) { self.selection = selection }
    func activationMode() -> HotkeyConfiguration.Activation { activation }
    func setActivationMode(_ activation: HotkeyConfiguration.Activation) {
        self.activation = activation
    }

    // The cloud-cleanup acknowledgement is not what these tests are about, so the double answers
    // the safe direction and remembers a write — `false` means the confirmation is shown, which
    // is never the dangerous answer.
    private var acknowledgedCloud = false

    func hasAcknowledgedCloudCleanup() -> Bool { acknowledgedCloud }

    func setAcknowledgedCloudCleanup(_ acknowledged: Bool) { acknowledgedCloud = acknowledged }

}

/// An engine whose `prepare()` blocks until it is released — the only way to hold a preparation
/// open across a switch, which is what the stale-preparation race is made of.
private actor GatedEngine: ASREngine {
    static func parakeet() -> GatedEngine {
        GatedEngine(
            identity: EngineIdentity(
                id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", isLocal: true))
    }

    static func whisper() -> GatedEngine {
        GatedEngine(
            identity: EngineIdentity(
                id: "whisper-large-v3-turbo", displayName: "Whisper large-v3-turbo", isLocal: true))
    }

    let identity: EngineIdentity
    let supportsStreaming = false
    private(set) var prepareCount = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(identity: EngineIdentity) {
        self.identity = identity
    }

    func prepare() async throws {
        prepareCount += 1
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    /// Lets the blocked `prepare()` return, and makes every later one return at once.
    func release() {
        isReleased = true
        waiter?.resume()
        waiter = nil
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        Transcript(
            text: "", segments: [], engine: identity, isFinal: true,
            audioDuration: buffer.audioDuration)
    }
}

/// An engine whose `prepare()` always throws — a model that is missing, or bytes that will not
/// load. The failed-preparation row needs one, because a *failed* wait and an *ongoing* wait are
/// the two states R4 exists to keep apart.
private actor FailingEngine: ASREngine {
    static func whisper() -> FailingEngine {
        FailingEngine(
            identity: EngineIdentity(
                id: "whisper-large-v3-turbo", displayName: "Whisper large-v3-turbo", isLocal: true))
    }

    let identity: EngineIdentity
    let supportsStreaming = false

    init(identity: EngineIdentity) {
        self.identity = identity
    }

    func prepare() async throws {
        throw VoccaError.modelUnavailable(identity, reason: "the test's missing model")
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        throw VoccaError.modelUnavailable(identity, reason: "the test's missing model")
    }
}

/// The widget's level source, silent — this suite asserts nothing about the waveform.
private struct QuietLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}

/// One event, stamped with the constant timestamp the machine's own tests use.
private func keyEvent(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: false, timestamp: .zero)
}
