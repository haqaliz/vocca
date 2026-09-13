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

/// The speech fixture suite's machinery: fixtures in, per-synthesizer legs out — one harness,
/// run parameterized over every `SpeechSynthesizer` (`speech-seam/spec.md` R4, the C3
/// `ASRFixtureSuite` shape).
///
/// Everything here runs headlessly: the fixtures are plain text with a pinned duration floor,
/// and the synthesizer under test is a test double in the harness tests. The real-engine half
/// (the second aspect) drives the same function with a real synthesizer env-gated.
struct SpeechFixtureCase: Sendable {
    /// The fixture's base name — `three-sentence-reply`, `short-reply`, …
    let name: String
    /// The text the synthesizer is asked to render — a known utterance, written naturally.
    let text: String
    /// The floor of plausible rendered audio: the fixture's utterance must render at least this
    /// many seconds of PCM (the sum of the chunk durations), which catches truncation without
    /// flaking on engine timing.
    let minimumDuration: Double
}

/// One synthesizer's measured legs on one fixture.
struct SpeechFixtureResult: Sendable {
    let name: String
    /// Sum of the chunk durations of the first render, in seconds.
    let renderedDuration: Double
    /// How many chunks the first render yielded.
    let chunkCount: Int
    /// The chunk durations in arrival order.
    let chunkDurations: [Double]
    /// Wall-clock from `cancel()` completing to the stream terminating.
    let cancelLatency: Duration
    /// How many chunks the re-invoked render yielded.
    let reinvokedChunkCount: Int
    /// Sum of the chunk durations of the re-invoked render, in seconds.
    let reinvokedDuration: Double
}

enum SpeechFixtureSuite {

    /// Runs one synthesizer over the fixtures and measures every leg the seam promises
    /// (`spec.md` R4): non-empty audio of pinned plausible duration, chunks in arrival order,
    /// the cancel leg (≤50 ms wall-clock from `cancel()` to stream termination) and the
    /// re-invoke leg (a second `speak` after the cancel renders fully).
    ///
    /// The body measures and records; the assertions live in the tests, where the ground truth
    /// (the stub's script, or a real engine's expectations) is written by hand rather than
    /// read back from the synthesizer.
    static func evaluate(
        _ synth: any SpeechSynthesizer, fixtures: [SpeechFixtureCase]
    ) async throws -> [SpeechFixtureResult] {
        var results: [SpeechFixtureResult] = []
        let clock = ContinuousClock()
        for fixture in fixtures {
            var chunkDurations: [Double] = []
            for try await chunk in synth.speak(fixture.text) {
                chunkDurations.append(chunk.duration)
            }

            var iterator = synth.speak(fixture.text).makeAsyncIterator()
            _ = try await iterator.next()
            let start = clock.now
            await synth.cancel()
            let afterCancel = try await iterator.next()
            let cancelLatency = start.duration(to: clock.now)
            guard afterCancel == nil else {
                throw SpeechFixtureSuiteError.chunkAfterCancel(
                    fixture: fixture.name, latency: cancelLatency)
            }

            var reinvokedCount = 0
            var reinvokedDuration = 0.0
            for try await chunk in synth.speak(fixture.text) {
                reinvokedCount += 1
                reinvokedDuration += chunk.duration
            }

            results.append(
                SpeechFixtureResult(
                    name: fixture.name,
                    renderedDuration: chunkDurations.reduce(0, +),
                    chunkCount: chunkDurations.count,
                    chunkDurations: chunkDurations,
                    cancelLatency: cancelLatency,
                    reinvokedChunkCount: reinvokedCount,
                    reinvokedDuration: reinvokedDuration))
        }
        return results
    }

    private enum SpeechFixtureSuiteError: Error, CustomStringConvertible {
        case chunkAfterCancel(fixture: String, latency: Duration)

        var description: String {
            switch self {
            case .chunkAfterCancel(let fixture, let latency):
                return "fixture \(fixture): a chunk arrived after cancel() (latency \(latency)) — a barge-in that leaks the tail of the utterance"
            }
        }
    }
}