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
@testable import VoccaContext
import XCTest

/// The consent store — the `consent-store` aspect's Phase 1 contract
/// (`plan_20260918.md`), written before the store exists. Failing to compile is the red state:
/// no `PersistentConsentStore` is in scope yet.
///
/// Like the strategy and usage stores, `FileManager` works on a hosted runner, so the real
/// ``PersistentConsentStore`` runs here against real temp directories: corrupt files are
/// skipped loudly and never rewritten, saves are the atomic temp-write→rename pair, and a
/// missing file loads empty silently. The injected ``ConsentFileSystem`` seam is exercised
/// through three doubles in this file — a recording actor (the atomic-pair protocol), a
/// failing rename (the torn half), and a refusing create-directory (the refused-write
/// contract) — mirroring the strategy store's.
///
/// The load-bearing half is the byte-level pin (M10, `prd.md:119-121`): the consent file is
/// the auditable artifact — a user opens `context-consent.json` and sees exactly bundle IDs.
/// No transcript text, no selection text and no wall-clock timestamp may ever reach it.
final class PersistentConsentStoreTests: XCTestCase {

    // MARK: - The missing file

    /// A store over an absent directory loads an empty consent — no error, no log: the missing
    /// file is the first-run state, not a failure.
    func testMissingFileLoadsEmptySilently() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = LogCollector()
        let store = PersistentConsentStore(directory: directory, log: { logs.append($0) })

        let loaded = await store.load()

        XCTAssertEqual(loaded, [], "an absent file is an empty consent, not an error")
        XCTAssertTrue(logs.entries.isEmpty, "a missing file must load silently")
    }

    // MARK: - Whole-file corruption

    /// A file whose top level is not an object at all loads empty with exactly one loud log —
    /// and the file on disk is byte-identical afterwards.
    func testWholeFileThatIsNotAnObjectLoadsEmptyWithOneLoudLog() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = #"["com.example.app"]"#
        try json.write(
            to: directory.appendingPathComponent("context-consent.json"), atomically: true,
            encoding: .utf8)
        let logs = LogCollector()
        let store = PersistentConsentStore(directory: directory, log: { logs.append($0) })

        let loaded = await store.load()

        XCTAssertEqual(loaded, [], "a non-object top level is an empty consent, not a throw")
        XCTAssertEqual(logs.entries.count, 1, "a non-object top level is exactly one loud refusal")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("context-consent.json")),
            Data(json.utf8),
            "a failed parse must never rewrite the user's file")
    }

    /// A file a future version wrote — `"version": 2` — and a version-less object both load
    /// empty with exactly one loud log each, bytes unchanged: version-tolerant, never mis-read.
    func testUnknownVersionLoadsEmptyWithOneLoudLog() async throws {
        for json in [
            #"{"version": 2, "consent": ["com.example.app"]}"#,
            #"{"consent": ["com.example.app"]}"#,
        ] {
            let directory = Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try json.write(
                to: directory.appendingPathComponent("context-consent.json"), atomically: true,
                encoding: .utf8)
            let logs = LogCollector()
            let store = PersistentConsentStore(directory: directory, log: { logs.append($0) })

            let loaded = await store.load()

            XCTAssertEqual(
                loaded, [],
                "an unknown or missing version must load empty — never be mis-read")
            XCTAssertEqual(
                logs.entries.count, 1,
                "an unknown or missing version is exactly one loud refusal")
            XCTAssertEqual(
                try? Data(contentsOf: directory.appendingPathComponent("context-consent.json")),
                Data(json.utf8),
                "a version rejection must never rewrite the user's file")
        }
    }

    /// A `consent` field that is missing — or present but not a list — loads empty with exactly
    /// one loud log each, bytes unchanged.
    func testANonListConsentFieldLoadsEmptyWithOneLoudLog() async throws {
        for json in [
            #"{"version": 1}"#,
            #"{"version": 1, "consent": "com.example.app"}"#,
        ] {
            let directory = Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try json.write(
                to: directory.appendingPathComponent("context-consent.json"), atomically: true,
                encoding: .utf8)
            let logs = LogCollector()
            let store = PersistentConsentStore(directory: directory, log: { logs.append($0) })

            let loaded = await store.load()

            XCTAssertEqual(loaded, [], "no consent list is an empty consent, never mis-read")
            XCTAssertEqual(logs.entries.count, 1, "a missing or non-list consent field is one loud refusal")
            XCTAssertEqual(
                try? Data(contentsOf: directory.appendingPathComponent("context-consent.json")),
                Data(json.utf8),
                "a malformed consent field must never rewrite the user's file")
        }
    }

    // MARK: - Tolerant per-entry decode

    /// A hand-edited file mixing valid bundle IDs with a content-shaped string and a
    /// time-shaped string loads the valid remainder — each invalid entry skipped with exactly
    /// one loud log, the file left exactly as written.
    func testContentShapedAndTimeShapedEntriesAreSkippedLoudlyAndTheValidRemainderLoads() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
            {
              "version": 1,
              "consent": ["com.example.app", "meeting at noon with Alice", "14:32:05", "com.apple.Notes"]
            }
            """
        try json.write(
            to: directory.appendingPathComponent("context-consent.json"), atomically: true,
            encoding: .utf8)
        let logs = LogCollector()
        let store = PersistentConsentStore(directory: directory, log: { logs.append($0) })

        let loaded = await store.load()

        XCTAssertEqual(
            loaded, ["com.example.app", "com.apple.Notes"],
            "the valid entries must load; each invalid one must be skipped")
        XCTAssertEqual(logs.entries.count, 2, "exactly one loud log per skipped entry")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("context-consent.json")),
            Data(json.utf8),
            "a tolerant load must never rewrite the user's file")
    }

    // MARK: - Write-side validation

    /// An invalid bundle ID is refused on the way in: `set` returns `false`, persists nothing,
    /// and logs once — the reverse-DNS boundary rows from the seam pins, plus the
    /// content-shaped string that must never reach the file.
    func testAnInvalidSetIsRefusedAndPersistsNothing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingConsentFileSystem(directory: directory)
        let logs = LogCollector()
        let store = PersistentConsentStore(
            directory: directory, fileSystem: fileSystem, log: { logs.append($0) })

        for invalid in ["meeting at noon with Alice", "", "  ", "nodot",
            String(repeating: "a", count: 256)] {
            let accepted = try await store.set(invalid, consented: true)
            XCTAssertFalse(
                accepted,
                "\(invalid.debugDescription) is not a bundle ID and must be refused, not persisted")
        }

        XCTAssertEqual(
            logs.entries.count, 5,
            "each refused set is exactly one loud log, got: \(logs.entries)")
        let events = await fileSystem.events
        XCTAssertTrue(
            events.isEmpty,
            "a refused set must never reach the file system, got: \(events)")
        let loaded = await store.load()
        XCTAssertEqual(loaded, [], "nothing invalid may be held")
    }

    // MARK: - The atomic pair

    /// The protocol half: `set` is recorded as exactly the atomic pair — temp written, then
    /// renamed over the committed name. The real file holds the encoded consent, and no `.tmp`
    /// remains.
    func testSetIsAnAtomicTempWriteThenRenamePair() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingConsentFileSystem(directory: directory)
        let store = PersistentConsentStore(directory: directory, fileSystem: fileSystem)

        let accepted = try await store.set("com.example.app", consented: true)

        XCTAssertTrue(accepted, "a valid new bundle under the cap is accepted")
        let events = await fileSystem.events
        XCTAssertEqual(
            events,
            [.tempWrite("context-consent.json.tmp"), .rename("context-consent.json")],
            "a durable set is exactly two events: temp written, then renamed into place")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("context-consent.json")),
            try PersistentConsentStore.encode(["com.example.app"]),
            "the committed file must hold the encoded consent")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("context-consent.json.tmp").path),
            "no .tmp may remain after a completed set")
    }

    /// The wholesale path is the same atomic pair — and `.sortedKeys` plus a sorted array make
    /// it byte-stable: save → read bytes → save again → identical bytes.
    func testSaveIsAnAtomicTempWriteThenRenamePairAndByteStable() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingConsentFileSystem(directory: directory)
        let store = PersistentConsentStore(directory: directory, fileSystem: fileSystem)
        let ids: Set<String> = ["com.example.app", "com.apple.Notes"]

        try await store.save(ids)
        let firstBytes = try Data(
            contentsOf: directory.appendingPathComponent("context-consent.json"))

        let events = await fileSystem.events
        XCTAssertEqual(
            events,
            [.tempWrite("context-consent.json.tmp"), .rename("context-consent.json")],
            "a durable save is exactly two events: temp written, then renamed into place")
        XCTAssertEqual(
            firstBytes, try PersistentConsentStore.encode(ids),
            "the committed file must hold the encoded consent")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("context-consent.json.tmp").path),
            "no .tmp may remain after a completed save")

        try await store.save(ids)
        let secondBytes = try Data(
            contentsOf: directory.appendingPathComponent("context-consent.json"))
        XCTAssertEqual(
            firstBytes, secondBytes,
            "a save of the same set must produce byte-identical file — sorted keys, not chaos")
    }

    // MARK: - The torn update

    /// The torn half: a rename that throws after the temp write lands leaves the committed file
    /// at its previous bytes — never partial — and the leftover `.tmp` is never readable as
    /// consent: a fresh store over the real directory loads the previous consent.
    func testAFailedSetAfterTheTempWriteLeavesThePreviousCommittedContent() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await PersistentConsentStore(directory: directory)
            .set("com.example.app", consented: true)
        let committedBefore = try Data(
            contentsOf: directory.appendingPathComponent("context-consent.json"))

        let torn = PersistentConsentStore(
            directory: directory, fileSystem: FailingRenameConsentFileSystem())
        do {
            _ = try await torn.set("com.example.second", consented: true)
            XCTFail("a rename that throws must surface as a failed set")
        } catch {
            // Expected — the torn update is the point of the test.
        }

        let committedAfter = try Data(
            contentsOf: directory.appendingPathComponent("context-consent.json"))
        XCTAssertEqual(
            committedAfter, committedBefore,
            "the committed file must be the previous content, never partial")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("context-consent.json.tmp").path),
            "the torn temp must remain on disk — that is what a crash between the pair leaves")

        let fresh = PersistentConsentStore(directory: directory)
        let reloaded = await fresh.load()
        XCTAssertEqual(
            reloaded, ["com.example.app"],
            "the leftover .tmp must never be readable as consent; the committed set is what loads")
    }

    // MARK: - The refused write

    /// The refused-write contract: a directory that cannot be created makes `set` throw — the
    /// consent is not durable, and the caller must know.
    func testSetThrowsWhenTheDirectoryCannotBeCreated() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentConsentStore(
            directory: directory,
            fileSystem: RefusingCreateDirectoryConsentFileSystem())

        do {
            _ = try await store.set("com.example.app", consented: true)
            XCTFail("set must throw when the directory cannot be created")
        } catch {
            // Expected — the throw is the contract.
        }
    }

    // MARK: - The stray temp

    /// A stray `context-consent.json.tmp` from a crash is never read: planted beside the
    /// committed file, load returns the committed consent only — the temp path is
    /// `<dir>/context-consent.json.tmp`, and it is never loaded.
    func testAStrayTempFileFromACrashIsNeverRead() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
_ = try await PersistentConsentStore(directory: directory)
            .set("com.example.app", consented: true)
        try "torn write, never renamed".write(
            to: directory.appendingPathComponent("context-consent.json.tmp"), atomically: true,
            encoding: .utf8)

        let store = PersistentConsentStore(directory: directory)
        let loaded = await store.load()

        XCTAssertEqual(
            loaded, ["com.example.app"],
            "the committed content is what loads; a stray .tmp must never be read as consent")
    }

    // MARK: - Round trip through the real store

    /// Two apps consented through the real store, a fresh store over the same directory: both
    /// load — and a revoked consent (`consented: false`) is gone on the next load.
    func testRoundTripThroughTheRealStore() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentConsentStore(directory: directory)

        _ = try await store.set("com.example.app", consented: true)
        _ = try await store.set("com.apple.Notes", consented: true)

        let fresh = PersistentConsentStore(directory: directory)
        let loaded = await fresh.load()
        XCTAssertEqual(
            loaded, ["com.example.app", "com.apple.Notes"],
            "both consents must survive save and reload")

        _ = try await store.set("com.apple.Notes", consented: false)
        let afterRevoke = await PersistentConsentStore(directory: directory).load()
        XCTAssertEqual(
            afterRevoke, ["com.example.app"],
            "a revoked consent is gone from the file on the next load")
    }

    // MARK: - The cap refuses, never evicts

    /// The store at capacity 2: two new apps accepted; a third **new** app → `false` and the
    /// file untouched; an update of a known app always succeeds. Refusal, never eviction.
    func testCapRefusalForANewAppAndKnownAppsKeepFlowing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentConsentStore(directory: directory, capacity: 2)
        _ = try await store.set("com.example.app", consented: true)
        _ = try await store.set("com.apple.Notes", consented: true)
        let before = try Data(
            contentsOf: directory.appendingPathComponent("context-consent.json"))

        let refused = try await store.set("com.example.third", consented: true)
        let knownAgain = try await store.set("com.example.app", consented: true)

        XCTAssertFalse(refused, "a third new app at capacity is refused, not evicted")
        XCTAssertTrue(knownAgain, "an update of a known app always succeeds")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("context-consent.json")),
            before,
            "a refused set must not touch the file")
        let held = await store.load()
        XCTAssertEqual(
            held, ["com.example.app", "com.apple.Notes"],
            "a refused app is not held")
    }

    /// The plan's cap row, at the real bound: fill the store to
    /// ``ConsentStoreConstants.maximumConsentedApps``, then a new bundle → `false` and nothing
    /// persisted.
    func testFillingTheStoreToTheCapRefusesANewAppAndPersistsNothing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingConsentFileSystem(directory: directory)
        let store = PersistentConsentStore(directory: directory, fileSystem: fileSystem)

        for index in 0..<ConsentStoreConstants.maximumConsentedApps {
            let accepted = try await store.set("com.example.app.\(index)", consented: true)
            XCTAssertTrue(accepted, "entry \(index) fits under the cap")
        }
        let before = try Data(
            contentsOf: directory.appendingPathComponent("context-consent.json"))

        let refused = try await store.set("com.example.refused513", consented: true)

        XCTAssertFalse(refused, "the \(ConsentStoreConstants.maximumConsentedApps + 1)th new app is refused")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("context-consent.json")),
            before,
            "a refused set must not touch the file — refusal at saturation is a decision, not a write")
        let held = await store.load()
        XCTAssertEqual(
            held.count, ConsentStoreConstants.maximumConsentedApps,
            "the refused app must not be held")
        XCTAssertFalse(
            held.contains("com.example.refused513"),
            "the refused bundle ID must not appear anywhere in the held consent")
    }

    /// `save` is the deliberate wholesale write: three bundles into an at-capacity-2 store
    /// succeed and load — the future Apps-tab editing path is not subject to the cap.
    func testSaveReplacesTheWholeSetAndBypassesTheCap() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentConsentStore(directory: directory, capacity: 2)
        _ = try await store.set("com.example.app", consented: true)
        _ = try await store.set("com.apple.Notes", consented: true)
        let three: Set<String> = ["com.example.app", "com.apple.Notes", "com.example.third"]

        try await store.save(three)

        let held = await store.load()
        XCTAssertEqual(held, three, "a deliberate save replaces the whole set, cap or not")
    }

    // MARK: - The byte-level pin

    /// **The aspect's central promise, asserted on the artifact.** A genuine consented set that
    /// includes digit-bearing bundle IDs encodes to bytes holding neither a phrase, nor a time
    /// of day, nor a timestamp of any shape — and the decoded object's keys are exactly
    /// `{version, consent}`, every entry a valid bundle ID.
    ///
    /// `context-consent.json` is the file a privacy-focused user opens to check what Vocca
    /// keeps about their consent (`prd.md` M10: "no transcript text, no selection text, no
    /// wall-clock timestamps reach the file"). A transcript fragment would be the obvious
    /// breach; a wall-clock time is the quiet one, because a `grantedAt` would reconstruct when
    /// a user granted what — a consent ledger is not a usage trace.
    ///
    /// **What each half is worth, stated plainly.** The key-set pin is the strong half: the
    /// decoded object may hold exactly `version` and `consent`, so a future `grantedAt` field,
    /// a display-name field or a selection-text field fails this on the day it is added — and
    /// the vocabulary check guarantees every entry is bundle-ID-shaped, which is the privacy
    /// claim in type form. The time regexes are the defense-in-depth half: they have teeth
    /// against the format as it stands, and they are kept because they fail loudly the day a
    /// row is widened to carry a name. The phrase assertion is, today, guaranteed by the
    /// vocabulary rather than by the format — written on the bytes anyway, and kept, for the
    /// same reason the usage pin keeps its phrase.
    func testTheEncodedBytesCarryNoContentAndNoWallClockTime() throws {
        let ids: Set<String> = ["com.example.app123", "com.apple.Notes", "dev.vocca.Vocca2"]
        XCTAssertFalse(
            ids.isEmpty,
            "vacuity guard: the pin must run against a non-empty consented set")
        XCTAssertTrue(
            ids.allSatisfy { ConsentBundleID.isValid($0) },
            "vacuity guard: every entry must validate — the pin must run against a genuine consent")

        let data = try PersistentConsentStore.encode(ids)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertNil(
            data.range(of: Data(Self.distinctivePhrase.utf8)),
            "context-consent.json must not carry a phrase. This is the file a privacy-focused "
                + "user opens to check what Vocca keeps about their consent; text of any "
                + "provenance in it breaks the promise that transcripts and selections never "
                + "reach it. Bytes: \(text)")
        XCTAssertNil(
            text.range(of: "[0-9]:[0-9]", options: .regularExpression),
            "context-consent.json must hold no time of day. A colon between two digits is the "
                + "HH:MM shape; a consent file that records when a user granted is a trace, not "
                + "a ledger. Bytes: \(text)")
        for (name, pattern) in [
            ("an ISO-8601 date-time marker", "[0-9]{4}-[0-9]{2}-[0-9]{2}T"),
            ("a Zulu suffix", "[0-9]Z"),
            ("an epoch-looking integer", "[0-9]{10}"),
        ] {
            XCTAssertNil(
                text.range(of: pattern, options: .regularExpression),
                "context-consent.json must hold no timestamp: found \(name). A consent ledger "
                    + "is not a usage trace — anything finer than a bundle ID reconstructs when "
                    + "a user granted what. Bytes: \(text)")
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("the encoded bytes must decode as a JSON object")
        }
        XCTAssertEqual(
            Set(object.keys), ["version", "consent"],
            "the file's keys must be exactly version and consent — a future grantedAt field, a "
                + "display-name field or a selection-text field fails this on the day it is added")
        let entries = object["consent"] as? [String] ?? []
        XCTAssertTrue(
            entries.allSatisfy { ConsentBundleID.isValid($0) },
            "every persisted entry must be bundle-ID-shaped — the vocabulary is the privacy claim")
    }

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-consent-\(UUID().uuidString)")
    }

    /// The content-shaped string the store refused and the pin must never see in the bytes.
    private static let distinctivePhrase = "meeting at noon with Alice"
}

/// What the consent store's file-system seam records, in order — the **atomic-pair protocol**
/// the durability claim is carried by (the strategy store's `InjectionStrategyFileSystemEvent`
/// shape).
enum ConsentFileSystemEvent: Equatable {
    /// The temp file was written — not yet readable, not yet committed.
    case tempWrite(String)
    /// The temp file was renamed over the entry name — the commit point.
    case rename(String)
}

/// An in-memory ``ConsentFileSystem`` whose every save is recorded as the atomic
/// temp-write/rename pair, against a real temp directory — the atomic-pair protocol half. The
/// commit is `replaceItemAt`, mirroring the shipped adapter (whose overwrite-succeeds commit
/// is the point of the pair), so a second save over the same file records the same two events.
actor RecordingConsentFileSystem: ConsentFileSystem {
    private(set) var events: [ConsentFileSystemEvent] = []
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

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

    func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// The torn half of the atomic pair: the temp write lands on disk, the rename throws.
struct FailingRenameConsentFileSystem: ConsentFileSystem {
    func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        throw ConsentStoreTestError.renameFailed
    }

    func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// The refused-write contract: the directory cannot be created, so `set` must throw.
struct RefusingCreateDirectoryConsentFileSystem: ConsentFileSystem {
    func createDirectory(at url: URL) async throws {
        throw ConsentStoreTestError.directoryRefused
    }

    func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// What a consent-store failure is, for the throw tests — the specific error is the file
/// system's business; the contract is that `set` surfaces it.
enum ConsentStoreTestError: Error {
    /// The rename between the pair failed.
    case renameFailed
    /// The directory could not be created.
    case directoryRefused
}