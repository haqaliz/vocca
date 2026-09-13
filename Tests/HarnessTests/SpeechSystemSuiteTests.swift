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

/// The parameterized speech suite over the real system synthesizer (`system-synthesizer` spec
/// R4-real): the same ``SpeechFixtureSuite/evaluate(_:fixtures:)`` body the stub suite runs, with
/// a real `SystemSynthesizer` behind it.
///
/// Env-gated on `VOCCA_RUN_REAL_SPEECH=1` — the C3 real-engine pattern. CI cannot render speech
/// reliably, so CI runs the skip path (visibly); the founder's machine runs the legs and records
/// the output. Everything asserted here is a measured claim about the real renderer's behaviour
/// — duration floors, chunk ordering, cancel ≤50 ms wall-clock, re-invoke — the numbers the
/// seam's stub suite could only promise.
///
/// The fixtures are tuned to what the first real run measured (2026-09-13): the system renderer
/// runs far ahead of its consumer (~20× realtime, ~256-frame buffers at 22050 Hz mono), so the
/// cancel leg's fixture leads with a short sentence and a long tail — the consumer reaches the
/// cancel at a sentence boundary inside the renderer's slack, which is what makes
/// "no chunk after cancel()" a measurement rather than a scheduling race.
final class SpeechSystemSuiteTests: XCTestCase {

    /// The fixtures over the real engine: the same names and duration floors as the stub suite,
    /// with the cancel-safe first sentence.
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

    /// **R4-real.** The parameterized body over `SystemSynthesizer`: every fixture renders at
    /// least its pinned duration floor of PCM in arrival order, cancel halts the stream within
    /// 50 ms wall-clock with nothing after it, and the re-invoked render is complete.
    func testTheSystemSynthesizerRendersEveryFixtureWithDurationFloorCancelAndReinvoke() async throws {
        guard ProcessInfo.processInfo.environment["VOCCA_RUN_REAL_SPEECH"] != nil else {
            throw XCTSkip(
                "set VOCCA_RUN_REAL_SPEECH=1 to run the real system-synthesizer suite — CI has "
                    + "no speech rendering environment")
        }

        let synth = SystemSynthesizer(voiceIdentifier: nil)
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

    /// **R5, the TTFA benchmark.** Time to first chunk for a known multi-sentence fixture,
    /// printed for the record (`SPEECH-TTFA`), asserted only to be a real measurement.
    ///
    /// The ≤300 ms P3 budget is a **recorded measurement, never a CI gate** — the number lands in
    /// `SMOKE_CHECKLIST.md` as step 126 with the never-gated note; if it measures over the budget,
    /// the number is recorded verbatim and the Kokoro binding owns the budget.
    func testTimeToFirstChunkForAMultiSentenceFixtureIsMeasuredAndRecorded() async throws {
        guard ProcessInfo.processInfo.environment["VOCCA_RUN_REAL_SPEECH"] != nil else {
            throw XCTSkip(
                "set VOCCA_RUN_REAL_SPEECH=1 to run the TTFA benchmark — CI has no speech "
                    + "rendering environment")
        }

        let synth = SystemSynthesizer(voiceIdentifier: nil)
        let fixture = Self.fixtures()[0]

        let clock = ContinuousClock()
        var iterator = synth.speak(fixture.text).makeAsyncIterator()
        let start = clock.now
        let first = try await iterator.next()
        let ttfa = start.duration(to: clock.now)
        let milliseconds = ttfa / .milliseconds(1)

        print(
            "SPEECH-TTFA\t\(String(format: "%.1f", milliseconds))ms\tfixture=\(fixture.name)"
                + "\tbudget=300ms\trecorded-never-gated")

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