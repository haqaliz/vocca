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

/// The persisted per-tool enablement and MCP server configuration — one byte-pinned JSON file,
/// `action-config.json`, under `<applicationSupport>/Vocca/` (`enablement-store` spec, PRD R1 +
/// R4).
///
/// ## The N1 lineage — where this store came from
///
/// `action-safety-spine` (C13 slice 1) deferred persisted per-tool enablement to "the slice
/// that introduces real tools to enable" (`action-safety-spine/prd.md:295-297`), and the
/// deferral is what this store lands: real tools exist (`MCPProvider`, `AuditActionProvider`),
/// and nothing persisted enablement or server configuration. Without it, M7's default-off is
/// forgettable every launch — the enablement set would have to be rebuilt by hand each run —
/// and a server configuration cannot exist at all.
///
/// ## What this file is not
///
/// It is not the audit log: it holds no sentence, no decision and no outcome, because it is not
/// a record of what a human approved — it is a record of what may act. **The raw argument blob
/// is never persisted**, the `ActionAuditEntry` precedent held from the other direction: the
/// audit log keeps the rendered sentence and never the wire dump, while this file keeps neither
/// — the enablement row is two identifiers, and the byte-pin in `ActionConfigStoreTests`
/// asserts that no transcript text, sentence or raw tool argument can reach the bytes.
///
/// ## The file is the memory
///
/// The store is deliberately **stateless**: ``load()`` and ``loadEnablement()`` read the file
/// on every call, and ``save(_:)`` replaces it whole. Nothing is held between calls, so two
/// store instances over the same directory cannot disagree — the file is the only fact, and
/// the cross-instance acceptance is true by construction rather than by coordination.
///
/// ## The write protocol is the audit store's
///
/// A save is the atomic temp-write-then-rename pair: `<file>.tmp` written, then renamed over
/// `<file>`. A crash between the two steps leaves a `.tmp` that no reader reads — the name is
/// the whole of the read side, so there is no such thing as a half-written config that loads as
/// truth. ``load()`` creates nothing: an absent file is the normal first-launch state, and the
/// directory does not exist until the first save.
///
/// ## Failure is loud on the way in and on the way out
///
/// ``save(_:)`` **throws** when the config cannot be persisted — the caps, the path rule and
/// every file-system failure surface to the caller, because a config the caller believes saved
/// is a server the user believes configured. ``load()`` is the opposite and tolerant by the
/// same reasoning: a corrupt or unreadable file is the **empty** config with one loud log
/// entry — never a throw, and never a rewrite of the user's file. The `log` closure is the
/// loud half, injectable so the loudness is asserted rather than hoped.
///
/// ## The caps refuse, they never clamp
///
/// More than ``maximumServers`` servers or ``maximumEnablementRows`` rows is refused loudly —
/// a config the store silently shrinks is a server the user believes configured.
public actor ActionConfigStore {

    /// The directory the file lives in.
    public let directory: URL

    /// How many servers the file may configure. 8, a bound on how many children this process
    /// may ever be asked to launch — the config cap, deliberately far below the audit log's.
    public static let maximumServers = 8

    /// How many enablement rows the file may hold. 512, the consent-store cap, for the same
    /// reason it has one: enablement is written on a path a user can drive as often as they
    /// like, and an unbounded file is an unbounded list.
    public static let maximumEnablementRows = 512

    private let fileSystem: ActionConfigFileSystem
    private let log: @Sendable (String) -> Void

    /// A store over `directory`, keeping its config in `action-config.json`.
    ///
    /// The `log` closure is the loud half of the tolerance policy: every refused file and every
    /// refused save goes through it, injectable so that the loudness is asserted rather than
    /// hoped.
    public init(
        directory: URL,
        fileSystem: ActionConfigFileSystem = DefaultActionConfigFileSystem(),
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "action-config").error("\($0)")
        }
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.log = log
    }

    /// Where a shipped install keeps the file, as a pure function of what the file system
    /// answered: `<applicationSupport>/Vocca`, or `<home>/Library/Application Support/Vocca`
    /// when Application Support could not be resolved — beside `actions/` and the other stores.
    ///
    /// Separated from any initializer because the fallback is otherwise unreachable in a test
    /// (`PersistentUsageStore`'s precedent): the only way to drive it through an initializer is
    /// a machine whose Application Support does not resolve, and the only way to check the
    /// resolved branch is to write into the developer's own.
    public static func defaultDirectory(applicationSupport: URL?, home: URL) -> URL {
        let base =
            applicationSupport ?? home.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Vocca")
    }

    // MARK: - Reading

    /// The config as the file holds it — **never throws**.
    ///
    /// An absent file is the empty config (nothing is created, nothing is logged — absence is
    /// the normal first-launch state, not a failure). An unreadable or undecodable file is also
    /// the empty config, with exactly one loud log entry naming why, and the file's bytes are
    /// never rewritten: "empty config" is a reading, never a repair.
    public func load() async -> ActionConfig {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        guard await fileSystem.fileExists(atPath: fileURL.path) else { return .empty }
        guard let data = await fileSystem.read(fileURL) else {
            log("action-config: could not read \(fileURL.path); loading an empty config")
            return .empty
        }
        return Self.decode(data, onInvalidElement: log) ?? .empty
    }

    /// The persisted rows as ``ActionEnablement`` membership — **absent is off**, by
    /// ``ActionEnablement``'s own semantics (PRD M7).
    ///
    /// Each row maps to exactly one ``ActionInvocation`` with **no arguments — always `nil`**:
    /// enablement is a fact about membership, and tool-call arguments travel only at call time.
    /// A row whose identifiers cannot construct an invocation (an empty id in a hand-edited
    /// file) is skipped rather than fatal — the same tolerance stale tool rows get, for the
    /// same reason: the file is user-visible and hand-editable, and one bad row must never
    /// cost the rest of the enablement. **Stale tool ids are tolerated, never pruned**: a tool
    /// a server no longer lists keeps its row, because this store is not the discoverer of
    /// tools (the Actions-tab aspect owns discovery) and a row for a tool that has temporarily
    /// vanished must survive the round trip — re-enabling a tool a server lists again must not
    /// require the user to re-enable it.
    public func loadEnablement() async -> ActionEnablement {
        let rows = await load().enablement
        var invocations: [ActionInvocation] = []
        invocations.reserveCapacity(rows.count)
        for row in rows {
            if let invocation = ActionInvocation(
                providerID: row.providerID, toolID: row.toolID)
            {
                invocations.append(invocation)
            }
        }
        return ActionEnablement(invocations)
    }

    // MARK: - Writing

    /// Persists `config` atomically, refusing what the file must not hold.
    ///
    /// - Throws: ``ActionConfigStoreError`` when the caps or the path rule are exceeded, or the
    ///   file-system failure when the commit cannot be made. The checks run **before** anything
    ///   touches the file system, so a refused save leaves no directory and no file behind.
    public func save(_ config: ActionConfig) async throws {
        guard config.servers.count <= Self.maximumServers else {
            log(
                "action-config: refusing \(config.servers.count) servers (cap "
                    + "\(Self.maximumServers))")
            throw ActionConfigStoreError.tooManyServers(config.servers.count)
        }
        guard config.enablement.count <= Self.maximumEnablementRows else {
            log(
                "action-config: refusing \(config.enablement.count) enablement rows (cap "
                    + "\(Self.maximumEnablementRows))")
            throw ActionConfigStoreError.tooManyEnablementRows(config.enablement.count)
        }
        guard config.servers.allSatisfy({ !$0.executablePath.isEmpty }) else {
            log("action-config: refusing a server with an empty executable path")
            throw ActionConfigStoreError.emptyExecutablePath
        }

        try await fileSystem.createDirectory(at: directory)
        let data = try Self.encode(config)
        let temporaryURL = directory.appendingPathComponent(Self.fileName + Self.tempSuffix)
        let committedURL = directory.appendingPathComponent(Self.fileName)
        try await fileSystem.write(data, to: temporaryURL)
        try await fileSystem.moveItem(at: temporaryURL, to: committedURL)
    }

    // MARK: - The bytes

    /// Encode a config the way ``save(_:)`` writes it: strict `JSONEncoder` with **sorted
    /// keys**, so the bytes are stable across calls and processes. A hand-editable, auditable
    /// file must not re-order itself between runs.
    public static func encode(_ config: ActionConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(config)
    }

    /// Decode a config the way ``load()`` reads it: **static, pure, and never throwing.**
    ///
    /// Anything undecodable — malformed bytes, a missing field, an unknown key — yields exactly
    /// one `onInvalidElement` call and `nil`. A corrupt file must never be fatal, and a failed
    /// parse must never rewrite the user's file.
    public static func decode(
        _ data: Data, onInvalidElement: (String) -> Void
    ) -> ActionConfig? {
        do {
            return try JSONDecoder().decode(ActionConfig.self, from: data)
        } catch let error as ActionConfigDecodeError {
            onInvalidElement("refusing a config this build cannot read: \(error)")
            return nil
        } catch {
            onInvalidElement("refusing an unreadable config file")
            return nil
        }
    }

    // MARK: - The one naming convention this file owns

    /// The config file's name — the committed name the atomic pair renames over.
    private static let fileName = "action-config.json"

    /// The suffix of the temp file mid-commit — never readable, never loaded.
    private static let tempSuffix = ".tmp"
}

/// What the config store refuses to persist.
///
/// The contract is that a store which cannot save **throws**, and the caller surfaces it rather
/// than answering as if the config had been written — a config the caller believes saved is a
/// server the user believes configured.
public enum ActionConfigStoreError: Error, Equatable {
    /// More than ``ActionConfigStore/maximumServers`` servers were submitted. Carries the
    /// count, so the caller can tell the user what was refused.
    case tooManyServers(Int)

    /// More than ``ActionConfigStore/maximumEnablementRows`` rows were submitted. Carries the
    /// count, so the caller can tell the user what was refused.
    case tooManyEnablementRows(Int)

    /// A server's `executablePath` is empty — a server without a path is not a server, and the
    /// stdio transport's absolute-path contract has no reading of "" that means anything.
    case emptyExecutablePath
}