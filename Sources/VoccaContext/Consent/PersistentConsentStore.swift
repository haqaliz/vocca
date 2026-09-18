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

/// **The consent store's file-system seam — the one file in `VoccaContext` permitted to name
/// `FileManager`** (the consent seam's entry in `InjectionSeamBoundaryTests`' per-seam
/// FileManager table, the `PersistentInjectionStrategyStore` shape).
///
/// Raw operations only, in the strategy adapter's shape: directory creation, the atomic
/// temp-write-then-rename commit, and reads. Nothing here decides. Which entry is corrupt,
/// what version is readable and when a save commits are ``PersistentConsentStore``'s
/// questions, answered over this seam — a second `FileManager`-naming file in the module would
/// be a consent decision that escaped the headless suite forever.
public protocol ConsentFileSystem: Sendable {
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
public struct DefaultConsentFileSystem: ConsentFileSystem {
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

/// Per-app context consent on disk — `<directory>/context-consent.json` (the PRD's M3/M4
/// reading, `prd.md:76-85`; `understanding.md:97-99`), the `PersistentInjectionStrategyStore`
/// shape exactly: atomic temp-write→`replaceItemAt` commits, a tolerant load that never throws
/// and never rewrites, `.sortedKeys` byte-stable encodes, and an injected log.
///
/// ## Schema
///
/// The file is `{"version": 1, "consent": ["<bundle ID>", ...]}` — a version field is the
/// honest mechanism for version-tolerance: a file a future version wrote is skipped loudly by
/// this build, never mis-read. Each entry is validated through ``ConsentBundleID.isValid``, so
/// one bad entry skips, not the file. **The privacy boundary is the schema's shape: bundle IDs
/// only — no transcript text, no selection text, no wall-clock timestamps reach the file**
/// (`prd.md` M10; the byte-level pin asserts it on the artifact). The array is written sorted,
/// so the bytes are stable across calls and processes — a hand-editable, auditable file must
/// not re-order itself between runs.
///
/// ## Concurrency contract
///
/// Single process, one writer: `load()` once at launch, then `set`/`save` mutate the held set
/// and persist the **whole set** atomically — a racing pair of updates ends with one complete
/// file, and the in-memory set carries the other entry forward to the next persist. The atomic
/// rename means a concurrent read sees the old or the new complete file, never a partial one.
/// An actor is the honest Swift 6 shape for that state, the ``LatencyLedger`` precedent.
///
/// ## The cap
///
/// ``set(_:consented:)`` refuses — returns `false` and persists nothing — when at capacity and
/// the bundle ID is new; updates of known apps always succeed, and a revoke
/// (`consented: false`) always succeeds. Refusal, never eviction: consent is a user decision,
/// and silently evicting one app because 512 others were tried into would un-consent the user
/// invisibly. `load` and `save` are uncapped — the file is user-owned, and the Apps tab is the
/// user's own editing mechanism.
public actor PersistentConsentStore: ConsentStore {
    /// The directory the consent lives in. The file is always `<directory>/context-consent.json`.
    public let directory: URL

    private let capacity: Int
    private let fileSystem: ConsentFileSystem
    private let log: @Sendable (String) -> Void
    private var held: Set<String> = []

    /// A store over `directory`, consenting at most `capacity` apps (defaulting to the
    /// Core-owned constant). The directory is created on the first persist; a store over a
    /// directory that does not exist is an empty consent, not an error.
    ///
    /// The `log` closure is the loud half of the corruption policy: every skipped entry, every
    /// unreadable file and every refusal goes through it, injectable in tests so the loudness
    /// is asserted rather than hoped.
    public init(
        directory: URL,
        capacity: Int = ConsentStoreConstants.maximumConsentedApps,
        fileSystem: ConsentFileSystem = DefaultConsentFileSystem(),
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "context-consent").error("\($0)")
        }
    ) {
        self.directory = directory
        self.capacity = capacity
        self.fileSystem = fileSystem
        self.log = log
    }

    // MARK: - Encoding

    /// The versioned top-level container — this file's own private Codable shape.
    private struct ConsentFile: Codable {
        let version: Int
        let consent: [String]
    }

    /// Encode the consent the way ``save(_:)`` writes it: strict `JSONEncoder` over the
    /// versioned wrapper with **sorted keys** and the array itself sorted, so the bytes are
    /// stable across calls and processes — a hand-editable, auditable file must not re-order
    /// itself between runs. In-memory consent is trusted — a save only ever writes bundle IDs
    /// the store itself validated.
    public static func encode(_ ids: Set<String>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ConsentFile(version: 1, consent: ids.sorted()))
    }

    /// Decode the file the way ``load()`` reads it: version-tolerant top level,
    /// validation-tolerant entries.
    ///
    /// The top level must be a JSON object whose `version` is exactly 1 — otherwise exactly
    /// one `onInvalidElement` call and an empty result, the version-tolerance. Each entry is
    /// then validated through ``ConsentBundleID.isValid``; each entry that fails yields exactly
    /// one `onInvalidElement` call and is skipped. Never throws — a corrupt file must never be
    /// fatal, and a failed parse must never rewrite the user's file.
    public static func decode(
        _ data: Data,
        onInvalidElement: @escaping @Sendable (String) -> Void
    ) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let file = object as? [String: Any]
        else {
            onInvalidElement(
                "context-consent: the file's top level is not a JSON object; loading an empty consent")
            return []
        }
        guard let version = file["version"] as? Int, version == 1 else {
            onInvalidElement(
                "context-consent: unknown context-consent.json version; loading an empty consent")
            return []
        }
        guard let elements = file["consent"] as? [Any] else {
            onInvalidElement(
                "context-consent: context-consent.json holds no consent list; loading an empty consent")
            return []
        }

        var consented: Set<String> = []
        for (index, element) in elements.enumerated() {
            guard let bundleID = element as? String, ConsentBundleID.isValid(bundleID) else {
                onInvalidElement("context-consent: skipping invalid consent entry at index \(index)")
                continue
            }
            consented.insert(bundleID)
        }
        return consented
    }

    // MARK: - Load, set, save

    /// The consent on disk, or the empty consent. Never throws and never writes: a missing file
    /// is `[]` silently; an unreadable file is one loud log and `[]`; invalid entries are
    /// skipped with one loud log each. Replaces the held set and returns it.
    public func load() async -> Set<String> {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        guard await fileSystem.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = await fileSystem.read(fileURL) else {
            log("context-consent: could not read \(fileURL.path); loading an empty consent")
            return []
        }
        let consented = Self.decode(data, onInvalidElement: log)
        held = consented
        return consented
    }

    /// Upsert `bundleID` into the held consent (`consented: true`) or remove it
    /// (`consented: false`) and persist the whole set atomically.
    ///
    /// A string that is not a bundle ID — and a new app at capacity — returns `false` and
    /// persists nothing: the refusal is the privacy boundary and the saturation policy, not an
    /// error. Updates of known apps always succeed. Throws on any persist failure — a failed
    /// save means the file was *not* updated while the held set says it was, and the caller
    /// must be able to see and log it.
    public func set(_ bundleID: String, consented: Bool) async throws -> Bool {
        guard ConsentBundleID.isValid(bundleID) else {
            log("context-consent: refusing a non-bundle-ID consent entry")
            return false
        }
        if consented {
            guard held.contains(bundleID) || held.count < capacity else { return false }
            held.insert(bundleID)
        } else {
            held.remove(bundleID)
        }
        try await persist()
        return true
    }

    /// Replace the whole held set and persist it atomically — the future Apps-tab editing
    /// path; uncapped.
    public func save(_ ids: Set<String>) async throws {
        held = ids
        try await persist()
    }

    /// The atomic persist: create the directory, encode, temp-write
    /// `<dir>/context-consent.json.tmp`, rename over `<dir>/context-consent.json`. Throws on
    /// any failure — the caller must know the file was not updated.
    private func persist() async throws {
        try await fileSystem.createDirectory(at: directory)
        let data = try Self.encode(held)
        let tempURL = directory.appendingPathComponent(Self.fileName + Self.tempSuffix)
        let finalURL = directory.appendingPathComponent(Self.fileName)
        try await fileSystem.write(data, to: tempURL)
        try await fileSystem.moveItem(at: tempURL, to: finalURL)
    }

    // MARK: - The one naming convention this file owns

    /// The consent file's name.
    private static let fileName = "context-consent.json"

    /// The suffix of the temp file mid-commit — never readable, never loaded.
    private static let tempSuffix = ".tmp"
}