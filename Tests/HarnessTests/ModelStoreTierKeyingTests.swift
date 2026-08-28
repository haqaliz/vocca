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
import VoccaCore
import XCTest

/// Storage is keyed by **tier**, not by engine (`model-store-keying/spec.md` R1, R5).
///
/// `ModelStore` keys every model directory as `<root>/<engineID>/<version>/`, and both
/// `isPresent` and `downloadIfMissing` are keyed on that pair. Both Whisper tiers used to declare
/// the *same* pair — `("whisper-large-v3-turbo", "1")` — because they belong to the same
/// ``EngineCandidate``, whose `id` the manifests copied. So the two tiers shared one directory and
/// one verified marker: download q5_0, select turbo, and `downloadIfMissing` short-circuits on the
/// wrong tier's marker while the engine is handed a directory whose `.bin` is 574 MB of q5_0 under
/// the name the full-precision tier expects. **The user silently gets a model they did not
/// choose.**
///
/// The three rows below are the collision itself, the guard against its whole class, and the
/// guard's own gate. No network and no real model: every store here is rooted in a fresh
/// temporary directory and nothing is ever downloaded — the manifests are read from the shipped
/// bundle resources, which is disk, not egress.
final class ModelStoreTierKeyingTests: XCTestCase {

    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
        super.tearDown()
    }

    /// A store rooted at a fresh, empty temporary directory — never the real Application Support.
    private func makeStore() -> ModelStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-tier-keying-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        tempRoots.append(root)
        return ModelStore(rootURL: root)
    }

    /// The uniqueness check R5 asks for, as a pure function over `(engineID, version)` pairs: the
    /// pairs that appear more than once, in the order they were handed over.
    ///
    /// It lives in the test file rather than in the store because it is a claim about the *set of
    /// shipped manifests*, which is a build-time fact — there is no runtime moment at which the
    /// product asks it. Both the shipped-manifest row and its planted-duplicate gate call this
    /// same function, so the gate proves the row.
    private func collidingStorageKeys(in manifests: [ModelManifest]) -> [String] {
        var seen: Set<String> = []
        var collisions: [String] = []
        for manifest in manifests {
            let key = "\(manifest.engineID)@\(manifest.version)"
            if seen.contains(key) {
                collisions.append(key)
            } else {
                seen.insert(key)
            }
        }
        return collisions
    }

    /// R1, and the defect in one line: the two Whisper tiers must resolve to **different**
    /// directories.
    ///
    /// This is the row that matters to a user, because the directory is what the engine is handed.
    /// Two tiers sharing `<root>/whisper-large-v3-turbo/1/` means the second tier's download is
    /// skipped as already-present and the first tier's bytes are loaded under the second tier's
    /// name — a wrong model with no error anywhere, which is the worst shape a storage defect can
    /// take.
    func testTheTwoWhisperTiersResolveToDifferentDirectories() async throws {
        let store = makeStore()
        let turbo = try ShippedModelManifest.load(for: .whisperTurbo)
        let q5 = try ShippedModelManifest.load(for: .whisperTurboQ5)

        let turboURL = await store.baseURL(for: turbo.engineID, version: turbo.version)
        let q5URL = await store.baseURL(for: q5.engineID, version: q5.version)

        XCTAssertNotEqual(
            turboURL, q5URL,
            """
            the whisper turbo and q5_0 tiers resolve to the same model directory, so one tier's \
            verified marker answers for the other and one tier's bytes are loaded under the \
            other's name
            """)
    }

    /// R5, over the real shipped set: no two manifests Vocca ships may declare the same
    /// `(engineID, version)` pair.
    ///
    /// This is the guard that makes the defect's *class* unrepeatable rather than fixing one
    /// instance of it. It enumerates ``EngineTier/allCases``, so a tier added to the Core enum
    /// cannot quietly reuse an existing tier's storage key — the failure lands here, at build
    /// time, rather than on a user's disk.
    func testShippedManifestsHavePairwiseDistinctStorageKeys() throws {
        let manifests = try EngineTier.allCases.map { try ShippedModelManifest.load(for: $0) }
        XCTAssertEqual(manifests.count, EngineTier.allCases.count)

        let collisions = collidingStorageKeys(in: manifests)
        XCTAssertEqual(
            collisions, [],
            "two shipped manifests declare the same (engineID, version) storage key: \(collisions)")
    }

    /// The guard's own gate: a planted duplicate must make the uniqueness check report the
    /// collision.
    ///
    /// A gate that cannot fail proves nothing. The row above passes once the manifests are
    /// corrected, and from then on it would keep passing even if the check itself were broken —
    /// so this row feeds the check two synthetic manifests that deliberately share a pair, and
    /// asserts it says so. It passes both before and after the fix, because it is a claim about
    /// the check rather than about the shipped data.
    func testAPlantedDuplicateFailsTheUniquenessGuard() {
        let file = ManifestFile(name: "model.bin", sha256: String(repeating: "a", count: 64), byteCount: 1)
        let first = ModelManifest(engineID: "planted-engine", version: "1", files: [file])
        let second = ModelManifest(engineID: "planted-engine", version: "1", files: [file])
        let unrelated = ModelManifest(engineID: "planted-engine", version: "2", files: [file])

        XCTAssertEqual(
            collidingStorageKeys(in: [first, unrelated, second]), ["planted-engine@1"],
            "the uniqueness check must report a duplicated (engineID, version) pair")
        XCTAssertEqual(
            collidingStorageKeys(in: [first, unrelated]), [],
            "the same engineID at a different version is not a collision")
    }
}
