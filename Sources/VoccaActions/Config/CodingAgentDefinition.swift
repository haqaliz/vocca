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

/// One configured coding agent — the persisted form of an `agents[]` row of
/// `coding-agents.json` (`agent-registry` spec, PRD R1 Data Model).
///
/// ## The file is definitions only
///
/// A row names the agent's stable id, the **absolute** executable that runs it (no PATH lookup —
/// the MCP precedent: the spawn is a `URL(fileURLWithPath:)`, never a search), the fixed argv it
/// is told, the **absolute** project directory it works in, a timeout with a default, an optional
/// environment and an optional plain-text clause. **There is no enablement field, no timestamp,
/// and no `readOnly` field**: enablement is membership in `ActionConfigStore` (providerID
/// `vocca.agent` + agent id), and an agent is never read-only — its blast radius is
/// `outwardFacing` for every row by construction (founder decision, the spec's "No `readOnly`
/// field" row). The byte-pin in `CodingAgentRegistryTests` asserts the key set on the artifact,
/// and a hand-edited file that grows such a key is refused rather than read.
///
/// ## Construction is a contract, decoding is a tolerance
///
/// The failable ``init`` is the caller-facing contract: it returns `nil` on any violation — an
/// empty or over-long id, an empty or non-absolute path, an over-long argv, a timeout outside
/// `1...600` (with `nil` resolving to the 30-second default), an over-capped environment —
/// because a definition a caller believes configured must be one the registry will actually
/// persist. Decoding is the tolerant half and does **not** apply those rules: a planted
/// `"timeoutSeconds": 0` decodes (the row is then skipped loudly by the registry's validation
/// pass, one log per row) so that the loudness is the registry's, never a silent nil. What
/// decoding does refuse is the shape: a key this build cannot name, or a value of the wrong
/// type — the F1 no-coercion rule, a `1` where a string belongs is never read as one.
///
/// ## The environment is explicit, capped, and the file's own trust surface
///
/// ``environment`` holds explicit values — key material such as `ANTHROPIC_API_KEY` — in the
/// user's own file, capped (16 entries, 256 characters per key and per value) and refused rather
/// than truncated. The D2 trust-extension copy covers it: configuring an agent is trust extended
/// to its author, and what reaches the child's environment is what this file says, nothing else.
public struct CodingAgentDefinition: Codable, Equatable, Sendable {
    /// The stable identifier of the agent — the id enablement rows name it by.
    public let id: String

    /// The executable to launch. **Absolute** — no PATH lookup, the transport's contract.
    public let executablePath: String

    /// The fixed argv the executable is told — no shell expansion, no metacharacters, nothing
    /// typed at call time. May be empty: a binary that needs no arguments is a valid agent.
    public let arguments: [String]

    /// The absolute directory the agent works in — the "active project", founder decision Q2.
    public let projectDirectory: String

    /// How long the agent may run, in seconds. Absent in the file means 30; anything below 1 or
    /// above ``CodingAgentRegistry/maximumTimeoutSeconds`` is refused, never clamped.
    public let timeoutSeconds: Int

    /// Explicit environment entries for the agent's process — capped, never truncated.
    public let environment: [String: String]?

    /// An optional plain-text sentence the author adds to the confirmation surface.
    public let clause: String?

    /// Constructs a definition, **returning `nil` on any violation of the row's contract** — the
    /// caller-facing half of the caps: an empty or over-long id, an empty or non-absolute
    /// executable or project directory, more than ``CodingAgentRegistry/maximumArgumentCount``
    /// arguments, a timeout outside `1...600` (`nil` resolves to the 30-second default), or an
    /// environment over its caps. Decoding does not run this pass — see the type documentation.
    public init?(
        id: String, executablePath: String, arguments: [String] = [],
        projectDirectory: String, timeoutSeconds: Int? = nil,
        environment: [String: String]? = nil, clause: String? = nil
    ) {
        let resolvedTimeout = timeoutSeconds ?? CodingAgentRegistry.defaultTimeoutSeconds
        guard !id.isEmpty, id.count <= CodingAgentRegistry.maximumIDLength else { return nil }
        guard !executablePath.isEmpty, Self.isAbsolute(executablePath) else { return nil }
        guard !projectDirectory.isEmpty, Self.isAbsolute(projectDirectory) else { return nil }
        guard arguments.count <= CodingAgentRegistry.maximumArgumentCount else { return nil }
        guard resolvedTimeout >= 1, resolvedTimeout <= CodingAgentRegistry.maximumTimeoutSeconds
        else {
            return nil
        }
        if let environment {
            guard
                environment.count <= CodingAgentRegistry.maximumEnvironmentEntries,
                environment.allSatisfy({
                    $0.key.count <= CodingAgentRegistry.maximumEnvironmentValueLength
                        && $0.value.count <= CodingAgentRegistry.maximumEnvironmentValueLength
                })
            else {
                return nil
            }
        }
        self.id = id
        self.executablePath = executablePath
        self.arguments = arguments
        self.projectDirectory = projectDirectory
        self.timeoutSeconds = resolvedTimeout
        self.environment = environment
        self.clause = clause
    }

    /// Decodes a row, **refusing** one whose object carries a key this type does not define —
    /// the same wildcard-key scan as ``ActionConfig.init(from:)``, so a `readOnly` or an
    /// `enablement` key smuggled into a row is refused on the day it is planted.
    ///
    /// ``timeoutSeconds`` is decoded with `decodeIfPresent` and defaults to 30 — the default is
    /// a property of the file shape, not of a caller remembering to fill one in. Value-level
    /// rules (an out-of-range timeout, an over-long id) are the registry's validation pass's, so
    /// a planted violation is skipped loudly rather than read as a different shape.
    public init(from decoder: Decoder) throws {
        try Self.rejectUnknownFields(in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.executablePath = try container.decode(String.self, forKey: .executablePath)
        self.arguments = try container.decode([String].self, forKey: .arguments)
        self.projectDirectory = try container.decode(String.self, forKey: .projectDirectory)
        self.timeoutSeconds =
            try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
            ?? CodingAgentRegistry.defaultTimeoutSeconds
        self.environment = try container.decodeIfPresent(
            [String: String].self, forKey: .environment)
        self.clause = try container.decodeIfPresent(String.self, forKey: .clause)
    }

    private static func rejectUnknownFields(in decoder: Decoder) throws {
        let allKeys = try decoder.container(keyedBy: AnyStringKey.self)
        if let unknown = allKeys.allKeys.map(\.stringValue).first(where: {
            CodingKeys(stringValue: $0) == nil
        }) {
            throw ActionConfigDecodeError.unknownKey(unknown)
        }
    }

    /// Whether `path` is a usable absolute path under the fixed-argv contract: it must begin
    /// with `/`, and it must **not** begin with `~` — Foundation counts a tilde path as absolute,
    /// but nothing in this product expands `~` (there is no shell anywhere in the contract), so
    /// a `~/bin/agent` would silently resolve to a literal `~` directory at spawn time. That is
    /// the exact silent mangling the store exists to refuse.
    private static func isAbsolute(_ path: String) -> Bool {
        (path as NSString).isAbsolutePath && !path.hasPrefix("~")
    }

    private enum CodingKeys: String, CodingKey {
        case id, executablePath, arguments, projectDirectory, timeoutSeconds, environment, clause
    }
}