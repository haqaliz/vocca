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

/// The persisted coding agent definitions — one byte-pinned JSON file, `coding-agents.json`,
/// under `<applicationSupport>/Vocca/` (`agent-registry` spec, PRD R1 + Data Model).
///
/// ## Where this store came from
///
/// The wedge's P4 promise is "voice → run commands / drive MCP tools / coding agents"
/// (`ROADMAP.md:41`). The shell and MCP legs exist; the **coding agents** leg does not. Before a
/// `CodingAgentProvider` can describe or invoke anything, the configured agent definitions must
/// have a single source of truth — this store. No agent exists unless it is configured here, and
/// nothing is configured out of the box: the default configuration cannot create a child, and
/// the D2 promise ("spawns no child process") stays true because there is no file to read agents
/// from.
///
/// ## What this file is not
///
/// It is not enablement and it is not a trust claim: the file holds **definitions only**.
/// Enablement is membership in ``ActionConfigStore`` (providerID `dev.vocca.coding-agent` +
/// agent id), and an agent row has **no `readOnly` field** — an agent is never read-only, its
/// blast radius is `outwardFacing` for every row by construction (founder decision, the spec's
/// "No `readOnly` field" row). The byte-pin in `CodingAgentRegistryTests` asserts the key set on
/// the artifact, and a hand-edited file that grows such a key is refused rather than read.
///
/// ## The file is the memory
///
/// The store is deliberately **stateless**: ``load()`` reads the file on every call, and
/// ``save(_:)`` replaces it whole. Nothing is held between calls, so two store instances over
/// the same directory cannot disagree — the file is the only fact, and the cross-instance
/// acceptance is true by construction rather than by coordination. This is the
/// ``ShellCommandRegistry`` shape, including the atomic temp-write-then-rename commit: a crash
/// between the two steps leaves a `.tmp` that no reader reads, and ``load()`` creates nothing.
///
/// ## Failure is loud on the way in and on the way out
///
/// ``save(_:)`` **throws** when the registry cannot be persisted — the caps and every
/// file-system failure surface to the caller, because a registry the caller believes saved is an
/// agent the user believes configured. ``load()`` is the opposite and tolerant by the same
/// reasoning: a corrupt or unreadable file is the **empty** registry with one loud log entry —
/// never a throw, and never a rewrite of the user's file. The `log` closure is the loud half,
/// injectable so the loudness is asserted rather than hoped. The logs name the file and the row
/// **index**, never the row's text: an agent file may hold an API key, and a log line must not
/// repeat it.
///
/// ## Two tolerances, one policy
///
/// A file this build cannot decode at all — malformed bytes, an unknown top-level key, a field
/// of the wrong type — is a file read wrongly, and the answer is the empty registry with **one**
/// loud log. A row that fails *validation* (a duplicate id, an out-of-range timeout, an over-cap
/// argv or environment, a non-absolute path) is a row the rest of the file can simply not
/// include: it is skipped loudly, one log per row, and the rest load — the `IntentPhraseStore`
/// `LossyRow` precedent. Both halves are the same rule: the file is user-visible and
/// hand-editable, and nothing about it may be fatal or silent.
///
/// ## The caps refuse, they never clamp
///
/// More than ``maximumAgents`` agents or more than ``maximumFileBytes`` of encoded bytes is
/// refused loudly — a registry the store silently shrinks is an agent the user believes
/// configured. A row over its own caps (``maximumIDLength``, ``maximumArgumentCount``,
/// ``maximumEnvironmentEntries``, ``maximumEnvironmentValueLength``,
/// ``maximumTimeoutSeconds``) is skipped loudly, never truncated. The numbers are seeds, like
/// the other stores' caps — a retune is a reviewed edit.
public actor CodingAgentRegistry {

    /// The directory the file lives in.
    public let directory: URL

    /// How many agents the file may define. 16, a bound on how many children this process may
    /// ever be asked to launch from the agent surface — deliberately far below what any real
    /// user needs, and far above what the default configuration holds (zero).
    public static let maximumAgents = 16

    /// How many encoded bytes the file may hold. 64 KB, the bound on a hand-edited file's reach
    /// — the total size cap of the `agent-registry` spec, seeded like the count cap.
    public static let maximumFileBytes = 64 * 1024

    /// How long an agent id may be. 128, a bound on the id a confirmation card must render and
    /// an enablement row must repeat — a seed, like the caps.
    public static let maximumIDLength = 128

    /// How many elements an agent's argv may hold. 64, a bound on the fixed argv an agent may
    /// carry — a seed, like the caps.
    public static let maximumArgumentCount = 64

    /// How many environment entries an agent row may carry. 16 — a seed, like the caps.
    public static let maximumEnvironmentEntries = 16

    /// How long an environment key or value may be. 256 characters — a seed, like the caps.
    public static let maximumEnvironmentValueLength = 256

    /// How long an agent may run, in seconds — the hard cap. 600, founder decision Q5.
    public static let maximumTimeoutSeconds = 600

    /// The timeout a row without `timeoutSeconds` runs with. 30 seconds, founder decision Q5.
    public static let defaultTimeoutSeconds = 30

    private let fileSystem: ActionConfigFileSystem
    private let log: @Sendable (String) -> Void

    /// A store over `directory`, keeping its registry in `coding-agents.json`.
    ///
    /// The `log` closure is the loud half of the tolerance policy: every refused file, every
    /// skipped row and every refused save goes through it, injectable so that the loudness is
    /// asserted rather than hoped.
    public init(
        directory: URL,
        fileSystem: ActionConfigFileSystem = DefaultActionConfigFileSystem(),
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "coding-agents").error("\($0)")
        }
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.log = log
    }

    /// Where a shipped install keeps the file, as a pure function of what the file system
    /// answered: `<applicationSupport>/Vocca`, or `<home>/Library/Application Support/Vocca`
    /// when Application Support could not be resolved — beside `action-config.json` and the
    /// other stores.
    ///
    /// Separated from any initializer because the fallback is otherwise unreachable in a test:
    /// the only way to drive it through an initializer is a machine whose Application Support
    /// does not resolve, and the only way to check the resolved branch is to write into the
    /// developer's own.
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
    public func load() async -> CodingAgentFile {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        guard await fileSystem.fileExists(atPath: fileURL.path) else { return .empty }
        guard let data = await fileSystem.read(fileURL) else {
            log("coding-agents: could not read \(fileURL.path); loading an empty registry")
            return .empty
        }
        return Self.decode(data, onInvalid: log)
    }

    // MARK: - Writing

    /// Persists `file` atomically, refusing what the file must not hold.
    ///
    /// - Throws: ``CodingAgentRegistryError`` when a cap is exceeded, or the file-system
    ///   failure when the commit cannot be made. The checks run **before** anything touches the
    ///   file system, so a refused save leaves the previously committed file byte-identical.
    public func save(_ file: CodingAgentFile) async throws {
        guard file.agents.count <= Self.maximumAgents else {
            log(
                "coding-agents: refusing \(file.agents.count) agents (cap "
                    + "\(Self.maximumAgents))")
            throw CodingAgentRegistryError.tooManyAgents(file.agents.count)
        }
        let data = try Self.encode(file)
        guard data.count <= Self.maximumFileBytes else {
            log(
                "coding-agents: refusing a file of \(data.count) bytes (cap "
                    + "\(Self.maximumFileBytes))")
            throw CodingAgentRegistryError.fileTooLarge(data.count)
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
    public static func encode(_ file: CodingAgentFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            FileDTO(version: file.version, agents: file.agents))
    }

    /// Decode a registry the way ``load()`` reads it: **static, pure, and never throwing.**
    ///
    /// Anything undecodable — malformed bytes, an unknown top-level key, a missing section —
    /// yields exactly one `onInvalid` call and the empty registry. A row that fails *shape*
    /// decode (a `1` where a string belongs — the F1 no-coercion rule, a key this build cannot
    /// name) is dropped by the `LossyRow` pass, one call per row, and a row that fails
    /// *validation* (duplicate id, over-long id, empty or non-absolute path, out-of-range
    /// timeout, over-cap argv or environment) is skipped loudly, one call per row, and the rest
    /// of the file loads. A corrupt file must never be fatal, and a failed parse must never
    /// rewrite the user's file.
    public static func decode(
        _ data: Data, onInvalid: (String) -> Void
    ) -> CodingAgentFile {
        guard data.count <= maximumFileBytes else {
            onInvalid(
                "coding-agents: refusing a file of \(data.count) bytes (cap \(maximumFileBytes))")
            return .empty
        }
        guard let decoded = try? JSONDecoder().decode(LossyFileDTO.self, from: data) else {
            onInvalid("coding-agents: refusing an agent file this build cannot read")
            return .empty
        }
        guard decoded.version == 1 else {
            onInvalid("coding-agents: refusing an agent file of version \(decoded.version)")
            return .empty
        }

        var acceptedIDs = Set<String>()
        var agents: [CodingAgentDefinition] = []
        agents.reserveCapacity(decoded.agents.count)
        for (index, element) in decoded.agents.enumerated() {
            guard let row = element.row else {
                onInvalid("coding-agents: skipping row \(index): not an agent row this build can read")
                continue
            }
            guard !row.id.isEmpty else {
                onInvalid("coding-agents: skipping row \(index): an empty id")
                continue
            }
            guard row.id.count <= maximumIDLength else {
                onInvalid(
                    "coding-agents: skipping row \(index): the id exceeds \(maximumIDLength) "
                        + "characters")
                continue
            }
            guard !acceptedIDs.contains(row.id) else {
                onInvalid("coding-agents: skipping row \(index): a duplicate id")
                continue
            }
            guard !row.executablePath.isEmpty else {
                onInvalid("coding-agents: skipping row \(index): an empty executable path")
                continue
            }
            guard
                (row.executablePath as NSString).isAbsolutePath
                    && !row.executablePath.hasPrefix("~")
            else {
                onInvalid(
                    "coding-agents: skipping row \(index): a non-absolute executable path")
                continue
            }
            guard !row.projectDirectory.isEmpty else {
                onInvalid("coding-agents: skipping row \(index): an empty project directory")
                continue
            }
            guard
                (row.projectDirectory as NSString).isAbsolutePath
                    && !row.projectDirectory.hasPrefix("~")
            else {
                onInvalid(
                    "coding-agents: skipping row \(index): a non-absolute project directory")
                continue
            }
            guard row.arguments.count <= maximumArgumentCount else {
                onInvalid(
                    "coding-agents: skipping row \(index): more than \(maximumArgumentCount) "
                        + "arguments")
                continue
            }
            guard row.timeoutSeconds >= 1 else {
                onInvalid("coding-agents: skipping row \(index): a timeout below 1 second")
                continue
            }
            guard row.timeoutSeconds <= maximumTimeoutSeconds else {
                onInvalid(
                    "coding-agents: skipping row \(index): a timeout above \(maximumTimeoutSeconds) "
                        + "seconds")
                continue
            }
            if let environment = row.environment {
                guard environment.count <= maximumEnvironmentEntries else {
                    onInvalid(
                        "coding-agents: skipping row \(index): more than "
                            + "\(maximumEnvironmentEntries) environment entries")
                    continue
                }
                guard
                    environment.allSatisfy({
                        $0.key.count <= maximumEnvironmentValueLength
                            && $0.value.count <= maximumEnvironmentValueLength
                    })
                else {
                    onInvalid(
                        "coding-agents: skipping row \(index): an environment key or value exceeds "
                            + "\(maximumEnvironmentValueLength) characters")
                    continue
                }
            }
            acceptedIDs.insert(row.id)
            agents.append(row)
        }

        return CodingAgentFile(version: decoded.version, agents: agents)
    }

    // MARK: - The wire shapes

    private struct FileDTO: Encodable {
        let version: Int
        let agents: [CodingAgentDefinition]
    }

    /// One array element, judged alone: a row that does not decode as the agent-row shape is
    /// `nil`, never a thrown error that would sink the whole file.
    private struct LossyRow: Decodable {
        let row: CodingAgentDefinition?

        init(from decoder: Decoder) throws {
            row = try? CodingAgentDefinition(from: decoder)
        }
    }

    /// The file-level shape, with the same wildcard-key scan as the other stores: an unknown
    /// top-level key is a file read wrongly, and the answer is the empty registry with one loud
    /// log — never a guess at the key's meaning.
    private struct LossyFileDTO: Decodable {
        let version: Int
        let agents: [LossyRow]

        init(from decoder: Decoder) throws {
            try Self.rejectUnknownFields(in: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try container.decode(Int.self, forKey: .version)
            self.agents = try container.decode([LossyRow].self, forKey: .agents)
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
            case version, agents
        }
    }

    // MARK: - The one naming convention this file owns

    /// The registry file's name — the committed name the atomic pair renames over.
    private static let fileName = "coding-agents.json"

    /// The suffix of the temp file mid-commit — never readable, never loaded.
    private static let tempSuffix = ".tmp"
}

/// What the registry store refuses to persist.
///
/// The contract is that a store which cannot save **throws**, and the caller surfaces it rather
/// than answering as if the registry had been written — a registry the caller believes saved is
/// an agent the user believes configured.
public enum CodingAgentRegistryError: Error, Equatable {
    /// More than ``CodingAgentRegistry/maximumAgents`` agents were submitted. Carries the
    /// count, so the caller can tell the user what was refused.
    case tooManyAgents(Int)

    /// More than ``CodingAgentRegistry/maximumFileBytes`` of encoded bytes were submitted.
    /// Carries the byte count, so the caller can tell the user what was refused.
    case fileTooLarge(Int)
}

/// The decoded registry — the file's value, not its bytes.
public struct CodingAgentFile: Equatable, Sendable {
    /// The file format's version. This build reads `1`.
    public let version: Int

    /// The accepted agent definitions, in the file's order, at most
    /// ``CodingAgentRegistry/maximumAgents``.
    public let agents: [CodingAgentDefinition]

    /// No agents — the file's empty spelling, and the answer to every refusal.
    public static let empty = CodingAgentFile(version: 1, agents: [])

    public init(version: Int = 1, agents: [CodingAgentDefinition]) {
        self.version = version
        self.agents = agents
    }
}