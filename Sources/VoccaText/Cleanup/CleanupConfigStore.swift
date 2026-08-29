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

/// **The cleanup config's file-system seam — the one file in `VoccaText` permitted to name
/// `FileManager` for the config store** (the config seam's entry in
/// `InjectionSeamBoundaryTests`' per-seam FileManager table, beside the dictionary seam's
/// `FileSystemDictionaryStore`).
///
/// Raw operations only, in the dictionary adapter's shape — and deliberately just the two a
/// load-only store needs: existence and read. Nothing here decides. Which entry is invalid, what
/// degrades and what stays silent are ``CleanupConfig``'s questions, answered over this seam —
/// a second `FileManager`-naming file in the module would be a config decision that escaped the
/// headless suite forever.
public protocol CleanupConfigFileSystem: Sendable {
    /// Whether a file exists at `path`.
    func fileExists(atPath path: String) async -> Bool

    /// The file's bytes, or `nil` if it cannot be read.
    func read(_ url: URL) async -> Data?

    /// Create `url` (and its parents), as `FileManager` would with
    /// `withIntermediateDirectories: true`.
    func createDirectory(at url: URL) async throws

    /// Write `data` to `url`.
    func write(_ data: Data, to url: URL) async throws

    /// Move the file at `source` over `destination` — the commit point of the atomic pair.
    /// Succeeds whether or not `destination` already exists: an overwrite is a replace, not a
    /// refusal.
    func moveItem(at source: URL, to destination: URL) async throws
}

/// The seam's only `FileManager` implementation — translation with no decisions in it.
public struct DefaultCleanupConfigFileSystem: CleanupConfigFileSystem {
    public init() {}

    public func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    public func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    public func moveItem(at source: URL, to destination: URL) async throws {
        // `replaceItemAt`, not `moveItem`, for the reason the dictionary seam records
        // (`DefaultDictionaryFileSystem.moveItem(at:to:)`): `FileManager.moveItem` refuses an
        // existing destination, which would make every save after the first one fail once
        // `cleanup-config.json` existed — and the *second* save is the one that switches a user
        // away from a cloud rung.
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
    }
}

/// The cleanup config's persistence — `<directory>/cleanup-config.json`, the hand-edited file
/// the product's opt-in mechanism is until the Cleanup tab ships (`prd.md` M7).
///
/// ## The save path, and the surface it waited for
///
/// The store shipped **load-only** on purpose: the write path was to arrive with the settings
/// surface that consumes it, because an untested-by-consumer save API would be pretend-fidelity
/// (`spec.md:98-100`). The Cleanup tab is that surface, so ``save(_:)`` is here now — writing the
/// same file the resolver reads, never a second copy that can drift from it.
///
/// **A failed *load* still never writes.** A corrupt file degrades loudly and stays byte-for-byte
/// what the user hand-wrote; only an explicit ``save(_:)`` ever replaces it, and it does so
/// atomically, so a failure at either step leaves the committed file untouched.
///
/// **The file stays hand-editable**, because that is still a supported path: sorted keys,
/// pretty-printed, and slashes unescaped, so a person opening it in an editor finds what they
/// wrote rather than one line of escaped JSON.
///
/// **The BYOK key is never here.** It lives in the Keychain behind the `KeyProvider` seam, and
/// this is a plain file in Application Support a user is invited to open — the config carries an
/// endpoint and a model, and `CleanupConfigStoreTests` asserts the absence rather than trusting
/// the type not to grow a field.
///
/// ## Concurrency contract
///
/// Single process, read-once at launch: the resolver calls ``load()`` at most once, and the
/// in-flight guard makes a concurrent second call share it. Writes come from the settings window
/// and are serialized by the main actor it runs on. A plain struct over the injected seam — no
/// actor needed for a single atomic read and a rename-over commit, which a concurrent load sees
/// as either the old file or the new one, never a partial one.
public struct CleanupConfigStore: Sendable {
    /// The directory the config lives in. The file is always `<directory>/cleanup-config.json`.
    public let directory: URL

    private let fileSystem: CleanupConfigFileSystem
    private let log: @Sendable (String) -> Void

    /// A store over `directory`. A directory that does not exist is the default config, not an
    /// error.
    ///
    /// The `log` closure is the loud half of the degrade policy: every invalid file goes through
    /// it, injectable in tests so the loudness is asserted rather than hoped (`spec.md:52-54`).
    public init(
        directory: URL,
        fileSystem: CleanupConfigFileSystem = DefaultCleanupConfigFileSystem(),
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "cleanup-config").error("\($0)")
        }
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.log = log
    }

    /// A store over the default location (`prd.md` Data Model):
    /// `~/Library/Application Support/Vocca/cleanup-config.json`. The fallback keeps the store
    /// working even if the Application Support directory is unavailable to resolve — a defensive
    /// default, not a decision about where the config lives.
    public init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        self.init(directory: base.appendingPathComponent("Vocca"))
    }

    // MARK: - Load

    /// The config on disk, or the default. Never throws and never writes: a missing file is the
    /// default silently (`spec.md:52`); an unreadable or corrupt file is the default with one
    /// loud log, and the file is never rewritten (`spec.md:55-57`).
    public func load() async -> CleanupConfig {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        guard await fileSystem.fileExists(atPath: fileURL.path) else { return .defaultConfig }
        guard let data = await fileSystem.read(fileURL) else {
            log("cleanup-config: could not read \(fileURL.path); using the rules provider")
            return .defaultConfig
        }
        return CleanupConfig.tolerantDecode(data, log: log)
    }

    // MARK: - Save

    /// Write `config` to disk atomically: create the directory, encode, temp-write
    /// `<dir>/cleanup-config.json.tmp`, rename over `<dir>/cleanup-config.json` — the
    /// `FileSystemDictionaryStore.save(_:)` idiom, for the same reason.
    ///
    /// Throws on any failure. A cleanup choice that silently failed to save is one the user makes
    /// again next launch having been told it worked — and on the cloud rung that is the difference
    /// between a person believing their text stays on the Mac and it not.
    public func save(_ config: CleanupConfig) async throws {
        try await fileSystem.createDirectory(at: directory)
        let data = try config.encoded()
        let tempURL = directory.appendingPathComponent(Self.fileName + Self.tempSuffix)
        let finalURL = directory.appendingPathComponent(Self.fileName)
        try await fileSystem.write(data, to: tempURL)
        try await fileSystem.moveItem(at: tempURL, to: finalURL)
    }

    // MARK: - The one naming convention this file owns

    /// The config file's name — the product's hand-edited opt-in surface (`prd.md` M7), and now
    /// the Cleanup tab's write target too.
    private static let fileName = "cleanup-config.json"

    /// The suffix of the temp file mid-commit — never readable, never loaded.
    private static let tempSuffix = ".tmp"
}
