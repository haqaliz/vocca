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

/// One configured MCP server — the persisted form of `StdioMCPTransport.Configuration`
/// (`enablement-store` spec: the `servers` section of `action-config.json`).
///
/// ## The path is absolute, and that is the whole of the contract
///
/// ``executablePath`` is an absolute path and **nothing here consults a `PATH`**, because
/// resolving a name against an environment variable is a second decision about *which* program
/// runs — the stdio transport's own configuration contract (`StdioMCPTransport.swift`), stated
/// here so that the file and the transport cannot drift apart on what a path means. An empty
/// path is refused at save by the store, not tolerated here: a server without a path is not a
/// server.
///
/// ## The id is stable, never invented here
///
/// ``id`` identifies the server across relaunches — the wiring that presents the server list
/// generates it at add time, and this type only holds it. The file is the memory, so a
/// regenerated id would look to every later reader like a deleted server and a new one.
public struct MCPServerConfiguration: Codable, Equatable, Sendable {
    /// The stable identifier of the server, generated once at add time.
    public let id: String

    /// A human-readable name, for the UI that edits the list.
    public let name: String

    /// The executable to launch. **Absolute** — no PATH lookup, the transport's contract.
    public let executablePath: String

    /// The child's arguments, passed through untouched.
    public let arguments: [String]

    public init(
        id: String, name: String, executablePath: String, arguments: [String] = []
    ) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
    }

    /// Decodes a server, **refusing** one whose object carries a key this type does not define.
    ///
    /// The scan cannot run through `CodingKeys`: a `KeyedDecodingContainer` typed with a fixed
    /// `CodingKey` enum drops unknown keys before `allKeys` can see them (measured on this SDK
    /// in `ModelManifest`), so it runs through ``AnyStringKey`` — a key type that accepts every
    /// string — and asks which of the resulting keys `CodingKeys` cannot represent.
    public init(from decoder: Decoder) throws {
        try Self.rejectUnknownFields(in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.executablePath = try container.decode(String.self, forKey: .executablePath)
        self.arguments = try container.decode([String].self, forKey: .arguments)
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
        case id, name, executablePath, arguments
    }
}