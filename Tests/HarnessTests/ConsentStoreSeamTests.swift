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
import XCTest

/// The consent store's seam — the `consent-store` aspect's Phase 1 pins
/// (`plan_20260918.md`), written before the store exists. Failing to compile is the red state:
/// no `ConsentStore` is in scope yet, the `mode-machine` precedent for a new store.
///
/// What is pinned here, in the ``ASREngineSeamTests`` shape:
///
/// - a conformer implementing exactly `load`/`set`/`save` — and nothing else — satisfies the
///   protocol, and those three members are referenced by name through the existential: a fourth
///   *required* member breaks the stub's conformance and a rename breaks this file, so the
///   seam's surface is a compile-time fact rather than a comment;
/// - ``ConsentBundleID.isValid`` answers on the pinned reverse-DNS vocabulary (D4): nil, empty,
///   whitespace and no-dot strings are refused, a real bundle ID and a 255-char boundary string
///   are accepted, and a 256-char string is refused — the validation is what makes "bundle IDs
///   only" a property of the vocabulary (`prd.md` M10), so its boundary is pinned here first;
/// - `maximumConsentedApps == 512`, in exactly one definition (`plan_20260918.md` D3, the
///   strategies cap's single-source precedent).
final class ConsentStoreSeamTests: XCTestCase {

    /// A store that implements exactly `load`/`set`/`save` — and **not** a fourth member —
    /// still satisfies the protocol.
    ///
    /// This is the seam-shape claim in its compile-time form: the moment a fourth requirement
    /// joins `ConsentStore`, `StubConsentStore` stops conforming and this file stops building.
    /// The seam is the `usage-store` precedent — the store of the consent set, separated from
    /// everything that decides about consent, so the decisions run headless over the
    /// ``PersistentConsentStoreTests`` doubles.
    func testAStoreWithJustLoadSetAndSaveSatisfiesTheProtocol() {
        func requireConsentStore(_ store: any ConsentStore) -> any ConsentStore { store }

        let stub = StubConsentStore()
        let store = requireConsentStore(stub)
        XCTAssertTrue(store is StubConsentStore)
    }

    /// The seam carries exactly `load`, `set(_:consented:)` and `save(_:)` — each referenced
    /// through the existential, so a rename or a signature change fails here to compile.
    func testTheSeamCarriesExactlyLoadSetAndSave() async throws {
        let store: any ConsentStore = StubConsentStore()

        let loaded = await store.load()
        XCTAssertEqual(loaded, [], "the stub answers the empty consent")

        let accepted = try await store.set("com.example.app", consented: true)
        XCTAssertTrue(accepted, "the stub accepts every set")

        try await store.save(["com.example.app"])
    }

    /// The reverse-DNS vocabulary, pinned at its boundaries: `nil`, empty, whitespace and
    /// no-dot strings are not bundle IDs; a real bundle ID is; 255 characters is the ceiling
    /// and 256 is not a bundle ID.
    func testBundleIDValidationAnswersOnThePinnedReverseDNSVocabulary() {
        XCTAssertFalse(
            ConsentBundleID.isValid(nil),
            "no bundle identifier at all is not a bundle ID — the gate's nil refusal")
        XCTAssertFalse(ConsentBundleID.isValid(""), "the empty string is not a bundle ID")
        XCTAssertFalse(
            ConsentBundleID.isValid("  "),
            "whitespace is not a bundle ID — a content-shaped string must not slip through")
        XCTAssertFalse(
            ConsentBundleID.isValid("nodot"),
            "a reverse-DNS bundle ID has at least one dot — no-dot strings are not bundle IDs")
        XCTAssertTrue(
            ConsentBundleID.isValid("com.example.app"),
            "a real reverse-DNS bundle ID is the vocabulary's resident")
        XCTAssertTrue(
            ConsentBundleID.isValid("com.apple.Notes"),
            "a real system bundle ID validates — the vocabulary must admit the apps it exists for")

        let ceiling = "com.example." + String(repeating: "a", count: 243)
        XCTAssertEqual(ceiling.count, 255, "the boundary string must be exactly 255 chars")
        XCTAssertTrue(
            ConsentBundleID.isValid(ceiling),
            "255 characters is the ceiling — the reverse-DNS bound the validation promises")
        XCTAssertFalse(
            ConsentBundleID.isValid(ceiling + "b"),
            "256 characters is not a bundle ID — the validation must bound what it accepts")
    }

    /// The consent cap is the ``LatencyLedger.maximumRetainedRecords`` shape: a named value
    /// whose **definition** (`maximumConsentedApps = 512`) lives in exactly the one Core file
    /// and this pinning test — the ``WarmStartRatio`` single-source precedent. The bare `512`
    /// numeral and the name itself legitimately appear elsewhere, so the scan pins the
    /// definition, not the identifier or the numeral: a second *definition* of the bound under
    /// another name would be a second home.
    func testTheConsentCapLivesOnlyInTheNamedConstant() throws {
        XCTAssertEqual(ConsentStoreConstants.maximumConsentedApps, 512)

        let root = try PackageRootLocator.find(from: #filePath)
        let namedFile = "ConsentStore.swift"
        let pinningTest = "ConsentStoreSeamTests.swift"
        let allowedSightings: Set<String> = [namedFile, pinningTest]
        let pattern = #"maximumConsentedApps = 512"#
        var sightings: [String: Int] = [:]
        for tree in [root.appendingPathComponent("Sources"), root.appendingPathComponent("Tests")] {
            for file in SwiftSourceScanner.swiftFiles(under: tree) {
                let content = try String(contentsOf: file, encoding: .utf8)
                if SwiftSourceScanner.stripComments(from: content).contains(pattern) {
                    sightings[file.lastPathComponent, default: 0] += 1
                }
            }
        }

        XCTAssertFalse(sightings.isEmpty, "vacuity guard: the scan saw no files at all")
        XCTAssertEqual(
            Set(sightings.keys), allowedSightings,
            "the cap's definition must live in exactly the named Core file and its pinning test, got: \(sightings)")
        XCTAssertEqual(
            sightings[namedFile], 1,
            "the named file's own definition must exist — the vacuity guard's second direction")
    }
}

/// A store implementing exactly the seam's three members — the compile pin that a fourth
/// member would break.
private struct StubConsentStore: ConsentStore {
    func load() async -> Set<String> { [] }

    func set(_ bundleID: String, consented: Bool) async throws -> Bool { true }

    func save(_ ids: Set<String>) async throws {}
}