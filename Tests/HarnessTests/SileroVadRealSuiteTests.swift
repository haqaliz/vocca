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

import VoccaASR
import VoccaCore
import VoccaSpeech
import XCTest

/// The parameterized voice-activity suite over the real ``SileroVAD`` adapter
/// (`sdk-adapters/plan_20260915.md` Step 3.2): the same ``VoiceActivityFixtureSuite/evaluate(_:cases:)``
/// body the `EnergyVAD` CI leg runs, now with the FluidAudio model behind it — measured on the
/// founder's machine.
///
/// Env-gated on `VOCCA_RUN_REAL_VAD` **and** `VOCCA_VAD_MODEL_DIR` — the two-variable pattern the
/// real suites use (`SpeechKokoroSuiteTests`, `EquivalenceRealEngineTests`): the first says "run
/// the real VAD", the second names the directory **containing**
/// `silero-vad-unified-256ms-v6.2.1.mlmodelc` (the staged `vad/` directory the manifest's
/// `sdkDirectory` describes). Without either — or with a path that is not a directory, or a
/// directory without the model — the tests **skip visibly** with a message naming both variables;
/// CI has no VAD model, so CI runs the skip path (the skip still counts in the executed tally,
/// which the floor math depends on). Real-run command: bare
/// `swift test --filter SileroVadRealSuiteTests` — never through the floor script.
///
/// The fixture renders speech **locally** through ``SystemSynthesizer`` (AVSpeechSynthesizer
/// works in a test process on the founder's machine — `SpeechSystemSuiteTests` proves it), decodes
/// the little-endian Float32 chunk bytes at the renderer's own rate (~22050 Hz), and resamples to
/// the interchange rate with a **test-local pure helper** — a fixture artifact; the adapter never
/// converts (the production path is the identity conversion). The silence fixture is 4096-sample
/// zero buffers.
final class SileroVadRealSuiteTests: XCTestCase {

    private static let modelFileName = "silero-vad-unified-256ms-v6.2.1.mlmodelc"

    /// The two-variable gate: `VOCCA_RUN_REAL_VAD` present and `VOCCA_VAD_MODEL_DIR` naming a
    /// directory that contains the model. Either missing — or the path not a directory, or the
    /// model absent from it — is a visible skip naming both variables, never a silent pass.
    private static func gatedModelDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOCCA_RUN_REAL_VAD"] != nil,
            let modelPath = environment["VOCCA_VAD_MODEL_DIR"]
        else {
            throw XCTSkip(
                "set VOCCA_RUN_REAL_VAD=1 and VOCCA_VAD_MODEL_DIR=<directory containing "
                    + "\(modelFileName)> to run the real Silero VAD suite — CI has no VAD model")
        }
        let directory = URL(fileURLWithPath: modelPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelPath, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw XCTSkip(
                "VOCCA_VAD_MODEL_DIR does not name a directory (\(modelPath)) — point it at the "
                    + "staged directory containing \(modelFileName); VOCCA_RUN_REAL_VAD is set")
        }
        guard
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(modelFileName).path)
        else {
            throw XCTSkip(
                "VOCCA_VAD_MODEL_DIR names \(modelPath) but it does not contain "
                    + "\(modelFileName) — provision the model with "
                    + "Scripts/provision-vad-fixtures.sh; VOCCA_RUN_REAL_VAD is set")
        }
        return directory
    }

    /// The seam configuration the `EnergyVAD` CI leg runs — the same numbers, so the real leg
    /// compares like with like. `minimumSilence` maps onto the SDK's `minSilenceDuration`.
    private static func seamConfiguration() -> VADConfiguration {
        VADConfiguration(
            onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)
    }

    // MARK: - The fixture (test-local, pure)

    /// Renders ~3 s of speech through the system renderer and returns 16 kHz mono samples.
    ///
    /// The chunk bytes are the renderer's own (little-endian Float32 at its own rate, ~22050 Hz —
    /// the `KokoroEngine` decode precedent); the resample to the interchange rate is this
    /// fixture's own pure helper. Nothing here is production code.
    private static func speechFixtureSamples() async throws -> [Float] {
        let synth = SystemSynthesizer(voiceIdentifier: nil)
        let text = "The quick brown fox jumps over the lazy dog and then it rests under the oak."

        var rendered: [Float] = []
        var sourceRate: Double?
        for try await chunk in synth.speak(text) {
            sourceRate = chunk.sampleRate
            rendered.append(
                contentsOf: decodeLittleEndianFloat32(
                    chunk.bytes, channelCount: chunk.channelCount))
        }
        guard let rate = sourceRate, !rendered.isEmpty else {
            throw SileroVadRealSuiteError.emptyFixtureRender
        }
        return resample(rendered, from: rate, to: Double(AudioBuffer.interchangeSampleRate))
    }

    /// The chunk bytes as frames: little-endian Float32, taking the first channel when the
    /// renderer delivers more than one.
    private static func decodeLittleEndianFloat32(
        _ bytes: [UInt8], channelCount: Int
    ) -> [Float] {
        let stride = max(channelCount, 1)
        var samples: [Float] = []
        samples.reserveCapacity(bytes.count / (MemoryLayout<Float>.size * stride))
        var index = 0
        while index + MemoryLayout<Float>.size <= bytes.count {
            var bits: UInt32 = 0
            bits |= UInt32(bytes[index])
            bits |= UInt32(bytes[index + 1]) << 8
            bits |= UInt32(bytes[index + 2]) << 16
            bits |= UInt32(bytes[index + 3]) << 24
            samples.append(Float(bitPattern: bits))
            index += MemoryLayout<Float>.size * stride
        }
        return samples
    }

    /// Linear-interpolation resample — the fixture's pure helper, never production code.
    private static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double)
        -> [Float]
    {
        guard !samples.isEmpty, sourceRate > 0, sourceRate != targetRate else { return samples }
        let ratio = sourceRate / targetRate
        let outputCount = Int(Double(samples.count) / ratio)
        return (0..<outputCount).map { index in
            let position = Double(index) * ratio
            let lower = Int(position)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }

    /// Frames 16 kHz samples into 4096-sample `AudioBuffer`s — the model's own chunk boundary.
    private static func frames(from samples: [Float]) -> [AudioBuffer] {
        stride(from: 0, to: samples.count, by: 4096).map { start in
            AudioBuffer(
                samples: Array(samples[start..<min(start + 4096, samples.count)]),
                sampleRate: AudioBuffer.interchangeSampleRate)
        }
    }

    private static func silenceFrames(count: Int) -> [AudioBuffer] {
        (0..<count).map { _ in
            AudioBuffer(
                samples: Array(repeating: 0, count: 4096),
                sampleRate: AudioBuffer.interchangeSampleRate)
        }
    }

    // MARK: - Row 1: the honest claim

    /// **Row 1.** The real adapter classifies a rendered-speech fixture as speech and a silence
    /// fixture as silence — nothing more.
    ///
    /// The silence leg runs first and is asserted **exactly**: a fresh detector starts in
    /// silence, so a zero fixture must stay `.silence` throughout (four chunks — no onset ever
    /// fires). The speech leg then runs over the same detector instance (real VAD state persists
    /// across cases, exactly as ``VoiceActivityFixtureSuite`` documents) and is asserted only by
    /// its **direction of travel**: at least one `.speech` classification. The model's exact
    /// onset timing is its own — no WER-style claims, no timing claims; the classifications are
    /// recorded in the fixture body, never gated per frame.
    func testTheRealSileroVADClassifiesASpeechFixtureAsSpeechAndSilenceAsSilence() async throws {
        let modelDirectory = try Self.gatedModelDirectory()
        let speech = Self.frames(from: try await Self.speechFixtureSamples())
        XCTAssertFalse(speech.isEmpty, "the speech fixture must render audio")

        let cases: [VoiceActivityFixtureCase] = [
            VoiceActivityFixtureCase(
                name: "silence",
                frames: Self.silenceFrames(count: 4),
                expected: [.silence, .silence, .silence, .silence]),
            VoiceActivityFixtureCase(
                name: "speech",
                frames: speech,
                expected: Array(repeating: .speech, count: speech.count)),
        ]

        var detector: any VoiceActivityDetector = SileroVAD(
            configuration: Self.seamConfiguration(), modelDirectory: modelDirectory)
        let results = try VoiceActivityFixtureSuite.evaluate(&detector, cases: cases)

        XCTAssertEqual(
            results.map(\.name), cases.map(\.name),
            "every fixture runs, in order — a suite that skips a fixture reads green while a leg "
                + "goes unmeasured")

        let silence = try XCTUnwrap(results.first { $0.name == "silence" })
        XCTAssertEqual(
            silence.classifications, [.silence, .silence, .silence, .silence],
            "the silence fixture must stay .silence throughout — a zero signal carries no speech "
                + "evidence")

        let speechResult = try XCTUnwrap(results.first { $0.name == "speech" })
        XCTAssertTrue(
            speechResult.classifications.contains(.speech),
            "the speech fixture must yield at least one .speech classification — recorded "
                + "classifications: \(speechResult.classifications)")
    }

    // MARK: - Row 2: measured, never gated

    /// **Row 2.** The per-chunk classify cost of the real adapter, printed for the record,
    /// asserted only to be a real measurement (finite, positive).
    ///
    /// The measurement is **warm**: one full fixture pass is consumed first, so the CoreML model
    /// compile and the SDK's first-chunk setup are a prepare fact — never part of the number.
    /// The printed `<ms>` is the mean wall-clock per `classify` call over the timed pass (the
    /// sync→actor bridge included — that is the cost the seam's callers pay); `chunks=N` is the
    /// number of classify calls timed. The 200 ms barge-in budget decomposition is the
    /// `barge-in-loop` aspect's; this row is its recorded input, never a CI gate.
    func testTheRealSileroVADClassifyLatencyIsMeasuredAndRecorded() async throws {
        let modelDirectory = try Self.gatedModelDirectory()
        let frames = Self.frames(from: try await Self.speechFixtureSamples())
        XCTAssertFalse(frames.isEmpty, "the latency fixture must render audio")

        var detector: any VoiceActivityDetector = SileroVAD(
            configuration: Self.seamConfiguration(), modelDirectory: modelDirectory)

        // Warm-up: the model load and CoreML compile are a prepare fact.
        for frame in frames { _ = detector.classify(frame) }

        let clock = ContinuousClock()
        let start = clock.now
        for frame in frames { _ = detector.classify(frame) }
        let elapsed = start.duration(to: clock.now)
        let totalMilliseconds = elapsed / .milliseconds(1)
        let perChunkMilliseconds = totalMilliseconds / Double(frames.count)

        print(
            "VAD-CLASSIFY-LATENCY\t\(String(format: "%.1f", perChunkMilliseconds))ms"
                + "\tchunks=\(frames.count)\trecorded-never-gated")

        XCTAssertTrue(
            perChunkMilliseconds.isFinite && perChunkMilliseconds > 0,
            "the measurement must be a real one: finite and positive, got "
                + "\(perChunkMilliseconds)ms over \(frames.count) chunks")
    }
}

/// A fixture-construction failure — a render that produced nothing measures nothing, so it
/// fails loudly rather than reporting a green row it never earned.
private enum SileroVadRealSuiteError: Error, CustomStringConvertible {
    case emptyFixtureRender

    var description: String {
        "the system renderer produced no audio for the fixture text — the real VAD row would "
            + "measure nothing"
    }
}