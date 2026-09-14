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

import VoccaCore
import VoccaSpeech
import XCTest

/// The parameterized speech suite over the real Kokoro engine (`kokoro-binding`/`engine-binding`
/// spec R4-real): the same ``SpeechFixtureSuite/evaluate(_:fixtures:)`` body the stub suite runs in
/// CI and the system renderer runs env-gated, now with ``KokoroEngine`` behind it — the second
/// real `SpeechSynthesizer`, measured on the founder's machine.
///
/// Env-gated on `VOCCA_RUN_REAL_SPEECH` **and** `VOCCA_KOKORO_MODEL_DIR` — the two-variable
/// pattern the real-engine suites use (`EquivalenceRealEngineTests`): the first says "render real
/// speech", the second names the directory of extracted Kokoro models
/// (`kokoro_frontend.mlmodelc` + `kokoro_backend.mlmodelc` + `voices/`). Without either — or with
/// a `VOCCA_KOKORO_MODEL_DIR` that does not name a directory — the tests **skip visibly** with a
/// message naming both variables; CI has no model, so CI runs the skip path (the skip still counts
/// in the executed tally, which the floor math depends on).
///
/// The fixtures are the system suite's names, texts and duration floors — the same utterances
/// both real renderers are measured through. Everything asserted here is a measured claim about
/// the real engine's behaviour — duration floors, chunk ordering, cancel ≤50 ms wall-clock,
/// re-invoke — the numbers the seam's stub suite could only promise.
final class SpeechKokoroSuiteTests: XCTestCase {

    /// The two-variable gate: `VOCCA_RUN_REAL_SPEECH` present and `VOCCA_KOKORO_MODEL_DIR` naming
    /// an extracted-models directory. Either missing — or the path not a directory — is a visible
    /// skip naming both variables, never a silent pass.
    private static func gatedModelDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOCCA_RUN_REAL_SPEECH"] != nil,
            let modelPath = environment["VOCCA_KOKORO_MODEL_DIR"]
        else {
            throw XCTSkip(
                "set VOCCA_RUN_REAL_SPEECH=1 and VOCCA_KOKORO_MODEL_DIR=<extracted Kokoro models "
                    + "directory> to run the real Kokoro suite — CI has no Kokoro model")
        }
        let directory = URL(fileURLWithPath: modelPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelPath, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw XCTSkip(
                "VOCCA_KOKORO_MODEL_DIR does not name a directory (\(modelPath)) — point it at the "
                    + "extracted Kokoro models (kokoro_frontend.mlmodelc, kokoro_backend.mlmodelc, "
                    + "voices/); VOCCA_RUN_REAL_SPEECH is set")
        }
        return directory
    }

    /// The fixtures over the real engine: the same names, texts and duration floors as the stub
    /// and system suites. `three-sentence-reply` is the longer real-engine text the TTFA row
    /// measures; `short-reply` is the single-sentence duration floor.
    private static func fixtures() -> [SpeechFixtureCase] {
        [
            SpeechFixtureCase(
                name: "three-sentence-reply",
                text:
                    "Hello there. The quick brown fox jumps over the lazy dog, and then it rests "
                    + "under the old oak tree. Finally it sleeps until the morning light arrives.",
                minimumDuration: 1.0),
            SpeechFixtureCase(
                name: "short-reply",
                text: "Hello there.",
                minimumDuration: 0.25),
        ]
    }

    /// **R4-real.** The parameterized body over `KokoroEngine`: every fixture renders at least its
    /// pinned duration floor of PCM in arrival order, cancel halts the stream within 50 ms
    /// wall-clock with nothing after it, and the re-invoked render is complete.
    func testTheKokoroEngineRendersEveryFixtureWithDurationFloorCancelAndReinvoke() async throws {
        let modelDirectory = try Self.gatedModelDirectory()

        let synth = KokoroEngine(modelDirectory: modelDirectory, voice: "af_heart", rate: nil)
        let fixtures = Self.fixtures()
        let results = try await SpeechFixtureSuite.evaluate(synth, fixtures: fixtures)

        XCTAssertEqual(
            results.map(\.name), fixtures.map(\.name),
            "every fixture runs, in order — a suite that skips a fixture reads green while a leg goes unmeasured")
        for result in results {
            let fixture = fixtures.first { $0.name == result.name }!
            XCTAssertGreaterThanOrEqual(
                result.renderedDuration, fixture.minimumDuration,
                "fixture \(result.name): a known utterance must render at least its pinned duration floor of PCM — less is truncation")
            XCTAssertGreaterThanOrEqual(
                result.chunkCount, 1,
                "fixture \(result.name): the render must be non-empty audio, not a silent stream")
            XCTAssertTrue(
                result.chunkDurations.allSatisfy { $0 > 0 },
                "fixture \(result.name): every chunk in arrival order carries audio — a zero-duration chunk is a boundary leak: \(result.chunkDurations)")
            XCTAssertLessThanOrEqual(
                result.cancelLatency, .milliseconds(50),
                "fixture \(result.name): cancel must halt output within 50 ms, got \(result.cancelLatency)")
            XCTAssertGreaterThanOrEqual(
                result.reinvokedChunkCount, 1,
                "fixture \(result.name): the re-invoked speak must render — a deadlocked or half-cancelled session renders nothing")
            XCTAssertGreaterThanOrEqual(
                result.reinvokedDuration, fixture.minimumDuration,
                "fixture \(result.name): the re-invoked render's audio sums to at least the pinned floor — the second stream rendered fully")
        }
    }

    /// **The KOKORO-TTFA row.** Time to first chunk for a known multi-sentence fixture, printed
    /// for the record, asserted only to be a real measurement.
    ///
    /// The measurement is **warm**: a full warm-up speak is consumed first, so the CoreML model
    /// compile and the port's background warmup are a prepare fact — never part of the number.
    ///
    /// The ≤300 ms P3 budget is a **recorded measurement, never a CI gate** — the number lands in
    /// the SMOKE row as `KOKORO-TTFA` with the never-gated note, read against the system
    /// renderer's recorded 178.8 ms baseline. If it measures over the budget, the number is
    /// recorded verbatim and the Kokoro binding owns the budget.
    func testTimeToFirstChunkForAMultiSentenceFixtureIsMeasuredAndRecorded() async throws {
        let modelDirectory = try Self.gatedModelDirectory()

        let synth = KokoroEngine(modelDirectory: modelDirectory, voice: "af_heart", rate: nil)
        let fixture = Self.fixtures()[0]

        // The warm-up: the port engine is constructed lazily on the first non-empty speak and the
        // CoreML compile happens there — consumed fully so the measurement starts warm.
        for try await _ in synth.speak(fixture.text) {}

        let clock = ContinuousClock()
        var iterator = synth.speak(fixture.text).makeAsyncIterator()
        let start = clock.now
        let first = try await iterator.next()
        let ttfa = start.duration(to: clock.now)
        let milliseconds = ttfa / .milliseconds(1)

        print(
            "KOKORO-TTFA\t\(String(format: "%.1f", milliseconds))ms\tfixture=\(fixture.name)"
                + "\tbaseline=178.8ms\tbudget=300ms\trecorded-never-gated")

        XCTAssertNotNil(
            first,
            "the TTFA fixture must render a first chunk — a benchmark with no first chunk measures nothing")
        XCTAssertGreaterThan(
            first?.duration ?? 0, 0,
            "the first chunk carries audio — the time-to-first-chunk is time to first *speech*")
        XCTAssertGreaterThanOrEqual(
            ttfa, .zero,
            "time to first chunk cannot run backwards")
    }
}
