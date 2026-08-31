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

/// The streaming adapter's first real execution: the `clean` fixture through
/// `ParakeetEngine.stream` in 1 s chunks — env-gated exactly like `ParakeetEngineWERTests`,
/// because the model cannot reach a hosted runner (it skips visibly otherwise).
///
/// This row is the adapter's SMOKE half (`docs/SMOKE_CHECKLIST.md` step 124), not a claim: the
/// spec's acceptance is **finish-final text non-empty** — no WER comparison, no equivalence
/// verdict, no latency number. Open question 2 (final-vs-batch equivalence) belongs to the
/// equivalence-measurement aspect; the adapter is the vehicle, not the verdict. A green run here
/// proves one non-empty final on one machine, once — nothing more.
///
/// The partials half of the seam contract is deliberately not asserted here: with the SDK's
/// default window (11 s chunk + 2 s right context), the first update arrives only after ~13 s of
/// audio, and the `clean` fixture is shorter than that. Partials are observed on a long fixture
/// in the SMOKE step, never gated here.
final class ParakeetStreamingWERTests: XCTestCase {

    func testTheStreamingAdapterProducesOneNonEmptyFinalOnTheCleanFixture() async throws {
        guard
            let modelDir = ProcessInfo.processInfo.environment["VOCCA_MODEL_DIR"]
        else {
            throw XCTSkip(
                "set VOCCA_MODEL_DIR to a store-shaped version directory — see Scripts/provision-asr-fixtures.sh")
        }
        let modelDirectory = URL(fileURLWithPath: modelDir)

        // The shipped manifest: engineID/version/sdkDirectory + the digests the store verifies —
        // the `ParakeetEngineWERTests` construction, unchanged.
        let manifestURL = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaASR/Models/Manifests/parakeet-tdt-0.6b-v3.json")
        let manifest = try ModelManifest.load(from: Data(contentsOf: manifestURL))
        let store = ModelStore(
            rootURL: modelDirectory
                .deletingLastPathComponent()
                .deletingLastPathComponent())
        let engine = ParakeetEngine(
            store: store,
            manifest: manifest,
            transport: DefaultModelTransport(
                baseURL: URL(string: "https://unused.invalid")!),
            clock: ContinuousMonotonicClock())

        try await engine.prepare()

        let fixtures = try ASRFixtureSuite.loadFixtures()
        let clean = try XCTUnwrap(
            fixtures.first { $0.name == "clean" },
            "the fixture suite must contain the clean fixture")
        let samples = clean.buffer.samples

        // 1 s chunks at the interchange rate — the seam's own format, so the chunk builder is a
        // slice, never a conversion.
        let chunkSize = AudioBuffer.interchangeSampleRate
        let chunks = AsyncStream<VoccaCore.AudioBuffer> { continuation in
            var offset = 0
            while offset < samples.count {
                let end = min(offset + chunkSize, samples.count)
                continuation.yield(
                    VoccaCore.AudioBuffer(
                        samples: Array(samples[offset..<end]), sampleRate: 16_000))
                offset = end
            }
            continuation.finish()
        }

        var finals: [Transcript] = []
        for try await transcript in engine.stream(chunks) {
            if transcript.isFinal {
                finals.append(transcript)
            }
        }

        XCTAssertEqual(
            finals.count, 1,
            "the stream must yield exactly one final, got \(finals.count)")
        let final = try XCTUnwrap(finals.first)
        XCTAssertTrue(final.isFinal)
        XCTAssertFalse(
            final.text.isEmpty,
            "the finish-final text must be non-empty on the clean fixture — the spec's acceptance")
        XCTAssertEqual(
            final.engine, ParakeetEngineIdentity.parakeet,
            "the stream's final must be attributed to this engine")
    }
}