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
import VoccaCore
import VoccaText
import XCTest

/// The rules-then-LLM cleanup chain's contract (spec B1–B7): the composition that makes C6's
/// degrade guarantee ("never breaks dictation", `ROADMAP.md:140`) one line of code rather than a
/// contract every caller re-checks (`ARCHITECTURE.md:506-512`).
///
/// The chain is the only place in C6 where one provider's result is replaced by another
/// provider's result (`spec.md:51-56`): rules always run first, the LLM stage rewrites the
/// **rules output**, and on any LLM throw — or empty/whitespace answer — the rules output
/// stands. "Fallback to rules" is therefore structural, not a post-hoc rescue. The one sharp
/// edge is cancellation: a cancelled session must never inject a stale rules result, so the
/// chain rethrows `CancellationError` rather than returning `base` when its task is cancelled.
///
/// Driven headlessly over a scripted ``ChainStageProvider`` double for both stages; the real
/// providers land in the resolver (`cleanup-config`) and the composition root (`root-wiring`).
final class CleanupChainTests: XCTestCase {

    // MARK: - B1: rules-only passthrough

    /// **B1 — with no LLM stage the chain is the rules provider, byte for byte.** Identity,
    /// network and budget are the rules provider's; the output is exactly the rules output; the
    /// LLM slot is never consulted (there is none).
    func testRulesOnlyPassthrough() async throws {
        let rules = ChainStageProvider(identity: Self.rulesIdentity, behavior: .returns("rules output"))
        let chain = ChainedCleanupProvider(rules: rules, llm: nil)

        XCTAssertEqual(
            chain.identity, Self.rulesIdentity,
            "without an LLM stage the chain attributes to the rules provider")
        XCTAssertFalse(
            chain.requiresNetwork,
            "without an LLM stage the chain inherits the rules provider's offline declaration")
        XCTAssertEqual(
            chain.budget, .milliseconds(10),
            "without an LLM stage the chain inherits the rules provider's budget")

        let output = try await chain.clean(Self.transcript, context: Self.context())
        XCTAssertEqual(output, "rules output")
    }

    // MARK: - B2: chain composition

    /// **B2 — the LLM stage receives the rules output, and its result is returned.** The chain is
    /// rules-first by construction: the LLM stub's recorded input is the **rules output** (the
    /// structural degrade — the LLM rewrites cleaned text, never raw), and the chain returns the
    /// LLM's answer.
    func testTheLlmStageReceivesTheRulesOutputAndItsResultIsReturned() async throws {
        let rules = ChainStageProvider(identity: Self.rulesIdentity, behavior: .returns("rules output"))
        let llm = ChainStageProvider(
            identity: Self.llmIdentity, requiresNetwork: true, budget: .seconds(5),
            behavior: .returns("llm output"))
        let chain = ChainedCleanupProvider(rules: rules, llm: llm)

        let output = try await chain.clean(Self.transcript, context: Self.context())

        XCTAssertEqual(
            output, "llm output",
            "the LLM stage's result is the chain's output")
        let received = await llm.receivedTranscripts
        XCTAssertEqual(
            received.count, 1,
            "one clean call feeds the LLM stage exactly one transcript")
        XCTAssertEqual(
            received.first?.text, "rules output",
            "the LLM stage must rewrite the rules output, never the raw transcript — the degrade is structural")
    }

    // MARK: - B3: LLM throws ⇒ rules output stands

    /// **B3 — a throwing LLM stage degrades to the rules output and the chain does not rethrow.**
    /// The swallow is a policy, not an accident (`spec.md:34-36`): the pipeline's raw-degrade is
    /// reserved for rules-stage failures, so the LLM's failure never loses the cleaned text.
    func testAnLlmThrowDegradesToTheRulesOutput() async throws {
        let rules = ChainStageProvider(identity: Self.rulesIdentity, behavior: .returns("rules output"))
        let llm = ChainStageProvider(identity: Self.llmIdentity, behavior: .throwsBoom)
        let chain = ChainedCleanupProvider(rules: rules, llm: llm)

        let output = try await chain.clean(Self.transcript, context: Self.context())
        XCTAssertEqual(
            output, "rules output",
            "an LLM throw must stand the rules output, never lose the text")
    }

    // MARK: - B4: LLM empty/whitespace ⇒ rules output stands

    /// **B4 — an empty or whitespace-only LLM answer degrades to the rules output.** Emptiness is
    /// the never-empty rule (`DictationPipeline.swift:360-366`): nothing to inject is not an
    /// empty string.
    func testAnEmptyOrWhitespaceLlmOutputDegradesToTheRulesOutput() async throws {
        let rules = ChainStageProvider(identity: Self.rulesIdentity, behavior: .returns("rules output"))
        for behavior: ChainStageProvider.Behavior in [.returnsEmpty, .returnsWhitespace] {
            let llm = ChainStageProvider(identity: Self.llmIdentity, behavior: behavior)
            let chain = ChainedCleanupProvider(rules: rules, llm: llm)
            let output = try await chain.clean(Self.transcript, context: Self.context())
            XCTAssertEqual(
                output, "rules output",
                "an empty or whitespace LLM answer must stand the rules output")
        }
    }

    // MARK: - B5: cancellation rethrow

    /// **B5 — a cancelled session rethrows cancellation; it never returns a stale rules result.**
    /// The LLM stage is genuinely cancelled (the outer task is cancelled while the stage parks on
    /// `Task.sleep`, which throws `CancellationError`): the chain re-checks `Task.isCancelled`
    /// and rethrows — a cancelled session must never inject, and the rules output is stale the
    /// moment the user pressed Esc.
    func testCancellationRethrowsRatherThanReturningStaleRulesOutput() async throws {
        let rules = ChainStageProvider(identity: Self.rulesIdentity, behavior: .returns("rules output"))
        let llm = ChainStageProvider(identity: Self.llmIdentity, behavior: .hang)
        let chain = ChainedCleanupProvider(rules: rules, llm: llm)

        let transcript = Self.transcript
        let context = Self.context()
        let task = Task { try await chain.clean(transcript, context: context) }
        await waitUntil { await llm.inFlight }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled session must not return a stale rules result")
        } catch is CancellationError {
            // the chain rethrew cancellation — nothing injects
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - B6: propagation

    /// **B6 — identity, network and budget propagate from the LLM stage when present.** The
    /// ledger must attribute the *decisive* stage, the badge keys on the LLM's egress, and the
    /// caller races the LLM's declared 5 s — all three flip back to the rules provider when the
    /// LLM stage is absent (B1).
    func testIdentityNetworkAndBudgetPropagateFromTheLlmStageWhenPresent() async throws {
        let rules = ChainStageProvider(identity: Self.rulesIdentity, behavior: .returns("rules"))
        let llm = ChainStageProvider(
            identity: Self.llmIdentity, requiresNetwork: true, budget: .seconds(5),
            behavior: .returns("x"))
        let chain = ChainedCleanupProvider(rules: rules, llm: llm)

        XCTAssertEqual(chain.identity, Self.llmIdentity)
        XCTAssertTrue(
            chain.requiresNetwork,
            "the chain declares the LLM stage's egress — the badge keys on it")
        XCTAssertEqual(
            chain.budget, .seconds(5),
            "the chain declares the LLM stage's budget — the caller races the LLM's seconds")
    }

    // MARK: - B7: never-empty into the LLM

    /// **B7 — an empty or whitespace rules output skips the LLM stage entirely.** The chain must
    /// not feed an empty string to the LLM; the rules output stands as-is and the LLM stub
    /// records no call.
    func testAnEmptyOrWhitespaceRulesOutputSkipsTheLlmStage() async throws {
        for rulesText in ["", "   \n"] {
            let rules = ChainStageProvider(identity: Self.rulesIdentity, behavior: .returns(rulesText))
            let llm = ChainStageProvider(identity: Self.llmIdentity, behavior: .returns("llm output"))
            let chain = ChainedCleanupProvider(rules: rules, llm: llm)

            let output = try await chain.clean(Self.transcript, context: Self.context())
            XCTAssertEqual(output, rulesText)
            let calls = await llm.cleanCalls
            XCTAssertEqual(
                calls, 0,
                "an empty or whitespace rules output must never reach the LLM stage")
        }
    }

    // MARK: - Fixtures

    /// The rules stage's identity — the double's stand-in for `ShippingRulesCleanupProvider`.
    private static let rulesIdentity = ProviderIdentity(id: "rules", displayName: "Rules")

    /// The LLM stage's identity — the double's stand-in for an Ollama/BYOK provider.
    private static let llmIdentity = ProviderIdentity(id: "ollama", displayName: "Ollama")

    /// The canonical transcript text the chain cleans.
    private static let transcriptText = "um so like we need to ship this period"

    /// The transcript the chain cleans, over the probe-stub engine identity.
    private static let transcript = Transcript(
        text: transcriptText,
        segments: [],
        engine: EngineIdentity(
            id: "probe-stub-engine", displayName: "Probe stub engine", isLocal: true),
        isFinal: true,
        audioDuration: 1.0)

    /// The dictation-mode context the pipeline hands a provider.
    private static func context() -> CleanupContext {
        CleanupContext(
            target: TargetContext(
                bundleID: "com.example.Notes", windowTitle: "Notes - The Draft",
                isSecureInput: false),
            mode: .dictation,
            dictionary: [],
            budget: .seconds(5))
    }

    /// Polls until `condition` is true — the `DictationPipelineTests` shape
    /// (`:431-435`), so a hanging LLM stage's in-flight marker can be observed
    /// before the test cancels it.
    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        for _ in 0..<2000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("timed out waiting for condition")
    }
}

/// **A cleanup provider the chain tests script** — the `ScriptedCleanupProvider` shape applied
/// to the chain's two slots: an actor (because `CleanupProvider` is a `Sendable` protocol and
/// the double must cross the boundary honestly) that records every transcript it receives and
/// answers from a scripted behavior.
///
/// `.hang` parks on a long `Task.sleep`, which throws `CancellationError` when the calling task
/// is cancelled — the B5 cancellation test's deterministic in-flight marker (`inFlight` is set
/// before the sleep) and its cancellation trigger in one mode.
private actor ChainStageProvider: CleanupProvider {
    /// What a `clean` call may do.
    enum Behavior: Sendable {
        /// Return `text` — the happy path.
        case returns(String)
        /// Return `""` — an empty answer.
        case returnsEmpty
        /// Return whitespace — emptiness for the injector's purposes.
        case returnsWhitespace
        /// Throw ``ChainStageError/boom`` — a generic stage failure.
        case throwsBoom
        /// Park on a long sleep until the calling task is cancelled.
        case hang
    }

    let identity: ProviderIdentity
    nonisolated let requiresNetwork: Bool
    nonisolated let budget: Duration

    private let behavior: Behavior
    private(set) var receivedTranscripts: [Transcript] = []
    private(set) var cleanCalls = 0
    private(set) var inFlight = false

    init(
        identity: ProviderIdentity,
        requiresNetwork: Bool = false,
        budget: Duration = .milliseconds(10),
        behavior: Behavior
    ) {
        self.identity = identity
        self.requiresNetwork = requiresNetwork
        self.budget = budget
        self.behavior = behavior
    }

    func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String {
        cleanCalls += 1
        receivedTranscripts.append(transcript)
        switch behavior {
        case .returns(let text):
            return text
        case .returnsEmpty:
            return ""
        case .returnsWhitespace:
            return "   \n"
        case .throwsBoom:
            throw ChainStageError.boom
        case .hang:
            inFlight = true
            try await Task.sleep(for: .seconds(3600))
            return ""
        }
    }
}

/// The one failure the stage double can name — the B3 swallow's distinct marker.
private enum ChainStageError: Error, Sendable {
    case boom
}
