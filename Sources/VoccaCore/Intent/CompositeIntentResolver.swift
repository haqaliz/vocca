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

/// The chained ``IntentResolver`` (`composite-intent-resolver` PRD must-haves 1, 3, 4;
/// `resolver-chain` spec acceptances A1, A3, A4) — a primary resolver first, a fallback second,
/// and a set of providers the fallback may never resolve to.
///
/// The shipped composition is the phrase resolver as the primary and the keyword resolver as
/// the fallback, behind the user's `keywordFallback` switch (default off).
///
/// ## How an utterance is resolved
///
/// The primary is asked first. Any resolution other than ``IntentResolution/none`` is returned
/// as-is — a `.toolCall` unchanged, and an `.ask` passed through (the phrase leg never asks, but
/// the composite does not rewrite what it did not produce) — and **the fallback is never
/// consulted**. On `.none`, the fallback resolves against the catalog with every row of an
/// excluded provider removed.
///
/// ## The excluded providers, closed twice
///
/// Belt and braces: the fallback never *sees* an excluded row, and a fallback `.toolCall` that
/// names an excluded provider anyway is discarded to `.none`. Either half alone closes the leg;
/// both ship so a fallback that ignores its catalog cannot reopen it. The identifiers are
/// supplied by the caller — `VoccaCore` cannot name the shell provider, so the composition root
/// passes it. The primary's catalog is not filtered: the phrase store refuses an excluded row
/// at load, which is its own reviewed rule.
///
/// Foundation-free and deterministic, so the empty import allow-list
/// (`CoreBoundaryTests.swift:116`) holds.
public struct CompositeIntentResolver: IntentResolver {

    /// The resolver asked first.
    public let primary: any IntentResolver

    /// The resolver asked only when the primary resolves to nothing.
    public let fallback: any IntentResolver

    /// The providers the fallback may never see or resolve to.
    public let excludedProviderIDs: Set<String>

    /// - Parameters:
    ///   - primary: The resolver asked first.
    ///   - fallback: The resolver asked on the primary's `.none`.
    ///   - excludedProviderIDs: The providers removed from the fallback's catalog and refused
    ///     from its result.
    public init(
        primary: any IntentResolver, fallback: any IntentResolver,
        excludedProviderIDs: Set<String>
    ) {
        self.primary = primary
        self.fallback = fallback
        self.excludedProviderIDs = excludedProviderIDs
    }

    /// Primary first, then the filtered fallback, per the type documentation.
    public func resolve(
        _ utterance: String, against catalog: [ToolReference]
    ) -> IntentResolution {
        let first = primary.resolve(utterance, against: catalog)
        guard first == .none else { return first }

        let permitted = catalog.filter { !excludedProviderIDs.contains($0.providerID) }
        let second = fallback.resolve(utterance, against: permitted)
        if case .toolCall(let invocation) = second,
            excludedProviderIDs.contains(invocation.providerID)
        {
            return .none
        }
        return second
    }
}
