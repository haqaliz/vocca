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
@testable import VoccaInject
import VoccaCore
import XCTest

/// The recovery journal — Phase A of `failsafe-surface` (`plan_20260809.md` §2).
///
/// The journal is the first implementation of the recovery half of custody: when the ladder
/// exhausts every rung, ``JournalTranscriptHolder/init(journal:)`` holds the transcript durably
/// behind the core's ``TranscriptHolder`` seam, and the FAILSAFE window reads it back after a
/// relaunch. Everything that decides is above the injected ``JournalStore`` seam and tested
/// here; the one file that may name `FileManager` is exercised against a real temp directory in
/// this same file, because `FileManager` works in CI and a linted-but-never-run adapter is not
/// an adapter that has been shown to work.
///
/// The load-bearing test is the durability ordering (PRD R6): `hold` must not answer before the
/// durable write commits, because a crash between ladder exhaustion and the journal write is a
/// lost transcript — the one window I1's floor must close. It is asserted across the same
/// two-ended ledger shape the seam's contract test uses (`HeldTranscriptTests`), and its two
/// failure halves are pinned: a crash between the temp write and the rename leaves *no readable
/// entry* (the atomic-pair protocol, recorded by the fake), and a store that refuses the write
/// makes `hold` throw with the slot still empty.
final class RecoveryJournalTests: XCTestCase {

    // MARK: - The atomic-pair write protocol

    /// The store's save is a temp-write followed by a rename, recorded as two events — the
    /// protocol that makes "a crash cannot leave a readable partial entry" a fact about the
    /// store rather than a hope.
    func testSaveIsAnAtomicTempWriteThenRenamePair() async throws {
        let store = RecordingJournalStore()
        let journal = try await RecoveryJournal(store: store, capacity: 5)
        let held = HeldTranscript(
            text: "the words", reason: .exhausted, targetAppName: "Slack", capturedAt: .seconds(3))

        try await journal.hold(held)

        let expectedName = RecordingJournalStore.fileName(for: 1)
        let events = await store.events
        XCTAssertEqual(
            events,
            [.tempWrite(expectedName), .rename(expectedName)],
            "a durable write is exactly two events: temp written, then renamed into place")
    }

    /// A simulated crash between the two events leaves no readable entry.
    ///
    /// The crash is not a refusal — the store dies mid-pair, having written its temp file. The
    /// pair is incomplete (no rename recorded), nothing is committed, nothing is listable, and
    /// the slot stays empty: the durability claim holds on the side of the protocol that a torn
    /// write actually attacks.
    func testACrashBetweenTempWriteAndRenameLeavesNoReadableEntry() async throws {
        let store = RecordingJournalStore()
        let journal = try await RecoveryJournal(store: store, capacity: 5)
        let held = HeldTranscript(
            text: "the words", reason: .exhausted, targetAppName: nil, capturedAt: .zero)
        await store.simulateCrashAfterTempWrite()

        do {
            try await journal.hold(held)
            XCTFail("a crash between temp-write and rename must surface as a failed hold")
        } catch {
            // Expected — the crash is the point of the test.
        }

        let committed = try await store.load()
        XCTAssertTrue(committed.isEmpty, "an interrupted save must leave no readable entry")
        let listed = try await store.list()
        XCTAssertTrue(listed.isEmpty, "an interrupted save must leave nothing listable")
        let events = await store.events
        XCTAssertEqual(
            events,
            [.tempWrite(RecordingJournalStore.fileName(for: 1))],
            "the pair must not complete: the temp was written, the rename never recorded")
        let current = await journal.current()
        XCTAssertNil(current, "a crashed hold must not leave a transcript in the slot")
    }

    // MARK: - The durability contract (PRD R6)

    /// **The load-bearing test: the durable write happens before `hold` returns.**
    ///
    /// The real journal's `hold` runs under the ledger: the store records `.durableWrite` at the
    /// moment the rename lands, and the marker holder records `.holdReturned` the moment `hold`
    /// answers. Two events, in that order, carrying the same transcript — the identical
    /// assertion `HeldTranscriptTests.testHoldIsDurableBeforeItReturns` makes over the seam, now
    /// made over the journal that implements it.
    func testHoldIsDurableBeforeItReturns() async throws {
        let ledger = TranscriptEventLog()
        let store = RecordingJournalStore(ledger: ledger)
        let journal = try await RecoveryJournal(store: store, capacity: 5)
        let holder = LedgerMarkingHolder(journal: journal, ledger: ledger)
        let held = HeldTranscript(
            text: "the words", reason: .exhausted, targetAppName: "Slack", capturedAt: .seconds(3))

        try await holder.hold(held)

        let events = await ledger.events
        XCTAssertEqual(
            events, [.durableWrite(held), .holdReturned(held)],
            "hold must not answer before the durable write commits (PRD R6); ledger: \(events)")
    }

    /// The negative control: the ordering check can fail, in the journal's own shape.
    ///
    /// A holder that answers before the journal has committed is the exact violation R6 exists
    /// to close, and the ledger catches it — which is what makes the positive assertion above
    /// load-bearing rather than decorative.
    func testTheOrderingCheckDetectsAReturnBeforeTheDurableWrite() async throws {
        let ledger = TranscriptEventLog()
        let store = RecordingJournalStore(ledger: ledger)
        let journal = try await RecoveryJournal(store: store, capacity: 5)
        let holder = ReturningBeforeCommitHolder(journal: journal, ledger: ledger)
        let held = HeldTranscript(
            text: "the words", reason: .exhausted, targetAppName: nil, capturedAt: .zero)

        try await holder.hold(held)

        let events = await ledger.events
        XCTAssertNotEqual(
            events, [.durableWrite(held), .holdReturned(held)],
            "a holder that answers before the commit must fail the durability ordering")
    }

    /// A store that cannot write makes `hold` throw, and the slot stays empty.
    ///
    /// The seam documents "throws when it cannot be made so": a journal that cannot commit must
    /// surface as a throw, not as a successful return — the caller is relying on the answer
    /// meaning "safe against process death".
    func testHoldThrowsWhenTheStoreCannotWriteAndTheSlotStaysEmpty() async throws {
        let store = RecordingJournalStore()
        let journal = try await RecoveryJournal(store: store, capacity: 5)
        let held = HeldTranscript(
            text: "the words", reason: .exhausted, targetAppName: nil, capturedAt: .zero)
        await store.refuseNextSave()

        do {
            try await journal.hold(held)
            XCTFail("hold must throw when the transcript cannot be made durable")
        } catch {
            // Expected — the throw is the contract.
        }

        let current = await journal.current()
        XCTAssertNil(current, "a failed hold must not leave a transcript in the slot")
        let remaining = try await store.load()
        XCTAssertTrue(remaining.isEmpty, "a refused write must commit nothing")
    }

    // MARK: - Reload, eviction, purge

    /// hold-then-reload: a fresh journal instance over the same store reads the entry back —
    /// the relaunch shape, with every field intact (`PRODUCT_SPEC.md:117`'s captured-at note
    /// included).
    func testHoldThenReloadReadsTheEntryBack() async throws {
        let store = RecordingJournalStore()
        let first = try await RecoveryJournal(store: store, capacity: 5)
        let held = HeldTranscript(
            text: "the words", reason: .exhausted, targetAppName: "Slack",
            capturedAt: .seconds(3))

        try await first.hold(held)

        // A fresh instance over the same store — the process died and relaunched.
        let relaunched = try await RecoveryJournal(store: store, capacity: 5)
        let current = await relaunched.current()
        XCTAssertEqual(current, held, "the held transcript must survive the relaunch whole")
        XCTAssertEqual(current?.text, "the words")
        XCTAssertEqual(current?.reason, .exhausted)
        XCTAssertEqual(current?.targetAppName, "Slack")
        XCTAssertEqual(current?.capturedAt, .seconds(3))
    }

    /// A capped journal drops the oldest entry first, and keeps dropping as the cap is crossed
    /// again — `ARCHITECTURE.md:437`'s bounded journal, as behaviour rather than prose.
    func testBoundedJournalEvictsTheOldestFirst() async throws {
        let store = RecordingJournalStore()
        let journal = try await RecoveryJournal(store: store, capacity: 2)

        for second in 1...4 {
            try await journal.hold(
                HeldTranscript(
                    text: "entry \(second)", reason: .exhausted, targetAppName: nil,
                    capturedAt: .seconds(Int64(second))))
        }

        let listed = try await store.list()
        XCTAssertEqual(
            listed, [3, 4],
            "with capacity 2, the two oldest of four must have been evicted, oldest first")
        let current = await journal.current()
        XCTAssertEqual(current?.text, "entry 4")
    }

    /// release purges the held entry: the user copied it, a retry delivered it, or they
    /// dismissed it — and the journal forgets it.
    func testReleasePurgesTheHeldEntry() async throws {
        let store = RecordingJournalStore()
        let journal = try await RecoveryJournal(store: store, capacity: 5)
        let held = HeldTranscript(
            text: "the words", reason: .exhausted, targetAppName: nil, capturedAt: .zero)
        try await journal.hold(held)

        await journal.release()

        let current = await journal.current()
        XCTAssertNil(current, "release must empty the slot")
        let listed = try await store.list()
        XCTAssertTrue(listed.isEmpty, "release must purge the stored entry")
        let remaining = try await store.load()
        XCTAssertTrue(remaining.isEmpty, "nothing may survive the purge")
    }

    /// release with nothing held is a no-op, not a crash and not an invented state.
    ///
    /// The window can dismiss at any moment, including one where nothing was ever held — and the
    /// seam's contract (`HeldTranscriptTests.testReleaseWithNothingHeldIsANoOp`) must hold for
    /// the journal implementation too.
    func testReleaseWithNothingHeldIsANoOp() async throws {
        let store = RecordingJournalStore()
        let journal = try await RecoveryJournal(store: store, capacity: 5)

        await journal.release()

        let current = await journal.current()
        XCTAssertNil(current, "release with nothing held must leave the slot empty")
        let events = await store.events
        XCTAssertTrue(events.isEmpty, "a no-op release must not touch the store")
    }

    /// The journal speaks the seam: hold → current → release through the shipped
    /// ``JournalTranscriptHolder``, the one conformance the ladder and the window actually see.
    func testJournalTranscriptHolderSpeaksTheSeam() async throws {
        let journal = try await RecoveryJournal(store: RecordingJournalStore(), capacity: 5)
        let holder = JournalTranscriptHolder(journal: journal)
        let held = HeldTranscript(
            text: "the words", reason: .exhausted, targetAppName: "Mail", capturedAt: .seconds(7))

        try await holder.hold(held)
        let current = await holder.current()
        XCTAssertEqual(current, held)

        await holder.release()
        let afterRelease = await holder.current()
        XCTAssertNil(afterRelease)
    }

    // MARK: - The real store (FileManager works in CI)

    /// The real ``FileSystemJournalStore`` against a real temp directory: write, relaunch (a
    /// fresh store over the same directory), read back, purge, read back again. The journal's
    /// adapter is not linted-and-untrusted — it runs here, every CI run.
    func testTheRealStoreRoundTripsAcrossInstancesAndPurges() async throws {
        let directory = Self.tempJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = HeldTranscript(
            text: "real words", reason: .noFocusedField, targetAppName: "Mail",
            capturedAt: .seconds(42))

        let first = try await RecoveryJournal(
            store: FileSystemJournalStore(directory: directory), capacity: 5)
        try await first.hold(held)

        let relaunched = try await RecoveryJournal(
            store: FileSystemJournalStore(directory: directory), capacity: 5)
        let current = await relaunched.current()
        XCTAssertEqual(current, held, "the real store must survive a relaunch over the same directory")

        await relaunched.release()

        let relaunchedAgain = try await RecoveryJournal(
            store: FileSystemJournalStore(directory: directory), capacity: 5)
        let afterPurge = await relaunchedAgain.current()
        XCTAssertNil(afterPurge, "the purge must survive a relaunch too")
    }

    /// A corrupt entry is skipped without losing the rest — and so is a temp file a crash left
    /// behind.
    ///
    /// The journal must never block on a torn or foreign file, and must never lose the readable
    /// rest because of one. The planted corrupt entry and the planted `.tmp` both sit in the
    /// directory before the valid write; the store reads around them, and a journal over the
    /// same directory sees only the valid entry.
    func testACorruptEntryIsSkippedWithoutLosingTheRest() async throws {
        let directory = Self.tempJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "not a journal entry at all".write(
            to: directory.appendingPathComponent("00000001.json"),
            atomically: true, encoding: .utf8)
        try "torn write, never renamed".write(
            to: directory.appendingPathComponent("00000009.json.tmp"),
            atomically: true, encoding: .utf8)

        let store = FileSystemJournalStore(directory: directory)
        let valid = HeldTranscript(
            text: "the rest", reason: .exhausted, targetAppName: "Slack", capturedAt: .seconds(9))
        try await store.save(JournalEntry(id: 2, transcript: valid))

        let loaded = try await store.load()
        XCTAssertEqual(
            loaded, [JournalEntry(id: 2, transcript: valid)],
            "the corrupt entry and the torn temp must be skipped, the valid entry kept")
        let listed = try await store.list()
        XCTAssertEqual(
            listed, [1, 2],
            "listing is by name: the corrupt file's name is committed, the torn temp's is not — skipping happens at load, where the content is read")
        XCTAssertFalse(
            listed.contains(9),
            "a temp file mid-commit is never a committed name")

        // A journal over the same directory must survive both hazards as well.
        let journal = try await RecoveryJournal(store: store, capacity: 5)
        let current = await journal.current()
        XCTAssertEqual(current, valid, "the journal must load the readable rest")
    }

    // MARK: - Fixtures

    private static func tempJournalDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-recovery-journal-\(UUID().uuidString)")
    }
}
