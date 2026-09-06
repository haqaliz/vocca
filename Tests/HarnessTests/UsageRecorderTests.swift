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
import Synchronization
import VoccaCore
@testable import VoccaUsage
import XCTest

/// **The holder that owns the live window** — `usage-wiring/spec.md`'s D1–D4 and D6–D9, driven at
/// the one type that has all three parts: the window, the store and the day provider.
///
/// `AppBootstrap.configure` is `@MainActor`, builds an audio graph and an event tap, and is
/// executed by nothing in CI, so the *composition* facts (that the load is kicked, that the sink
/// is installed, that termination flushes) are source-scanned in ``UsageWiringTests``. Everything
/// the recorder itself decides is driven here, against the **real** ``PersistentUsageStore`` over
/// temp directories and its injected file-system seam — so "no write happened" is a claim about
/// recorded calls rather than about what the code looks like.
///
/// No test in this file touches `~/Library/Application Support/Vocca/`: every store is built with
/// an explicit `directory:` under `NSTemporaryDirectory()`, and the one initialiser that resolves
/// the real path (`PersistentUsageStore.init()`) is never called.
final class UsageRecorderTests: XCTestCase {

    // MARK: - D1 · a finalized record reaches the window, once, on the day the provider named

    /// One folded record, one day, one session — and the day is the provider's answer, not
    /// something the record carried.
    ///
    /// A ``SessionRecord`` has no date on it: `VoccaCore` reads no clock, so the day can only come
    /// from the provider at this seam. Folding twice, or filing under a day nobody named, are the
    /// two ways a day's counts stop being the number of sessions that happened on it.
    func testAFoldedRecordLandsOnceOnTheDayTheProviderNamed() async throws {
        let harness = Harness()
        let day = Self.day(2026, 9, 7)
        harness.days.set([day])
        await harness.recorder.load()

        await harness.recorder.fold(Self.delivered(via: .accessibility))

        let window = await harness.recorder.currentWindow
        XCTAssertEqual(
            window.days.map(\.day), [day],
            "the fold must file the record under the day the provider answered, and no other")
        XCTAssertEqual(
            window.aggregate(for: day)?.realWork.delivered, 1,
            "one finalized delivery must reach the day's counts exactly once")
        XCTAssertEqual(
            window.aggregate(for: day)?.sessionCount, 1,
            """
            the day holds more (or fewer) sessions than were folded into it — a day's counts are \
            the number of sessions, and a double fold makes every P0 figure read off this window \
            a multiple of the truth
            """)
    }

    // MARK: - D2 · every outcome class and both session kinds

    /// All six outcome classes and both ``SessionKind``s survive the trip through the recorder.
    ///
    /// ``DayAggregate``'s own fold is tested exhaustively in `DayAggregateTests`; what is under
    /// test here is that *the wiring* carries the whole vocabulary — a recorder that dropped
    /// onboarding, or coerced `lost` into `failed`, would leave those tests green and the ledger
    /// wrong.
    func testEveryOutcomeClassAndBothKindsFoldThroughTheRecorder() async throws {
        let harness = Harness()
        let day = Self.day(2026, 9, 7)
        harness.days.set([day])
        await harness.recorder.load()

        for outcome in Self.everyOutcomeClass {
            await harness.recorder.fold(Self.record(outcome: outcome, kind: .dictation))
            await harness.recorder.fold(Self.record(outcome: outcome, kind: .onboarding))
        }

        let folded = await harness.recorder.currentWindow
        let aggregate = try XCTUnwrap(folded.aggregate(for: day))
        for column in [aggregate.realWork, aggregate.onboarding] {
            XCTAssertEqual(column.delivered, 4, "four of the six fixtures are deliveries")
            XCTAssertEqual(column.failsafeHeld, 1, "failsafeHeld is neither a delivery nor a loss")
            XCTAssertEqual(column.aborted, 1)
            XCTAssertEqual(column.failed, 1)
            XCTAssertEqual(
                column.lost, 1,
                "`lost` is the one class `ROADMAP.md:95` fixes at zero — it may not be coerced")
            XCTAssertEqual(column.emptySkip, 1)
            for rung in InjectionRung.allCases {
                XCTAssertEqual(
                    column.deliveries(via: rung), 1,
                    "every rung that delivered must be tallied as itself: \(rung)")
            }
        }
        XCTAssertEqual(
            aggregate.realWork.total, aggregate.onboarding.total,
            "the two columns took the same fixtures and must hold the same totals")
    }

    // MARK: - D3 · a fold performs no write

    /// **The criterion this phase exists for: folding touches no file.**
    ///
    /// Asserted on the injected ``UsageFileSystem``'s recorded call log, not by reading the
    /// source. A write inside the fold is a latency regression in the one loop the whole product
    /// is judged on (`prd.md` M8), and it is exactly the kind of regression that leaves every
    /// other test in this file green.
    ///
    /// The second half is the vacuity guard: the same seam, the same recorder, one `flush()` —
    /// and the log fills. Without it "no events" would also pass over a seam that records
    /// nothing.
    func testFoldingPerformsNoWriteAtAll() async throws {
        let harness = Harness()
        harness.days.set([Self.day(2026, 9, 7)])
        await harness.recorder.load()

        for _ in 0..<25 {
            await harness.recorder.fold(Self.delivered(via: .clipboardPaste))
        }

        var events = await harness.fileSystem.events
        XCTAssertEqual(
            events, [],
            """
            a fold reached the file system: \(events). Folding is in-memory and O(1); writing is \
            not, and a write on the dictation path moves the p95 the P2 gate reads. The cadence \
            is `flushIfDue()`'s and `flush()`'s alone.
            """)

        await harness.recorder.flush()
        events = await harness.fileSystem.events
        XCTAssertFalse(
            events.isEmpty,
            """
            the seam recorded nothing even for an explicit flush, so the assertion above was \
            vacuous — it would pass over a recorder that never writes at all
            """)
    }

    // MARK: - D4 · the day rollover

    /// A day rollover makes the write due **immediately**, and the completed day is in it.
    ///
    /// The clock never moves in this test, so the debounce alone would write nothing: the write
    /// that happens is the rollover's, and what comes back off disk is yesterday's finished
    /// counts. An app left running past midnight commits the day it just finished rather than
    /// carrying it in memory until something else happens to trigger a save.
    func testADayRolloverMakesTheWriteDueAndCommitsTheCompletedDay() async throws {
        let harness = Harness()
        let yesterday = Self.day(2026, 9, 7)
        let today = Self.day(2026, 9, 8)
        harness.days.set([yesterday, yesterday, today])
        await harness.recorder.load()

        await harness.recorder.fold(Self.delivered(via: .accessibility))
        await harness.recorder.fold(Self.delivered(via: .accessibility))
        await harness.recorder.flushIfDue()
        let beforeRollover = await harness.fileSystem.events
        XCTAssertEqual(
            beforeRollover, [],
            """
            a write happened inside the debounce interval with no rollover to justify it: \
            \(beforeRollover). The interval is the bound on how many counts a crash can lose; a \
            write per fold makes it meaningless.
            """)

        await harness.recorder.fold(Self.delivered(via: .clipboardPaste))
        await harness.recorder.flushIfDue()

        let after = await harness.fileSystem.events
        XCTAssertFalse(
            after.isEmpty,
            "crossing midnight must make the write due even though the interval has not elapsed")

        let persisted = await harness.freshStore().load()
        XCTAssertEqual(
            persisted.aggregate(for: yesterday)?.realWork.delivered, 2,
            """
            the committed file does not hold the completed day's counts. The rollover write \
            exists precisely because that day is finished and will never be added to again.
            """)
    }

    // MARK: - D6 · the debounce

    /// N folds inside one interval coalesce to **at most one** write, and the write happens once
    /// the interval has elapsed.
    ///
    /// Three phases against a hand-moved clock: nothing before the interval however many folds
    /// arrive, exactly one atomic pair once it has, and nothing again when the cadence is asked a
    /// second time with no new folds behind it.
    func testTheDebounceCoalescesManyFoldsIntoOneWrite() async throws {
        let harness = Harness()
        harness.days.set([Self.day(2026, 9, 7)])
        await harness.recorder.load()

        for _ in 0..<40 {
            await harness.recorder.fold(Self.delivered(via: .keystrokeSynthesis))
            await harness.recorder.flushIfDue()
        }
        var events = await harness.fileSystem.events
        XCTAssertEqual(
            events, [],
            "forty folds inside one interval wrote \(events.count) events; the interval is a bound")

        harness.clock.advance(by: UsageRecorder.writeInterval)
        await harness.recorder.flushIfDue()
        events = await harness.fileSystem.events
        XCTAssertEqual(
            events.count, 2,
            """
            the due write must be exactly one atomic temp-write/rename pair, not \(events): forty \
            folds are one write's worth of change
            """)

        harness.clock.advance(by: UsageRecorder.writeInterval)
        await harness.recorder.flushIfDue()
        let afterIdle = await harness.fileSystem.events
        XCTAssertEqual(
            afterIdle.count, 2,
            """
            the cadence wrote again with nothing folded since the last write: \(afterIdle). A \
            window that has not changed is already on disk.
            """)
    }

    /// The interval is stated in exactly one place, tree-wide.
    ///
    /// It is the bound on how many counts a crash can lose, so it is a decision to take once and
    /// visibly — the ``UsageWindowConstants/maximumRetainedDays`` and
    /// ``LatencyLedger/maximumRetainedRecords`` shape, scanned in the
    /// ``IdleReWarmPolicyTests/testTheFiveMinuteLiteralAppearsNowhereOutsideTheNamedFiles`` form.
    /// The scan matches the literal's **assigned** spelling and strips comments first, so a
    /// duration that happens to equal it in an unrelated test fixture is not a sighting and a doc
    /// comment naming it is not a second home.
    func testTheWriteIntervalLivesOnlyInItsNamedConstant() throws {
        let seconds = Int(UsageRecorder.writeInterval.components.seconds)
        XCTAssertGreaterThan(seconds, 0, "the interval must be a real span, not zero or negative")
        let root = try PackageRootLocator.find(from: #filePath)
        let named = "UsageRecorder.swift"
        let pattern = "= \\.seconds\\(\(seconds)\\)"

        var sightings: [String: Int] = [:]
        for tree in [root.appendingPathComponent("Sources"), root.appendingPathComponent("Tests")] {
            for file in SwiftSourceScanner.swiftFiles(under: tree) {
                let stripped = SwiftSourceScanner.stripComments(
                    from: try String(contentsOf: file, encoding: .utf8))
                if stripped.range(of: pattern, options: .regularExpression) != nil {
                    sightings[file.lastPathComponent, default: 0] += 1
                }
            }
        }

        XCTAssertFalse(sightings.isEmpty, "vacuity guard: the scan saw no files at all")
        XCTAssertEqual(
            Set(sightings.keys), [named],
            """
            the write interval must live in exactly \(named), got: \(sightings). It bounds how \
            many counts a crash can lose; spelled twice, the two spellings drift and the bound \
            becomes whichever one the reader found first.
            """)
    }

    // MARK: - D7 · the round trip through two launches

    /// A second launch sees the first launch's counts.
    ///
    /// The whole aspect in one assertion: fold, flush, and then a **fresh recorder over the same
    /// directory** — the restart, in the only form a test can stage it — loads the day and goes
    /// on adding to it rather than starting from zero.
    func testASecondLaunchLoadsTheFirstLaunchesCountsAndAddsToThem() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = Self.day(2026, 9, 7)

        let first = Harness(directory: directory)
        first.days.set([day])
        await first.recorder.load()
        await first.recorder.fold(Self.delivered(via: .accessibility))
        await first.recorder.fold(Self.delivered(via: .accessibility))
        await first.recorder.flush()

        let second = Harness(directory: directory)
        second.days.set([day])
        await second.recorder.load()
        let reloaded = await second.recorder.currentWindow
        XCTAssertEqual(
            reloaded.aggregate(for: day)?.realWork.delivered, 2,
            """
            the second launch started from an empty window — the ledger would reset every launch \
            and a seven-day streak (`ROADMAP.md:102`) would be unmeasurable by construction
            """)

        await second.recorder.fold(Self.delivered(via: .clipboardPaste))
        await second.recorder.flush()

        let persisted = await second.freshStore().load()
        XCTAssertEqual(
            persisted.aggregate(for: day)?.realWork.delivered, 3,
            "the second launch's session must add to the day rather than replace it")
    }

    // MARK: - D8 · a load that fails

    /// A file this build cannot read leaves a **usable empty window**, and the dictation that
    /// follows is folded and persisted exactly as if the file had never existed.
    ///
    /// `load()` never throws — that is the store's contract — but the wiring has its own half of
    /// M7: an unreadable ledger must not leave the recorder unusable, silently swallowing every
    /// session for the rest of the run.
    func testALoadFailureLeavesAUsableEmptyWindow() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("this is not the ledger's format".utf8).write(
            to: directory.appendingPathComponent(PersistentUsageStore.fileName))

        let harness = Harness(directory: directory)
        let day = Self.day(2026, 9, 7)
        harness.days.set([day])
        await harness.recorder.load()

        let afterFailedLoad = await harness.recorder.currentWindow
        XCTAssertEqual(
            afterFailedLoad, UsageWindow(),
            "an unreadable file must load as the empty window, not as a broken one")
        XCTAssertFalse(
            harness.logs.entries.isEmpty,
            "the store's loud half must still have said so — a silent unreadable file is M7's "
                + "failure mode")

        await harness.recorder.fold(Self.delivered(via: .accessibility))
        await harness.recorder.flush()

        let persisted = await harness.freshStore().load()
        XCTAssertEqual(
            persisted.aggregate(for: day)?.realWork.delivered, 1,
            """
            a dictation after a failed load reached neither the window nor the file. A ledger that \
            could not be read is a lost history; it may not also be a broken recorder for the rest \
            of the run.
            """)
    }

    /// A session finalized while the launch load is still in flight is **not lost**, and the load
    /// does not overwrite it.
    ///
    /// The load is asynchronous because `configure` may not block, so a fast first dictation can
    /// genuinely land before the file has been read. Seeding the window from disk on top of an
    /// already-folded record would silently drop that session; folding onto an empty window and
    /// then loading over it would drop the whole history.
    func testAFoldThatArrivesBeforeTheLoadCompletesSurvivesIt() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = Self.day(2026, 9, 7)

        let seeding = Harness(directory: directory)
        seeding.days.set([day])
        await seeding.recorder.load()
        await seeding.recorder.fold(Self.delivered(via: .accessibility))
        await seeding.recorder.flush()

        let harness = Harness(directory: directory)
        harness.days.set([day])
        await harness.recorder.fold(Self.delivered(via: .clipboardPaste))
        let beforeLoad = await harness.fileSystem.events
        XCTAssertEqual(
            beforeLoad, [],
            "a fold before the load must not write — the window on disk has not been read yet")

        await harness.recorder.load()

        let merged = await harness.recorder.currentWindow
        let aggregate = try XCTUnwrap(merged.aggregate(for: day))
        XCTAssertEqual(
            aggregate.realWork.delivered, 2,
            """
            the launch load and the early session must both be in the window: got \
            \(aggregate.realWork.delivered) deliveries. One of the two was dropped.
            """)
    }

    // MARK: - D9 · the day is resolved per fold

    /// The provider is asked **on every fold**, so an app left running past midnight starts a new
    /// day without a restart (PRD E3).
    ///
    /// A day cached at launch is the defect this pins: it is invisible for as long as anyone
    /// tests within one day, and then posts every session of the next fortnight to the day the
    /// app happened to launch on.
    func testTheDayIsResolvedPerFoldSoASessionAfterMidnightLandsOnTheNewDay() async throws {
        let harness = Harness()
        let yesterday = Self.day(2026, 12, 31)
        let today = Self.day(2027, 1, 1)
        harness.days.set([yesterday, today, today])
        await harness.recorder.load()

        await harness.recorder.fold(Self.delivered(via: .accessibility))
        await harness.recorder.fold(Self.delivered(via: .accessibility))
        await harness.recorder.fold(Self.delivered(via: .accessibility))

        let window = await harness.recorder.currentWindow
        XCTAssertEqual(
            window.days.map(\.day), [yesterday, today],
            "each fold must be filed under the day the provider answered for it")
        XCTAssertEqual(window.aggregate(for: yesterday)?.realWork.delivered, 1)
        XCTAssertEqual(window.aggregate(for: today)?.realWork.delivered, 2)
        XCTAssertEqual(
            harness.days.calls(), 3,
            "the provider must be asked once per fold — a day cached at launch is E3's defect")
    }

    /// A provider that cannot name a day skips the fold rather than fabricating one or crashing.
    ///
    /// ``CalendarDayProvider`` is deliberately optional-returning (`SystemCalendarDayProvider`'s
    /// doc comment): a nonsense clock reading must not become a crash in a menu-bar app, and it
    /// must not become a plausible-looking day either. Nothing downstream can tell a fabricated
    /// day from a real one.
    func testAFoldWithNoDayIsSkippedRatherThanFiledUnderAFabricatedOne() async throws {
        let harness = Harness()
        harness.days.set([nil])
        await harness.recorder.load()

        await harness.recorder.fold(Self.delivered(via: .accessibility))

        let undated = await harness.recorder.currentWindow
        XCTAssertEqual(
            undated, UsageWindow(),
            "a record with no day must reach no day — never a repaired one")
        await harness.recorder.flush()
        let events = await harness.fileSystem.events
        XCTAssertEqual(
            events, [],
            "nothing changed, so nothing is owed to the file")
    }

    // MARK: - Termination

    /// `flush()` writes whatever is unwritten, whatever the clock says — the termination hook's
    /// half of the cadence.
    func testFlushWritesInsideTheIntervalBecauseTerminationCannotWait() async throws {
        let harness = Harness()
        let day = Self.day(2026, 9, 7)
        harness.days.set([day])
        await harness.recorder.load()
        await harness.recorder.fold(Self.delivered(via: .accessibility))

        await harness.recorder.flush()

        var events = await harness.fileSystem.events
        XCTAssertEqual(
            events.count, 2,
            "termination must commit the unwritten counts as one atomic pair")
        let persisted = await harness.freshStore().load()
        XCTAssertEqual(
            persisted.aggregate(for: day)?.realWork.delivered, 1,
            "the terminating write must contain the session that had not been committed yet")

        await harness.recorder.flush()
        events = await harness.fileSystem.events
        XCTAssertEqual(
            events.count, 2,
            "a second flush with nothing unwritten must not rewrite the file")
    }

    /// A flush before the load has completed writes **nothing**.
    ///
    /// The window in memory is not yet the window on disk, so committing it would replace a real
    /// history with an empty one. A quit during the launch load loses at most the sessions of
    /// that same launch — never the thirty days already recorded.
    func testAFlushBeforeTheLoadCompletesNeverOverwritesTheFile() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = Self.day(2026, 9, 7)

        let seeding = Harness(directory: directory)
        seeding.days.set([day])
        await seeding.recorder.load()
        await seeding.recorder.fold(Self.delivered(via: .accessibility))
        await seeding.recorder.flush()

        let harness = Harness(directory: directory)
        harness.days.set([day])
        await harness.recorder.fold(Self.delivered(via: .clipboardPaste))
        await harness.recorder.flush()

        let events = await harness.fileSystem.events
        XCTAssertEqual(
            events, [],
            "a flush before the load must write nothing — the file holds history this run has "
                + "not read")
        let persisted = await harness.freshStore().load()
        XCTAssertEqual(
            persisted.aggregate(for: day)?.realWork.delivered, 1,
            "the file must still hold the previous launch's day, untouched")
    }

    /// A save that throws is survivable: the recorder logs it and keeps the window it holds, so
    /// the next cadence tick tries again rather than the run going silent.
    func testASaveFailureIsLoudAndLeavesTheWindowIntact() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = LogCollector()
        let day = Self.day(2026, 9, 7)
        let store = PersistentUsageStore(
            directory: directory, fileSystem: FailingRenameUsageFileSystem(),
            log: { logs.append($0) })
        let days = SequencedDayProvider([day])
        let recorder = UsageRecorder(
            store: store, day: days.provider, clock: HandMovedClock(),
            log: { logs.append($0) })

        await recorder.load()
        await recorder.fold(Self.delivered(via: .accessibility))
        await recorder.flush()

        XCTAssertFalse(
            logs.entries.isEmpty,
            "a save that failed must be visible: the window the caller holds is not the window on "
                + "disk, and only a log line can say so")
        let held = await recorder.currentWindow
        XCTAssertEqual(
            held.aggregate(for: day)?.realWork.delivered, 1,
            "a failed save must not cost the counts already folded")
    }

    // MARK: - The harness

    /// Everything one recorder needs, over one temp directory: the real store, its recording
    /// file-system seam, a hand-moved clock and a scripted day provider.
    private final class Harness {
        let directory: URL
        let fileSystem = RecordingUsageFileSystem()
        let clock = HandMovedClock()
        let days = SequencedDayProvider()
        let logs = LogCollector()
        let recorder: UsageRecorder

        init(directory: URL? = nil) {
            let resolved = directory ?? UsageRecorderTests.tempDirectory()
            self.directory = resolved
            let logs = self.logs
            recorder = UsageRecorder(
                store: PersistentUsageStore(
                    directory: resolved, fileSystem: fileSystem, log: { logs.append($0) }),
                day: days.provider,
                clock: clock,
                log: { logs.append($0) })
        }

        /// A second store over the same directory, for reading back what was committed — the
        /// restart, without a second recorder.
        func freshStore() -> PersistentUsageStore {
            PersistentUsageStore(directory: directory)
        }
    }

    /// A temp directory that no test shares and no install uses. Never
    /// `~/Library/Application Support/Vocca/`.
    private static func tempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vocca-usage-recorder-\(UUID().uuidString)")
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay {
        guard let value = CalendarDay(year: year, month: month, day: day) else {
            preconditionFailure("the fixture names a real date")
        }
        return value
    }

    /// One fixture per outcome class, with each ``InjectionRung`` represented among the
    /// deliveries — so D2's claim covers the rung tally as well as the six classes.
    private static var everyOutcomeClass: [SessionOutcomeClass] {
        InjectionRung.allCases.map { .delivered(rung: $0, verified: true) }
            + [.failsafeHeld, .aborted, .failed, .lost, .emptySkip]
    }

    private static func delivered(via rung: InjectionRung) -> SessionRecord {
        record(outcome: .delivered(rung: rung, verified: true), kind: .dictation)
    }

    private static func record(
        outcome: SessionOutcomeClass, kind: SessionKind
    ) -> SessionRecord {
        SessionRecord(
            id: SessionRecord.ID(rawValue: nextIdentifier()), outcome: outcome,
            spans: [LatencySpan.recorded(name: .asr, elapsed: .milliseconds(120))],
            engine: nil, kind: kind)
    }

    /// Record identifiers are irrelevant to an aggregate — it folds counts — but they must be
    /// distinct so a fixture never reads as one record repeated.
    private static func nextIdentifier() -> Int {
        identifiers.withLock { value in
            value += 1
            return value
        }
    }

    private static let identifiers = Mutex<Int>(0)

}

/// A ``CalendarDayProvider`` reading from a script, one answer per call — the only way to stage a
/// midnight without waiting for one.
///
/// The last answer repeats once the script runs out, so a test that cares about two days does not
/// have to count the folds after them. Every call is counted, which is what makes "the provider is
/// asked per fold" (E3) assertable rather than inferred.
final class SequencedDayProvider: Sendable {
    private let answers = Mutex<[CalendarDay?]>([])
    private let callCount = Mutex<Int>(0)

    init(_ scripted: [CalendarDay?] = []) {
        answers.withLock { $0 = scripted }
    }

    func set(_ scripted: [CalendarDay?]) {
        answers.withLock { $0 = scripted }
    }

    func calls() -> Int {
        callCount.withLock { $0 }
    }

    var provider: CalendarDayProvider {
        { self.next() }
    }

    private func next() -> CalendarDay? {
        let index = callCount.withLock { count -> Int in
            defer { count += 1 }
            return count
        }
        return answers.withLock { scripted in
            guard !scripted.isEmpty else { return nil }
            return scripted[min(index, scripted.count - 1)]
        }
    }
}

/// The hand-moved monotonic clock the cadence tests drive — `@unchecked Sendable` for the reason
/// `RewarmTestClock` is: it crosses into an actor and its one field is behind a mutex.
final class HandMovedClock: MonotonicClock, @unchecked Sendable {
    private let reading = Mutex<Duration>(.zero)

    var now: Duration { reading.withLock { $0 } }

    func advance(by delta: Duration) {
        reading.withLock { $0 += delta }
    }
}
