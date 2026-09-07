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

/// The daily-use ledger's store — `usage-store/spec.md`'s C1–C12, in the
/// ``InjectionStrategyStoreTests`` shape it was planned against.
///
/// Like the strategy, dictionary and journal stores, `FileManager` works on a hosted runner, so
/// the real ``PersistentUsageStore`` runs here against **real temp directories**: a saved window
/// comes back from a fresh store over the same directory, a missing file loads empty silently,
/// and a load never rewrites the file. The injected file-system seam is what makes the failure
/// paths reachable and the injected log is what makes loudness assertable — both arrive with the
/// tolerance pins.
final class PersistentUsageStoreTests: XCTestCase {

    // MARK: - C1 · the round trip

    /// A window saved through the store comes back from a **fresh store over the same
    /// directory** — the restart, in the only form a test can stage it.
    ///
    /// This is the aspect's whole claim in one assertion: without it the ledger is a number that
    /// resets every launch, and a seven-day streak (`ROADMAP.md:102`) is unmeasurable by
    /// construction. It fails against the Phase 1 stub, which answers the empty window to every
    /// load.
    func testASavedWindowComesBackFromAFreshStoreOverTheSameDirectory() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = Self.twoDayWindow()

        try await PersistentUsageStore(directory: directory).save(saved)
        let loaded = await PersistentUsageStore(directory: directory).load()

        XCTAssertEqual(
            loaded, saved,
            "a window saved through the store must survive a restart — counts, rung tallies, "
                + "latency buckets and days, unchanged")
    }

    // MARK: - C2 · the missing file

    /// A store over a directory that does not exist loads the empty window — and says nothing.
    ///
    /// The silence is the assertion. Every install's first launch takes this path, so a log line
    /// here would be a permanent false alarm in the user's system log, and the seam's contract
    /// (`UsageStore.swift`, mirroring `InjectionStrategyStore.swift:15-29`) makes a missing file
    /// the empty history rather than a failure.
    func testAMissingFileLoadsEmptySilently() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = LogCollector()
        let store = PersistentUsageStore(directory: directory, log: { logs.append($0) })

        let loaded = await store.load()

        XCTAssertEqual(loaded, UsageWindow(), "an absent file is an empty history, not an error")
        XCTAssertTrue(
            logs.entries.isEmpty,
            "a first run must load silently — a missing usage.json is not a corruption, and a "
                + "log line here would fire on every install's first launch, got: \(logs.entries)")
    }

    // MARK: - C3 · corrupt rows

    /// A hand-edited file holding two readable days and five unreadable rows loads the two, one
    /// loud log per skipped row — and the file is byte-identical afterwards.
    ///
    /// This is what the per-row decode buys: a single `JSONDecoder` over the whole file would
    /// cost a user thirty days of history because one row was edited into nonsense. The five
    /// rows cover the ways a row can be unreadable — a wrong-typed field, a missing field, a
    /// fragment that is not an object at all, a count the vocabulary refuses as negative, and a
    /// rung raw value this build's ladder does not have.
    func testCorruptDayRowsAreSkippedLoudlyAndTheRemainingRowsLoad() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Self.readableRow(day: Self.day(2026, 9, 6), delivered: 3)
        let second = Self.readableRow(day: Self.day(2026, 9, 9), delivered: 1)
        let json = Self.fileText(rows: [
            first.text,
            #"{"day": 42}"#,
            second.text,
            #"{"day": "2026-09-07"}"#,
            #""not an object""#,
            Self.rowText(day: "2026-09-08", deliveredCount: -4, rung: "clipboardPaste"),
            Self.rowText(day: "2026-09-10", deliveredCount: 2, rung: "carrierPigeon"),
        ])
        try Self.plant(json, in: directory)
        let logs = LogCollector()

        let loaded = await PersistentUsageStore(directory: directory, log: { logs.append($0) })
            .load()

        var expected = UsageWindow()
        expected.insert(first.aggregate)
        expected.insert(second.aggregate)
        XCTAssertEqual(
            loaded, expected,
            "the readable days must load; each unreadable row must be skipped, never repaired")
        XCTAssertEqual(
            logs.entries.count, 5,
            "exactly one loud log per skipped row — a silent skip is history disappearing "
                + "without a trace, got: \(logs.entries)")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("usage.json")), Data(json.utf8),
            "a tolerant load must never rewrite the user's file")
    }

    // MARK: - C4 · a load never rewrites the file

    /// **A load never writes.** Three files — one this build wrote, one with a corrupt row, and
    /// one it refuses whole — are each byte-identical after a load.
    ///
    /// A file this build cannot fully interpret is not a file this build may overwrite: a
    /// repair-on-read would silently delete the very rows a user opened the file to look at, and
    /// would do it on the launch after the mistake rather than the one that made it.
    func testALoadNeverRewritesTheFile() async throws {
        let healthy = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: healthy) }
        try await PersistentUsageStore(directory: healthy).save(Self.twoDayWindow())

        let cases: [(name: String, directory: URL)] = try [
            ("a file this build wrote", healthy),
            ("a file with one corrupt row", Self.planted(
                Self.fileText(rows: [
                    Self.readableRow(day: Self.day(2026, 9, 6), delivered: 3).text,
                    #"{"day": 42}"#,
                ]))),
            ("a file this build refuses whole", Self.planted(
                Self.fileText(rows: [], version: 2))),
        ]

        for (name, directory) in cases {
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("usage.json")
            let before = try Data(contentsOf: url)

            _ = await PersistentUsageStore(directory: directory).load()

            XCTAssertEqual(
                try Data(contentsOf: url), before,
                "a load must leave \(name) byte-identical — reading history must never be a "
                    + "write, least of all a repair the user did not ask for")
        }
    }

    // MARK: - C5 · the whole-file tolerance gates

    /// A top level that is not an object, an unknown `version`, and a version-less object each
    /// load the empty window with exactly one loud log, bytes untouched.
    ///
    /// Version 1 is the first version and there is no migration machinery (`spec.md`): a
    /// version-2 file a later build wrote loads empty rather than being guessed at, because a
    /// guess about a format this build has never seen is a silent misreading of a user's
    /// history.
    func testAFileThatIsNotAnObjectOrCarriesAnUnknownVersionLoadsEmptyLoudly() async throws {
        let readable = Self.readableRow(day: Self.day(2026, 9, 6), delivered: 3).text
        for (name, json) in [
            ("a top level that is an array", "[\(readable)]"),
            ("a top level that is a string", #""usage""#),
            ("a version this build has never seen", Self.fileText(rows: [readable], version: 2)),
            ("no version at all", Self.fileText(rows: [readable], version: nil)),
            ("no days list at all", Self.fileText(rows: nil)),
        ] {
            let directory = try Self.planted(json)
            defer { try? FileManager.default.removeItem(at: directory) }
            let logs = LogCollector()

            let loaded = await PersistentUsageStore(directory: directory, log: { logs.append($0) })
                .load()

            XCTAssertEqual(
                loaded, UsageWindow(),
                "\(name) must load empty — never be partly believed")
            XCTAssertEqual(
                logs.entries.count, 1,
                "\(name) is exactly one loud refusal, got: \(logs.entries)")
            XCTAssertEqual(
                try Data(contentsOf: directory.appendingPathComponent("usage.json")),
                Data(json.utf8),
                "a refused file must never be rewritten")
        }
    }

    // MARK: - C6 · bounds that are not this build's

    /// **A file whose `bucketUpperBoundsMilliseconds` are not the running build's loads empty,
    /// loudly** — not partially trusted, not repaired.
    ///
    /// This is the reinterpretation trap the bounds are written into the file to catch
    /// (`spec.md`). Bucket counts are meaningless without the bounds that produced them: were
    /// the table to change in a later release, every retained day would silently re-read as
    /// different latencies, and a p50 the user had been watching would move because the code
    /// changed rather than because the tool did. Both shapes must be refused — a same-length
    /// table with different numbers, which decodes perfectly and means something else, and a
    /// different-length one.
    func testBoundsThatAreNotThisBuildsLoadEmptyLoudly() async throws {
        let readable = Self.readableRow(day: Self.day(2026, 9, 6), delivered: 3).text
        let build = LatencyHistogram.bucketUpperBoundsMilliseconds
        for (name, bounds) in [
            ("a same-length table with different numbers", build.map { $0 * 2 }),
            ("a shorter table", Array(build.dropLast())),
            ("a longer table", build + [9_000]),
            ("an empty table", []),
        ] {
            let json = Self.fileText(rows: [readable], bounds: bounds)
            let directory = try Self.planted(json)
            defer { try? FileManager.default.removeItem(at: directory) }
            let logs = LogCollector()

            let loaded = await PersistentUsageStore(directory: directory, log: { logs.append($0) })
                .load()

            XCTAssertEqual(
                loaded, UsageWindow(),
                "\(name) must load empty — a bucket count read against bounds that did not "
                    + "produce it is a fabricated latency, not a tolerated one")
            XCTAssertEqual(
                logs.entries.count, 1,
                "a bounds mismatch is exactly one loud refusal, got: \(logs.entries)")
            XCTAssertEqual(
                try Data(contentsOf: directory.appendingPathComponent("usage.json")),
                Data(json.utf8),
                "a refused file must never be rewritten")
        }
    }

    // MARK: - C7 · the atomic pair

    /// A save is recorded as exactly two events — the temp written, then renamed over
    /// `usage.json` — the committed file holds the encoded window, and no `.tmp` remains.
    func testSaveIsAnAtomicTempWriteThenRenamePair() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingUsageFileSystem()
        let store = PersistentUsageStore(directory: directory, fileSystem: fileSystem)
        let window = Self.twoDayWindow()

        try await store.save(window)

        let events = await fileSystem.events
        XCTAssertEqual(
            events, [.tempWrite("usage.json.tmp"), .rename("usage.json")],
            "a durable save is exactly two events: temp written, then renamed into place")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("usage.json")),
            try PersistentUsageStore.encode(window),
            "the committed file must hold the encoded window")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("usage.json.tmp").path),
            "no .tmp may remain after a completed save")
    }

    /// The torn half: a rename that throws after the temp write lands leaves the previously
    /// committed file exactly as it was, and a fresh store still loads the previous window.
    ///
    /// Power loss between the pair is the case this stages, and the ledger is saved on a cadence
    /// — so this is not a rare path over a lifetime of use. A half-written ledger would be worse
    /// than a stale one: the stale file is history the user did have.
    func testAFailedRenameLeavesThePreviouslyCommittedContentIntact() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let committed = Self.twoDayWindow()
        try await PersistentUsageStore(directory: directory).save(committed)
        let before = try Data(contentsOf: directory.appendingPathComponent("usage.json"))

        let torn = PersistentUsageStore(
            directory: directory, fileSystem: FailingRenameUsageFileSystem())
        do {
            try await torn.save(Self.thirtyFiveDayWindow())
            XCTFail("a rename that throws must surface as a failed save")
        } catch {
            // Expected — the caller must be able to see that its window is not the file's.
        }

        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("usage.json")), before,
            "the committed file must be the previous content, never partial")
        let reloaded = await PersistentUsageStore(directory: directory).load()
        XCTAssertEqual(
            reloaded, committed,
            "a torn save loses the new window, never the old one")
    }

    // MARK: - C8 · the stray temp

    /// A stray `usage.json.tmp` left by a crash between the pair is never read: planted beside
    /// the committed file — and holding a window that would otherwise decode perfectly, so the
    /// test cannot pass merely because the temp was garbage — a load returns the committed one.
    func testAStrayTempFileFromACrashIsNeverRead() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let committed = Self.twoDayWindow()
        try await PersistentUsageStore(directory: directory).save(committed)
        try PersistentUsageStore.encode(Self.thirtyFiveDayWindow())
            .write(to: directory.appendingPathComponent("usage.json.tmp"))

        let loaded = await PersistentUsageStore(directory: directory).load()

        XCTAssertEqual(
            loaded, committed,
            "only usage.json is ever read — a torn write that never reached the rename is not "
                + "history, however well-formed its bytes are")
    }

    // MARK: - C9 · an impossible date

    /// An impossible or malformed date in a hand-edited file skips that row rather than
    /// repairing it into a plausible one — one loud log each, and the well-dated row loads.
    ///
    /// `CalendarDay.init(year:month:day:)` is the parser's gate (`spec.md`), and the parse
    /// around it is strict on the spelling: a lenient parse would accept `2026-09-06T14:32:11`,
    /// which is a wall-clock time in a file that must never hold one.
    func testAnImpossibleOrMalformedDateSkipsTheRowRatherThanRepairingIt() async throws {
        let readable = Self.readableRow(day: Self.day(2026, 9, 6), delivered: 3)
        for (name, spelling) in [
            ("a day February does not have", "2026-02-30"),
            ("an unpadded month", "2026-9-6"),
            ("a thirteenth month", "2026-13-01"),
            ("a date carrying a time", "2026-09-07T14:32:11"),
            ("an epoch integer where a date belongs", "1757203200"),
            ("not a date at all", "yesterday"),
        ] {
            let json = Self.fileText(rows: [
                readable.text,
                Self.rowText(day: spelling, deliveredCount: 5, rung: "clipboardPaste"),
            ])
            let directory = try Self.planted(json)
            defer { try? FileManager.default.removeItem(at: directory) }
            let logs = LogCollector()

            let loaded = await PersistentUsageStore(directory: directory, log: { logs.append($0) })
                .load()

            var expected = UsageWindow()
            expected.insert(readable.aggregate)
            XCTAssertEqual(
                loaded, expected,
                "\(name) must skip its row — a repaired date attributes a day's work to a day "
                    + "it did not happen on")
            XCTAssertEqual(
                logs.entries.count, 1, "\(name) is exactly one loud skip, got: \(logs.entries)")
        }
    }

    // MARK: - C10 · the privacy pin, on the bytes

    /// **The unit's central promise, asserted on the artifact.** A window folded from sessions
    /// that carried a distinctive phrase, and were measured at real millisecond latencies,
    /// encodes to bytes holding neither the phrase, nor a time of day, nor a timestamp of any
    /// shape.
    ///
    /// `usage.json` is the file a privacy-focused user opens to check what Vocca keeps about
    /// them. It must read as a **tally of what happened** — how many dictations, how fast, on
    /// which days — and never as a **trace of when they were at their desk**. A transcript
    /// fragment would be the obvious breach; a wall-clock time is the quiet one, because a
    /// per-session timestamp reconstructs a person's working hours, their breaks and their
    /// nights from a file that looks like statistics.
    ///
    /// The phrase is carried where a ``SessionRecord`` can genuinely hold free text — the
    /// ``EngineIdentity`` attached to each session, whose `id` and `displayName` are strings
    /// that travelled the whole pipeline with the transcript. The record has no transcript field
    /// at all, by construction, and that is exactly the property this pin defends from the other
    /// side: the format must not acquire one, and must not smuggle in the text it *can* reach.
    ///
    /// **What each half is worth, stated plainly.** The time assertions have teeth against the
    /// format as it stands: a `generatedAt` — an ISO string or epoch seconds, the obvious thing
    /// to add to a file someone wants to know the age of — is one line away, and each shape is
    /// caught here. The phrase assertion is, today, guaranteed by the vocabulary rather than by
    /// the format: ``DayAggregate`` folds the engine away, so the encoder has no text to reach
    /// even if it wanted some. It is written on the bytes anyway, and kept, because it is the
    /// assertion that fails on the day a row is widened to carry a name — deliveries by engine,
    /// by app, by anything — which is the plausible next request and the one that would end the
    /// promise quietly.
    func testTheEncodedBytesCarryNoTextAndNoWallClockTime() throws {
        let window = Self.phraseCarryingWindow()
        XCTAssertFalse(
            window.days.isEmpty,
            "vacuity guard: the pin must run against a window with days in it")
        XCTAssertGreaterThan(
            window.days.reduce(0) { $0 + $1.sessionCount }, 0,
            "vacuity guard: the pin must run against a window folded from real sessions")

        let data = try PersistentUsageStore.encode(window)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertNil(
            data.range(of: Data(Self.distinctivePhrase.utf8)),
            "usage.json must not carry a syllable the sessions carried. This is the file a "
                + "privacy-focused user opens to check what Vocca keeps about them; text of any "
                + "provenance in it breaks the promise that audio and transcripts never leave "
                + "the moment they were spoken in. Bytes: \(text)")
        XCTAssertNil(
            text.range(of: "[0-9]:[0-9]", options: .regularExpression),
            "usage.json must hold no time of day. A colon between two digits is the HH:MM shape; "
                + "the only colons in this file may be JSON's own key separators. A ledger that "
                + "records when a user dictated is a trace of when they were at their desk, not "
                + "a tally of what they did. Bytes: \(text)")
        for (name, pattern) in [
            ("an ISO-8601 date-time marker", "[0-9]{4}-[0-9]{2}-[0-9]{2}T"),
            ("a Zulu suffix", "[0-9]Z"),
            ("an epoch-looking integer", "[0-9]{10}"),
        ] {
            XCTAssertNil(
                text.range(of: pattern, options: .regularExpression),
                "usage.json must hold no timestamp: found \(name). A calendar day is the "
                    + "finest time this file may resolve — anything finer reconstructs a "
                    + "person's working hours from what is meant to be a count. Bytes: \(text)")
        }
    }

    // MARK: - C11 · retention survives the round trip

    /// At most thirty days are ever written, and at most thirty are ever read: a window fed
    /// thirty-five days saves thirty rows and reloads as the newest thirty, and a hand-edited
    /// file holding thirty-five rows still loads bounded.
    ///
    /// The bound is the ledger's whole answer to "how long does Vocca keep this" — an unbounded
    /// file would quietly become a year of a user's habits because nothing ever pruned it.
    func testAtMostThirtyDaysAreEverWrittenAndEverRead() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = Self.thirtyFiveDayWindow()
        XCTAssertEqual(
            window.days.count, UsageWindowConstants.maximumRetainedDays,
            "the window bounds itself on the way in")

        try await PersistentUsageStore(directory: directory).save(window)

        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("usage.json")))
        XCTAssertEqual(
            ((written as? [String: Any])?["days"] as? [Any])?.count,
            UsageWindowConstants.maximumRetainedDays,
            "the file must hold at most the retained days — never more history than the window "
                + "itself keeps")
        let loaded = await PersistentUsageStore(directory: directory).load()
        XCTAssertEqual(loaded, window, "the retained days round-trip exactly")

        let overfull = try Self.planted(
            Self.fileText(
                rows: (1...35).map {
                    Self.rowText(
                        day: Self.spelled(Self.consecutiveDay(offset: $0)), deliveredCount: 1,
                        rung: "clipboardPaste")
                }))
        defer { try? FileManager.default.removeItem(at: overfull) }
        let bounded = await PersistentUsageStore(directory: overfull).load()
        XCTAssertEqual(
            bounded.days.count, UsageWindowConstants.maximumRetainedDays,
            "a hand-edited file holding more than the retained days loads bounded — retention is "
                + "the window's rule and applies on the way in, not the file's to widen")
        XCTAssertEqual(
            bounded.days.first?.day, Self.day(2026, 1, 6),
            "the newest days are what survive; the oldest are the ones evicted")
    }

    // MARK: - C12 · the default location

    /// The no-argument store resolves `~/Library/Application Support/Vocca/usage.json`, and its
    /// fallback — for the machine where Application Support cannot be resolved — puts the file
    /// under the home directory rather than somewhere unpredictable.
    ///
    /// Asserted on the **constructed URL**: a test that wrote here would put a real
    /// `usage.json` in the developer's own Application Support and then have to decide whether
    /// to delete a file it might not have created.
    func testTheDefaultLocationIsApplicationSupportVoccaUsageJSON() async {
        let resolved = PersistentUsageStore.defaultDirectory(
            applicationSupport: URL(fileURLWithPath: "/Users/example/Library/Application Support"),
            home: URL(fileURLWithPath: "/Users/example"))
        XCTAssertEqual(
            resolved.appendingPathComponent(PersistentUsageStore.fileName).path,
            "/Users/example/Library/Application Support/Vocca/usage.json",
            "the ledger lives beside the tree's other Application Support files")

        let fallback = PersistentUsageStore.defaultDirectory(
            applicationSupport: nil, home: URL(fileURLWithPath: "/Users/example"))
        XCTAssertEqual(
            fallback.appendingPathComponent(PersistentUsageStore.fileName).path,
            "/Users/example/Library/Application Support/Vocca/usage.json",
            "an unresolvable Application Support falls back to the same place under the home "
                + "directory — defensive, not a different decision about where history lives")

        let real = await PersistentUsageStore().fileURL
        XCTAssertTrue(
            real.path.hasSuffix("/Library/Application Support/Vocca/usage.json"),
            "the shipped default resolves the documented path, got: \(real.path)")
    }

    // MARK: - C13 · clearing the ledger

    /// **Clear deletes the file**, and a load after it is the empty window.
    ///
    /// `PRODUCT_SPEC.md:306` says the control "empties the window and deletes the file behind
    /// it", and `UsageTabCopy.clearExplanation` says so to the user in the same words. An
    /// implementation that wrote an empty window instead would leave a file on disk that the copy
    /// says is gone — a false statement on the one page whose entire job is being checkable.
    func testClearDeletesTheFileSoALoadAfterItIsEmpty() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingUsageFileSystem()
        let store = PersistentUsageStore(directory: directory, fileSystem: fileSystem)
        try await store.save(Self.twoDayWindow())
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("usage.json").path),
            "the fixture must actually be on disk, or the removal below proves nothing")

        try await store.clear()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("usage.json").path),
            "clear removes the ledger's file — the copy says it deletes it, so it deletes it")
        let events = await fileSystem.events
        XCTAssertEqual(
            events.last, .removal("usage.json"),
            "the removal goes through the seam, not around it: FileManager in this module lives "
                + "in the adapter alone, got: \(events)")
        let reloaded = await PersistentUsageStore(directory: directory).load()
        XCTAssertEqual(
            reloaded, UsageWindow(),
            "and a fresh store loads nothing afterwards — a Clear whose history comes back at "
                + "the next launch is a disclosure that lied")
    }

    /// Clearing a ledger that was never written is not an error.
    ///
    /// The missing file is the first-run state (`C2`), and a user who presses Clear on a fresh
    /// install must not be told something failed: there was nothing to delete, which is the
    /// outcome they asked for.
    func testClearOverAMissingFileIsNotAnError() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentUsageStore(directory: directory)

        try await store.clear()

        let reloaded = await store.load()
        XCTAssertEqual(reloaded, UsageWindow(), "nothing to delete is nothing to report")
    }

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-usage-\(UUID().uuidString)")
    }

    /// Two days of real content: both columns used, three rungs credited, latencies in several
    /// buckets including the overflow one, and an onboarding loss that must not be folded into
    /// the real-work column by the format.
    private static func twoDayWindow() -> UsageWindow {
        var window = UsageWindow()
        window.insert(
            DayAggregate.folded(
                [
                    delivered(via: .accessibility, milliseconds: 90),
                    delivered(via: .accessibility, milliseconds: 140),
                    delivered(via: .clipboardPaste, milliseconds: 260),
                    heldByTheFailsafe(milliseconds: 7_000),
                    emptyPress(),
                ],
                on: day(2026, 9, 6)))
        window.insert(
            DayAggregate.folded(
                [
                    delivered(via: .clipboardPaste, milliseconds: 45),
                    lostTranscript(milliseconds: 310),
                    onboardingLoss(),
                ],
                on: day(2026, 9, 7)))
        return window
    }

    private static func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> CalendarDay {
        guard let day = CalendarDay(year: year, month: month, day: dayOfMonth) else {
            preconditionFailure("the fixture names a real date")
        }
        return day
    }

    private static func delivered(via rung: InjectionRung, milliseconds: Int) -> SessionRecord {
        record(outcome: .delivered(rung: rung, verified: true), milliseconds: milliseconds)
    }

    private static func heldByTheFailsafe(milliseconds: Int) -> SessionRecord {
        record(outcome: .failsafeHeld, milliseconds: milliseconds)
    }

    private static func lostTranscript(milliseconds: Int) -> SessionRecord {
        record(outcome: .lost, milliseconds: milliseconds)
    }

    /// A short press: nothing recorded, so it contributes a count and **no** latency sample.
    private static func emptyPress() -> SessionRecord {
        SessionRecord(
            id: SessionRecord.ID(rawValue: nextIdentifier()), outcome: .emptySkip,
            spans: [LatencySpan.cleanupNotPresent()], engine: nil, kind: .dictation)
    }

    private static func onboardingLoss() -> SessionRecord {
        SessionRecord(
            id: SessionRecord.ID(rawValue: nextIdentifier()), outcome: .lost,
            spans: [LatencySpan.recorded(name: .asr, elapsed: .milliseconds(500))], engine: nil,
            kind: .onboarding)
    }

    /// `engine` is defaulted away for every fixture but C10's, where the point is that a session
    /// carried free text through the pipeline and none of it may reach the file.
    private static func record(
        outcome: SessionOutcomeClass, milliseconds: Int, engine: EngineIdentity? = nil
    ) -> SessionRecord {
        SessionRecord(
            id: SessionRecord.ID(rawValue: nextIdentifier()), outcome: outcome,
            spans: [
                LatencySpan.recorded(name: .asr, elapsed: .milliseconds(milliseconds)),
                LatencySpan.cleanupNotPresent(),
            ],
            engine: engine, kind: .dictation)
    }

    /// Record identifiers are irrelevant to the aggregate — it folds counts — but they must be
    /// distinct so the fixture never reads as one record repeated.
    private static func nextIdentifier() -> Int {
        identifiers.withLock { value in
            value += 1
            return value
        }
    }

    private static let identifiers = Mutex<Int>(0)

    /// A `usage.json` body around `rows`, carrying the running build's own bucket table unless a
    /// different one is named — so no test in this file spells the bounds, which have exactly one
    /// home (`LatencyHistogramTests.testTheBucketBoundsLiveInExactlyOneNamedConstant`). `nil`
    /// omits the key entirely, which is how the version-less and list-less files are staged.
    private static func fileText(
        rows: [String]?, version: Int? = 1,
        bounds: [Int] = LatencyHistogram.bucketUpperBoundsMilliseconds
    ) -> String {
        var fields: [String] = []
        if let version { fields.append("\"version\": \(version)") }
        fields.append(
            "\"bucketUpperBoundsMilliseconds\": [\(bounds.map(String.init).joined(separator: ", "))]")
        if let rows { fields.append("\"days\": [\(rows.joined(separator: ", "))]") }
        return "{\(fields.joined(separator: ", "))}"
    }

    /// One hand-written day row: `deliveredCount` real-work deliveries credited to `rung`, no
    /// onboarding, an empty histogram. Written as text rather than encoded, because the point of
    /// every test that uses it is a file this build did **not** write.
    private static func rowText(day: String, deliveredCount: Int, rung: String) -> String {
        let empty =
            #"{"aborted": 0, "delivered": 0, "deliveriesByRung": {}, "emptySkip": 0, "#
            + #""failed": 0, "failsafeHeld": 0, "lost": 0}"#
        let realWork =
            #"{"aborted": 0, "delivered": \#(deliveredCount), "#
            + #""deliveriesByRung": {"\#(rung)": \#(deliveredCount)}, "emptySkip": 0, "#
            + #""failed": 0, "failsafeHeld": 0, "lost": 0}"#
        let buckets = Array(
            repeating: "0", count: LatencyHistogram.bucketUpperBoundsMilliseconds.count + 1)
        return
            #"{"day": "\#(day)", "onboarding": \#(empty), "realWork": \#(realWork), "#
            + #""realWorkLatencyBuckets": [\#(buckets.joined(separator: ", "))]}"#
    }

    /// A readable row and the aggregate it must load as — paired, so a test that plants one
    /// cannot drift from what it asserts loaded.
    private static func readableRow(
        day: CalendarDay, delivered: Int
    ) -> (text: String, aggregate: DayAggregate) {
        guard
            let counts = DayAggregate.OutcomeCounts(
                delivered: delivered, failsafeHeld: 0, aborted: 0, failed: 0, lost: 0,
                emptySkip: 0, deliveriesByRung: [.clipboardPaste: delivered]),
            let empty = DayAggregate.OutcomeCounts(
                delivered: 0, failsafeHeld: 0, aborted: 0, failed: 0, lost: 0, emptySkip: 0,
                deliveriesByRung: [:])
        else {
            preconditionFailure("the fixture's counts are non-negative")
        }
        return (
            rowText(day: spelled(day), deliveredCount: delivered, rung: "clipboardPaste"),
            DayAggregate(
                day: day, realWork: counts, onboarding: empty,
                realWorkLatency: LatencyHistogram())
        )
    }

    /// The row's own spelling of a day — the format's `YYYY-MM-DD`, written here so the fixtures
    /// and the store agree on it without the tests reaching into the store to ask.
    private static func spelled(_ day: CalendarDay) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    /// Plant `json` as `usage.json` in `directory`, creating it.
    private static func plant(_ json: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("usage.json"))
    }

    /// Plant `json` in a fresh temp directory and answer the directory.
    private static func planted(_ json: String) throws -> URL {
        let directory = tempDirectory()
        try plant(json, in: directory)
        return directory
    }

    /// Thirty-five consecutive days of one delivery each, offered to a window that retains
    /// thirty — so what comes back is already the bounded set.
    private static func thirtyFiveDayWindow() -> UsageWindow {
        var window = UsageWindow()
        for offset in 1...35 {
            window.insert(
                DayAggregate.folded(
                    [delivered(via: .clipboardPaste, milliseconds: 100 + offset)],
                    on: consecutiveDay(offset: offset)))
        }
        return window
    }

    /// The `offset`-th day of a consecutive run starting 2026-01-01 — January's thirty-one days
    /// and then February's, so a thirty-five-day fixture crosses a month boundary rather than
    /// naming dates like `2026-01-33`, which are not days and would be skipped as such.
    private static func consecutiveDay(offset: Int) -> CalendarDay {
        offset <= 31 ? day(2026, 1, offset) : day(2026, 2, offset - 31)
    }

    /// The phrase the C10 sessions carried — distinctive enough that finding it in the bytes
    /// could mean nothing else, and hyphenated so no substring of it is ordinary JSON.
    private static let distinctivePhrase = "quokka-parliament-hexadecimal"

    /// Three days folded from sessions that each carried ``distinctivePhrase`` — in
    /// ``EngineIdentity``, the one place a ``SessionRecord`` holds free text — and were measured
    /// at real latencies. What the format may keep of all that is counts, buckets and dates.
    private static func phraseCarryingWindow() -> UsageWindow {
        let engine = EngineIdentity(
            id: "engine.\(distinctivePhrase)", displayName: "Engine \(distinctivePhrase)",
            isLocal: true)
        var window = UsageWindow()
        for (offset, milliseconds) in [143, 927, 1_432, 60_000].enumerated() {
            window.insert(
                DayAggregate.folded(
                    [
                        record(
                            outcome: .delivered(rung: .accessibility, verified: true),
                            milliseconds: milliseconds, engine: engine),
                        record(
                            outcome: .delivered(rung: .clipboardPaste, verified: true),
                            milliseconds: milliseconds / 2, engine: engine),
                        record(outcome: .lost, milliseconds: milliseconds, engine: engine),
                        emptyPress(),
                    ],
                    on: day(2026, 9, 4 + offset)))
        }
        return window
    }
}

/// What the usage ledger's file-system seam records, in order — the **atomic-pair protocol** the
/// durability claim is carried by (the strategy store's `InjectionStrategyFileSystemEvent` shape).
enum UsageFileSystemEvent: Equatable {
    /// The temp file was written — not yet readable, not yet committed.
    case tempWrite(String)
    /// The temp file was renamed over the ledger's name — the commit point.
    case rename(String)
    /// The ledger's file was deleted — what Clear does, and the one event that is not a write.
    case removal(String)
}

/// A ``UsageFileSystem`` over real temp directories whose every save is recorded as the atomic
/// temp-write/rename pair. The commit is `replaceItemAt`, mirroring the shipped adapter — whose
/// overwrite-succeeds commit is the point of the pair — so the second save of a ledger saved on a
/// cadence records the same two events as the first.
actor RecordingUsageFileSystem: UsageFileSystem {
    private(set) var events: [UsageFileSystemEvent] = []

    func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
        events.append(.tempWrite(url.lastPathComponent))
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        events.append(.rename(destination.lastPathComponent))
    }

    func removeItem(at url: URL) async throws {
        try FileManager.default.removeItem(at: url)
        events.append(.removal(url.lastPathComponent))
    }

    func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// The torn half of the pair: the temp write lands on disk, the rename throws — a crash between
/// the two, staged.
struct FailingRenameUsageFileSystem: UsageFileSystem {
    func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        throw UsageStoreTestError.renameFailed
    }

    func removeItem(at url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }

    func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// What a usage-store failure is, for the torn-save test — the specific error is the file
/// system's business; the contract is that `save` surfaces it.
enum UsageStoreTestError: Error {
    /// The rename between the pair failed.
    case renameFailed
    /// The ledger's file could not be deleted — the Clear half of the same contract.
    case removalFailed
}

