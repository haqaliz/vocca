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
}

/// The cleanup config's persistence — `<directory>/cleanup-config.json`, the hand-edited file
/// the product's opt-in mechanism is until the Cleanup tab ships (`prd.md` M7).
///
/// ## Load-only
///
/// There is no save path: the future settings surface writes this same file (`prd.md` M7 — "no
/// other write path exists"), and an untested-by-consumer save API would be pretend-fidelity
/// (`spec.md:98-100`). The store reads; the file is never rewritten — a corrupt file degrades
/// loudly and stays byte-for-byte what the user hand-wrote.
///
/// ## Concurrency contract
///
/// Single process, read-once at launch: the resolver calls ``load()`` at most once, and the
/// in-flight guard makes a concurrent second call share it. A plain struct over the injected
/// seam — no actor needed for a single atomic read.
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

    // MARK: - The one naming convention this file owns

    /// The config file's name — the product's hand-edited opt-in surface (`prd.md` M7).
    private static let fileName = "cleanup-config.json"
}
