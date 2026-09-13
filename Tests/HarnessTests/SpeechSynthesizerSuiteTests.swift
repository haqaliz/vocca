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
import XCTest

/// The parameterized speech suite over the only synthesizer CI can run:
/// ``SpeechSynthesizerSeamTests/StubSynthesizer`` (`speech-seam/spec.md` R4).
///
/// One body — ``SpeechFixtureSuite/evaluate(_:fixtures:)`` — measures every leg the seam
/// promises, and this suite asserts them against ground truth written by hand: the stub's
/// script is a fixture's plausible render, so the assertions here are the same ones the second
/// aspect will run env-gated over a real engine (minus the script-equality half, which only a
/// stub can satisfy).
final class SpeechSynthesizerSuiteTests: XCTestCase {

    /// The fixture script: 1.5 s of PCM across three chunks — a plausible render of a ~3-4 s
    /// utterance's floor, distinct durations so order is observable.
    private static func script() -> [AudioChunk] {
        [
            AudioChunk(bytes: [0x00], sampleRate: 16_000, channelCount: 1, duration: 0.5),
            AudioChunk(bytes: [0x01], sampleRate: 16_000, channelCount: 1, duration: 0.6),
            AudioChunk(bytes: [0x02], sampleRate: 16_000, channelCount: 1, duration: 0.4),
        ]
    }

    /// The stub renders every fixture's text with plausible duration, in script order; the
    /// cancel leg stays within the 50 ms budget with nothing after the cancel; and the
    /// re-invoked render is complete.
    ///
    /// Each leg's assertion is the suite's promise to the seam: a `SpeechSynthesizer` that
    /// truncates, reorders, leaks past cancel, or deadlocks on re-invoke fails here first —
    /// over the deterministic stub, where the failure is reproducible, rather than over a real
    /// engine where it would be timing's.
    func testTheStubRendersEveryFixtureWithPlausibleDurationOrderCancelAndReinvoke() async throws {
        let script = Self.script()
        let stub = StubSynthesizer(
            identity: VoiceIdentity(engineID: "kokoro-82m", voiceName: "af_heart"),
            chunks: script,
            yieldDelay: .milliseconds(10))
        let fixtures = [
            SpeechFixtureCase(
                name: "three-sentence-reply",
                text: "The quick brown fox jumps over the lazy dog. Then it rests. Finally it sleeps.",
                minimumDuration: 1.0),
            SpeechFixtureCase(
                name: "short-reply",
                text: "Hello there.",
                minimumDuration: 0.25),
        ]

        let results = try await SpeechFixtureSuite.evaluate(stub, fixtures: fixtures)

        XCTAssertEqual(
            results.map(\.name), ["three-sentence-reply", "short-reply"],
            "every fixture runs, in order — a suite that skips a fixture reads green while a leg goes unmeasured")
        for result in results {
            XCTAssertGreaterThanOrEqual(
                result.renderedDuration, fixtures.first { $0.name == result.name }!.minimumDuration,
                "fixture \(result.name): a known utterance must render at least its pinned duration floor of PCM — less is truncation")
            XCTAssertGreaterThanOrEqual(
                result.chunkCount, 1,
                "fixture \(result.name): the render must be non-empty audio, not a silent stream")
            XCTAssertEqual(
                result.chunkDurations, script.map(\.duration),
                "fixture \(result.name): the chunks arrive in script order — the sentence-order claim of the seam")
            XCTAssertLessThanOrEqual(
                result.cancelLatency, .milliseconds(50),
                "fixture \(result.name): cancel must halt output within 50 ms, got \(result.cancelLatency)")
            XCTAssertEqual(
                result.reinvokedChunkCount, script.count,
                "fixture \(result.name): the re-invoked speak must render the full script — no deadlock, no resumed half-session")
            XCTAssertEqual(
                result.reinvokedDuration, 1.5,
                "fixture \(result.name): the re-invoked render's audio sums to the script's duration")
        }
    }
}