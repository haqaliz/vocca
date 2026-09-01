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

/// **The three surfaces that name the hotkey never disagree** — `general-tab-recorder` criteria 4
/// and 5, on the `EngineStateAgreementTests` precedent.
///
/// Until this aspect all three read one literal, `AppBootstrap.shippedHotkeyDisplayName = "⌥Space"`,
/// captured at construction — and the settings window and the status item are each built once and
/// kept for the process's lifetime. So the moment a rebind became possible, all three would have
/// gone on naming ⌥Space until the next launch: the tab the user had just changed it in, the
/// VoiceOver label, and the onboarding line telling a new user which key to hold.
///
/// That is the same shape as the defect the Speech tab's agreement test caught, and it is why
/// these are asserted **together** out of one root rather than one surface at a time: three
/// separate tests would each pass while the three said different things about the same instant.
@MainActor
final class HotkeySurfaceAgreementTests: XCTestCase {

    /// The shipped chord the harness launches on.
    private static let launchChord = PersistedSettings.defaultHotkeyChord

    /// ⌃⌥J — a different key *and* different modifiers, so "the surfaces followed the rebind" is a
    /// claim about the whole rendering rather than about one glyph.
    private static let newChord = HotkeyChord(keyCode: 38, modifiers: [.control, .option])

    private static func rendered(_ chord: HotkeyChord) -> String {
        HotkeyChordFormatter.describe(keyCode: chord.keyCode, modifiers: chord.modifiers)
    }

    // MARK: - Criterion 5: a stale chord is impossible after a rebind

    /// **Read twice across a rebind, the display name answers differently.** Asserted over the
    /// closure rather than the view, because the view is executed by nothing in CI — and because
    /// the closure is where the defect lived: a `String` field captured once cannot follow a
    /// rebind no matter what the view does with it.
    func testTheDisplayNameReadTwiceAcrossARebindAnswersDifferently() {
        let harness = Harness()
        // **Built once, before the rebind** — the window's own lifetime. Building it again
        // afterwards is what makes this test unable to fail: a `SettingsBindings` constructed
        // after the change would capture the new chord however the field is declared, and the
        // defect is precisely a value frozen at construction.
        let bindings = Self.settingsBindings(for: harness.root)

        let before = bindings.hotkeyDisplayName()
        XCTAssertEqual(before, Self.rendered(Self.launchChord))

        XCTAssertEqual(harness.root.rebind(to: Self.newChord), .rebound)

        let after = bindings.hotkeyDisplayName()
        XCTAssertEqual(after, Self.rendered(Self.newChord))
        XCTAssertNotEqual(
            before, after,
            """
            The same closure answered the same string on both sides of a rebind. That is the \
            captured-String defect: the settings window is built once and kept for the process's \
            lifetime, so a user who changes the shortcut would read the old one until they quit.
            """)
    }

    /// A refused rebind must not move the displayed chord either — the page would then be naming a
    /// binding nothing is bound to, which is worse than naming a stale one: at least the stale one
    /// works.
    func testARefusedRebindLeavesTheDisplayedChordAlone() {
        let harness = Harness()
        let bindings = Self.settingsBindings(for: harness.root)
        let bare = HotkeyChord(keyCode: 38, modifiers: [])

        XCTAssertEqual(harness.root.rebind(to: bare), .refused(.notBindable))
        XCTAssertEqual(bindings.hotkeyDisplayName(), Self.rendered(Self.launchChord))
    }

    // MARK: - Criterion 4: one formatter, three surfaces

    /// **The tab, the menu bar and onboarding render one chord through one formatter**, before and
    /// after a rebind, out of one root.
    ///
    /// The menu bar and onboarding sides are their copy functions applied to the root's answer,
    /// which is exactly what the wiring does — the status item and the onboarding window are
    /// window-server objects and cannot be built here (the window-server precedent).
    func testAllThreeSurfacesRenderTheBoundChordAndFollowARebindTogether() {
        let harness = Harness()
        // All three surfaces are constructed **once**, before any rebind, because all three really
        // are: the settings window and the status item are built on first use and kept until quit,
        // and the onboarding window until the flow completes.
        let bindings = Self.settingsBindings(for: harness.root)
        let menuBarHotkey: () -> String = { [root = harness.root] in root.hotkeyDisplayName }
        let onboardingHotkey: () -> String = { [root = harness.root] in root.hotkeyDisplayName }

        for chord in [Self.launchChord, Self.newChord] {
            if chord != Self.launchChord {
                XCTAssertEqual(harness.root.rebind(to: chord), .rebound)
            }
            let expected = Self.rendered(chord)

            let tab = bindings.hotkeyDisplayName()
            let menuBar = MenuBarCopy.accessibilityLabel(for: .ready, hotkey: menuBarHotkey())
            let onboarding = OnboardingCopy.tryItPrompt(hotkey: onboardingHotkey())

            XCTAssertEqual(tab, expected, "the General tab must name the chord that is bound")
            XCTAssertTrue(
                menuBar.contains(expected),
                "the menu bar's VoiceOver label must name it too, not a literal: \(menuBar)")
            XCTAssertTrue(
                onboarding.contains(expected),
                "and so must the line telling a new user which key to hold: \(onboarding)")
            XCTAssertEqual(
                [tab, menuBar, onboarding].filter { $0.contains(expected) }.count, 3,
                "three surfaces, one chord — a disagreement here is a user reading two answers")
        }
    }

    /// Every onboarding line that names the chord is a function of it, not a constant. The three
    /// were `PRODUCT_SPEC.md`-verbatim strings with ⌥Space written into them; the spec's wording is
    /// preserved exactly, with the chord as its one variable.
    func testEveryOnboardingLineThatNamesTheChordFollowsIt() {
        let lines = [
            OnboardingCopy.accessibilityReason(hotkey:),
            OnboardingCopy.tryItPrompt(hotkey:),
            OnboardingCopy.doneCopy(hotkey:),
        ]
        for line in lines {
            XCTAssertTrue(line("⌃⌥J").contains("⌃⌥J"))
            XCTAssertFalse(
                line("⌃⌥J").contains("⌥Space"),
                "an onboarding line still carries the shipped chord as a literal")
        }
    }

    // MARK: - The structural half

    /// **The three wiring sites each read the root's one answer.** Read off `AppBootstrap`'s own
    /// source, because the behavioural rows above assert what the surfaces *do* with a display name
    /// and cannot see a wiring that hands one of them something else.
    ///
    /// This is the row that fails when the menu bar is given its own answer instead of the shared
    /// one — which is precisely the arrangement that shipped before this aspect.
    func testTheThreeWiringSitesAllReadTheRootsDisplayName() throws {
        let source = try String(
            contentsOf: PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaBootstrap/AppBootstrap.swift"),
            encoding: .utf8)
        let stripped = SwiftSourceScanner.stripComments(from: source)
        let characters = Array(stripped)

        for site in ["func attachMenuBarItem", "func showSettings", "func showOnboarding"] {
            guard let declaration = stripped.range(of: site),
                let brace = characters[
                    stripped.distance(from: stripped.startIndex, to: declaration.upperBound)...
                ].firstIndex(of: "{"),
                let body = SwiftSourceScanner.bracedBody(in: characters, openingBraceIndex: brace)
            else {
                XCTFail("\(site) could not be found to scan")
                continue
            }
            XCTAssertTrue(
                SwiftSourceScanner.identifiers(inBody: body.body).contains("hotkeyDisplayName"),
                """
                \(site) no longer reads the root's hotkeyDisplayName. Whatever it names the chord \
                with now is a second answer, and a second answer is a surface that goes stale the \
                first time a user rebinds — which is exactly what all three did before this aspect.
                """)
        }
    }

    /// **The shipped chord exists nowhere in `Sources/` as code.** One formatter, no second
    /// dialect: a hard-coded `⌥Space` is a rendering that cannot follow the binding, and there is
    /// now no reason for one to exist.
    ///
    /// Comments are stripped first, deliberately. Prose *about* the shipped chord is exactly what
    /// this codebase is made of — the key code's own doc comment names it, and so does the tap
    /// adapter's explanation of what an unswallowed press types. What is forbidden is a literal a
    /// surface could render.
    func testTheShippedChordIsNotWrittenOutAnywhereInSources() throws {
        let sources = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources")
        let files = SwiftSourceScanner.swiftFiles(under: sources)
        XCTAssertFalse(files.isEmpty, "this scan ran against nothing")

        for file in files {
            let code = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            XCTAssertFalse(
                code.contains("⌥Space"),
                """
                \(file.lastPathComponent) writes ⌥Space out by hand. Every surface renders the \
                bound chord through HotkeyChordFormatter now; a literal is a fourth surface that \
                nothing rebinds.
                """)
        }
    }

    /// The settings bindings as the composition root builds them, cut to the closure this suite is
    /// about. Everything else is defaulted or inert.
    private static func settingsBindings(for root: DictationLoopRoot) -> SettingsBindings {
        SettingsBindings(
            isToggleMode: { true },
            setToggleMode: { _ in },
            hotkeyDisplayName: { [weak root] in root?.hotkeyDisplayName ?? "" },
            chordForKeyEvent: { _, keyCode in HotkeyChord(keyCode: keyCode, modifiers: []) },
            validateChord: { HotkeyBindingRules.validate($0, against: []) },
            rebind: { [weak root] in root?.rebind(to: $0) ?? .refused(.notBindable) },
            engineDisplayName: { "" },
            cleanupSummary: { nil },
            loadDictionary: { [] },
            saveDictionary: { _ in })
    }

    // MARK: - The harness

    /// One composed root over fakes — the `RebindBoundaryTests.Harness` shape, cut down to what a
    /// surface question needs.
    @MainActor
    private struct Harness {
        let root: DictationLoopRoot

        init() {
            let chord = HotkeySurfaceAgreementTests.launchChord
            let configurations = AppBootstrap.hotkeyConfigurations(chord: chord)
            let holder = LedgerHolder()
            let engine = StubEngine.parakeet()

            self.root = DictationLoopRoot(
                configuration: configurations.holdToTalk,
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
                    secureInput: FakeSecureInput()),
                panel: RecordingPanel(holder: holder),
                pipeline: DictationPipeline(
                    engine: engine,
                    injector: LedgerInjector(
                        result: InjectionResult(
                            rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                            elapsed: .zero)),
                    holder: holder),
                settings: AgreementSettingsStore(chord: chord),
                toggleConfiguration: configurations.toggle,
                toggleSource: RecordingAudioSource(),
                toggleTimer: FakeTimer(),
                runningAppName: FakeRunningAppName(),
                widgetClock: FakeTimer(),
                liveLevel: SilentSurfaceLevelSource(),
                makeWatchdogTimer: { FakeTimer() })
        }
    }
}

/// A settings store with no disk behind it — the ``RebindBoundaryTests`` double, cut to what a
/// surface question needs.
private final class AgreementSettingsStore: SettingsStore, @unchecked Sendable {
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
private struct SilentSurfaceLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}
