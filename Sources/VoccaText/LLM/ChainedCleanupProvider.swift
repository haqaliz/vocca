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

import VoccaCore

/// The rules-then-LLM cleanup chain (`ARCHITECTURE.md:506-512`): rules always run first, the LLM
/// stage rewrites the **rules output**, and on any LLM failure or timeout the rules output
/// stands — "fallback to rules" is structural, not a post-hoc rescue (`cleanup-chain` M6).
///
/// The chain is the only place in C6 where one provider's result is replaced by another
/// provider's result, which makes the degrade policy a single tested function instead of a
/// promise repeated in two providers and a caller (`spec.md:51-56`). It is provider-agnostic:
/// `rules` is any ``CleanupProvider`` (the shipped rules engine in the resolver), and `llm` is
/// an optional second stage (Ollama or BYOK) whose output replaces the rules output when it
/// succeeds. With `llm == nil` the chain is byte-for-byte the rules provider (B1).
///
/// ## The degrade contract
///
/// - **An LLM throw is a return, not a rethrow** — the chain swallows the LLM stage's throw
///   deliberately and returns the rules output, so the pipeline's raw-degrade (which fires only
///   on a chain throw) is reserved for rules-stage failures. The one exception is cancellation:
///   a cancelled session must never inject, so when the task is cancelled the chain rethrows
///   ``CancellationError`` rather than returning a stale rules result (B5) — the pipeline's
///   post-cleanup re-check is the backstop.
/// - **Empty/whitespace LLM output routes to the rules output** — the never-empty rule
///   (`DictationPipeline.swift:360-366`).
/// - **An empty/whitespace rules output never reaches the LLM stage** — the chain does not feed
///   an empty string to an LLM (B7).
///
/// ## What the chain is not
///
/// The chain owns no timeout — the pipeline's budget race (M1) enforces the declared budget; the
/// chain only declares the LLM stage's. It owns no provider decisions — the two stages are the
/// `ollama-provider`/`byok-provider` aspects' conformers, injected.
public struct ChainedCleanupProvider: CleanupProvider {

    /// The always-running first stage — the deterministic rules engine at ship.
    public let rules: any CleanupProvider

    /// The optional second stage — an Ollama or BYOK provider, or `nil` for rules-only.
    public let llm: (any CleanupProvider)?

    /// The LLM stage's identity when present, else the rules provider's — the ledger must
    /// attribute the *decisive* stage (``cleanup-chain`` B6).
    public var identity: ProviderIdentity {
        llm?.identity ?? rules.identity
    }

    /// The LLM stage's egress when present, else the rules provider's — the badge keys on it
    /// (`ARCHITECTURE.md:296`).
    public var requiresNetwork: Bool {
        llm?.requiresNetwork ?? rules.requiresNetwork
    }

    /// The LLM stage's declared budget when present, else the rules provider's — rules runs
    /// first, *inside* the declared deadline (``cleanup-chain`` B6).
    public var budget: Duration {
        llm?.budget ?? rules.budget
    }

    public init(rules: any CleanupProvider, llm: (any CleanupProvider)?) {
        self.rules = rules
        self.llm = llm
    }

    /// Cleans one transcript: run rules first, then the LLM stage over the rules output.
    ///
    /// - Rules always run, even with an LLM stage — the degrade is to *cleaned* text, not raw.
    /// - An empty/whitespace rules output is returned as-is and the LLM stage is skipped (B7).
    /// - The LLM stage receives a synthetic ``Transcript`` carrying the rules output, built from
    ///   the original transcript's engine/isFinal/duration with **zero** missing samples
    ///   (`spec.md:94-96` — the synthetic transcript is a text transform, not a claim about
    ///   captured audio; only `text` is consumed by the LLM providers today).
    /// - An LLM throw or empty/whitespace answer degrades to the rules output; a cancelled task
    ///   rethrows ``CancellationError`` instead.
    public func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String {
        let base = try await rules.clean(transcript, context: context)
        guard let llm else { return base }
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }

        let staged = Transcript(
            text: base,
            segments: [],
            engine: transcript.engine,
            isFinal: transcript.isFinal,
            audioDuration: transcript.audioDuration,
            missingSampleCount: 0)

        let result: String
        do {
            result = try await llm.clean(staged, context: context)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return base
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
        return result
    }
}
