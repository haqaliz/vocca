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

import Carbon.HIToolbox
import VoccaBootstrap
import VoccaCore
import VoccaInject
import XCTest

/// The `loop-wiring` Task 4 composed-loop acceptance: the **real** machine, watchdog and pipeline
/// driven through the composition root — `DictationLoopRoot` — over fakes everywhere the system
/// would be touched.
///
/// `HarnessTests` can reach `VoccaBootstrap`: the test target depends on the `VoccaNetworkProbe`
/// executable, and SwiftPM gives a test target the executable's whole dependency closure — the
/// same mechanism by which these tests already import `VoccaCore`, `VoccaUI` and the other modules
/// without declaring them directly. So the acceptance is asserted **through the root's assembly
/// recipe**: the root is constructed with fakes substituted where the system is unreachable —
/// `RecordingAudioSource` for the microphone, the shared `Keyboard`/`TruthfulKeyState` for the
/// physical key read, a `FakeTimer` for the watchdog's clock, a synchronous deferral for the
/// run-loop hop, a `FakeHotkeyEventSource` for the tap, fake focused-app/Secure Input reads for
/// `TargetResolution`, the shared `StubEngine` for ASR, a ledger injector, a ledger holder and a
/// recording panel.
///
/// ## What is measured, and what is not
///
/// Everything with a branch in it — the machine, the watchdog, the sink, the pipeline — is real.
/// What the fakes stand in for is the half CI structurally cannot execute (the tap adapter
/// precedent): the microphone graph, the `CGEvent` tap, the AX calls, the pasteboard, the journal
/// on disk. The ledger fakes are what make "100 cycles" an assertion on counters rather than a
/// claim.
///
/// `@MainActor` because the root is: the tap's side of the seam lives in the one isolation domain,
/// and driving it from anywhere else would be the race the seam exists to prevent.
@MainActor
final class DictationLoopTests: XCTestCase {

    // MARK: - The shipped configuration

    /// ⌥Space, hold-to-talk — the shipped binding (`PRODUCT_SPEC.md:127`).
    private static let configuration = HotkeyConfiguration(
        keyCode: 49, modifiers: [.option], activation: .holdToTalk)

    /// The same binding in toggle mode — the R6 second configuration, same key and chord.
    private static let toggleConfiguration = HotkeyConfiguration(
        keyCode: 49, modifiers: [.option], activation: .toggle)

    /// One delivered transcript's text, verbatim from `StubEngine`'s transcription of `[1, 2, 3]`.
    private static let deliveredText = "1 2 3"

    // MARK: - The composed harness

    /// One composed loop over fakes: the root plus the ledgers the acceptance is asserted against.
    ///
    /// Everything the root owns is real; everything the root was given is fake, and each fake is
    /// exposed here so an assertion is made against what it *recorded* rather than against a call
    /// the root is believed to have made.
    @MainActor
    private struct Harness {
        let clock: TestClock
        let keyboard: Keyboard
        let keyState: TruthfulKeyState
        let source: RecordingAudioSource
        let toggleSource: RecordingAudioSource
        let timer: FakeTimer
        let toggleTimer: FakeTimer
        let healthTimer: FakeTimer
        let widgetClock: FakeTimer
        let tap: FakeHotkeyEventSource
        let resolver: DictationEngineResolver
        let injector: LedgerInjector
        let holder: LedgerHolder
        let focusedApp: FakeFocusedApp
        let secureInput: FakeSecureInput
        let appName: FakeRunningAppName
        let panel: RecordingPanel
        let liveLevel: any LiveLevelSource
        let root: DictationLoopRoot

        init(
            engine: any ASREngine,
            injectorResult: InjectionResult,
            held: HeldTranscript? = nil,
            samples: [Float] = [1, 2, 3],
            prepared: Bool = true,
            liveLevel: any LiveLevelSource = FakeLevelSource(level: 0)
        ) {
            let clock = TestClock()
            let keyboard = Keyboard()
            let source = RecordingAudioSource()
            source.nextSamples = samples
            let toggleSource = RecordingAudioSource()
            let timer = FakeTimer()
            let toggleTimer = FakeTimer()
            let healthTimer = FakeTimer()
            let widgetClock = FakeTimer()
            let tap = FakeHotkeyEventSource()
            let focusedApp = FakeFocusedApp(
                identity: FocusedAppIdentity(bundleID: "com.apple.Notes", windowTitle: "The Draft"))
            let secureInput = FakeSecureInput()
            let appName = FakeRunningAppName()
            let holder = LedgerHolder(held: held)
            let injector = LedgerInjector(result: injectorResult)
            let targetResolution = TargetResolution(
                focusedApp: focusedApp, secureInput: secureInput)
            let panel = RecordingPanel(holder: holder)
            let resolver = DictationEngineResolver(selection: .defaultSelection) { _ in engine }
            let pipeline = DictationPipeline(engine: engine, injector: injector, holder: holder)
            let root = DictationLoopRoot(
                configuration: DictationLoopTests.configuration,
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
                toggleConfiguration: DictationLoopTests.toggleConfiguration,
                toggleSource: toggleSource,
                toggleTimer: toggleTimer,
                runningAppName: appName,
                widgetClock: widgetClock,
                liveLevel: liveLevel)

            self.clock = clock
            self.keyboard = keyboard
            self.keyState = TruthfulKeyState(keyboard)
            self.source = source
            self.toggleSource = toggleSource
            self.timer = timer
            self.toggleTimer = toggleTimer
            self.healthTimer = healthTimer
            self.widgetClock = widgetClock
            self.tap = tap
            self.resolver = resolver
            self.injector = injector
            self.holder = holder
            self.focusedApp = focusedApp
            self.secureInput = secureInput
            self.appName = appName
            self.panel = panel
            self.liveLevel = liveLevel
            self.root = root

            if prepared {
                root.markEnginePrepared()
            }
        }

        // MARK: The gestures

        /// One full hold-to-talk cycle: chord down, chord up. The opening completes on the
        /// synchronous deferral inside the key-down, exactly as `ScheduledWatchdog` orders it.
        func oneCycle() {
            keyboard.hold(DictationLoopTests.configuration)
            _ = root.holdToTalk.scheduledWatchdog.receive(
                event(.keyDown, DictationLoopTests.configuration.keyCode, [.option]))
            _ = root.holdToTalk.scheduledWatchdog.receive(
                event(.keyUp, DictationLoopTests.configuration.keyCode, [.option]))
            keyboard.release(DictationLoopTests.configuration.keyCode)
        }

        /// Starts a session and leaves it recording (the key still physically held).
        func pressAndRecord() {
            keyboard.hold(DictationLoopTests.configuration)
            _ = root.holdToTalk.scheduledWatchdog.receive(
                event(.keyDown, DictationLoopTests.configuration.keyCode, [.option]))
        }

        /// Lets the router's unstructured tasks run until `condition` holds, then asserts it.
        ///
        /// The router delivers each session's outcome through `Task` hops (the resolution actor,
        /// the engine actor, the pipeline), so the drive and the observation are separated by the
        /// main actor's queue. Yielding is what turns the queue.
        func drain(until condition: @escaping () async -> Bool, _ message: String) async {
            var attempts = 0
            while !(await condition()) && attempts < 1_000 {
                await Task.yield()
                attempts += 1
            }
            let held = await condition()
            XCTAssertTrue(held, message)
        }

        /// The real-time form of ``drain(until:_:)``, for paths that cross an actual sleep.
        ///
        /// ``drain``'s pure yield loop cannot wait out a real `Task.sleep` — the gated engine's
        /// parked transcribe — so this form interleaves short sleeps with the yields, bounded by
        /// a deadline rather than by a turn count.
        func drainRealtime(until condition: @escaping () async -> Bool, _ message: String) async {
            let deadline = Date().addingTimeInterval(10)
            while !(await condition()) && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let held = await condition()
            XCTAssertTrue(held, message)
        }
    }

    // MARK: - The composed acceptance

    /// The R8-1 acceptance over the composed root: 100 cycles → 100 started, 100 ended, 0
    /// overlapping, 0 orphaned, 100 transcripts delivered — and every delivery carries the target
    /// context the root resolved at key-down (S1: inject into the *same* context at key-up).
    func testOneHundredComposedCyclesDeliverEveryTranscriptIntoTheKeyDownContext() async {
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        for cycle in 1...100 {
            harness.oneCycle()
            await harness.drain(
                until: { await harness.injector.calls.count == cycle },
                "cycle \(cycle): the transcript must reach the injector")
        }

        XCTAssertEqual(
            harness.source.beginCount, 100,
            "100 started — the microphone opened once per press")
        XCTAssertEqual(
            harness.source.endCount, 100,
            "100 ended — the microphone closed once per release")
        XCTAssertEqual(
            harness.source.overlappingBegins, 0,
            "0 overlapping — no session began inside another session's opening")
        XCTAssertEqual(
            harness.source.closesWithoutOpen, 0,
            "0 orphaned — no microphone closed without an open to pair it with")
        let calls = await harness.injector.calls
        XCTAssertEqual(
            calls.count, 100,
            "100 transcripts delivered-or-held — every session's text reached the injector")
        XCTAssertEqual(
            calls.map(\.text), Array(repeating: Self.deliveredText, count: 100),
            "every transcript is the stub engine's transcription of the captured buffer")
        XCTAssertEqual(
            calls.map(\.target),
            Array(repeating: expectedTarget(), count: 100),
            "every delivery is into the context resolved at key-down, unchanged")
        let holdCalls = await harness.holder.holdCalls
        XCTAssertEqual(holdCalls, 0, "no delivery may touch the holder")
        XCTAssertEqual(harness.panel.heldPresentations, 0, "no delivery may present the failsafe")
        XCTAssertEqual(harness.panel.reasons, [], "no delivery may show a reason notice")
    }

    // MARK: - Failure injection, per the spec

    /// `transcribe` throws → the `.transcriptionFailed` reason-only surface; the injector is never
    /// called and the holder is never touched (PRD R5: "Nothing was lost — you can try again").
    func testATranscribeFailureSurfacesTranscriptionFailedAndInjectsNothing() async {
        let harness = Harness(
            engine: ScriptedTranscribeEngine(error: FakeTranscriptionError.boom),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        harness.oneCycle()
        await harness.drain(
            until: { !harness.panel.reasons.isEmpty },
            "the failure must reach the panel as a reason-only notice")

        XCTAssertEqual(harness.panel.reasons, [.transcriptionFailed])
        XCTAssertEqual(harness.panel.heldPresentations, 0)
        let calls = await harness.injector.calls
        XCTAssertEqual(calls, [])
        let holdCalls = await harness.holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
        let currentCalls = await harness.holder.currentCalls
        XCTAssertEqual(currentCalls, 0)
    }

    /// The ladder exhausts → `.widgetFailsafe`, and the holder (the journal, in production)
    /// already holds: the pipeline surfaces the held transcript, and the panel presents it —
    /// read exactly once, never held again.
    func testLadderExhaustionPresentsTheHeldTranscript() async {
        let held = HeldTranscript(
            text: Self.deliveredText, reason: .exhausted, targetAppName: nil,
            capturedAt: .seconds(7))
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .widgetFailsafe, attempted: [.accessibility, .clipboardPaste],
                verified: false, elapsed: .zero),
            held: held)

        harness.oneCycle()
        await harness.drain(
            until: { harness.panel.heldPresentations == 1 },
            "the held transcript must reach the panel")

        XCTAssertEqual(harness.panel.heldPresentations, 1)
        XCTAssertEqual(harness.panel.heldTranscripts, [held])
        XCTAssertEqual(harness.panel.reasons, [])
        let currentCalls = await harness.holder.currentCalls
        XCTAssertEqual(
            currentCalls, 2,
            "the holder is read twice on the failsafe path: once by the pipeline to surface the "
                + "held transcript, and once by the panel's presentation — exactly as the shipped "
                + "composition reads it (the pipeline's own read-once contract is pinned in "
                + "DictationPipelineTests)")
        let holdCalls = await harness.holder.holdCalls
        XCTAssertEqual(holdCalls, 0, "the ladder's handoff already held — the pipeline never holds")
    }

    /// An empty captured buffer — the 20 ms press — never asks the engine and never calls the
    /// injector: the empty-buffer policy is decided before transcription.
    func testAnEmptyBufferSkipsTheInjector() async {
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero),
            samples: [])

        harness.oneCycle()
        await harness.drain(
            until: { await harness.injector.calls.isEmpty },
            "the empty session's routing must settle")

        let calls = await harness.injector.calls
        XCTAssertEqual(calls, [])
        XCTAssertEqual(harness.panel.heldPresentations, 0)
        XCTAssertEqual(harness.panel.reasons, [])
        XCTAssertEqual(harness.source.endCount, 1, "the microphone still closed — the session ended")
    }

    /// A cancelled session (Escape) discards: no transcribe, no inject, no holder touch — even
    /// though the microphone had already captured audio.
    func testACancelledSessionNeverInjects() async {
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        harness.pressAndRecord()
        XCTAssertEqual(harness.source.beginCount, 1, "the session is recording")
        _ = harness.root.cancel()
        await harness.drain(
            until: { await harness.injector.calls.isEmpty },
            "the cancellation's routing must settle")

        let calls = await harness.injector.calls
        XCTAssertEqual(calls, [])
        XCTAssertEqual(harness.source.endCount, 1, "cancelling still closed the microphone")
        let holdCalls = await harness.holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
        let currentCalls = await harness.holder.currentCalls
        XCTAssertEqual(currentCalls, 0)
        XCTAssertEqual(harness.panel.heldPresentations, 0)
        XCTAssertEqual(harness.panel.reasons, [])
    }

    // MARK: - Esc, routed to the machine's cancel path (PRODUCT_SPEC.md:129)

    /// **Esc during RECORDING, through the tap.** The Escape key-down arrives at the root's sink;
    /// the session's cancel route ends it as `.userCancelled` — the one `EndReason` permitted to
    /// discard — and nothing is transcribed or injected. The Escape itself is swallowed: the
    /// session acted on it, so the focused application never sees it (`SessionKeyPolicy`).
    func testEscDuringRecordingCancelsTheSessionAndInjectsNothing() async {
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        harness.pressAndRecord()
        XCTAssertEqual(harness.source.beginCount, 1, "the session is recording")

        let disposition = harness.tap.deliver(event(.keyDown, UInt16(kVK_Escape), []))
        await harness.drain(
            until: { await harness.injector.calls.isEmpty },
            "the cancellation's routing must settle")

        XCTAssertEqual(
            disposition, .swallow,
            "an Escape the session acted on must not reach the focused application")
        XCTAssertEqual(
            harness.tap.charactersTyped(for: UInt16(kVK_Escape)), 0,
            "the focused application never saw the Escape key-down")
        XCTAssertEqual(harness.source.endCount, 1, "cancelling still closed the microphone")
        XCTAssertEqual(
            harness.source.closesWithoutOpen, 0,
            "the close is the session's own — not an orphaned teardown")
        let calls = await harness.injector.calls
        XCTAssertEqual(calls, [], "a cancelled session must never inject")
        let holdCalls = await harness.holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
        let currentCalls = await harness.holder.currentCalls
        XCTAssertEqual(currentCalls, 0)
        XCTAssertEqual(harness.panel.heldPresentations, 0)
        XCTAssertEqual(harness.panel.reasons, [])
        XCTAssertEqual(
            harness.root.widgetStore.state.state, .idle,
            "the discard returns the widget to IDLE")
    }

    /// **Esc during TRANSCRIBING.** The session has already ended — the machine answers
    /// `.unchanged` — but the pipeline's transcribe is in flight, parked on the gated engine's
    /// sleep. The Escape key-down cancels the transcription task; the engine observes the
    /// cancellation; and a cancelled transcription never injects. The discard is not a failure:
    /// no reason notice, no failsafe — the user asked to abandon, and the widget returns to IDLE.
    func testEscDuringTranscribingCancelsTheInFlightTranscriptionAndInjectsNothing() async {
        let engine = GatedTranscribeEngine()
        let harness = Harness(
            engine: engine,
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        harness.oneCycle()
        await harness.drainRealtime(
            until: { await engine.transcribeCalls == 1 },
            "the session's audio must reach the engine's transcribe before Escape can abort it")
        XCTAssertEqual(
            harness.root.widgetStore.state.state, .transcribing,
            "the widget is showing TRANSCRIBING while the transcription is in flight")

        let disposition = harness.tap.deliver(event(.keyDown, UInt16(kVK_Escape), []))
        await harness.drainRealtime(
            until: { await engine.sawCancellation },
            "the in-flight transcribe must observe the cancellation")

        XCTAssertEqual(
            disposition, .swallow,
            "an Escape the loop acted on must not reach the focused application")
        XCTAssertEqual(
            harness.tap.charactersTyped(for: UInt16(kVK_Escape)), 0,
            "the focused application never saw the Escape key-down")
        let calls = await harness.injector.calls
        XCTAssertEqual(calls, [], "a cancelled transcription must never inject")
        let holdCalls = await harness.holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
        XCTAssertEqual(harness.panel.heldPresentations, 0)
        XCTAssertEqual(harness.panel.reasons, [])
        XCTAssertEqual(
            harness.root.widgetStore.state.state, .idle,
            "the abort returns the widget to IDLE")
    }

    /// **The readiness gate, wired through the root**: an unprepared engine refuses honestly —
    /// the `.modelUnavailable` reason-only notice — and **the microphone never opens**. The
    /// refusal goes through the machine's own `captureUnavailable` funnel (via the root's
    /// readiness gate on the audio source), so the hotkey survives the refusal: once the engine
    /// is prepared, the very next press records.
    func testAnUnpreparedEngineRefusesBeforeTheMicrophoneOpens() async {
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero),
            prepared: false)

        harness.pressAndRecord()
        await harness.drain(
            until: { !harness.panel.reasons.isEmpty },
            "the refusal must reach the panel")

        XCTAssertEqual(harness.panel.reasons, [.modelUnavailable])
        XCTAssertEqual(
            harness.source.beginCount, 0,
            "the mic never opens — the readiness gate refused before the microphone was asked")
        XCTAssertEqual(
            harness.tap.charactersTyped(for: 49), 0,
            "the press was still swallowed — no NO-BREAK SPACE reached the field")

        // The refusal is not a dead hotkey: the gate opened, the next press records and delivers.
        harness.root.markEnginePrepared()
        harness.oneCycle()
        await harness.drain(
            until: { await harness.injector.calls.count == 1 },
            "after preparation the same hotkey must record and deliver")
        XCTAssertEqual(harness.source.beginCount, 1)
        let calls = await harness.injector.calls
        XCTAssertEqual(calls.map(\.text), [Self.deliveredText])
    }

    // MARK: - The tap, armed

    /// The root arms the tap and starts the ~1 s health poll — the two obligations the
    /// composition root exists to discharge (`TapHealthTimer` holds the observer so the
    /// disablement graph stays alive).
    func testTheRootArmsTheTapAndStartsTheHealthPoll() {
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        XCTAssertEqual(harness.tap.startCount, 1, "the root arms the tap exactly once")
        XCTAssertEqual(
            harness.healthTimer.cadencesRequested, [.seconds(1)],
            "the health poll runs at the shipped one-second cadence")
        XCTAssertTrue(harness.healthTimer.isRunning)
    }

    // MARK: - The toggle configuration (R6)

    /// The active mode defaults to hold-to-talk, and the tap's route follows the switch: a press
    /// through the tap starts the hold-to-talk machine's microphone and leaves the toggle
    /// machine's untouched; after the switch, the same press does the opposite.
    func testTheActiveModeDefaultsToHoldToTalkAndTheSinkFollowsTheSwitch() async {
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        XCTAssertEqual(harness.root.activeMode, .holdToTalk)

        // Through the tap: the mode-routing sink forwards to the hold-to-talk wiring.
        harness.keyboard.hold(Self.configuration)
        _ = harness.tap.deliver(event(.keyDown, Self.configuration.keyCode, [.option]))
        _ = harness.tap.deliver(event(.keyUp, Self.configuration.keyCode, [.option]))
        harness.keyboard.release(Self.configuration.keyCode)
        await harness.drain(
            until: { await harness.injector.calls.count == 1 },
            "the hold-to-talk session must deliver")
        XCTAssertEqual(harness.source.beginCount, 1, "the hold-to-talk microphone opened")
        XCTAssertEqual(
            harness.toggleSource.beginCount, 0,
            "the toggle machine is wired but not active — its microphone never opened")

        harness.root.setActiveMode(.toggle)
        XCTAssertEqual(harness.root.activeMode, .toggle)

        harness.keyboard.hold(Self.toggleConfiguration)
        _ = harness.tap.deliver(event(.keyDown, Self.toggleConfiguration.keyCode, [.option]))
        _ = harness.tap.deliver(event(.keyUp, Self.toggleConfiguration.keyCode, [.option]))
        _ = harness.tap.deliver(event(.keyDown, Self.toggleConfiguration.keyCode, [.option]))
        _ = harness.tap.deliver(event(.keyUp, Self.toggleConfiguration.keyCode, [.option]))
        harness.keyboard.release(Self.toggleConfiguration.keyCode)
        await harness.drain(
            until: { await harness.injector.calls.count == 2 },
            "the toggle session must deliver")
        XCTAssertEqual(
            harness.toggleSource.beginCount, 1,
            "after the switch the toggle machine's microphone opened")
        XCTAssertEqual(harness.source.beginCount, 1, "the hold-to-talk microphone stayed shut")
    }

    /// The toggle configuration's composed cycle: press → runs (the key-up does **not** end it,
    /// which is the mode's defining difference) → press again → ended via `.toggledOff`, and the
    /// transcript is delivered like any other.
    func testTheToggleConfigurationRunsAComposedCycleEndingViaToggledOff() async {
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))
        harness.root.setActiveMode(.toggle)

        harness.keyboard.hold(Self.toggleConfiguration)
        // Press 1: start.
        _ = harness.tap.deliver(event(.keyDown, Self.toggleConfiguration.keyCode, [.option]))
        XCTAssertEqual(harness.toggleSource.beginCount, 1, "the session is running")
        // The key-up must not end a toggle session.
        _ = harness.tap.deliver(event(.keyUp, Self.toggleConfiguration.keyCode, [.option]))
        XCTAssertEqual(
            harness.toggleSource.endCount, 0,
            "the key-up is not a stop in toggle mode — the session is still running")
        // Press 2: `.toggledOff`.
        _ = harness.tap.deliver(event(.keyDown, Self.toggleConfiguration.keyCode, [.option]))
        _ = harness.tap.deliver(event(.keyUp, Self.toggleConfiguration.keyCode, [.option]))
        harness.keyboard.release(Self.toggleConfiguration.keyCode)

        await harness.drain(
            until: { await harness.injector.calls.count == 1 },
            "the toggled-off session's transcript must be delivered")
        XCTAssertEqual(harness.toggleSource.beginCount, 1)
        XCTAssertEqual(harness.toggleSource.endCount, 1)
        XCTAssertEqual(harness.toggleSource.overlappingBegins, 0)
        XCTAssertEqual(harness.toggleSource.closesWithoutOpen, 0)
        let calls = await harness.injector.calls
        XCTAssertEqual(calls.map(\.text), [Self.deliveredText])
    }

    /// The toggle configuration's unconditional backstop: the ceiling ends a toggle session whose
    /// stopping press never comes, through the watchdog's own timer.
    func testTheToggleConfigurationEndsAtTheCeiling() async {
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))
        harness.root.setActiveMode(.toggle)

        harness.keyboard.hold(Self.toggleConfiguration)
        _ = harness.tap.deliver(event(.keyDown, Self.toggleConfiguration.keyCode, [.option]))
        _ = harness.tap.deliver(event(.keyUp, Self.toggleConfiguration.keyCode, [.option]))
        XCTAssertEqual(harness.toggleSource.beginCount, 1, "the toggle session is running")

        harness.clock.now = SessionCeiling.default
        harness.toggleTimer.tick()

        await harness.drain(
            until: { await harness.injector.calls.count == 1 },
            "the ceiling-ended session's transcript must be delivered")
        XCTAssertEqual(harness.toggleSource.endCount, 1, "the ceiling closed the microphone")
    }

    /// The tap's death ends a toggle session too — the `.tapDisabled` route, which in toggle mode
    /// is the only stop a dead tap can still deliver (`SessionRules.swift:357-359`).
    func testTheToggleConfigurationEndsViaATapDisablement() async {
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))
        harness.root.setActiveMode(.toggle)

        harness.keyboard.hold(Self.toggleConfiguration)
        _ = harness.tap.deliver(event(.keyDown, Self.toggleConfiguration.keyCode, [.option]))
        _ = harness.tap.deliver(event(.keyUp, Self.toggleConfiguration.keyCode, [.option]))
        XCTAssertEqual(harness.toggleSource.beginCount, 1, "the toggle session is running")

        _ = harness.tap.deliver(
            RawKeyEvent(
                kind: .tapDisabled, keyCode: 0, modifiers: [], isAutorepeat: false,
                timestamp: .zero))

        await harness.drain(
            until: { await harness.injector.calls.count == 1 },
            "the tap-disabled session's transcript must be delivered")
        XCTAssertEqual(harness.toggleSource.endCount, 1, "the disablement closed the microphone")
    }

    // MARK: - The widget projection seam (R4/S1)

    /// The display-name resolution feeds the projection: the root resolves the focused
    /// application's name through the injected reader, and the DELIVERED confirmation carries it
    /// ("→ Notes"), so the widget says where the text went.
    func testTheDisplayNameResolutionFeedsTheProjectionAndTheDeliveredConfirmation() async {
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))
        harness.appName.names["com.apple.Notes"] = "Notes"

        harness.oneCycle()
        await harness.drain(
            until: {
                if case .delivered(let name) = harness.root.widgetStore.state.state {
                    return name == "Notes"
                }
                return false
            },
            "the delivered confirmation must carry the resolved display name")

        if case .delivered(let name) = harness.root.widgetStore.state.state {
            XCTAssertEqual(name, "Notes")
        } else {
            XCTFail("the widget must be showing DELIVERED, got \(harness.root.widgetStore.state.state)")
        }
    }

    /// The widget clock drives the store's timers at the root's cadence: a DELIVERED
    /// confirmation collapses to IDLE once the injected clock passes the 600 ms deadline, and the
    /// clock stops — a live timer over an idle widget is the battery shape this repository
    /// forbids.
    func testTheRootsWidgetClockCollapsesTheDeliveredConfirmationAndStops() async {
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        harness.oneCycle()
        await harness.drain(
            until: {
                if case .delivered = harness.root.widgetStore.state.state { return true }
                return false
            },
            "the delivered confirmation must appear before the collapse can be measured")
        XCTAssertTrue(harness.widgetClock.isRunning, "the widget clock runs while DELIVERED")

        harness.clock.now = harness.clock.now + .seconds(1)
        harness.widgetClock.tick()

        XCTAssertEqual(harness.root.widgetStore.state.state, .idle, "the confirmation collapsed")
        XCTAssertFalse(harness.widgetClock.isRunning, "the widget clock stopped at IDLE")
    }

    // MARK: - The live widget's window, wired (R4)

    /// The composition recipe for the live pill: the root's live widget is bound to **the same
    /// store the effect stream feeds**, with the injected level source, and the window is
    /// **lazy** — `configure`'s window-freedom is structural, because no window exists until the
    /// first non-IDLE state makes one necessary. The lazy construction then runs through the
    /// real effect stream: a press constructs the panel, and the panel follows the store.
    func testTheRootConstructsTheLiveWidgetBoundToItsStoreAndLevelSource() async {
        let level = FakeLevelSource(level: 0.5)
        let harness = Harness(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero),
            liveLevel: level)

        XCTAssertTrue(
            harness.root.liveWidget.store === harness.root.widgetStore,
            "the live widget must be bound to the same store the effect stream folds")
        XCTAssertTrue(
            (harness.root.liveWidget.level as AnyObject) === level,
            "the injected level source must be the one the widget's waveform draws")
        XCTAssertNil(
            harness.root.liveWidget.presentedPanel,
            "configure created no window — the panel is constructed lazily")

        harness.pressAndRecord()
        await harness.drain(
            until: { harness.root.liveWidget.presentedPanel != nil },
            "the first non-IDLE state must construct the live widget's window")
        XCTAssertEqual(
            harness.root.liveWidget.presentedPanel?.isVisible, true,
            "the constructed panel orders itself front — the pill is showing RECORDING")
        XCTAssertTrue(
            harness.root.liveWidget.presentedPanel?.styleMask.contains(.nonactivatingPanel) == true,
            "the live pill must never activate Vocca (PRODUCT_SPEC.md:22)")
    }
}

// MARK: - The microphone, with an AudioBuffer payload

/// The `RecordingSource` shape (`SessionTestDoubles.swift`) with the machine's real buffer type:
/// every session hands over an `AudioBuffer`, so the composed loop's custody ledger speaks the
/// same vocabulary as the pipeline it feeds.
final class RecordingAudioSource: SessionAudioSource {
    typealias Buffer = AudioBuffer

    private(set) var isOpen = false
    private(set) var beginCount = 0
    private(set) var endCount = 0
    /// `beginCapture()` while already open — the "0 overlapping" measure.
    private(set) var overlappingBegins = 0
    /// `endCapture()` while closed — the "0 orphaned" measure.
    private(set) var closesWithoutOpen = 0

    /// What the next `beginCapture()` reports.
    var nextStart: CaptureStart = .opened

    /// What the next `endCapture()` hands over. `[]` is the empty press.
    var nextSamples: [Float] = [1, 2, 3]

    func beginCapture() -> CaptureStart {
        if isOpen { overlappingBegins += 1 }
        guard nextStart == .opened else { return .unavailable }
        beginCount += 1
        isOpen = true
        return .opened
    }

    func endCapture() -> AudioBuffer {
        if !isOpen { closesWithoutOpen += 1 }
        endCount += 1
        isOpen = false
        return AudioBuffer(
            samples: nextSamples, sampleRate: AudioBuffer.interchangeSampleRate)
    }
}

// MARK: - The target-resolution reads

/// The focused application, as a fact the test sets. Class-bound for the reason the seam is:
/// `TargetResolution` holds it across the actor boundary.
///
/// `@unchecked Sendable` because the seam is `Sendable` and the fake's identity is set from the
/// test's main-actor context, before any resolution await — the same confinement the shared
/// `TestClock` enjoys, made explicit because the protocol the compiler cannot see through.
final class FakeFocusedApp: FocusedAppReading, @unchecked Sendable {
    var identity: FocusedAppIdentity?
    private(set) var reads = 0

    init(identity: FocusedAppIdentity?) {
        self.identity = identity
    }

    func focusedApp() async -> FocusedAppIdentity? {
        reads += 1
        return identity
    }
}

/// Secure Input, off by default — a password field is not part of the composed acceptance. Same
/// `@unchecked Sendable` confinement as ``FakeFocusedApp``.
final class FakeSecureInput: SecureInputReading, @unchecked Sendable {
    var active = false

    func isSecureInputActive() async -> Bool {
        active
    }
}

/// The display-name reader, as a table the test sets — "com.apple.Notes" → "Notes", the shape
/// `NSRunningApplication.localizedName` answers. Class-bound for the reason the seam is: the
/// router holds it across its folds.
final class FakeRunningAppName: RunningAppNameReading {
    var names: [String: String] = [:]

    func displayName(bundleID: String) -> String? {
        names[bundleID]
    }
}

// MARK: - The panel

/// The failsafe surface, as a ledger: every presentation recorded, so "presented once" and
/// "never presented" are assertions rather than absences.
@MainActor
final class RecordingPanel: FailsafePresenting {
    private let holder: any TranscriptHolder

    private(set) var heldPresentations = 0
    private(set) var heldTranscripts: [HeldTranscript] = []
    private(set) var reasons: [FailsafeReason] = []

    init(holder: any TranscriptHolder) {
        self.holder = holder
    }

    func presentHeldTranscript() async -> HeldTranscript? {
        guard let transcript = await holder.current() else { return nil }
        heldPresentations += 1
        heldTranscripts.append(transcript)
        return transcript
    }

    func presentReasonOnly(_ reason: FailsafeReason) {
        reasons.append(reason)
    }
}

// MARK: - The engine, injector and holder ledgers

/// What a scripted transcription failure is. The specific error is the engine's business.
private enum FakeTranscriptionError: Error {
    case boom
}

/// An engine the test scripts: `transcribe` either answers `text` or throws. The two real
/// engines cannot run in CI, and `StubEngine` cannot fail by construction.
actor ScriptedTranscribeEngine: ASREngine {
    let identity = EngineIdentity(
        id: "scripted-engine", displayName: "Scripted engine", isLocal: true)
    let supportsStreaming = false
    private let text: String?
    private let error: Error?
    private(set) var transcribeCalls = 0

    init(text: String? = nil, error: Error? = nil) {
        self.text = text
        self.error = error
    }

    func prepare() async throws {}

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        transcribeCalls += 1
        if let error { throw error }
        return Transcript(
            text: text ?? "",
            segments: [],
            engine: identity,
            isFinal: true,
            audioDuration: buffer.audioDuration)
    }
}

/// An engine whose `transcribe` **parks in flight** — the "Esc during TRANSCRIBING" fixture.
///
/// The park is a `Task.sleep` loop, which throws `CancellationError` the moment the enclosing
/// task is cancelled: the engine records that it *observed* the cancellation (the abort is
/// asserted on the engine's own ledger, never on a believed call) and rethrows, so the pipeline's
/// cancellation path is exercised end to end rather than replaced.
actor GatedTranscribeEngine: ASREngine {
    let identity = EngineIdentity(
        id: "gated-engine", displayName: "Gated engine", isLocal: true)
    let supportsStreaming = false
    private(set) var transcribeCalls = 0
    private(set) var sawCancellation = false

    func prepare() async throws {}

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        transcribeCalls += 1
        while true {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                sawCancellation = true
                throw error
            }
        }
    }
}

/// One recorded injection — the injector ledger's row.
fileprivate struct InjectionCall: Equatable {
    let text: String
    let target: TargetContext
}

/// The injector, with a ledger: every call's text and context recorded in order, and one fixed
/// result. An actor, for the boundary reason every other `TextInjector` double is.
actor LedgerInjector: TextInjector {
    private let result: InjectionResult
    fileprivate var calls: [InjectionCall] = []

    init(result: InjectionResult) {
        self.result = result
    }

    func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
        calls.append(InjectionCall(text: text, target: target))
        return result
    }
}

/// The holder, with a ledger: every method's call count recorded, and a transcript the test
/// preloads to stand in for the ladder's handoff.
actor LedgerHolder: TranscriptHolder {
    private var held: HeldTranscript?
    private(set) var holdCalls = 0
    private(set) var currentCalls = 0
    private(set) var releaseCalls = 0

    init(held: HeldTranscript? = nil) {
        self.held = held
    }

    func hold(_ transcript: HeldTranscript) async throws {
        holdCalls += 1
        held = transcript
    }

    func current() async -> HeldTranscript? {
        currentCalls += 1
        return held
    }

    func release() async {
        releaseCalls += 1
    }
}

// MARK: - The widget's level source

/// The input level the composed loop's live widget draws, as a plain value the test scripts.
///
/// A class rather than the projection tests' struct so the recipe assertion can be an **identity**
/// check — "the level source the test injected is the one the widget holds" is the composition
/// claim, and `===` is the only form of it that cannot be satisfied by a different instance that
/// happens to read the same. Final with one immutable stored property, so `Sendable` (the seam's
/// requirement) is inferred rather than asserted. File-private, like every other same-named fake
/// in this suite: the level source is a common double and each file owns its own spelling.
private final class FakeLevelSource: LiveLevelSource {
    let level: Float

    init(level: Float) {
        self.level = level
    }

    func latestLevel() -> Float { level }
}

// MARK: - Fixture helpers

/// The context the composed loop's focused-app fake resolves at key-down.
fileprivate func expectedTarget() -> TargetContext {
    TargetContext(
        bundleID: "com.apple.Notes", windowTitle: "The Draft", isSecureInput: false)
}

/// One event, stamped with the constant timestamp the machine's own tests use.
fileprivate func event(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: false,
        timestamp: .zero)
}
