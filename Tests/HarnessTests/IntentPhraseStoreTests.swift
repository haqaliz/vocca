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
