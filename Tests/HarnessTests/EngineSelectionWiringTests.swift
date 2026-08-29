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
import VoccaASR
import VoccaBootstrap
import VoccaCore
import VoccaUI
import XCTest

/// **The composition root reads the engine the user chose, at every site that used to hardcode it.**
///
/// Five sites in `AppBootstrap.configure` named `EngineSelection.defaultSelection` outright: the
/// resolver's selection, the download session's manifest, the download session's base URL, the
/// onboarding step's model-presence check, and the Settings page's engine label. Aspect 2 shipped
/// the store those five should have been reading; this aspect wires it.
///
/// ## Why the load-bearing test here is a source scan
///
/// `configure` needs an `NSApplication` and a run loop, so no test in this suite calls it
/// (`AppBootstrapWiringTests` states the same limit, and `WarmStartLaunchTests` explains why the
/// probe composes its own root rather than calling `configure` with fakes). What a test *can* do is
/// read the shipped source and assert the hardcodes are gone and that the store is read **once** —
/// which is the assertion that matters, because the failure this aspect exists to prevent is not
/// "a site reads the wrong value" but "two sites read different values". A download session that
/// fetches Parakeet's manifest while the resolver builds Whisper is exactly the shape a five-site
/// change invites, and one read cannot produce it.
///
/// The behavioural half is pinned at the seam `configure` hands the store's answer to: the resolver
/// factory, and the three pure derivations (manifest, repository, display name) the other sites are.
final class EngineSelectionWiringTests: XCTestCase {

    // MARK: - The store's answer reaches the resolver

    /// **R1.** A store holding Whisper turbo produces a resolver that has resolved to Whisper; an
    /// empty store produces Parakeet. Driven over the seam the root uses — the resolver factory —
    /// with the real adapter over a scoped defaults suite, never `UserDefaults.standard`.
    func testTheStoredSelectionIsTheSelectionTheResolverIsBuiltWith() {
        let (defaults, name) = Self.makeScopedSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let empty = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(
            AppBootstrap.makeResolver(
                selection: empty.engineSelection(), store: ModelStore(),
                clock: ContinuousMonotonicClock()
            ).selection,
            EngineSelection.defaultSelection,
            "a fresh install runs the shipped default — Parakeet v3")

        UserDefaultsSettingsStore(defaults: defaults).setEngineSelection(
            EngineSelection(tier: .whisperTurbo))
        let chosen = UserDefaultsSettingsStore(defaults: defaults)
        let resolver = AppBootstrap.makeResolver(
            selection: chosen.engineSelection(), store: ModelStore(),
            clock: ContinuousMonotonicClock())
        XCTAssertEqual(
            resolver.selection, EngineSelection(tier: .whisperTurbo),
            "the chosen engine is the engine the process resolves — no restart, no hardcode")
        XCTAssertEqual(
            resolver.selection.tier.engine, EngineCandidate.whisperTurbo,
            "and it really is the whisper engine, not the whisper tier of Parakeet")
    }

    /// **R1.** `defaultSelection` is reached **only** on an empty or unreadable store. The invalid
    /// case is driven too, because it is the one that could silently swallow a real choice: a value
    /// that is present but unreadable falls back *and reports*, so a user whose setting reverted has
    /// something that says why.
    func testTheShippedDefaultIsReachedOnlyByAnEmptyOrUnreadableStore() {
        let (defaults, name) = Self.makeScopedSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let reports = LogCollector()
        let store = UserDefaultsSettingsStore(defaults: defaults, log: { reports.append($0) })

        XCTAssertEqual(store.engineSelection(), EngineSelection.defaultSelection)
        XCTAssertEqual(
            reports.entries, [], "a fresh install has chosen nothing — that is not an error")

        defaults.set("an-engine-that-never-shipped", forKey: UserDefaultsSettingsStore.engineSelectionKey)
        XCTAssertEqual(
            store.engineSelection(), EngineSelection.defaultSelection,
            "an unreadable value degrades to the shipped default — a working configuration")
        XCTAssertEqual(
            reports.entries.count, 1,
            "...and says so exactly once, so a reverted setting is never silent; "
                + "got \(reports.entries)")
    }

    // MARK: - The five sites describe one engine

    /// **R1, the site-agreement row.** Every derivation the five sites make — the manifest, the
    /// repository the manifest resolves against, and the label Settings shows — describes the
    /// **same** engine as the selection it was derived from.
    ///
    /// Driven over the closed set of tiers rather than the two the founder is likely to pick, so a
    /// tier added without a manifest or a repository fails here rather than at a user's first
    /// download.
    func testEveryDerivedSiteDescribesTheSelectionItWasDerivedFrom() throws {
        for tier in EngineTier.allCases {
            let selection = EngineSelection(tier: tier)
            let manifest = try ShippedModelManifest.load(for: selection.tier)
            XCTAssertEqual(
                manifest.engineID, selection.tier.storageID,
                """
                \(tier)'s manifest must name \(tier)'s own storage key. Storage is keyed by tier \
                rather than by engine (aspect 1: two Whisper tiers sharing one verified marker), so \
                this is the assertion that catches a download session fetching one tier's bytes \
                while the resolver loads another's — the defect the single read exists to prevent.
                """)
            XCTAssertEqual(
                AppBootstrap.repositoryURL(for: selection.tier),
                selection.tier.engine == EngineCandidate.parakeetV3
                    ? AppBootstrap.parakeetModelRepository : AppBootstrap.whisperModelRepository,
                "\(tier)'s files are served by its own engine's repository")
            XCTAssertEqual(
                selection.tier.engine.displayName,
                EngineSessionStart.resolve(selection: selection).displayName,
                "the label Settings shows names the engine a session started now would resolve to")
        }
    }

    // MARK: - One read, no hardcodes

    /// **R1, the load-bearing row.** `AppBootstrap.swift` no longer names
    /// `EngineSelection.defaultSelection` anywhere, and reads the store's selection exactly once.
    ///
    /// Both halves matter and they fail for different reasons. A surviving `defaultSelection` is a
    /// site that ignores the user's choice. A *second* `engineSelection()` read is worse and much
    /// harder to see: two reads can answer differently the moment the setting is written between
    /// them, which is precisely the mid-launch window a switch now creates.
    func testTheRootHardcodesNoSelectionAndReadsTheStoreExactlyOnce() throws {
        let source = try Self.bootstrapSource()

        XCTAssertFalse(
            source.contains("EngineSelection.defaultSelection"),
            """
            AppBootstrap.swift still hardcodes EngineSelection.defaultSelection. Every site must \
            derive from the one persisted selection; a hardcode is a site that silently ignores the \
            engine the user chose.
            """)

        let reads = source.components(separatedBy: "engineSelection()").count - 1
        XCTAssertEqual(
            reads, 1,
            """
            the persisted engine selection must be read exactly once in the composition root; \
            found \(reads). Two reads can answer differently, which is how the download session \
            ends up fetching one engine's model while the resolver builds another.
            """)
    }

    // MARK: - Helpers

    /// A fresh, process-unique defaults suite plus its name — the `UserDefaultsSettingsStoreTests`
    /// shape, so the developer's real settings are untouchable from this suite.
    private static func makeScopedSuite() -> (defaults: UserDefaults, name: String) {
        let name = "dev.vocca.tests.engine-wiring.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// `AppBootstrap.swift`, comments stripped — a hardcode that survives only inside a comment is
    /// documentation, not a defect.
    private static func bootstrapSource() throws -> String {
        let root = try PackageRootLocator.find(from: #filePath)
        let file = root.appendingPathComponent("Sources/VoccaBootstrap/AppBootstrap.swift")
        return SwiftSourceScanner.stripComments(from: try String(contentsOf: file, encoding: .utf8))
    }
}
