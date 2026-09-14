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
import VoccaBootstrap
import VoccaCore
import VoccaSpeech
import XCTest

/// The provisioning sequence, end to end and headless (`kokoro-binding`/`provisioning` spec
/// acceptance 4): the store downloads the pinned tarball, the extractor unpacks it into the
/// SDK-shaped directory, and the composition root's builder injects that directory into the real
/// `KokoroEngine` — pinned through the engine's own recorded error, never a new accessor.
///
/// Nothing here touches the network or the 103 MB release asset: the transport double serves the
/// committed 675-byte `fixture.tar.gz`, and the sequence test's manifest pins the fixture's own
/// digest so the store's verification runs for real over the fixture's bytes. The shipped
/// manifest's row is the provenance test, where the fixture's inevitable verification failure is
/// the proof that the SHIPPED manifest is the one the prepare function loaded — an in-test
/// manifest with the fixture's digest would have matched and committed instead.
final class KokoroProvisioningTests: XCTestCase {

    /// Every temporary store root a test created, removed after each test.
    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A fresh, empty temporary store root — never Application Support, never the repository.
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-kokoro-provisioning-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        tempRoots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The committed fixture tarball, located from this source file — never a hardcoded path.
    private func fixtureTarball() throws -> URL {
        try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Tests/HarnessTests/Fixtures/fixture.tar.gz")
    }

    /// The fixture's bytes — what the transport double serves and what the in-test manifest pins.
    private func fixtureBytes() throws -> Data {
        try Data(contentsOf: fixtureTarball())
    }

    /// The in-test manifest: the fixture's own measurement, under the shipped manifest's shape
    /// (`engineID` "kokoro-82m", version "1", `sdkDirectory` "kokoro", one `kokoro-models.tar.gz`
    /// entry) — so the store's download-verify-commit cycle runs for real over fixture bytes.
    private func fixtureManifest() throws -> ModelManifest {
        let data = try fixtureBytes()
        return ModelManifest(
            engineID: "kokoro-82m",
            version: "1",
            sdkDirectory: "kokoro",
            files: [
                ManifestFile(
                    name: "kokoro-models.tar.gz",
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    byteCount: data.count)
            ])
    }

    /// The store-shaped extraction directory the sequence commits into:
    /// `<root>/<engineID>/<version>/<sdkDirectory>` — the same expression the composition root's
    /// builder computes (`ParakeetEngine.loadDirectory` precedent).
    private func extractedDirectory(store: ModelStore, manifest: ModelManifest) async -> URL {
        await store.baseURL(for: manifest.engineID, version: manifest.version)
            .appendingPathComponent(manifest.sdkDirectory ?? "kokoro", isDirectory: true)
    }

    /// The provisioning sequence as the launch path runs it: download-if-missing through the
    /// store, then extract-if-needed into the SDK directory.
    private func runProvisioningSequence(
        store: ModelStore, transport: any ModelTransport, manifest: ModelManifest
    ) async throws {
        try await store.downloadIfMissing(manifest: manifest, transport: transport)
        let directory = await extractedDirectory(store: store, manifest: manifest)
        try TarballExtractor.extractIfNeeded(
            tarball: directory.appendingPathComponent(manifest.files[0].name), into: directory)
    }

    /// Whether every member of the extractor's marker trio is present in `directory`.
    private func trioIsPresent(in directory: URL) -> Bool {
        TarballExtractor.markerComponents.allSatisfy { component in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(component).path)
        }
    }

    // MARK: - The sequence

    /// **Acceptance 4, first half.** The sequence downloads through the store, extracts into
    /// `<root>/kokoro-82m/1/kokoro`, and the composition root's builder returns a synthesizer
    /// whose identity is the Kokoro engine with the configured voice.
    ///
    /// The injected path is pinned through the engine's own recorded error, not a new accessor:
    /// the fixture's trio satisfies the port's `modelsAvailable` check, so the probe first removes
    /// the extracted trio — the plan's "engine unprovisioned" state — and then reads the path back
    /// off `KokoroEngineError.modelsUnavailable`, whose associated URL is exactly the directory
    /// the builder injected.
    func testTheProvisioningSequenceDownloadsExtractsAndInjectsTheExtractedPath() async throws {
        let root = try makeTempRoot()
        let store = ModelStore(rootURL: root)
        let manifest = try fixtureManifest()
        let transport = StubTransport(
            files: [manifest.files[0].name: [UInt8](try fixtureBytes())])

        try await runProvisioningSequence(store: store, transport: transport, manifest: manifest)

        let directory = await extractedDirectory(store: store, manifest: manifest)
        XCTAssertEqual(
            directory.path,
            root.appendingPathComponent("kokoro-82m", isDirectory: true)
                .appendingPathComponent("1", isDirectory: true)
                .appendingPathComponent("kokoro", isDirectory: true)
                .path,
            "the sequence extracts into <root>/<engineID>/<version>/<sdkDirectory>")
        XCTAssertTrue(
            trioIsPresent(in: directory),
            "the extraction must have landed the marker trio the port requires")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("kokoro-82m", isDirectory: true)
                    .appendingPathComponent("1", isDirectory: true)
                    .appendingPathComponent(ModelStore.markerFileName).path),
            "the store's verified marker commits the download")

        let synthesizer = try await AppBootstrap.kokoroSynthesizer(store: store)
        XCTAssertEqual(
            synthesizer.identity.engineID, "kokoro-82m",
            "the builder returns the Kokoro engine — the seam's own vocabulary")
        XCTAssertEqual(
            synthesizer.identity.voiceName, "af_heart",
            "the builder configures the one voice this unit ships")

        for component in TarballExtractor.markerComponents {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(component))
        }
        var received: [AudioChunk] = []
        do {
            for try await chunk in synthesizer.speak("Hello there.") {
                received.append(chunk)
            }
            XCTFail("a speak over the unprovisioned directory must throw, not finish silently")
        } catch let error as KokoroEngineError {
            guard case .modelsUnavailable(let named) = error else {
                return XCTFail("expected the mapped models-unavailable error, got \(error)")
            }
            XCTAssertEqual(
                named.path, directory.path,
                "the error's associated URL is the path probe: the engine was constructed over "
                    + "exactly the extracted <root>/kokoro-82m/1/kokoro")
        } catch {
            XCTFail("the stream threw an unmapped error: \(error)")
        }
        XCTAssertTrue(
            received.isEmpty,
            "no chunk may be yielded before the mapped error — a partial sentence is never delivered")
    }

    /// **Acceptance 4, second half.** Running the sequence twice downloads once — the store's
    /// verified marker short-circuits the second run — and extracts safely: the trio survives and
    /// the extracted bytes are untouched.
    func testRunningTheProvisioningSequenceTwiceDownloadsOnceAndExtractsSafely() async throws {
        let root = try makeTempRoot()
        let store = ModelStore(rootURL: root)
        let manifest = try fixtureManifest()
        let transport = StubTransport(
            files: [manifest.files[0].name: [UInt8](try fixtureBytes())])

        try await runProvisioningSequence(store: store, transport: transport, manifest: manifest)
        try await runProvisioningSequence(store: store, transport: transport, manifest: manifest)

        let calls = await transport.downloadCallCount
        XCTAssertEqual(
            calls, 1,
            "the second run must short-circuit on the store's verified marker, not re-download")

        let directory = await extractedDirectory(store: store, manifest: manifest)
        XCTAssertTrue(trioIsPresent(in: directory), "the marker trio survives the second run")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("voices/af_heart.bin")),
            Data("af-heart-embedding-bytes".utf8),
            "the skipped extraction leaves the extracted files byte-for-byte intact")
    }

    // MARK: - Provenance

    /// **Acceptance 4, provenance.** The composition root's prepare function loads the SHIPPED
    /// manifest — never an in-test one — and drives the store with the pinned release asset.
    ///
    /// The fixture's 675 bytes can never match the shipped manifest's digest (the real 103 MB
    /// asset's, `0d24bbf8…`), so the download must fail verification; that failure is the proof
    /// that the shipped manifest is the one loaded — an in-test manifest pinning the fixture's
    /// digest would have matched and committed. The transport double records every call and fails
    /// the test on any file name other than the shipped manifest's one entry.
    func testPrepareSpeechModelsLoadsTheShippedManifestAtThePinnedRepository() async throws {
        let root = try makeTempRoot()
        let store = ModelStore(rootURL: root)
        let pinnedReleaseBase = URL(
            string: "https://github.com/Jud/kokoro-coreml/releases/download/models-2026-03-23")!
        let transport = ProvenanceTransport(
            baseURL: pinnedReleaseBase, fixtureBytes: [UInt8](try fixtureBytes()))

        do {
            try await AppBootstrap.prepareSpeechModels(store: store, transport: transport)
            XCTFail(
                "the fixture's bytes can never match the shipped manifest's digest — the "
                    + "download must fail verification against it")
        } catch let error as ModelStoreError {
            XCTAssertEqual(
                error, .checksumMismatch(file: "kokoro-models.tar.gz"),
                "the store verified the fixture bytes against the SHIPPED manifest's digest — "
                    + "an in-test manifest with the fixture's digest would have committed")
        } catch {
            XCTFail("the download must fail verification, not \(error)")
        }

        let calls = await transport.calls
        XCTAssertEqual(
            calls.count, 3,
            "the downloader's bounded restart loop (default restartLimit 2) retries the "
                + "mismatch twice before giving up — all three attempts for the same file")
        XCTAssertTrue(
            calls.allSatisfy { $0.name == "kokoro-models.tar.gz" },
            "the fake transport fails the test on any other name — the shipped manifest's one "
                + "entry is the pinned release asset")
        let expectedPart = root
            .appendingPathComponent("kokoro-82m", isDirectory: true)
            .appendingPathComponent("1", isDirectory: true)
            .appendingPathComponent("kokoro", isDirectory: true)
            .appendingPathComponent("kokoro-models.tar.gz.part")
        XCTAssertTrue(
            calls.allSatisfy { $0.destination.path == expectedPart.path },
            "the store laid the download out under the shipped manifest's "
                + "engineID/version/sdkDirectory — got \(calls.map(\.destination.path))")
        XCTAssertEqual(
            transport.baseURL, AppBootstrap.kokoroModelRepository,
            "the bootstrap's repository constant is the pinned models-2026-03-23 release asset base")
    }
}

/// A recording ``ModelTransport`` for the provenance pin: it serves the fixture bytes for the
/// shipped manifest's one file name, records every `(name, destination)` the store asks for, and
/// throws on any other name — so a prepare function that drifted to a different manifest fails the
/// test rather than passing it quietly.
private actor ProvenanceTransport: ModelTransport {

    /// One recorded download call.
    struct Call: Sendable, Equatable {
        let name: String
        let destination: URL
    }

    /// The base URL the transport would resolve names against — the test pins the bootstrap's
    /// repository constant against it.
    nonisolated let baseURL: URL

    private let fixtureBytes: [UInt8]
    private(set) var calls: [Call] = []

    init(baseURL: URL, fixtureBytes: [UInt8]) {
        self.baseURL = baseURL
        self.fixtureBytes = fixtureBytes
    }

    func download(
        file name: String,
        fromRangeStart rangeStart: Int,
        to destination: URL,
        onBytesWritten: (@Sendable (Int) -> Void)?
    ) async throws {
        guard name == "kokoro-models.tar.gz" else {
            throw ProvenanceTransportError.unexpectedFile(name)
        }
        calls.append(Call(name: name, destination: destination))
        try Data(fixtureBytes).write(to: destination)
        onBytesWritten?(fixtureBytes.count)
    }
}

/// The provenance double's own failure: a download for a name the shipped manifest does not
/// declare is a drifted prepare function, not a transport failure.
private enum ProvenanceTransportError: Error {
    case unexpectedFile(String)
}
