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

/// A tool as a server declared it: its name, its own description of itself, and its annotations.
///
/// Every field here is the **server's claim about itself**, and nothing in this module verifies
/// any of it. That is not a gap to be closed later; it is the trust boundary
/// `action-safety-spine` recorded before MCP existed — a blast radius is the provider's own
/// claim, so local policy may only ever *escalate* it, never de-escalate. A descriptor is
/// therefore evidence, never a decision.
public struct MCPToolDescriptor: Sendable, Equatable {

    /// The tool's identifier, as the server spells it. Never empty — a nameless tool cannot be
    /// called, so it is a parse failure rather than a tool with an empty name.
    public let name: String

    /// The server's own one-line account of what the tool does. Empty when it offered none.
    ///
    /// Spelled `summary` rather than `description` because a `description` member on a Swift
    /// value reads as `CustomStringConvertible` and is not one.
    public let summary: String

    /// What the server claimed about the tool's behaviour — and, as importantly, what it did not.
    public let annotations: MCPToolAnnotations

    public init(name: String, summary: String, annotations: MCPToolAnnotations) {
        self.name = name
        self.summary = summary
        self.annotations = annotations
    }

    /// Reads one element of a `tools/list` result.
    ///
    /// - Returns: `nil` for anything that is not a usable descriptor — not an object, no name, a
    ///   non-string name, an empty name. The caller turns that `nil` into **no tools at all**
    ///   rather than a shorter list; see ``MCPSession/listTools()``.
    ///
    /// A `description` that is present but is not a string is read as absent rather than
    /// refused: it is prose, not a decision, and a server whose copy is malformed should not
    /// thereby hide its whole tool list. An annotation gets no such latitude — see
    /// ``MCPToolAnnotations/parse(_:)``.
    public static func parse(_ value: JSONValue) -> MCPToolDescriptor? {
        guard case .object(let members) = value else { return nil }
        guard case .string(let name)? = members["name"], !name.isEmpty else { return nil }

        var summary = ""
        if case .string(let text)? = members["description"] { summary = text }

        return MCPToolDescriptor(
            name: name, summary: summary,
            annotations: MCPToolAnnotations.parse(members["annotations"]))
    }
}

/// The subset of MCP's tool annotations this layer reads — currently `readOnlyHint` alone, which
/// is the only one a safety decision has ever been taken from here.
///
/// ## Absent means unsafe, and the absence is recorded rather than resolved away
///
/// ``declaredReadOnly`` is an `Optional<Bool>` with three states on purpose: claimed read-only,
/// claimed not read-only, and **no claim made**. Most real MCP servers ship tools with no
/// annotations at all, so the third state is the common one, and a type that collapsed it into
/// `false` could never afterwards say that the server had been silent — a distinction the
/// confirmation copy and any later policy both need.
///
/// ``isReadOnly`` is where the silence is resolved, and it resolves the unsafe way: only an
/// explicit `true` counts. Reading silence as a read-only claim would be a de-escalation
/// performed by omission — the cheapest possible way to defeat the whole action safety spine,
/// since it costs an attacker nothing to omit a field.
public struct MCPToolAnnotations: Sendable, Equatable {

    /// What the server claimed, or `nil` where it claimed nothing.
    public let declaredReadOnly: Bool?

    public init(declaredReadOnly: Bool?) {
        self.declaredReadOnly = declaredReadOnly
    }

    /// Whether this tool may be treated as read-only. **Only an explicit claim counts.**
    public var isReadOnly: Bool {
        declaredReadOnly == true
    }

    /// Reads an `annotations` member.
    ///
    /// Only a genuine JSON boolean is a claim. A `readOnlyHint` of `1`, of `"true"`, of `null`,
    /// or an `annotations` member that is not an object at all, all yield "no claim made" — not
    /// because such a server is necessarily hostile, but because a value that is not a boolean is
    /// not the claim the annotation names, and a safety decision may not be taken from one.
    /// ``JSONValue`` is what makes this possible at all: `JSONSerialization` would have handed
    /// `1` back as something `as? Bool` accepts.
    public static func parse(_ value: JSONValue?) -> MCPToolAnnotations {
        guard case .object(let members)? = value else {
            return MCPToolAnnotations(declaredReadOnly: nil)
        }
        guard case .bool(let claimed)? = members["readOnlyHint"] else {
            return MCPToolAnnotations(declaredReadOnly: nil)
        }
        return MCPToolAnnotations(declaredReadOnly: claimed)
    }
}
