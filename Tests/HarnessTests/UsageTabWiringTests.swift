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
import VoccaUsage
import XCTest

/// **What the Usage tab is plugged into** — the half of the aspect that is not a window.
///
/// The page is executed by nothing in CI (no window server) and `showSettings()` builds one, so
/// the bindings cannot be *run* through the view here. They can be run through the same path the
/// view takes — load, fold, clear, fold — and that is E8: the control has to reach the ledger, and
/// reading the tab has to reach nothing. A Clear that only emptied a `@State` would look exactly
/// like this one for as long as the window stayed open, and would be a disclosure that lied at the
/// next launch.
///
/// E11 is the other half: `configure`/`showSettings()` is `@MainActor`, builds an audio graph and
/// an event tap, and is executed by nothing in CI, so what the app actually fills these closures
/// with is source-scanned — the ``SpeechTabWiringTests``/``UsageWiringTests`` shape, each scan
/// with a planted-mutant guard so it cannot pass vacuously.
final class UsageTabWiringTests: XCTestCase {

    // MARK: - E8 · the Clear control is real

    /// **Clear empties the in-memory state and asks the ledger to clear** — the same two steps the
    /// page takes, driven through the bindings and the reducer rather than through the view.
    ///
    /// The ledger is a real ``UsageRecorder`` over a real ``PersistentUsageStore`` in a temp
    /// directory, so "asks the store to clear" is a claim about a file that is gone rather than
    /// about a spy that was called.
    @MainActor
    func testClearingEmptiesTheStateAndTheLedgerTogether() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = Self.day(2026, 9, 7)
        let recorder = Self.recorder(over: directory, today: day)
        await recorder.load()
        await recorder.fold(Self.delivered)
        await recorder.flush()

        let bindings = Self.bindings(over: recorder, today: day)
        var state = UsageTabState.initial
        state = UsageTabReducer.reduce(state, .snapshotLoaded(await bindings.loadUsageSnapshot()))
        XCTAssertFalse(
            state.rows.isEmpty,
            "the tab must be showing something before it is cleared, or this proves nothing")

        await bindings.clearUsage()
        state = UsageTabReducer.reduce(state, .cleared)

        XCTAssertTrue(state.rows.isEmpty, "the state the user is looking at holds nothing")
        XCTAssertEqual(state.streak, 0, "and no run of days survives the history it was read off")
        XCTAssertTrue(
            state.isLoaded,
            "still read: the user watched it empty, so 'we haven't looked yet' would be a second "
                + "false claim on top of the first")
        let window = await recorder.currentWindow
        XCTAssertEqual(
            window, UsageWindow(),
            "the live window is empty — every fold for the rest of this run counts from nothing")
        let persisted = await PersistentUsageStore(directory: directory).load()
        XCTAssertEqual(
            persisted, UsageWindow(),
            "and the file is gone. A Clear that empties only the page is cosmetic, and a "
                + "cosmetic Clear on a disclosure page is worse than no Clear at all")
    }

    /// **Reading the tab clears nothing** — the cancelled dialog's half of E8.
    ///
    /// Cancelling is the absence of a call, so what is assertable is that nothing on the path a
    /// user takes to *look* touches the ledger: opening the tab loads a snapshot, and the ledger
    /// is exactly as it was afterwards. A page that cleared as a side effect of being read would
    /// pass every assertion about the Clear button and delete the user's history for looking.
    @MainActor
    func testReadingTheTabClearsNothingAndACancelledDialogLeavesTheLedgerWhereItWas() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = Self.day(2026, 9, 7)
        let recorder = Self.recorder(over: directory, today: day)
        await recorder.load()
        await recorder.fold(Self.delivered)
        await recorder.flush()

        let bindings = Self.bindings(over: recorder, today: day)
        var state = UsageTabState.initial
        state = UsageTabReducer.reduce(state, .snapshotLoaded(await bindings.loadUsageSnapshot()))
        // The dialog was raised and dismissed: no action is folded, and nothing is called.
        let afterCancelling = state

        XCTAssertEqual(
            afterCancelling, state,
            "a dismissed dialog folds no action — the state is the one the load produced")
        XCTAssertFalse(
            afterCancelling.rows.isEmpty,
            "and the rows the user was reading are still there")
        let window = await recorder.currentWindow
        XCTAssertEqual(
            window.aggregate(for: day)?.realWork.delivered, 1,
            "the live window still holds the day, untouched by a read")
        let persisted = await PersistentUsageStore(directory: directory).load()
        XCTAssertEqual(
            persisted.aggregate(for: day)?.realWork.delivered, 1,
            "and so does the file: looking at the ledger is not a way to lose it")
    }

    /// **The defaults claim nothing and change nothing.** `SettingsBindings` is public and these
    /// two fields are defaulted so existing callers keep compiling — but a default that pretended
    /// to work would be worse than none. An empty snapshot renders the empty state, which is the
    /// honest "we have nothing to show"; a no-op clear deletes nothing rather than reporting a
    /// deletion that never happened.
    @MainActor
    func testTheUsageBindingDefaultsClaimNothing() async {
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

        let snapshot = await bindings.loadUsageSnapshot()
        XCTAssertEqual(
            snapshot, UsageSnapshot(days: [], streak: 0),
            "no day is claimed and no streak is claimed — with nothing behind the page, the "
                + "empty state is the only true thing it can say")
        await bindings.clearUsage()
        // Nothing to assert but that it returned: the point is that the default deletes nothing
        // and reports nothing, which a claims-something default could not manage.
    }

    /// **The Clear control takes the destructive treatment**, not the Apps tab's plain button.
    ///
    /// The codebase draws the line at reset-what-was-derived (a button and a sentence) versus
    /// delete-bytes-off-disk (a confirmation) — `SpeechSettingsPage.swift`'s removal dialog is the
    /// second, and clearing the ledger deletes a file and cannot be undone. The page is executed
    /// by nothing in CI, so this is a source scan: a Clear wired straight to the button would look
    /// identical in every other test in this file.
    func testTheClearControlTakesTheDestructiveConfirmationTreatment() throws {
        let source = try Self.usagePageSource()
        for fragment in [
            "confirmationDialog", "role: .destructive", "role: .cancel",
            "UsageTabCopy.clearConfirmButton", "UsageTabCopy.clearCancelButton",
        ] {
            XCTAssertTrue(
                source.contains(fragment),
                """
                The Usage page no longer carries \(fragment). Clearing the ledger deletes a file \
                and cannot be undone, which is the Speech tab's removal treatment — a plain \
                button is for resetting what was derived.
                """)
        }
    }

    /// The dialog scan is not vacuous: a plain button with no confirmation must fail it.
    func testTheConfirmationScanRejectsAPlainButton() {
        let planted = "Button(UsageTabCopy.clearButton) { clear() }"
        for fragment in ["confirmationDialog", "role: .destructive", "role: .cancel"] {
            XCTAssertFalse(
                planted.contains(fragment),
                "the scan would pass an unconfirmed Clear — it is looking for the wrong thing")
        }
    }

    // MARK: - E11 · what `showSettings()` fills the closures with

    /// **The snapshot is read off the live recorder, not a fresh store** — and the streak is
    /// answered where today is known.
    ///
    /// This is the one place the Usage tab is deliberately *unlike* the Apps tab. Apps reads a
    /// fresh `PersistentInjectionStrategyStore` because the running memory holds seeded entries
    /// that are not learning; here the asymmetry inverts. The recorder holds up to a minute of
    /// folds the cadence has not written yet, so a fresh-store read would tell a user who just
    /// dictated that the session never happened — on the one page whose entire job is showing
    /// them what Vocca recorded.
    func testTheSnapshotIsReadOffTheLiveRecorderRatherThanAFreshStore() throws {
        let body = try Self.showSettingsBody()
        guard !body.isEmpty else { return }

        for fragment in ["loadUsageSnapshot:", "usageRecorder", "currentWindow", "streak(asOf:"] {
            XCTAssertTrue(
                body.contains(fragment),
                """
                showSettings() no longer reads the usage snapshot off the live recorder \
                (\(fragment) is gone). The recorder's window is the loaded file plus everything \
                folded since; the file is a copy that lags it by up to the write interval, and a \
                tab reading the copy would be missing the dictation the user opened it to see.
                """)
        }
        XCTAssertFalse(
            body.contains("PersistentUsageStore()"),
            """
            showSettings() constructs a fresh usage store. That is the Apps tab's pattern and it \
            is wrong here: the file lags the live window by up to `UsageRecorder.writeInterval`, \
            so the page would show a user stale counts immediately after they dictated.
            """)
    }

    /// **Clear reaches the recorder**, which is the one object that can empty both halves.
    ///
    /// Routed anywhere else it could only manage one: a store-only clear leaves the run counting
    /// from the history the user deleted and writes it back at the next tick, and a window-only
    /// clear leaves the file to reload it at the next launch.
    func testClearIsRoutedToTheRecorderSoBothHalvesAreEmptied() throws {
        let body = try Self.showSettingsBody()
        guard !body.isEmpty else { return }

        XCTAssertTrue(
            body.contains("clearUsage:"),
            "showSettings() no longer fills the clear closure — the button would be a control "
                + "that looks live and is not")
        XCTAssertTrue(
            body.contains("usageRecorder?.clear()"),
            """
            Clear no longer reaches `UsageRecorder.clear()`. It is the only object holding both \
            the live window and the store, and clearing one without the other is a Clear the \
            user's history survives.
            """)
    }

    /// The wiring scan is not vacuous: the fresh-store read it exists to reject must fail it.
    func testTheWiringScanRejectsAFreshStoreReadAndAnUnroutedClear() {
        let planted = """
            { loadUsageSnapshot: { UsageSnapshot(days: await PersistentUsageStore().load().days, \
            streak: 0) }, clearUsage: {} }
            """

        XCTAssertFalse(
            planted.contains("currentWindow"),
            "the scan would pass a body that never reads the live window")
        XCTAssertFalse(
            planted.contains("streak(asOf:"),
            "the scan would pass a body that never answers the streak where today is known")
        XCTAssertTrue(
            planted.contains("PersistentUsageStore()"),
            "the planted body is the fresh-store read — the check below is what rejects it")
        XCTAssertFalse(
            planted.contains("usageRecorder?.clear()"),
            "the scan would pass a Clear routed to nothing")
    }

    // MARK: - The source scans

    private static func usagePageSource() throws -> String {
        let root = try PackageRootLocator.find(from: #filePath)
        let file = root.appendingPathComponent("Sources/VoccaUI/Usage/UsageSettingsPage.swift")
        return SwiftSourceScanner.stripComments(from: try String(contentsOf: file, encoding: .utf8))
    }

    /// The braced body of `showSettings()`, comments stripped — so a mention in prose is never
    /// mistaken for a call. The ``SpeechTabWiringTests`` scan, unchanged.
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

    // MARK: - The harness

    /// A recorder over a temp directory whose every day is `today` — the shipped store's real
    /// file behaviour, never `~/Library/Application Support/Vocca/`.
    private static func recorder(over directory: URL, today: CalendarDay) -> UsageRecorder {
        UsageRecorder(
            store: PersistentUsageStore(directory: directory),
            day: { today },
            clock: HandMovedClock(),
            log: { _ in })
    }

    /// The two closures the app fills, filled the way the app fills them — the live window, and
    /// the streak answered where today is known.
    @MainActor
    private static func bindings(over recorder: UsageRecorder, today: CalendarDay)
        -> SettingsBindings
    {
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
            loadUsageSnapshot: {
                let window = await recorder.currentWindow
                return UsageSnapshot(days: window.days, streak: window.streak(asOf: today))
            },
            clearUsage: { await recorder.clear() })
    }

    private static func tempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vocca-usage-tab-\(UUID().uuidString)")
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay {
        guard let value = CalendarDay(year: year, month: month, day: day) else {
            preconditionFailure("the fixture names a real date")
        }
        return value
    }

    private static var delivered: SessionRecord {
        SessionRecord(
            id: SessionRecord.ID(rawValue: 1),
            outcome: .delivered(rung: .clipboardPaste, verified: true),
            spans: [LatencySpan.recorded(name: .asr, elapsed: .milliseconds(120))],
            engine: nil,
            kind: .dictation)
    }
}
