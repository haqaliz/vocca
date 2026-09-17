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

/// **R8 — the mode-scoped resolver contract (D2)**: `resolve(mode:)` answers the selection the
/// file names for that mode, the no-arg `resolve()` is byte-identical to today (the dictate
/// half), and **one file read serves both halves** — the single-flight guard holds a pair, so
/// resolving both modes still reads the file exactly once (the B4 pin, extended).
///
/// The mode is consumed **at the resolver seam** — provider selection by mode — never inside a
/// provider (`CleanupProviderSeamTests`). The caller still races each half against the half's
/// declared `budget`/`requiresNetwork`, so the timeout-yields-raw machinery races the same
/// numbers as today (B6 propagation, now pinned per mode).
final class CleanupResolverPerModeTests: XCTestCase {

    // MARK: - The selection per mode

    /// **The dictate half is exactly as before**: a `provider: ollama` file resolves the ollama
    /// chain through the no-arg `resolve()`, and the converse half (absent key) is rules.
    func testResolveReturnsTheDictationSelectionExactlyAsBefore() async throws {
        let resolver = Self.makeResolver(
            over: Self.tempDirectory(),
            configJSON: #"{"provider":"ollama","ollama":{"endpoint":"http://localhost:11434","model":"llama3.1"}}"#)

        let provider = try await resolver.resolve()
        XCTAssertEqual(provider.identity.id, "ollama-cleanup")

        let converse = try await resolver.resolve(mode: .conversing)
        XCTAssertEqual(
            converse.identity.id, "rules-cleanup",
            "an absent converseProvider is the rules default, silently")
    }

    /// **`resolve(mode: .conversing)` returns the converse selection** — `converseProvider: byok`
    /// is the BYOK chain for conversations, while the no-arg `resolve()` keeps answering the
    /// dictate half.
    func testResolveForConversingReturnsTheConverseSelection() async throws {
        let resolver = Self.makeResolver(
            over: Self.tempDirectory(),
            configJSON: #"{"provider":"rules","converseProvider":"byok","byok":{"endpoint":"https://api.example.com/v1","model":"gpt-4o-mini"}}"#)

        let converse = try await resolver.resolve(mode: .conversing)
        let chain = try XCTUnwrap(converse as? ChainedCleanupProvider)
        XCTAssertEqual(chain.identity.id, "byok-cleanup")
        let byok = try XCTUnwrap(chain.llm as? BYOKCleanupProvider)
        XCTAssertEqual(byok.endpoint, URL(string: "https://api.example.com/v1"))

        let dictate = try await resolver.resolve()
        XCTAssertEqual(dictate.identity.id, "rules-cleanup")
    }

    // MARK: - One file read, both halves

    /// **Both modes resolve from one file read.** The single-flight guard holds the pair; a
    /// `resolve()` followed by `resolve(mode: .conversing)` reads the file exactly once — the
    /// B4 pin held with both halves resolved.
    func testBothModesResolveFromOneFileRead() async throws {
        let fileSystem = PerModeCountingConfigFileSystem(
            fileExistsResult: true,
            data: Data(#"{"provider":"byok","converseProvider":"byok","byok":{"endpoint":"https://api.example.com/v1","model":"gpt-4o-mini"}}"#.utf8))
        let resolver = CleanupResolver(
            store: CleanupConfigStore(
                directory: Self.tempDirectory(), fileSystem: fileSystem, log: { _ in }),
            transport: {
                StubLLMTransport(mode: .happyPath(response: LLMResponse(statusCode: 200, body: Data())))
            },
            keyProvider: { StubPerModeKeyProvider() },
            log: { _ in })

        _ = try await resolver.resolve()
        _ = try await resolver.resolve(mode: .conversing)

        let calls = await fileSystem.fileExistsCalls
        XCTAssertEqual(
            calls, 1,
            "the pair is built in the one flight — a second mode must not re-read the file")
    }

    /// **Both halves never swap after resolution.** A second resolve of either mode returns the
    /// cached half; the file read count stays 1.
    func testBothModesNeverSwapAfterResolution() async throws {
        let fileSystem = PerModeCountingConfigFileSystem(
            fileExistsResult: true,
            data: Data(#"{"provider":"ollama","ollama":{"endpoint":"http://localhost:11434","model":"llama3.1"},"converseProvider":"rules"}"#.utf8))
        let resolver = CleanupResolver(
            store: CleanupConfigStore(
                directory: Self.tempDirectory(), fileSystem: fileSystem, log: { _ in }),
            transport: {
                StubLLMTransport(mode: .happyPath(response: LLMResponse(statusCode: 200, body: Data())))
            },
            keyProvider: { StubPerModeKeyProvider() },
            log: { _ in })

        let firstDictate = try await resolver.resolve()
        let firstConverse = try await resolver.resolve(mode: .conversing)
        let secondDictate = try await resolver.resolve()
        let secondConverse = try await resolver.resolve(mode: .conversing)

        XCTAssertEqual(firstDictate.identity.id, "ollama-cleanup")
        XCTAssertEqual(firstConverse.identity.id, "rules-cleanup")
        XCTAssertEqual(secondDictate.identity.id, firstDictate.identity.id)
        XCTAssertEqual(secondConverse.identity.id, firstConverse.identity.id)
        let calls = await fileSystem.fileExistsCalls
        XCTAssertEqual(calls, 1, "resolve-once holds per mode")
    }

    // MARK: - The per-mode degrade

    /// **An unknown converse selection resolves to rules, loudly** — and the dictate half is
    /// untouched.
    func testAnUnknownConverseSelectionResolvesToRulesLoudly() async throws {
        let logs = LogCollector()
        let resolver = Self.makeResolver(
            over: Self.tempDirectory(),
            configJSON: #"{"provider":"ollama","ollama":{"endpoint":"http://localhost:11434","model":"llama3.1"},"converseProvider":"spaceship"}"#,
            log: { logs.append($0) })

        let converse = try await resolver.resolve(mode: .conversing)
        XCTAssertEqual(converse.identity.id, "rules-cleanup")
        let dictate = try await resolver.resolve()
        XCTAssertEqual(dictate.identity.id, "ollama-cleanup", "the dictate half stands")
        XCTAssertEqual(logs.entries.count, 1, "one loud log, naming the unknown string")
        XCTAssertTrue(logs.entries[0].contains("spaceship"))
    }

    /// **An invalid converse block resolves to rules while dictation stands** — converse byok at
    /// an undialable endpoint lands on converse rules with one loud log, and the dictate ollama
    /// chain is intact.
    func testAnInvalidConverseBlockResolvesToRulesWhileDictationStands() async throws {
        let logs = LogCollector()
        let resolver = Self.makeResolver(
            over: Self.tempDirectory(),
            configJSON: #"{"provider":"ollama","ollama":{"endpoint":"http://localhost:11434","model":"llama3.1"},"converseProvider":"byok","byok":{"endpoint":"not a url"}}"#,
            log: { logs.append($0) })

        let converse = try await resolver.resolve(mode: .conversing)
        XCTAssertEqual(converse.identity.id, "rules-cleanup")
        let dictate = try await resolver.resolve()
        XCTAssertEqual(dictate.identity.id, "ollama-cleanup")
        XCTAssertEqual(logs.entries.count, 1)
    }

    // MARK: - The half keeps its declared budget and egress

    /// **The timeout-yields-raw evidence at this aspect's boundary**: the caller races the
    /// half's declared numbers, per mode — rules is the 10 ms offline default, and each LLM
    /// chain declares the LLM stage's 5 s and its egress (the B6 propagation, now pinned per
    /// mode).
    func testTheConverseProviderKeepsItsDeclaredBudgetAndEgress() async throws {
        // Converse rules: the shipped 10 ms, offline.
        let rulesResolver = Self.makeResolver(
            over: Self.tempDirectory(), configJSON: #"{"provider":"rules"}"#)
        let rules = try await rulesResolver.resolve(mode: .conversing)
        XCTAssertEqual(rules.budget, .milliseconds(10))
        XCTAssertFalse(rules.requiresNetwork)

        // Converse ollama: the chain over the Ollama stage — 5 s, and the stage's declared
        // egress (an LLM round-trip sends text off the process).
        let ollamaResolver = Self.makeResolver(
            over: Self.tempDirectory(),
            configJSON: #"{"provider":"rules","converseProvider":"ollama","ollama":{"endpoint":"http://localhost:11434","model":"llama3.1"}}"#)
        let ollama = try await ollamaResolver.resolve(mode: .conversing)
        XCTAssertEqual(ollama.budget, .seconds(5))
        XCTAssertTrue(
            ollama.requiresNetwork,
            "the chain declares the LLM stage's egress — the badge keys on it")

        // Converse byok: the chain over the BYOK stage — 5 s, and the stage's egress.
        let byokResolver = Self.makeResolver(
            over: Self.tempDirectory(),
            configJSON: #"{"provider":"rules","converseProvider":"byok","byok":{"endpoint":"https://api.example.com/v1","model":"gpt-4o-mini"}}"#)
        let byok = try await byokResolver.resolve(mode: .conversing)
        XCTAssertEqual(byok.budget, .seconds(5))
        XCTAssertTrue(byok.requiresNetwork)
    }

    // MARK: - Construction never dials

    /// **Resolving the converse half performs no transport call.** The stub transport records
    /// `complete` calls; resolving `.conversing` performs none — construction-only, the
    /// never-block / zero-network-by-default posture.
    func testResolvingConversingNeverDialstheTransport() async throws {
        let transport = StubLLMTransport(
            mode: .happyPath(response: LLMResponse(statusCode: 200, body: Data())))
        let resolver = CleanupResolver(
            store: CleanupConfigStore(directory: Self.tempDirectory(), log: { _ in }),
            transport: { transport },
            keyProvider: { StubPerModeKeyProvider() },
            log: { _ in })

        _ = try await resolver.resolve(mode: .conversing)
        let calls = await transport.recordedRequests
        XCTAssertTrue(
            calls.isEmpty,
            "resolving constructs the chain; nothing is dialed")
    }

    // MARK: - The surface stays (compile pins)

    /// **The mode-scoped surface exists and the no-arg forms still exist** — the compile pins
    /// the wiring compiles against: `resolve(mode:)`/`summary(mode:)`/`egressEndpoint(mode:)`
    /// per half, no-arg `resolve()`/`summary()`/`egressEndpoint()` as the dictate forms.
    func testTheModeScopedSurfaceCompiles() async throws {
        let resolver = Self.makeResolver(over: Self.tempDirectory(), configJSON: nil)

        let provider = try await resolver.resolve()
        let modeProvider = try await resolver.resolve(mode: .dictation)
        let summary = await resolver.summary()
        let modeSummary = await resolver.summary(mode: .conversing)
        let endpoint = await resolver.egressEndpoint()
        let modeEndpoint = await resolver.egressEndpoint(mode: .conversing)

        XCTAssertEqual(provider.identity.id, modeProvider.identity.id)
        XCTAssertEqual(summary.name, modeSummary.name)
        XCTAssertEqual(endpoint, modeEndpoint)
    }

    // MARK: - Fixtures

    /// Builds a resolver over a temp directory, writing `configJSON` when non-nil, with stub
    /// transport/key factories and an injectable log — the `CleanupResolverTests` harness shape.
    private static func makeResolver(
        over directory: URL,
        configJSON: String?,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> CleanupResolver {
        if let configJSON {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? configJSON.write(
                to: directory.appendingPathComponent("cleanup-config.json"),
                atomically: true, encoding: .utf8)
        }
        return CleanupResolver(
            store: CleanupConfigStore(directory: directory, log: log),
            transport: {
                StubLLMTransport(mode: .happyPath(response: LLMResponse(statusCode: 200, body: Data())))
            },
            keyProvider: { StubPerModeKeyProvider() },
            log: log)
    }

    /// A fresh throwaway directory for one test.
    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-cleanup-resolver-per-mode-\(UUID().uuidString)")
    }
}

/// A key-seam double for the per-mode resolver tests — never a real Keychain.
private struct StubPerModeKeyProvider: KeyProvider {
    func key() throws -> String? {
        "stub-key"
    }
}

/// A config file-system double that counts its calls — the one-file-read proof for the pair
/// shape (`CountingConfigFileSystem`'s role in `CleanupResolverTests`, private there, so this
/// suite carries its own).
private actor PerModeCountingConfigFileSystem: CleanupConfigFileSystem {
    private(set) var fileExistsCalls = 0
    private let fileExistsResult: Bool
    private let data: Data?

    init(fileExistsResult: Bool = true, data: Data? = nil) {
        self.fileExistsResult = fileExistsResult
        self.data = data
    }

    func fileExists(atPath path: String) async -> Bool {
        fileExistsCalls += 1
        return fileExistsResult
    }

    func read(_ url: URL) async -> Data? {
        data
    }

    // The write half of the seam refuses loudly — a resolver test that silently "saved" would
    // be claiming something about a path it never exercises.
    struct WriteNotSupported: Error {}

    func createDirectory(at url: URL) async throws { throw WriteNotSupported() }
    func write(_ data: Data, to url: URL) async throws { throw WriteNotSupported() }
    func moveItem(at source: URL, to destination: URL) async throws { throw WriteNotSupported() }
}