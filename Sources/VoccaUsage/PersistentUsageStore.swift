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
import OSLog
import VoccaCore

/// **The usage ledger's file-system seam — the one file in `VoccaUsage` permitted to name
/// `FileManager`** (the `usage` row in `InjectionSeamBoundaryTests`' per-seam FileManager table,
/// beside the journal, dictionary, config and strategy seams' adapters).
///
/// Raw operations only, in the strategy adapter's shape: directory creation, the atomic
/// temp-write-then-rename commit, and reads. Nothing here decides. Which row is corrupt, what
/// version is readable and when a save commits are ``PersistentUsageStore``'s questions, answered
/// over this seam — a second `FileManager`-naming file in the module would be a usage-store
/// decision that escaped the headless suite forever.
public protocol UsageFileSystem: Sendable {
    /// Create `url` (and its parents), as `FileManager` would with
    /// `withIntermediateDirectories: true`.
    func createDirectory(at url: URL) async throws

    /// Write `data` to `url`.
    func write(_ data: Data, to url: URL) async throws

    /// Move the file at `source` over `destination` — the commit point of the atomic pair.
    /// Succeeds whether or not `destination` already exists: an overwrite is a replace, not a
    /// refusal.
    func moveItem(at source: URL, to destination: URL) async throws

    /// Delete the file at `url`. Called only for a file the store has just seen exist, so a
    /// missing one may throw — the store's own ``PersistentUsageStore/clear()`` asks first.
    func removeItem(at url: URL) async throws

    /// The file's bytes, or `nil` if it cannot be read.
    func read(_ url: URL) async -> Data?

    /// Whether a file exists at `path`.
    func fileExists(atPath path: String) async -> Bool
}

/// The seam's only `FileManager` implementation — translation with no decisions in it.
public struct DefaultUsageFileSystem: UsageFileSystem {
    public init() {}

    public func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    public func moveItem(at source: URL, to destination: URL) async throws {
        // The atomic replace, not `moveItem`: `FileManager.moveItem` refuses an existing
        // destination (NSFileWriteFileExistsError), which — in the strategy store, where this
        // was learned — made every save after the first fail once the file existed. A ledger
        // saved on a cadence is the shape that failure hurts most: the first day would persist
        // and every day after it would throw. `replaceItemAt` is the same rename-over commit
        // and succeeds whether or not the destination is there.
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
    }

    public func removeItem(at url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }

    public func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    public func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// The daily-use ledger on disk — `<directory>/usage.json` — and the ``UsageStore`` the app
/// loads at launch and saves the whole window through.
///
/// It is the `PersistentInjectionStrategyStore` shape, deliberately: a store over a directory,
/// with the decisions — the day parse, the per-row skips, the bucket-bounds check — belonging
/// above the file system where a headless suite can drive them, and nothing but path resolution
/// and raw I/O below.
///
/// ## The format
///
/// ```json
/// { "version": 1,
///   "bucketUpperBoundsMilliseconds": [ ... ],
///   "days": [
///     { "day": "2026-09-06",
///       "realWork":   { "delivered": 33, "failsafeHeld": 1, "aborted": 0, "failed": 0,
///                       "lost": 0, "emptySkip": 2,
///                       "deliveriesByRung": { "accessibility": 11, "clipboardPaste": 22 } },
///       "onboarding": { "delivered": 0, ... , "deliveriesByRung": {} },
///       "realWorkLatencyBuckets": [0, 0, 2, ...] } ] }
/// ```
///
/// **The bucket bounds are written into the file, deliberately** (`spec.md`). Bucket counts are
/// meaningless without the bounds that produced them: change
/// ``LatencyHistogram/bucketUpperBoundsMilliseconds`` in a later release and every retained day
/// silently re-reads as different latencies. Recording them is what makes that mismatch
/// *detectable* instead of a quiet reinterpretation. They are never re-derived or spelled here —
/// the array is read from the Core constant, which has exactly one home
/// (`LatencyHistogramTests.testTheBucketBoundsLiveInExactlyOneNamedConstant`).
///
/// Rung tallies are keyed by ``InjectionRung``'s raw values — "the persisted spelling, so a
/// rename is a migration, not a refactor" (`InjectionRung.swift:29`) — as a **string-keyed
/// object**, so the file stays hand-readable like `dictionary.json` and `cleanup-config.json`
/// (`ARCHITECTURE.md`). `day` is `YYYY-MM-DD`, and ``CalendarDay/init(year:month:day:)`` is the
/// parser's gate: an impossible date in a hand-edited file yields `nil` and the row is skipped,
/// never repaired into a plausible one.
///
/// ## Tolerant on the way in, and loud about it
///
/// Three gates refuse a whole file — a top level that is not an object, a `version` this build
/// has never seen, and **bucket bounds that are not this build's** — and each emits exactly one
/// line through the injected ``log``. Below them, each day row is decoded on its own, and a row
/// that cannot be read is skipped with one line of its own rather than costing the file. Nothing
/// is repaired: a refused file and a skipped row are both left exactly as the user wrote them,
/// because a load that rewrites is a load that can delete history the user opened the file to
/// read.
///
/// ## Concurrency contract
///
/// Single process, one writer: ``load()`` once at launch, then the caller holds the window and
/// ``save(_:)`` persists the **whole window** atomically — a racing pair of saves ends with one
/// complete file, never a partial one. The atomic rename means a concurrent read sees the old or
/// the new complete file. An actor is the honest Swift 6 shape for that, the
/// ``PersistentInjectionStrategyStore`` precedent.
public actor PersistentUsageStore: UsageStore {
    /// The directory the ledger lives in. The file is always `<directory>/usage.json`.
    public let directory: URL

    private let fileSystem: UsageFileSystem
    private let log: @Sendable (String) -> Void

    /// The ledger's file name, in one place, because it is the persisted spelling: changing it
    /// orphans every existing install's history rather than migrating it.
    public static let fileName = "usage.json"

    /// The suffix of the temp file mid-commit — never readable, never loaded.
    private static let tempSuffix = ".tmp"

    /// The format's version, in one place so ``encode(_:)`` and the version gate in
    /// ``decode(_:onInvalidRow:)`` cannot drift into writing one number and accepting another.
    /// Version 1 is the first version and there is no migration machinery (`spec.md`).
    private static let formatVersion = 1

    /// The file itself — `<directory>/usage.json`.
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// A store over `directory`. The directory is created on the first persist; a store over a
    /// directory that does not exist is an empty history, not an error.
    ///
    /// The `log` closure is the loud half of the corruption policy — every skipped row and every
    /// unreadable file will go through it, injectable so the loudness is asserted rather than
    /// hoped (`PersistentInjectionStrategyStore.swift:130-133`). See the type's doc comment: the
    /// lines themselves arrive with the tolerance gates.
    public init(
        directory: URL,
        fileSystem: UsageFileSystem = DefaultUsageFileSystem(),
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "usage-ledger").error("\($0)")
        }
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.log = log
    }

    /// A store over the default location (`ARCHITECTURE.md` §12's Application Support table):
    /// `~/Library/Application Support/Vocca/usage.json`. The fallback keeps the store working
    /// even if the Application Support directory is unavailable to resolve — a defensive default,
    /// not a decision about where the history lives.
    public init() {
        self.init(
            directory: Self.defaultDirectory(
                applicationSupport: FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                ).first,
                home: FileManager.default.homeDirectoryForCurrentUser))
    }

    /// Where ``init()`` puts the ledger, as a pure function of what the file system answered —
    /// `<applicationSupport>/Vocca`, or `<home>/Library/Application Support/Vocca` when
    /// Application Support could not be resolved.
    ///
    /// Separated from ``init()`` because the fallback is otherwise unreachable in a test: the
    /// only way to drive it through the initialiser is a machine whose Application Support does
    /// not resolve, and the only way to check the resolved branch is to write into the
    /// developer's own. A pure function makes both assertable without a test ever creating a
    /// file where a real install keeps its history.
    static func defaultDirectory(applicationSupport: URL?, home: URL) -> URL {
        let base =
            applicationSupport ?? home.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Vocca")
    }

    // MARK: - The persisted shape

    /// The versioned top-level container — this file's own private Codable shape, written but
    /// never decoded as a whole: a load takes the top level apart with `JSONSerialization` so one
    /// bad row cannot cost the file.
    private struct PersistedFile: Encodable {
        let version: Int
        let bucketUpperBoundsMilliseconds: [Int]
        let days: [PersistedDay]
    }

    /// One day's row. `realWorkLatencyBuckets` is ``LatencyHistogram/bucketCounts`` verbatim —
    /// one count per bound plus the trailing overflow count — which is why the bounds have to
    /// travel with it.
    private struct PersistedDay: Codable {
        let day: String
        let realWork: PersistedCounts
        let onboarding: PersistedCounts
        let realWorkLatencyBuckets: [Int]
    }

    /// One column, the six outcome classes plus the rung tallies. The same shape twice — real
    /// work and onboarding — because ``DayAggregate`` holds the same shape twice, and a format
    /// that gave the two columns different fields would let them drift apart on disk.
    private struct PersistedCounts: Codable {
        let delivered: Int
        let failsafeHeld: Int
        let aborted: Int
        let failed: Int
        let lost: Int
        let emptySkip: Int
        /// Keyed by ``InjectionRung``'s raw values — a string-keyed object, so the file reads
        /// like the tally it is. Every rung is written, including the uncredited ones, so a
        /// hand-reader can see which rungs *did not* deliver rather than guessing whether an
        /// absent key means zero or means the build had no such rung.
        let deliveriesByRung: [String: Int]
    }

    // MARK: - Encoding

    /// Encode the window the way ``save(_:)`` writes it: strict `JSONEncoder` over the versioned
    /// wrapper with **sorted keys**, so the bytes are stable across calls and processes — a
    /// hand-editable file must not re-order itself between runs, and a diff of two saves must
    /// show what changed rather than how the dictionary hashed.
    ///
    /// In-memory windows are trusted: a save only ever writes a state the app itself folded. The
    /// values written are counts, bucket tallies and calendar days and nothing else — no
    /// transcript, no wall-clock time, no audio (`prd.md` M6). That promise is a property of this
    /// function's output, and the next slice asserts it on the bytes rather than on this comment.
    public static func encode(_ window: UsageWindow) throws -> Data {
        let file = PersistedFile(
            version: formatVersion,
            bucketUpperBoundsMilliseconds: LatencyHistogram.bucketUpperBoundsMilliseconds,
            days: window.days.map(persistedDay))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    /// One aggregate as its row.
    private static func persistedDay(_ aggregate: DayAggregate) -> PersistedDay {
        PersistedDay(
            day: spelled(aggregate.day),
            realWork: persistedCounts(aggregate.realWork),
            onboarding: persistedCounts(aggregate.onboarding),
            realWorkLatencyBuckets: aggregate.realWorkLatency.bucketCounts)
    }

    /// One column as its object.
    private static func persistedCounts(_ counts: DayAggregate.OutcomeCounts) -> PersistedCounts {
        var byRung: [String: Int] = [:]
        for rung in InjectionRung.allCases {
            byRung[rung.rawValue] = counts.deliveries(via: rung)
        }
        return PersistedCounts(
            delivered: counts.delivered, failsafeHeld: counts.failsafeHeld,
            aborted: counts.aborted, failed: counts.failed, lost: counts.lost,
            emptySkip: counts.emptySkip, deliveriesByRung: byRung)
    }

    /// A day as `YYYY-MM-DD` — the spelling ``day(from:)`` parses back, zero-padded so the rows
    /// sort in calendar order as text as well as as dates.
    ///
    /// The format spells the four-digit years, which is every year a usage ledger can be handed:
    /// days arrive from an adapter resolving the system clock, not from arithmetic.
    /// ``CalendarDay`` will hold a negative year, that year has no spelling here, and the strict
    /// parser refuses the result rather than repairing it — a refused row, like every other
    /// unreadable one.
    private static func spelled(_ day: CalendarDay) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    // MARK: - Decoding

    /// Decode the file the way ``load()`` reads it: `JSONSerialization` for the top level, then
    /// **one `JSONDecoder` per day row**.
    ///
    /// The per-row decode is the whole point of not handing the file to a single decoder: a
    /// user's thirty days of history must not be lost because one row was hand-edited into
    /// nonsense. A row that cannot be read — bad JSON, a missing field, an impossible date, a
    /// negative count, a bucket array of the wrong length, or a rung this build does not have —
    /// is **skipped** with one `onInvalidRow` call, and the readable remainder loads.
    ///
    /// Above the rows, three gates refuse the whole file with one `onInvalidRow` call each and no
    /// partial belief:
    ///
    /// - **A top level that is not a JSON object.** Not this format, and nothing in it can be
    ///   placed.
    /// - **A `version` that is not ``formatVersion``.** A version-2 file a later build wrote is
    ///   loaded empty rather than guessed at; a guess about a format this build has never seen is
    ///   a silent misreading of a user's history. A version-less file is the same case.
    /// - **`bucketUpperBoundsMilliseconds` that are not this build's.** This is the
    ///   reinterpretation trap the bounds are in the file to catch: bucket counts mean nothing
    ///   without the bounds that produced them, so a table that differs — in its numbers or its
    ///   length — makes every retained latency a different latency. The file is not repaired and
    ///   not partially trusted, because the counts are not wrong, they are *about something
    ///   else*.
    ///
    /// Never throws, and a load never writes: a file this build cannot interpret is not a file
    /// this build may overwrite.
    public static func decode(
        _ data: Data,
        onInvalidRow: @escaping @Sendable (String) -> Void
    ) -> UsageWindow {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let file = object as? [String: Any]
        else {
            onInvalidRow(
                "usage-ledger: the file's top level is not a JSON object; loading an empty history")
            return UsageWindow()
        }
        guard let version = file["version"] as? Int, version == formatVersion else {
            onInvalidRow("usage-ledger: unknown usage.json version; loading an empty history")
            return UsageWindow()
        }
        guard let bounds = file["bucketUpperBoundsMilliseconds"] as? [Int],
            bounds == LatencyHistogram.bucketUpperBoundsMilliseconds
        else {
            onInvalidRow(
                "usage-ledger: usage.json's latency bucket bounds are not this build's; "
                    + "loading an empty history rather than re-reading its buckets as different "
                    + "latencies")
            return UsageWindow()
        }
        guard let rows = file["days"] as? [Any] else {
            onInvalidRow("usage-ledger: usage.json holds no days list; loading an empty history")
            return UsageWindow()
        }

        var window = UsageWindow()
        for (index, row) in rows.enumerated() {
            guard JSONSerialization.isValidJSONObject(row),
                let rowData = try? JSONSerialization.data(withJSONObject: row),
                let persisted = try? JSONDecoder().decode(PersistedDay.self, from: rowData),
                let aggregate = aggregate(from: persisted)
            else {
                onInvalidRow("usage-ledger: skipping unreadable day row at index \(index)")
                continue
            }
            window.insert(aggregate)
        }
        return window
    }

    /// One decoded row as a ``DayAggregate``, or `nil` if the row is not one.
    ///
    /// Every `nil` here is a refusal the vocabulary itself made — the date, the counts and the
    /// buckets each gate their own values — so the store adds no repair of its own and no
    /// judgement of its own about what a plausible day looks like.
    private static func aggregate(from row: PersistedDay) -> DayAggregate? {
        guard let day = day(from: row.day),
            let realWork = counts(from: row.realWork),
            let onboarding = counts(from: row.onboarding),
            let latency = LatencyHistogram(bucketCounts: row.realWorkLatencyBuckets)
        else {
            return nil
        }
        return DayAggregate(
            day: day, realWork: realWork, onboarding: onboarding, realWorkLatency: latency)
    }

    /// One decoded column, or `nil` if a count is negative or a rung key is not one this build
    /// knows.
    ///
    /// An unknown rung is a **skipped row, not a dropped key**: the raw values are the persisted
    /// spelling, so a key this build cannot place means the file was written by a build whose
    /// ladder differs from this one's, and silently discarding its tallies would report a day's
    /// deliveries as fewer than they were.
    private static func counts(from column: PersistedCounts) -> DayAggregate.OutcomeCounts? {
        var byRung: [InjectionRung: Int] = [:]
        for (key, count) in column.deliveriesByRung {
            guard let rung = InjectionRung(rawValue: key) else { return nil }
            byRung[rung] = count
        }
        return DayAggregate.OutcomeCounts(
            delivered: column.delivered, failsafeHeld: column.failsafeHeld,
            aborted: column.aborted, failed: column.failed, lost: column.lost,
            emptySkip: column.emptySkip, deliveriesByRung: byRung)
    }

    /// `YYYY-MM-DD` back to a day, strictly: exactly four digits, two, two, hyphen-separated.
    ///
    /// The strictness is what makes ``CalendarDay/init(year:month:day:)`` the gate the spec says
    /// it is. A lenient parse would accept `2026-9-31`, hand `31` to a month that has thirty
    /// days, and — because the initialiser refuses it — skip the row anyway; but it would also
    /// accept `2026-09-06T14:32:11`, which is a wall-clock time in a file that must never hold
    /// one. Refusing everything that is not exactly the spelling keeps that door shut.
    private static func day(from text: String) -> CalendarDay? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
            let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2])
        else {
            return nil
        }
        return CalendarDay(year: year, month: month, day: dayOfMonth)
    }

    // MARK: - Load and save

    /// The window on disk, or the empty window. Never throws and never writes: a missing file is
    /// the empty window silently — a first run is not an error — and an unreadable one is the
    /// empty window too. Retention is re-applied on the way in by ``UsageWindow/insert(_:)``, so
    /// a hand-edited file holding more than the retained days loads bounded.
    public func load() async -> UsageWindow {
        let url = fileURL
        guard await fileSystem.fileExists(atPath: url.path) else { return UsageWindow() }
        guard let data = await fileSystem.read(url) else { return UsageWindow() }
        return Self.decode(data, onInvalidRow: log)
    }

    /// Replace the persisted window atomically: create the directory, encode, temp-write
    /// `<dir>/usage.json.tmp`, rename it over `<dir>/usage.json`.
    ///
    /// The pair is the durability claim. The bytes become visible at the rename or not at all, so
    /// a crash mid-write leaves the previously committed file intact rather than a half-written
    /// ledger — and the stray `.tmp` it leaves behind is never read, because only `usage.json` is
    /// ever loaded. Throws on any failure: the caller must be able to see that the window it
    /// holds is not the window on disk.
    public func save(_ window: UsageWindow) async throws {
        try await fileSystem.createDirectory(at: directory)
        let data = try Self.encode(window)
        let tempURL = directory.appendingPathComponent(Self.fileName + Self.tempSuffix)
        try await fileSystem.write(data, to: tempURL)
        try await fileSystem.moveItem(at: tempURL, to: fileURL)
    }

    /// Delete `usage.json`, so that the next ``load()`` answers the empty window.
    ///
    /// **Deletion, not a save of nothing.** The user is told the file goes (`PRODUCT_SPEC.md:306`,
    /// and `UsageTabCopy.clearExplanation` in the same words), and this is the page where the
    /// product's claims are supposed to be checkable — an empty file left where the copy says
    /// there is none would be a small lie told on the privacy screen.
    ///
    /// Asked-then-removed rather than removed-and-ignore-the-error: `FileManager.removeItem`
    /// fails for a missing file and for a file that cannot be deleted, and swallowing both would
    /// make a permission failure look exactly like a first run. A missing file returns quietly; a
    /// removal that fails throws, and the caller says so.
    ///
    /// The stray `<dir>/usage.json.tmp` a torn save can leave is deliberately not touched: it is
    /// never read (`C8`), and a `clear()` that reached for a second file would be reaching past
    /// the one name this store owns.
    public func clear() async throws {
        let url = fileURL
        guard await fileSystem.fileExists(atPath: url.path) else { return }
        try await fileSystem.removeItem(at: url)
    }
}
