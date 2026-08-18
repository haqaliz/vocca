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
import XCTest

// The `cleanup-seam` contract, written before the types exist (spec B1–B5): the protocol,
// its context, its rule vocabulary, and its identity, pinned the way `ASRVocabularyTests` and
// `ASREngineSeamTests` pinned theirs — the shape is load-bearing because the seam is pluggable,
// so any adapter (the rules engine, Ollama, BYOK) must be able to implement it with zero system
// access, and attribution (I1) and the zero-network default must be structural rather than
// conventional.
//
// Nothing real executes here: the stub conformers below are the only `CleanupProvider` the suite
// will ever run, exactly as `StubEngine` is the only `ASREngine` CI can execute
// (`ASRTestDoubles.swift:27-34`). The seam is the deliverable, not a provider.
//
// The one divergence from the ASR precedent: `JSONEncoder`/`JSONDecoder` are legal here (the test
// target may import Foundation) because B5 proves the `ReplacementRule` persistence contract the
// `user-dictionary` aspect will build on — while `VoccaCore` itself never imports Foundation, and
// `CoreBoundaryTests` keeps it that way.
final class CleanupProviderSeamTests: XCTestCase {

    /// The transcript the drive calls read: real fields, a real engine identity — nothing about
    /// the seam's input may be a stand-in for the pipeline's actual `Transcript`.
    private func transcript(_ text: String) -> Transcript {
        Transcript(
            text: text,
            segments: [],
            engine: EngineIdentity(id: "stub-engine", displayName: "Stub Engine", isLocal: true),
            isFinal: true,
            audioDuration: 1.0)
    }

    /// The context the drive calls are handed: the real `TargetContext` construction the pipeline
    /// tests use (`TargetContext.swift:47-51`), a mode, an ordered dictionary and a caller-set
    /// budget.
    private func context(
        mode: SessionMode,
        dictionary: [ReplacementRule],
        budget: Duration = .milliseconds(250)
    ) -> CleanupContext {
        CleanupContext(
            target: TargetContext(
                bundleID: "com.example.Notes", windowTitle: "Notes - The Draft", isSecureInput: false),
            mode: mode,
            dictionary: dictionary,
            budget: budget)
    }

    /// The ordered rule array B4 and B5 drive through the echo stub. Three rules, deliberately
    /// distinct and deliberately not alphabetised — a conformer that sorts or deduplicates fails.
    private func rules() -> [ReplacementRule] {
        [
            ReplacementRule(source: "gonna", replacement: "going to", caseSensitive: false, wordBoundary: true),
            ReplacementRule(source: "Wanna", replacement: "want to", caseSensitive: true, wordBoundary: false),
            ReplacementRule(source: "kinda", replacement: "kind of", caseSensitive: false, wordBoundary: true),
        ]
    }

    // MARK: - B1: the protocol shape

    /// `clean(_:context:) async throws -> String` takes the real ``Transcript`` and returns its
    /// answer unchanged through the protocol.
    ///
    /// The signature being `throws` is pinned by the stub declaring `throws` and the successful
    /// call being driven through `try` — the deliberate divergence from the non-throwing
    /// ``TextInjector`` (`ARCHITECTURE.md:273`): timeout/failure is a first-class outcome the
    /// caller routes to raw, so the seam must say so.
    func testProtocolShapeCleanThrowsAndReturnsString() async throws {
        let provider = StubCleanupProvider(
            identity: ProviderIdentity(id: "rules-cleanup", displayName: "Rules Cleanup"))
        let input = transcript("um so anyway I think we should ship it")

        let result = try await provider.clean(input, context: context(mode: .dictation, dictionary: []))

        XCTAssertEqual(result, "cleaned-by-stub", "the stub's answer must arrive at the caller unchanged")
        let received = await provider.lastReceivedText
        XCTAssertEqual(received, input.text, "the seam must read the real transcript's text")
    }

    // MARK: - B2: the `requiresNetwork` default

    /// A conformer that does not declare `requiresNetwork` reads `false`; one that declares it
    /// reads `true` — the C6 egress hook is real and the default-config zero-network claim
    /// (`prd.md:167-168`) is enforced by the protocol's default, not by convention.
    func testRequiresNetworkDefaultsToFalse() {
        let offline = DefaultOfflineCleanupProvider(
            identity: ProviderIdentity(id: "rules-cleanup", displayName: "Rules Cleanup"))
        let networked = NetworkedCleanupProvider(
            identity: ProviderIdentity(id: "ollama-cleanup", displayName: "Ollama Cleanup"))

        XCTAssertFalse(offline.requiresNetwork)
        XCTAssertTrue(networked.requiresNetwork)
    }

    // MARK: - B2b: the budget default

    /// A conformer that declares no `budget` inherits exactly `.milliseconds(10)` — the C5
    /// number, pinned by the extension default so a conformer that says nothing costs the shipped
    /// rules budget (`spec.md` B1). The pipeline races this declared value, never a constant.
    func testBudgetDefaultsToTenMilliseconds() {
        let provider = DefaultOfflineCleanupProvider(
            identity: ProviderIdentity(id: "rules-cleanup", displayName: "Rules Cleanup"))

        XCTAssertEqual(
            provider.budget, .milliseconds(10),
            "a conformer that declares no budget inherits the shipped 10 ms default")
    }

    // MARK: - B3: attribution is non-optional

    /// `identity: ProviderIdentity` is required and non-optional: a conformer must name itself
    /// (the I1 discipline `Transcript.swift:16-21` documents for engines), and its identity
    /// survives a drive call equal — Hashable equality, so a lookup that finds the "same" provider
    /// is exact, `displayName` collisions included.
    func testIdentityIsRequiredAndNonOptional() async throws {
        let identity = ProviderIdentity(id: "rules-cleanup", displayName: "Rules Cleanup")
        let provider = StubCleanupProvider(identity: identity)

        _ = try await provider.clean(transcript("identity survives the drive"), context: context(mode: .dictation, dictionary: []))

        let carried = provider.identity
        XCTAssertEqual(carried, identity)
        XCTAssertEqual(carried.id, identity.id)
        XCTAssertEqual(carried.displayName, identity.displayName)
    }

    // MARK: - B4: `CleanupContext` carries all four fields

    /// A hand-built context carries `target`, `mode` (both cases constructible), an ordered
    /// `dictionary` and `budget` — asserted field-for-field through the echo stub, including that
    /// the budget arrives unchanged: the caller-enforced budget (`prd.md:89-93`) must not be
    /// reinterpreted by the seam.
    func testCleanupContextCarriesAllFourFields() async throws {
        let provider = StubCleanupProvider(
            identity: ProviderIdentity(id: "rules-cleanup", displayName: "Rules Cleanup"))
        let target = TargetContext(
            bundleID: "com.example.Notes", windowTitle: "Notes - The Draft", isSecureInput: false)
        let budget = Duration.milliseconds(250)
        let ordered = rules()

        for mode in [SessionMode.dictation, SessionMode.conversing] {
            let context = CleanupContext(target: target, mode: mode, dictionary: ordered, budget: budget)
            _ = try await provider.clean(transcript("field for field"), context: context)

            let received = await provider.lastReceivedContext
            assertContext(
                received,
                carries: context,
                assertMode: mode)
        }
    }

    // MARK: - B5: the `ReplacementRule` vocabulary

    /// A rule is `Sendable`/`Hashable`/`Equatable`/`Codable` with distinct `caseSensitive` and
    /// `wordBoundary` flags; an ordered array of rules arrives at a conformer in exactly the order
    /// given — no sorting, no deduplication; and a JSON round-trip here (legal in the test, never
    /// in Core) proves the `user-dictionary` aspect's persistence contract fits.
    func testReplacementRuleVocabularyAndOrder() async throws {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        let ordered = rules()

        // Sendable at compile time; distinct flags on one rule; Hashable/Equatable behaviour.
        XCTAssertEqual(requireSendable(ordered[0]).source, "gonna")
        XCTAssertNotEqual(ordered[0].caseSensitive, ordered[0].wordBoundary,
            "caseSensitive and wordBoundary are independent flags — a rule may carry one without the other")
        XCTAssertEqual(
            ordered[0],
            ReplacementRule(source: "gonna", replacement: "going to", caseSensitive: false, wordBoundary: true))
        XCTAssertNotEqual(ordered[0], ordered[1])
        XCTAssertEqual(Set(ordered).count, 3, "three distinct rules must stay three in a set")

        // The ordered array arrives at a conformer untouched: no sorting, no deduplication.
        let provider = StubCleanupProvider(
            identity: ProviderIdentity(id: "rules-cleanup", displayName: "Rules Cleanup"))
        _ = try await provider.clean(
            transcript("rules in order"), context: context(mode: .dictation, dictionary: ordered))
        let received = await provider.lastReceivedContext
        XCTAssertEqual(received?.dictionary, ordered, "declared order is application order (`prd.md:180-181`)")

        // The persistence contract: a JSON round-trip outside Core survives all four fields.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(ordered)
        let decoded = try decoder.decode([ReplacementRule].self, from: data)
        XCTAssertEqual(decoded, ordered)
    }

    // MARK: - Helpers

    /// Asserts the echoed context field-for-field. `mode` is matched by case rather than `==` —
    /// the production enum carries no conformances beyond `Sendable`; matching the case is the
    /// assertion.
    private func assertContext(
        _ received: CleanupContext?,
        carries expected: CleanupContext,
        assertMode mode: SessionMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let received else {
            XCTFail("the echo stub recorded no context", file: file, line: line)
            return
        }
        XCTAssertEqual(received.target, expected.target, file: file, line: line)
        switch (received.mode, mode) {
        case (.dictation, .dictation), (.conversing, .conversing):
            break
        default:
            XCTFail(
                "mode was \(received.mode), expected \(mode)",
                file: file, line: line)
        }
        XCTAssertEqual(received.dictionary, expected.dictionary, file: file, line: line)
        XCTAssertEqual(received.budget, expected.budget, "the caller's budget must arrive unchanged", file: file, line: line)
    }
}

// MARK: - Stub conformers

/// The echo provider: records what it received and answers a fixed marker string.
///
/// An **actor**, like ``StubEngine`` (`ASRTestDoubles.swift:36-38`): `CleanupProvider` is a
/// `Sendable` protocol, and the double must cross actor boundaries honestly — an `@unchecked
/// Sendable` counter would be measuring Sendability with the very race the seam exists to avoid.
/// It declares `identity` and no `requiresNetwork`; that the protocol still accepts it is B2's
/// compile-time half.
actor StubCleanupProvider: CleanupProvider {
    let identity: ProviderIdentity

    /// The text the last drive received — the ledger half of B1: the seam reads the real
    /// transcript, not a stand-in.
    private(set) var lastReceivedText: String?

    /// The context the last drive received — the echo B4 and B5 assert against.
    private(set) var lastReceivedContext: CleanupContext?

    init(identity: ProviderIdentity) {
        self.identity = identity
    }

    func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String {
        lastReceivedText = transcript.text
        lastReceivedContext = context
        return "cleaned-by-stub"
    }
}

/// The second B2 conformer: a provider that does **not** declare `requiresNetwork`, so the
/// protocol default is what answers.
struct DefaultOfflineCleanupProvider: CleanupProvider {
    let identity: ProviderIdentity

    func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String {
        transcript.text
    }
}

/// The third B2 conformer: a provider that declares `requiresNetwork = true` — the C6 egress
/// hook, flipped by the provider that needs it, never by the seam.
struct NetworkedCleanupProvider: CleanupProvider {
    let identity: ProviderIdentity

    var requiresNetwork: Bool { true }

    func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String {
        transcript.text
    }
}
