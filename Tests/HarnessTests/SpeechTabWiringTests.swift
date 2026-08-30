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
import VoccaCore
import VoccaUI
import XCTest

/// **What the Speech tab is plugged into** — the half of Phase 4 that is not a window.
///
/// The page itself is executed by nothing in CI (no window server), and `showSettings()` builds
/// one, so the bindings it fills in cannot be *run* here. They can be **read**: the closures route
/// the tab's gestures into the root, and a gesture wired to nothing is a control that looks live
/// and is not — the exact failure `SettingsCopy.hotkeyNotRebindable` exists to avoid admitting to.
/// The `EngineReadinessTests` / `EngineSelectionWiringTests` precedent: scan the shipped source,
/// because the hazard is a path CI cannot execute.
final class SpeechTabWiringTests: XCTestCase {

    /// **Every Speech-tab gesture reaches the root.** A selection change goes to
    /// `setEngineSelection` — aspect 3's switch, which already refuses mid-session and prepares
    /// eagerly — and the two facts the other surfaces need are reported back through the
    /// affordances the agreement test pinned.
    ///
    /// Reported *back* is the load-bearing half. The tab is where a model is removed and where a
    /// download begins, and it is the only place that knows; if it kept those to itself the menu
    /// bar would keep saying "ready" over a model that is gone. That is the disagreement
    /// `EngineStateAgreementTests` forbids, and this is the wiring that makes it reachable.
    func testTheSpeechBindingsRouteEveryGestureIntoTheRoot() throws {
        let body = try Self.showSettingsBody()

        for call in [
            "setEngineSelection", "engineModelRemoved", "engineDownloadChanged",
            "engineReadinessState",
        ] {
            XCTAssertTrue(
                body.contains(call),
                """
                showSettings() no longer routes \(call). A Speech tab that cannot reach the root \
                is a page of controls that look live and are not — and one that does not report \
                a removal or a download back leaves the menu bar and the pill describing a state \
                that ended.
                """)
        }
    }

    /// **The engine selection is read live, never captured.** The window is built once and kept
    /// for the process's lifetime, so a captured selection would leave the radio button pointing
    /// at the engine Vocca launched with for ever — including immediately after the user changed
    /// it in this very tab.
    ///
    /// The same argument `engineDisplayName` already makes ("the *live* selection, not the
    /// launch-time one"), applied to the control rather than to the label.
    func testTheSelectionIsReadThroughTheResolverRatherThanCaptured() throws {
        let body = try Self.showSettingsBody()
        XCTAssertTrue(
            body.contains("resolver.selection"),
            "the tab reads the resolver's own selection, which is the fact rather than a copy")
    }

    /// **The defaults are honest no-ops.** `SettingsBindings` is public and its Speech fields are
    /// defaulted so that existing callers keep compiling — but a default that pretended to work
    /// would be worse than none: a test harness that silently "removed" models and "switched"
    /// engines would prove things about a page nothing is behind.
    ///
    /// So: no tier is present, nothing is on disk, no download session can be built, and the
    /// engine reports `unavailable` — the closed gate, which is the safe direction everywhere else
    /// in this system too.
    @MainActor
    func testTheSpeechBindingDefaultsClaimNothing() async {
        let bindings = SettingsBindings(
            isToggleMode: { true },
            setToggleMode: { _ in },
            hotkeyDisplayName: { "⌥Space" },
            chordForKeyEvent: { _, keyCode in HotkeyChord(keyCode: keyCode, modifiers: []) },
            validateChord: { HotkeyBindingRules.validate($0, against: []) },
            rebind: { _ in .unchanged },
            engineDisplayName: { "Parakeet v3" },
            cleanupSummary: { nil },
            loadDictionary: { [] },
            saveDictionary: { _ in })

        XCTAssertEqual(
            bindings.engineSelection(), .defaultSelection,
            "the shipped default, which is a working configuration")
        XCTAssertEqual(
            bindings.engineReadiness(), .unavailable,
            "closed is the safe direction: a default that claimed `ready` would let a page offer "
                + "a dictation nothing is behind")
        let snapshot = await bindings.modelSnapshot()
        XCTAssertTrue(snapshot.isEmpty, "and no tier is claimed present or absent")
        XCTAssertNil(
            bindings.makeDownloadSession(EngineTier.parakeetV3),
            "a download nothing can perform is offered by nobody")
        XCTAssertFalse(
            bindings.isSessionInFlight(),
            "and with no loop behind it, nothing is dictating")
    }

    // MARK: - The source scan

    /// The braced body of `showSettings()`, comments stripped — so a mention in prose is never
    /// mistaken for a call.
    private static func showSettingsBody() throws -> String {
        let root = try PackageRootLocator.find(from: #filePath)
        let file = root.appendingPathComponent("Sources/VoccaBootstrap/AppBootstrap.swift")
        let source = SwiftSourceScanner.stripComments(
            from: try String(contentsOf: file, encoding: .utf8))
        let header = "public func showSettings()"
        guard let start = source.range(of: header) else {
            XCTFail("showSettings() must still exist — it is the Settings window's one entry point")
            return ""
        }
        var depth = 0
        var body = ""
        for character in source[start.upperBound...] {
            if character == "{" { depth += 1 }
            if depth > 0 { body.append(character) }
            if character == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        return body
    }
}
