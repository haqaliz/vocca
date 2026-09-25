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

/// The persisted phrase table (`phrase-intent-resolver` PRD R3-R4; `phrase-table-store` spec) —
/// **`intent-phrases.json`**, the user's hand-editable map from a spoken phrase to a tool, read
/// by the composed ``PhraseIntentResolver`` once per converse turn.
///
/// ## The file
///
/// `<applicationSupport>/Vocca/intent-phrases.json`:
///
/// ```json
/// {"version": 1, "phrases": [{"phrase": "wipe the log", "providerID": "dev.vocca.audit",
///                             "toolID": "audit.clear"}]}
/// ```
///
/// **Shape-only**: three strings a row, never enablement (that is `action-config.json`'s,
/// and the resolver's catalog), never arguments, never a timestamp.
///
/// ## Tolerance — a typo is never fatal
///
/// ``load()`` never throws and never writes. An absent file is the empty table, silently. A file
/// that cannot be read, is not the shape, carries a version this build does not read, or is over
/// ``maximumFileBytes`` is the empty table with **one** loud log. Within a good file each row is
/// judged on its own and an invalid one is skipped with one loud log: a missing, empty or
/// non-string field (a `1` or a `true` is never coerced into an identifier — the F1 lesson), a
/// field over its cap, a phrase that normalizes to nothing, or a phrase that normalizes to one
/// already accepted (the first row wins — the file's own order decides). Every empty answer
/// means the voice leg resolves nothing, which is the safe direction.
///
/// ## The shell refusal
///
/// A row naming ``ShellProvider/providerID`` is refused at load, loudly: the voice leg can never
/// reach a shell command, however the file was edited — the arm-surface-only decision
/// (`shell-provider`) holds without Core ever learning a provider id.
///
/// ## Caps refuse, never clamp
///
/// More than ``maximumPhrases`` valid rows refuses the whole file on load, and ``save(_:)``
/// throws over either cap and writes nothing: a truncated table is a different table. The caps
/// are seeds; a retune is a reviewed edit.
///
/// ## Durability
///
/// ``save(_:)`` is the atomic pair — write `<dir>/intent-phrases.json.tmp`, rename over the
/// committed name — with sorted keys, so the bytes are stable across runs. A `.tmp` left by a
/// crash is never read. The logs name the file and the row, **never** a phrase's text: phrases
/// are the user's own words.
public actor IntentPhraseStore {

    /// The directory the table lives in. The file is always `<directory>/intent-phrases.json`.
    public let directory: URL

    /// The most rows a file may hold. More refuses the whole file.
    public static let maximumPhrases = 256

    /// The largest file that is read, and the largest that is written.
    public static let maximumFileBytes = 64 * 1024

    /// The longest phrase, in characters.
    public static let maximumPhraseLength = 256

    /// The longest provider or tool identifier, in characters.
    public static let maximumIDLength = 128

    private let fileSystem: ActionConfigFileSystem
    private let log: @Sendable (String) -> Void

    /// A store over `directory`. The directory is created on the first save; a store over a
    /// directory that does not exist is the empty table, not an error.
    public init(
        directory: URL,
        fileSystem: ActionConfigFileSystem = DefaultActionConfigFileSystem(),
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "intent-phrases").error("\($0)")
        }
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.log = log
    }

    /// `<applicationSupport>/Vocca`, or the same location reached through `home` when the
    /// Application Support directory cannot be resolved.
    public static func defaultDirectory(applicationSupport: URL?, home: URL) -> URL {
        let base =
            applicationSupport ?? home.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Vocca")
    }

    // MARK: - Reading

    /// The table on disk, or the empty table — per the type documentation's tolerance rules.
    public func load() async -> IntentPhraseFile {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        guard await fileSystem.fileExists(atPath: fileURL.path) else { return .empty }
        guard let data = await fileSystem.read(fileURL) else {
            log("intent-phrases: could not read \(fileURL.path); loading an empty table")
            return .empty
        }
        return Self.decode(data, onInvalid: log)
    }

    // MARK: - Writing

    /// Writes `file` atomically. Throws — and writes nothing — over either cap, or on any
    /// file-system failure: a failed save means the table is not durable.
    public func save(_ file: IntentPhraseFile) async throws {
        guard file.phrases.count <= Self.maximumPhrases else {
            log(
                "intent-phrases: refusing \(file.phrases.count) phrases (cap "
                    + "\(Self.maximumPhrases))")
            throw IntentPhraseStoreError.tooManyPhrases(file.phrases.count)
        }
        let data = try Self.encode(file)
        guard data.count <= Self.maximumFileBytes else {
            log(
                "intent-phrases: refusing a file of \(data.count) bytes (cap "
                    + "\(Self.maximumFileBytes))")
            throw IntentPhraseStoreError.fileTooLarge(data.count)
        }

        try await fileSystem.createDirectory(at: directory)
        let temporaryURL = directory.appendingPathComponent(Self.fileName + Self.tempSuffix)
        let committedURL = directory.appendingPathComponent(Self.fileName)
        try await fileSystem.write(data, to: temporaryURL)
        try await fileSystem.moveItem(at: temporaryURL, to: committedURL)
    }

    // MARK: - The bytes

    /// The bytes ``save(_:)`` writes: sorted keys, so the same table is the same file.
    public static func encode(_ file: IntentPhraseFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            FileDTO(
                version: file.version,
                phrases: file.phrases.map {
                    RowDTO(phrase: $0.phrase, providerID: $0.providerID, toolID: $0.toolID)
                }))
    }

    /// The table ``load()`` reads from `data` — never throws; every refusal goes through
    /// `onInvalid`, once per refused file or row.
    public static func decode(
        _ data: Data, onInvalid: (String) -> Void
    ) -> IntentPhraseFile {
        guard data.count <= maximumFileBytes else {
            onInvalid(
                "intent-phrases: refusing a file of \(data.count) bytes (cap \(maximumFileBytes))")
            return .empty
        }
        guard let decoded = try? JSONDecoder().decode(LossyFileDTO.self, from: data) else {
            onInvalid("intent-phrases: refusing an unreadable phrase file")
            return .empty
        }
        guard decoded.version == 1 else {
            onInvalid("intent-phrases: refusing a phrase file of version \(decoded.version)")
            return .empty
        }

        var accepted = Set<String>()
        var phrases: [PhraseIntentRow] = []
        for (index, element) in decoded.phrases.enumerated() {
            guard let row = element.row else {
                onInvalid("intent-phrases: skipping row \(index): not three string fields")
                continue
            }
            guard !row.phrase.isEmpty, !row.providerID.isEmpty, !row.toolID.isEmpty else {
                onInvalid("intent-phrases: skipping row \(index): an empty field")
                continue
            }
            guard row.phrase.count <= maximumPhraseLength else {
                onInvalid(
                    "intent-phrases: skipping row \(index): the phrase exceeds "
                        + "\(maximumPhraseLength) characters")
                continue
            }
            guard row.providerID.count <= maximumIDLength, row.toolID.count <= maximumIDLength
            else {
                onInvalid(
                    "intent-phrases: skipping row \(index): an identifier exceeds "
                        + "\(maximumIDLength) characters")
                continue
            }
            guard row.providerID != ShellProvider.providerID else {
                onInvalid(
                    "intent-phrases: refusing row \(index): a shell command cannot be reached "
                        + "by voice")
                continue
            }
            let key = PhraseIntentResolver.normalized(row.phrase)
            guard !key.isEmpty else {
                onInvalid("intent-phrases: skipping row \(index): the phrase has no words")
                continue
            }
            guard !accepted.contains(key) else {
                onInvalid("intent-phrases: skipping row \(index): a duplicate phrase")
                continue
            }
            accepted.insert(key)
            phrases.append(
                PhraseIntentRow(phrase: row.phrase, providerID: row.providerID, toolID: row.toolID))
        }

        guard phrases.count <= maximumPhrases else {
            onInvalid(
                "intent-phrases: refusing \(phrases.count) phrases (cap \(maximumPhrases))")
            return .empty
        }
        return IntentPhraseFile(version: decoded.version, phrases: phrases)
    }

    // MARK: - The wire shapes

    private struct RowDTO: Codable {
        let phrase: String
        let providerID: String
        let toolID: String
    }

    private struct FileDTO: Encodable {
        let version: Int
        let phrases: [RowDTO]
    }

    /// One array element, judged alone: a row that does not decode as three strings is `nil`,
    /// never a thrown error that would sink the whole file.
    private struct LossyRow: Decodable {
        let row: RowDTO?

        init(from decoder: Decoder) throws {
            row = try? RowDTO(from: decoder)
        }
    }

    private struct LossyFileDTO: Decodable {
        let version: Int
        let phrases: [LossyRow]
    }

    // MARK: - The one naming convention this file owns

    /// The table's file name — the product's hand-editable surface.
    private static let fileName = "intent-phrases.json"

    /// The suffix of the temp file mid-commit — never readable, never loaded.
    private static let tempSuffix = ".tmp"
}

/// Why ``IntentPhraseStore/save(_:)`` refused — nothing was written.
public enum IntentPhraseStoreError: Error, Equatable {

    /// More than ``IntentPhraseStore/maximumPhrases`` rows were submitted.
    case tooManyPhrases(Int)

    /// More than ``IntentPhraseStore/maximumFileBytes`` of encoded bytes were produced.
    case fileTooLarge(Int)
}

/// The decoded phrase table — the file's value, not its bytes.
public struct IntentPhraseFile: Equatable, Sendable {

    /// The file format's version. This build reads `1`.
    public let version: Int

    /// The accepted rows, in the file's order.
    public let phrases: [PhraseIntentRow]

    /// No phrases — the file's empty spelling, and the answer to every refusal.
    public static let empty = IntentPhraseFile(version: 1, phrases: [])

    public init(version: Int = 1, phrases: [PhraseIntentRow]) {
        self.version = version
        self.phrases = phrases
    }
}
