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

/// What would happen, in one concrete sentence, and how far it would reach — what
/// ``ActionProvider/describe(_:)`` returns (`action-safety-spine` PRD M2, M5a).
///
/// The sentence is the **provider's own claim about its own tool**, rendered without acting.
/// Only the provider knows that `delete-downloads` means "Delete 3 files in ~/Downloads." — a
/// gate that composed its own sentence from the tool id would be guessing, and the user would
/// be confirming the guess. That is why the seam splits `describe` from `invoke` at all (M5a):
/// without the split, the only way to say concretely what will happen is to do it first.
///
/// The radius travels with the sentence rather than beside it. The gate reads both from one
/// value, so there is no window in which a destructive action wears a read-only sentence
/// because two lookups disagreed — the two-copies-of-one-fact desync the house bans.
public struct ActionSummary: Sendable, Equatable {
    /// The concrete sentence a confirmation shows and an audit entry records.
    public let sentence: String

    /// How far the described action would reach — the gate's one branch point.
    ///
    /// ## The radius is the provider's own claim, and it is not yet verified
    ///
    /// This value arrives from ``ActionProvider/describe(_:)``, which means the thing being
    /// gated is the thing that classified itself. Nothing in this aspect checks the claim
    /// against anything: a provider that labels a destructive tool ``BlastRadius/readOnly``
    /// is believed, and a gate that believes the thing it is gating is not yet a gate.
    ///
    /// The claim is carried here anyway because `describe` is the only place that can render
    /// a concrete sentence at all — only the provider knows what its tool does. What is
    /// missing is the second half, and it belongs to the `confirmation-gate` aspect: a
    /// **local policy** that decides the radius the gate acts on, which may only ever
    /// **escalate** a provider's claim (`readOnly` -> `destructive` or `outwardFacing`) and
    /// may **never de-escalate** it. Under that rule a lying provider can only ever cause a
    /// user to be asked more often than necessary, never less.
    ///
    /// Until that policy exists, this field is provider-asserted and unverified. Recorded
    /// rather than assumed — see `action-safety-spine` PRD §6.
    public let blastRadius: BlastRadius

    /// A summary as the provider rendered it.
    ///
    /// The sentence is not validated here. A provider that returns an empty one has a defect,
    /// but a describe call must never trap or fail (the seam is non-throwing by contract), and
    /// refusing the value would leave the caller holding nothing to show. Emptiness is a
    /// provider-conformance claim, asserted where providers are tested.
    public init(sentence: String, blastRadius: BlastRadius) {
        self.sentence = sentence
        self.blastRadius = blastRadius
    }
}
