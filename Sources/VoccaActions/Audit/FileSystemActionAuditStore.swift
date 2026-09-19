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

/// The local audit log — every action the gate decided on, on disk, reconstructible
/// (`action-safety-spine` PRD M6/G3, C13's third acceptance leg).
///
/// ## Append-only is by directory, never by file mode
///
/// Nothing in this repository appends to a file, and this store does not start. One file per
/// event, named by a zero-padded 8-digit write ordinal so that lexicographic order **is** numeric
/// order, committed as a `.tmp` write renamed over the final name — ``FileSystemJournalStore``'s
/// protocol, whole. The shape is what makes durability cheap: a crash between the write and the
/// rename leaves a file whose *name* excludes it from every read, so there is no such thing as a
/// half-written entry that loads as truth.
///
/// ## The ordinal is a fact about the directory
///
/// Nothing counts in memory. Each ``record(_:decision:at:)`` reads the committed ordinals and
/// takes the next one, so a store constructed after a relaunch continues where the last one
/// stopped — the journal's rule, and the only form of it that survives a process that died between
/// two actions. Eviction only ever removes the oldest, so the largest ordinal on disk is always
/// the last one written.
///
/// ## Eviction happens on write
///
/// The cap is a fact about the directory, not about a reader. A store that evicted in `load()`
/// would let a user's disk grow without bound while every reader looked correct, and the growth
/// would be invisible until someone went and looked.
///
/// ## Failure is loud
///
/// ``record(_:decision:at:)`` throws when the directory cannot be made, cannot be listed, or the
/// commit fails. **An audit log that silently loses entries is worse than none**: it reports a
/// clean history of an action that happened. Reads are the opposite and tolerant by the same
/// reasoning — one corrupt file must never cost the rest of the log — so ``load()`` and ``list()``
/// never throw, and every skip goes through the injected log.
public actor FileSystemActionAuditStore {

    /// The directory the log lives in. One file per entry, no index.
    public let directory: URL

    private let capacity: Int
    private let fileSystem: ActionAuditFileSystem
    private let log: @Sendable (String) -> Void

    /// How many entries the directory keeps before the oldest is evicted.
    ///
    /// Bounded rather than unbounded because the log is written on a path a user can drive as
    /// often as they like. Oldest-first, because the recent past is what a person opens an audit
    /// log to read.
    public static let defaultCapacity = 512

    /// A store over `directory`, keeping at most `capacity` entries.
    ///
    /// The directory is created on the first record; a store over a directory that does not exist
    /// is an empty log, not an error.
    ///
    /// The `log` closure is the loud half of the tolerance policy: every skipped entry and every
    /// unreadable file goes through it, injectable so that the loudness is asserted rather than
    /// hoped. `capacity` is clamped to at least one — a zero-capacity log would evict the entry it
    /// had just been asked to keep, which is a configuration mistake the store should survive
    /// rather than obey.
    public init(
        directory: URL,
        capacity: Int = FileSystemActionAuditStore.defaultCapacity,
        fileSystem: ActionAuditFileSystem = DefaultActionAuditFileSystem(),
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "action-audit").error("\($0)")
        }
    ) {
        self.directory = directory
        self.capacity = max(1, capacity)
        self.fileSystem = fileSystem
        self.log = log
    }

    /// Where a shipped install keeps the log, as a pure function of what the file system answered:
    /// `<applicationSupport>/Vocca/actions`, or `<home>/Library/Application Support/Vocca/actions`
    /// when Application Support could not be resolved — `actions/` beside `recovery/`.
    ///
    /// Separated from any initializer because the fallback is otherwise unreachable in a test
    /// (`PersistentUsageStore`'s precedent): the only way to drive it through an initializer is a
    /// machine whose Application Support does not resolve, and the only way to check the resolved
    /// branch is to write into the developer's own.
    public static func defaultDirectory(applicationSupport: URL?, home: URL) -> URL {
        let base =
            applicationSupport ?? home.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Vocca").appendingPathComponent("actions")
    }

    // MARK: - Writing

    /// Records what the gate decided about `invocation`, and returns the entry as it was written.
    ///
    /// - Parameters:
    ///   - invocation: What was submitted.
    ///   - decision: What ``ActionGate`` decided. The whole of it — a refusal is an event the log
    ///     exists to hold, not an absence of one.
    ///   - instant: A monotonic reading. The store owns no clock: `VoccaCore` bans
    ///     `Foundation.Date` and the modules that own a `MonotonicClock` conformance are adapters
    ///     this one may not import, so the caller supplies the reading and the contract that it is
    ///     monotonic travels with it.
    /// - Returns: The committed entry, including the ordinal it was given.
    /// - Throws: When the directory cannot be created or listed, when encoding fails, or when the
    ///   commit fails. Every one of those means the record was **not** made, and a caller that
    ///   cannot tell is a caller that will report a clean history of an action that happened.
    @discardableResult
    public func record(
        _ invocation: ActionInvocation, decision: ActionDecision, at instant: Duration
    ) async throws -> ActionAuditEntry {
        try await fileSystem.createDirectory(at: directory)
        guard let committed = await committedOrdinals() else {
            throw ActionAuditStoreError.directoryUnreadable(directory.path)
        }

        let id = (committed.last ?? 0) + 1
        let entry = ActionAuditEntry(
            id: id, instant: instant, invocation: invocation, decision: decision)
        let name = Self.fileName(for: id)
        let temporaryURL = directory.appendingPathComponent(name + Self.tempSuffix)
        let committedURL = directory.appendingPathComponent(name)
        try await fileSystem.write(try Self.encode(entry), to: temporaryURL)
        try await fileSystem.moveItem(at: temporaryURL, to: committedURL)

        try await evictOldest(from: committed + [id])
        return entry
    }

    /// Removes every committed entry. The directory itself stays.
    public func clear() async throws {
        for id in await list() {
            try await fileSystem.removeItem(
                at: directory.appendingPathComponent(Self.fileName(for: id)))
        }
    }

    /// Oldest-first eviction, by ordinal, at the moment of writing.
    private func evictOldest(from ordinals: [Int]) async throws {
        let surplus = ordinals.count - capacity
        guard surplus > 0 else { return }
        for id in ordinals.sorted().prefix(surplus) {
            try await fileSystem.removeItem(
                at: directory.appendingPathComponent(Self.fileName(for: id)))
        }
    }

    // MARK: - Reading

    /// Every readable entry, oldest first. Never throws.
    ///
    /// Unreadable and undecodable entries are skipped with one loud log each — a log must never
    /// block on one bad file, and never lose the rest because of it.
    public func load() async -> [ActionAuditEntry] {
        var entries: [ActionAuditEntry] = []
        for id in await list() {
            let name = Self.fileName(for: id)
            guard let data = await fileSystem.read(directory.appendingPathComponent(name)) else {
                log("action-audit: could not read \(name); skipping it")
                continue
            }
            let emit = log
            guard
                let entry = Self.decode(
                    data, onInvalidElement: { emit("action-audit: \(name): \($0)") })
            else {
                continue
            }
            entries.append(entry)
        }
        return entries
    }

    /// The write ordinals of every committed entry, ascending. Never throws: a directory that does
    /// not exist, or cannot be listed, is an empty log to a *reader*. A writer is told the
    /// difference — see ``record(_:decision:at:)``.
    public func list() async -> [Int] {
        await committedOrdinals() ?? []
    }

    /// The committed ordinals, or `nil` when the directory could not be listed at all.
    ///
    /// A `.tmp` file is excluded by its name, which is the whole of the atomic protocol's read
    /// side: an uncommitted write is invisible to every reader and reserves no ordinal.
    private func committedOrdinals() async -> [Int]? {
        guard let names = await fileSystem.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        return
            names
            .filter { $0.hasSuffix(Self.fileSuffix) }
            .compactMap { Int($0.dropLast(Self.fileSuffix.count)) }
            .sorted()
    }

    // MARK: - The bytes

    /// Encode an entry the way ``record(_:decision:at:)`` writes it: strict `JSONEncoder` with
    /// **sorted keys**, so the bytes are stable across calls and processes. A hand-editable,
    /// auditable file must not re-order itself between runs.
    public static func encode(_ entry: ActionAuditEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(entry)
    }

    /// Decode one entry the way ``load()`` reads it: **static, pure, and never throwing.**
    ///
    /// Anything undecodable — malformed bytes, a missing field, a vocabulary this build cannot
    /// name — yields exactly one `onInvalidElement` call and `nil`. A corrupt file must never be
    /// fatal, and a failed parse must never rewrite the user's file.
    public static func decode(
        _ data: Data, onInvalidElement: (String) -> Void
    ) -> ActionAuditEntry? {
        do {
            return try JSONDecoder().decode(ActionAuditEntry.self, from: data)
        } catch let error as ActionAuditEntryError {
            onInvalidElement("skipping an entry this build cannot read: \(error)")
            return nil
        } catch {
            onInvalidElement("skipping an unreadable entry")
            return nil
        }
    }

    // MARK: - The one naming convention this file owns

    /// The width of the zero-padded ordinal — wide enough that lexicographic order is numeric
    /// order for any realistic log lifetime.
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

/// What the audit store cannot do.
///
/// The contract is that a store which cannot commit **throws**, and the caller surfaces it rather
/// than answering as if the action had been recorded.
public enum ActionAuditStoreError: Error, Equatable {
    /// The directory exists, or was created, and still could not be listed — so the next ordinal
    /// is unknowable. Minting one anyway would overwrite an entry already on disk, which is the
    /// one thing an append-only log may never do.
    case directoryUnreadable(String)
}
