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

/// **F3 — the Cleanup tab reports the provider Vocca resolved, not a literal.**
///
/// `AppBootstrap.showSettings()` passed `cleanupSummary: { ("Built-in rules", nil) }`. A constant.
/// A user on Ollama or BYOK read "Built-in rules" with no endpoint while the widget's egress badge
/// correctly showed the cloud marker, and `SettingsView` calls that egress line *"the point of
/// this tab … where they can check before it ever does"* — a line that could never appear.
///
/// The derivation is pure and lives in `VoccaCore`, so every decision in it runs headlessly: the
/// endpoint is shown **only** when the resolved provider declares `requiresNetwork`, and a
/// provider that declares it with no endpoint still says the text leaves.
final class CleanupSummaryTests: XCTestCase {

    // MARK: - The pure derivation

    /// **A local provider reports its name and nothing else.** No endpoint, and the tab's
    /// "nothing is sent anywhere" line is the correct one.
    func testALocalProviderReportsNoEndpoint() {
        let summary = CleanupSummary.resolved(
            identity: ProviderIdentity(id: "rules-cleanup", displayName: "Deterministic rules"),
            requiresNetwork: false,
            endpoint: nil)

        XCTAssertEqual(summary.name, "Deterministic rules")
        XCTAssertNil(summary.endpoint)
        XCTAssertFalse(summary.sendsTextOffTheMac)
    }

    /// **A network provider reports the endpoint the text goes to** — the same fact the egress
    /// badge hovers, so the two surfaces agree by construction rather than by coincidence.
    func testANetworkProviderReportsItsEndpoint() {
        let summary = CleanupSummary.resolved(
            identity: ProviderIdentity(id: "byok-cleanup", displayName: "BYOK"),
            requiresNetwork: true,
            endpoint: "https://api.example.com/v1")

        XCTAssertEqual(summary.name, "BYOK")
        XCTAssertEqual(summary.endpoint, "https://api.example.com/v1")
        XCTAssertTrue(summary.sendsTextOffTheMac)
    }

    /// **An endpoint is never rendered for a provider that does not use the network.**
    ///
    /// The load-bearing row. `requiresNetwork` is the seam's own egress declaration
    /// (`CleanupProvider.swift:51`) and the endpoint is bookkeeping beside it, so a resolve that
    /// degraded a bad LLM block to rules while an endpoint string was still in hand must not
    /// produce a cloud line over a provider that never dials. The declaration decides; the string
    /// only names.
    func testAnEndpointIsNeverShownForAProviderThatDoesNotUseTheNetwork() {
        let summary = CleanupSummary.resolved(
            identity: ProviderIdentity(id: "rules-cleanup", displayName: "Deterministic rules"),
            requiresNetwork: false,
            endpoint: "https://api.example.com/v1")

        XCTAssertNil(summary.endpoint, "a provider that does not dial has no endpoint to show")
        XCTAssertFalse(summary.sendsTextOffTheMac)
    }

    /// **A network provider with no endpoint still says the text leaves.**
    ///
    /// The other direction of the same rule, and the one that decides why this type carries a flag
    /// rather than only an optional string. "Text leaves your Mac" and "here is where it goes" are
    /// two facts, and a page that inferred the first from the second would fall silent — rendering
    /// the reassuring local line — in exactly the case it cannot name the destination.
    func testANetworkProviderWithNoEndpointStillSaysTheTextLeaves() {
        let summary = CleanupSummary.resolved(
            identity: ProviderIdentity(id: "byok-cleanup", displayName: "BYOK"),
            requiresNetwork: true,
            endpoint: nil)

        XCTAssertTrue(
            summary.sendsTextOffTheMac,
            "the egress declaration is the fact; the endpoint only names the destination")
        XCTAssertNil(summary.endpoint)
    }

    // MARK: - Through the real resolver

    /// **The default configuration resolves to a summary with no egress.** The absent file is the
    /// rules provider, and the tab says so — the same path the zero-network probe drives.
    func testTheDefaultConfigurationSummarisesAsLocal() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let summary = await Self.resolver(directory: directory).summary()

        XCTAssertFalse(summary.sendsTextOffTheMac)
        XCTAssertNil(summary.endpoint)
        XCTAssertEqual(summary.name, "Deterministic rules")
    }

    /// **A BYOK config resolves to a summary naming its endpoint.** The test the plan says fails
    /// today: with the literal in place this tab reported "Built-in rules" and no endpoint for
    /// exactly this file.
    func testABYOKConfigurationSummarisesWithItsEndpoint() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(
            #"{"provider":"byok","byok":{"endpoint":"https://api.example.com/v1","model":"gpt-4o-mini"}}"#
                .utf8
        ).write(to: directory.appendingPathComponent("cleanup-config.json"))

        let summary = await Self.resolver(directory: directory).summary()

        XCTAssertTrue(summary.sendsTextOffTheMac)
        XCTAssertEqual(summary.endpoint, "https://api.example.com/v1")
        XCTAssertEqual(summary.name, "BYOK")
    }

    /// **A degraded LLM block summarises as local, and names the provider actually running.**
    ///
    /// An `ollama` selection with an undialable endpoint degrades to rules with a loud log
    /// (`CleanupResolver.build()`). The tab must report what is *running*, which is the whole
    /// point of deriving it from the resolved provider: a page that echoed the file would tell a
    /// user their text goes to a machine nothing ever dials.
    func testADegradedLLMBlockSummarisesAsLocal() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"provider":"ollama","ollama":{"endpoint":"not a url","model":"llama3.1"}}"#.utf8)
            .write(to: directory.appendingPathComponent("cleanup-config.json"))

        let summary = await Self.resolver(directory: directory).summary()

        XCTAssertFalse(summary.sendsTextOffTheMac, "nothing dials, so nothing leaves")
        XCTAssertNil(summary.endpoint)
        XCTAssertEqual(summary.name, "Deterministic rules")
    }

    // MARK: - The wiring (F3)

    /// **The composition root no longer hands the tab a constant.**
    ///
    /// A source scan, because the defect was not a wrong value a behavioural test could catch —
    /// it was a literal that no amount of configuration could move. The scan fails against the
    /// shipped `showSettings()` as it stood before this aspect, which is why it is here.
    func testTheSummaryBindingIsNotAHardcodedLiteral() throws {
        let body = try Self.showSettingsBody()

        XCTAssertFalse(
            body.contains("\"Built-in rules\""),
            "the tab reported a literal regardless of the resolved provider — F3")
        XCTAssertTrue(
            body.contains("cleanupSummary"),
            "the binding must still be wired; a removed binding is not a fix")
        XCTAssertTrue(
            body.contains("cleanupResolver"),
            "the summary is derived from the resolver, which is the fact rather than a copy of it")
    }

    // MARK: - Fixtures

    /// A resolver over `directory` with both LLM seams stubbed — nothing here dials, and the
    /// summary is a question about declarations, not about traffic.
    private static func resolver(directory: URL) -> CleanupResolver {
        CleanupResolver(
            store: CleanupConfigStore(directory: directory, log: { _ in }),
            transport: { StubSummaryTransport() },
            keyProvider: { StubSummaryKeyProvider() },
            log: { _ in })
    }

    /// A fresh throwaway directory for one test.
    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-cleanup-summary-\(UUID().uuidString)")
    }

    /// The braced body of `showSettings()`, comments stripped — so a mention in prose is never
    /// mistaken for a binding (the `SpeechTabWiringTests` scanner, reused).
    private static func showSettingsBody() throws -> String {
        let root = try PackageRootLocator.find(from: #filePath)
        let file = root.appendingPathComponent("Sources/VoccaBootstrap/AppBootstrap.swift")
        let source = SwiftSourceScanner.stripComments(
            from: try String(contentsOf: file, encoding: .utf8))
        let header = "public func showSettings()"
        guard let start = source.range(of: header) else {
            XCTFail("showSettings() must still exist — it is the Settings window's one entry point")
            return ""
        }
        return String(source[start.lowerBound...])
    }
}

/// A transport that refuses every call — the summary never sends anything, and a double that
/// answered would be pretending otherwise.
private struct StubSummaryTransport: LLMTransport {
    struct NeverDialed: Error {}

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        throw NeverDialed()
    }
}

/// A key seam double — never a real Keychain.
private struct StubSummaryKeyProvider: KeyProvider {
    func key() throws -> String? { "stub-key" }
}
