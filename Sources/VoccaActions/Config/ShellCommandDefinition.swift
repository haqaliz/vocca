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

/// One configured shell command — the persisted form of a `commands[]` row of
/// `shell-commands.json` (`command-registry` spec, PRD Data Model).
///
/// ## The file is definitions only
///
/// A row names the command, the fixed argv that runs it, the blast-radius claim, the named
/// parameter slots and an optional plain-text clause. **There is no enablement field and no
/// argument-value field**: enablement is membership in `ActionConfigStore` (providerID
/// `dev.vocca.shell` + command id), and argument values travel only at call time. The byte-pin
/// in `ShellCommandRegistryTests` asserts the key set on the artifact, and a hand-edited file
/// that grows such a key is refused rather than read.
///
/// ## Destructive by default
///
/// ``readOnly`` defaults to `false` when the key is absent — a command whose file does not
/// declare `readOnly: true` claims the destructive radius (founder decision, the MCP "absent
/// means unsafe" precedent). The gate's escalate-only policy can only raise what the file
/// claims, never lower it, so the file is the floor the confirmation surface builds on.
///
/// ## The argv is fixed, and that is the whole of the contract
///
/// ``command`` is a fixed argv array — no shell expansion, no metacharacters, nothing a user
/// types at call time. `parameters` declare the fixed named slots (`$1`, …) rendered
/// `key = value` in the provider's concrete sentence, and ``clause`` is an *optional* plain-text
/// sentence the author adds; the card confirms the argv-derived sentence with the clause
/// appended, never the clause alone (PRD: "a misleading clause cannot hide a different argv").
public struct ShellCommandDefinition: Codable, Equatable, Sendable {
    /// The stable identifier of the command — the id enablement rows name it by.
    public let id: String

    /// The fixed argv that runs when the command is invoked — no shell expansion, no
    /// metacharacters, nothing typed at call time.
    public let command: [String]

    /// The blast-radius claim: `false` (destructive) when absent, `true` the only way to claim
    /// a read-only radius.
    public let readOnly: Bool

    /// The fixed named parameter slots (`$1`, …), rendered `key = value` in the concrete
    /// sentence.
    public let parameters: [ShellCommandParameter]

    /// An optional plain-text sentence the author adds to the argv-derived confirmation.
    public let clause: String?

    public init(
        id: String, command: [String], readOnly: Bool = false,
        parameters: [ShellCommandParameter] = [], clause: String? = nil
    ) {
        self.id = id
        self.command = command
        self.readOnly = readOnly
        self.parameters = parameters
        self.clause = clause
    }

    /// Decodes a command, **refusing** one whose object carries a key this type does not define.
    ///
    /// The scan cannot run through `CodingKeys`: a `KeyedDecodingContainer` typed with a fixed
    /// `CodingKey` enum drops unknown keys before `allKeys` can see them (measured on this SDK
    /// in `ModelManifest`), so it runs through ``AnyStringKey`` — a key type that accepts every
    /// string — and asks which of the resulting keys `CodingKeys` cannot represent.
    ///
    /// ``readOnly`` is decoded with `decodeIfPresent` and defaults to `false` — the
    /// destructive-by-default rule is a property of the file shape, not of a caller remembering
    /// to fill a default in.
    public init(from decoder: Decoder) throws {
        try Self.rejectUnknownFields(in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.command = try container.decode([String].self, forKey: .command)
        self.readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        self.parameters = try container.decode([ShellCommandParameter].self, forKey: .parameters)
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

    private enum CodingKeys: String, CodingKey {
        case id, command, readOnly, parameters, clause
    }
}