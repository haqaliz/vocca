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

/// The `rewarm-after-idle` phase (c) root wiring, driven through the composition root exactly as
/// ``WarmStartLaunchTests`` drives it: the real root over fakes, with the policy's clock and the
/// health poll under the test's hand.
///
/// Five promises are pinned here:
///
/// - **Five idle minutes fire exactly once.** The policy's tick rides the existing ~1 s health
///   poll (no new timer); the fire reaches the resolver and the engine's `rewarm`.
/// - **A session during the window cancels and reschedules it.** The effect funnel is the single
///   observer — both modes, all terminals — and a refused press is not a session.
/// - **The fire re-reads the current resolver.** A selection change mid-window re-points the fire
///   at the new resolver — the re-warm always hits the selected tier's engine, never the
///   abandoned one (the `EngineTier.storageID` keying, respected at fire time).
/// - **A session starting mid-re-warm is never refused** — the readiness gate stays open (the
///   re-warm never touches `EngineReadiness`), and the transcription completes after the
///   in-flight re-warm (the Q5 ordering pin, root half).
/// - **The re-warm never opens or closes `EngineReadiness`** — `markReady()` stays the only
///   opener, and a re-warm is never reported as a preparation.
@MainActor
final class IdleReWarmWiringTests: XCTestCase {

    // MARK: - The shipped configuration

    /// ⌥Space, hold-to-talk — the shipped binding (`PRODUCT_SPEC.md:127`).
    private static let configuration = HotkeyConfiguration(
        keyCode: 49, modifiers: [.option], activation: .holdToTalk)

    /// The same binding in toggle mode — the R6 second configuration, same key and chord.
    private static let toggleConfiguration = HotkeyConfiguration(
        keyCode: 49, modifiers: [.option], activation: .toggle)

    // MARK: - The composed harness

    /// The ``WarmStartLaunchTests`` shape: one composed root over fakes, with the re-warm's
    /// clock and the health poll under the test's hand.
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

        init(
            engine: any ASREngine,
            makeResolver: (@Sendable (EngineSelection) -> DictationEngineResolver)? = nil
        ) {
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
                configuration: IdleReWarmWiringTests.configuration,
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
                makeResolver: makeResolver,
                toggleConfiguration: IdleReWarmWiringTests.toggleConfiguration,
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
            keyboard.hold(IdleReWarmWiringTests.configuration)
            _ = root.holdToTalk.scheduledWatchdog.receive(
                keyEvent(.keyDown, IdleReWarmWiringTests.configuration.keyCode, [.option]))
            _ = root.holdToTalk.scheduledWatchdog.receive(
                keyEvent(.keyUp, IdleReWarmWiringTests.configuration.keyCode, [.option]))
            keyboard.release(IdleReWarmWiringTests.configuration.keyCode)
        }

        /// Lets the router's unstructured tasks run until `condition` holds, then asserts it.
        func drain(until condition: @escaping () async -> Bool, _ message: String) async {
            var attempts = 0
            while !(await condition()) && attempts < 1_000 {
                await Task.yield()
                attempts += 1
            }
            let held = await condition()
            XCTAssertTrue(held, message)
        }

        /// Lets any mis-wired task land — the "must stay 0" assertions' settle.
        func settle() async {
            for _ in 0..<50 { await Task.yield() }
        }
    }

    // MARK: - The policy's fire, through the root

    /// Five idle minutes fire the re-warm exactly once through the composed root: the policy's
    /// tick rides the existing health poll, the fire reaches the resolver, and the engine's
    /// `rewarm` runs — and further health fires in the same window stay spent.
    func testFiveMinutesIdleFiresTheRewarmExactlyOnce() async {
        let engine = StubEngine.parakeet()
        let harness = Harness(engine: engine)
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared },
            "the launch preload must complete before the idle window counts")

        harness.clock.now += IdleReWarmTargets.idleDuration
        harness.healthTimer.tick()
        await harness.drain(
            until: { await engine.rewarmCount == 1 },
            "the idle window's fire must reach a real re-warm")

        harness.healthTimer.tick()
        await harness.settle()
        let count = await engine.rewarmCount
        XCTAssertEqual(count, 1, "one fire per window — further health fires stay spent")
        let prepares = await engine.prepareCount
        XCTAssertEqual(prepares, 1, "the re-warm is not a prepare — the launch ledger stays 1")
    }

    /// A session during the window cancels and reschedules it: the cycle's `.started` closes the
    /// window, health fires through the old window's expiry re-warm nothing, and a fresh five
    /// idle minutes after the cycle's `.ended` fire exactly once.
    func testASessionDuringTheWindowCancelsAndReschedules() async {
        let engine = StubEngine.parakeet()
        let harness = Harness(engine: engine)
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared },
            "the launch preload must complete before the idle window counts")

        harness.clock.now += IdleReWarmTargets.idleDuration * 2 / 5
        harness.oneCycle()
        await harness.drain(
            until: {
                if case .delivered = harness.root.widgetStore.state.state { return true }
                return false
            },
            "the cycle must deliver")

        harness.clock.now += IdleReWarmTargets.idleDuration * 3 / 5
        harness.healthTimer.tick()
        await harness.settle()
        let noFire = await engine.rewarmCount
        XCTAssertEqual(noFire, 0, "a session during the window cancels it — the old idle must not count")

        harness.clock.now += IdleReWarmTargets.idleDuration
        harness.healthTimer.tick()
        await harness.drain(
            until: { await engine.rewarmCount == 1 },
            "a fresh five idle minutes after the end fire exactly once")
    }

    /// The fire re-reads the current resolver: a selection change mid-window re-points the fire
    /// at the new resolver's engine — the re-warm always hits the selected tier and never the
    /// abandoned one (the `EngineTier.storageID` keying, respected at fire time).
    func testTheFireReReadsTheCurrentResolver() async {
        let oldEngine = StubEngine.parakeet()
        let newEngine = StubEngine.whisper()
        let harness = Harness(
            engine: oldEngine,
            makeResolver: { selection in
                DictationEngineResolver(selection: selection) { _ in newEngine }
            })
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared },
            "the launch preload must complete before the idle window counts")

        harness.root.setEngineSelection(EngineSelection(tier: .whisperTurbo))
        await harness.drain(
            until: { await newEngine.prepareCount == 1 },
            "the switch prepares the newly selected engine")

        harness.clock.now += IdleReWarmTargets.idleDuration
        harness.healthTimer.tick()
        await harness.drain(
            until: { await newEngine.rewarmCount == 1 },
            "the fire re-reads the current resolver at fire time")

        let oldRewarms = await oldEngine.rewarmCount
        XCTAssertEqual(
            oldRewarms, 0,
            "the abandoned resolver's engine never re-warms — the re-warm always hits the selected tier")
    }

    /// The ordering pin, root half: a session starting mid-re-warm is **never refused** — the
    /// readiness gate stayed open (the re-warm never touched it) — and the transcription
    /// completes only after the in-flight re-warm does.
    func testASessionStartingMidRewarmIsNeverRefusedAndTranscribesAfterIt() async {
        let engine = WiringRewarmEngine()
        let harness = Harness(engine: engine)
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared },
            "the launch preload must complete before the idle window counts")

        harness.clock.now += IdleReWarmTargets.idleDuration
        harness.healthTimer.tick()
        await harness.drain(
            until: { await engine.parkedRewarms == 1 },
            "the re-warm parks in flight")

        harness.oneCycle()
        await harness.drain(
            until: {
                if case .transcribing = harness.root.widgetStore.state.state { return true }
                return false
            },
            "the press was not refused — the session is transcribing, held on the in-flight re-warm")

        await engine.openGate()
        await harness.drain(
            until: {
                if case .delivered = harness.root.widgetStore.state.state { return true }
                return false
            },
            "the transcription completes after the in-flight re-warm")
        let rewarms = await engine.rewarmCount
        XCTAssertEqual(rewarms, 1)
    }

    /// The re-warm never opens or closes `EngineReadiness`: while the re-warm is in flight the
    /// menu bar still reports the engine prepared, never "preparing" — `markReady()` stays the
    /// only opener, and a re-warm is not a preparation.
    func testTheRewarmNeverOpensOrClosesTheReadinessGate() async {
        let engine = WiringRewarmEngine()
        let harness = Harness(engine: engine)
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared },
            "the launch preload must complete before the idle window counts")

        harness.clock.now += IdleReWarmTargets.idleDuration
        harness.healthTimer.tick()
        await harness.drain(
            until: { await engine.parkedRewarms == 1 },
            "the re-warm parks in flight")

        XCTAssertTrue(
            harness.root.menuBarConditions.isEnginePrepared,
            "the re-warm never closes the gate — a session mid-re-warm is never refused")
        XCTAssertFalse(
            harness.root.menuBarConditions.isPreparingEngine,
            "a re-warm is not a preparation — nothing may say 'preparing'")

        await engine.openGate()
        await harness.drain(
            until: { await engine.rewarmCount == 1 },
            "the re-warm completes")
        XCTAssertTrue(
            harness.root.menuBarConditions.isEnginePrepared,
            "and it never opened the gate either — the gate was open and stays open")
    }
}

// MARK: - The gated re-warm double

/// The wiring rows' engine: a ``StubEngine``-shaped double whose `rewarm()` parks at a gate and
/// whose `transcribe` awaits the in-flight re-warm — the engine half of the ordering pin,
/// mirrored so the root half has somewhere to run. An actor, like ``StubEngine``.
private actor WiringRewarmEngine: ASREngine, EngineRewarmable {

    let identity = EngineIdentity(
        id: "wiring-rewarm-engine", displayName: "Wiring re-warm engine", isLocal: true)
    let supportsStreaming = false

    private(set) var prepareCount = 0
    private(set) var rewarmCount = 0
    private(set) var parkedRewarms = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var rewarmInFlight: Task<Void, Error>?

    func prepare() async throws {
        prepareCount += 1
    }

    func rewarm() async throws {
        rewarmCount += 1
        let task = Task { try await self.performRewarm() }
        rewarmInFlight = task
        defer { rewarmInFlight = nil }
        try await task.value
    }

    private func performRewarm() async throws {
        parkedRewarms += 1
        await withCheckedContinuation { gate = $0 }
    }

    func openGate() {
        gate?.resume()
        gate = nil
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        if let rewarmInFlight {
            try? await rewarmInFlight.value
        }
        return Transcript(
            text: "wired", segments: [], engine: identity, isFinal: true,
            audioDuration: buffer.audioDuration)
    }
}

// MARK: - The widget's level source

/// The input level the composed loop's live widget draws, as a plain value the test scripts.
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