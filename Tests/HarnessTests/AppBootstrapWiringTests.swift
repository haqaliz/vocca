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
import VoccaUI
import XCTest

/// The composition root's cleanup wiring contract (spec B4) — the piece of `root-wiring` the
/// suite can drive headlessly: the resolver selects the provider once, and the root folds the
/// egress badge from the resolved provider's `requiresNetwork` + endpoint into the widget store.
///
/// `AppBootstrap.configure` itself needs an `NSApplication` and a run loop, so the fold is
/// extracted into the testable shape the root uses — `WidgetEgressState.fromResolvedProvider(
/// requiresNetwork:end point:)` plus the store's `setEgress` — and this suite asserts that
/// shape against a real resolver over real temp directories (absent config ⇒ rules ⇒ `.none`;
/// an `ollama` config ⇒ a `requiresNetwork == true` provider whose endpoint is the configured
/// one ⇒ `.active(endpoint:)`).
final class AppBootstrapWiringTests: XCTestCase {

    // MARK: - B4: the fold helper

    /// **B4 — a `requiresNetwork == true` provider folds `.active(endpoint:)`.**
    func testTheWiringFoldsAnActiveBadgeForANetworkProvider() {
        XCTAssertEqual(
            WidgetEgressState.fromResolvedProvider(
                requiresNetwork: true, endpoint: "http://localhost:11434"),
            .active(endpoint: "http://localhost:11434"))
    }

    /// **B4 — an offline provider folds `.none`.** The default (rules) path is byte-for-byte
    /// today: no network provider, no badge.
    func testTheWiringFoldsNoBadgeForAnOfflineProvider() {
        XCTAssertEqual(
            WidgetEgressState.fromResolvedProvider(requiresNetwork: false, endpoint: nil),
            .none)
    }

    // MARK: - B4: the resolver + fold through the store

    /// **B4 — an absent config resolves to rules and folds `.none` into the store.** The probe
    /// report's `egress=none` is this fold's byte-for-byte surface on the default path.
    @MainActor
    func testTheAbsentConfigFoldsNoEgressIntoTheWidgetStore() async throws {
        let resolver = Self.makeResolver(over: Self.tempDirectory(), configJSON: nil)
        let cleanup = try await resolver.resolve()
        XCTAssertEqual(cleanup.identity.id, "rules-cleanup")
        XCTAssertFalse(cleanup.requiresNetwork)

        let egress = WidgetEgressState.fromResolvedProvider(
            requiresNetwork: cleanup.requiresNetwork, endpoint: await resolver.egressEndpoint())
        XCTAssertEqual(egress, .none)

        let store = WidgetStateStore(clock: TestClock())
        store.setEgress(egress)
        XCTAssertEqual(store.state.egress, .none)
    }

    /// **B4 — an `ollama` config resolves to a `requiresNetwork == true` provider whose endpoint
    /// is the configured one, and folds `.active(endpoint:)` into the store.**
    @MainActor
    func testAnOllamaConfigFoldsActiveEgressIntoTheWidgetStore() async throws {
        let resolver = Self.makeResolver(
            over: Self.tempDirectory(),
            configJSON: #"{"provider":"ollama","ollama":{"endpoint":"http://localhost:11434","model":"llama3.1"}}"#)
        let cleanup = try await resolver.resolve()
        XCTAssertTrue(
            cleanup.requiresNetwork,
            "the resolved Ollama chain must declare the network — the badge keys on it")
        let endpoint = try XCTUnwrap(await resolver.egressEndpoint())
        XCTAssertEqual(endpoint, "http://localhost:11434")

        let egress = WidgetEgressState.fromResolvedProvider(
            requiresNetwork: cleanup.requiresNetwork, endpoint: endpoint)
        XCTAssertEqual(egress, .active(endpoint: "http://localhost:11434"))

        let store = WidgetStateStore(clock: TestClock())
        store.setEgress(egress)
        XCTAssertEqual(store.state.egress, .active(endpoint: "http://localhost:11434"))
    }

    // MARK: - Fixtures

    /// Builds a resolver over a temp directory, writing `configJSON` when non-nil, with stub
    /// transport/key factories.
    private static func makeResolver(
        over directory: URL,
        configJSON: String?
    ) -> CleanupResolver {
        if let configJSON {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? configJSON.write(
                to: directory.appendingPathComponent("cleanup-config.json"),
                atomically: true, encoding: .utf8)
        }
        return CleanupResolver(
            store: CleanupConfigStore(directory: directory, log: { _ in }),
            transport: {
                StubLLMTransport(mode: .happyPath(response: LLMResponse(statusCode: 200, body: Data())))
            },
            keyProvider: { StubWiringKeyProvider() },
            log: { _ in })
    }

    /// A fresh throwaway directory for one test.
    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-wiring-\(UUID().uuidString)")
    }
}

/// A key-seam double for the wiring tests — never a real Keychain.
private struct StubWiringKeyProvider: KeyProvider {
    func key() throws -> String? {
        "stub-key"
    }
}
