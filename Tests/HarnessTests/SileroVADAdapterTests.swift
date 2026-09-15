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

import FluidAudio
import VoccaASR
import VoccaCore
import XCTest

/// The `sdk-adapters` aspect's headless contract (`plan_20260915.md` Phase 1): every test CI can
/// execute, written against the not-yet-existing `SileroVAD` / `SileroVADConfiguration` /
/// `SileroVADDerivedConfig`. Compile-time RED is the right reason — the seam signatures are
/// final (voice-detection shipped them), and the missing types are the adapter's.
///
/// The SDK types are importable in a test file (`FluidAudio`); the H8b family lint scans
/// `Sources/` only, never `Tests/`.
///
/// What CI can reach of the real adapter is deliberately small and the suite is deliberately
/// strict about it: the **pure init** (the probe's construct contract — construction touches
/// nothing), the **short-circuit rules** (an empty frame or a sub-chunk frame must never reach
/// the model, observable precisely because the model is absent), the **memoized clear error**,
/// and the two pure functions (`derivedConfig`, `chunked`) that pin the identity conversion
/// (seam samples reach the SDK boundary sample-for-sample) and the seam→SDK config mapping.
///
/// Every detector is consumed as `any VoiceActivityDetector` — the seam's no-branch pin applied
/// to the real adapter: a caller that must know `SileroVAD` to use it stops compiling here.
final class SileroVADAdapterTests: XCTestCase {

    /// The seam's no-branch compile pin: the adapter is a `VoiceActivityDetector`, nothing more.
    private func requireDetector(_ detector: any VoiceActivityDetector) -> any VoiceActivityDetector {
        detector
    }

    /// The voice-detection fixture configuration — the same numbers the `VoiceActivitySuiteTests`
    /// leg runs, so the env-gated real leg compares like with like.
    private func seamConfiguration() -> VADConfiguration {
        VADConfiguration(
            onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)
    }

    /// A fresh, empty temporary directory — the model-absent state every short-circuit row needs.
    private func emptyTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "vocca-silero-vad-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Compile pins

    /// The adapter conforms to the seam and exposes the seam's vocabulary: `configuration` is the
    /// seam's own `VADConfiguration`, and `classify` answers with `SpeechActivity`.
    func testSileroVADConformsToTheVoiceActivityDetectorSeam() throws {
        let directory = try emptyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let detector = requireDetector(
            SileroVAD(configuration: seamConfiguration(), modelDirectory: directory))
        let configuration: VADConfiguration = detector.configuration
        XCTAssertEqual(configuration.onsetRMS, 0.05)
        XCTAssertEqual(configuration.offsetRMS, 0.02)
        XCTAssertEqual(configuration.minimumSpeech, 0.10)
        XCTAssertEqual(configuration.minimumSilence, 0.20)
    }

    /// The `SileroVADConfiguration` defaults are **the SDK's own** — a drift on either side fails:
    /// the adapter's default `speechThreshold` must equal `VadConfig`'s, and the hysteresis
    /// pair's defaults must equal `VadSegmentationConfig`'s.
    func testTheSileroVADConfigurationDefaultsAreTheSDKsOwn() {
        let sdk = SileroVADConfiguration()
        XCTAssertEqual(sdk.speechThreshold, VadConfig.default.defaultThreshold)
        XCTAssertEqual(sdk.negativeThresholdOffset, VadSegmentationConfig().negativeThresholdOffset)
        XCTAssertEqual(sdk.speechPadding, VadSegmentationConfig().speechPadding)
    }

    // MARK: - The construct-only pin (the probe contract)

    /// Construction over a fresh, empty directory throws nothing and records no failure: the init
    /// stores plain data and touches nothing (no model bytes, no directory reads, no network).
    func testConstructionIsPureAndTouchesNothing() throws {
        let directory = try emptyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let vad = SileroVAD(configuration: seamConfiguration(), modelDirectory: directory)
        let detector: any VoiceActivityDetector = requireDetector(vad)
        XCTAssertNil(vad.loadFailureDescription, "construction must not touch the model")
    }

    // MARK: - The short-circuit rules

    /// An empty frame carries no evidence, accumulates nothing, and never touches the model —
    /// the probe's empty-frame pin, made load-bearing for the real adapter.
    func testAnEmptyFrameNeverTouchesTheModel() throws {
        let directory = try emptyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let vad = SileroVAD(configuration: seamConfiguration(), modelDirectory: directory)
        var detector: any VoiceActivityDetector = requireDetector(vad)
        let activity = detector.classify(AudioBuffer(samples: [], sampleRate: 16_000))
        XCTAssertEqual(activity, .silence)
        XCTAssertNil(
            vad.loadFailureDescription,
            "an empty frame must not reach the model — the missing model dir is observable only "
                + "if a frame attempted the load")
    }

    /// The real adapter's decision granularity is the model's 256 ms chunk (4096 samples @
    /// 16 kHz): a frame that cannot complete a chunk returns the current state and never touches
    /// the model.
    func testASubChunkFrameNeverTouchesTheModel() throws {
        let directory = try emptyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let vad = SileroVAD(configuration: seamConfiguration(), modelDirectory: directory)
        var detector: any VoiceActivityDetector = requireDetector(vad)
        let frame = AudioBuffer(
            samples: Array(repeating: 0.1, count: 1000), sampleRate: 16_000)
        XCTAssertEqual(detector.classify(frame), .silence)
        XCTAssertNil(
            vad.loadFailureDescription,
            "a 1000-sample frame cannot complete a 4096-sample chunk — the load must not be attempted")
    }

    /// A frame that completes a chunk attempts the load — against a missing model dir that means
    /// a recorded clear error, never a silent speech decision and never a network fallback.
    func testACompletedChunkAttemptsTheLoadAndRecordsTheClearError() throws {
        let directory = try emptyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let vad = SileroVAD(configuration: seamConfiguration(), modelDirectory: directory)
        var detector: any VoiceActivityDetector = requireDetector(vad)
        let frame = AudioBuffer(
            samples: Array(repeating: 0.1, count: 4096), sampleRate: 16_000)
        XCTAssertEqual(detector.classify(frame), .silence)
        XCTAssertNotNil(
            vad.loadFailureDescription,
            "a completed 4096-sample chunk must attempt the model load — the failure is the "
                + "observable, and it must be recorded")
    }

    /// The clear error is memoized: two chunk-completing classifies against the same missing dir
    /// record **one** failure (the same recorded description — never a retry per frame, never a
    /// download), and both answer `.silence`.
    func testTheClearErrorIsMemoized() throws {
        let directory = try emptyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let vad = SileroVAD(configuration: seamConfiguration(), modelDirectory: directory)
        var detector: any VoiceActivityDetector = requireDetector(vad)
        let frame = AudioBuffer(
            samples: Array(repeating: 0.1, count: 4096), sampleRate: 16_000)
        XCTAssertEqual(detector.classify(frame), .silence)
        let first = vad.loadFailureDescription
        XCTAssertNotNil(first, "the first chunk-completing classify must record the load failure")
        XCTAssertEqual(detector.classify(frame), .silence)
        XCTAssertEqual(
            vad.loadFailureDescription, first,
            "the recorded failure is memoized — a retry per frame would overwrite or clear it")

        XCTAssertTrue(
            first!.contains("silero-vad-unified-256ms-v6.2.1.mlmodelc"),
            "the clear error must name the expected model path: \(first!)")
    }

    // MARK: - missingSampleCount

    /// The decision is over the present samples only: same samples with `missingSampleCount` 0 vs
    /// 4096 produce identical chunks and identical decisions (the voice-detection pin, applied to
    /// the real adapter).
    func testMissingSampleCountNeverReachesTheDecision() throws {
        let directory = try emptyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let samples = (0..<5000).map { Float($0 % 7) / 7.0 }

        let complete = AudioBuffer(samples: samples, sampleRate: 16_000, missingSampleCount: 0)
        let short = AudioBuffer(samples: samples, sampleRate: 16_000, missingSampleCount: 4096)

        let fromComplete = SileroVAD.chunked([], frame: complete)
        let fromShort = SileroVAD.chunked([], frame: short)
        XCTAssertEqual(fromComplete.chunks, fromShort.chunks)
        XCTAssertEqual(fromComplete.remainder, fromShort.remainder)

        let completeVad = SileroVAD(configuration: seamConfiguration(), modelDirectory: directory)
        let shortVad = SileroVAD(configuration: seamConfiguration(), modelDirectory: directory)
        var completeDetector: any VoiceActivityDetector = requireDetector(completeVad)
        var shortDetector: any VoiceActivityDetector = requireDetector(shortVad)
        XCTAssertEqual(
            completeDetector.classify(complete), shortDetector.classify(short),
            "missingSampleCount is the ASR seam's completeness link, never a VAD decision input")
        XCTAssertEqual(
            completeVad.loadFailureDescription, shortVad.loadFailureDescription)
    }

    // MARK: - The mapping tests (the only production functions CI can execute)

    /// `derivedConfig` maps the seam's config onto the SDK's, field for field, in both
    /// directions: the seam's hold times ride into `minSpeechDuration`/`minSilenceDuration`, the
    /// SDK's threshold/padding values ride into their own fields.
    func testDerivedConfigMapsTheSeamConfigOntoTheSDKConfig() {
        let seam = seamConfiguration()
        let sdk = SileroVADConfiguration(
            speechThreshold: 0.7, negativeThresholdOffset: 0.25, speechPadding: 0.2)
        let derived = SileroVAD.derivedConfig(from: seam, sdk: sdk)

        XCTAssertEqual(derived.minSpeechDuration, seam.minimumSpeech)
        XCTAssertEqual(derived.minSilenceDuration, seam.minimumSilence)
        XCTAssertEqual(derived.speechThreshold, sdk.speechThreshold)
        XCTAssertEqual(derived.negativeThresholdOffset, sdk.negativeThresholdOffset)
        XCTAssertEqual(derived.speechPadding, sdk.speechPadding)
    }

    /// The SDK-defaults row: an un-tuned `SileroVADConfiguration` yields the SDK's own numbers,
    /// so neither side can drift silently.
    func testDerivedConfigDefaultsMatchTheSDKsOwnDefaults() {
        let derived = SileroVAD.derivedConfig(
            from: seamConfiguration(), sdk: SileroVADConfiguration())
        XCTAssertEqual(derived.speechThreshold, VadConfig.default.defaultThreshold)
        XCTAssertEqual(
            derived.negativeThresholdOffset, VadSegmentationConfig().negativeThresholdOffset)
        XCTAssertEqual(derived.speechPadding, VadSegmentationConfig().speechPadding)
        XCTAssertEqual(derived.minSpeechDuration, 0.10)
        XCTAssertEqual(derived.minSilenceDuration, 0.20)
    }

    /// `chunked` hands the frames' samples through **sample-for-sample** (the identity
    /// conversion — no resampling, no reordering), chunked at exactly the SDK's 4096-sample
    /// boundary, with the remainder kept for the next frame.
    func testChunkedHandsFramesThroughVerbatimAndRespectsTheChunkBoundary() {
        func run(_ frames: [AudioBuffer]) -> (chunks: [[Float]], remainder: [Float]) {
            var accumulator: [Float] = []
            var chunks: [[Float]] = []
            for frame in frames {
                let result = SileroVAD.chunked(accumulator, frame: frame)
                chunks.append(contentsOf: result.chunks)
                accumulator = result.remainder
            }
            return (chunks, accumulator)
        }

        // Empty frame → no chunks, no remainder.
        let empty = run([AudioBuffer(samples: [], sampleRate: 16_000)])
        XCTAssertTrue(empty.chunks.isEmpty)
        XCTAssertTrue(empty.remainder.isEmpty)

        // Boundary rows: 1, 4095, 4096, 8192, 10000 samples across multiple frames.
        let single = run([AudioBuffer(samples: [0.5], sampleRate: 16_000)])
        XCTAssertTrue(single.chunks.isEmpty)
        XCTAssertEqual(single.remainder, [0.5])

        let justUnder = run([AudioBuffer(
            samples: Array(repeating: 0.25, count: 4095), sampleRate: 16_000)])
        XCTAssertTrue(justUnder.chunks.isEmpty)
        XCTAssertEqual(justUnder.remainder.count, 4095)

        let exact = Array(repeating: Float(0.5), count: 4096)
        let oneChunk = run([AudioBuffer(samples: exact, sampleRate: 16_000)])
        XCTAssertEqual(oneChunk.chunks.count, 1)
        XCTAssertEqual(oneChunk.chunks[0], exact, "the chunk is the frame's samples verbatim")
        XCTAssertTrue(oneChunk.remainder.isEmpty)

        let twoExact = exact + exact
        let twoChunks = run([AudioBuffer(samples: twoExact, sampleRate: 16_000)])
        XCTAssertEqual(twoChunks.chunks.count, 2)
        XCTAssertEqual(twoChunks.chunks[0], exact)
        XCTAssertEqual(twoChunks.chunks[1], exact)
        XCTAssertTrue(twoChunks.remainder.isEmpty)

        // 10000 samples as two frames of 5000: two complete chunks + 1808 remainder, and the
        // chunked samples concatenate exactly to the input — sample-for-sample across frames.
        let tenThousand = (0..<10000).map { Float($0) / 10000.0 }
        let split = run([
            AudioBuffer(samples: Array(tenThousand[0..<5000]), sampleRate: 16_000),
            AudioBuffer(samples: Array(tenThousand[5000..<10000]), sampleRate: 16_000),
        ])
        XCTAssertEqual(split.chunks.count, 2)
        XCTAssertEqual(
            split.chunks.flatMap { $0 } + split.remainder, tenThousand,
            "the SDK samples are the seam samples concatenated sample-for-sample — no conversion, "
                + "no reordering")
        XCTAssertEqual(split.remainder.count, 10000 - 2 * 4096)

        // The boundary is the SDK's own: exactly `VadManager.chunkSize` per chunk.
        let boundary = run([AudioBuffer(samples: Array(repeating: 0.1, count: VadManager.chunkSize + 1), sampleRate: 16_000)])
        XCTAssertEqual(boundary.chunks.count, 1)
        XCTAssertEqual(boundary.chunks[0].count, VadManager.chunkSize)
        XCTAssertEqual(boundary.remainder.count, 1)
    }
}