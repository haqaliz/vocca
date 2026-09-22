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

/// One named parameter slot of a shell command — the persisted form of the PRD's fixed named
/// parameters (`$1`, `$2`, …) of `shell-commands.json`.
///
/// ## The slot is positional, the name is display
///
/// A parameter declares a fixed slot in the command's argv, and the slot is the array position —
/// the first parameter is `$1`, the second `$2`, and so on. The file carries **only the display
/// name**, the text a confirmation card renders (`key = value`) when the provider renders the
/// concrete sentence. There is no slot number in the file because the position already is the
/// slot: two files cannot disagree about which parameter is which.
///
/// ## No values, ever
///
/// There is no value field, and there cannot be one: a value is a fact about a particular
/// invocation, supplied at call time, and this file is definitions only (`command-registry`
/// spec: "No argument values at rest"). A hand-edited file that grows a value key is refused
/// rather than read (see ``ShellCommandDefinition`` for the same rule at the row level).
public struct ShellCommandParameter: Codable, Equatable, Sendable {
    /// The display name a confirmation card renders for this slot.
    public let name: String

    public init(name: String) {
        self.name = name
    }

    /// Decodes a parameter, **refusing** one whose object carries a key this type does not
    /// define — the same wildcard-key scan as ``ActionConfig``, so a `value` or an `arguments`
    /// key smuggled into a slot is refused on the day it is planted.
    public init(from decoder: Decoder) throws {
        try Self.rejectUnknownFields(in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
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
        case name
    }
}