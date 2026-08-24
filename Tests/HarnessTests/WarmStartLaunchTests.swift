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

import VoccaBootstrap
import VoccaCore
import VoccaInject
import XCTest

/// The `warm-start-streaming` W1 launch-path pins, driven through the composition root exactly as
/// ``DictationLoopTests`` drives it: the real root over fakes everywhere the system would be
/// touched, with ``StubEngine``'s `prepareCount` as the ledger half of the prepare-policy
/// contract (`ASRTestDoubles.swift:71-74` — "the engine owns it, and this count is how a test
/// tells whether `transcribe` honoured it or quietly re-prepared").
///
/// Three promises are pinned here:
///
/// - **Launch preload prepares exactly once** (`W1`, `warm-start/spec.md:13`): calling
///   ``DictationLoopRoot/startEnginePreparation()`` runs the resolver's `prepareIfNeeded()` once —
///   the engine's `prepareCount` is 1 — and opens the readiness gate; the gate then answers the
///   very engine that was prepared.
/// - **The session path never re-prepares** (`W1`, `warm-start/spec.md:14`): a full composed
///   cycle — press, capture, transcribe, inject — leaves `prepareCount` at 1. A hotkey press is
///   not a model load, and a test that lets the count move would be catching a re-warm defect the
///   first dictation of the day pays for in latency.
/// - **Construction never prepares; only the launch path does** (`W1`, `AppBootstrap.swift:854-856`:
///   "Not called by `configure` — this is where model bytes arrive"). The pin is expressed at the
///   root boundary because that is the only boundary a counting stub can reach: `configure`'s
///   resolver builder is hard-coded to the real engine, which is why the zero-network probe
///   composes its own root over ``ProbeEngine`` (`DictationCycleDrive.swift:362-367`) rather than
///   calling `configure` with a fake. The root's constructor is the test-shape `configure`: it
///   must leave `prepareCount` at 0 with the readiness gate closed, and `startEnginePreparation`
///   must be the one call that moves both.
///
/// `@MainActor` because the root is: the launch path and the drive both live in the one isolation
/// domain, exactly as `DictationLoopTests` states for its own harness.
@MainActor
final class WarmStartLaunchTests: XCTestCase {

    // MARK: - The shipped configuration

    /// ⌥Space, hold-to-talk — the shipped binding (`PRODUCT_SPEC.md:127`).
    private static let configuration = HotkeyConfiguration(
        keyCode: 49, modifiers: [.option], activation: .holdToTalk)

    /// The same binding in toggle mode — the R6 second configuration, same key and chord.
    private static let toggleConfiguration = HotkeyConfiguration(
        keyCode: 49, modifiers: [.option], activation: .toggle)

    // MARK: - The composed harness

    /// The `DictationLoopTests` shape: one composed root over fakes, with **no** engine
    /// preparation — the launch path is what these tests exercise, so the harness never calls
    /// ``DictationLoopRoot/markEnginePrepared()`` itself.
    @MainActor
    private struct Harness {
        let clock: TestClock
        let keyboard: Keyboard
        let source: RecordingAudioSource
        let timer: FakeTimer
        let healthTimer: FakeTimer
        let widgetClock: FakeTimer
        let tap: FakeHotkeyEventSource
        let resolver: DictationEngineResolver
        let injector: LedgerInjector
        let holder: LedgerHolder
        let root: DictationLoopRoot

        init(engine: any ASREngine) {
            let clock = TestClock()
            let keyboard = Keyboard()
            let source = RecordingAudioSource()
            source.nextSamples = [1, 2, 3]
            let timer = FakeTimer()
            let healthTimer = FakeTimer()
            let widgetClock = FakeTimer()
            let tap = FakeHotkeyEventSource()
            let focusedApp = FakeFocusedApp(
                identity: FocusedAppIdentity(
                    bundleID: "com.apple.Notes", windowTitle: "The Draft"))
            let secureInput = FakeSecureInput()
            let holder = LedgerHolder()
            let injector = LedgerInjector(
                result: InjectionResult(
                    rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                    elapsed: .zero))
            let panel = RecordingPanel(holder: holder)
            let targetResolution = TargetResolution(
                focusedApp: focusedApp, secureInput: secureInput)
            let resolver = DictationEngineResolver(selection: .defaultSelection) { _ in engine }
            let pipeline = DictationPipeline(
                engine: engine, injector: injector, holder: holder)
            let root = DictationLoopRoot(
                configuration: WarmStartLaunchTests.configuration,
                ceiling: SessionCeiling.default,
                clock: clock,
                audioSource: source,
                keyState: TruthfulKeyState(keyboard),
                watchdogTimer: timer,
                healthTimer: healthTimer,
                deferOpening: { $0() },
                tap: tap,
                secureInput: FakeSecureInputState(),
                resolver: resolver,
                targetResolution: targetResolution,
                panel: panel,
                pipeline: pipeline,
                toggleConfiguration: WarmStartLaunchTests.toggleConfiguration,
                toggleSource: RecordingAudioSource(),
                toggleTimer: FakeTimer(),
                runningAppName: FakeRunningAppName(),
                widgetClock: widgetClock,
                liveLevel: StillLevelSource())

            self.clock = clock
            self.keyboard = keyboard
            self.source = source
            self.timer = timer
            self.healthTimer = healthTimer
            self.widgetClock = widgetClock
            self.tap = tap
            self.resolver = resolver
            self.injector = injector
            self.holder = holder
            self.root = root
        }

        // MARK: The gestures

        /// One full hold-to-talk cycle: chord down, chord up. The opening completes on the
        /// synchronous deferral inside the key-down, exactly as `ScheduledWatchdog` orders it.
        func oneCycle() {
            keyboard.hold(WarmStartLaunchTests.configuration)
            _ = root.holdToTalk.scheduledWatchdog.receive(
                keyEvent(.keyDown, WarmStartLaunchTests.configuration.keyCode, [.option]))
            _ = root.holdToTalk.scheduledWatchdog.receive(
                keyEvent(.keyUp, WarmStartLaunchTests.configuration.keyCode, [.option]))
            keyboard.release(WarmStartLaunchTests.configuration.keyCode)
        }

        /// Lets the router's unstructured tasks run until `condition` holds, then asserts it.
        ///
        /// The launch path and each session's outcome cross `Task` hops (the resolution actor,
        /// the engine actor, the pipeline), so the drive and the observation are separated by the
        /// main actor's queue. Yielding is what turns the queue — the `DictationLoopTests` drain.
        func drain(until condition: @escaping () async -> Bool, _ message: String) async {
            var attempts = 0
            while !(await condition()) && attempts < 1_000 {
                await Task.yield()
                attempts += 1
            }
            let held = await condition()
            XCTAssertTrue(held, message)
        }
    }

    // MARK: - W1: launch preload

    /// **W1.** `startEnginePreparation()` — the launch path's own call — runs the resolver's
    /// `prepareIfNeeded()` exactly once: the engine's `prepareCount` is 1, the readiness gate
    /// opens, and the gate answers the **same** engine object that was prepared.
    func testLaunchPreloadPreparesExactlyOnceAndOpensTheReadinessGate() async {
        let engine = StubEngine.parakeet()
        let harness = Harness(engine: engine)

        let before = await engine.prepareCount
        XCTAssertEqual(
            before, 0,
            "nothing has prepared before the launch path runs")
        let notPrepared = await harness.root.resolver.isPrepared
        XCTAssertFalse(notPrepared, "the readiness gate starts closed")

        harness.root.startEnginePreparation()
        await harness.drain(
            until: { await harness.root.resolver.isPrepared },
            "startEnginePreparation must open the readiness gate")

        let after = await engine.prepareCount
        XCTAssertEqual(
            after, 1,
            "the launch path prepares the engine exactly once")
        let ready = await harness.root.resolver.engineIfReady() as? StubEngine
        XCTAssertTrue(
            ready === engine,
            "the readiness gate answers the engine the launch path prepared — resolve-once")
    }

    /// **W1.** A full composed session — press, capture, transcribe, inject — never re-prepares:
    /// after the launch preload, the delivered cycle leaves `prepareCount` at exactly 1. The
    /// session path routes through the prepared engine (the transcription happened) without ever
    /// calling `prepare` again.
    func testADeliveredSessionNeverRePreparesTheEngine() async {
        let engine = StubEngine.parakeet()
        let harness = Harness(engine: engine)

        harness.root.startEnginePreparation()
        await harness.drain(
            until: { await harness.root.resolver.isPrepared },
            "the launch preload must complete before the session")

        harness.oneCycle()
        await harness.drain(
            until: {
                if case .delivered = harness.root.widgetStore.state.state { return true }
                return false
            },
            "the session must deliver through the prepared engine")

        let prepareAfterSession = await engine.prepareCount
        XCTAssertEqual(
            prepareAfterSession, 1,
            "the session path must never re-prepare — a press is not a model load")
        let transcribes = await engine.transcribeCalls
        XCTAssertEqual(
            transcribes, 1,
            "the session did transcribe through the engine the launch path prepared")
    }

    /// **W1.** The composition root's contract, as `AppBootstrap.swift:854-856` states it:
    /// construction never prepares — model bytes arrive only on the launch path. A root built the
    /// way the probe builds its (`DictationCycleDrive.swift:427-455`) leaves the engine untouched
    /// and the gate closed, and `startEnginePreparation()` is the one call that moves both.
    func testConstructingTheRootNeverPreparesUntilStartEnginePreparationRuns() async {
        let engine = StubEngine.parakeet()
        let harness = Harness(engine: engine)

        let untouched = await engine.prepareCount
        XCTAssertEqual(
            untouched, 0,
            "construction alone must never prepare — configure's contract, pinned")
        let isPrepared = await harness.root.resolver.isPrepared
        XCTAssertFalse(isPrepared, "the readiness gate stays closed until the launch path runs")
        let ready = await harness.root.resolver.engineIfReady()
        XCTAssertNil(ready, "an unprepared engine refuses honestly — the mic never opens")

        harness.root.startEnginePreparation()
        await harness.drain(
            until: { await harness.root.resolver.isPrepared },
            "startEnginePreparation is the one call that opens the gate")

        let prepared = await engine.prepareCount
        XCTAssertEqual(
            prepared, 1,
            "only the launch path prepares — exactly once")
        let isPreparedAfter = await harness.root.resolver.isPrepared
        XCTAssertTrue(isPreparedAfter, "the gate opened with the prepared engine")
    }
}

// MARK: - The widget's level source

/// The input level the composed loop's live widget draws, as a plain value the test scripts.
/// File-private, like every other same-named fake in this suite: the level source is a common
/// double and each file owns its own spelling (`DictationLoopTests.swift:1167-1168`).
private struct StillLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}

// MARK: - Fixture helpers

/// One event, stamped with the constant timestamp the machine's own tests use.
private func keyEvent(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: false,
        timestamp: .zero)
}