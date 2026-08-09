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

/// **The journal's file-system adapter — the one file in `VoccaInject` permitted to name
/// `FileManager`** (the journal seam's entry in `InjectionSeamBoundaryTests`' per-seam table).
///
/// Raw operations only, in the tap-adapter's shape: directory creation, the atomic
/// temp-write-then-rename commit, listing by name, removal. Nothing here decides. Which entry
/// is current, when the oldest is evicted and what release resolves are ``RecoveryJournal``'s
/// questions, answered over the ``JournalStore`` seam this file implements — a second
/// `FileManager`-naming file in the module would be a journal decision that escaped the
/// headless suite forever.
///
/// ## The write protocol is the durability contract's carrier
///
/// ``save(_:)`` writes `<id>.json.tmp` and renames it over `<id>.json`, and does not answer
/// before the rename — so a crash between the two steps leaves a `.tmp` file that ``load()``
/// and ``list()`` never see, never a readable partial entry. The protocol's shape is asserted
/// by the fake's recorded pair (`RecoveryJournalTests.testSaveIsAnAtomicTempWriteThenRenamePair`),
/// and the real store's behaviour is exercised against a real temp directory in the same file —
/// `FileManager` works in CI, so this adapter is tested, not merely linted.
///
/// Entries are named by their write ordinal, zero-padded so that lexicographic order is numeric
/// order: ``list()`` walks the directory once in name order, and the ascending order is the
/// eviction ordering ``RecoveryJournal`` relies on.
public struct FileSystemJournalStore: JournalStore {
    /// The directory the journal lives in. Entries are written and listed here.
    public let directory: URL

    /// A store over `directory`. The directory is created on the first save; a store over a
    /// directory that does not exist is an empty journal, not an error.
    public init(directory: URL) {
        self.directory = directory
    }

    /// A store over the default location (`ARCHITECTURE.md` §13):
    /// `~/Library/Application Support/Vocca/recovery/`. The fallback keeps the journal working
    /// even if the Application Support directory is unavailable to resolve — a defensive
    /// default, not a decision about where recovery belongs.
    public init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        self.init(directory: base.appendingPathComponent("Vocca/recovery"))
    }

    // MARK: - JournalStore

    public func save(_ entry: JournalEntry) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = Self.fileName(for: entry.id)
        let data = try JSONEncoder().encode(entry)
        let tempURL = directory.appendingPathComponent(name + Self.tempSuffix)
        let finalURL = directory.appendingPathComponent(name)
        try data.write(to: tempURL)
        try manager.moveItem(at: tempURL, to: finalURL)
    }

    public func load() async throws -> [JournalEntry] {
        var loaded: [JournalEntry] = []
        for id in try await list() {
            let url = directory.appendingPathComponent(Self.fileName(for: id))
            guard let data = try? Data(contentsOf: url),
                let entry = try? JSONDecoder().decode(JournalEntry.self, from: data)
            else {
                continue
            }
            loaded.append(entry)
        }
        return loaded
    }

    public func list() async throws -> [Int] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names
            .filter { $0.hasSuffix(Self.fileSuffix) }
            .compactMap { Int($0.dropLast(Self.fileSuffix.count)) }
            .sorted()
    }

    public func remove(id: Int) async throws {
        let url = directory.appendingPathComponent(Self.fileName(for: id))
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Idempotent removal: purging an entry that is already gone is a no-op, not an error.
        }
    }

    // MARK: - The one naming convention this file owns

    /// The width of the zero-padded ordinal — wide enough that lexicographic order is numeric
    /// order for any realistic journal lifetime.
    private static let nameDigitWidth = 8

    /// The suffix of a committed entry file.
    private static let fileSuffix = ".json"

    /// The suffix of a temp file mid-commit — never readable, never listable.
    private static let tempSuffix = ".tmp"

    private static func fileName(for id: Int) -> String {
        let digits = String(id)
        return String(repeating: "0", count: max(0, nameDigitWidth - digits.count))
            + digits + fileSuffix
    }
}
