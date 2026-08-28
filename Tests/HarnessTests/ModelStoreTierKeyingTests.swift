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

import CryptoKit
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

    /// A store rooted at a fresh, empty temporary directory — never the real Application Support —
    /// with the root handed back so a test can look at the tree the store wrote.
    private func makeStore() -> (store: ModelStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-tier-keying-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        tempRoots.append(root)
        return (ModelStore(rootURL: root), root)
    }

    /// The directory a tier's version occupies, spelled out from the tier's own storage key: the
    /// tree the store is expected to have written, computed independently of the store.
    private func versionDirectory(for tier: EngineTier, under root: URL) -> URL {
        root
            .appendingPathComponent(tier.storageID, isDirectory: true)
            .appendingPathComponent(Self.shippedVersion, isDirectory: true)
    }

    /// Polls until `condition` holds, or fails after two seconds. The poll exists because both the
    /// store and the stub are actors: there is no synchronous "the download has entered the gate"
    /// event, only an observable state — a download parked in the gate — and the removal must be
    /// issued *while the store is suspended inside the transport*, which is what the gate makes
    /// possible.
    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("condition did not hold within 2 seconds")
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
        let (store, _) = makeStore()
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

    /// The storage key has **one** source: ``EngineTier/storageID``, and every shipped manifest
    /// must agree with it.
    ///
    /// Two things now name a tier's directory — the enum, which the per-tier queries ask, and the
    /// manifest's `engineID`, which the download and load paths carry — and the whole defect above
    /// is what happens when two names for one directory drift apart. So they are pinned to each
    /// other here, over the closed tier set: a manifest edited without the enum, or a tier added
    /// without a manifest, fails at build time rather than resolving to a directory nobody meant.
    func testEveryShippedManifestAgreesWithItsTierStorageID() throws {
        for tier in EngineTier.allCases {
            let manifest = try ShippedModelManifest.load(for: tier)
            XCTAssertEqual(
                manifest.engineID, tier.storageID,
                "\(tier)'s manifest keys storage differently from the tier that owns it")
        }
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

    // MARK: - Per-tier presence, disk usage and removal (R2-R4)

    /// The SHA-256 of some bytes, hex-encoded — the digest a synthetic manifest declares, computed
    /// from the bytes the stub transport actually serves. Nothing here is tautological: the store
    /// verifies these digests exactly as it verifies a shipped manifest's.
    private func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// A one-file manifest keyed by `tier.storageID` at the shipped version, over bytes small
    /// enough to serve in memory.
    ///
    /// The key is the tier's own ``EngineTier/storageID`` rather than a literal, which is the
    /// point: `testEveryShippedManifestAgreesWithItsTierStorageID` already pins every shipped
    /// manifest to that same value, so a synthetic manifest built this way exercises the real
    /// directory key without needing the real 1.6 GB artifact.
    private func makeTierManifest(
        for tier: EngineTier, fileName: String, bytes: [UInt8]
    ) -> ModelManifest {
        ModelManifest(
            engineID: tier.storageID,
            version: Self.shippedVersion,
            files: [
                ManifestFile(name: fileName, sha256: sha256Hex(bytes), byteCount: bytes.count)
            ])
    }

    /// The version every shipped manifest declares today. The per-tier queries are version-scoped,
    /// so the tests name the version the product actually asks for.
    private static let shippedVersion = "1"

    /// AC2: downloading one Whisper tier must leave the **other** tier absent.
    ///
    /// This is the user-visible half of the collision. Before storage was keyed by tier, one
    /// download wrote one directory and one verified marker that answered for both tiers — so the
    /// Speech tab would have shown `[installed]` beside a tier whose 1.6 GB had never been
    /// fetched, and selecting it would have loaded the other tier's bytes. The per-tier presence
    /// query is what that row is drawn from, so it is asked here directly.
    func testDownloadingOneWhisperTierLeavesTheOtherTierAbsent() async throws {
        let (store, _) = makeStore()
        let bytes: [UInt8] = Array("q5-weights".utf8)
        let manifest = makeTierManifest(
            for: .whisperTurboQ5, fileName: "ggml-large-v3-turbo-q5_0.bin", bytes: bytes)
        let transport = StubTransport(files: ["ggml-large-v3-turbo-q5_0.bin": bytes])

        try await store.downloadIfMissing(manifest: manifest, transport: transport)

        let q5Present = await store.isPresent(tier: .whisperTurboQ5, version: Self.shippedVersion)
        XCTAssertTrue(q5Present, "the tier that was downloaded must read as present")

        let turboPresent = await store.isPresent(
            tier: .whisperTurbo, version: Self.shippedVersion)
        XCTAssertFalse(
            turboPresent,
            """
            downloading the q5_0 tier made the full-precision tier read as present: the two tiers \
            share a directory and a verified marker, so the Speech tab would claim a model is \
            installed that was never fetched
            """)
    }

    /// AC3: `downloadIfMissing` for the second tier must actually reach the transport, even when
    /// the first tier is present and verified.
    ///
    /// The short-circuit at the top of `downloadIfMissing` is a *correctness* feature — a verified
    /// version is immutable, so re-downloading it would be waste — and the collision turned it
    /// into the defect's delivery mechanism: keyed by engine, tier B's download returned
    /// immediately on tier A's marker and the user was handed A's bytes. So the assertion here is
    /// on the transport's own call ledger rather than on the absence of a throw: a silent no-op
    /// and a completed download are both "no error", and only the ledger tells them apart.
    ///
    /// One transport serves all three calls, which is what makes this a gate rather than a claim:
    /// the same counter must *stay* at 1 for the repeat of a present tier and *rise* to 2 for the
    /// sibling tier. A store that short-circuits everything, and one that short-circuits nothing,
    /// each fail one of those two halves.
    func testDownloadingTheSecondTierIsNotShortCircuitedByTheFirstTiersMarker() async throws {
        let (store, _) = makeStore()
        let q5Bytes: [UInt8] = Array("q5-weights".utf8)
        let turboBytes: [UInt8] = Array("full-precision-weights".utf8)
        let q5Manifest = makeTierManifest(
            for: .whisperTurboQ5, fileName: "ggml-large-v3-turbo-q5_0.bin", bytes: q5Bytes)
        let turboManifest = makeTierManifest(
            for: .whisperTurbo, fileName: "ggml-large-v3-turbo.bin", bytes: turboBytes)
        let transport = StubTransport(files: [
            "ggml-large-v3-turbo-q5_0.bin": q5Bytes,
            "ggml-large-v3-turbo.bin": turboBytes,
        ])

        try await store.downloadIfMissing(manifest: q5Manifest, transport: transport)
        let afterFirst = await transport.downloadCallCount
        XCTAssertEqual(afterFirst, 1, "the first tier's download must reach the transport once")

        try await store.downloadIfMissing(manifest: q5Manifest, transport: transport)
        let afterRepeat = await transport.downloadCallCount
        XCTAssertEqual(
            afterRepeat, 1,
            "a verified version is immutable: asking for the same tier again must not re-download")

        try await store.downloadIfMissing(manifest: turboManifest, transport: transport)
        let afterSibling = await transport.downloadCallCount
        XCTAssertEqual(
            afterSibling, 2,
            """
            the sibling tier's download never reached the transport: it short-circuited on the \
            other tier's verified marker, and the engine would be handed bytes nobody chose
            """)

        let turboPresent = await store.isPresent(tier: .whisperTurbo, version: Self.shippedVersion)
        let q5Present = await store.isPresent(tier: .whisperTurboQ5, version: Self.shippedVersion)
        XCTAssertTrue(
            turboPresent && q5Present, "both tiers must read as present once both are downloaded")
    }

    /// AC5: removing a tier deletes its directory **and** its verified marker, so it cannot read
    /// back as present — and removing a tier that is not there is a no-op, not a throw.
    ///
    /// The marker is the whole of presence, so a removal that deleted the bytes and left the
    /// marker would leave a model that reads `[installed]`, loads nothing, and can never be
    /// re-downloaded (`downloadIfMissing` would short-circuit on the marker it left). That is the
    /// worst reachable outcome of this operation, which is why the marker is asserted gone
    /// directly rather than inferred from the presence query.
    ///
    /// Removal is version-scoped, exactly as presence is: the caller names the version whose bytes
    /// it is freeing, and a sibling tier — the reason this whole aspect exists — is untouched.
    func testRemovingATierDeletesItsDirectoryAndMarkerAndLeavesTheSiblingAlone() async throws {
        let (store, root) = makeStore()
        let q5Bytes: [UInt8] = Array("q5-weights".utf8)
        let turboBytes: [UInt8] = Array("full-precision-weights".utf8)
        let transport = StubTransport(files: [
            "ggml-large-v3-turbo-q5_0.bin": q5Bytes,
            "ggml-large-v3-turbo.bin": turboBytes,
        ])
        try await store.downloadIfMissing(
            manifest: makeTierManifest(
                for: .whisperTurboQ5, fileName: "ggml-large-v3-turbo-q5_0.bin", bytes: q5Bytes),
            transport: transport)
        try await store.downloadIfMissing(
            manifest: makeTierManifest(
                for: .whisperTurbo, fileName: "ggml-large-v3-turbo.bin", bytes: turboBytes),
            transport: transport)

        let directory = versionDirectory(for: .whisperTurboQ5, under: root)
        let marker = directory.appendingPathComponent(ModelStore.markerFileName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "the fixture is wrong if the download did not commit a verified marker")

        try await store.remove(tier: .whisperTurboQ5, version: Self.shippedVersion)

        let removedPresent = await store.isPresent(
            tier: .whisperTurboQ5, version: Self.shippedVersion)
        XCTAssertFalse(removedPresent, "a removed tier must not read back as present")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            """
            removal left the verified marker behind: the tier would read as installed, load \
            nothing, and never re-download, because downloadIfMissing short-circuits on a marker
            """)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "removal must delete the tier's version directory, not only its marker")

        let siblingPresent = await store.isPresent(
            tier: .whisperTurbo, version: Self.shippedVersion)
        XCTAssertTrue(
            siblingPresent, "removing one tier must not remove the other tier's model")

        // Idempotent: the settings row's [Remove] pressed twice, or pressed on a tier a previous
        // run already removed, is a no-op — never an error the user has to read.
        try await store.remove(tier: .whisperTurboQ5, version: Self.shippedVersion)
        try await store.remove(tier: .parakeetV3, version: Self.shippedVersion)
    }

    /// AC6: disk usage answers `0` for an absent tier and the summed file size for a present one —
    /// including the SDK-shaped **nested** layout.
    ///
    /// The number this returns is the one `PRODUCT_SPEC.md:260`'s "disk used" shows beside a
    /// Speech-tab row, so it must be the number [Remove] would free — every byte under that
    /// tier's version directory, at any depth. The nested half is not a nicety: the shipped
    /// Parakeet manifest declares an `sdkDirectory` and file names that are themselves paths
    /// (`Encoder.mlmodelc/model.mil`), so a non-recursive walk would report `0` for the default
    /// engine, next to a row that says it is installed. ``ModelStore/isPresent(engineID:version:)``
    /// scans for `.part` files recursively for exactly this reason; the size walk inherits that
    /// shape rather than inventing a second one.
    func testDiskUsageIsZeroWhenAbsentAndTheSummedSizeWhenPresentAtAnyDepth() async throws {
        let (store, _) = makeStore()

        let beforeAnything = await store.bytesOnDisk(
            tier: .whisperTurboQ5, version: Self.shippedVersion)
        XCTAssertEqual(
            beforeAnything, 0, "a tier with nothing on disk must report zero bytes, not fail")

        // The flat layout: one file at the version root, beside the (zero-byte) verified marker.
        let flatBytes: [UInt8] = Array(repeating: 0x51, count: 96)
        try await store.downloadIfMissing(
            manifest: makeTierManifest(
                for: .whisperTurboQ5, fileName: "ggml-large-v3-turbo-q5_0.bin", bytes: flatBytes),
            transport: StubTransport(files: ["ggml-large-v3-turbo-q5_0.bin": flatBytes]))

        let flatUsage = await store.bytesOnDisk(
            tier: .whisperTurboQ5, version: Self.shippedVersion)
        XCTAssertEqual(
            flatUsage, flatBytes.count,
            "a present tier must report the bytes of the files it committed")

        // The SDK-shaped layout the default engine actually ships: files under a named
        // subdirectory, with names that are themselves paths — two levels below the version root.
        let configBytes: [UInt8] = Array(repeating: 0x7B, count: 40)
        let weightBytes: [UInt8] = Array(repeating: 0x2A, count: 200)
        let nested = ModelManifest(
            engineID: EngineTier.parakeetV3.storageID,
            version: Self.shippedVersion,
            sdkDirectory: "parakeet-tdt-0.6b-v3",
            files: [
                ManifestFile(
                    name: "config.json", sha256: sha256Hex(configBytes),
                    byteCount: configBytes.count),
                ManifestFile(
                    name: "Encoder.mlmodelc/model.mil", sha256: sha256Hex(weightBytes),
                    byteCount: weightBytes.count),
            ])
        try await store.downloadIfMissing(
            manifest: nested,
            transport: StubTransport(files: [
                "config.json": configBytes,
                "Encoder.mlmodelc/model.mil": weightBytes,
            ]))

        let nestedUsage = await store.bytesOnDisk(
            tier: .parakeetV3, version: Self.shippedVersion)
        XCTAssertEqual(
            nestedUsage, configBytes.count + weightBytes.count,
            """
            the size walk did not reach the SDK-shaped layout's nested files: the default engine \
            would report 0 bytes beside a row that says it is installed
            """)

        // And the number is what [Remove] frees: after removal it is zero again.
        try await store.remove(tier: .parakeetV3, version: Self.shippedVersion)
        let afterRemoval = await store.bytesOnDisk(
            tier: .parakeetV3, version: Self.shippedVersion)
        XCTAssertEqual(afterRemoval, 0, "the bytes a removal frees must be the bytes it reported")
    }

    /// AC7: the Parakeet path is untouched — its directory key, its presence and its download
    /// behave exactly as they did, and this row fails if the key shape moves.
    ///
    /// Parakeet is the one tier that **is** on disk today: `~/Library/Application
    /// Support/Vocca/models/parakeet-tdt-0.6b-v3/1/` is what a provisioned machine holds, and it
    /// is the shipped default engine. Re-keying storage was safe only because neither Whisper tier
    /// had ever been downloaded anywhere; Parakeet's key had to stay byte-for-byte where it was,
    /// or every existing install would silently re-download 470 MB into a new directory.
    ///
    /// So the literals here are deliberate. The path is spelled out rather than derived from
    /// ``EngineTier/storageID``, because a test that asks the enum what the enum says would pass
    /// through any rename — which is precisely the change this row exists to catch.
    func testTheParakeetPathIsUnchangedByTierKeying() async throws {
        let (store, root) = makeStore()

        XCTAssertEqual(
            EngineTier.parakeetV3.storageID, "parakeet-tdt-0.6b-v3",
            """
            the default engine's storage key moved: every provisioned machine would re-download \
            470 MB into a new directory and orphan the one it already has
            """)
        let shipped = try ShippedModelManifest.load(for: .parakeetV3)
        XCTAssertEqual(shipped.engineID, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(shipped.version, "1")

        let expected = root
            .appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
            .appendingPathComponent("1", isDirectory: true)
        let byEngineID = await store.baseURL(for: shipped.engineID, version: shipped.version)
        XCTAssertEqual(byEngineID, expected, "the Parakeet version directory must not move")

        // And the two questions — asked by manifest key and asked by tier — must answer the same,
        // before and after a download, because they name one directory.
        let absentByEngineID = await store.isPresent(
            engineID: shipped.engineID, version: shipped.version)
        let absentByTier = await store.isPresent(tier: .parakeetV3, version: shipped.version)
        XCTAssertFalse(absentByEngineID)
        XCTAssertFalse(absentByTier)

        let bytes: [UInt8] = Array(repeating: 0x0F, count: 64)
        let manifest = ModelManifest(
            engineID: shipped.engineID,
            version: shipped.version,
            sdkDirectory: "parakeet-tdt-0.6b-v3",
            files: [
                ManifestFile(name: "config.json", sha256: sha256Hex(bytes), byteCount: bytes.count)
            ])
        try await store.downloadIfMissing(
            manifest: manifest, transport: StubTransport(files: ["config.json": bytes]))

        let presentByEngineID = await store.isPresent(
            engineID: shipped.engineID, version: shipped.version)
        let presentByTier = await store.isPresent(tier: .parakeetV3, version: shipped.version)
        XCTAssertTrue(presentByEngineID, "the download must commit where the manifest key says")
        XCTAssertTrue(
            presentByTier,
            "the tier query and the manifest key must name one directory, not two")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: expected.appendingPathComponent(ModelStore.markerFileName).path),
            "the verified marker must still be committed at the same path it always was")
    }

    /// Removal **while that tier's download is in flight**: this row documents what happens today.
    /// It does not decide a policy.
    ///
    /// `ModelStore.remove` deletes a directory; `downloadIfMissing` holds a one-flight task that
    /// knows nothing about it. What the two do when they overlap is a real question — cancel the
    /// download, refuse the removal, or let the removal win — and it belongs to the aspect that
    /// owns the [Remove] button (`plan_20260828.md` §6, aspect 4's M12). Inventing an answer here,
    /// in the store, would make that decision by accident and pin it with a test that reads like
    /// intent.
    ///
    /// So the assertion is the one property that must hold under **any** policy: when the dust
    /// settles the tier must not read as present, because a half-removed, half-downloaded
    /// directory that answers `[installed]` is the one outcome no later policy could repair.
    func testRemovalDuringAnInFlightDownloadIsDocumentedNotDecided() async throws {
        let (store, root) = makeStore()
        let bytes: [UInt8] = Array(repeating: 0x33, count: 32)
        let manifest = makeTierManifest(
            for: .whisperTurboQ5, fileName: "ggml-large-v3-turbo-q5_0.bin", bytes: bytes)
        let transport = StubTransport(files: ["ggml-large-v3-turbo-q5_0.bin": bytes])
        await transport.armGate()

        let download = Task {
            try await store.downloadIfMissing(manifest: manifest, transport: transport)
        }
        await waitUntil { await transport.gatedDownloads == 1 }

        try await store.remove(tier: .whisperTurboQ5, version: Self.shippedVersion)
        await transport.releaseGate()

        // The download's own outcome is recorded, not required. Measured today: it fails with
        // `ModelDownloadError.transportFailed`, wrapping `NSCocoaErrorDomain` 4 — "the file
        // ggml-large-v3-turbo-q5_0.bin.part doesn't exist" — because the directory its `.part`
        // file lives in was deleted out from under the transfer. A later policy may cancel the
        // download cleanly instead; that is a change to this comment, not a regression.
        var downloadFailed = false
        do {
            try await download.value
        } catch {
            downloadFailed = true
        }
        XCTAssertTrue(
            downloadFailed,
            """
            current behaviour: a removal mid-download makes the download fail rather than being \
            refused or cancelling cleanly (documented, not decided — aspect 4's M12)
            """)

        let present = await store.isPresent(tier: .whisperTurboQ5, version: Self.shippedVersion)
        XCTAssertFalse(
            present,
            """
            whatever the policy becomes, a tier removed mid-download must never read as present: \
            a directory that is half-removed and half-downloaded would claim to hold a model
            """)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: versionDirectory(for: .whisperTurboQ5, under: root)
                    .appendingPathComponent(ModelStore.markerFileName).path),
            "no verified marker may survive a removal, in flight or not")

        // The store's one-flight guard is undisturbed: a later download of the same tier still
        // starts, rather than awaiting a task that is gone.
        let second = StubTransport(files: ["ggml-large-v3-turbo-q5_0.bin": bytes])
        try await store.downloadIfMissing(manifest: manifest, transport: second)
        let afterRetry = await store.isPresent(tier: .whisperTurboQ5, version: Self.shippedVersion)
        XCTAssertTrue(
            afterRetry, "a failed download must not poison the next attempt for that tier")
    }
}
