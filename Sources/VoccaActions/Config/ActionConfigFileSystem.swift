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

/// **The config store's file-system seam — the second file in `VoccaActions` permitted to name
/// `FileManager`** (the actions seam's second row in `InjectionSeamBoundaryTests`' per-seam
/// FileManager table).
///
/// The audit store's seam (`ActionAuditFileSystem`) is deliberately **not** widened: a seam is
/// a module's single file-system surface per concern, and the audit log's protocol (ordinals,
/// directory listing, idempotent removal) is the audit's vocabulary, not the config's. This
/// seam is the consent adapter's shape instead — raw operations only: directory creation, the
/// atomic temp-write-then-rename commit, reads, and an existence check. **Nothing here
/// decides.** Which caps apply, which bytes are refused, whether a failure is loud and what an
/// absent file means are ``ActionConfigStore``'s questions, answered over this seam — a second
/// `FileManager`-naming file in the module beyond the two seams would be a config decision that
/// escaped the headless suite forever.
public protocol ActionConfigFileSystem: Sendable {
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
public struct DefaultActionConfigFileSystem: ActionConfigFileSystem {
    public init() {}

    public func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    public func moveItem(at source: URL, to destination: URL) async throws {
        // The atomic replace, not `moveItem`: `FileManager.moveItem` refuses an existing
        // destination (NSFileWriteFileExistsError), which made every save after the first fail
        // once the file existed — a bug this tree has already paid for twice
        // (`PersistentConsentStore:61-65`). `replaceItemAt` is the same rename-over commit and
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