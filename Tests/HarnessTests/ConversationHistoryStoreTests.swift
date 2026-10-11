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
@testable import VoccaConversation
import XCTest

/// The conversation-history store — the `history-store` aspect's Phase 2 contract
/// (`plan_20261011.md`), written before the store exists. Failing to compile is the red state:
/// no `ConversationRecording` is in scope and no `ConversationHistoryStore(directory:…)` exists
/// yet.
///
/// Like the consent and usage stores, `FileManager` works on a hosted runner, so the real
/// ``ConversationHistoryStore`` runs here against real temp directories: the round trip,
/// the caps, the tolerant decode and the clear are all exercised over the real bytes, and the
/// injected ``ConversationFileSystem`` seam is driven through a recording actor (the atomic-pair
/// protocol) and a refusing create-directory (the never-throws contract).
///
/// The load-bearing halves are the bounds (H4): the 51st turn evicts the oldest, a text longer
/// than the cap is truncated without ever splitting a multi-byte UTF-8 scalar, and a hand-edited
/// oversize file loads bounded — every one of them an acceptance test, not a promise, because
/// this is the first store whose file carries what the user said (`prd.md` gap 1). The
/// byte-level pin (H6) is the other: the file carries exactly `version` + `turns`, two strings
/// and a bool per turn, and nothing else.
final class ConversationHistoryStoreTests: XCTestCase {

    // MARK: - H3 · record & round trip

    /// `recordTurn` appends `(utterance, reply, interrupted: false)` in order, byte-for-byte
    /// within the cap, and a fresh store over the same file (a relaunch) returns the identical
    /// list.
    func testRecordAppendsTurnsInOrderByteForByteAndSurvivesARelaunch() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationHistoryStore(directory: directory)

        let multilingual = "second — with an em dash, émoji 🙂, and 日本語"
        await store.recordTurn(utterance: "first words", reply: "first answer")
        await store.recordTurn(utterance: multilingual, reply: "second answer")
        await store.recordTurn(utterance: "third", reply: "third answer")

        let held = await store.currentTurns()
        XCTAssertEqual(
            held,
            [
                ConversationTurn(utterance: "first words", reply: "first answer"),
                ConversationTurn(utterance: multilingual, reply: "second answer"),
                ConversationTurn(utterance: "third", reply: "third answer"),
            ],
            "recordTurn must append in order, byte-for-byte, with interrupted false")

        let relaunched = ConversationHistoryStore(directory: directory)
        let reloaded = await relaunched.load()
        XCTAssertEqual(
            reloaded, held,
            "a fresh store over the same file (a relaunch) must return the identical list")
    }

    // MARK: - H4 · the bounds

    /// With 50 turns stored, the 51st **evicts the oldest** — the deliberate divergence from the
    /// settings stores' refuse-never-clamp (the RecoveryJournal precedent, D3), pinned at the
    /// real bound, and the eviction is persisted, not just held.
    func testTheFiftyFirstTurnEvictsTheOldestAndTheEvictionIsPersisted() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationHistoryStore(directory: directory)

        XCTAssertEqual(
            ConversationHistoryStore.maximumTurns, 50,
            "the documented window is 50 turns — the value the copy discloses")

        for index in 0..<ConversationHistoryStore.maximumTurns {
            await store.recordTurn(utterance: "turn \(index)", reply: "reply \(index)")
        }
        await store.recordTurn(utterance: "turn 50", reply: "reply 50")

        let held = await store.currentTurns()
        XCTAssertEqual(
            held.count, ConversationHistoryStore.maximumTurns,
            "the store never grows past the cap — a 51st turn evicts, it does not refuse")
        XCTAssertEqual(held.first?.utterance, "turn 1", "the oldest turn is the one evicted")
        XCTAssertEqual(held.last?.utterance, "turn 50", "the newest turn is the one kept")

        let reloaded = await ConversationHistoryStore(directory: directory).load()
        XCTAssertEqual(reloaded, held, "the eviction is on disk, not only in memory")
    }

    /// Texts longer than the cap are truncated at the bound, in both fields — 2000 characters,
    /// the bubble's render cap value reused (D3). A text exactly at the bound is untouched.
    func testTextsLongerThanTheCapAreTruncatedAtTheBoundInBothFields() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationHistoryStore(directory: directory)
        let cap = ConversationHistoryStore.maximumTextCharacters

        XCTAssertEqual(cap, 2000, "the documented text cap is the bubble's render cap value")

        let overlong = String(repeating: "x", count: cap + 500)
        let atCap = String(repeating: "y", count: cap)
        await store.recordTurn(utterance: overlong, reply: atCap)

        let held = await store.currentTurns()
        XCTAssertEqual(
            held.first?.utterance, String(repeating: "x", count: cap),
            "an overlong utterance is truncated at the bound, never refused")
        XCTAssertEqual(
            held.first?.reply, atCap,
            "a text exactly at the bound is untouched")

        let reloaded = await ConversationHistoryStore(directory: directory).load()
        XCTAssertEqual(reloaded, held, "what was truncated in memory is what persisted")
    }

    /// **The UTF-8 scalar pin.** Truncation counts characters, never bytes: a byte-counted cut
    /// through a multi-byte scalar would emit a replacement character (or split the encoded
    /// value), and the user's text would be silently corrupted at exactly the bound.
    func testTruncationAtTheBoundNeverSplitsAMultiByteUTF8Scalar() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationHistoryStore(directory: directory)
        let cap = ConversationHistoryStore.maximumTextCharacters

        // 1999 ASCII characters put the 2000-character bound exactly on the lead byte of a
        // two-byte scalar ("é" is 2 bytes in UTF-8): a byte-counted truncation at 2000 bytes
        // would keep half of it.
        let mixed = String(repeating: "a", count: cap - 1) + String(repeating: "é", count: 2000)
        await store.recordTurn(utterance: mixed, reply: "ok")
        let expected = String(repeating: "a", count: cap - 1) + "é"
        let firstHeld = await store.currentTurns()
        XCTAssertEqual(
            firstHeld.first?.utterance, expected,
            """
            truncation must not split a multi-byte UTF-8 scalar: the cut landed inside "é" and \
            the result must be the complete scalar, not a replacement character
            """)
        XCTAssertEqual(
            firstHeld.first?.utterance.count, cap,
            "the truncated text is exactly the cap in characters")

        // A pure four-byte-scalar case, to the same bound.
        let emoji = String(repeating: "🙂", count: cap + 100)
        await store.recordTurn(utterance: emoji, reply: "ok")
        let secondHeld = await store.currentTurns()
        XCTAssertEqual(
            secondHeld.last?.utterance, String(repeating: "🙂", count: cap),
            "four-byte scalars are truncated at the same character bound, never mid-scalar")
    }

    /// A hand-edited file holding more turns than the window is bounded on the way in — the
    /// newest 50 survive — and its over-cap texts are truncated by the same one bound.
    func testAHandEditedOversizeFileLoadsBoundedNewestFiftyWithTruncatedTexts() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var rows: [String] = (0..<59).map {
            #"{"utterance":"turn \#($0)","reply":"reply \#($0)","interrupted":false}"#
        }
        let overlong = String(repeating: "z", count: ConversationHistoryStore.maximumTextCharacters + 100)
        rows.append(#"{"utterance":"\#(overlong)","reply":"last","interrupted":false}"#)
        let json = #"{"version":1,"turns":[\#(rows.joined(separator: ","))]}"#
        try json.write(
            to: directory.appendingPathComponent("conversation.json"), atomically: true,
            encoding: .utf8)

        let store = ConversationHistoryStore(directory: directory)
        let loaded = await store.load()

        XCTAssertEqual(
            loaded.count, ConversationHistoryStore.maximumTurns,
            "a hand-edited file holding more than the window loads bounded — the bound is the "
                + "store's rule and applies on the way in, not the file's to widen")
        XCTAssertEqual(loaded.first?.utterance, "turn 10", "the newest turns are what survive")
        XCTAssertEqual(loaded.last?.reply, "last", "the newest turn is the last one kept")
        XCTAssertEqual(
            loaded.last?.utterance,
            String(repeating: "z", count: ConversationHistoryStore.maximumTextCharacters),
            "an over-cap text in a hand-edited file is truncated by the same bound")
    }

    // MARK: - H5 · mark & clear

    /// `markLastTurnInterrupted` marks the most recent turn only, and the mark is persisted.
    func testMarkLastTurnInterruptedMarksOnlyTheMostRecentTurnAndSurvivesRelaunch() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationHistoryStore(directory: directory)
        await store.recordTurn(utterance: "one", reply: "answer one")
        await store.recordTurn(utterance: "two", reply: "answer two")
        await store.recordTurn(utterance: "three", reply: "answer three")

        await store.markLastTurnInterrupted()

        let held = await store.currentTurns()
        XCTAssertEqual(
            held.map(\.interrupted), [false, false, true],
            "the barge-in mark belongs to the most recent turn, never a neighbor")
        XCTAssertEqual(
            held.map(\.utterance), ["one", "two", "three"],
            "marking must not reorder or drop turns")

        let reloaded = await ConversationHistoryStore(directory: directory).load()
        XCTAssertEqual(reloaded, held, "the mark is on disk, not only in memory")
    }

    /// `markLastTurnInterrupted` with no turns is a no-op: nothing is held, nothing is written.
    func testMarkWithNoTurnsIsANoOpAndWritesNothing() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingConversationFileSystem()
        let store = ConversationHistoryStore(directory: directory, fileSystem: fileSystem)

        await store.markLastTurnInterrupted()

        let held = await store.currentTurns()
        XCTAssertEqual(held, [], "marking an empty history produces no turn")
        let events = await fileSystem.events
        XCTAssertTrue(
            events.isEmpty,
            "marking an empty history must not touch the file system at all, got: \(events)")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("conversation.json").path),
            "marking an empty history must not create the file")
    }

    /// `clear()` deletes the file through the seam and empties state; a clear over a missing
    /// file succeeds quietly — nothing to delete is the outcome the caller asked for.
    func testClearDeletesTheFileThroughTheSeamAndEmptiesStateAndIsQuietOnAMissingFile() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingConversationFileSystem()
        let store = ConversationHistoryStore(directory: directory, fileSystem: fileSystem)
        await store.recordTurn(utterance: "one", reply: "answer one")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("conversation.json").path),
            "the record committed a file to delete")

        try await store.clear()

        let after = await store.currentTurns()
        XCTAssertEqual(after, [], "clear empties the held history")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("conversation.json").path),
            "clear must delete the file — bytes off disk, not an empty file left behind")
        let events = await fileSystem.events
        XCTAssertEqual(
            Array(events.suffix(2)),
            [.fileExists("conversation.json"), .remove("conversation.json")],
            "clear asks, then removes through the seam — the deletion is the effect")

        try await store.clear()
        let eventsAfterSecondClear = await fileSystem.events
        XCTAssertEqual(
            Array(eventsAfterSecondClear.suffix(1)), [.fileExists("conversation.json")],
            "a clear over a missing file is quiet: an existence check and nothing else")
    }

    /// `load()` over a missing file answers empty and **never writes** — the usage-store
    /// contract; a first run is not an error and not a write.
    func testLoadOverAMissingFileAnswersEmptyAndNeverWrites() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingConversationFileSystem()
        let store = ConversationHistoryStore(directory: directory, fileSystem: fileSystem)

        let loaded = await store.load()

        XCTAssertEqual(loaded, [], "a missing file is the empty history")
        let events = await fileSystem.events
        XCTAssertEqual(
            events, [.fileExists("conversation.json")],
            "a load over a missing file must ask and stop — never a write of any kind, got: "
                + "\(events)")
    }

    /// An unreadable file (the seam's read answers `nil`) loads empty with one loud line and is
    /// never rewritten.
    func testAnUnreadableFileLoadsEmptyLoudlyAndIsNeverRewritten() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("conversation.json")
        try #"{"version":1,"turns":[]}"#.write(to: path, atomically: true, encoding: .utf8)
        let readable = try Data(contentsOf: path)

        let logs = LogCollector()
        let store = ConversationHistoryStore(
            directory: directory, fileSystem: UnreadableConversationFileSystem(),
            log: { logs.append($0) })

        let loaded = await store.load()

        XCTAssertEqual(loaded, [], "an unreadable file loads empty, never a throw")
        XCTAssertEqual(logs.entries.count, 1, "an unreadable file is exactly one loud line")
        XCTAssertEqual(
            try? Data(contentsOf: path), readable,
            "a failed read must never rewrite the user's file")
    }

    // MARK: - H6 · shape & pins

    /// The commit is the atomic temp-write → rename pair, exactly: directory created, the temp
    /// file written, then renamed over the committed name — no `.tmp` left behind.
    func testARecordCommitsAsTheAtomicTempWriteThenRenamePairWithNoTmpLeftBehind() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingConversationFileSystem()
        let store = ConversationHistoryStore(directory: directory, fileSystem: fileSystem)

        await store.recordTurn(utterance: "u", reply: "r")

        let events = await fileSystem.events
        XCTAssertEqual(
            events,
            [
                .createDirectory(directory.path),
                .tempWrite("conversation.json.tmp"),
                .rename("conversation.json"),
            ],
            "a durable record is exactly the atomic pair: temp written, then renamed into place")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("conversation.json")),
            try ConversationHistoryStore.encode([ConversationTurn(utterance: "u", reply: "r")]),
            "the committed file must hold the encoded turn")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("conversation.json.tmp").path),
            "no .tmp may remain after a completed record")
    }

    /// Invalid rows are skipped with one loud line each, the readable remainder loads, and the
    /// file is left exactly as written — a tolerant load never rewrites.
    func testInvalidRowsAreSkippedLoudlyAndTheReadableRemainderLoads() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
            {
              "version": 1,
              "turns": [
                {"utterance": "kept one", "reply": "kept reply", "interrupted": false},
                null,
                "not a turn",
                {"utterance": 5, "reply": "x", "interrupted": false},
                {"utterance": "missing reply", "interrupted": true},
                {"utterance": "kept two", "reply": "kept reply two", "interrupted": true}
              ]
            }
            """
        try json.write(
            to: directory.appendingPathComponent("conversation.json"), atomically: true,
            encoding: .utf8)

        let logs = LogCollector()
        let store = ConversationHistoryStore(directory: directory, log: { logs.append($0) })
        let loaded = await store.load()

        XCTAssertEqual(
            loaded,
            [
                ConversationTurn(utterance: "kept one", reply: "kept reply"),
                ConversationTurn(utterance: "kept two", reply: "kept reply two", interrupted: true),
            ],
            "the valid rows must load; each invalid one must be skipped")
        XCTAssertEqual(logs.entries.count, 4, "exactly one loud line per skipped row")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("conversation.json")),
            Data(json.utf8),
            "a tolerant load must never rewrite the user's file")
    }

    /// A whole file this build cannot read as this format — a non-object top level, an unknown
    /// version, no turns list — loads empty with exactly one loud line each, bytes unchanged.
    func testAWholeFileThatIsNotThisFormatLoadsEmptyLoudlyAndIsNeverRewritten() async throws {
        for json in [
            #"["not", "an", "object"]"#,
            #"{"version": 2, "turns": []}"#,
            #"{"version": 1}"#,
        ] {
            let directory = Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try json.write(
                to: directory.appendingPathComponent("conversation.json"), atomically: true,
                encoding: .utf8)

            let logs = LogCollector()
            let store = ConversationHistoryStore(directory: directory, log: { logs.append($0) })
            let loaded = await store.load()

            XCTAssertEqual(
                loaded, [],
                "a file this build cannot read as this format must load empty, never be guessed at")
            XCTAssertEqual(
                logs.entries.count, 1,
                "a whole-file refusal is exactly one loud line, for: \(json)")
            XCTAssertEqual(
                try? Data(contentsOf: directory.appendingPathComponent("conversation.json")),
                Data(json.utf8),
                "a refused file must never be rewritten, for: \(json)")
        }
    }

    /// **The byte-level pin.** The encoded bytes carry exactly `version` + `turns`, and each
    /// turn exactly `utterance` + `reply` + `interrupted` — two strings and a bool, no
    /// timestamps, no extra keys, sorted so the bytes are stable across processes.
    ///
    /// The key-set half is the strong one: a future `recordedAt` field, a session ID or a
    /// display name fails this on the day it is added, because there is no key the format could
    /// carry it under. The exact-bytes half adds stability: the same turns always encode to the
    /// same file.
    func testTheEncodedBytesCarryExactlyVersionAndTurnsAndNothingElse() throws {
        let turns = [
            ConversationTurn(utterance: "the first thing", reply: "the first answer"),
            ConversationTurn(utterance: "second thing", reply: "reply two", interrupted: true),
        ]

        let data = try ConversationHistoryStore.encode(turns)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(
            text,
            #"{"turns":[{"interrupted":false,"reply":"the first answer","utterance":"the first thing"},{"interrupted":true,"reply":"reply two","utterance":"second thing"}],"version":1}"#,
            "the encoded bytes must be stable and carry exactly the bounded turn list")

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("the encoded bytes must decode as a JSON object")
        }
        XCTAssertEqual(
            Set(object.keys), ["version", "turns"],
            "the file's keys must be exactly version and turns — a timestamp field or any other "
                + "metadata fails this on the day it is added")
        XCTAssertEqual(object["version"] as? Int, 1, "version 1 is the only version this build writes")
        let rows = object["turns"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, turns.count)
        for row in rows {
            XCTAssertEqual(
                Set(row.keys), ["utterance", "reply", "interrupted"],
                "each turn carries exactly the utterance, the reply and the interrupted flag — "
                    + "no other field exists in a record")
        }

        let decoded = ConversationHistoryStore.decode(data, onInvalidRow: { _ in })
        XCTAssertEqual(decoded, turns, "the encoded bytes decode back to the same turns")
    }

    /// `onChange` fires with the new count after `recordTurn`, after `load()` and after
    /// `clear()` — and **not** after `markLastTurnInterrupted`, which changes no count (D4).
    func testOnChangeFiresWithTheNewCountAfterRecordLoadAndClearButNotMark() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counts = CountCollector()
        let store = ConversationHistoryStore(directory: directory, onChange: { counts.append($0) })

        await store.recordTurn(utterance: "one", reply: "answer one")
        await store.markLastTurnInterrupted()
        await store.recordTurn(utterance: "two", reply: "answer two")
        _ = await store.load()
        try await store.clear()
        _ = await store.load()

        XCTAssertEqual(
            counts.counts, [1, 2, 2, 0, 0],
            """
            onChange must fire with the new count after record/load/clear — and not after \
            mark, which changes no count: got \(counts.counts)
            """)
    }

    /// A persist failure is logged and swallowed: the in-memory turn stays, the conversation is
    /// never interrupted by a thrown error (the `local-data-provider` lesson), and nothing
    /// reaches the disk.
    func testAFailedPersistIsLoggedAndNeverThrown() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = LogCollector()
        let store = ConversationHistoryStore(
            directory: directory, fileSystem: RefusingCreateDirectoryConversationFileSystem(),
            log: { logs.append($0) })

        await store.recordTurn(utterance: "u", reply: "r")

        let held = await store.currentTurns()
        XCTAssertEqual(
            held.count, 1,
            "a failed persist is a value: the turn stays in memory, the turn-taking is untouched")
        XCTAssertEqual(logs.entries.count, 1, "a failed persist is one loud line")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("conversation.json").path),
            "a refused write must leave no file")
    }

    /// The no-argument store resolves
    /// `~/Library/Application Support/Vocca/conversation.json`, and its fallback — for the
    /// machine where Application Support cannot be resolved — puts the file under the home
    /// directory rather than somewhere unpredictable.
    func testTheDefaultLocationIsApplicationSupportVoccaConversationJSON() async {
        let resolved = ConversationHistoryStore.defaultDirectory(
            applicationSupport: URL(fileURLWithPath: "/Users/example/Library/Application Support"),
            home: URL(fileURLWithPath: "/Users/example"))
        XCTAssertEqual(
            resolved.appendingPathComponent(ConversationHistoryStore.fileName).path,
            "/Users/example/Library/Application Support/Vocca/conversation.json",
            "the history lives beside the tree's other Application Support files")

        let fallback = ConversationHistoryStore.defaultDirectory(
            applicationSupport: nil, home: URL(fileURLWithPath: "/Users/example"))
        XCTAssertEqual(
            fallback.appendingPathComponent(ConversationHistoryStore.fileName).path,
            "/Users/example/Library/Application Support/Vocca/conversation.json",
            "an unresolvable Application Support falls back to the same place under the home "
                + "directory — defensive, not a different decision about where history lives")

        let real = await ConversationHistoryStore().fileURL
        XCTAssertTrue(
            real.path.hasSuffix("/Library/Application Support/Vocca/conversation.json"),
            "the shipped default resolves the documented path, got: \(real.path)")
    }

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-conversation-\(UUID().uuidString)")
    }
}

/// Collects the `onChange` counts in tests — `Sendable`-safe because its only mutable state sits
/// behind a `Mutex`, so the `@Sendable (Int) -> Void` closure can capture it in strict Swift 6.
final class CountCollector: Sendable {
    private let storage = Mutex<[Int]>([])

    func append(_ count: Int) {
        storage.withLock { $0.append(count) }
    }

    var counts: [Int] {
        storage.withLock { $0 }
    }
}

/// What the conversation store's file-system seam records, in order — the **atomic-pair
/// protocol** the durability claim is carried by (the consent store's
/// `ConsentFileSystemEvent` shape).
enum ConversationFileSystemEvent: Equatable {
    /// The directory was created — on the way to the temp write.
    case createDirectory(String)
    /// The temp file was written — not yet readable, not yet committed.
    case tempWrite(String)
    /// The temp file was renamed over the committed name — the commit point.
    case rename(String)
    /// The committed file was deleted — `clear()`'s effect.
    case remove(String)
    /// The file was read.
    case read(String)
    /// The file's existence was asked.
    case fileExists(String)
}

/// An in-memory ``ConversationFileSystem`` whose every operation is recorded, against a real
/// temp directory — the atomic-pair protocol half. The commit is `replaceItemAt`, mirroring the
/// shipped adapter (whose overwrite-succeeds commit is the point of the pair), so a second
/// record over the same file records the same two commit events.
actor RecordingConversationFileSystem: ConversationFileSystem {
    private(set) var events: [ConversationFileSystemEvent] = []

    func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        events.append(.createDirectory(url.path))
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
        events.append(.remove(url.lastPathComponent))
    }

    func read(_ url: URL) async -> Data? {
        events.append(.read(url.lastPathComponent))
        return FileManager.default.contents(atPath: url.path)
    }

    func fileExists(atPath path: String) async -> Bool {
        let exists = FileManager.default.fileExists(atPath: path)
        events.append(.fileExists(URL(fileURLWithPath: path).lastPathComponent))
        return exists
    }
}

/// The read-refusal half: the file exists and cannot be read, so `load()` must answer empty
/// loudly without touching it.
struct UnreadableConversationFileSystem: ConversationFileSystem {
    func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
    }

    func removeItem(at url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }

    func read(_ url: URL) async -> Data? {
        nil
    }

    func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// The refused-write contract: the directory cannot be created, so a record must log the
/// failure and carry on — never throw into the conversation.
struct RefusingCreateDirectoryConversationFileSystem: ConversationFileSystem {
    func createDirectory(at url: URL) async throws {
        throw ConversationStoreTestError.directoryRefused
    }

    func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        try FileManager.default.moveItem(at: source, to: destination)
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

/// What a conversation-store failure is, for the never-throws test — the specific error is the
/// file system's business; the contract is that the store logs it and carries on.
enum ConversationStoreTestError: Error {
    /// The directory could not be created.
    case directoryRefused
}