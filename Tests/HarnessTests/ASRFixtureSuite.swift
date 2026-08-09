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

import AVFoundation
import Foundation
import VoccaCore

/// The C2 fixture suite's machinery: fixtures in, per-engine WER out — one harness, run
/// parameterized over every `ASREngine` (C3's whisper.cpp is a swap, not a rewrite).
///
/// Everything here runs headlessly: the fixtures are checked-in 16 kHz mono clips with golden
/// transcripts, and the engines under test are test doubles in the harness tests. The
/// real-model half (`ParakeetEngineWERTests`) drives the same two functions with a real engine
/// on a machine that has one.
struct ASRFixtureCase: Sendable {
    /// The fixture's base name — `clean`, `noisy`, `sixty-second`, …
    let name: String
    /// The audio as the seam speaks it: 16 kHz mono Float32. (Explicitly `VoccaCore.AudioBuffer`:
    /// FluidAudio ships its own type of the same name, and the test target links both.)
    let buffer: VoccaCore.AudioBuffer
    /// The expected transcript, written naturally — the scorer normalizes.
    let goldenText: String
}

/// One engine's result on one fixture.
struct ASRFixtureResult: Sendable {
    let name: String
    let wer: Double
    let transcript: String
    let engine: EngineIdentity
}

enum ASRFixtureSuite {

    /// Discovers `*.wav` + matching `.txt` pairs under `Tests/Fixtures/`.
    ///
    /// A clip without a golden is a broken fixture, and a broken fixture must fail loudly —
    /// a suite that cannot measure must never read as green.
    static func loadFixtures(from fixturesDirectory: URL? = nil) throws -> [ASRFixtureCase] {
        let directory: URL
        if let fixturesDirectory {
            directory = fixturesDirectory
        } else {
            directory = try PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Tests/Fixtures")
        }
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        let wavs = entries.filter { $0.pathExtension == "wav" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        guard !wavs.isEmpty else {
            throw ASRFixtureSuiteError.noFixturesFound(directory.path)
        }
        return try wavs.map { wav in
            let golden = wav.deletingPathExtension().appendingPathExtension("txt")
            guard fileManager.fileExists(atPath: golden.path) else {
                throw ASRFixtureSuiteError.missingGolden(
                    fixture: wav.lastPathComponent, expectedAt: golden.path)
            }
            let samples = try readSamples16kMono(from: wav)
            let goldenText = try String(contentsOf: golden, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ASRFixtureCase(
                name: wav.deletingPathExtension().lastPathComponent,
                buffer: VoccaCore.AudioBuffer(samples: samples, sampleRate: 16_000),
                goldenText: goldenText)
        }
    }

    /// Runs one engine over the fixtures and scores each transcript.
    static func evaluate(
        _ engine: any ASREngine, fixtures: [ASRFixtureCase]
    ) async throws -> [ASRFixtureResult] {
        var results: [ASRFixtureResult] = []
        for fixture in fixtures {
            let transcript = try await engine.transcribe(fixture.buffer)
            results.append(
                ASRFixtureResult(
                    name: fixture.name,
                    wer: WER.compute(reference: fixture.goldenText, hypothesis: transcript.text),
                    transcript: transcript.text,
                    engine: transcript.engine))
        }
        return results
    }

    private enum ASRFixtureSuiteError: Error, CustomStringConvertible {
        case noFixturesFound(String)
        case missingGolden(fixture: String, expectedAt: String)
        case cannotAllocateBuffer
        case cannotCreateConverter
        case conversionFailed(String)

        var description: String {
            switch self {
            case .noFixturesFound(let path):
                return "no .wav fixtures found under \(path) — the suite has nothing to measure"
            case .missingGolden(let fixture, let expectedAt):
                return "fixture \(fixture) has no golden transcript at \(expectedAt)"
            case .cannotAllocateBuffer:
                return "could not allocate PCM buffer"
            case .cannotCreateConverter:
                return "could not create AVAudioConverter"
            case .conversionFailed(let detail):
                return "conversion failed: \(detail)"
            }
        }
    }

    /// Reads any WAV into 16 kHz mono Float32 — the seam's format — via AVFoundation.
    private static func readSamples16kMono(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw ASRFixtureSuiteError.cannotAllocateBuffer }
        try file.read(into: buffer)

        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw ASRFixtureSuiteError.cannotCreateConverter
        }
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw ASRFixtureSuiteError.cannotAllocateBuffer
        }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            throw ASRFixtureSuiteError.conversionFailed(
                error?.localizedDescription ?? "unknown")
        }
        guard let channels = output.floatChannelData else {
            throw ASRFixtureSuiteError.conversionFailed("no float data")
        }
        return Array(UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength)))
    }

}
