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

/// **The audit log's file-system seam — the one file in `VoccaActions` permitted to name
/// `FileManager`** (the actions seam's entry in `InjectionSeamBoundaryTests`' per-seam FileManager
/// table, the `PersistentConsentStore` shape).
///
/// Raw operations only, in the consent adapter's shape: directory creation, the atomic
/// temp-write-then-rename commit, reads, a directory listing, and removal. **Nothing here
/// decides.** Which ordinal is next, which entry is corrupt, when the oldest is evicted and
/// whether a failure is loud are ``FileSystemActionAuditStore``'s questions, answered over this
/// seam — a second `FileManager`-naming file in the module would be an audit decision that escaped
/// the headless suite forever.
public protocol ActionAuditFileSystem: Sendable {
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

    /// The names in `path`, or `nil` if the directory could not be listed.
    ///
    /// `nil` and `[]` are different answers and the store treats them differently: an empty
    /// directory is an empty log, while a directory that cannot be listed is a log whose next
    /// ordinal is unknowable — and minting one anyway would overwrite history.
    func contentsOfDirectory(atPath path: String) async -> [String]?

    /// Remove the file at `url`. Removing one that is already gone is a no-op, not an error.
    func removeItem(at url: URL) async throws
}

/// The seam's only `FileManager` implementation — translation with no decisions in it.
public struct DefaultActionAuditFileSystem: ActionAuditFileSystem {
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

    public func contentsOfDirectory(atPath path: String) async -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    public func removeItem(at url: URL) async throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Idempotent removal: purging an entry that is already gone is a no-op, not an error
            // — the journal adapter's rule, for the same reason (an eviction racing a hand
            // deletion must not fail the write that triggered it).
        }
    }
}
