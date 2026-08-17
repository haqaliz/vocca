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

/// **The dictionary's file-system seam — the one file in `VoccaText` permitted to name
/// `FileManager`** (the dictionary seam's entry in `InjectionSeamBoundaryTests`' per-seam
/// FileManager table, beside the journal seam's `FileSystemJournalStore`).
///
/// Raw operations only, in the journal adapter's shape: directory creation, the atomic
/// temp-write-then-rename commit, and reads. Nothing here decides. Which entry is corrupt,
/// what to skip and what order the rules are in are ``FileSystemDictionaryStore``'s questions,
/// answered over this seam — a second `FileManager`-naming file in the module would be a
/// dictionary decision that escaped the headless suite forever.
public protocol DictionaryFileSystem: Sendable {
    /// Create `url` (and its parents), as `FileManager` would with
    /// `withIntermediateDirectories: true`.
    func createDirectory(at url: URL) async throws

    /// Write `data` to `url`.
    func write(_ data: Data, to url: URL) async throws

    /// Move the file at `source` over `destination` — the commit point of the atomic pair.
    func moveItem(at source: URL, to destination: URL) async throws

    /// The file's bytes, or `nil` if it cannot be read.
    func read(_ url: URL) async -> Data?

    /// Whether a file exists at `path`.
    func fileExists(atPath path: String) async -> Bool
}

/// The seam's only `FileManager` implementation — translation with no decisions in it.
public struct DefaultDictionaryFileSystem: DictionaryFileSystem {
    public init() {}

    public func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    public func moveItem(at source: URL, to destination: URL) async throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    public func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// The user dictionary's persistence — `<directory>/dictionary.json`, the plain JSON array the
/// product's edit surface is (`ARCHITECTURE.md:549`): hand-editable, version-controllable, and
/// applied last, in declared order.
///
/// ## Concurrency contract
///
/// Single process, one writer: load once at session start (the rules engine reads the
/// dictionary via `CleanupContext`), and the first save path (the settings UI, P3) serializes
/// through its caller. An actor would serialize calls that are already safe by construction:
/// the atomic rename means a concurrent load sees either the old or the new committed file,
/// never a partial one.
///
/// ## Durability contract
///
/// ``save(_:)`` is exactly two events — write `<dir>/dictionary.json.tmp`, rename over
/// `<dir>/dictionary.json` — so a crash between them leaves a `.tmp` that ``load()`` never
/// reads, never a readable partial dictionary. ``load()`` never throws and never writes: a
/// missing file is an empty dictionary, a corrupt entry is skipped with one loud log, and a
/// failed parse never rewrites the user's file. **A save normalizes the file**: only the four
/// known fields of in-memory rules are written, and unknown fields a hand-edit or a future
/// version added are not re-emitted (`spec.md:141-144`).
public struct FileSystemDictionaryStore: Sendable {
    /// The directory the dictionary lives in. The file is always `<directory>/dictionary.json`.
    public let directory: URL

    private let fileSystem: DictionaryFileSystem
    private let log: @Sendable (String) -> Void

    /// A store over `directory`. The directory is created on the first save; a store over a
    /// directory that does not exist is an empty dictionary, not an error.
    ///
    /// The `log` closure is the loud half of the corruption policy: every skipped entry and
    /// every unreadable file goes through it, injectable in tests so the loudness is asserted
    /// rather than hoped (`spec.md:74-75`).
    public init(
        directory: URL,
        fileSystem: DictionaryFileSystem = DefaultDictionaryFileSystem(),
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "dictionary").error("\($0)")
        }
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.log = log
    }

    /// A store over the default location (`ARCHITECTURE.md:549`):
    /// `~/Library/Application Support/Vocca/dictionary.json`. The fallback keeps the store
    /// working even if the Application Support directory is unavailable to resolve — a
    /// defensive default, not a decision about where the dictionary lives.
    public init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        self.init(directory: base.appendingPathComponent("Vocca"))
    }

    // MARK: - Encoding

    /// Encode the rules the way ``save(_:)`` writes them: strict `JSONEncoder` over the whole
    /// array with **sorted keys**, so the bytes are stable across calls and processes — a
    /// hand-editable, version-controllable file must not re-order itself between runs
    /// (synthesized `Codable` containers are not key-order-stable on their own). In-memory
    /// rules are trusted — save only ever writes a state the app itself produced
    /// (`spec.md:72-74`).
    public static func encode(_ rules: [ReplacementRule]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(rules)
    }

    /// Decode the file the way ``load()`` reads it: element-wise tolerant.
    ///
    /// The top level is read as an untyped JSON array; each element is then decoded as a
    /// ``ReplacementRule`` (unknown keys skipped by stock `JSONDecoder` behavior). Each element
    /// that fails yields exactly one `onInvalidElement` call and is skipped; a top level that is
    /// not a JSON array yields exactly one call and an empty result. Never throws — a corrupt
    /// file must never be fatal, and a failed parse must never rewrite the user's file.
    public static func decode(
        _ data: Data,
        onInvalidElement: @escaping @Sendable (String) -> Void
    ) -> [ReplacementRule] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let elements = object as? [Any]
        else {
            onInvalidElement(
                "dictionary: the file's top level is not a JSON array; loading an empty dictionary")
            return []
        }

        var rules: [ReplacementRule] = []
        for (index, element) in elements.enumerated() {
            guard JSONSerialization.isValidJSONObject(element),
                let elementData = try? JSONSerialization.data(withJSONObject: element),
                let rule = try? JSONDecoder().decode(ReplacementRule.self, from: elementData)
            else {
                onInvalidElement("dictionary: skipping invalid entry at index \(index)")
                continue
            }
            rules.append(rule)
        }
        return rules
    }

    // MARK: - Load and save

    /// The dictionary on disk, or the empty dictionary. Never throws and never writes: a
    /// missing file is `[]` silently; an unreadable file is one loud log and `[]`; corrupt
    /// entries are skipped with one loud log each (`spec.md:70-75`).
    public func load() async -> [ReplacementRule] {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        guard await fileSystem.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = await fileSystem.read(fileURL) else {
            log("dictionary: could not read \(fileURL.path); loading an empty dictionary")
            return []
        }
        return Self.decode(data, onInvalidElement: log)
    }

    /// Write `rules` to disk atomically: create the directory, encode, temp-write
    /// `<dir>/dictionary.json.tmp`, rename over `<dir>/dictionary.json`. Throws on any failure —
    /// a failed save means the rules are not durable and the caller must know.
    public func save(_ rules: [ReplacementRule]) async throws {
        try await fileSystem.createDirectory(at: directory)
        let data = try Self.encode(rules)
        let tempURL = directory.appendingPathComponent(Self.fileName + Self.tempSuffix)
        let finalURL = directory.appendingPathComponent(Self.fileName)
        try await fileSystem.write(data, to: tempURL)
        try await fileSystem.moveItem(at: tempURL, to: finalURL)
    }

    // MARK: - The one naming convention this file owns

    /// The dictionary file's name — the product's hand-editable surface (`ARCHITECTURE.md:549`).
    private static let fileName = "dictionary.json"

    /// The suffix of the temp file mid-commit — never readable, never loaded.
    private static let tempSuffix = ".tmp"
}
