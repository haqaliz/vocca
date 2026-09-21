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

/// The confirmation card's reducer state (`confirmation-card`): the gate's
/// `confirmationRequired` sentence rendered as a widget surface — the first human-in-the-loop
/// safety surface, and the only route to `invoke` in the shipped configuration.
///
/// The card is **presented and cleared by explicit folds only**, exactly as the egress/context
/// badges are: the wiring's `WidgetAction/confirmation(_:)` sets it (one card at a time — a
/// presentation replaces the current card), `WidgetAction/confirmationDismissed` ends it
/// (dismiss/decline/confirm all fold the same clear; the semantic difference lives in the
/// wiring's executor call, not in the state), and no timer and no projection adoption can
/// clear it — `adopting(_:)` and the notice branch carry it forward (`WidgetStateReducerTests`
/// pins the carry). A confirm needs no timer race: the delivered-collapse ends DELIVERED alone.
///
/// The card is **per-invocation only (M4a)**: no "remember"/"ask again" affordance exists in
/// this type or anywhere in the reducer — the suite's source scans pin the absence, so adding
/// one later is a reviewed edit.
public struct WidgetConfirmationState: Equatable, Sendable {
    /// The signal the wiring folded — the sentence, the provider/tool identity and the
    /// invocation's generation token.
    public let signal: WidgetConfirmationSignal

    public init(signal: WidgetConfirmationSignal) {
        self.signal = signal
    }
}

/// The raw facts the wiring folds into the card — the signal `WidgetAction/confirmation(_:)`
/// carries (`confirmation-card`, the `WidgetContextSignal` shape).
///
/// `sentence` is the gate's rendered summary, the provider's own words, to be shown verbatim —
/// never trimmed, re-wrapped or paraphrased (M5a). `providerID`/`toolID` name whose tool the
/// sentence belongs to, for the card's heading. `generation` is the invocation's token, minted
/// by the wiring at presentation: the store refuses a confirm whose generation does not match
/// the current card's, so a stale card cannot confirm after the state moved on (spec acceptance
/// 4) — the wiring supplies it, the reducer and store only compare it.
public struct WidgetConfirmationSignal: Equatable, Sendable {
    /// The provider's rendered sentence, shown verbatim.
    public let sentence: String
    /// The provider's identity, for the card's heading.
    public let providerID: String
    /// The tool's identity, for the card's heading.
    public let toolID: String
    /// The invocation's generation token — the stale-card guard.
    public let generation: Int

    public init(sentence: String, providerID: String, toolID: String, generation: Int) {
        self.sentence = sentence
        self.providerID = providerID
        self.toolID = toolID
        self.generation = generation
    }
}