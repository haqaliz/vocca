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

/// Which tool, on which provider, and with what — the plain-data descriptor every operation on
/// the action seam takes (`action-safety-spine` PRD M2).
///
/// Two identifiers and an optional payload. The identifiers are what the seam, the gate and the
/// audit log all need in common: the *name* of what is about to happen, which is enough to
/// render a concrete sentence and to attribute an entry afterwards. The payload arrived later
/// and for one reason — see ``arguments``.
///
/// Identifiers are `String` because `VoccaCore` imports nothing — not even Foundation, so no
/// `UUID` and no `URL` (`CoreBoundaryTests.swift:116` enforces the empty allow-list).
public struct ActionInvocation: Sendable, Equatable {
    /// The provider that owns the tool, e.g. a reverse-DNS identifier.
    public let providerID: String

    /// The tool within that provider.
    public let toolID: String

    /// The tool's arguments as **JSON text**, or `nil` when the call carries none
    /// (`mcp-provider`, 2026-09-20).
    ///
    /// ## Why the field exists at all
    ///
    /// This type was deliberately just two identifiers, and said so. MCP's `tools/call` takes a
    /// name **and** an arguments object, so an MCP tool call could not be expressed in the
    /// vocabulary at all — and a confirmation sentence that cannot name the arguments cannot say
    /// *"send this message to #general"*, which is the concreteness C13 asks of it. The field is
    /// the smallest change that fixes both: the seam's signatures are untouched, so
    /// ``ActionProvider/describe(_:)`` still receives everything it needs to be concrete.
    ///
    /// ## ⚠️ It is text this type cannot validate, and it says so rather than implying otherwise
    ///
    /// `VoccaCore` imports nothing, so there is no `Data` here and no JSON type — a `String` is
    /// what this module can hold. It follows that **nothing here checks that the text is
    /// well-formed JSON**, or that it is an object rather than a fragment, or that it matches
    /// the tool's schema. It is an opaque blob the core carries and cannot read. The provider
    /// parses it and fails as a *returned value* (``ActionOutcome/failed(reasonKey:)``), which is
    /// where the check belongs anyway, since only the provider knows the schema.
    ///
    /// A type that cannot validate its own contents should admit it rather than imply a
    /// guarantee. The one thing this type *can* judge, it does: the size, and emptiness.
    ///
    /// ## It is never persisted
    ///
    /// The audit entry records the rendered summary — the sentence a person was actually asked
    /// to approve — and never this text (`action-safety-spine` PRD §5). That promise used to
    /// hold because there was no payload to persist; now that there is one, it is asserted
    /// against the file bytes in `ActionAuditStoreTests`.
    public let arguments: String?

    // MARK: - The bound

    /// The largest argument payload an invocation may carry, in UTF-8 bytes.
    ///
    /// **The bound in one place**, read by the initializer and by anything that wants to know.
    /// 4 KB, the same ceiling `ContextGrantGate` puts on a context payload, and for the same
    /// reason: text that crosses a safety boundary and reaches a sentence a person is asked to
    /// read is a liability at unbounded size even when nothing writes it down.
    public static let maximumArgumentsUTF8Bytes = 4096

    /// Builds an invocation, or `nil` when either identifier is empty, or when the argument text
    /// is empty or over ``maximumArgumentsUTF8Bytes``.
    ///
    /// **The refusal is at construction, never a validity flag carried alongside.** An
    /// invocation that exists is one the confirmation sentence can be concrete about (M2) and
    /// the audit log can attribute (M6); a nameless one is neither, and letting it exist would
    /// mean every downstream consumer re-checking — which is the shape in which one of them
    /// eventually forgets.
    ///
    /// Whitespace is not trimmed: `VoccaCore` has no Foundation to trim with, and a provider id
    /// that is meaningful only after normalisation is a provider id the audit log would record
    /// differently from the one the user confirmed.
    ///
    /// ## The two refusals the payload adds
    ///
    /// **Empty argument text is refused, so absence has one spelling.** `nil` means "no
    /// arguments"; `""` would be a second way to say the same thing, and two spellings of one
    /// state are two cases every consumer has to treat alike — the shape in which one of them
    /// eventually does not.
    ///
    /// **Oversized argument text is refused, never truncated** — and the difference from
    /// `ActionAuditEntry`'s summary, which truncates, is the point. A truncated *sentence* is a
    /// shorter account of the same action; truncated *arguments* are a different action,
    /// silently. An action nobody can name is refused here for the same reason: better no
    /// invocation than a misleading one.
    ///
    /// - Parameters:
    ///   - providerID: The provider that owns the tool. Never empty.
    ///   - toolID: The tool. Never empty.
    ///   - arguments: JSON text the provider will parse, or `nil` for a call that carries none.
    ///     Defaults to `nil`, so every construction site written before this field existed keeps
    ///     compiling and keeps meaning exactly what it meant.
    public init?(providerID: String, toolID: String, arguments: String? = nil) {
        guard !providerID.isEmpty, !toolID.isEmpty else { return nil }
        if let arguments {
            guard !arguments.isEmpty else { return nil }
            guard arguments.utf8.count <= Self.maximumArgumentsUTF8Bytes else { return nil }
        }
        self.providerID = providerID
        self.toolID = toolID
        self.arguments = arguments
    }
}
