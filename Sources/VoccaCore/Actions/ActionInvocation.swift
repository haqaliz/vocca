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

/// Which tool, on which provider — the plain-data descriptor every operation on the action
/// seam takes (`action-safety-spine` PRD M2).
///
/// Deliberately just the two identifiers. Arguments, a payload and a schema all belong to the
/// intent layer that is explicitly out of this unit's scope; what the seam, the gate and the
/// audit log all need in common is the *name* of what is about to happen, and naming it is
/// enough to render a concrete sentence and to attribute an entry afterwards.
///
/// Identifiers are `String` because `VoccaCore` imports nothing — not even Foundation, so no
/// `UUID` and no `URL` (`CoreBoundaryTests.swift:116` enforces the empty allow-list).
public struct ActionInvocation: Sendable, Equatable {
    /// The provider that owns the tool, e.g. a reverse-DNS identifier.
    public let providerID: String

    /// The tool within that provider.
    public let toolID: String

    /// Builds an invocation, or `nil` when either identifier is empty.
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
    public init?(providerID: String, toolID: String) {
        guard !providerID.isEmpty, !toolID.isEmpty else { return nil }
        self.providerID = providerID
        self.toolID = toolID
    }
}
