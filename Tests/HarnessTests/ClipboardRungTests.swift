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

import VoccaCore
@testable import VoccaInject
import XCTest

/// **The clipboard rung — the headless half of the injection ladder's workhorse.**
///
/// `ARCHITECTURE.md:405-415`'s clipboard protocol is the fiddliest rung in the ladder, because
/// clipboard managers (Raycast, Alfred, Paste, Maccy) race us for pasteboard ownership: save →
/// set → synthesize ⌘V → settle → restore *only if the change count is still ours*, and never
/// clobber a manager that took ownership. Every one of those steps is a decision above the seam —
/// the real `SystemPasteboard` names `NSPasteboard` and translates, the rung decides — so the
/// whole protocol runs headless over the injected pasteboard and keystroke seams, with a fake
/// pasteboard that simulates the manager by moving its change count between our write and our
/// check.
///
/// The load-bearing acceptance is ``testWhenAManagerTookThePasteboardTheRungDoesNotRestoreIt``:
/// stomping the user's clipboard manager is worse than leaving our text there
/// (`ARCHITECTURE.md:413-414`), so the event log must show no restore and the rung must still
/// report what it did — the paste happened, with no verification claim to invent (verified is
/// for AX; the clipboard rung reports `.succeeded(verified: false)` raw, and the decision
/// interprets).
@MainActor
final class ClipboardRungTests: XCTestCase {

    // MARK: - Builders

    private func target(
        bundleID: String = "com.example.Notes"
    ) -> TargetContext {
        TargetContext(bundleID: bundleID, windowTitle: nil, isSecureInput: false)
    }

    /// One rung run with every input explicit: the pasteboard, the keystroke seam, the injected
    /// settle delay and the settle mechanism itself all arrive through the initialiser, so a
    /// test can vary exactly one thing.
    private func makeRung(
        log: ClipboardProtocolLog,
        pasteboard: FakePasteboardManager,
        keystrokes: FakeKeystrokeSource,
        settleDelay: Duration = .milliseconds(123)
    ) -> ClipboardRungStrategy {
        ClipboardRungStrategy(
            pasteboard: pasteboard,
            keystrokes: keystrokes,
            settleDelay: settleDelay,
            settle: { delay in log.append(.settle(delay)) })
    }

    // MARK: - The protocol's ordering

    /// **Save → set → ⌘V → settle → ownership check → restore, in that order** — the whole of
    /// `ARCHITECTURE.md:408-414` pinned by one event log.
    ///
    /// Each claim in the sequence is a distinct hazard: a snapshot that happens after the write
    /// saves our own text instead of the user's; a paste before the write pastes the *old*
    /// clipboard; a restore before the paste yanks the text the field is about to receive; and a
    /// restore before the ownership check would clobber a manager that took the pasteboard
    /// between the write and the settle (the never-clobber rule's other half, tested in
    /// ``testWhenAManagerTookThePasteboardTheRungDoesNotRestoreIt``). The paste and the settle
    /// enter this log through the injected seams — that is what makes their positions assertable
    /// at all.
    func testTheClipboardProtocolRunsSaveSetPasteSettleRestoreInOrder() async {
        let log = ClipboardProtocolLog()
        let pasteboard = FakePasteboardManager(log: log)
        let keystrokes = FakeKeystrokeSource(log: log)
        let rung = makeRung(log: log, pasteboard: pasteboard, keystrokes: keystrokes)

        let result = await rung.tryInject("the transcript", into: target())

        XCTAssertEqual(
            result, .succeeded(verified: false),
            """
            The clipboard rung has no read-back, so it must report plain success with no \
            verification claim — verified is for AX (ARCHITECTURE.md:400), and the decision \
            interprets.
            """)
        XCTAssertEqual(
            log.events,
            [
                .snapshot,
                .set("the transcript"),
                .paste,
                .settle(.milliseconds(123)),
                .changeCountRead,
                .restore,
            ],
            """
            The clipboard protocol's ordering has broken: save → set → ⌘V → settle → check → \
            restore. A paste that sits before the write pastes the user's old clipboard; a \
            restore before the settle yanks the text back before the field received it.
            """)
    }

    /// **Never clobber**: when the fake manager moved the change count after our write, the rung
    /// does NOT restore — the log shows no restore event, the saved snapshot is never handed
    /// back, and our text stays where the manager now owns it (`ARCHITECTURE.md:412-414`).
    ///
    /// This is the aspect's load-bearing acceptance (`plan_20260809.md` §7): stomping the user's
    /// clipboard manager is worse than leaving our text there, and the *absence* of a restore is
    /// the only observable that proves it — a rung that restored unconditionally would pass every
    /// test that never simulated the race.
    func testWhenAManagerTookThePasteboardTheRungDoesNotRestoreIt() async {
        let log = ClipboardProtocolLog()
        let pasteboard = FakePasteboardManager(log: log, takesOwnershipAfterSet: true)
        let keystrokes = FakeKeystrokeSource(log: log)
        let rung = makeRung(log: log, pasteboard: pasteboard, keystrokes: keystrokes)

        let result = await rung.tryInject("the transcript", into: target())

        XCTAssertEqual(
            result, .succeeded(verified: false),
            """
            The paste still happened — the rung reports what it did, raw. A skipped restore is \
            not a failed injection; it is the manager's pasteboard now, and our text is in it.
            """)
        XCTAssertEqual(
            log.events,
            [
                .snapshot,
                .set("the transcript"),
                .paste,
                .settle(.milliseconds(123)),
                .changeCountRead,
            ],
            """
            The rung restored a pasteboard a manager had taken. The count `set` returned was no \
            longer current, so restoring would stomp the manager's own snapshot \
            (ARCHITECTURE.md:412-414). Stomping the user's clipboard manager is worse than \
            leaving our text there.
            """)
        XCTAssertNil(
            pasteboard.restoredSnapshot,
            "No restore may be attempted when the change count moved — not even with the old snapshot.")
        let readBack = await pasteboard.readBack()
        XCTAssertEqual(
            readBack, "the transcript",
            """
            The pasteboard still holds our text: the manager owns it now, and the rung must not \
            reach in after it.
            """)
    }

    /// **Restore happens when the count is still ours** — the happy-path half of the
    /// never-clobber pair: the snapshot the rung restores is the snapshot it saved (the change
    /// count round-trips), and the pasteboard no longer holds our text once the restore lands.
    func testWhenTheChangeCountIsStillOursTheSavedSnapshotIsRestored() async {
        let log = ClipboardProtocolLog()
        let pasteboard = FakePasteboardManager(log: log, initialChangeCount: 7)
        let keystrokes = FakeKeystrokeSource(log: log)
        let rung = makeRung(log: log, pasteboard: pasteboard, keystrokes: keystrokes)

        let result = await rung.tryInject("the transcript", into: target())

        XCTAssertEqual(result, .succeeded(verified: false))
        XCTAssertEqual(
            pasteboard.restoredSnapshot?.changeCount, 7,
            """
            The restore must receive the snapshot taken before the write — the change count the \
            pasteboard carried at save time — not a snapshot taken after our own write, which \
            would re-paste our text back into the user's clipboard.
            """)
        let readBack = await pasteboard.readBack()
        XCTAssertNil(
            readBack,
            "After a restore, the pasteboard must no longer hold our text.")
    }

    /// **The ⌘V goes through the keystroke seam, exactly once** — the clipboard rung names no
    /// `CGEvent` (the per-seam lint pins that separately); it asks the injected seam for the one
    /// gesture, and a paste that happened twice — or never — is a rung that wrote and settled
    /// for nothing.
    func testThePasteCommandIsSentThroughTheKeystrokeSeamExactlyOnce() async {
        let log = ClipboardProtocolLog()
        let pasteboard = FakePasteboardManager(log: log)
        let keystrokes = FakeKeystrokeSource(log: log)
        let rung = makeRung(log: log, pasteboard: pasteboard, keystrokes: keystrokes)

        let result = await rung.tryInject("the transcript", into: target())
        XCTAssertEqual(result, .succeeded(verified: false))

        XCTAssertEqual(
            keystrokes.pasteCount, 1,
            """
            pressPaste() must be called exactly once per attempt: not zero (the write was \
            pointless), and not twice (the field would receive two pastes).
            """)
    }

    // MARK: - The settle delay

    /// **The settle delay is an injected value, and the 80 ms default is pinned in exactly one
    /// place.**
    ///
    /// The injected-value half is proven by ``testTheClipboardProtocolRunsSaveSetPasteSettleRestoreInOrder`` —
    /// the `.settle(.milliseconds(123))` in the log is the value the test injected, travelling
    /// unmodified through the rung. What remains to pin is the default: `.milliseconds(80)` may
    /// appear in the rung's source exactly once — the initialiser's default argument. A second
    /// occurrence would be a hard-coded settle somewhere the injected value cannot reach, and
    /// zero would be a default that moved out of the one place review expects it.
    func testTheSettleDelayDefaultIsEightyMillisecondsPinnedInExactlyOnePlace() throws {
        let rungFile = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaInject/Clipboard/ClipboardRungStrategy.swift")
        let source = try String(contentsOf: rungFile, encoding: .utf8)

        XCTAssertEqual(
            source.components(separatedBy: "milliseconds(80)").count - 1, 1,
            """
            The 80 ms settle default must appear exactly once in ClipboardRungStrategy.swift — \
            the initialiser's default argument (PRD R3). A second occurrence is a settle the \
            injected value cannot reach; none is a default that moved out of the one place.
            """)
    }

    // MARK: - The failure paths

    /// A pasteboard write that fails must report `.failed` and stop before the paste — pasting
    /// nothing is not a silent success, and the decision falls through to the next rung
    /// (`ARCHITECTURE.md:212`).
    func testAWriteFailureReportsFailedWithoutPastingOrRestoring() async {
        let log = ClipboardProtocolLog()
        let pasteboard = FakePasteboardManager(log: log, failsSet: true)
        let keystrokes = FakeKeystrokeSource(log: log)
        let rung = makeRung(log: log, pasteboard: pasteboard, keystrokes: keystrokes)

        let result = await rung.tryInject("the transcript", into: target())

        XCTAssertEqual(
            result, .failed,
            "A failed write is a failed rung — there is nothing to paste, so nothing may be claimed.")
        XCTAssertEqual(
            log.events, [.snapshot, .set("the transcript")],
            """
            On a write failure the rung must stop before the paste: no ⌘V, no settle, no \
            restore, and no invented success.
            """)
        XCTAssertEqual(keystrokes.pasteCount, 0)
    }

    /// A snapshot that fails must report `.failed` before touching the pasteboard at all.
    ///
    /// This is the never-clobber rule's first half: without a saved snapshot there is nothing to
    /// restore, so writing would *permanently* replace the user's clipboard — not the manager's
    /// race, but the same doctrine (`ARCHITECTURE.md:413` — stomping the user's clipboard is
    /// worse than leaving our text there). The rung refuses rather than write into an
    /// unrestorable state.
    func testASnapshotFailureReportsFailedWithoutTouchingThePasteboard() async {
        let log = ClipboardProtocolLog()
        let pasteboard = FakePasteboardManager(log: log, failsSnapshot: true)
        let keystrokes = FakeKeystrokeSource(log: log)
        let rung = makeRung(log: log, pasteboard: pasteboard, keystrokes: keystrokes)

        let result = await rung.tryInject("the transcript", into: target())

        XCTAssertEqual(
            result, .failed,
            "Without a saved snapshot the rung cannot restore, so writing would clobber the user's clipboard with nothing to give back.")
        XCTAssertEqual(
            log.events, [.snapshot],
            """
            The rung must not write, paste, settle or restore when the snapshot failed — every \
            later step assumes a state that was never saved.
            """)
    }

    // MARK: - The seam's own contract

    /// The write half of the seam, pinned directly: what `set(text:)` puts in the pasteboard is
    /// what `readBack()` reads out.
    ///
    /// The rung never reads back — the clipboard rung reports no verification, and `verified` is
    /// for AX — so the write→read-back contract has no other test to live in; the seam carries
    /// it for the phases that will need it (the smoke checklist's real-pasteboard step, and any
    /// future read-back consumer).
    func testTheSeamWritesTextThatReadsBack() async {
        let log = ClipboardProtocolLog()
        let pasteboard = FakePasteboardManager(log: log)

        let changeCount = await pasteboard.set(text: "hello world")
        let readBack = await pasteboard.readBack()

        XCTAssertNotNil(changeCount, "A successful write must note the new change count.")
        XCTAssertEqual(
            readBack, "hello world",
            "The pasteboard must hold exactly the text that was written.")
        XCTAssertEqual(log.events, [.set("hello world"), .readBack])
    }
}
