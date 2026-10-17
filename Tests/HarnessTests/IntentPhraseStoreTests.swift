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
import VoccaActions
import VoccaCore
import XCTest

/// The phrase table's store (`phrase-intent-resolver` PRD R3-R4; `phrase-table-store` spec
/// acceptance 1-8): `intent-phrases.json` — the user's hand-editable file, which a typo can
/// never make fatal and a hostile edit can never turn into a voice path to a shell command.
///
/// Real temp directories throughout; the assertions about the file are about its bytes, read
/// with `FileManager` directly.
final class IntentPhraseStoreTests: XCTestCase {

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-intent-phrases-\(UUID().uuidString)")
    }

    private static let fileName = "intent-phrases.json"

    private static let clearRow = PhraseIntentRow(
        phrase: "clear the audit log", providerID: "dev.vocca.audit", toolID: "audit.clear")
    private static let countRow = PhraseIntentRow(
        phrase: "how big is the log", providerID: "dev.vocca.audit", toolID: "audit.count")

    /// Writes `text` as the file's raw bytes — a hand-edit, which is the threat model.
    private func writeRaw(_ text: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: directory.appendingPathComponent(Self.fileName))
    }

    private func bytes(in directory: URL) -> Data? {
        FileManager.default.contents(
            atPath: directory.appendingPathComponent(Self.fileName).path)
    }

    private func row(_ phrase: String, _ providerID: String, _ toolID: String) -> String {
        #"{"phrase": "\#(phrase)", "providerID": "\#(providerID)", "toolID": "\#(toolID)"}"#
    }

    private func file(_ rows: [String], version: String = "1") -> String {
        #"{"version": \#(version), "phrases": [\#(rows.joined(separator: ", "))]}"#
    }

    // MARK: - Acceptance 1 — absent is empty, quietly

    /// No file is the first-launch default: the empty table, and nothing to complain about.
    func testAnAbsentFileIsTheEmptyTableAndLogsNothing() async {
        let complaints = ComplaintRecorder()
        let loaded = await IntentPhraseStore(
            directory: Self.tempDirectory(), log: complaints.log
        ).load()

        XCTAssertEqual(loaded, .empty)
        XCTAssertEqual(complaints.recorded, [])
    }

    // MARK: - Acceptance 2 — unreadable files are empty, loudly, and never rewritten

    /// A file that is not the shape — garbage, a non-object top level, a version this build
    /// does not read — loads empty with exactly one complaint each.
    func testAnUnreadableOrNonObjectOrWrongVersionFileIsEmptyWithOneLog() async throws {
        let cases = [
            "not json at all",
            #"[{"phrase": "a", "providerID": "p", "toolID": "t"}]"#,
            file([row("clear the audit log", "dev.vocca.audit", "audit.clear")], version: "2"),
            file([row("clear the audit log", "dev.vocca.audit", "audit.clear")], version: "true"),
        ]
        for text in cases {
            let directory = Self.tempDirectory()
            try writeRaw(text, in: directory)
            let complaints = ComplaintRecorder()

            let loaded = await IntentPhraseStore(directory: directory, log: complaints.log).load()

            XCTAssertEqual(loaded, .empty, "'\(text)' must load empty")
            XCTAssertEqual(complaints.recorded.count, 1, "'\(text)' must complain exactly once")
        }
    }

    /// A file over the byte cap is refused whole — never read partially.
    func testAnOversizeFileLoadsEmptyWithOneLog() async throws {
        let directory = Self.tempDirectory()
        let padding = String(repeating: " ", count: IntentPhraseStore.maximumFileBytes)
        try writeRaw(
            file([row("clear the audit log", "dev.vocca.audit", "audit.clear")]) + padding,
            in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await IntentPhraseStore(directory: directory, log: complaints.log).load()

        XCTAssertEqual(loaded, .empty)
        XCTAssertEqual(complaints.recorded.count, 1)
    }

    /// A failed load never rewrites the user's file: the bytes after equal the bytes before.
    func testLoadNeverWritesTheUsersFile() async throws {
        let directory = Self.tempDirectory()
        try writeRaw(#"{"version": 1, "phrases": [ oops"#, in: directory)
        let before = bytes(in: directory)

        _ = await IntentPhraseStore(directory: directory, log: { _ in }).load()

        XCTAssertEqual(bytes(in: directory), before)
    }

    // MARK: - Acceptance 3 — row-level tolerance

    /// Each invalid row is skipped with one complaint, and the valid rows survive in order.
    func testInvalidRowsAreSkippedOneLogEachAndTheRestKeptInOrder() async throws {
        let directory = Self.tempDirectory()
        let longPhrase = String(repeating: "a", count: IntentPhraseStore.maximumPhraseLength + 1)
        let longID = String(repeating: "p", count: IntentPhraseStore.maximumIDLength + 1)
        try writeRaw(
            file([
                row("clear the audit log", "dev.vocca.audit", "audit.clear"),
                row("", "dev.vocca.audit", "audit.count"),
                #"{"phrase": "missing tool", "providerID": "dev.vocca.audit"}"#,
                row(longPhrase, "dev.vocca.audit", "audit.count"),
                row("long provider", longID, "audit.count"),
                row("long tool", "dev.vocca.audit", longID),
                row("!!!", "dev.vocca.audit", "audit.count"),
                "42",
                row("how big is the log", "dev.vocca.audit", "audit.count"),
            ]),
            in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await IntentPhraseStore(directory: directory, log: complaints.log).load()

        XCTAssertEqual(loaded.phrases, [Self.clearRow, Self.countRow])
        XCTAssertEqual(complaints.recorded.count, 7)
    }

    /// The F1 lesson, named: a number or a boolean cannot stand in for a string — the row is
    /// refused, never coerced into an identifier.
    func testABooleanOrNumberCannotStandInForAString() async throws {
        let directory = Self.tempDirectory()
        try writeRaw(
            file([
                #"{"phrase": "clear the audit log", "providerID": "dev.vocca.audit", "toolID": 1}"#,
                #"{"phrase": true, "providerID": "dev.vocca.audit", "toolID": "audit.clear"}"#,
            ]),
            in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await IntentPhraseStore(directory: directory, log: complaints.log).load()

        XCTAssertEqual(loaded.phrases, [])
        XCTAssertEqual(complaints.recorded.count, 2)
    }

    /// Two rows that normalize to the same phrase: the first is kept, the second is skipped
    /// loudly — the file's own order decides, and the resolver never sees an ambiguity.
    func testADuplicateNormalizedPhraseKeepsTheFirstRow() async throws {
        let directory = Self.tempDirectory()
        try writeRaw(
            file([
                row("clear the audit log", "dev.vocca.audit", "audit.clear"),
                row("Clear the audit-log!", "dev.vocca.audit", "audit.count"),
            ]),
            in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await IntentPhraseStore(directory: directory, log: complaints.log).load()

        XCTAssertEqual(loaded.phrases, [Self.clearRow])
        XCTAssertEqual(complaints.recorded.count, 1)
    }

    // MARK: - Acceptance 4 — the shell refusal

    /// A row naming the shell provider is refused at load, with one complaint that says so —
    /// the voice leg can never reach a shell command (the arm-surface-only decision), however
    /// the file was edited.
    func testAShellTargetIsRefusedAtLoadWithOneLog() async throws {
        let directory = Self.tempDirectory()
        try writeRaw(
            file([
                row("empty my downloads", ShellProvider.providerID, "empty-downloads"),
                row("clear the audit log", "dev.vocca.audit", "audit.clear"),
            ]),
            in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await IntentPhraseStore(directory: directory, log: complaints.log).load()

        XCTAssertEqual(loaded.phrases, [Self.clearRow])
        XCTAssertEqual(complaints.recorded.count, 1)
        XCTAssertTrue(
            complaints.recorded.first?.contains("shell") ?? false,
            "the complaint must name the shell refusal, got \(complaints.recorded)")
    }

    // MARK: - Acceptance 5-6 — caps refuse, never clamp

    /// More valid rows than the cap: the whole file is refused — a truncated table is a
    /// different table.
    func testMoreThanTheMaximumPhrasesRefusesTheWholeFile() async throws {
        let directory = Self.tempDirectory()
        let rows = (0...IntentPhraseStore.maximumPhrases).map {
            row("phrase \($0)", "dev.vocca.audit", "audit.count")
        }
        try writeRaw(file(rows), in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await IntentPhraseStore(directory: directory, log: complaints.log).load()

        XCTAssertEqual(loaded, .empty)
        XCTAssertEqual(complaints.recorded.count, 1)
    }

    /// Saving over a cap throws a typed error and leaves nothing on disk — not the file, not a
    /// stray temp file.
    func testSavingOverACapThrowsAndWritesNothing() async throws {
        let directory = Self.tempDirectory()
        let store = IntentPhraseStore(directory: directory, log: { _ in })
        let tooMany = (0...IntentPhraseStore.maximumPhrases).map {
            PhraseIntentRow(phrase: "phrase \($0)", providerID: "p", toolID: "t")
        }
        // Under the row cap, over the byte cap: 250 rows of ~290 encoded bytes is ~72 KB.
        let tooBig = (0..<250).map {
            PhraseIntentRow(
                phrase: "\($0) " + String(repeating: "x", count: 250), providerID: "p", toolID: "t")
        }

        do {
            try await store.save(IntentPhraseFile(version: 1, phrases: tooMany))
            XCTFail("saving over the phrase cap must throw")
        } catch let error as IntentPhraseStoreError {
            XCTAssertEqual(error, .tooManyPhrases(IntentPhraseStore.maximumPhrases + 1))
        }
        do {
            try await store.save(IntentPhraseFile(version: 1, phrases: tooBig))
            XCTFail("saving over the byte cap must throw")
        } catch let error as IntentPhraseStoreError {
            guard case .fileTooLarge = error else {
                return XCTFail("expected fileTooLarge, got \(error)")
            }
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(contents, [], "a refused save must leave nothing behind")
    }

    // MARK: - Acceptance 7 — round trip and atomicity

    func testSaveThenLoadRoundTrips() async throws {
        let store = IntentPhraseStore(directory: Self.tempDirectory(), log: { _ in })
        let file = IntentPhraseFile(version: 1, phrases: [Self.clearRow, Self.countRow])

        try await store.save(file)

        let loaded = await store.load()
        XCTAssertEqual(loaded, file)
    }

    /// Sorted keys: the same table encodes to the same bytes every time, so a hand-edited,
    /// version-controlled file never re-orders itself between runs.
    func testEncodeIsByteStable() throws {
        let file = IntentPhraseFile(version: 1, phrases: [Self.clearRow, Self.countRow])

        XCTAssertEqual(try IntentPhraseStore.encode(file), try IntentPhraseStore.encode(file))
    }

    /// A temp file left by a crash mid-save is never read: only the committed name loads.
    func testAStrayTempFileIsNeverRead() async throws {
        let directory = Self.tempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(file([row("clear the audit log", "dev.vocca.audit", "audit.clear")]).utf8)
            .write(to: directory.appendingPathComponent(Self.fileName + ".tmp"))

        let loaded = await IntentPhraseStore(directory: directory, log: { _ in }).load()

        XCTAssertEqual(loaded, .empty)
    }

    // MARK: - Acceptance 8 — the byte-level pin

    /// The file is shape-only: exactly these bytes for a fixed table — three fields a row, no
    /// enablement, no arguments, no timestamp.
    func testTheEncodedFileIsPinned() throws {
        let file = IntentPhraseFile(version: 1, phrases: [Self.clearRow])

        let encoded = String(decoding: try IntentPhraseStore.encode(file), as: UTF8.self)

        XCTAssertEqual(
            encoded,
            #"{"phrases":[{"phrase":"clear the audit log","providerID":"dev.vocca.audit","toolID":"audit.clear"}],"version":1}"#
        )
    }

    // MARK: - The one normalization

    /// The store's duplicate check and the resolver's match agree: two phrases the store
    /// treats as one are two spellings the resolver matches identically.
    func testTheStoresDuplicateCheckAgreesWithTheResolversMatch() async throws {
        let directory = Self.tempDirectory()
        try writeRaw(
            file([
                row("How big -- is the LOG?", "dev.vocca.audit", "audit.count"),
                row("how big is the log", "dev.vocca.audit", "audit.clear"),
            ]),
            in: directory)

        let loaded = await IntentPhraseStore(directory: directory, log: { _ in }).load()
        let resolver = PhraseIntentResolver(rows: loaded.phrases)
        let catalog = [
            ToolReference(providerID: "dev.vocca.audit", toolID: "audit.count", displayName: ""),
            ToolReference(providerID: "dev.vocca.audit", toolID: "audit.clear", displayName: ""),
        ]

        XCTAssertEqual(loaded.phrases.count, 1)
        XCTAssertEqual(
            resolver.resolve("how big is the log", against: catalog),
            .toolCall(
                try XCTUnwrap(
                    ActionInvocation(
                        providerID: "dev.vocca.audit", toolID: "audit.count", arguments: nil))))
    }

    // MARK: - The keywordFallback switch (composite-intent-resolver A5)

    private func decodeFile(_ text: String) -> (IntentPhraseFile, [String]) {
        let complaints = ComplaintRecorder()
        let decoded = IntentPhraseStore.decode(Data(text.utf8), onInvalid: { _ = complaints.log($0) })
        return (decoded, complaints.recorded)
    }

    private func fileWithSwitch(_ value: String?, rows: [String] = []) -> String {
        let key = value.map { #", "keywordFallback": \#($0)"# } ?? ""
        return #"{"version": 1, "phrases": [\#(rows.joined(separator: ", "))]\#(key)}"#
    }

    /// Absent and an explicit `false` are both off, and neither is worth a log line.
    func testKeywordFallbackAbsentOrFalseIsOffAndSilent() {
        for value in [nil, "false"] {
            let (decoded, logs) = decodeFile(fileWithSwitch(value))
            XCTAssertFalse(decoded.keywordFallback, "\(value ?? "absent") must be off")
            XCTAssertEqual(logs, [], "\(value ?? "absent") must not complain")
        }
        XCTAssertFalse(IntentPhraseFile.empty.keywordFallback)
    }

    /// The F1 no-coercion rule: a number, a string or a null cannot stand in for a Bool.
    func testKeywordFallbackPresentButNotABoolIsOffWithOneLog() {
        for value in ["1", #""true""#, "null", "[]", "{}"] {
            let rows = [row("clear the audit log", "dev.vocca.audit", "audit.clear")]
            let (decoded, logs) = decodeFile(fileWithSwitch(value, rows: rows))
            XCTAssertFalse(decoded.keywordFallback, "\(value) must be off")
            XCTAssertEqual(logs.count, 1, "\(value) must complain exactly once")
            XCTAssertEqual(decoded.phrases.count, 1, "\(value) must not sink the rows")
        }
    }

    func testKeywordFallbackTrueIsOnAndUnknownKeysAreStillIgnored() {
        let text =
            #"{"version": 1, "phrases": [], "keywordFallback": true, "somethingElse": [1, 2]}"#
        let (decoded, logs) = decodeFile(text)
        XCTAssertTrue(decoded.keywordFallback)
        XCTAssertEqual(logs, [])
    }

    func testTheSwitchLeavesPhraseRowsUnaffected() {
        let rows = [
            row("clear the audit log", "dev.vocca.audit", "audit.clear"),
            row("how big is the log", "dev.vocca.audit", "audit.count"),
        ]
        let (off, _) = decodeFile(fileWithSwitch(nil, rows: rows))
        let (on, _) = decodeFile(fileWithSwitch("true", rows: rows))
        XCTAssertEqual(on.phrases, off.phrases)
        XCTAssertEqual(on.phrases.count, 2)
    }

    func testAShellRowIsStillRefusedWhenTheSwitchIsOn() {
        let rows = [row("run it", ShellProvider.providerID, "shell.anything")]
        let (decoded, logs) = decodeFile(fileWithSwitch("true", rows: rows))
        XCTAssertTrue(decoded.keywordFallback)
        XCTAssertEqual(decoded.phrases, [])
        XCTAssertEqual(logs.count, 1)
    }

    func testEncodeThenDecodePreservesTheSwitch() throws {
        let rows = [Self.clearRow]
        let on = IntentPhraseFile(phrases: rows, keywordFallback: true)
        let (decoded, logs) = decodeFile(
            String(decoding: try IntentPhraseStore.encode(on), as: UTF8.self))
        XCTAssertEqual(decoded, on)
        XCTAssertEqual(logs, [])
    }

    /// An off file's bytes are today's bytes: the key is omitted, not written as `false`.
    func testAnOffFileEncodesByteIdenticallyToTheShapeBeforeTheSwitch() throws {
        let off = IntentPhraseFile(phrases: [Self.clearRow])
        let expected =
            #"{"phrases":[{"phrase":"clear the audit log","providerID":"dev.vocca.audit","toolID":"audit.clear"}],"version":1}"#
        XCTAssertEqual(
            String(decoding: try IntentPhraseStore.encode(off), as: UTF8.self), expected)
    }

    // MARK: - Save validation (`phrase-store-validation` A1-A5)

    /// Asserts `save` refuses `submitted` with exactly `reason` and leaves the directory empty —
    /// a refused save must write neither the file nor a stray temp file.
    private func assertSaveRefuses(
        _ submitted: IntentPhraseFile, in directory: URL, reason: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let store = IntentPhraseStore(directory: directory, log: { _ in })
        do {
            try await store.save(submitted)
            XCTFail("save must refuse with \(reason)", file: file, line: line)
        } catch let error as IntentPhraseStoreError {
            XCTAssertEqual(error, .invalidRow(reason: reason), file: file, line: line)
        } catch {
            XCTFail("expected IntentPhraseStoreError, got \(error)", file: file, line: line)
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(
            contents, [], "a refused save must leave nothing behind", file: file, line: line)
    }

    /// A1 — a row naming the shell provider is refused at save, so the voice leg's shell refusal
    /// cannot be defeated by writing the row through the store instead of hand-editing the file.
    func testSaveRefusesAShellTargetRow() async {
        await assertSaveRefuses(
            IntentPhraseFile(phrases: [
                PhraseIntentRow(
                    phrase: "empty my downloads", providerID: ShellProvider.providerID,
                    toolID: "empty-downloads")
            ]),
            in: Self.tempDirectory(), reason: "shellTarget")
    }

    /// A2 — a duplicate normalized phrase is refused: the same rows `load` would collapse to one,
    /// judged with the resolver's own normalization.
    func testSaveRefusesADuplicateNormalizedPhrase() async {
        await assertSaveRefuses(
            IntentPhraseFile(phrases: [
                Self.clearRow,
                PhraseIntentRow(
                    phrase: "Clear the audit-log!", providerID: "dev.vocca.audit",
                    toolID: "audit.count"),
            ]),
            in: Self.tempDirectory(), reason: "duplicatePhrase")
    }

    /// A3 — an empty, whitespace-only or punctuation-only phrase (the one normalization) is
    /// refused.
    func testSaveRefusesAnEmptyOrWhitespacePhrase() async {
        for phrase in ["", "   ", "\t\n", "!!!"] {
            await assertSaveRefuses(
                IntentPhraseFile(phrases: [
                    PhraseIntentRow(
                        phrase: phrase, providerID: "dev.vocca.audit", toolID: "audit.clear")
                ]),
                in: Self.tempDirectory(), reason: "emptyPhrase")
        }
    }

    /// A4 — an over-length phrase is refused, and over-length identifiers are refused distinctly.
    func testSaveRefusesAnOverLengthPhrase() async {
        let tooLong = String(repeating: "a", count: IntentPhraseStore.maximumPhraseLength + 1)
        await assertSaveRefuses(
            IntentPhraseFile(phrases: [
                PhraseIntentRow(
                    phrase: tooLong, providerID: "dev.vocca.audit", toolID: "audit.clear")
            ]),
            in: Self.tempDirectory(), reason: "phraseTooLong")
    }

    func testSaveRefusesAnOverLengthIdentifier() async {
        let longProvider = String(repeating: "p", count: IntentPhraseStore.maximumIDLength + 1)
        let longTool = String(repeating: "t", count: IntentPhraseStore.maximumIDLength + 1)
        await assertSaveRefuses(
            IntentPhraseFile(phrases: [
                PhraseIntentRow(
                    phrase: "clear the audit log", providerID: longProvider, toolID: "audit.clear")
            ]),
            in: Self.tempDirectory(), reason: "idTooLong")
        await assertSaveRefuses(
            IntentPhraseFile(phrases: [
                PhraseIntentRow(
                    phrase: "clear the audit log", providerID: "dev.vocca.audit", toolID: longTool)
            ]),
            in: Self.tempDirectory(), reason: "idTooLong")
    }

    /// The refusal order is deterministic: shell outranks duplicate, empty and length, so the
    /// reason a surface shows is unambiguous.
    func testTheSaveRefusalOrderIsShellFirst() async {
        let tooLong = String(repeating: "a", count: IntentPhraseStore.maximumPhraseLength + 1)
        await assertSaveRefuses(
            IntentPhraseFile(phrases: [
                Self.clearRow,
                PhraseIntentRow(
                    phrase: "clear the audit log", providerID: ShellProvider.providerID, toolID: "x"),
            ]),
            in: Self.tempDirectory(), reason: "shellTarget")
        await assertSaveRefuses(
            IntentPhraseFile(phrases: [
                PhraseIntentRow(phrase: "", providerID: ShellProvider.providerID, toolID: "x")
            ]),
            in: Self.tempDirectory(), reason: "shellTarget")
        await assertSaveRefuses(
            IntentPhraseFile(phrases: [
                PhraseIntentRow(phrase: tooLong, providerID: ShellProvider.providerID, toolID: "x")
            ]),
            in: Self.tempDirectory(), reason: "shellTarget")
    }

    /// A5 — a valid table still saves byte-identically to the pin: the refusals never touch a good
    /// row's encoding.
    func testAValidSaveWritesThePinnedBytes() async throws {
        let directory = Self.tempDirectory()
        let store = IntentPhraseStore(directory: directory, log: { _ in })

        try await store.save(IntentPhraseFile(version: 1, phrases: [Self.clearRow]))

        XCTAssertEqual(
            String(decoding: try XCTUnwrap(bytes(in: directory)), as: UTF8.self),
            #"{"phrases":[{"phrase":"clear the audit log","providerID":"dev.vocca.audit","toolID":"audit.clear"}],"version":1}"#
        )
    }

    // MARK: - The file-location accessor (`phrase-store-validation` A7)

    /// A7 — the accessor names `<directory>/intent-phrases.json`, the one path save and load use.
    func testTheFileURLAccessorNamesTheCommittedFile() async throws {
        let directory = Self.tempDirectory()
        let store = IntentPhraseStore(directory: directory, log: { _ in })

        let accessor = await store.fileURL

        XCTAssertEqual(accessor, directory.appendingPathComponent(Self.fileName))
        try await store.save(IntentPhraseFile(phrases: [Self.clearRow]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: accessor.path))
        let loaded = await store.load()
        XCTAssertEqual(loaded, IntentPhraseFile(phrases: [Self.clearRow]))
    }

    // MARK: - The read-before-write guard (`phrase-store-validation` D-4)

    /// A committed file that changed since the snapshot refuses the write and leaves the bytes
    /// untouched — the conflict rule lives in the store, not the surface.
    func testSaveIfUnchangedRefusesWhenTheFileChangedOnDisk() async throws {
        let directory = Self.tempDirectory()
        let store = IntentPhraseStore(directory: directory, log: { _ in })
        let snapshot = IntentPhraseFile(phrases: [Self.clearRow])
        try await store.save(snapshot)
        try await store.save(IntentPhraseFile(phrases: [Self.countRow]))
        let before = bytes(in: directory)

        do {
            try await store.save(
                IntentPhraseFile(phrases: [Self.clearRow, Self.countRow]),
                ifUnchangedFrom: snapshot)
            XCTFail("a committed file that changed must refuse the save")
        } catch let error as IntentPhraseStoreError {
            XCTAssertEqual(error, .fileChangedOnDisk)
        }

        XCTAssertEqual(bytes(in: directory), before)
    }

    /// A committed file equal to the snapshot saves — the happy path the guard must not block.
    func testSaveIfUnchangedWritesWhenTheFileMatches() async throws {
        let directory = Self.tempDirectory()
        let store = IntentPhraseStore(directory: directory, log: { _ in })
        let snapshot = IntentPhraseFile(phrases: [Self.clearRow])
        try await store.save(snapshot)
        let next = IntentPhraseFile(phrases: [Self.clearRow, Self.countRow])

        try await store.save(next, ifUnchangedFrom: snapshot)

        let loaded = await store.load()
        XCTAssertEqual(loaded, next)
    }

    /// An absent file is the empty committed table: an `.empty` snapshot matches and the save
    /// lands, so a first save needs no special case.
    func testSaveIfUnchangedWritesWhenAbsentAndTheSnapshotWasEmpty() async throws {
        let directory = Self.tempDirectory()
        let store = IntentPhraseStore(directory: directory, log: { _ in })
        let next = IntentPhraseFile(phrases: [Self.clearRow])

        try await store.save(next, ifUnchangedFrom: .empty)

        let loaded = await store.load()
        XCTAssertEqual(loaded, next)
    }

    // MARK: - The default location

    func testTheDefaultDirectoryIsApplicationSupportVocca() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support")

        XCTAssertEqual(
            IntentPhraseStore.defaultDirectory(applicationSupport: support, home: home),
            support.appendingPathComponent("Vocca"))
        XCTAssertEqual(
            IntentPhraseStore.defaultDirectory(applicationSupport: nil, home: home),
            support.appendingPathComponent("Vocca"))
    }
}

// MARK: - Test doubles

/// A recorder for the store's injected log — the loud half of the tolerance policy, asserted
/// rather than hoped.
private final class ComplaintRecorder: Sendable {
    private let messages = Mutex<[String]>([])

    var recorded: [String] { messages.withLock { $0 } }

    var log: @Sendable (String) -> Void {
        { message in self.messages.withLock { $0.append(message) } }
    }
}
