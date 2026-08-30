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
import VoccaUI
import XCTest

/// **The composition root builds both hotkey configurations from the stored chord** — the
/// `binding-store` aspect's third phase, and the point at which a rebind becomes something a
/// relaunch honours rather than a value sitting unread in a plist.
///
/// Two hardcoded call sites are replaced: `configure` built
/// `HotkeyConfiguration(keyCode: shippedHotkeyKeyCode, modifiers: [.option], …)` twice, once per
/// activation mode, so nothing anywhere read a binding at launch because there was nothing to
/// read.
///
/// ## Why the wiring is pinned at an extracted function and by a source scan
///
/// `configure` needs an `NSApplication` and a run loop, so no test in this suite calls it — the
/// limit `EngineSelectionWiringTests` and `AppBootstrapWiringTests` both state. What a test can do
/// is drive the pure derivation `configure` now calls, and read the shipped source to assert the
/// hardcodes are gone and the store is read **once**. One read matters here for the same reason it
/// mattered for the engine selection: two reads can answer differently, and a root whose two
/// machines are bound to different chords is a hotkey that starts a session one machine cannot
/// end.
@MainActor
final class HotkeyLaunchReadTests: XCTestCase {

    /// **The stored chord reaches both machines, and the two differ only in activation.**
    ///
    /// A tuple from one call over one chord rather than two independent constructions, so
    /// "both machines share the binding" is structural: there is no second chord to pass.
    func testBothConfigurationsCarryTheStoredChordAndDifferOnlyInActivation() {
        let chord = HotkeyChord(keyCode: 0x69, modifiers: [.control, .command])
        let configurations = AppBootstrap.hotkeyConfigurations(chord: chord)

        XCTAssertEqual(configurations.holdToTalk.keyCode, chord.keyCode)
        XCTAssertEqual(configurations.holdToTalk.modifiers, chord.modifiers)
        XCTAssertEqual(configurations.holdToTalk.activation, .holdToTalk)

        XCTAssertEqual(configurations.toggle.keyCode, chord.keyCode)
        XCTAssertEqual(configurations.toggle.modifiers, chord.modifiers)
        XCTAssertEqual(configurations.toggle.activation, .toggle)

        XCTAssertEqual(
            configurations.holdToTalk,
            HotkeyConfiguration(
                keyCode: configurations.toggle.keyCode,
                modifiers: configurations.toggle.modifiers,
                activation: .holdToTalk),
            "the activation is the only thing the two configurations may disagree about — a "
                + "hold-to-talk machine bound to a different chord is one that can never end a "
                + "session the toggle machine started")
    }

    // MARK: - Nothing changed for an existing install

    /// **With nothing stored, the root gets exactly the two configurations it got before this
    /// aspect** — ⌥Space, hold-to-talk and toggle (the `pipeline-wiring` B2 precedent).
    ///
    /// Driven through the real adapter over an empty scoped suite, so the whole launch path is
    /// exercised: the store's absent read, the tolerant decode's silent default, and the
    /// derivation. Written as literals rather than as `PersistedSettings.defaultHotkeyChord`,
    /// because a test that asks the new code what it thinks the old behaviour was cannot detect
    /// the new code changing it.
    func testAFreshInstallGetsExactlyTheConfigurationsTheRootUsedToHardcode() {
        let name = "dev.vocca.tests.hotkey-launch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let logged = LogCollector()
        let store = UserDefaultsSettingsStore(defaults: defaults, log: { logged.append($0) })
        let configurations = AppBootstrap.hotkeyConfigurations(chord: store.hotkeyChord())

        XCTAssertEqual(
            configurations.holdToTalk,
            HotkeyConfiguration(keyCode: 49, modifiers: [.option], activation: .holdToTalk))
        XCTAssertEqual(
            configurations.toggle,
            HotkeyConfiguration(keyCode: 49, modifiers: [.option], activation: .toggle))
        XCTAssertEqual(
            logged.entries, [],
            "an install that never rebound has chosen nothing — that is not an error")
    }

    /// A stored chord reaches the configurations through the real store, across a relaunch.
    ///
    /// The row above proves nothing changed; this one proves something can. A second store over
    /// the same domain *is* the next launch.
    func testAStoredChordSurvivesARelaunchAndReachesBothConfigurations() {
        let name = "dev.vocca.tests.hotkey-launch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        UserDefaultsSettingsStore(defaults: defaults)
            .setHotkeyChord(HotkeyChord(keyCode: 0x7A, modifiers: []))

        let relaunched = UserDefaultsSettingsStore(defaults: defaults)
        let configurations = AppBootstrap.hotkeyConfigurations(chord: relaunched.hotkeyChord())
        XCTAssertEqual(
            configurations.holdToTalk,
            HotkeyConfiguration(keyCode: 0x7A, modifiers: [], activation: .holdToTalk),
            "bare F1 — the single-key accessibility shape, still bound after a relaunch")
        XCTAssertEqual(
            configurations.toggle,
            HotkeyConfiguration(keyCode: 0x7A, modifiers: [], activation: .toggle))
    }

    // MARK: - The default is named once

    /// `PersistedSettings.defaultHotkeyKeyCode` and `AppBootstrap.shippedHotkeyKeyCode` are the
    /// same number.
    ///
    /// They are two constants because `VoccaCore` imports nothing and `VoccaBootstrap` is the only
    /// module that can see both — the `HotkeyBindingTables`/`SessionKeyPolicy` arrangement, for the
    /// same reason. Held together by test rather than by comment: if they drifted, the store would
    /// fall back to one chord while every message about the shipped hotkey named another, and the
    /// user would be told to press a key that does nothing.
    func testTheCoreDefaultAndTheShippedKeyCodeAreOneNumber() {
        XCTAssertEqual(PersistedSettings.defaultHotkeyKeyCode, AppBootstrap.shippedHotkeyKeyCode)
        XCTAssertEqual(PersistedSettings.defaultHotkeyKeyCode, 49, "kVK_Space")
    }

    /// The shipped chord still reads as ⌥Space, through the one renderer.
    ///
    /// `AppBootstrap.shippedHotkeyDisplayName` — a literal the menu bar and onboarding both read —
    /// was deleted by `general-tab-recorder`'s M10, because a captured string cannot follow a
    /// rebind. What that literal was worth is kept here: the day the default chord changes, the
    /// product's own documentation and copy still say ⌥Space, and this row fails rather than
    /// shipping a first-run screen naming a key that does nothing.
    func testTheShippedChordStillRendersAsTheDocumentedGlyphs() {
        XCTAssertEqual(
            HotkeyChordFormatter.describe(
                keyCode: PersistedSettings.defaultHotkeyKeyCode,
                modifiers: PersistedSettings.defaultHotkeyModifiers),
            "⌥Space")
    }

    // MARK: - One read, no hardcodes

    /// **The load-bearing row.** `AppBootstrap.swift` builds no `HotkeyConfiguration` from a
    /// literal modifier set any more, and reads the stored chord exactly once.
    ///
    /// Both halves fail for different reasons. A surviving `modifiers: [.option]` is a machine
    /// that ignores the user's binding. A second `hotkeyChord()` read is worse and much harder to
    /// see: the two reads can answer differently, leaving the two machines bound to different
    /// chords — one that starts a session and one that cannot end it.
    func testTheRootHardcodesNoChordAndReadsTheStoreExactlyOnce() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let file = root.appendingPathComponent("Sources/VoccaBootstrap/AppBootstrap.swift")
        let source = SwiftSourceScanner.stripComments(
            from: try String(contentsOf: file, encoding: .utf8))

        XCTAssertFalse(
            source.contains("modifiers: [.option]"),
            """
            AppBootstrap.swift still builds a hotkey from a literal modifier set. Every             configuration must come from the one stored chord; a literal is a machine that             silently ignores the binding the user chose.
            """)

        let reads = source.components(separatedBy: "hotkeyChord()").count - 1
        XCTAssertEqual(
            reads, 1,
            """
            the stored chord must be read exactly once in the composition root; found \(reads).             Two reads can answer differently, which is how the hold-to-talk and toggle machines             end up bound to different chords.
            """)
    }
}
