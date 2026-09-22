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

/// The persisted shell command definitions — one byte-pinned JSON file, `shell-commands.json`,
/// under `<applicationSupport>/Vocca/` (`command-registry` spec, PRD R1 + Data Model).
///
/// ## Where this store came from
///
/// The wedge's P4 promise is "voice → run commands / drive MCP tools / coding agents"
/// (`ROADMAP.md:41`). The MCP leg exists; the **run commands** leg does not. Before a
/// `ShellProvider` can describe or invoke anything, the configured command definitions must
/// have a single source of truth — this store. No command exists unless it is configured here,
/// and nothing is configured out of the box: the default configuration cannot create a child,
/// and the D2 promise ("spawns no child process") stays true because there is no file to read
/// commands from.
///
/// ## What this file is not
///
/// It is not enablement and it is not argument storage: the file holds **definitions only**.
/// Enablement is membership in ``ActionConfigStore`` (providerID `dev.vocca.shell` + command
/// id), and argument values travel only at call time — the byte-pin in
/// `ShellCommandRegistryTests` asserts that no enablement or argument-value key can reach the
/// bytes, and a hand-edited file that grows one is refused rather than read.
///
/// ## The file is the memory
///
/// The store is deliberately **stateless**: ``load()`` reads the file on every call, and
/// ``save(_:)`` replaces it whole. Nothing is held between calls, so two store instances over
/// the same directory cannot disagree — the file is the only fact, and the cross-instance
/// acceptance is true by construction rather than by coordination. This is the
/// ``ActionConfigStore`` shape, including the atomic temp-write-then-rename commit: a crash
/// between the two steps leaves a `.tmp` that no reader reads, and ``load()`` creates nothing.
///
/// ## Failure is loud on the way in and on the way out
///
/// ``save(_:)`` **throws** when the registry cannot be persisted — the caps and every
/// file-system failure surface to the caller, because a registry the caller believes saved is a
/// command the user believes configured. ``load()`` is the opposite and tolerant by the same
/// reasoning: a corrupt or unreadable file is the **empty** registry with one loud log entry —
/// never a throw, and never a rewrite of the user's file. The `log` closure is the loud half,
/// injectable so the loudness is asserted rather than hoped.
///
/// ## Two tolerances, one policy
///
/// A file this build cannot decode at all — malformed bytes, an unknown key, a field of the
/// wrong type — is a file read wrongly, and the answer is the empty registry with **one** loud
/// log. A row that fails *validation* (a duplicate id, an empty argv, an over-long id, an
/// unnamed parameter) is a row the rest of the file can simply not include: it is skipped
/// loudly, one log per row, and the rest load — the enablement-row skip precedent. Both halves
/// are the same rule: the file is user-visible and hand-editable, and nothing about it may be
/// fatal or silent.
///
/// ## The caps refuse, they never clamp
///
/// More than ``maximumCommands`` commands or more than ``maximumFileBytes`` of encoded bytes is
/// refused loudly — a registry the store silently shrinks is a command the user believes
/// configured. The numbers are seeds, like the C2 store's caps — a retune is a reviewed edit.
public actor ShellCommandRegistry {

    /// The directory the file lives in.
    public let directory: URL

    /// How many commands the file may define. 64, a bound on how many children this process may
    /// ever be asked to launch from the shell surface — deliberately far below what any real
    /// user needs, and far above what the default configuration holds (zero).
    public static let maximumCommands = 64

    /// How many encoded bytes the file may hold. 64 KB, the bound on a hand-edited file's reach
    /// — the total size cap of the `command-registry` spec, seeded like the count cap.
    public static let maximumFileBytes = 64 * 1024

    /// How long a command id may be. 128, a bound on the id a confirmation card must render and
    /// an enablement row must repeat — a seed, like the caps.
    public static let maximumIDLength = 128

    /// How many elements a command's argv may hold. 64, a bound on the fixed argv a command may
    /// carry — a seed, like the caps.
    public static let maximumCommandElements = 64

    private let fileSystem: ActionConfigFileSystem
    private let log: @Sendable (String) -> Void

    /// A store over `directory`, keeping its registry in `shell-commands.json`.
    ///
    /// The `log` closure is the loud half of the tolerance policy: every refused file, every
    /// skipped row and every refused save goes through it, injectable so that the loudness is
    /// asserted rather than hoped.
    public init(
        directory: URL,
        fileSystem: ActionConfigFileSystem = DefaultActionConfigFileSystem(),
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "shell-commands").error("\($0)")
        }
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.log = log
    }

    /// Where a shipped install keeps the file, as a pure function of what the file system
    /// answered: `<applicationSupport>/Vocca`, or `<home>/Library/Application Support/Vocca`
    /// when Application Support could not be resolved — beside `action-config.json` and the
    /// other stores (PRD: "Application Support, the `ActionConfigStore` directory shape").
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

    /// The registry as the file holds it — **never throws**.
    ///
    /// An absent file is the empty registry (nothing is created, nothing is logged — absence is
    /// the normal first-launch state, not a failure). An unreadable or undecodable file is also
    /// the empty registry, with exactly one loud log entry naming why, and the file's bytes are
    /// never rewritten: "empty registry" is a reading, never a repair.
    public func load() async -> ShellCommandFile {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        guard await fileSystem.fileExists(atPath: fileURL.path) else { return .empty }
        guard let data = await fileSystem.read(fileURL) else {
            log("shell-commands: could not read \(fileURL.path); loading an empty registry")
            return .empty
        }
        return Self.decode(data, onInvalidElement: log) ?? .empty
    }

    // MARK: - Writing

    /// Persists `file` atomically, refusing what the file must not hold.
    ///
    /// - Throws: ``ShellCommandRegistryError`` when a cap is exceeded, or the file-system
    ///   failure when the commit cannot be made. The checks run **before** anything touches the
    ///   file system, so a refused save leaves the previously committed file byte-identical.
    public func save(_ file: ShellCommandFile) async throws {
        guard file.commands.count <= Self.maximumCommands else {
            log(
                "shell-commands: refusing \(file.commands.count) commands (cap "
                    + "\(Self.maximumCommands))")
            throw ShellCommandRegistryError.tooManyCommands(file.commands.count)
        }
        let data = try Self.encode(file)
        guard data.count <= Self.maximumFileBytes else {
            log(
                "shell-commands: refusing a file of \(data.count) bytes (cap "
                    + "\(Self.maximumFileBytes))")
            throw ShellCommandRegistryError.fileTooLarge(data.count)
        }

        try await fileSystem.createDirectory(at: directory)
        let temporaryURL = directory.appendingPathComponent(Self.fileName + Self.tempSuffix)
        let committedURL = directory.appendingPathComponent(Self.fileName)
        try await fileSystem.write(data, to: temporaryURL)
        try await fileSystem.moveItem(at: temporaryURL, to: committedURL)
    }

    // MARK: - The bytes

    /// Encode a registry the way ``save(_:)`` writes it: strict `JSONEncoder` with **sorted
    /// keys**, so the bytes are stable across calls and processes. A hand-editable, auditable
    /// file must not re-order itself between runs.
    public static func encode(_ file: ShellCommandFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    /// Decode a registry the way ``load()`` reads it: **static, pure, and never throwing.**
    ///
    /// Anything undecodable — malformed bytes, a missing field, an unknown key, a field of the
    /// wrong type — yields exactly one `onInvalidElement` call and `nil`. A row that fails
    /// validation (duplicate id, empty argv, over-long id, empty id, unnamed parameter) is
    /// skipped loudly, one call per row, and the rest of the file loads. A corrupt file must
    /// never be fatal, and a failed parse must never rewrite the user's file.
    public static func decode(
        _ data: Data, onInvalidElement: (String) -> Void
    ) -> ShellCommandFile? {
        do {
            let file = try JSONDecoder().decode(ShellCommandFile.self, from: data)
            return validated(file, onInvalidElement: onInvalidElement)
        } catch let error as ActionConfigDecodeError {
            onInvalidElement("shell-commands: refusing a file this build cannot read: \(error)")
            return nil
        } catch {
            onInvalidElement("shell-commands: refusing an unreadable shell-commands file")
            return nil
        }
    }

    // MARK: - Validation

    /// The row-level skip pass: a row the file would have to invent meaning for is dropped with
    /// its own loud complaint, and the rest load — the enablement-row skip precedent.
    ///
    /// The first **valid** occurrence of an id wins: a duplicate is only a duplicate of a row
    /// the file actually accepted, so an invalid first occurrence does not occupy the id.
    private static func validated(
        _ file: ShellCommandFile, onInvalidElement: (String) -> Void
    ) -> ShellCommandFile {
        var acceptedIDs = Set<String>()
        var commands: [ShellCommandDefinition] = []
        commands.reserveCapacity(file.commands.count)
        for row in file.commands {
            guard !row.id.isEmpty else {
                onInvalidElement("shell-commands: skipping a command with an empty id")
                continue
            }
            guard row.id.count <= Self.maximumIDLength else {
                onInvalidElement(
                    "shell-commands: skipping a command whose id exceeds "
                        + "\(Self.maximumIDLength) characters")
                continue
            }
            guard !acceptedIDs.contains(row.id) else {
                onInvalidElement("shell-commands: skipping a duplicate command id \"\(row.id)\"")
                continue
            }
            guard !row.command.isEmpty else {
                onInvalidElement("shell-commands: skipping a command with an empty argv")
                continue
            }
            guard row.command.count <= Self.maximumCommandElements else {
                onInvalidElement(
                    "shell-commands: skipping a command whose argv exceeds "
                        + "\(Self.maximumCommandElements) elements")
                continue
            }
            guard row.parameters.allSatisfy({ !$0.name.isEmpty }) else {
                onInvalidElement("shell-commands: skipping a command with an unnamed parameter")
                continue
            }
            acceptedIDs.insert(row.id)
            commands.append(row)
        }
        return ShellCommandFile(version: file.version, commands: commands)
    }

    // MARK: - The one naming convention this file owns

    /// The registry file's name — the committed name the atomic pair renames over.
    private static let fileName = "shell-commands.json"

    /// The suffix of the temp file mid-commit — never readable, never loaded.
    private static let tempSuffix = ".tmp"
}

/// What the registry store refuses to persist.
///
/// The contract is that a store which cannot save **throws**, and the caller surfaces it rather
/// than answering as if the registry had been written — a registry the caller believes saved is
/// a command the user believes configured.
public enum ShellCommandRegistryError: Error, Equatable {
    /// More than ``ShellCommandRegistry/maximumCommands`` commands were submitted. Carries the
    /// count, so the caller can tell the user what was refused.
    case tooManyCommands(Int)

    /// More than ``ShellCommandRegistry/maximumFileBytes`` of encoded bytes were submitted.
    /// Carries the byte count, so the caller can tell the user what was refused.
    case fileTooLarge(Int)
}

/// The file shape of `shell-commands.json` — the `version` and the `commands` array, and
/// nothing else (`command-registry` spec, PRD Data Model).
///
/// ## Strictness is the tolerance policy's other half
///
/// Decoding refuses **unknown keys** at every level of the shape: a file read with a field this
/// build cannot name is a file read wrongly, and the store's tolerance is *skip the file
/// loudly*, never *guess at its meaning* (the ``ActionConfig`` precedent). Tolerant decode and
/// strict shape are the same policy from two directions — corruption must never be fatal, and
/// drift must never be silently adopted.
///
/// ## The version is preserved, never gated
///
/// ``version`` round-trips as the file holds it. The shipped shape is version 1; a future
/// schema change is a reviewed edit to this type and its key scans, not a runtime decision —
/// an unknown key in a future file is already refused by the scan, which is the same wall the
/// version would have been.
public struct ShellCommandFile: Codable, Equatable, Sendable {
    /// The file shape's version, preserved as the file holds it (the shipped spelling is 1).
    public let version: Int

    /// The defined commands, at most ``ShellCommandRegistry/maximumCommands``.
    public let commands: [ShellCommandDefinition]

    /// Nothing configured — the file's empty spelling, and the answer to a corrupt file.
    public static let empty = ShellCommandFile(version: 1, commands: [])

    public init(version: Int = 1, commands: [ShellCommandDefinition]) {
        self.version = version
        self.commands = commands
    }

    /// Decodes a file, **refusing** one whose object carries a key this type does not define.
    ///
    /// The scan cannot run through `CodingKeys`: a `KeyedDecodingContainer` typed with a fixed
    /// `CodingKey` enum drops unknown keys before `allKeys` can see them (measured on this SDK
    /// in `ModelManifest`), so it runs through ``AnyStringKey`` — a key type that accepts every
    /// string — and asks which of the resulting keys `CodingKeys` cannot represent.
    public init(from decoder: Decoder) throws {
        try Self.rejectUnknownFields(in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.commands = try container.decode([ShellCommandDefinition].self, forKey: .commands)
    }

    private static func rejectUnknownFields(in decoder: Decoder) throws {
        let allKeys = try decoder.container(keyedBy: AnyStringKey.self)
        if let unknown = allKeys.allKeys.map(\.stringValue).first(where: {
            CodingKeys(stringValue: $0) == nil
        }) {
            throw ActionConfigDecodeError.unknownKey(unknown)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, commands
    }
}