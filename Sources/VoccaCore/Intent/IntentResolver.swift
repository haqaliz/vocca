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

/// The pluggable intent boundary (`intent-layer` PRD R1; `intent-seam` spec acceptance 1-5) —
/// the seam that turns a cleaned transcript into a tool call, a spoken question, or nothing.
///
/// The plainest seam in the action layer, on purpose: **input is the cleaned transcript text** —
/// the wiring runs ASR and per-mode cleanup before the resolver, exactly as it does for the reply
/// generator (``ReplyGenerator``), so this seam's input never sees utterance frames or a
/// `Transcript` — and **output is a Core-vocabulary ``IntentResolution``**, the same vocabulary
/// the rest of the action machinery speaks. The call is **synchronous and deterministic**,
/// mirroring the reply seam's reasons (`ReplyGenerator.swift:26-31`): the classifier is local and
/// stateless, runs once per committed turn at a decision point off the per-frame path, and if
/// C13's real agent ever forces an async leg that is a C13 signature reconsideration, recorded
/// there rather than added now.
///
/// The catalog is **supplied by the caller and never read here** (R3): the wiring resolves only
/// *enabled* tools, so a disabled tool is never resolved to, never described, never called. The
/// resolver itself never invents a tool the catalog does not name.
///
/// Two deterministic, local, zero-network implementations ship behind this seam
/// (`CAPABILITY_ROADMAP.md` guardrail 7):
///
/// - ``KeywordIntentResolver`` — token-scored matching over a seeded synonym table;
/// - ``NullIntentResolver`` — the composed default: `.none` for every utterance.
public protocol IntentResolver: Sendable {

    /// Resolves a cleaned utterance against the enabled-tool catalog.
    ///
    /// - Parameters:
    ///   - utterance: the cleaned transcript text, exactly as cleanup produced it.
    ///   - catalog: the tools the resolver may resolve to — the enablement, never read.
    /// - Returns: ``IntentResolution/toolCall(_:)`` on a confident match,
    ///   ``IntentResolution/ask(question:)`` below the not-confident threshold, or
    ///   ``IntentResolution/none`` when nothing matched.
    func resolve(_ utterance: String, against catalog: [ToolReference]) -> IntentResolution
}

/// One entry in the enabled-tool catalog the intent seam resolves against (R3).
///
/// The two identifiers are what every resolver output needs in common — the same pair
/// ``ActionInvocation`` carries — and `displayName` is the human name the resolver may rank and
/// the ask path may speak. Identifiers are `String` because `VoccaCore` imports nothing
/// (`CoreBoundaryTests.swift:116`).
public struct ToolReference: Sendable, Equatable {

    /// The provider that owns the tool, e.g. a reverse-DNS identifier.
    public let providerID: String

    /// The tool within that provider.
    public let toolID: String

    /// The human-readable name the resolver ranks and the ask path may speak. May be empty, in
    /// which case the ask path speaks `providerID/toolID` instead.
    public let displayName: String

    /// - Parameters:
    ///   - providerID: The provider that owns the tool. Never empty.
    ///   - toolID: The tool. Never empty.
    ///   - displayName: The human-readable name; may be empty.
    public init(providerID: String, toolID: String, displayName: String) {
        self.providerID = providerID
        self.toolID = toolID
        self.displayName = displayName
    }
}