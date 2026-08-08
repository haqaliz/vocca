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

/// The ASR seam: the protocol `ARCHITECTURE.md:219-229` specifies, as code, with the batch
/// streaming default and the empty-buffer policy pinned.
///
/// Where ``ASRVocabularyTests`` pinned *shape*, this suite pins *behaviour* — but behaviour of the
/// only engine a test can ever run, ``StubEngine``. The two real engines need model files and a
/// microphone a hosted runner has neither, so everything this suite asserts is a claim about the
/// seam as the adapters will find it:
///
/// - a conformer that never mentions `stream` still satisfies the protocol, because the batch
///   default exists — the claim that makes streaming "optional-with-default" rather than a
///   promise every adapter must keep (`ARCHITECTURE.md:226-228`);
/// - a transcript is attributed to the engine that made it, and two engines with different ids
///   produce different transcripts — the C2 acceptance's identity clause
///   (`CAPABILITY_ROADMAP.md:60`) and the seed of the C3 swap test;
/// - an empty buffer is a valid answer, never an error (PRD M3);
/// - the batch default buffers its chunks and yields exactly one final transcript, so a caller
///   never branches on `supportsStreaming`;
/// - the seam is `Sendable` end to end, so transcription can run on any actor;
/// - `prepare()` is the engine's own policy: the seam states it, and the stub's counter proves
///   `transcribe` does not silently re-prepare behind the caller's back.
final class ASREngineSeamTests: XCTestCase {

    /// A stub that implements `identity`, `supportsStreaming`, `prepare()` and `transcribe(_:)` —
    /// and **not** `stream` — still satisfies the protocol.
    ///
    /// This is the optional-with-default claim in its compile-time form: the moment the batch
    /// default disappears, `StubEngine` stops conforming and this file stops building. The runtime
    /// half is the "exactly one final transcript" test; the batch default must exist *and* must
    /// behave, and no single test can fail both ways.
    func testAStubWithoutStreamStillSatisfiesTheProtocol() {
        func requireEngine(_ engine: any ASREngine) -> any ASREngine { engine }

        let stub = StubEngine.parakeet()
        let engine = requireEngine(stub)
        XCTAssertEqual(engine.identity, stub.identity)
        XCTAssertFalse(
            engine.supportsStreaming,
            """
            the stub is a batch engine and the seam tests must measure the batch default, not a \
            stream the stub implemented itself — supportsStreaming stays false until C7
            """)
    }

    /// A transcript carries the engine that produced it, and a second engine with a different `id`
    /// produces a different one.
    ///
    /// Attribution is invariant I1 and the field is non-optional, so the C3 swap test's seed is
    /// this: if the Parakeet stub's transcript ever came back credited to whisper's identity — or
    /// vice versa — the whole "which model said this?" answer downstream is a lie. The annotated
    /// binding is the same compile-time pin `ASRVocabularyTests` applies to the transcript's field:
    /// if `engine` is ever weakened, this stops compiling rather than coercing.
    func testAttributionIsTheStubsOwnIdentityAndDiffersAcrossEngines() async throws {
        let parakeet = StubEngine.parakeet()
        let whisper = StubEngine.whisper()

        let transcript = try await parakeet.transcribe(
            AudioBuffer(samples: [1, 2, 3], sampleRate: 16_000))
        let carried: EngineIdentity = transcript.engine
        XCTAssertEqual(carried, parakeet.identity)
        XCTAssertNotEqual(
            carried, whisper.identity,
            "a Parakeet transcript must not be credited to the whisper stub — the swap test's seed")

        let swapped = try await whisper.transcribe(
            AudioBuffer(samples: [1, 2, 3], sampleRate: 16_000))
        XCTAssertEqual(
            swapped.engine, whisper.identity,
            "a whisper transcript must carry the whisper identity: the C3 swap is a swap of engines, not a relabeling of transcripts")
        XCTAssertNotEqual(swapped.engine, parakeet.identity)
    }

    /// An empty buffer is a legitimate answer: a valid empty `Transcript` — `text == ""`,
    /// `audioDuration == 0` — and never an error.
    ///
    /// C1's capture path really can hand over an empty buffer (a 20 ms press captures almost
    /// nothing), so the seam's answer to it must be a *transcript*, not a failure: a caller that
    /// treats silence as an error would lose a legitimate near-silent utterance. The stub's
    /// transcription is a pure function of the samples, so `[]` → `""` is the honest empty answer
    /// rather than a special case.
    func testEmptyBufferTranscribesToAValidEmptyTranscript() async throws {
        let stub = StubEngine.parakeet()

        let transcript = try await stub.transcribe(
            AudioBuffer(samples: [], sampleRate: 16_000))

        XCTAssertEqual(transcript.text, "")
        XCTAssertEqual(transcript.audioDuration, 0)
        XCTAssertTrue(
            transcript.isFinal,
            "batch transcription always yields a final transcript, empty buffer or not")
        XCTAssertEqual(transcript.engine, stub.identity)
        XCTAssertEqual(
            transcript.missingSampleCount, 0,
            "the engine transcribed everything it was given — an empty buffer is complete, not short")
    }

    /// The batch default: three chunks in, exactly one final transcript out, whose text is the
    /// concatenated transcription.
    ///
    /// The stub never implements `stream`, so everything this test exercises is the extension. The
    /// load-bearing claim is the one a caller depends on: **no branching on `supportsStreaming`** —
    /// a batch engine's `stream` must yield one final transcript and terminate, the same shape a
    /// streaming engine's yields at the end, so the pipeline is written once.
    func testTheBatchDefaultBuffersThreeChunksIntoOneFinalTranscript() async throws {
        let stub = StubEngine.parakeet()
        let chunk1 = AudioBuffer(samples: [1, 2, 3], sampleRate: 16_000)
        let chunk2 = AudioBuffer(samples: [4], sampleRate: 16_000)
        let chunk3 = AudioBuffer(samples: [5, 6], sampleRate: 16_000)

        let chunks = AsyncStream<AudioBuffer> { continuation in
            continuation.yield(chunk1)
            continuation.yield(chunk2)
            continuation.yield(chunk3)
            continuation.finish()
        }

        var transcripts: [Transcript] = []
        for try await transcript in stub.stream(chunks) {
            transcripts.append(transcript)
        }

        // One transcript, and the loop terminating is the stream terminating: XCTest could not
        // reach the line after the loop without the stream ending.
        XCTAssertEqual(
            transcripts.count, 1,
            "the batch default must yield exactly one transcript, got \(transcripts.count)")

        let transcript = transcripts[0]
        XCTAssertTrue(
            transcript.isFinal,
            "the one transcript a batch stream yields must be final — partials are C7's promise")
        XCTAssertEqual(
            transcript.text, "1 2 3 4 5 6",
            "the merged buffer transcribes to the concatenation of its chunks' audio")

        // The plan's exact claim: the batch transcript's text equals the concatenation of what the
        // stub would transcribe chunk by chunk — computed through the stub's own public surface,
        // because the concatenation is a claim about the seam, not about the stub's internals.
        var perChunk: [String] = []
        for chunk in [chunk1, chunk2, chunk3] {
            perChunk.append(try await stub.transcribe(chunk).text)
        }
        XCTAssertEqual(
            transcript.text, perChunk.joined(separator: " "),
            "the batch default must concatenate the audio before transcribing, never drop a chunk")

        XCTAssertEqual(
            transcript.engine, stub.identity,
            "the batch default must attribute the merged transcript to the engine that made it")
        XCTAssertEqual(
            transcript.audioDuration, 6.0 / 16_000,
            "the merged buffer is six samples at 16 kHz — the duration must describe the whole utterance, not the last chunk")
        XCTAssertEqual(transcript.missingSampleCount, 0)
    }

    /// The seam crosses actor boundaries: the stub's transcript survives a `Task.detached` round
    /// trip.
    ///
    /// `ASREngine` is `Sendable` and `Transcript` is `Sendable` because transcription runs wherever
    /// the engine's actor runs and the answer comes back to the session and the widget. An actor
    /// double makes the crossing honest — there is no `@unchecked` to smuggle a race through — and
    /// the detached task is the boundary itself: this is exactly how the app will call the engine.
    func testTheStubAndItsTranscriptCrossActorBoundaries() async throws {
        let stub = StubEngine.parakeet()
        let buffer = AudioBuffer(samples: [7, 8], sampleRate: 16_000)

        let transcript = try await Task.detached {
            try await stub.transcribe(buffer)
        }.value

        XCTAssertEqual(transcript.text, "7 8")
        XCTAssertEqual(transcript.engine, stub.identity)
        XCTAssertEqual(transcript.audioDuration, 2.0 / 16_000)
    }

    /// `prepare()` is the engine's policy: the seam documents it and does not enforce it, and
    /// `transcribe` must not silently re-prepare behind the caller's back.
    ///
    /// The documented shape (`ARCHITECTURE.md:223`) is that an engine *may* require a prepared
    /// model — Parakeet's is that its model is loaded — and that the seam never calls `prepare`
    /// on a caller's behalf, because it cannot know when the caller wanted the warm-start cost paid.
    /// The stub's counter pins the seam's half of that: a `transcribe` that implicitly ran
    /// `prepare` again would be an engine that decides the policy, and this test would see it.
    func testTranscribeDoesNotImplicitlyPrepare() async throws {
        let stub = StubEngine.parakeet()

        try await stub.prepare()
        try await stub.prepare()
        let preparedTwice = await stub.prepareCount
        XCTAssertEqual(preparedTwice, 2)

        _ = try await stub.transcribe(AudioBuffer(samples: [1], sampleRate: 16_000))

        let afterTranscribe = await stub.prepareCount
        XCTAssertEqual(
            afterTranscribe, preparedTwice,
            """
            transcribe must not implicitly re-prepare: the engine owns the prepare policy, and a \
            seam that ran prepare behind the caller's back would make every warm-start cost \
            unpayable twice
            """)
    }
}
