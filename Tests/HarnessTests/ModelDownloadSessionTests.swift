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

/// The download session seam's adapter (`download-ui` Phase 1): the store's progress and
/// outcome as an event stream the UI can consume without ever seeing a store type — headless,
/// over the stub transport.
final class ModelDownloadSessionTests: XCTestCase {

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

    private func makeStore() -> ModelStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-session-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        tempRoots.append(root)
        return ModelStore(rootURL: root)
    }

    private func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func makeManifest(weights: [UInt8]) -> ModelManifest {
        ModelManifest(engineID: engineID, version: version, files: [
            ManifestFile(name: "weights.bin", sha256: sha256Hex(weights), byteCount: weights.count),
        ])
    }

    /// Drives a session to completion and returns the events it produced. Static, so `async let`
    /// captures only the (Sendable) session, never the test case.
    private static func collect(_ session: StoreModelDownloadSession) async -> [ModelDownloadEvent] {
        var events: [ModelDownloadEvent] = []
        for await event in session.events {
            events.append(event)
        }
        return events
    }

    /// Happy path: monotonic progress ending in `.committed`.
    func testTheHappyPathEndsCommittedWithMonotonicProgress() async throws {
        let weights: [UInt8] = Array("weights-bytes".utf8)
        let store = makeStore()
        let stub = StubTransport(files: ["weights.bin": weights])
        let session = StoreModelDownloadSession(
            store: store, manifest: makeManifest(weights: weights), transport: stub)

        async let eventsTask = Self.collect(session)
        await session.start()
        let events = await eventsTask

        var last = -1.0
        for event in events {
            if case .progress(let fraction) = event {
                XCTAssertGreaterThanOrEqual(fraction, last, "progress must be monotonic")
                last = fraction
            }
        }
        XCTAssertEqual(events.last, .committed, "the stream must end committed")
        XCTAssertEqual(last, 1.0, "progress must reach exactly 1.0 before committing")
    }

    /// A corrupt-serving transport ends the stream in `.failed` with the cause, store not present.
    func testAFailureEndsInFailedWithTheCause() async throws {
        let good: [UInt8] = Array("good-bytes".utf8)
        let corrupt: [UInt8] = Array("wrong-bytes".utf8)
        let manifest = makeManifest(weights: good)
        let store = makeStore()
        let stub = StubTransport(files: ["weights.bin": corrupt], mode: .corruptBytes)
        let session = StoreModelDownloadSession(store: store, manifest: manifest, transport: stub)

        async let eventsTask = Self.collect(session)
        await session.start()
        let events = await eventsTask

        guard case .failed(let reason) = events.last else {
            XCTFail("a corrupt download must end in .failed, got \(events.last as Any)")
            return
        }
        XCTAssertTrue(
            reason.contains("weights.bin"),
            "the failure must name the cause, got \(reason)")
        let present = await store.isPresent(engineID: engineID, version: version)
        XCTAssertFalse(present)
    }

    /// `cancel()` mid-download ends the stream in `.cancelled` (the skip semantics), the `.part`
    /// survives, and a later download resumes from it.
    func testCancellingEndsInCancelledAndTheNextRunResumes() async throws {
        let weights: [UInt8] = Array(repeating: 7, count: 2_000)
        let store = makeStore()
        let stub = StubTransport(files: ["weights.bin": weights])
        let session = StoreModelDownloadSession(
            store: store, manifest: makeManifest(weights: weights), transport: stub)

        async let eventsTask = Self.collect(session)
        await session.start()

        // Let bytes land, then skip.
        let partURL = await store.baseURL(for: engineID, version: version)
            .appendingPathComponent("weights.bin.part")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if (try? FileManager.default.attributesOfItem(atPath: partURL.path)) != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        session.cancel()
        let events = await eventsTask

        XCTAssertEqual(
            events.last, .cancelled,
            "a user skip must end the stream in .cancelled")
        let preserved = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(preserved, 0, "the partial must survive the skip")

        // The next run resumes from the preserved size.
        let resuming = StubTransport(files: ["weights.bin": weights])
        let second = StoreModelDownloadSession(
            store: store, manifest: makeManifest(weights: weights), transport: resuming)
        async let secondEvents = Self.collect(second)
        await second.start()
        let events2 = await secondEvents
        XCTAssertEqual(events2.last, .committed)
        let ranges = await resuming.recordedRangeStarts
        XCTAssertEqual(ranges, [preserved], "the resuming run must resume from the partial size")
    }
}
