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

/// The shared real-engine runner's own contract, driven headlessly with a stub engine
/// (`plan_20260810.md` Phase 1): attribution, tolerance ceilings, the 200 ms substitution rule,
/// and the loud failure for a suite with nothing to measure.
///
/// Each test runs the runner against a hand-built **single-fixture** directory, so the stub's
/// answer is unambiguous — the runner loads fixtures through the same `ASRFixtureSuite` machinery
/// the real runs use, and the wavs go through the same AVFoundation loader as the shipped clips.
final class RealEngineWERRunnerTests: XCTestCase {

    // MARK: - Attribution

    /// A transcript that carries the wrong engine fails the run before any tolerance is consulted:
    /// a whisper transcript under a parakeet-expected run is a downstream lie, not a score.
    func testTheRunnerFiresWhenATranscriptCarriesTheWrongEngine() async throws {
        let directory = try makeFixtureDirectory(named: "clean", golden: "the quick brown fox")
        defer { try? FileManager.default.removeItem(at: directory) }
        let misattributingStub = StubTranscriber(
            identity: WhisperCppEngineIdentity.whisper) { _ in "the quick brown fox" }

        do {
            try await RealEngineWERRunner.run(
                engine: misattributingStub,
                expectedIdentity: ParakeetEngineIdentity.parakeet,
                toleranceTable: ["clean": 1.0],
                fixturesDirectory: directory)
            XCTFail("a transcript attributed to another engine must fail the run")
        } catch let error as RealEngineWERRunnerError {
            guard case .attributionMismatch(let fixture, let expected, let actual, _) = error else {
                XCTFail("expected attributionMismatch, got \(error)")
                return
            }
            XCTAssertEqual(fixture, "clean")
            XCTAssertEqual(expected, ParakeetEngineIdentity.parakeet)
            XCTAssertEqual(actual, WhisperCppEngineIdentity.whisper)
        }
    }

    // MARK: - Tolerances

    /// A WER above the fixture's ceiling fails the run, naming the fixture and both numbers.
    func testTheRunnerFiresWhenTheWERExceedsTheTolerance() async throws {
        let directory = try makeFixtureDirectory(named: "clean", golden: "the quick brown fox")
        defer { try? FileManager.default.removeItem(at: directory) }
        // One deletion out of four words: exactly WER 0.25, over the 0.0 ceiling.
        let imperfectStub = StubTranscriber(
            identity: ParakeetEngineIdentity.parakeet) { _ in "the quick fox" }

        do {
            try await RealEngineWERRunner.run(
                engine: imperfectStub,
                expectedIdentity: ParakeetEngineIdentity.parakeet,
                toleranceTable: ["clean": 0.0],
                fixturesDirectory: directory)
            XCTFail("a WER over the tolerance must fail the run")
        } catch let error as RealEngineWERRunnerError {
            guard case .toleranceExceeded(let fixture, let wer, let tolerance, _, _) = error else {
                XCTFail("expected toleranceExceeded, got \(error)")
                return
            }
            XCTAssertEqual(fixture, "clean")
            XCTAssertEqual(wer, 0.25)
            XCTAssertEqual(tolerance, 0.0)
        }
    }

    /// A WER within the ceiling passes — the run returns without a throw.
    func testTheRunnerPassesWhenTheWERIsWithinTolerance() async throws {
        let directory = try makeFixtureDirectory(named: "clean", golden: "the quick brown fox")
        defer { try? FileManager.default.removeItem(at: directory) }
        let goldenEcho = StubTranscriber(
            identity: ParakeetEngineIdentity.parakeet) { _ in "the quick brown fox" }

        try await RealEngineWERRunner.run(
            engine: goldenEcho,
            expectedIdentity: ParakeetEngineIdentity.parakeet,
            toleranceTable: ["clean": 1.0],
            fixturesDirectory: directory)
    }

    // MARK: - The 200 ms substitution rule

    /// The substitution rule is a rule of its own: with the fixture marked in `specialRules` and
    /// **no** table entry for it, a transcript two edits from the single-word golden fails — the
    /// rule, not a WER ceiling out of the table, is what bounds the clip.
    func testTheRunnerFiresWhenTheSubstitutionRuleIsViolated() async throws {
        let directory = try makeFixtureDirectory(named: "two-hundred-ms", golden: "test")
        defer { try? FileManager.default.removeItem(at: directory) }
        // "hello world" is two edits from the one-word golden: WER 2.0.
        let twoEditsAway = StubTranscriber(
            identity: ParakeetEngineIdentity.parakeet) { _ in "hello world" }

        do {
            try await RealEngineWERRunner.run(
                engine: twoEditsAway,
                expectedIdentity: ParakeetEngineIdentity.parakeet,
                toleranceTable: [:],
                specialRules: ["two-hundred-ms": .atMostOneSubstitution],
                fixturesDirectory: directory)
            XCTFail("a transcript two edits from the 200 ms golden must fail the run")
        } catch let error as RealEngineWERRunnerError {
            guard case .substitutionRuleViolated(let fixture, _, _, _) = error else {
                XCTFail("expected substitutionRuleViolated, got \(error)")
                return
            }
            XCTAssertEqual(fixture, "two-hundred-ms")
        }
    }

    /// The rule's boundary: one substitution (the golden's word mangled) is still within the rule —
    /// a single-word clip the engine nearly got is not a failure.
    func testTheRunnerAcceptsASingleSubstitutionUnderTheRule() async throws {
        let directory = try makeFixtureDirectory(named: "two-hundred-ms", golden: "test")
        defer { try? FileManager.default.removeItem(at: directory) }
        let oneSubstitution = StubTranscriber(
            identity: ParakeetEngineIdentity.parakeet) { _ in "tell" }

        try await RealEngineWERRunner.run(
            engine: oneSubstitution,
            expectedIdentity: ParakeetEngineIdentity.parakeet,
            toleranceTable: [:],
            specialRules: ["two-hundred-ms": .atMostOneSubstitution],
            fixturesDirectory: directory)
    }

    // MARK: - Empty suites

    /// A fixture directory with nothing to measure fails loudly — a suite that cannot measure must
    /// never read as green.
    func testAnEmptyFixturesDirectoryFailsLoudly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-real-engine-wer-runner", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = StubTranscriber(
            identity: ParakeetEngineIdentity.parakeet) { _ in "anything" }

        do {
            try await RealEngineWERRunner.run(
                engine: stub,
                expectedIdentity: ParakeetEngineIdentity.parakeet,
                toleranceTable: ["clean": 1.0],
                fixturesDirectory: directory)
            XCTFail("an empty fixture directory must fail the run, never pass green")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("no .wav fixtures found"),
                "the failure must name the empty discovery, got \(error)")
        }
    }

    // MARK: - Fixture building

    /// A one-fixture directory: a real 16 kHz mono PCM wav (readable by the same AVFoundation
    /// loader the shipped fixtures go through) plus its golden transcript.
    private func makeFixtureDirectory(named name: String, golden: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-real-engine-wer-runner", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.writeWav(named: name, into: directory)
        try golden.write(
            to: directory.appendingPathComponent(name + ".txt"),
            atomically: true, encoding: .utf8)
        return directory
    }

    /// A minimal 16-bit PCM mono 16 kHz wav: 0.1 s of silence. The loader needs the format, never
    /// the content — the stub's answer is a fixed string, not a function of the samples.
    private static func writeWav(named name: String, into directory: URL) throws {
        let samples: [Int16] = Array(repeating: 0, count: 1_600)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(Self.le32(UInt32(36 + samples.count * 2)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(Self.le32(16))
        data.append(Self.le16(1))  // PCM
        data.append(Self.le16(1))  // mono
        data.append(Self.le32(16_000))  // sample rate
        data.append(Self.le32(32_000))  // byte rate
        data.append(Self.le16(2))  // block align
        data.append(Self.le16(16))  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(Self.le32(UInt32(samples.count * 2)))
        for sample in samples {
            data.append(Self.le16(UInt16(bitPattern: sample)))
        }
        try data.write(to: directory.appendingPathComponent(name + ".wav"))
    }

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}
