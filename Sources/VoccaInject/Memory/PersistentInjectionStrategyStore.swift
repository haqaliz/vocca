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

/// **The strategy store's file-system seam — the one file in `VoccaInject` permitted to name
/// `FileManager` for the strategy store** (the strategy seam's entry in
/// `InjectionSeamBoundaryTests`' per-seam FileManager table, beside the journal seam's
/// `FileSystemJournalStore`).
///
/// Raw operations only, in the dictionary adapter's shape: directory creation, the atomic
/// temp-write-then-rename commit, and reads. Nothing here decides. Which element is corrupt,
/// what version is readable and when a save commits are ``PersistentInjectionStrategyStore``'s
/// questions, answered over this seam — a second `FileManager`-naming file in the module would
/// be a strategy-store decision that escaped the headless suite forever.
public protocol InjectionStrategyFileSystem: Sendable {
    /// Create `url` (and its parents), as `FileManager` would with
    /// `withIntermediateDirectories: true`.
    func createDirectory(at url: URL) async throws

    /// Write `data` to `url`.
    func write(_ data: Data, to url: URL) async throws

    /// Move the file at `source` over `destination` — the commit point of the atomic pair.
    /// Succeeds whether or not `destination` already exists: an overwrite is a replace, not a
    /// refusal.
    func moveItem(at source: URL, to destination: URL) async throws

    /// The file's bytes, or `nil` if it cannot be read.
    func read(_ url: URL) async -> Data?

    /// Whether a file exists at `path`.
    func fileExists(atPath path: String) async -> Bool
}

/// The seam's only `FileManager` implementation — translation with no decisions in it.
public struct DefaultInjectionStrategyFileSystem: InjectionStrategyFileSystem {
    public init() {}

    public func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    public func moveItem(at source: URL, to destination: URL) async throws {
        // The atomic replace, not `moveItem`: `FileManager.moveItem` refuses an existing
        // destination (NSFileWriteFileExistsError), which made every save after the first
        // fail once the file existed. `replaceItemAt` is the same rename-over commit and
        // succeeds whether or not the destination is there.
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
    }

    public func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    public func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// C8's strategy memory on disk — `<directory>/strategies.json` (`ARCHITECTURE.md:580` names
/// the file; `prd.md` R9), the `FileSystemDictionaryStore` shape exactly: atomic
/// temp-write→`replaceItemAt` commits, a tolerant load that never throws and never rewrites,
/// `.sortedKeys` byte-stable encodes, and an injected log.
///
/// ## Schema
///
/// The file is `{"version": 1, "strategies": [<InjectionStrategy>, ...]}` — a version field is
/// the honest mechanism for version-tolerance (X5): a file a future version wrote is skipped
/// loudly by this build, never mis-read. Each element is decoded through its own `JSONDecoder`,
/// so one bad entry skips, not the file. The privacy boundary is the schema's shape: bundle
/// IDs, `InjectionRung` raw values and integer epoch seconds only — no text, no transcripts
/// (`prd.md` "Privacy"). A save normalizes: unknown fields a hand-edit or a future version
/// added are not re-emitted.
///
/// ## Concurrency contract
///
/// Single process, one writer: `load()` once at launch (the custody-chain load, `prd.md` T-2),
/// then `update`/`save` mutate the held set and persist the **whole set** atomically — a racing
/// pair of updates ends with one complete file, and the in-memory set carries the other entry
/// forward to the next persist. The atomic rename means a concurrent read sees the old or the
/// new complete file, never a partial one. An actor is the honest Swift 6 shape for that
/// state, the ``LatencyLedger`` precedent.
///
/// ## The cap
///
/// ``update(_:)`` refuses — returns `false` and persists nothing — when at capacity and the
/// bundle ID is new; updates of known apps always succeed. Refusal, never eviction: a learned
/// strategy is the product of real dictations, and silently evicting one because 512 other
/// apps were tried into would unlearn what the memory exists to remember, invisibly. `load`
/// and `save` are uncapped — the file is user-owned, and reset-learned (R7) is the user's own
/// eviction mechanism.
public actor PersistentInjectionStrategyStore: InjectionStrategyStore {
    /// The directory the memory lives in. The file is always `<directory>/strategies.json`.
    public let directory: URL

    private let capacity: Int
    private let fileSystem: InjectionStrategyFileSystem
    private let log: @Sendable (String) -> Void
    private var held: [InjectionStrategy] = []

    /// A store over `directory`, remembering at most `capacity` apps (the learning cap,
    /// defaulting to the Core-owned constant). The directory is created on the first persist;
    /// a store over a directory that does not exist is an empty memory, not an error.
    ///
    /// The `log` closure is the loud half of the corruption policy: every skipped element and
    /// every unreadable file goes through it, injectable in tests so the loudness is asserted
    /// rather than hoped (`spec.md:120-122`).
    public init(
        directory: URL,
        capacity: Int = InjectionStrategyStoreConstants.maximumRememberedApps,
        fileSystem: InjectionStrategyFileSystem = DefaultInjectionStrategyFileSystem(),
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "strategy-memory").error("\($0)")
        }
    ) {
        self.directory = directory
        self.capacity = capacity
        self.fileSystem = fileSystem
        self.log = log
    }

    /// A store over the default location (`ARCHITECTURE.md:580`):
    /// `~/Library/Application Support/Vocca/strategies.json`. The fallback keeps the store
    /// working even if the Application Support directory is unavailable to resolve — a
    /// defensive default, not a decision about where the memory lives.
    public init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        self.init(directory: base.appendingPathComponent("Vocca"))
    }

    // MARK: - Encoding

    /// The versioned top-level container — this file's own private Codable shape.
    private struct StrategyFile: Codable {
        let version: Int
        let strategies: [InjectionStrategy]
    }

    /// Encode the strategies the way ``save(_:)`` writes them: strict `JSONEncoder` over the
    /// versioned wrapper with **sorted keys**, so the bytes are stable across calls and
    /// processes — a hand-editable, version-controllable file must not re-order itself between
    /// runs. In-memory strategies are trusted — a save only ever writes a state the app itself
    /// produced.
    public static func encode(_ strategies: [InjectionStrategy]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(StrategyFile(version: 1, strategies: strategies))
    }

    /// Decode the file the way ``load()`` reads it: version-tolerant top level, element-wise
    /// tolerant elements.
    ///
    /// The top level must be a JSON object whose `version` is exactly 1 — otherwise exactly one
    /// `onInvalidElement` call and an empty result, the version-tolerance (X5). Each element is
    /// then decoded as an ``InjectionStrategy`` through its own `JSONDecoder`; each element
    /// that fails yields exactly one `onInvalidElement` call and is skipped. Never throws — a
    /// corrupt file must never be fatal, and a failed parse must never rewrite the user's file.
    public static func decode(
        _ data: Data,
        onInvalidElement: @escaping @Sendable (String) -> Void
    ) -> [InjectionStrategy] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let file = object as? [String: Any]
        else {
            onInvalidElement(
                "strategy-memory: the file's top level is not a JSON object; loading an empty memory")
            return []
        }
        guard let version = file["version"] as? Int, version == 1 else {
            onInvalidElement(
                "strategy-memory: unknown strategies.json version; loading an empty memory")
            return []
        }
        guard let elements = file["strategies"] as? [Any] else {
            onInvalidElement(
                "strategy-memory: strategies.json holds no strategies list; loading an empty memory")
            return []
        }

        var strategies: [InjectionStrategy] = []
        for (index, element) in elements.enumerated() {
            guard JSONSerialization.isValidJSONObject(element),
                let elementData = try? JSONSerialization.data(withJSONObject: element),
                let strategy = try? JSONDecoder().decode(InjectionStrategy.self, from: elementData)
            else {
                onInvalidElement("strategy-memory: skipping invalid strategy at index \(index)")
                continue
            }
            strategies.append(strategy)
        }
        return strategies
    }

    // MARK: - Load, update, save

    /// The memory on disk, or the empty memory. Never throws and never writes: a missing file
    /// is `[]` silently; an unreadable file is one loud log and `[]`; corrupt elements are
    /// skipped with one loud log each. Replaces the held set and returns it.
    public func load() async -> [InjectionStrategy] {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        guard await fileSystem.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = await fileSystem.read(fileURL) else {
            log("strategy-memory: could not read \(fileURL.path); loading an empty memory")
            return []
        }
        let strategies = Self.decode(data, onInvalidElement: log)
        held = strategies
        return strategies
    }

    /// Upsert `strategy` by its bundle ID and persist the whole set atomically. A new app at
    /// capacity returns `false` and persists nothing — the refusal is policy at saturation, not
    /// an error. Updates of known apps always succeed. Throws on any persist failure — a
    /// failed save means the file was *not* updated while the held set says it was, and the
    /// caller (memory-order's recorder, in its detached task) must be able to see and log it.
    public func update(_ strategy: InjectionStrategy) async throws -> Bool {
        if let index = held.firstIndex(where: { $0.bundleID == strategy.bundleID }) {
            held[index] = strategy
        } else {
            guard held.count < capacity else { return false }
            held.append(strategy)
        }
        try await persist()
        return true
    }

    /// Replace the whole held set and persist it atomically — the reset-learned and future
    /// editing paths; uncapped.
    public func save(_ strategies: [InjectionStrategy]) async throws {
        held = strategies
        try await persist()
    }

    /// The atomic persist: create the directory, encode, temp-write `<dir>/strategies.json.tmp`,
    /// rename over `<dir>/strategies.json`. Throws on any failure — the caller must know the
    /// file was not updated.
    private func persist() async throws {
        try await fileSystem.createDirectory(at: directory)
        let data = try Self.encode(held)
        let tempURL = directory.appendingPathComponent(Self.fileName + Self.tempSuffix)
        let finalURL = directory.appendingPathComponent(Self.fileName)
        try await fileSystem.write(data, to: tempURL)
        try await fileSystem.moveItem(at: tempURL, to: finalURL)
    }

    // MARK: - The one naming convention this file owns

    /// The memory file's name (`ARCHITECTURE.md:580`).
    private static let fileName = "strategies.json"

    /// The suffix of the temp file mid-commit — never readable, never loaded.
    private static let tempSuffix = ".tmp"
}