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
import VoccaUI
import XCTest

/// **The mode routing composition** (`dual-mode` C11, the machine's owner): the integration
/// gap every aspect of the unit recorded as "not constructed here" — the `SessionModeMachine`
/// owned by the composition root, the chord → intent translation on the tap's own path, the
/// effect application (which effect does what), the system-trigger stops, the menu-bar
/// toggle, and the converse state sink's projection fold + machine bookkeeping.
///
/// The RED reason is the gap itself: `DictationLoopRoot` has no `modeMachine`, no
/// `selectMode(_:)` and no `converseLoopEnded()` — this file does not compile until the
/// routing composition exists (the `reply-seam` compile-time-RED precedent).
///
/// ## What is real here
///
/// The root (`DictationLoopRoot` — its tap, its wirings, its router), the mode machine
/// (root-owned), the `ConverseLoopDriver` over fake seams (a scripted capture — never a real
/// microphone; the driver's ASR/cleanup/synthesizer recipes are lazy and never resolved by
/// these tests), and the loop. Everything the system would be touched through is fake, the
/// `AppBootstrapWiringTests`/`DictationLoopTests` harness shape.
///
/// ## What is pinned
///
/// - the converse chord press starts the driver and mints the machine's session (R3/R6);
/// - the chord again is the stop affordance's chord leg (D7) — the machine's session ends and
///   the driver stops (R4);
/// - the dictate chord's behavior is byte-for-byte today's — the machine's dictate rows are
///   forwarded to the wiring, which decides (R9; the existing pins are the contract);
/// - a dictate press during a converse session is refused as a total no-op (R1: nothing
///   delivered, nothing minted, the press claimed) and a converse press during a dictation is
///   the mirror;
/// - Esc is **not** the converse stop (D7 — Esc is dictation's cancel; converse has nothing
///   to discard);
/// - the system triggers end the converse driver (R4: continuous listening never outlives
///   them) and the machine's dictate session ends with the wiring's own;
/// - the menu-bar toggle is the explicit switch: from idle it starts the chosen mode, the
///   active mode's row is the session-control stop, the other mode's row is refused (R5);
/// - the loop's states fold the widget projection and the machine's bookkeeping catches up
///   with every stop path (the graph's configuration-change stop bypasses the machine);
/// - a converse start whose capture refuses leaves the machine idle (D5: nothing started, no
///   notice owed) — and so does a press in a composition with no converse wiring;
/// - `tapDisabled` stops the converse driver and still reaches the dictate wiring untouched.
@MainActor
final class ModeRoutingCompositionTests: XCTestCase {

    // MARK: - The shipped bindings

    /// ⌥Space — the shipped dictate binding (`PRODUCT_SPEC.md:127`).
    private static let dictateChord = HotkeyChord(keyCode: 49, modifiers: [.option])

    /// ⌥⇧Space — the shipped converse binding (`PRODUCT_SPEC.md:192`).
    private static let converseChord = HotkeyChord(keyCode: 49, modifiers: [.option, .shift])

    // MARK: - The harness

    /// The composed harness: a real root over fakes, a real `ConverseLoopDriver` over a
    /// scripted capture, and the state sink wired exactly as `configure` wires it (record +
    /// projection fold + machine bookkeeping), so the shipped wiring shape is what the tests
    /// exercise rather than a second, invented copy.
    private final class Harness {
        let root: DictationLoopRoot
        let driver: ConverseLoopDriver
        let capture: ScriptedConverseCapture
        let playback: RecordingPlayback
        let keyboard: Keyboard
        let tap: FakeHotkeyEventSource
        let holdSource: RecordingAudioSource
        let toggleSource: RecordingAudioSource
        let states: RecordingStateBox
        let rootBox: HarnessRootBox

        init(capture: ScriptedConverseCapture = ScriptedConverseCapture()) {
            let clock = TestClock()
            let keyboard = Keyboard()
            let holdSource = RecordingAudioSource()
            let toggleSource = RecordingAudioSource()
            let timer = FakeTimer()
            let toggleTimer = FakeTimer()
            let healthTimer = FakeTimer()
            let widgetClock = FakeTimer()
            let tap = FakeHotkeyEventSource()
            let focusedApp = FakeFocusedApp(
                identity: FocusedAppIdentity(
                    bundleID: "com.apple.Notes", windowTitle: "The Draft"))
            let secureInput = FakeSecureInput()
            let appName = FakeRunningAppName()
            let holder = LedgerHolder()
            let injector = LedgerInjector(
                result: InjectionResult(
                    rung: .clipboardPaste, attempted: [], verified: false, elapsed: .zero))
            let resolver = DictationEngineResolver(selection: .defaultSelection) { _ in
                StubEngine.parakeet()
            }
            let root = DictationLoopRoot(
                configuration: HotkeyConfiguration(
                    keyCode: ModeRoutingCompositionTests.dictateChord.keyCode,
                    modifiers: ModeRoutingCompositionTests.dictateChord.modifiers,
                    activation: .holdToTalk),
                ceiling: SessionCeiling.default,
                clock: clock,
                audioSource: holdSource,
                keyState: TruthfulKeyState(keyboard),
                watchdogTimer: timer,
                healthTimer: healthTimer,
                deferOpening: { $0() },
                tap: tap,
                secureInput: FakeSecureInputState(),
                resolver: resolver,
                targetResolution: TargetResolution(
                    focusedApp: focusedApp, secureInput: secureInput,
                    frontmost: FakeFrontmostApp()),
                panel: RecordingPanel(holder: holder),
                converseChord: ModeRoutingCompositionTests.converseChord,
                toggleConfiguration: HotkeyConfiguration(
                    keyCode: ModeRoutingCompositionTests.dictateChord.keyCode,
                    modifiers: ModeRoutingCompositionTests.dictateChord.modifiers,
                    activation: .toggle),
                toggleSource: toggleSource,
                toggleTimer: toggleTimer,
                runningAppName: appName,
                widgetClock: widgetClock,
                liveLevel: SilentLevelSource(),
                sessionKind: .dictation)
            root.markEnginePrepared()

            let playback = RecordingPlayback()
            let driver = ConverseLoopDriver(
                vad: EnergyVAD(
                    configuration: VADConfiguration(
                        onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10,
                        minimumSilence: 0.20)),
                turnDetector: SilenceThresholdDetector(
                    configuration: SilenceThresholdConfiguration(
                        commitAfterPause: 0.5, minimumUtteranceDuration: 0.2)),
                clock: ContinuousMonotonicClock(),
                gate: EchoGate(),
                capture: capture,
                asrProvider: { nil },
                cleanupProvider: { nil },
                replyGenerator: EchoReplyGenerator(),
                synthesizer: { throw RoutingSynthesizerError.unavailable },
                playback: playback,
                onStateChange: { state in
                    Task { @MainActor in
                        rootBox.value?.converseStateSink?(state)
                    }
                },
                failureSink: { _ in })
            root.converseDriver = driver

            // The state sink, wired exactly as `configure` wires the shipped composition: the
            // honest recording default is kept, the projection fold lands in the widget store,
            // and the machine's bookkeeping catches the loop's own `.idle`.
            let states = RecordingStateBox()
            let rootBox = HarnessRootBox()
            rootBox.root = root
            root.converseStateSink = { state in
                states.values.append(state)
                MainActor.assumeIsolated {
                    guard let root = rootBox.root else { return }
                    root.widgetStore.fold(WidgetProjection.project(turnState: state))
                    if state == .idle { root.converseLoopEnded() }
                }
            }

            self.root = root
            self.driver = driver
            self.capture = capture
            self.playback = playback
            self.keyboard = keyboard
            self.tap = tap
            self.holdSource = holdSource
            self.toggleSource = toggleSource
            self.states = states
            self.rootBox = rootBox
        }

        /// A fresh ⌥⇧Space key-down, exactly as the tap would deliver it.
        @discardableResult
        func pressConverse() -> EventPropagation {
            tap.deliver(
                RawKeyEvent(
                    kind: .keyDown, keyCode: ModeRoutingCompositionTests.converseChord.keyCode,
                    modifiers: ModeRoutingCompositionTests.converseChord.modifiers,
                    isAutorepeat: false, timestamp: .zero))
        }

        /// A fresh ⌥Space key-down, with the physical key held — the hold-to-talk gesture.
        @discardableResult
        func pressDictate() -> EventPropagation {
            keyboard.hold(
                HotkeyConfiguration(
                    keyCode: ModeRoutingCompositionTests.dictateChord.keyCode,
                    modifiers: ModeRoutingCompositionTests.dictateChord.modifiers,
                    activation: .holdToTalk))
            return tap.deliver(
                RawKeyEvent(
                    kind: .keyDown, keyCode: ModeRoutingCompositionTests.dictateChord.keyCode,
                    modifiers: ModeRoutingCompositionTests.dictateChord.modifiers,
                    isAutorepeat: false, timestamp: .zero))
        }

        /// The hold-to-talk release half of a dictate press.
        @discardableResult
        func releaseDictate() -> EventPropagation {
            keyboard.release(ModeRoutingCompositionTests.dictateChord.keyCode)
            return tap.deliver(
                RawKeyEvent(
                    kind: .keyUp, keyCode: ModeRoutingCompositionTests.dictateChord.keyCode,
                    modifiers: ModeRoutingCompositionTests.dictateChord.modifiers,
                    isAutorepeat: false, timestamp: .zero))
        }

        /// The driver's stops are spawned (`stop()` is async; the tap path cannot await) —
        /// bounded main-actor polling, the `AppBootstrapWiringTests` shape.
        func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
            for _ in 0..<2_000 {
                if await condition() { return }
                await Task.yield()
            }
            XCTFail("waitUntil exhausted its bound")
        }
    }

    // MARK: - The converse chord

    /// **The gap closed**: a fresh converse-chord press claims the key and starts the converse
    /// driver — the loop is listening, the machine's session is minted, and the menu bar's
    /// mode row follows the machine's one fact.
    func testTheConverseChordPressStartsTheConverseDriver() async {
        let harness = Harness()

        let disposition = harness.pressConverse()

        XCTAssertEqual(disposition, .swallow, "the converse chord is Vocca's — the app gets nothing")
        XCTAssertEqual(harness.capture.startCount, 1, "the driver's capture was asked to start")
        XCTAssertEqual(harness.capture.stopCount, 0, "nothing asked for a stop")
        XCTAssertEqual(harness.driver.loop.state, .listening, "the loop is listening")
        XCTAssertEqual(harness.root.modeMachine.currentMode, .conversing)
        XCTAssertEqual(harness.root.modeMachine.epoch, 1, "the start minted the first epoch")
        XCTAssertEqual(
            harness.root.menuBarConditions.mode, .conversing,
            "the menu's mode row follows the machine's current mode")
    }

    /// **The stop affordance's chord leg (D7)**: the chord again ends the machine's session and
    /// stops the driver, and the machine is idle again — the next dictate press starts a
    /// dictation, not a refusal.
    func testTheConverseChordAgainStopsTheDriverAndReturnsToIdle() async {
        let harness = Harness()
        _ = harness.pressConverse()
        XCTAssertEqual(harness.root.modeMachine.currentMode, .conversing)

        let disposition = harness.pressConverse()

        XCTAssertEqual(disposition, .swallow, "the second press is claimed too")
        XCTAssertEqual(
            harness.root.modeMachine.currentMode, nil,
            "the session-control stop ends the machine's session")
        await harness.waitUntil { await MainActor.run { harness.capture.stopCount == 1 } }
        XCTAssertEqual(harness.driver.loop.state, .idle, "the driver stopped the loop")
        XCTAssertEqual(
            harness.root.menuBarConditions.mode, .dictation,
            "the menu re-checks the default mode once the machine is idle")

        _ = harness.pressDictate()
        XCTAssertEqual(
            harness.root.holdToTalk.machine.state, .recording,
            "after a converse cycle the dictate chord starts a dictation as always")
        _ = harness.releaseDictate()
        XCTAssertEqual(harness.root.modeMachine.currentMode, nil)
    }

    // MARK: - The dictate chord stays today's path

    /// **R9, the pinned contract**: a dictate press flows through the mode machine's dictate
    /// row (`.started(.dictation)`) and straight into the active dictate wiring — the mic
    /// opens, the session records, the release ends it — and the machine's dictate session
    /// settles when the wiring's session ends.
    func testTheDictateChordStillDrivesTheDictateWiring() async {
        let harness = Harness()

        let disposition = harness.pressDictate()

        XCTAssertEqual(disposition, .swallow, "the dictate chord's own press is claimed as today")
        XCTAssertEqual(
            harness.holdSource.beginCount, 1, "the dictate microphone opened — today's path")
        XCTAssertEqual(harness.root.holdToTalk.machine.state, .recording)
        XCTAssertEqual(harness.root.modeMachine.currentMode, .dictation)
        XCTAssertEqual(harness.capture.startCount, 0, "no converse capture was touched")

        _ = harness.releaseDictate()
        XCTAssertEqual(
            harness.root.modeMachine.currentMode, nil,
            "the machine's dictate session ends with the wiring's own session")
        XCTAssertEqual(harness.root.holdToTalk.machine.state, .idle)
    }

    /// **R1, the no-op that must be total**: a dictate press during a converse session does
    /// nothing — no dictate session, no implicit switching, no ending of the converse session,
    /// and the press itself is claimed (the chord is Vocca's; the refusal never mints).
    func testADictatePressDuringAConverseSessionIsRefusedAndNeverMints() async {
        let harness = Harness()
        _ = harness.pressConverse()

        let disposition = harness.pressDictate()

        XCTAssertEqual(disposition, .swallow, "a refused press of Vocca's own chord is still claimed")
        XCTAssertEqual(
            harness.holdSource.beginCount, 0, "no dictate microphone was asked")
        XCTAssertEqual(harness.root.holdToTalk.machine.state, .idle, "no dictate session")
        XCTAssertEqual(
            harness.root.modeMachine.currentMode, .conversing,
            "the refusal is never a switch — the converse session continues")
        XCTAssertEqual(
            harness.root.modeMachine.epoch, 1,
            "a refusal never mints — the refusal is total, not merely invisible")
        XCTAssertEqual(harness.capture.startCount, 1)
        XCTAssertEqual(harness.capture.stopCount, 0, "the converse session was not ended")
        XCTAssertEqual(harness.driver.loop.state, .listening)
    }

    /// **R1, the mirror**: a converse press during a dictation is refused — the dictation
    /// continues untouched and ends normally on the release, and nothing converse was started.
    func testAConversePressDuringADictationIsRefusedAndTheDictationContinues() async {
        let harness = Harness()
        _ = harness.pressDictate()
        XCTAssertEqual(harness.root.holdToTalk.machine.state, .recording)

        let disposition = harness.pressConverse()

        XCTAssertEqual(disposition, .swallow, "the converse chord is Vocca's even when refused")
        XCTAssertEqual(harness.root.holdToTalk.machine.state, .recording, "the dictation continues")
        XCTAssertEqual(
            harness.root.modeMachine.currentMode, .dictation,
            "the refusal is never a switch")
        XCTAssertEqual(
            harness.root.modeMachine.epoch, 1, "the refusal did not mint")
        XCTAssertEqual(harness.capture.startCount, 0, "nothing converse was started")

        _ = harness.releaseDictate()
        XCTAssertEqual(harness.root.holdToTalk.machine.state, .idle)
        XCTAssertEqual(
            harness.root.modeMachine.currentMode, nil,
            "the dictation's own end settles the machine's session")
    }

    /// **D7 — Esc is not the converse stop**: the session's cancel key is dictation's discard
    /// path; a converse session has nothing to discard, so Escape passes through to the app and
    /// the loop keeps listening.
    func testEscapeIsNotTheConverseStop() async {
        let harness = Harness()
        _ = harness.pressConverse()

        let disposition = harness.tap.deliver(
            RawKeyEvent(
                kind: .keyDown, keyCode: SessionKeyPolicy.escapeKeyCode, modifiers: [],
                isAutorepeat: false, timestamp: .zero))

        XCTAssertEqual(disposition, .passThrough, "Escape is the user's own key while conversing")
        XCTAssertEqual(harness.capture.stopCount, 0, "the converse session was not stopped")
        XCTAssertEqual(harness.driver.loop.state, .listening)
        XCTAssertEqual(harness.root.modeMachine.currentMode, .conversing)
    }

    // MARK: - The system triggers

    /// **R4 — no session outlives a system trigger**: every one of the five ends the converse
    /// session — the driver stops and the machine returns to idle.
    func testEverySystemTriggerEndsTheConverseDriver() async {
        for trigger in SystemTrigger.allCases {
            let harness = Harness()
            _ = harness.pressConverse()
            XCTAssertEqual(harness.root.modeMachine.currentMode, .conversing, "\(trigger)")

            _ = harness.root.observe(trigger)

            await harness.waitUntil { await MainActor.run { harness.capture.stopCount == 1 } }
            XCTAssertEqual(
                harness.root.modeMachine.currentMode, nil,
                "\(trigger) ended the machine's converse session")
            XCTAssertEqual(harness.driver.loop.state, .idle, "\(trigger)")
            XCTAssertEqual(
                harness.root.menuBarConditions.mode, .dictation,
                "\(trigger) returned the menu's mode row to the default")
        }
    }

    /// A system trigger ends the machine's dictate session too — the wiring's own handling is
    /// untouched (its session ends through its own funnel), and the machine follows.
    func testASystemTriggerEndsTheMachinesDictateSessionToo() async {
        let harness = Harness()
        _ = harness.pressDictate()
        XCTAssertEqual(harness.root.holdToTalk.machine.state, .recording)
        XCTAssertEqual(harness.root.modeMachine.currentMode, .dictation)

        _ = harness.root.observe(.audioConfigurationChanged)

        XCTAssertEqual(harness.root.holdToTalk.machine.state, .idle, "the wiring ended its session")
        XCTAssertEqual(
            harness.root.modeMachine.currentMode, nil,
            "the machine's dictate session ended with the wiring's")
    }

    /// **A disabled tap means the key-up that would end a session is never coming** — the
    /// converse session stops (R4: the stop is fed through the machine's stop seam — tapDisabled
    /// is not one of `SystemTrigger`'s five), and the event still reaches the dictate wiring,
    /// which keeps its own tapDisabled semantics untouched.
    func testTapDisabledStopsTheConverseDriverAndStillReachesTheDictateWiring() async {
        let harness = Harness()
        _ = harness.pressConverse()

        let disposition = harness.tap.deliver(
            RawKeyEvent(
                kind: .tapDisabled, keyCode: 0, modifiers: [],
                isAutorepeat: false, timestamp: .zero))

        XCTAssertEqual(disposition, .passThrough, "the idle dictate wiring lets it pass")
        await harness.waitUntil { await MainActor.run { harness.capture.stopCount == 1 } }
        XCTAssertEqual(harness.root.modeMachine.currentMode, nil)
        XCTAssertEqual(harness.driver.loop.state, .idle)
    }

    // MARK: - The menu-bar toggle

    /// **R5 — the explicit switch**: from idle, the menu row starts its mode; the active mode's
    /// row again is the session-control stop (D7's secondary stop).
    func testTheMenuToggleStartsAndStopsConverse() async {
        let harness = Harness()

        harness.root.selectMode(.conversing)

        XCTAssertEqual(harness.root.modeMachine.currentMode, .conversing)
        XCTAssertEqual(harness.capture.startCount, 1, "the menu row started the driver")
        XCTAssertEqual(harness.driver.loop.state, .listening)
        XCTAssertEqual(harness.root.menuBarConditions.mode, .conversing)

        harness.root.selectMode(.conversing)

        XCTAssertEqual(
            harness.root.modeMachine.currentMode, nil,
            "the active mode's row is the session-control stop")
        await harness.waitUntil { await MainActor.run { harness.capture.stopCount == 1 } }
        XCTAssertEqual(harness.driver.loop.state, .idle)
    }

    /// **R1/R5 — the menu offers, the machine routes**: a mid-session toggle to the other mode
    /// is refused, in both directions — never a switch, never an ending.
    func testTheMenuToggleCannotSwitchMidSession() async {
        let harness = Harness()
        _ = harness.pressConverse()
        XCTAssertEqual(harness.root.modeMachine.currentMode, .conversing)

        harness.root.selectMode(.dictation)

        XCTAssertEqual(
            harness.root.modeMachine.currentMode, .conversing,
            "the dictate row during a converse session is refused")
        XCTAssertEqual(harness.capture.stopCount, 0, "the refusal did not end the session")
        XCTAssertEqual(harness.driver.loop.state, .listening)

        let second = Harness()
        _ = second.pressDictate()
        XCTAssertEqual(second.root.modeMachine.currentMode, .dictation)

        second.root.selectMode(.conversing)

        XCTAssertEqual(
            second.root.modeMachine.currentMode, .dictation,
            "the converse row during a dictation is refused")
        XCTAssertEqual(second.capture.startCount, 0, "nothing converse was started")
        XCTAssertEqual(second.root.holdToTalk.machine.state, .recording)
    }

    /// A menu "start dictation" has no gesture behind it — the wiring is gesture-driven, so the
    /// minted session is unwound the moment the wirings answer "no capture in flight": the
    /// machine stays honest, and the menu shows the default mode.
    func testTheMenuDictateRowWhileIdleLeavesTheMachineIdle() async {
        let harness = Harness()

        harness.root.selectMode(.dictation)

        XCTAssertEqual(
            harness.root.modeMachine.currentMode, nil,
            "a menu dictate start with no gesture has nothing to run — the machine stays honest")
        XCTAssertEqual(harness.holdSource.beginCount, 0)
        XCTAssertEqual(harness.root.holdToTalk.machine.state, .idle)
        XCTAssertEqual(harness.root.menuBarConditions.mode, .dictation)
    }

    // MARK: - The projection fold and the bookkeeping

    /// **The `onStateChange` → projection feed**: the loop's states fold the widget's
    /// CONVERSING state (the one source of it) and the session's end returns the widget to
    /// IDLE — the widget-converse aspect's recorded hand-off, wired at last.
    func testTheProjectionFoldsTheConverseTurnStates() async {
        let harness = Harness()
        XCTAssertEqual(harness.root.widgetStore.state.state, .idle)

        _ = harness.pressConverse()

        await harness.waitUntil {
            await MainActor.run {
                harness.root.widgetStore.state.state == .conversing(phase: .listening)
            }
        }
        XCTAssertEqual(
            harness.states.values, [.listening],
            "the loop's states reach the root's sink, in order")

        _ = harness.pressConverse()

        await harness.waitUntil {
            await MainActor.run { harness.root.widgetStore.state.state == .idle }
        }
    }

    /// **The external stop's bookkeeping**: the capture graph's configuration-change callback
    /// stops the driver directly — bypassing the machine — and the loop's `.idle` report ends
    /// the machine's session, so the machine never believes a session the driver no longer runs.
    func testTheStateSinkEndsTheMachinesSessionWhenTheLoopReportsIdle() async {
        let harness = Harness()
        _ = harness.pressConverse()
        XCTAssertEqual(harness.root.modeMachine.currentMode, .conversing)

        // The `composeConverseWiring` shape: the graph's configuration-change callback stops
        // the driver with no machine in the loop.
        await harness.root.converseDriver?.stop()

        await harness.waitUntil { await MainActor.run { harness.capture.stopCount == 1 } }
        XCTAssertEqual(harness.driver.loop.state, .idle)
        XCTAssertEqual(
            harness.root.modeMachine.currentMode, nil,
            "the loop's .idle report ended the machine's converse session")
        XCTAssertEqual(harness.root.menuBarConditions.mode, .dictation)
    }

    // MARK: - The honest refusals

    /// **D5 — a start whose capture refuses**: nothing started, no notice owed, and the
    /// machine's minted session is unwound — the machine and the composition agree that
    /// nothing is running, and the next press can still start a dictation.
    func testAConverseStartWhoseCaptureRefusesLeavesTheMachineIdle() async {
        let capture = ScriptedConverseCapture()
        capture.startError = .unavailable
        let harness = Harness(capture: capture)

        let disposition = harness.pressConverse()

        XCTAssertEqual(disposition, .swallow, "the chord is Vocca's whether or not it can start")
        XCTAssertEqual(
            harness.root.modeMachine.currentMode, nil,
            "a refused capture is not a session — the machine stays honest")
        XCTAssertEqual(harness.driver.loop.state, .idle)

        _ = harness.pressDictate()
        XCTAssertEqual(harness.root.holdToTalk.machine.state, .recording)
        _ = harness.releaseDictate()
    }

    /// A composition with no converse wiring (every headless harness): the press is claimed,
    /// the minted session is unwound, and dictation is untouched.
    func testAConversePressWithNoDriverLeavesTheMachineIdle() async {
        let harness = Harness()
        harness.root.converseDriver = nil

        let disposition = harness.pressConverse()

        XCTAssertEqual(disposition, .swallow)
        XCTAssertEqual(
            harness.root.modeMachine.currentMode, nil,
            "a composition with no converse wiring has no session to run")
        XCTAssertEqual(harness.capture.startCount, 0)

        _ = harness.pressDictate()
        XCTAssertEqual(harness.root.holdToTalk.machine.state, .recording)
        _ = harness.releaseDictate()
    }
}

/// The scripted continuous capture — the `ConverseLoopDriverTests.ScriptedContinuousCapture`
/// shape (file-private there, re-created here): `stop()` ends the stream (the driver's normal
/// terminal), a scripted `startError` throws `.unavailable`, and a second start while open is
/// refused (the ownership pin).
private final class ScriptedConverseCapture: ContinuousAudioSource {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: ContinuousAudioSourceError?
    private var continuation: AsyncStream<AudioBuffer>.Continuation?
    private var isOpen = false

    func start() throws -> AsyncStream<AudioBuffer> {
        startCount += 1
        if let startError { throw startError }
        guard !isOpen else { throw ContinuousAudioSourceError.alreadyStarted }
        isOpen = true
        let (stream, continuation) = AsyncStream.makeStream(of: AudioBuffer.self)
        self.continuation = continuation
        return stream
    }

    func stop() {
        stopCount += 1
        guard isOpen else { return }
        isOpen = false
        continuation?.finish()
        continuation = nil
    }
}

/// The routing tests' playback fake — an actor, the `ProbeConversePlayback` shape (the seam is
/// `Sendable`; the ledger crosses the boundary honestly). Nothing here ever plays.
private actor RecordingPlayback: PlaybackEngine {
    private(set) var playCount = 0
    private(set) var haltCount = 0

    func play(_ stream: AsyncThrowingStream<AudioChunk, Error>) async throws {
        playCount += 1
        for try await _ in stream {}
    }

    func duck() async {}

    func cancelToSilence() async {
        haltCount += 1
    }

    nonisolated func tearDown() {}
}

/// The state sink's recording box — `@unchecked Sendable` because the `@Sendable` sink closure
/// captures it; single-writer (the main actor, via the driver's hop).
private final class RecordingStateBox: @unchecked Sendable {
    var values: [TurnState] = []
}

/// The weak root hand the sink closure hops through — the `WeakRootBox` shape, file-local here.
private final class HarnessRootBox: @unchecked Sendable {
    weak var root: DictationLoopRoot?
}

/// The synthesizer recipe's never-resolved failure — the routing tests never commit an
/// utterance, so the recipe is never asked; a throw keeps the honest "never resolves" shape.
private enum RoutingSynthesizerError: Error {
    case unavailable
}

/// A level source that never moves — the wiring test's `QuietLevelSource` (file-private there).
private struct SilentLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}