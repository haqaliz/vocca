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

/// The file shape of `action-config.json` — two sections, and nothing else
/// (`enablement-store` spec): the configured MCP servers and the persisted enablement rows.
///
/// ## The privacy boundary is the shape's absence
///
/// **There is no sentence field and no arguments field.** The enablement row is the persisted
/// form of ``ActionEnablement`` membership, which is by whole ``ActionInvocation`` — and an
/// invocation's `arguments` travel only at call time, never in a persisted row. A transcript
/// sentence, a tool-call argument blob or any other free text has **no field to travel in**;
/// the byte-pin in `ActionConfigStoreTests` asserts it on the artifact, and a hand-edited file
/// that grows such a key is refused rather than read (see ``ActionConfigDecodeError``).
///
/// ## Strictness is the tolerance policy's other half
///
/// Decoding refuses **unknown keys** at every level of the shape: a config read with a field
/// this build cannot name is a config read wrongly, and the store's tolerance is *skip the file
/// loudly*, never *guess at its meaning* (the ``ActionAuditEntry`` precedent). Tolerant decode
/// and strict shape are the same policy from two directions — corruption must never be fatal,
/// and drift must never be silently adopted.
public struct ActionConfig: Codable, Equatable, Sendable {
    /// The configured servers, at most ``ActionConfigStore/maximumServers``.
    public let servers: [MCPServerConfiguration]

    /// The persisted enablement rows, at most ``ActionConfigStore/maximumEnablementRows``.
    public let enablement: [ActionConfigEnablementRow]

    /// Nothing configured — the file's empty spelling, and the answer to a corrupt file.
    public static let empty = ActionConfig(servers: [], enablement: [])

    public init(servers: [MCPServerConfiguration], enablement: [ActionConfigEnablementRow]) {
        self.servers = servers
        self.enablement = enablement
    }

    /// Decodes a config, **refusing** one whose object carries a key this type does not define.
    ///
    /// The scan cannot run through `CodingKeys`: a `KeyedDecodingContainer` typed with a fixed
    /// `CodingKey` enum drops unknown keys before `allKeys` can see them (measured on this SDK
    /// in `ModelManifest`), so it runs through ``AnyStringKey`` — a key type that accepts every
    /// string — and asks which of the resulting keys `CodingKeys` cannot represent.
    public init(from decoder: Decoder) throws {
        try Self.rejectUnknownFields(in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.servers = try container.decode([MCPServerConfiguration].self, forKey: .servers)
        self.enablement = try container.decode([ActionConfigEnablementRow].self, forKey: .enablement)
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
        case servers, enablement
    }
}

/// One enablement row — the persisted form of ``ActionEnablement`` membership
/// (`enablement-store` spec: the `enablement` section of `action-config.json`).
///
/// Two identifiers because membership is by whole ``ActionInvocation``, never by tool name
/// alone: two providers may serve the same tool name, and enabling one must not enable the
/// other. **No arguments field exists** — see ``ActionConfig`` for why that is a privacy
/// decision and not an omission.
///
/// Rows are tolerant of stale tool ids: a tool a server no longer lists keeps its row, and
/// decode stays valid — the store is not the discoverer of tools, and a row for a tool that has
/// temporarily vanished must survive the round trip rather than be pruned on load.
public struct ActionConfigEnablementRow: Codable, Equatable, Sendable {
    /// The provider that owns the tool.
    public let providerID: String

    /// The tool within that provider.
    public let toolID: String

    public init(providerID: String, toolID: String) {
        self.providerID = providerID
        self.toolID = toolID
    }

    /// Decodes a row, **refusing** one whose object carries a key this type does not define —
    /// the same wildcard-key scan as ``ActionConfig.init(from:)``, so a `rawArguments` smuggled
    /// into a row is refused on the day it is planted.
    public init(from decoder: Decoder) throws {
        try Self.rejectUnknownFields(in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.providerID = try container.decode(String.self, forKey: .providerID)
        self.toolID = try container.decode(String.self, forKey: .toolID)
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
        case providerID, toolID
    }
}

/// What a config file cannot be read as.
///
/// One case: a decoded object carried a key this build cannot name. It is an error rather than
/// a tolerated skip of the key because the store's tolerance is *skip the file loudly*, never
/// *guess at its meaning* — a sentence field or a raw-arguments field is exactly the drift the
/// byte-pin exists to make loud.
public enum ActionConfigDecodeError: Error, Equatable {
    /// A decoded object held a key outside the named field set.
    case unknownKey(String)
}

/// A `CodingKey` that accepts every string, used only to enumerate the keys a decoded object
/// actually carries.
///
/// A `KeyedDecodingContainer` typed with a fixed `CodingKey` enum drops keys the enum does not
/// define before `allKeys` can see them (measured in `ModelManifest`), so an unknown-key scan
/// through the enum would always come back clean. This type is the untyped view: every key
/// survives into `allKeys`, and the scan compares against the real `CodingKeys` by name.
///
/// `internal` rather than `private` because every type in `Config/` runs the same
/// unknown-key scan (`MCPServerConfiguration`, `ActionConfigEnablementRow`) — one copy of the
/// mechanism, not three that can drift apart.
struct AnyStringKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}