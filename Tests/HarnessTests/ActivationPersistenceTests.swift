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

/// **The activation mode, read from the store at launch and written back when it changes** (PRD M7,
/// aspect 3's R5).
///
/// Before this, `activeMode` came from a constant and `setActiveMode` wrote nowhere: the General
/// tab's switch worked for exactly one run of the app, and every launch put the user back in the
/// shipped mode. Hold-to-talk is an accessibility requirement rather than a preference
/// (`PRODUCT_SPEC.md`), so "the setting reverts every launch" is not a cosmetic bug for the people
/// who need it.
///
/// ## Why the routing is asserted and not only the label
///
/// `activeMode` and the tap's actual route are two assignments in one initializer, and the class's
/// own documentation says why they must never be written independently: a root reporting a mode its
/// events do not reach is a hotkey silently driving the wrong machine. So every row below drives a
/// real chord through the tap and asserts which microphone opened, not which mode the root claims.
///
/// This file also carries the pin `PersistedSettingsTests` used to: the shipped activation default
/// existed twice, in two modules that cannot import each other, held together by a test. It exists
/// once now — `DictationLoopRoot.defaultMode` is *derived* from `PersistedSettings.defaultActivation`
/// through an exhaustive mapping — so the pin is gone and the compiler holds what the test held.
@MainActor
final class ActivationPersistenceTests: XCTestCase {

    private static let configuration = HotkeyConfiguration(
        keyCode: 49, modifiers: [.option], activation: .holdToTalk)
    private static let toggleConfiguration = HotkeyConfiguration(
        keyCode: 49, modifiers: [.option], activation: .toggle)

    // MARK: - Launch

    /// **R5.** A store holding hold-to-talk starts the root in hold-to-talk — and the tap's events
    /// really do reach the hold-to-talk machine's microphone, not merely the label.
    func testTheRootStartsInTheStoredActivationMode() {
        let harness = Harness(settings: EphemeralSettingsStore(activation: .holdToTalk))
        harness.root.markEnginePrepared()

        XCTAssertEqual(harness.root.activeMode, .holdToTalk, "the stored mode is the active mode")

        harness.keyboard.hold(Self.configuration)
        _ = harness.tap.deliver(keyEvent(.keyDown, Self.configuration.keyCode, [.option]))
        XCTAssertEqual(
            harness.holdToTalkSource.beginCount, 1,
            "the tap's events must reach the machine the stored mode names")
        XCTAssertEqual(
            harness.toggleSource.beginCount, 0,
            "and the other configuration's microphone must never open")
    }

    /// **R5.** A fresh install — nothing stored — starts in the shipped default, which is toggle,
    /// and the tap routes there. This is the row that keeps the derivation honest now that the
    /// two-module agreement pin is gone: the default the store reports and the mode the root runs
    /// are one fact, observed through the microphone that opens.
    func testAFreshInstallStartsInTheShippedDefaultAndRoutesThere() {
        let harness = Harness(settings: EphemeralSettingsStore())
        harness.root.markEnginePrepared()

        XCTAssertEqual(harness.root.activeMode, DictationLoopRoot.defaultMode)
        XCTAssertEqual(
            harness.root.activeMode, .toggle,
            "toggle is the shipped default (2026-08-25, after the first real dictation)")

        harness.keyboard.hold(Self.toggleConfiguration)
        _ = harness.tap.deliver(keyEvent(.keyDown, Self.toggleConfiguration.keyCode, [.option]))
        _ = harness.tap.deliver(keyEvent(.keyUp, Self.toggleConfiguration.keyCode, [.option]))
        XCTAssertEqual(
            harness.toggleSource.beginCount, 1,
            "a fresh install's hotkey drives the toggle machine")
        XCTAssertEqual(harness.holdToTalkSource.beginCount, 0)
    }

    /// A root composed with no settings store at all — the headless shape most of the suite uses —
    /// still starts in the shipped default. An absent store is a fresh install, not a failure.
    func testACompositionWithNoStoreStartsInTheShippedDefault() {
        let harness = Harness(settings: nil)
        XCTAssertEqual(harness.root.activeMode, DictationLoopRoot.defaultMode)
    }

    // MARK: - The write

    /// **R5 / M7.** Changing the mode writes it, so a simulated relaunch — a fresh store over the
    /// same defaults domain — reads it back. Driven over the real `UserDefaults` adapter on a
    /// scoped suite, never the developer's own settings.
    func testAModeChangeIsPersistedAndSurvivesARelaunch() {
        let name = "dev.vocca.tests.activation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let harness = Harness(settings: UserDefaultsSettingsStore(defaults: defaults))
        XCTAssertEqual(
            harness.root.activeMode, .toggle, "the scoped suite starts empty — the shipped default")

        harness.root.setActiveMode(.holdToTalk)

        XCTAssertEqual(
            UserDefaultsSettingsStore(defaults: defaults).activationMode(), .holdToTalk,
            "the next launch must start in the mode the user chose — a setting that is not written "
                + "is a setting the user chooses again every morning")

        let relaunched = Harness(settings: UserDefaultsSettingsStore(defaults: defaults))
        relaunched.root.markEnginePrepared()
        XCTAssertEqual(relaunched.root.activeMode, .holdToTalk, "and the relaunch honours it")

        relaunched.keyboard.hold(Self.configuration)
        _ = relaunched.tap.deliver(keyEvent(.keyDown, Self.configuration.keyCode, [.option]))
        XCTAssertEqual(
            relaunched.holdToTalkSource.beginCount, 1,
            "the relaunched root routes to the machine it says it is running")
    }

    /// A change refused mid-session is not written either. The refusal and the write must move
    /// together: persisting a mode the running app did not adopt would leave the store describing
    /// something that never happened, and the next launch would honour it.
    func testAModeChangeRefusedMidSessionIsNotPersisted() {
        let settings = EphemeralSettingsStore()
        let harness = Harness(settings: settings)
        harness.root.markEnginePrepared()

        harness.keyboard.hold(Self.toggleConfiguration)
        _ = harness.tap.deliver(keyEvent(.keyDown, Self.toggleConfiguration.keyCode, [.option]))
        _ = harness.tap.deliver(keyEvent(.keyUp, Self.toggleConfiguration.keyCode, [.option]))
        XCTAssertEqual(harness.toggleSource.beginCount, 1, "a toggle session really is in flight")

        harness.root.setActiveMode(.holdToTalk)

        XCTAssertEqual(harness.root.activeMode, .toggle, "the change is refused mid-session")
        XCTAssertEqual(
            settings.activationMode(), PersistedSettings.defaultActivation,
            "and nothing was written — the store must not describe a mode the app never adopted")
    }

    // MARK: - The harness

    /// One composed root over fakes, built twice in the relaunch row — which is the whole point of
    /// keeping it cheap: a second `Harness` over the same defaults domain *is* the next launch.
    @MainActor
    private struct Harness {
        let keyboard: Keyboard
        let tap: FakeHotkeyEventSource
        let holdToTalkSource: RecordingAudioSource
        let toggleSource: RecordingAudioSource
        let root: DictationLoopRoot

        init(settings: (any SettingsStore)?) {
            let keyboard = Keyboard()
            let tap = FakeHotkeyEventSource()
            let holdToTalkSource = RecordingAudioSource()
            let toggleSource = RecordingAudioSource()
            let holder = LedgerHolder()
            let engine = StubEngine.parakeet()
            let root = DictationLoopRoot(
                configuration: ActivationPersistenceTests.configuration,
                ceiling: SessionCeiling.default,
                clock: TestClock(),
                audioSource: holdToTalkSource,
                keyState: TruthfulKeyState(keyboard),
                watchdogTimer: FakeTimer(),
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
                toggleConfiguration: ActivationPersistenceTests.toggleConfiguration,
                toggleSource: toggleSource,
                toggleTimer: FakeTimer(),
                runningAppName: FakeRunningAppName(),
                widgetClock: FakeTimer(),
                liveLevel: SilentLevelSource())

            self.keyboard = keyboard
            self.tap = tap
            self.holdToTalkSource = holdToTalkSource
            self.toggleSource = toggleSource
            self.root = root
        }
    }
}

// MARK: - The doubles

/// A settings store with no disk behind it. The persistence rows use the real adapter; this one is
/// for the rows about what the root does with an answer.
private final class EphemeralSettingsStore: SettingsStore, @unchecked Sendable {
    private var selection: EngineSelection
    private var activation: HotkeyConfiguration.Activation

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


    // The hotkey chord is not what these tests are about, so the double remembers what it was
    // handed and starts on the shipped chord — an ephemeral store that answered a *different*
    // chord would silently change which key every row in this file presses.
    private var chord = PersistedSettings.defaultHotkeyChord

    func hotkeyChord() -> HotkeyChord { chord }

    func setHotkeyChord(_ chord: HotkeyChord) { self.chord = chord }

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
