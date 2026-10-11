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
import VoccaConversation
import VoccaCore
@testable import VoccaInject
import VoccaText
import VoccaUI
import XCTest

/// **What the Conversation tab and the menu forget row are plugged into** (`turn-history`
/// `conversation-surface` S4-S6) — the ``UsageTabWiringTests`` shape, driven over a real
/// ``ConversationHistoryStore`` in a temp directory.
///
/// The page is executed by nothing in CI and `showSettings()`/`main()` build windows, so the
/// bindings and the menu closure cannot be *run* through the views here. They can be run
/// through the same paths the views take: the store's `onChange` folds the real conditions
/// (`root.updateMenuBarConditions { $0.isHistoryPresent = count > 0 }`, the D4 wire), the
/// bindings' snapshot/clear closures reach the same store, and the menu closure's body — the
/// store's `clear()` — is the third path. A Forget that only emptied a `@State` would look
/// exactly like these for as long as the window stayed open, and would be a disclosure that
/// lied at the next launch (`prd.md` gap 1: this is the first surface showing what the user
/// said).
@MainActor
final class ConversationWiringTests: XCTestCase {

    // MARK: - The conditions fold (S6)

    /// **Empty → the menu's history fact is false** — the launch shape: a fresh store loads
    /// nothing, stays silent (a first run is not an error), and the fold reports no history.
    @MainActor
    func testAnEmptyStoreFoldsNoHistoryIntoTheConditions() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = Self.makeRoot()
        let store = Self.store(over: directory, foldingInto: root)

        await store.load()
        XCTAssertFalse(
            root.menuBarConditions.isHistoryPresent,
            "an empty history must read as absent — the forget row has nothing to offer")
        let fileURL = await store.fileURL
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "the load must not create the file — a first run is not a write")
    }

    /// **Record → the menu's history fact is true** — the store's `onChange` fold is the row's
    /// only source, and a turn recorded through the real store reaches it.
    @MainActor
    func testARecordedTurnFoldsHistoryPresentIntoTheConditions() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = Self.makeRoot()
        let store = Self.store(over: directory, foldingInto: root)

        await store.recordTurn(utterance: "hello", reply: "hi there")
        await Self.pumpMainActor()

        XCTAssertTrue(
            root.menuBarConditions.isHistoryPresent,
            "the first recorded turn must fold the history-present fact on")
    }

    // MARK: - The Settings path (S5, S2)

    /// **The tab's snapshot reads the store, and the confirmed Forget empties store, file and
    /// page** — the `loadConversationSnapshot`/`clearConversation` closures, driven the way the
    /// page drives them (load, fold; clear, fold `.cleared` — "store first, page second").
    @MainActor
    func testTheSettingsPathClearsTheStoreTheFileAndThePage() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = Self.makeRoot()
        let store = Self.store(over: directory, foldingInto: root)
        let bindings = Self.bindings(over: root)

        // The page opens before anything happened: the empty, read state.
        var state = ConversationTabState.initial
        state = ConversationTabReducer.reduce(
            state, .snapshotLoaded(await bindings.loadConversationSnapshot()))
        XCTAssertTrue(state.isLoaded)
        XCTAssertTrue(state.rows.isEmpty)

        // The store records a turn; the tab is opened again: the turn renders.
        await store.recordTurn(utterance: "remind me", reply: "of the plan")
        await Self.pumpMainActor()
        state = ConversationTabReducer.reduce(
            state, .snapshotLoaded(await bindings.loadConversationSnapshot()))
        XCTAssertEqual(state.rows.first?.utterance, "remind me")
        XCTAssertEqual(state.rows.first?.reply, "of the plan")

        // The confirmed Forget: the store first, the page second (the page's own order).
        await bindings.clearConversation()
        state = ConversationTabReducer.reduce(state, .cleared)
        XCTAssertTrue(state.rows.isEmpty, "the page shows nothing")
        XCTAssertTrue(state.isLoaded, "and stays read — the user watched it empty")
        let fileURL = await store.fileURL
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "the file is gone — a Forget that emptied only the page is cosmetic, and a "
                + "cosmetic Forget on the first conversation-carrying surface is worse than "
                + "none")
    }

    // MARK: - The menu path (S5)

    /// **The menu closure's body clears the store and the fold goes false** — one action, the
    /// C12 kill-row shape: `try? await store.clear()`, the exact body `attachMenuBarItem`
    /// wires, asserted against the file's absence and the row's fact.
    @MainActor
    func testTheMenuPathClearsTheStoreAndFoldsTheConditionFalse() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = Self.makeRoot()
        let store = Self.store(over: directory, foldingInto: root)

        await store.recordTurn(utterance: "hello", reply: "hi there")
        await Self.pumpMainActor()
        XCTAssertTrue(root.menuBarConditions.isHistoryPresent)

        try? await store.clear()
        await Self.pumpMainActor()

        XCTAssertFalse(
            root.menuBarConditions.isHistoryPresent,
            "the one-action clear must fold the row's fact off — a stale `true` keeps a forget "
                + "row alive over nothing")
        let fileURL = await store.fileURL
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "and the file is gone from disk, which is what one action promised")
    }

    // MARK: - The defaults (the claims-nothing doctrine)

    /// **The conversation binding defaults claim nothing and delete nothing** — an empty
    /// snapshot renders the honest empty state, and a no-op clear deletes nothing rather than
    /// reporting a deletion that never happened.
    @MainActor
    func testTheConversationBindingDefaultsClaimNothing() async {
        let bindings = SettingsBindings(
            isToggleMode: { true },
            setToggleMode: { _ in },
            hotkeyDisplayName: { "" },
            chordForKeyEvent: { _, keyCode in HotkeyChord(keyCode: keyCode, modifiers: []) },
            validateChord: { chord, _ in HotkeyBindingRules.validate(chord, against: []) },
            rebind: { _, _ in .unchanged },
            engineDisplayName: { "" },
            cleanupSummary: { nil },
            loadDictionary: { [] },
            saveDictionary: { _ in })

        let snapshot = await bindings.loadConversationSnapshot()
        XCTAssertEqual(
            snapshot, ConversationSnapshot(turns: []),
            "no turn is claimed — with nothing behind the page, the empty state is the only "
                + "true thing it can say")
        await bindings.clearConversation()
        // Nothing to assert but that it returned: the point is that the default deletes
        // nothing and reports nothing, which a claims-something default could not manage.
    }

    // MARK: - The page's treatment (S2, source scans)

    /// **The Forget control takes the destructive confirmation treatment** — the
    /// ``UsageTabWiringTests`` scan: a Forget wired straight to the button would look identical
    /// in every other test in this file, and deleting a file that holds what the user said
    /// earns the confirmation.
    func testTheForgetControlTakesTheDestructiveConfirmationTreatment() throws {
        let source = try Self.conversationPageSource()
        for fragment in [
            "confirmationDialog", "role: .destructive", "role: .cancel",
            "ConversationTabCopy.forgetConfirmButton", "ConversationTabCopy.forgetCancelButton",
        ] {
            XCTAssertTrue(
                source.contains(fragment),
                """
                The Conversation page no longer carries \(fragment). Forgetting the \
                conversation deletes a file and cannot be undone, which is the Usage clear's \
                treatment — a plain button is for resetting what was derived.
                """)
        }
    }

    /// The confirmation scan is not vacuous: a plain button with no confirmation must fail it.
    func testTheConfirmationScanRejectsAPlainButton() {
        let planted = "Button(ConversationTabCopy.forgetButton) { forget() }"
        for fragment in ["confirmationDialog", "role: .destructive", "role: .cancel"] {
            XCTAssertFalse(
                planted.contains(fragment),
                "the scan would pass an unconfirmed Forget — it is looking for the wrong thing")
        }
    }

    /// **"Store first, page second"** — the page awaits `clearConversation` **before** folding
    /// `.cleared` (S2, the `UsageSettingsPage/clear()` order): the reversed order would
    /// empty the page on a deletion the disk refused, and the user would leave believing the
    /// file was gone while it sat beside them.
    func testThePageClearsTheStoreBeforeFoldingCleared() throws {
        let source = try Self.conversationPageSource()
        guard let forget = source.range(of: "func forget()"),
            let clear = source.range(of: "await bindings.clearConversation()"),
            let folded = source.range(of: ".cleared")
        else {
            return XCTFail(
                "the page must clear the store and fold `.cleared` in one function")
        }
        XCTAssertLessThan(
            clear.lowerBound, folded.lowerBound,
            "the store is asked first, the page second — the reverse order empties the page "
                + "on a deletion the disk refused")
        XCTAssertGreaterThan(
            clear.lowerBound, forget.lowerBound,
            "the clear must sit inside the forget gesture — a clear folded on page open would "
                + "delete the user's conversation for looking")
    }

    /// The order scan is not vacuous: the folded-page-first order must fail it.
    func testTheStoreFirstOrderScanRejectsTheReversedOrder() {
        let planted = """
            private func forget() {
                Task {
                    state = ConversationTabReducer.reduce(state, .cleared)
                    await bindings.clearConversation()
                }
            }
            """
        let clear = planted.range(of: "await bindings.clearConversation()")!
        let folded = planted.range(of: ".cleared")!
        XCTAssertGreaterThan(
            clear.lowerBound, folded.lowerBound,
            "the planted body folds the page before the store — the scan below must reject "
                + "exactly this")
    }

    // MARK: - The harness

    /// The standard headless root the wiring suites compose over — the
    /// `AgentPresetsInvariantTests.makeRoot()` shape: real stores and fakes, nothing that
    /// starts, reads or provisions at construction. Only `updateMenuBarConditions` is read
    /// here, and the root is otherwise inert.
    private static func makeRoot() -> DictationLoopRoot {
        let engine = StubEngine.parakeet()
        return DictationLoopRoot(
            configuration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk),
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
                secureInput: FakeSecureInput(),
                frontmost: FakeFrontmostApp()),
            panel: RecordingPanel(holder: LedgerHolder()),
            toggleConfiguration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .toggle),
            toggleSource: RecordingAudioSource(),
            toggleTimer: FakeTimer(),
            runningAppName: FakeRunningAppName(),
            widgetClock: FakeTimer(),
            liveLevel: QuietLevelSource(),
            sessionKind: .dictation)
    }

    /// A store over a temp directory whose `onChange` folds the D4 wire — the main actor's
    /// `updateMenuBarConditions { $0.isHistoryPresent = count > 0 }` — through a weak box, the
    /// AppBootstrap wiring's exact shape (a `@Sendable` closure cannot capture the main-actor
    /// root directly).
    private static func store(over directory: URL, foldingInto root: DictationLoopRoot)
        -> ConversationHistoryStore
    {
        let box = WeakRootBoxForTests()
        box.value = root
        return ConversationHistoryStore(
            directory: directory,
            onChange: { count in
                Task { @MainActor in
                    box.value?.updateMenuBarConditions { $0.isHistoryPresent = count > 0 }
                }
            })
    }

    /// The two closures the app fills, filled the way the app fills them — read through the
    /// root's slot, never a second store.
    @MainActor
    private static func bindings(over root: DictationLoopRoot) -> SettingsBindings {
        SettingsBindings(
            isToggleMode: { true },
            setToggleMode: { _ in },
            hotkeyDisplayName: { "" },
            chordForKeyEvent: { _, keyCode in HotkeyChord(keyCode: keyCode, modifiers: []) },
            validateChord: { chord, _ in HotkeyBindingRules.validate(chord, against: []) },
            rebind: { _, _ in .unchanged },
            engineDisplayName: { "" },
            cleanupSummary: { nil },
            loadDictionary: { [] },
            saveDictionary: { _ in },
            loadConversationSnapshot: {
                guard let store = root.conversationHistory else {
                    return ConversationSnapshot(turns: [])
                }
                let turns = await store.currentTurns()
                return ConversationSnapshot(
                    turns: turns.enumerated().map { position, turn in
                        ConversationTurnRow(
                            position: position,
                            utterance: turn.utterance,
                            reply: turn.reply,
                            interrupted: turn.interrupted)
                    })
            },
            clearConversation: {
                try? await root.conversationHistory?.clear()
            })
    }

    private static func conversationPageSource() throws -> String {
        let root = try PackageRootLocator.find(from: #filePath)
        let file = root.appendingPathComponent("Sources/VoccaUI/Conversation/ConversationSettingsPage.swift")
        return SwiftSourceScanner.stripComments(from: try String(contentsOf: file, encoding: .utf8))
    }

    private static func tempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vocca-conversation-\(UUID().uuidString)")
    }

    /// Lets the store's `onChange` fold task land — the `AppBootstrapWiringTests` pump shape.
    private static func pumpMainActor() async {
        for _ in 0..<2_000 {
            await Task.yield()
        }
    }
}

/// The weak box the wiring fold hops through — the file's own `WeakBox` shape, private to this
/// suite so the `AppBootstrap` one stays the shipped composition's.
private final class WeakRootBoxForTests: @unchecked Sendable {
    weak var value: DictationLoopRoot?
}

/// A level source that never moves — the `AgentPresetsInvariantTests` double.
private struct QuietLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}