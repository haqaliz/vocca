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

/// **The recorder, joined to the binding it changes** — `general-tab-recorder` phase 4.
///
/// The view itself is executed by nothing in CI (the window-server precedent). What is tested here
/// is everything above it: the one question a captured chord is asked, the loop from a capture to a
/// rebind and back to a notice, and the two structural rules that keep the recorder from taking the
/// user's whole keyboard.
@MainActor
final class HotkeyRecorderWiringTests: XCTestCase {

    private static let launchChord = PersistedSettings.defaultHotkeyChord
    /// ⌃⌥J — modified, so the rules accept it.
    private static let newChord = HotkeyChord(keyCode: 38, modifiers: [.control, .option])

    // MARK: - The one question a captured chord is asked

    /// A chord is reviewed against **both** halves in one place: what may be bound at all
    /// (``HotkeyBindingRules``) and what macOS has already claimed (``SystemShortcutRules``).
    ///
    /// One function rather than two calls in the composition root, because the order between them
    /// is a decision — and a decision in a composition root is a decision no test reaches.
    func testACleanModifiedChordIsAccepted() {
        XCTAssertEqual(HotkeyBindingRules.validate(Self.newChord, against: []), .accepted)
    }

    /// **A refusal outranks a warning.** A bare text-entry key is refused whether or not macOS also
    /// claims it: the refusal is the stronger answer, and a recorder that showed "macOS uses this,
    /// take it anyway" over a key that would stop typing everywhere has offered the user the one
    /// thing the rules exist to prevent.
    func testARefusalOutranksACollision() {
        let bare = HotkeyChord(keyCode: 38, modifiers: [])
        let occupied = [SystemShortcut(chord: bare, name: "Something of Apple's")]

        XCTAssertEqual(
            HotkeyBindingRules.validate(bare, against: occupied),
            .refused(.unmodifiedTextEntryKey))
    }

    /// A legal chord that collides is **warned, never refused** — the user's machine is the
    /// authority on their own shortcuts, and the name travels when there is one.
    func testALegalChordThatCollidesIsWarnedAndNamed() {
        let occupied = [SystemShortcut(chord: Self.newChord, name: "Switch to Desktop 1")]

        XCTAssertEqual(
            HotkeyBindingRules.validate(Self.newChord, against: occupied),
            .warned(.usedBySystemShortcut(name: "Switch to Desktop 1")))
        XCTAssertEqual(
            HotkeyBindingRules.validate(
                Self.newChord, against: [SystemShortcut(chord: Self.newChord, name: nil)]),
            .warned(.usedBySystemShortcut(name: nil)),
            "an unnamed collision is still a collision — dropping it would hide a real one")
    }

    // MARK: - The loop: capture, rebind, notice

    /// **A recording that ends in a rebind changes the binding**, and the tab's own display name
    /// follows it — the recorder's whole reason for existing, driven through the same closures the
    /// composition root hands the window.
    func testARecordedChordReachesTheBindingAndTheTabFollowsIt() {
        let harness = Harness()
        let bindings = harness.bindings

        var state = HotkeyRecorderReducer.reduce(.idle, .began)
        let chord = bindings.chordForKeyEvent(Self.rawFlags(control: true, option: true), 38)
        XCTAssertEqual(chord, Self.newChord, "the raw event word must translate to the chord meant")

        state = HotkeyRecorderReducer.reduce(state, .chordCaptured(chord, bindings.validateChord(chord)))
        guard let armed = state.chordToApply else {
            return XCTFail("a clean modified chord must arm: \(state)")
        }

        state = HotkeyRecorderReducer.reduce(state, .rebindAnswered(bindings.rebind(armed)))
        XCTAssertNil(state.notice, "a rebind that landed says nothing")
        XCTAssertEqual(bindings.hotkeyDisplayName(), "⌃⌥J")
    }

    /// **Criterion 6.** A rebind attempted while Vocca is listening surfaces
    /// ``RebindRefusal/sessionInFlight`` in the tab, rather than silently doing nothing — and the
    /// binding is untouched, so the running session keeps the key it was started on.
    func testARebindDuringADictationSurfacesTheRefusal() {
        let harness = Harness()
        harness.startSession()

        var state = HotkeyRecorderReducer.reduce(.idle, .began)
        state = HotkeyRecorderReducer.reduce(
            state, .chordCaptured(Self.newChord, harness.bindings.validateChord(Self.newChord)))
        guard let armed = state.chordToApply else { return XCTFail("expected an armed chord") }

        let outcome = harness.bindings.rebind(armed)
        XCTAssertEqual(outcome, .refused(.sessionInFlight))

        state = HotkeyRecorderReducer.reduce(state, .rebindAnswered(outcome))
        XCTAssertEqual(state.notice, .rebindRefused(.sessionInFlight))
        XCTAssertEqual(
            harness.bindings.hotkeyDisplayName(), "⌥Space",
            "a refused rebind must leave the running session's key exactly where it was")
    }

    /// The refusal has words. A closed-set walk, so a third reason cannot reach a user as a blank
    /// line under a control that has just declined them.
    func testEveryOutcomeTheRecorderCanReceiveHasSomethingToShow() {
        for refusal in RebindRefusal.allCases {
            let state = HotkeyRecorderReducer.reduce(
                HotkeyRecorderReducer.reduce(
                    HotkeyRecorderReducer.reduce(.idle, .began),
                    .chordCaptured(Self.newChord, .accepted)),
                .rebindAnswered(.refused(refusal)))
            guard case .rebindRefused(let shown)? = state.notice else {
                return XCTFail("\(refusal) produced no notice")
            }
            XCTAssertFalse(SettingsCopy.hotkeyRebindRefusal(shown).isEmpty)
        }
    }

    // MARK: - The two structural rules

    /// **The recorder never routes through the event tap and never installs a global monitor.**
    ///
    /// Both would swallow keys system-wide, and a recorder stuck in the recording state would then
    /// be eating the whole keyboard — with the way out needing that keyboard. A first-responder
    /// override in Vocca's own window cannot: it sees a key only while the settings window is
    /// frontmost and focused, and it needs no Accessibility grant to work at all.
    func testTheRecorderTakesKeysOnlyInsideVoccasOwnWindow() throws {
        let file = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaUI/Settings/HotkeyRecorderView.swift")
        let code = SwiftSourceScanner.stripComments(
            from: try String(contentsOf: file, encoding: .utf8))
        let identifiers = SwiftSourceScanner.identifiers(inBody: code)

        for forbidden in [
            "CGEvent", "CGEventTap", "tapCreate", "addGlobalMonitorForEvents",
            "addLocalMonitorForEvents",
        ] {
            XCTAssertFalse(
                identifiers.contains(forbidden),
                """
                HotkeyRecorderView names \(forbidden). A recorder that reads keys outside Vocca's \
                own window swallows them for the whole machine, and a stuck one eats the \
                keyboard the user needs in order to close it.
                """)
        }
        XCTAssertTrue(
            identifiers.contains("keyDown") && identifiers.contains("flagsChanged"),
            "the recorder must capture through the responder chain — that is the whole mechanism")
    }

    /// Nothing anywhere in `Sources/` installs a global event monitor. A repository-wide scan,
    /// because the reason is not local to the recorder: a global monitor is a second, unmanaged
    /// keyboard tap beside the one the tap-health policy exists to supervise.
    func testNothingInSourcesInstallsAGlobalEventMonitor() throws {
        let sources = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources")
        let files = SwiftSourceScanner.swiftFiles(under: sources)
        XCTAssertFalse(files.isEmpty, "this scan ran against nothing")

        for file in files {
            let code = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            XCTAssertFalse(
                code.contains("addGlobalMonitorForEvents"),
                """
                \(file.lastPathComponent) installs a global NSEvent monitor. Vocca has exactly one \
                keyboard reader, the CGEvent tap, and it has a health policy behind it precisely \
                because an unsupervised one is a hot keyboard nothing ends.
                """)
        }
    }

    /// **The composition root wires the recorder's three closures.** Read off `showSettings`'s own
    /// body: the behavioural rows above drive closures a test built, and cannot see a window handed
    /// something else.
    func testTheSettingsWiringSuppliesTheRecordersThreeClosures() throws {
        let source = try String(
            contentsOf: PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaBootstrap/AppBootstrap.swift"),
            encoding: .utf8)
        let stripped = SwiftSourceScanner.stripComments(from: source)
        let characters = Array(stripped)

        guard let declaration = stripped.range(of: "func showSettings"),
            let brace = characters[
                stripped.distance(from: stripped.startIndex, to: declaration.upperBound)...
            ].firstIndex(of: "{"),
            let body = SwiftSourceScanner.bracedBody(in: characters, openingBraceIndex: brace)
        else {
            return XCTFail("showSettings could not be found to scan")
        }
        let identifiers = SwiftSourceScanner.identifiers(inBody: body.body)

        for closure in ["chordForKeyEvent", "validateChord", "rebind"] {
            XCTAssertTrue(
                identifiers.contains(closure),
                """
                showSettings no longer wires \(closure). Whatever the General tab does without it \
                is a recorder that cannot change the binding — a control that looks editable and \
                is not, which is the exact thing the deleted copy used to warn about.
                """)
        }
    }

    // MARK: - Helpers

    /// A macOS event-flag word, built from the same bits the tap's translation reads.
    private static func rawFlags(control: Bool = false, option: Bool = false) -> UInt64 {
        (control ? 0x0004_0000 : 0) | (option ? 0x0008_0000 : 0)
    }

    /// One composed root plus the settings closures the root would hand its window.
    @MainActor
    private struct Harness {
        let root: DictationLoopRoot
        let bindings: SettingsBindings
        private let keyboard: Keyboard

        init() {
            let chord = HotkeyRecorderWiringTests.launchChord
            let configurations = AppBootstrap.hotkeyConfigurations(chord: chord)
            let keyboard = Keyboard()
            let holder = LedgerHolder()
            let engine = StubEngine.parakeet()

            let root = DictationLoopRoot(
                configuration: configurations.holdToTalk,
                ceiling: SessionCeiling.default,
                clock: TestClock(),
                audioSource: RecordingAudioSource(),
                keyState: TruthfulKeyState(keyboard),
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
                    secureInput: FakeSecureInput()),
                panel: RecordingPanel(holder: holder),
                pipeline: DictationPipeline(
                    engine: engine,
                    injector: LedgerInjector(
                        result: InjectionResult(
                            rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                            elapsed: .zero)),
                    holder: holder),
                settings: RecorderSettingsStore(chord: chord),
                toggleConfiguration: configurations.toggle,
                toggleSource: RecordingAudioSource(),
                toggleTimer: FakeTimer(),
                runningAppName: FakeRunningAppName(),
                widgetClock: FakeTimer(),
                liveLevel: SilentRecorderLevelSource(),
                makeWatchdogTimer: { FakeTimer() })
            root.markEnginePrepared()

            self.root = root
            self.keyboard = keyboard
            // Exactly the shape `showSettings()` builds, for the four closures this suite drives.
            self.bindings = SettingsBindings(
                isToggleMode: { true },
                setToggleMode: { _ in },
                hotkeyDisplayName: { [weak root] in root?.hotkeyDisplayName ?? "" },
                chordForKeyEvent: { rawFlags, keyCode in
                    HotkeyChord(
                        keyCode: keyCode,
                        modifiers: HotkeyFlagTranslation.modifiers(
                            rawFlags: rawFlags, keyCode: keyCode))
                },
                validateChord: { HotkeyBindingRules.validate($0, against: []) },
                rebind: { [weak root] chord in
                    root?.rebind(to: chord) ?? .refused(.notBindable)
                },
                engineDisplayName: { "" },
                cleanupSummary: { nil },
                loadDictionary: { [] },
                saveDictionary: { _ in })
        }

        /// Starts a hold-to-talk session in the routed machine, so a rebind meets the idle guard.
        func startSession() {
            keyboard.hold(root.holdToTalk.configuration)
            _ = root.holdToTalk.scheduledWatchdog.receive(
                RawKeyEvent(
                    kind: .keyDown,
                    keyCode: root.holdToTalk.configuration.keyCode,
                    modifiers: root.holdToTalk.configuration.modifiers,
                    isAutorepeat: false,
                    timestamp: .zero))
        }
    }
}

/// A settings store with no disk behind it.
private final class RecorderSettingsStore: SettingsStore, @unchecked Sendable {
    private var chord: HotkeyChord
    private var activation = PersistedSettings.defaultActivation
    private var selection = EngineSelection.defaultSelection
    private var acknowledgedCloud = false

    init(chord: HotkeyChord) { self.chord = chord }

    func engineSelection() -> EngineSelection { selection }
    func setEngineSelection(_ selection: EngineSelection) { self.selection = selection }
    func activationMode() -> HotkeyConfiguration.Activation { activation }
    func setActivationMode(_ activation: HotkeyConfiguration.Activation) {
        self.activation = activation
    }
    func hotkeyChord() -> HotkeyChord { chord }
    func setHotkeyChord(_ chord: HotkeyChord) { self.chord = chord }
    func hasAcknowledgedCloudCleanup() -> Bool { acknowledgedCloud }
    func setAcknowledgedCloudCleanup(_ acknowledged: Bool) { acknowledgedCloud = acknowledged }
    func keepInTray() -> Bool { false }
    func setKeepInTray(_ keepInTray: Bool) {}
}

/// The widget's level source, silent — this suite asserts nothing about the waveform.
private struct SilentRecorderLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}
