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
import VoccaCore
import XCTest

/// The C3 swap pinned the way the seam promises it (`CAPABILITY_ROADMAP.md:81`,
/// `ARCHITECTURE.md:219-229`): a caller drives `any ASREngine` — `transcribe` here, the batch
/// `stream` default there — and at the session boundary the engine may change while **nothing
/// else does**. Two stub engines with identical behavior and different identities stand in for
/// the two shipped engines; the tests assert the swap's only observable difference above the
/// seam is `Transcript.engine`, and the test source contains no engine-specific branch — the
/// parameterization itself is the proof. No model, no network, ever.
final class EngineSwapTests: XCTestCase {

    /// One session's transcription, driven through `any ASREngine` — the caller-shaped view of
    /// the seam. It names no engine and branches on none; the same body runs whichever engine
    /// the caller hands it.
    private func runSession(
        _ engine: any ASREngine, audio: AudioBuffer
    ) async throws -> Transcript {
        try await engine.transcribe(audio)
    }

    /// The mid-session-boundary swap: fixture A transcribed by engine 1, then — after the
    /// boundary — by engine 2. Above the seam, only `engine` differs: same text, same segments,
    /// same finality, same duration, same completeness count, each transcript attributed to the
    /// engine that produced it.
    func testTheSessionBoundarySwapChangesOnlyTheEngineIdentity() async throws {
        let fixtures = try ASRFixtureSuite.loadFixtures()
        let audio = fixtures[0].buffer

        // Two engines with identical behavior and different identities — the swap shape.
        let engineOne: any ASREngine = StubEngine.parakeet()
        let engineTwo: any ASREngine = StubEngine.whisper()

        let first = try await runSession(engineOne, audio: audio)
        let second = try await runSession(engineTwo, audio: audio)

        XCTAssertEqual(
            first.text, second.text,
            "the swap must not change the transcript text")
        XCTAssertEqual(
            first.segments, second.segments,
            "the swap must not change the segments")
        XCTAssertEqual(first.isFinal, second.isFinal)
        XCTAssertEqual(first.audioDuration, second.audioDuration)
        XCTAssertEqual(first.missingSampleCount, second.missingSampleCount)
        XCTAssertEqual(
            first.engine, engineOne.identity,
            "the first session's transcript must carry engine 1's identity")
        XCTAssertEqual(
            second.engine, engineTwo.identity,
            "the second session's transcript must carry engine 2's identity")
        XCTAssertNotEqual(
            first.engine, second.engine,
            "the two engines' identities must differ, or attribution is a lie")
    }

    /// The same swap through the stream form: the batch default yields exactly one final
    /// transcript carrying the second engine's identity — a caller written against `stream`
    /// observes the same swap as one written against `transcribe`, with no branch on
    /// `supportsStreaming` anywhere in it.
    func testTheStreamDefaultAfterTheSwapYieldsOneFinalTranscriptFromTheSecondEngine() async throws {
        let fixtures = try ASRFixtureSuite.loadFixtures()
        let audio = fixtures[0].buffer
        let engineOne: any ASREngine = StubEngine.parakeet()
        let engineTwo: any ASREngine = StubEngine.whisper()

        let first = try await runSession(engineOne, audio: audio)

        var transcripts: [Transcript] = []
        for try await transcript in engineTwo.stream(streamOf([audio])) {
            transcripts.append(transcript)
        }

        XCTAssertEqual(
            transcripts.count, 1,
            "the batch default must yield exactly one transcript")
        XCTAssertTrue(
            transcripts[0].isFinal,
            "the batch default's transcript must be final")
        XCTAssertEqual(
            transcripts[0].text, first.text,
            "the stream must transcribe the same audio to the same text")
        XCTAssertEqual(transcripts[0].segments, first.segments)
        XCTAssertEqual(
            transcripts[0].engine, engineTwo.identity,
            "after the swap, the stream's transcript must carry engine 2's identity")
    }

    /// The chunk producer: an `AsyncStream` of one buffer — the smallest stream a caller can
    /// send, and enough for the batch default to answer with a single final transcript.
    private func streamOf(_ chunks: [AudioBuffer]) -> AsyncStream<AudioBuffer> {
        AsyncStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
