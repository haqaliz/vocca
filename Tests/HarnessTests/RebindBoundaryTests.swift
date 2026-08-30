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
import VoccaHotkey
import VoccaInject
import VoccaUI
import XCTest

/// **Rebinding the hotkey at an idle boundary** — `hotkey-rebinding/rebind-boundary`, the aspect
/// that carries the unit's only Fatal-rated risk.
///
/// The binding is immutable end to end: `HotkeyConfiguration`'s fields are `let`,
/// `SessionMachine.configuration` is a `let`, and each `Wiring` bakes it in at construction. So a
/// rebind is not a value update — it is a **rebuild**, and the whole of this file is about the
/// window in which a rebuild could strand a recording on a key nobody is holding (roadmap C1-A,
/// *stuck recording*, rated Fatal).
@MainActor
final class RebindBoundaryTests: XCTestCase {

    /// The chord every harness below launches on — the shipped ⌥Space.
    private static let launchChord = PersistedSettings.defaultHotkeyChord

    // MARK: - Phase 1: the two wirings come from one construction

    /// **The §1 drift guard, at launch.** `init` and `rebind` build the two wirings through one
    /// factory, so what the factory pairs is what both callers get: each configuration with *its
    /// own* microphone and *its own* timer, and neither crossed.
    ///
    /// Crossed timers are the failure this row is planted against, and it is not cosmetic: two
    /// watchdogs sharing one `RepeatingTimer` means the second `start` cancels the first, so the
    /// machine whose timer was taken has no ceiling and no physical-key poll — a hot mic with
    /// nothing left to end it.
    func testTheLaunchWiringsPairEachConfigurationWithItsOwnSourceAndTimer() {
        let harness = Harness()

        XCTAssertEqual(
            harness.root.holdToTalk.configuration,
            HotkeyConfiguration(
                keyCode: Self.launchChord.keyCode, modifiers: Self.launchChord.modifiers,
                activation: .holdToTalk),
            "the hold-to-talk wiring carries the hold-to-talk configuration")
        XCTAssertEqual(
            harness.root.toggle.configuration,
            HotkeyConfiguration(
                keyCode: Self.launchChord.keyCode, modifiers: Self.launchChord.modifiers,
                activation: .toggle),
            "and the toggle wiring carries the toggle one")

        XCTAssertTrue(
            harness.root.holdToTalk.timer === harness.launchHoldTimer,
            "each wiring is woken by the timer it was given")
        XCTAssertTrue(
            harness.root.toggle.timer === harness.launchToggleTimer,
            "and never by the other wiring's — one timer under two watchdogs leaves the loser "
                + "with no ceiling and no key poll")
        XCTAssertFalse(
            harness.root.holdToTalk.timer === harness.root.toggle.timer,
            "two wirings, two timers")
        XCTAssertFalse(
            harness.root.holdToTalk.source === harness.root.toggle.source,
            "and two microphones, so the two machines can never disagree about who owns the input")
    }

    // MARK: - Phase 2: what a rebind can answer

    /// **M5.** The refusals are a **closed set**, and this row is what makes a fourth reason
    /// state itself here rather than arrive as a `default:` somewhere a user never sees.
    ///
    /// A rebind is *returned* rather than merely logged — the Speech tab's model-removal shape,
    /// not activation mode's silent no-op — because a rebind that appears not to have registered
    /// invites a second attempt, and the second attempt is made on a keyboard whose binding the
    /// user is no longer sure of.
    func testTheRefusalsAreAClosedSet() {
        XCTAssertEqual(
            Set(RebindRefusal.allCases), [.sessionInFlight, .notBindable],
            "two reasons a rebind is refused — a third must be named here, and given copy, "
                + "rather than reaching a user as a rebind that silently did nothing")
    }

    /// The three answers are distinguishable, which is the whole reason the outcome is a type
    /// rather than a `Bool`: *nothing changed* and *we would not change it* lead to different
    /// sentences on the page, and a caller that cannot tell them apart writes one of them wrong.
    func testTheThreeOutcomesAreDistinguishable() {
        XCTAssertNotEqual(RebindOutcome.rebound, .unchanged)
        XCTAssertNotEqual(RebindOutcome.unchanged, .refused(.sessionInFlight))
        XCTAssertNotEqual(
            RebindOutcome.refused(.sessionInFlight), .refused(.notBindable),
            "a refusal carries *which* refusal — the reason is the half the user needs")
        XCTAssertEqual(RebindOutcome.refused(.notBindable), .refused(.notBindable))
    }

    // MARK: - The harness

    /// One composed root over fakes, on the `ActivationPersistenceTests` shape: every event is
    /// driven through the **tap**, so what is asserted is which microphone actually opened rather
    /// than which wiring the root claims to be routing to.
    @MainActor
    private struct Harness {
        let keyboard: Keyboard
        let tap: FakeHotkeyEventSource
        let holdToTalkSource: RecordingAudioSource
        let toggleSource: RecordingAudioSource
        /// The two timers the *launch* wirings were built with — the old ones, once a rebind lands.
        let launchHoldTimer: FakeTimer
        let launchToggleTimer: FakeTimer
        /// Every timer a rebuild has minted, in order.
        let timers: TimerFactory
        let settings: EphemeralSettingsStore
        let root: DictationLoopRoot

        init(
            chord: HotkeyChord = RebindBoundaryTests.launchChord,
            activation: HotkeyConfiguration.Activation = PersistedSettings.defaultActivation
        ) {
            let settings = EphemeralSettingsStore(chord: chord, activation: activation)
            let configurations = AppBootstrap.hotkeyConfigurations(chord: chord)
            let keyboard = Keyboard()
            let tap = FakeHotkeyEventSource()
            let holdToTalkSource = RecordingAudioSource()
            let toggleSource = RecordingAudioSource()
            let launchHoldTimer = FakeTimer()
            let launchToggleTimer = FakeTimer()
            let timers = TimerFactory()
            let holder = LedgerHolder()
            let engine = StubEngine.parakeet()

            let root = DictationLoopRoot(
                configuration: configurations.holdToTalk,
                ceiling: SessionCeiling.default,
                clock: TestClock(),
                audioSource: holdToTalkSource,
                keyState: TruthfulKeyState(keyboard),
                watchdogTimer: launchHoldTimer,
                healthTimer: FakeTimer(),
                deferOpening: { $0() },
                tap: tap,
                secureInput: FakeSecureInputState(),
                resolver: DictationEngineResolver(selection: .defaultSelection) { _ in engine },
                targetResolution: TargetResolution(
                    focusedApp: FakeFocusedApp(
                        identity: FocusedAppIdentity(
                            bundleID: "com.apple.Notes", windowTitle: "The Draft")),
                    secureInput: FakeSecureInput()),
                panel: RecordingPanel(holder: holder),
                pipeline: DictationPipeline(
                    engine: engine,
                    injector: LedgerInjector(
                        result: InjectionResult(
                            rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                            elapsed: .zero)),
                    holder: holder),
                settings: settings,
                toggleConfiguration: configurations.toggle,
                toggleSource: toggleSource,
                toggleTimer: launchToggleTimer,
                runningAppName: FakeRunningAppName(),
                widgetClock: FakeTimer(),
                liveLevel: SilentLevelSource())

            self.keyboard = keyboard
            self.tap = tap
            self.holdToTalkSource = holdToTalkSource
            self.toggleSource = toggleSource
            self.launchHoldTimer = launchHoldTimer
            self.launchToggleTimer = launchToggleTimer
            self.timers = timers
            self.settings = settings
            self.root = root
        }
    }
}

// MARK: - The doubles

/// Every timer a rebuild minted, in order — so a test can say *fresh*, not merely *a timer*.
@MainActor
private final class TimerFactory {
    private(set) var made: [FakeTimer] = []

    func make() -> any RepeatingTimer {
        let timer = FakeTimer()
        made.append(timer)
        return timer
    }
}

/// A settings store with no disk behind it, remembering what it was handed.
private final class EphemeralSettingsStore: SettingsStore, @unchecked Sendable {
    private var chord: HotkeyChord
    private var activation: HotkeyConfiguration.Activation
    private var selection = EngineSelection.defaultSelection
    private var acknowledgedCloud = false

    /// How many times a chord was written — a count rather than a flag, because "persisted twice"
    /// and "persisted once" are different bugs and a flag cannot tell them apart.
    private(set) var chordWrites = 0

    init(
        chord: HotkeyChord = PersistedSettings.defaultHotkeyChord,
        activation: HotkeyConfiguration.Activation = PersistedSettings.defaultActivation
    ) {
        self.chord = chord
        self.activation = activation
    }

    func engineSelection() -> EngineSelection { selection }
    func setEngineSelection(_ selection: EngineSelection) { self.selection = selection }
    func activationMode() -> HotkeyConfiguration.Activation { activation }
    func setActivationMode(_ activation: HotkeyConfiguration.Activation) {
        self.activation = activation
    }
    func hotkeyChord() -> HotkeyChord { chord }
    func setHotkeyChord(_ chord: HotkeyChord) {
        self.chord = chord
        chordWrites += 1
    }
    func hasAcknowledgedCloudCleanup() -> Bool { acknowledgedCloud }
    func setAcknowledgedCloudCleanup(_ acknowledged: Bool) { acknowledgedCloud = acknowledged }
}

/// The widget's level source, silent — this suite asserts nothing about the waveform.
private struct SilentLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}

private func keyEvent(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: false, timestamp: .zero)
}
