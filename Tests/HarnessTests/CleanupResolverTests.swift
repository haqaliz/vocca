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

/// The cleanup resolver's contract (spec B4–B5): **one provider for the process**, resolved once
/// from the hand-edited config at launch (`DictationEngineResolver` resolve-once shape,
/// `spec.md:33-41`).
///
/// The resolver is the single source of "which provider runs": the composition root holds its
/// answer, nothing else reads the file, and a mid-session re-read is structurally impossible —
/// the file is read at most once, by the one in-flight build, and a second resolve returns the
/// cached provider. Absent/unknown/invalid configurations all land on the rules provider, with
/// the loud half of that policy already emitted by the store's tolerant decode.
///
/// Driven headlessly over real temp directories (the store executes in CI), a counting/gated
/// config file system for the resolve-once proof, and stub transport/key factories — the probe
/// wires fakes through these same slots (`root-wiring`).
final class CleanupResolverTests: XCTestCase {

    // MARK: - B4: resolve-once

    /// **B4 — concurrent resolves share one build; a resolve after success never re-reads.**
    /// The first resolve parks inside the file read (the armed gate); the second arrives while it
    /// is in flight and must share it — the file system sees exactly one `fileExists` across both.
    /// After success, further resolves return the cached provider with the count unchanged.
    func testResolveIsSingleFlightAndNeverReReadsTheFile() async throws {
        let gate = AsyncGate()
        await gate.arm()
        let fileSystem = CountingConfigFileSystem(
            gate: gate, fileExistsResult: true,
            data: Data(#"{"provider":"rules"}"#.utf8))
        let resolver = CleanupResolver(
            store: CleanupConfigStore(
                directory: Self.tempDirectory(), fileSystem: fileSystem, log: { _ in }),
            transport: { StubLLMTransport(mode: .happyPath(response: LLMResponse(statusCode: 200, body: Data()))) },
            keyProvider: { StubResolverKeyProvider() },
            log: { _ in })

        let first = Task { try? await resolver.resolve() }
        for _ in 0..<2000 where await fileSystem.fileExistsCalls == 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let parkedCalls = await fileSystem.fileExistsCalls
        XCTAssertEqual(
            parkedCalls, 1,
            "the first resolve must be parked in the file read before the second arrives")

        let second = Task { try? await resolver.resolve() }
        try? await Task.sleep(for: .milliseconds(50))
        let concurrentCalls = await fileSystem.fileExistsCalls
        XCTAssertEqual(
            concurrentCalls, 1,
            "the second resolve must share the first's build, not re-read the file")

        await gate.release()
        let a = try Self.unwrap(await first.value)
        let b = try Self.unwrap(await second.value)
        XCTAssertEqual(a.identity.id, "rules-cleanup")
        XCTAssertEqual(
            a.identity, b.identity,
            "both concurrent callers receive the same provider")

        let third = try Self.unwrap(try? await resolver.resolve())
        XCTAssertEqual(
            third.identity, a.identity,
            "a resolve after success returns the cached provider")
        let finalCalls = await fileSystem.fileExistsCalls
        XCTAssertEqual(
            finalCalls, 1,
            "the file must never be re-read once resolved")
    }

    // MARK: - B5: the decision table

    /// **B5 — an absent file resolves to the rules provider.** The default configuration: rules,
    /// zero network.
    func testAnAbsentFileResolvesToTheRulesProvider() async throws {
        let resolver = Self.makeResolver(over: Self.tempDirectory(), configJSON: nil)
        let provider = try await resolver.resolve()
        XCTAssertEqual(
            provider.identity.id, "rules-cleanup",
            "an absent file is the rules provider, silently")
    }

    /// **B5 — an explicit `rules` config resolves to the rules provider.**
    func testARulesConfigResolvesToTheRulesProvider() async throws {
        let resolver = Self.makeResolver(over: Self.tempDirectory(), configJSON: #"{"provider":"rules"}"#)
        let provider = try await resolver.resolve()
        XCTAssertEqual(provider.identity.id, "rules-cleanup")
    }

    /// **B5 — an `ollama` config resolves to a chain whose LLM stage is the Ollama provider with
    /// the configured endpoint and model.**
    func testAnOllamaConfigResolvesToAChainOverAnOllamaStage() async throws {
        let resolver = Self.makeResolver(
            over: Self.tempDirectory(),
            configJSON: #"{"provider":"ollama","ollama":{"endpoint":"http://localhost:11434","model":"llama3.1"}}"#)

        let provider = try await resolver.resolve()

        let chain = try XCTUnwrap(provider as? ChainedCleanupProvider)
        XCTAssertEqual(
            chain.identity.id, "ollama-cleanup",
            "the chain attributes to the LLM stage — the decisive provider")
        let ollama = try XCTUnwrap(chain.llm as? OllamaCleanupProvider)
        XCTAssertEqual(ollama.endpoint, URL(string: "http://localhost:11434"))
        XCTAssertEqual(ollama.model, "llama3.1")
    }

    /// **B5 — a `byok` config resolves to a chain over the BYOK provider with the configured
    /// endpoint and model.**
    func testAByokConfigResolvesToAChainOverAByokStage() async throws {
        let resolver = Self.makeResolver(
            over: Self.tempDirectory(),
            configJSON: #"{"provider":"byok","byok":{"endpoint":"https://api.example.com/v1/chat/completions","model":"gpt-4o-mini"}}"#)

        let provider = try await resolver.resolve()

        let chain = try XCTUnwrap(provider as? ChainedCleanupProvider)
        XCTAssertEqual(chain.identity.id, "byok-cleanup")
        let byok = try XCTUnwrap(chain.llm as? BYOKCleanupProvider)
        XCTAssertEqual(byok.endpoint, URL(string: "https://api.example.com/v1/chat/completions"))
        XCTAssertEqual(byok.model, "gpt-4o-mini")
    }

    /// **B5 — an `ollama` block without a model resolves to rules with a loud log.** The
    /// tolerant decode already degraded to `.rules` and logged; the resolver builds the rules
    /// provider.
    func testAnOllamaBlockWithoutAModelResolvesToRulesWithALoudLog() async throws {
        let logs = LogCollector()
        let resolver = Self.makeResolver(
            over: Self.tempDirectory(),
            configJSON: #"{"provider":"ollama","ollama":{"endpoint":"http://localhost:11434"}}"#,
            log: { logs.append($0) })

        let provider = try await resolver.resolve()

        XCTAssertEqual(provider.identity.id, "rules-cleanup")
        XCTAssertEqual(
            logs.entries.count, 1,
            "an invalid block must be loud, never silently different from the file")
    }

    /// **B5 — an unknown kind resolves to rules with a loud log.**
    func testAnUnknownKindResolvesToRulesWithALoudLog() async throws {
        let logs = LogCollector()
        let resolver = Self.makeResolver(
            over: Self.tempDirectory(),
            configJSON: #"{"provider":"claude"}"#,
            log: { logs.append($0) })

        let provider = try await resolver.resolve()

        XCTAssertEqual(provider.identity.id, "rules-cleanup")
        XCTAssertEqual(logs.entries.count, 1)
    }

    // MARK: - Fixtures

    /// Builds a resolver over a temp directory, writing `configJSON` when non-nil, with stub
    /// transport/key factories and an injectable log.
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
            keyProvider: { StubResolverKeyProvider() },
            log: log)
    }

    /// A fresh throwaway directory for one test.
    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-cleanup-resolver-\(UUID().uuidString)")
    }

    /// Unwraps an optional provider from a `try?`-shaped task, failing the test on nil.
    private static func unwrap(_ optional: (any CleanupProvider)?) throws -> any CleanupProvider {
        try XCTUnwrap(optional)
    }
}

/// A key-seam double for the resolver tests — never a real Keychain.
private struct StubResolverKeyProvider: KeyProvider {
    func key() throws -> String? {
        "stub-key"
    }
}

/// A config file-system double that counts its calls and can park the file-existence read on a
/// gate — the B4 single-flight proof's observability.
private actor CountingConfigFileSystem: CleanupConfigFileSystem {
    private(set) var fileExistsCalls = 0
    private(set) var readCalls = 0
    private let gate: AsyncGate?
    private let fileExistsResult: Bool
    private let data: Data?

    init(gate: AsyncGate? = nil, fileExistsResult: Bool = true, data: Data? = nil) {
        self.gate = gate
        self.fileExistsResult = fileExistsResult
        self.data = data
    }

    func fileExists(atPath path: String) async -> Bool {
        fileExistsCalls += 1
        if let gate { await gate.waitIfArmed() }
        return fileExistsResult
    }

    func read(_ url: URL) async -> Data? {
        readCalls += 1
        return data
    }

    // The write half of the seam. This double exists to count *reads*, so the writes refuse
    // loudly rather than pretending: a resolver test that silently "saved" would be claiming
    // something about a path it never exercises.
    struct WriteNotSupported: Error {}

    func createDirectory(at url: URL) async throws { throw WriteNotSupported() }

    func write(_ data: Data, to url: URL) async throws { throw WriteNotSupported() }

    func moveItem(at source: URL, to destination: URL) async throws { throw WriteNotSupported() }
}
