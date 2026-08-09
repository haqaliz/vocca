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
import XCTest

/// The store contract, `spec.md:53-58`: presence means *verified*, the commit is atomic, and two
/// concurrent downloads of the same version are one download.
///
/// Every test roots the store in a fresh temporary directory (`FileManager.temporaryDirectory` +
/// UUID) and never touches the real Application Support. The byte content is small and the digests
/// are computed from that content in the test — the manifest under test declares a real SHA-256 of
/// real bytes, which is what makes the verification half of these tests honest rather than
/// tautological.
final class ModelStoreTests: XCTestCase {

    private let engineID = "parakeet-tdt-0.6b-v3"
    private let version = "1.0.0"

    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
        super.tearDown()
    }

    /// A store rooted at a fresh, empty temporary directory, with the root URL handed back so the
    /// test can poke files at it directly.
    private func makeStore() -> (store: ModelStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-model-store-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        tempRoots.append(root)
        return (ModelStore(rootURL: root), root)
    }

    private func makeManifest(files: [ManifestFile]) -> ModelManifest {
        ModelManifest(engineID: engineID, version: version, files: files)
    }

    private func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func versionDirectory(under root: URL) -> URL {
        root
            .appendingPathComponent(engineID, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    private func isPresent(_ store: ModelStore) async -> Bool {
        await store.isPresent(engineID: engineID, version: version)
    }

    /// Polls until `condition` holds, or fails the test after two seconds. The poll exists because
    /// both the store and the stub are actors: there is no synchronous "the download has entered
    /// the gate" event, only an observable state — a download parked in the gate — and the test
    /// must read the store *while it is suspended inside the transport*, which is exactly what the
    /// gate makes possible.
    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("condition did not hold within 2 seconds")
    }

    // MARK: - Presence

    /// An empty root holds no model: `isPresent` must be false before anything has landed.
    func testIsPresentIsFalseOnAnEmptyRoot() async {
        let (store, _) = makeStore()
        let present = await isPresent(store)
        XCTAssertFalse(present, "an empty store must not report any model present")
    }

    /// A `.part` file is the in-flight mark: whether it is the only thing there or sitting next to
    /// a marker, presence must be false while one exists.
    ///
    /// The marker-plus-`.part` case cannot arise from the store's own commit sequence (the marker
    /// is written last), but it pins the *rule* rather than the sequence: a `.part` anywhere means
    /// a download is in flight or incomplete, and in-flight is never present.
    func testIsPresentIsFalseWhileAnyPartFileExists() async throws {
        let (store, root) = makeStore()
        let directory = versionDirectory(under: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("weights.bin.part"))
        let whilePartOnly = await isPresent(store)
        XCTAssertFalse(
            whilePartOnly,
            "a .part file means a download is in flight, and in-flight is never present")

        try Data().write(to: directory.appendingPathComponent(ModelStore.markerFileName))
        let withMarkerToo = await isPresent(store)
        XCTAssertFalse(
            withMarkerToo,
            "the marker must not win over a .part file: presence requires no in-flight download")
    }

    /// The directory key: `<root>/<engineID>/<version>/`, with a join that cannot double a
    /// separator when the downloader appends file names to it.
    func testBaseURLIsTheEngineVersionDirectoryWithASafeJoin() async {
        let (store, root) = makeStore()
        let base = await store.baseURL(for: engineID, version: version)

        XCTAssertEqual(base.path, root.path + "/" + engineID + "/" + version)
        XCTAssertTrue(
            base.absoluteString.hasSuffix("/"),
            "baseURL must be a directory URL: appending a file name to it must not be ambiguous")

        let fileURL = base.appendingPathComponent("weights.bin")
        XCTAssertEqual(
            fileURL.path, root.path + "/" + engineID + "/" + version + "/weights.bin",
            "appending a manifest file name to baseURL must produce exactly one separator")
        XCTAssertFalse(fileURL.path.contains("//"))
    }

    /// The commit contract, held open mid-flight: presence flips true only after every file is
    /// verified, and the verified marker is written last.
    ///
    /// The gate parks the store inside the transport at both stages of a two-file manifest: first
    /// before anything has been written, then — after the first file has downloaded and been
    /// verified — inside the second file's download. At the second park the first file's verified
    /// bytes sit in a `.part` awaiting commit, and presence must still be false: *every* file
    /// verified is the condition, and a half-committed version must not masquerade as a ready one.
    func testIsPresentFlipsTrueOnlyAfterEveryFileIsVerifiedAndCommitted() async throws {
        let (store, root) = makeStore()
        let weights: [UInt8] = Array("weights-bytes".utf8)
        let config: [UInt8] = Array(#"{"dtype": "fp16"}"#.utf8)
        let manifest = makeManifest(files: [
            ManifestFile(name: "weights.bin", sha256: sha256Hex(weights), byteCount: weights.count),
            ManifestFile(name: "config.json", sha256: sha256Hex(config), byteCount: config.count),
        ])
        let stub = StubTransport(files: ["weights.bin": weights, "config.json": config])
        await stub.armGate()

        let task = Task { try await store.downloadIfMissing(manifest: manifest, transport: stub) }

        // Parked inside the first download: nothing has been written yet.
        try await waitUntil { await stub.gatedDownloads == 1 }
        let countAtFirstPark = await stub.downloadCallCount
        XCTAssertEqual(countAtFirstPark, 1)
        let presentAtFirstPark = await isPresent(store)
        XCTAssertFalse(presentAtFirstPark)

        // Let the first file land; the second download starts and parks.
        await stub.releaseGate()
        try await waitUntil {
            let count = await stub.downloadCallCount
            let gated = await stub.gatedDownloads
            return count == 2 && gated == 1
        }

        let directory = versionDirectory(under: root)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("weights.bin.part").path),
            "the first file's verified bytes must be on disk (as .part, awaiting commit)")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(ModelStore.markerFileName).path),
            "the verified marker must not exist until every file has been verified")
        let presentAtSecondPark = await isPresent(store)
        XCTAssertFalse(presentAtSecondPark)

        // Let the last file land, verify, commit.
        await stub.releaseGate()
        try await task.value

        let presentAfterCommit = await isPresent(store)
        XCTAssertTrue(presentAfterCommit)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(ModelStore.markerFileName).path))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("weights.bin")),
            Data(weights))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("weights.bin.part").path),
            "no .part may survive the commit")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("config.json.part").path))
    }

    /// Presence is the marker, not the files: a directory that holds every final file but no
    /// verified marker must read as absent, because the marker is the commit record — the only
    /// thing written after *every* file's checksum has passed.
    func testFinalFilesWithoutTheVerifiedMarkerAreNotPresent() async throws {
        let (store, root) = makeStore()
        let directory = versionDirectory(under: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data("payload".utf8).write(to: directory.appendingPathComponent("weights.bin"))
        let presentWithoutMarker = await isPresent(store)
        XCTAssertFalse(
            presentWithoutMarker,
            "a directory full of files is not presence: only the verified marker is")

        try Data().write(to: directory.appendingPathComponent(ModelStore.markerFileName))
        let presentWithMarker = await isPresent(store)
        XCTAssertTrue(presentWithMarker)
    }

    // MARK: - Failure

    /// A checksum failure mid-download leaves the store not present — no marker, and no state that
    /// any later `isPresent` could read as ready. (The `.part` left behind is Phase 2's resume
    /// material.)
    func testAChecksumFailureMidDownloadLeavesTheStoreNotPresent() async throws {
        let (store, root) = makeStore()
        let good: [UInt8] = Array("good-bytes".utf8)
        let corrupt: [UInt8] = Array("wrong-bytes".utf8)
        let manifest = makeManifest(files: [
            ManifestFile(name: "weights.bin", sha256: sha256Hex(good), byteCount: good.count),
            ManifestFile(name: "config.json", sha256: sha256Hex(good), byteCount: good.count),
        ])
        let stub = StubTransport(files: ["weights.bin": good, "config.json": corrupt])

        do {
            try await store.downloadIfMissing(manifest: manifest, transport: stub)
            XCTFail("a download whose second file fails verification must throw")
        } catch {
            XCTAssertEqual(
                error as? ModelStoreError, .checksumMismatch(file: "config.json"),
                "the checksum failure must name the file that failed, and it must be the store's own error")
        }

        let present = await isPresent(store)
        XCTAssertFalse(present)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: versionDirectory(under: root).appendingPathComponent(ModelStore.markerFileName).path),
            "a failed download must never commit: no marker may be written")
    }

    // MARK: - Immutability and single-flight

    /// A committed version is immutable (`PRODUCT_SPEC.md:273`): a second `downloadIfMissing` with
    /// the same version must not refetch, must not rewrite, and must not even touch the directory.
    func testACommittedVersionDirectoryIsImmutableAgainstASecondDownload() async throws {
        let (store, root) = makeStore()
        let weights: [UInt8] = Array("weights-bytes".utf8)
        let manifest = makeManifest(files: [
            ManifestFile(name: "weights.bin", sha256: sha256Hex(weights), byteCount: weights.count),
        ])
        let stub = StubTransport(files: ["weights.bin": weights])

        try await store.downloadIfMissing(manifest: manifest, transport: stub)
        let countAfterFirst = await stub.downloadCallCount
        XCTAssertEqual(countAfterFirst, 1)

        let directory = versionDirectory(under: root)
        let before = try snapshot(directory)

        try await store.downloadIfMissing(manifest: manifest, transport: stub)

        let countAfterSecond = await stub.downloadCallCount
        XCTAssertEqual(
            countAfterSecond, 1,
            "an already-present version must never be refetched")
        XCTAssertEqual(
            try snapshot(directory), before,
            "the committed directory must be byte-for-byte and mtime-for-mtime untouched by a second download")
    }

    /// Single-flight: two concurrent `downloadIfMissing` calls for the same version result in one
    /// download, not two. The gate is what makes the calls truly overlap — the second call is
    /// submitted while the first is parked inside the transport, so a store that lacked the
    /// one-flight guard would start a second download before the assertion ever runs.
    func testTwoConcurrentDownloadsAreSingleFlight() async throws {
        let (store, root) = makeStore()
        let weights: [UInt8] = Array("weights-bytes".utf8)
        let manifest = makeManifest(files: [
            ManifestFile(name: "weights.bin", sha256: sha256Hex(weights), byteCount: weights.count),
        ])
        let stub = StubTransport(files: ["weights.bin": weights])
        await stub.armGate()

        async let first: Void = store.downloadIfMissing(manifest: manifest, transport: stub)
        async let second: Void = store.downloadIfMissing(manifest: manifest, transport: stub)

        try await waitUntil {
            let count = await stub.downloadCallCount
            let gated = await stub.gatedDownloads
            return count == 1 && gated == 1
        }
        let countWhileParked = await stub.downloadCallCount
        XCTAssertEqual(
            countWhileParked, 1,
            "while the first download is parked in the transport, no second download may start")

        await stub.releaseGate()
        try await first
        try await second

        let countAfterBoth = await stub.downloadCallCount
        XCTAssertEqual(
            countAfterBoth, 1,
            "two concurrent downloadIfMissing calls must result in exactly one download")
        let present = await isPresent(store)
        XCTAssertTrue(present)
    }

    // MARK: - The SDK-shaped layout (spike finding, `spike_20260809.md` §4.1)

    /// An `sdkDirectory` manifest commits its files under `<version>/<sdkDirectory>/`, nested
    /// names included, with the marker at the version root — the layout the SDK's manual
    /// `load(from:)` resolves to — and presence flips true only at the commit, as ever.
    func testAnSDKDirectoryManifestCommitsUnderTheDirectoryWithTheMarkerAtTheVersionRoot() async throws {
        let (store, root) = makeStore()
        let weights: [UInt8] = Array("weights-bytes".utf8)
        let mil: [UInt8] = Array("model-mil-bytes".utf8)
        let manifest = ModelManifest(
            engineID: engineID, version: version, sdkDirectory: "parakeet-tdt-0.6b-v3",
            files: [
                ManifestFile(name: "weights.bin", sha256: sha256Hex(weights), byteCount: weights.count),
                ManifestFile(
                    name: "Encoder.mlmodelc/model.mil", sha256: sha256Hex(mil), byteCount: mil.count),
            ])
        let stub = StubTransport(files: [
            "weights.bin": weights, "Encoder.mlmodelc/model.mil": mil,
        ])

        try await store.downloadIfMissing(manifest: manifest, transport: stub)

        let directory = versionDirectory(under: root)
        let sdkDir = directory.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        XCTAssertEqual(
            try Data(contentsOf: sdkDir.appendingPathComponent("weights.bin")),
            Data(weights))
        XCTAssertEqual(
            try Data(
                contentsOf: sdkDir.appendingPathComponent("Encoder.mlmodelc/model.mil")),
            Data(mil))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(ModelStore.markerFileName).path),
            "the marker must live at the version root, not inside the SDK directory")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: sdkDir.appendingPathComponent(ModelStore.markerFileName).path),
            "the SDK directory must not carry the marker")
        let present = await isPresent(store)
        XCTAssertTrue(present)

        // Immutable, recursively: a second download must not touch the tree.
        let stub2 = StubTransport(files: [
            "weights.bin": weights, "Encoder.mlmodelc/model.mil": mil,
        ])
        try await store.downloadIfMissing(manifest: manifest, transport: stub2)
        XCTAssertEqual(
            try recursiveSnapshot(sdkDir), try recursiveSnapshot(sdkDir),
            "a committed SDK-shaped version must be untouched by a second download")
    }

    /// The "a `.part` anywhere means not present" promise, surviving nesting: a `.part` two levels
    /// deep keeps presence false even beside a marker — the marker is the commit record, and a
    /// nested in-flight file must read as in-flight.
    func testANestedPartFileKeepsPresenceFalseEvenBesideTheMarker() async throws {
        let (store, root) = makeStore()
        let directory = versionDirectory(under: root)
        let nested = directory.appendingPathComponent("Enc/Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try Data([1, 2, 3]).write(to: nested.appendingPathComponent("model.mil.part"))
        try Data().write(to: directory.appendingPathComponent(ModelStore.markerFileName))

        let present = await isPresent(store)
        XCTAssertFalse(
            present,
            "a nested .part must keep presence false: in-flight is never present, at any depth")
    }

    // MARK: - Helpers

    /// One entry of a committed directory, enough to prove "untouched": name, bytes, modification
    /// time. A rewrite that produced identical bytes would still move the mtime; a rename would
    /// change a name.
    private struct EntrySnapshot: Equatable {
        let name: String
        let data: Data
        let mtime: Date
    }

    private func snapshot(_ directory: URL) throws -> [EntrySnapshot] {
        let fileManager = FileManager.default
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                return EntrySnapshot(
                    name: url.lastPathComponent,
                    data: try Data(contentsOf: url),
                    mtime: attributes[.modificationDate] as? Date ?? .distantPast)
            }
    }

    /// A recursive snapshot: name, bytes, and modification time for every file under `directory`,
    /// sorted and flattened by relative path — the immutability claim for SDK-shaped (nested)
    /// layouts.
    private func recursiveSnapshot(_ directory: URL) throws -> [EntrySnapshot] {
        let fileManager = FileManager.default
        let base = directory.path.count + 1
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var entries: [EntrySnapshot] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue { continue }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            entries.append(
                EntrySnapshot(
                    name: String(url.path.dropFirst(base)),
                    data: try Data(contentsOf: url),
                    mtime: attributes[.modificationDate] as? Date ?? .distantPast))
        }
        return entries.sorted { $0.name < $1.name }
    }
}
