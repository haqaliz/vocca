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

/// The fixture harness, proven end-to-end without a model: one `evaluate` body, run
/// parameterized over engine implementations (the C3 swap shape), with the imperfect stub's
/// WER asserted to equal the scorer's own arithmetic — the plumbing can only be right if the
/// score it computes over a known-bad transcript is the score the scorer would compute directly.
///
/// The real-model half of the suite (`ParakeetEngineWERTests`) calls the same two functions;
/// everything below runs in CI, now and ever.
final class ASRFixtureHarnessTests: XCTestCase {

    private func fixtures() throws -> [ASRFixtureCase] {
        let fixtures = try ASRFixtureSuite.loadFixtures()
        XCTAssertGreaterThan(
            fixtures.count, 0, "the checked-in fixture set must not be empty")
        return fixtures
    }

    /// A stub that echoes the golden scores exactly zero on every fixture — the plumbing's
    /// happy path: wav → buffer → engine → transcript → scorer, with attribution intact.
    func testTheGoldenEchoingStubScoresZeroOnEveryFixture() async throws {
        let identity = EngineIdentity(
            id: "echo-stub", displayName: "Echo Stub", isLocal: true)
        for fixture in try fixtures() {
            let stub = StubTranscriber(identity: identity) { _ in fixture.goldenText }
            let results = try await ASRFixtureSuite.evaluate(stub, fixtures: [fixture])

            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(
                results[0].wer, 0,
                "\(fixture.name): an engine that echoes the golden must score zero")
            XCTAssertEqual(
                results[0].engine, identity,
                "\(fixture.name): the result must be attributed to the engine that made it")
        }
    }

    /// A stub that drops every third word scores exactly what the scorer computes directly —
    /// the end-to-end proof that the harness measures what `WER.compute` defines.
    func testTheImperfectStubScoresExactlyTheScorersArithmetic() async throws {
        let identity = EngineIdentity(
            id: "imperfect-stub", displayName: "Imperfect Stub", isLocal: true)
        for fixture in try fixtures() {
            let hypothesis = Self.dropEveryThirdWord(fixture.goldenText)
            let stub = StubTranscriber(identity: identity) { _ in hypothesis }
            let results = try await ASRFixtureSuite.evaluate(stub, fixtures: [fixture])

            XCTAssertEqual(
                results[0].wer,
                WER.compute(reference: fixture.goldenText, hypothesis: hypothesis),
                "\(fixture.name): the harness WER must equal the scorer's direct computation")
            XCTAssertEqual(results[0].transcript, hypothesis)
            XCTAssertEqual(results[0].engine, identity)
        }
    }

    /// One test body, two engine implementations — the parameterization the C3 swap test
    /// inherits: `evaluate` never branches on which engine it is given.
    func testTheSameEvaluateBodyRunsOverBothStubImplementations() async throws {
        let perfect = EngineIdentity(id: "perfect", displayName: "Perfect", isLocal: true)
        let imperfect = EngineIdentity(id: "imperfect", displayName: "Imperfect", isLocal: true)
        for fixture in try fixtures() {
            let dropped = Self.dropEveryThirdWord(fixture.goldenText)
            let engines: [(any ASREngine, Double)] = [
                (StubTranscriber(identity: perfect) { _ in fixture.goldenText }, 0),
                (StubTranscriber(identity: imperfect) { _ in dropped },
                 WER.compute(reference: fixture.goldenText, hypothesis: dropped)),
            ]
            for (engine, expectedWER) in engines {
                let results = try await ASRFixtureSuite.evaluate(engine, fixtures: [fixture])
                XCTAssertEqual(
                    results[0].wer, expectedWER,
                    "\(fixture.name): the parameterized body must score each engine on its own merits")
                XCTAssertEqual(results[0].engine, engine.identity)
            }
        }
    }

    /// A fixture without its golden is a broken measurement and must fail loudly, not skip.
    func testAFixtureWithoutItsGoldenFailsLoudly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-fixture-lint", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: directory.appendingPathComponent("orphan.wav"))

        XCTAssertThrowsError(try ASRFixtureSuite.loadFixtures(from: directory)) { error in
            XCTAssertTrue(
                String(describing: error).contains("orphan.wav"),
                "the failure must name the fixture that cannot be measured, got \(error)")
        }
    }

    /// Drops the words at every third position (indices 2, 5, 8, …) — the imperfect stub's
    /// shape, defined over whitespace tokens of the raw golden.
    private static func dropEveryThirdWord(_ text: String) -> String {
        text.split(separator: " ").enumerated()
            .filter { $0.offset % 3 != 2 }
            .map { String($0.element) }
            .joined(separator: " ")
    }
}

/// A minimal `ASREngine` whose transcription is an injected function of the buffer — the
/// parameterization vehicle for the harness tests.
actor StubTranscriber: ASREngine {

    nonisolated let identity: EngineIdentity
    nonisolated var supportsStreaming: Bool { false }

    private let answer: @Sendable (AudioBuffer) -> String

    init(identity: EngineIdentity, answer: @escaping @Sendable (AudioBuffer) -> String) {
        self.identity = identity
        self.answer = answer
    }

    func prepare() async throws {}

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        Transcript(
            text: answer(buffer),
            segments: [],
            engine: identity,
            isFinal: true,
            audioDuration: buffer.audioDuration,
            missingSampleCount: buffer.missingSampleCount)
    }
}
