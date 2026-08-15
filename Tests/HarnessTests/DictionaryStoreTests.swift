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
import VoccaText
import XCTest

/// The user dictionary's store — the `user-dictionary` aspect's B5, B6 and B8, written before
/// the store exists (`plan_20260815.md` Phase 1). Failing to compile is the red state: no
/// `FileSystemDictionaryStore` is in scope yet.
///
/// Unlike the adapters CI cannot reach, `FileManager` works on a hosted runner, so the real
/// ``FileSystemDictionaryStore`` runs here against real temp directories (`spec.md:67-69`):
/// corrupt files are skipped loudly, saves are the atomic temp-write→rename pair, and a missing
/// file is an empty dictionary. The injected ``DictionaryFileSystem`` seam is exercised through
/// three doubles in this file: a recording actor (the B6 pair), a failing rename (the torn half
/// of B6), and a refusing create-directory (the refused-write contract).
final class DictionaryStoreTests: XCTestCase {

    // MARK: - B8 · the missing file

    /// A store over an absent directory loads `[]` — no error, no log: the missing file is the
    /// empty dictionary, not a failure (`spec.md:70`).
    func testMissingFileIsAnEmptyDictionary() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = LogCollector()
        let store = FileSystemDictionaryStore(directory: directory, log: { logs.append($0) })

        let loaded = await store.load()

        XCTAssertEqual(loaded, [], "an absent file is an empty dictionary, not an error")
        XCTAssertTrue(logs.entries.isEmpty, "a missing file must load silently")
    }

    // MARK: - B5 · corrupt entries

    /// A mixed file — one valid rule (deliberately carrying an unknown key), a wrong-typed
    /// element, a missing-field element and a non-object fragment — loads the valid one, emits
    /// exactly one loud log per skipped element, and does not throw.
    func testCorruptEntriesAreSkippedLoudlyAndNeverFatal() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
            [
              {"source": "mcp", "replacement": "MCP", "caseSensitive": false, "wordBoundary": true, "legacy": "kept on read, dropped on save"},
              {"source": 42, "replacement": "x", "caseSensitive": false, "wordBoundary": true},
              {"replacement": "missing source"},
              "not an object"
            ]
            """
        try json.write(
            to: directory.appendingPathComponent("dictionary.json"), atomically: true,
            encoding: .utf8)
        let logs = LogCollector()
        let store = FileSystemDictionaryStore(directory: directory, log: { logs.append($0) })

        let loaded = await store.load()

        XCTAssertEqual(
            loaded,
            [ReplacementRule(
                source: "mcp", replacement: "MCP", caseSensitive: false, wordBoundary: true)],
            "the valid element must load; each corrupt one must be skipped")
        XCTAssertEqual(logs.entries.count, 3, "exactly one loud log per skipped element")
    }

    /// A file whose top level is not an array at all loads empty with exactly one loud log —
    /// and the file on disk is byte-identical afterwards: a failed parse never rewrites the
    /// user's edit surface (`spec.md:70-75`).
    func testWholeFileThatIsNotAnArrayLoadsEmptyWithOneLoudLog() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = #"{"not": "an array"}"#
        try json.write(
            to: directory.appendingPathComponent("dictionary.json"), atomically: true,
            encoding: .utf8)
        let logs = LogCollector()
        let store = FileSystemDictionaryStore(directory: directory, log: { logs.append($0) })

        let loaded = await store.load()

        XCTAssertEqual(loaded, [], "a non-array top level is an empty dictionary, not a throw")
        XCTAssertEqual(logs.entries.count, 1, "a non-array top level is exactly one loud refusal")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("dictionary.json")),
            Data(json.utf8),
            "a failed parse must never rewrite the user's file")
    }

    // MARK: - B6 · atomic save

    /// The protocol half: the save is recorded as exactly the atomic pair — temp written, then
    /// renamed over the committed name (the journal's recorded pair,
    /// `RecoveryJournalTests.testSaveIsAnAtomicTempWriteThenRenamePair`). The real file holds
    /// the encoded rules, and no `.tmp` remains.
    func testSaveIsAnAtomicTempWriteThenRenamePair() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingDictionaryFileSystem(directory: directory)
        let store = FileSystemDictionaryStore(directory: directory, fileSystem: fileSystem)
        let rules = [
            ReplacementRule(
                source: "mcp", replacement: "MCP", caseSensitive: false, wordBoundary: true),
        ]

        try await store.save(rules)

        let events = await fileSystem.events
        XCTAssertEqual(
            events,
            [.tempWrite("dictionary.json.tmp"), .rename("dictionary.json")],
            "a durable save is exactly two events: temp written, then renamed into place")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("dictionary.json")),
            try FileSystemDictionaryStore.encode(rules),
            "the committed file must hold the encoded rules")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("dictionary.json.tmp").path),
            "no .tmp may remain after a completed save")
    }

    /// The torn half: a rename that throws after the temp write lands leaves the committed file
    /// at v1's bytes — never partial — and the leftover `.tmp` is never readable as a
    /// dictionary: a fresh store over the real directory loads v1.
    func testAFailedSaveAfterTheTempWriteLeavesThePreviousCommittedContent() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let v1 = [
            ReplacementRule(
                source: "gonna", replacement: "going to", caseSensitive: true, wordBoundary: true),
        ]
        try await FileSystemDictionaryStore(directory: directory).save(v1)
        let committedBefore = try Data(
            contentsOf: directory.appendingPathComponent("dictionary.json"))

        let v2 = [
            ReplacementRule(
                source: "mcp", replacement: "MCP", caseSensitive: false, wordBoundary: true),
        ]
        let torn = FileSystemDictionaryStore(
            directory: directory, fileSystem: FailingRenameFileSystem())
        do {
            try await torn.save(v2)
            XCTFail("a rename that throws must surface as a failed save")
        } catch {
            // Expected — the torn save is the point of the test.
        }

        let committedAfter = try Data(
            contentsOf: directory.appendingPathComponent("dictionary.json"))
        XCTAssertEqual(
            committedAfter, committedBefore,
            "the committed file must be the previous content, never partial")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("dictionary.json.tmp").path),
            "the torn temp must remain on disk — that is what a crash between the pair leaves")

        let fresh = FileSystemDictionaryStore(directory: directory)
        let reloaded = await fresh.load()
        XCTAssertEqual(
            reloaded, v1,
            "the leftover .tmp must never be readable as a dictionary; the committed v1 is what loads")
    }

    /// A stray `.tmp` from a crash is never read: planted beside the committed file (the
    /// `RecoveryJournalTests.testACorruptEntryIsSkippedWithoutLosingTheRest` planted-hazard
    /// shape), load returns the committed content only.
    func testAStrayTempFileFromACrashIsNeverRead() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "torn write, never renamed".write(
            to: directory.appendingPathComponent("dictionary.json.tmp"), atomically: true,
            encoding: .utf8)
        let rules = [
            ReplacementRule(
                source: "mcp", replacement: "MCP", caseSensitive: false, wordBoundary: true),
            ReplacementRule(
                source: "gonna", replacement: "going to", caseSensitive: true, wordBoundary: false),
        ]
        try await FileSystemDictionaryStore(directory: directory).save(rules)

        let store = FileSystemDictionaryStore(directory: directory)
        let loaded = await store.load()

        XCTAssertEqual(
            loaded, rules,
            "the committed content is what loads; a stray .tmp must never be read as a dictionary")
    }

    // MARK: - Round-trip and edge cases

    /// Save never reads the prior file: load, delete the file, save — the save succeeds and the
    /// fresh file decodes (create-directory, temp-write and rename are independent of prior
    /// existence).
    func testSaveRecreatesTheFileIfItWasDeletedBetweenLoadAndSave() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSystemDictionaryStore(directory: directory)
        let v1 = [
            ReplacementRule(
                source: "mcp", replacement: "MCP", caseSensitive: false, wordBoundary: true),
        ]
        try await store.save(v1)
        _ = await store.load()

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("dictionary.json"))

        let v2 = [
            ReplacementRule(
                source: "gonna", replacement: "going to", caseSensitive: true, wordBoundary: true),
        ]
        try await store.save(v2)

        let fresh = FileSystemDictionaryStore(directory: directory)
        XCTAssertEqual(await fresh.load(), v2, "the recreated file must decode")
    }

    /// `save([])` writes `[]`; a fresh store over the same directory loads `[]`.
    func testEmptyDictionaryRoundTrips() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSystemDictionaryStore(directory: directory)

        try await store.save([])

        XCTAssertEqual(await store.load(), [])
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("dictionary.json")),
            Data("[]".utf8),
            "an empty dictionary is an empty array on disk")
    }

    /// The B4 claim over the file: three rules with mixed flags survive a save, a fresh store
    /// over the same directory, and a load, in exactly the declared order with both flags
    /// intact.
    func testOrderingSurvivesAReloadThroughTheRealStore() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rules = [
            ReplacementRule(
                source: "mcp", replacement: "MCP", caseSensitive: false, wordBoundary: true),
            ReplacementRule(
                source: "gonna", replacement: "going to", caseSensitive: true, wordBoundary: false),
            ReplacementRule(
                source: "café", replacement: "CAFÉ", caseSensitive: false, wordBoundary: false),
        ]
        try await FileSystemDictionaryStore(directory: directory).save(rules)

        let fresh = FileSystemDictionaryStore(directory: directory)
        let loaded = await fresh.load()

        XCTAssertEqual(loaded, rules, "declared order and both flags must survive a reload")
    }

    /// UTF-8, not escaped-ASCII: a "café"/"CAFÉ" rule round-trips through the real store, and
    /// the committed file carries the literal UTF-8 bytes.
    func testUnicodeRulesRoundTripThroughTheRealStore() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rule = ReplacementRule(
            source: "café", replacement: "CAFÉ", caseSensitive: false, wordBoundary: true)
        try await FileSystemDictionaryStore(directory: directory).save([rule])

        let fresh = FileSystemDictionaryStore(directory: directory)
        XCTAssertEqual(await fresh.load(), [rule], "a unicode rule must survive save/load whole")

        let data = try? Data(contentsOf: directory.appendingPathComponent("dictionary.json"))
        let text = data.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertTrue(
            text?.contains("café") == true,
            "the file must carry the literal UTF-8 source, not an escaped form")
    }

    /// The refused-write contract: a directory that cannot be created makes save throw — the
    /// rules are not durable, and the caller must know (the journal's refused-write contract,
    /// `RecoveryJournalTests.testHoldThrowsWhenTheStoreCannotWriteAndTheSlotStaysEmpty`).
    func testSaveThrowsWhenTheDirectoryCannotBeCreated() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSystemDictionaryStore(
            directory: directory, fileSystem: RefusingCreateDirectoryFileSystem())

        do {
            try await store.save([])
            XCTFail("save must throw when the directory cannot be created")
        } catch {
            // Expected — the throw is the contract.
        }
    }

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-dictionary-\(UUID().uuidString)")
    }
}

/// Collects the store's injected log lines in tests — `Sendable`-safe because its only mutable
/// state sits behind a `Mutex`, so the log closure can capture it in strict Swift 6.
final class LogCollector: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ message: String) {
        storage.withLock { $0.append(message) }
    }

    var entries: [String] {
        storage.withLock { $0 }
    }
}

/// What the dictionary's file-system seam records, in order — the **atomic-pair protocol** the
/// durability claim is carried by (the journal's `JournalStoreEvent` shape).
enum DictionaryFileSystemEvent: Equatable {
    /// The temp file was written — not yet readable, not yet committed.
    case tempWrite(String)
    /// The temp file was renamed over the entry name — the commit point.
    case rename(String)
}

/// An in-memory ``DictionaryFileSystem`` whose every save is recorded as the atomic
/// temp-write/rename pair, against a real temp directory — the B6 protocol half.
actor RecordingDictionaryFileSystem: DictionaryFileSystem {
    private(set) var events: [DictionaryFileSystemEvent] = []
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
        try FileManager.default.moveItem(at: source, to: destination)
        events.append(.rename(destination.lastPathComponent))
    }

    func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// The torn half of B6: the temp write lands on disk, the rename throws.
struct FailingRenameFileSystem: DictionaryFileSystem {
    func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        throw DictionaryTestError.renameFailed
    }

    func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// The refused-write contract: the directory cannot be created, so save must throw.
struct RefusingCreateDirectoryFileSystem: DictionaryFileSystem {
    func createDirectory(at url: URL) async throws {
        throw DictionaryTestError.directoryRefused
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

/// What a dictionary-store failure is, for the throw tests — the specific error is the file
/// system's business; the contract is that save surfaces it.
enum DictionaryTestError: Error {
    /// The rename between the pair failed.
    case renameFailed
    /// The directory could not be created.
    case directoryRefused
}
