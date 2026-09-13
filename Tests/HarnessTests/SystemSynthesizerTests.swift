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

import AVFAudio
import VoccaCore
import XCTest
@testable import VoccaSpeech

/// The system synthesizer's headless pins (`system-synthesizer/spec.md` R3) — the first half of
/// the adapter's acceptance, written before the adapter exists.
///
/// Everything here that can run without a renderer does: the buffer→chunk conversion over
/// constructed `AVAudioPCMBuffer`s, the chunker→utterance mapping over the pure half, and the
/// identity. The one leg that needs a real `AVSpeechSynthesizer` — cancel over a minimal real
/// invocation — is env-gated on `VOCCA_RUN_REAL_SPEECH=1`, the C3 real-engine pattern: CI cannot
/// render speech reliably, so CI runs the skip path and the founder's machine runs the leg.
final class SystemSynthesizerTests: XCTestCase {

    // MARK: - Buffer conversion

    /// A constructed `AVAudioPCMBuffer` with known frames/rate/channels converts to an
    /// ``AudioChunk`` whose duration is frames ÷ rate and whose bytes are the buffer's frame
    /// data, read raw.
    ///
    /// The conversion is the adapter's hand-over to the seam: the chunk's `sampleRate` and
    /// `channelCount` come from the buffer's format, the payload is the PCM bytes, and the
    /// duration is the producer's own frames ÷ rate arithmetic — the "is this plausible audio?"
    /// check the seam reads.
    func testAudioChunkConversionReadsFramesRateChannelsAndPayload() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 2,
                interleaved: true))
        let frames: AVAudioFrameCount = 8_000
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let sampleCount = Int(frames) * 2
        let samples = (0..<sampleCount).map { Int16(truncatingIfNeeded: $0 * 7) }
        samples.withUnsafeBufferPointer { raw in
            buffer.int16ChannelData?.pointee.update(from: raw.baseAddress!, count: raw.count)
        }

        let chunk = try XCTUnwrap(SystemSynthesizer.audioChunk(from: buffer))

        XCTAssertEqual(chunk.sampleRate, 16_000, "the chunk names the rate the buffer was rendered at")
        XCTAssertEqual(chunk.channelCount, 2, "the chunk names the channels the buffer was rendered with")
        XCTAssertEqual(
            chunk.duration, Double(frames) / 16_000, accuracy: 1e-9,
            "duration is frames ÷ rate, computed by the producer")
        let expectedBytes = samples.withUnsafeBytes { Array($0) }
        XCTAssertEqual(
            chunk.bytes, expectedBytes,
            "the chunk's payload is the buffer's frame data, read raw — every sample, in order")
    }

    /// A zero-length buffer — the `write(toBufferCallback:)` end-of-utterance signal — produces
    /// no chunk. Dropped, never rendered (pinned).
    func testZeroLengthBufferIsDroppedNotRendered() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        buffer.frameLength = 0

        XCTAssertNil(
            SystemSynthesizer.audioChunk(from: buffer),
            "the zero-length buffer is the callback's completion signal — it must never become a chunk")
    }

    // MARK: - Chunker → utterance mapping (the pure half)

    /// The adapter feeds the chunker's sentences as one utterance each — the mapping over the
    /// pure half, where the decisions live.
    func testChunkerSentencesBecomeTheUtteranceList() {
        let text = "The quick brown fox jumps over the lazy dog. Then it rests. Finally it sleeps."

        XCTAssertEqual(
            SystemSynthesizer.utteranceTexts(for: text),
            ["The quick brown fox jumps over the lazy dog.", "Then it rests.", "Finally it sleeps."],
            "one utterance per sentence chunk, in chunker order")
        XCTAssertEqual(
            SystemSynthesizer.utteranceTexts(for: text),
            SentenceChunker.sentenceChunks(of: text),
            "the adapter's utterance list is exactly the chunker's sentence list — no re-splitting, no reordering")
        XCTAssertTrue(
            SystemSynthesizer.utteranceTexts(for: "").isEmpty,
            "empty text feeds no utterances — the seam's empty-stream policy starts here")
    }

    /// The utterance a sentence maps to carries the configured voice and rate as plain data
    /// inputs — the N1 knobs the follow-on UI will turn.
    func testAnUtteranceCarriesTheConfiguredVoiceAndRateAsData() throws {
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        let synth = SystemSynthesizer(voiceIdentifier: voice.identifier, rate: 0.3)

        let utterance = synth.makeUtterance(for: "Hello there.")

        XCTAssertEqual(
            utterance.voice?.identifier, voice.identifier,
            "the utterance speaks with the configured system voice")
        XCTAssertEqual(
            utterance.rate, 0.3, accuracy: 0.0001,
            "the utterance speaks at the configured rate")
        XCTAssertEqual(
            utterance.speechString, "Hello there.",
            "the utterance carries exactly its sentence's text")
    }

    // MARK: - Identity

    /// `identity` = `engineID: "system"` with the configured system voice's identifier as the
    /// voice name — nil when no voice was configured.
    func testIdentityNamesTheSystemEngineAndTheConfiguredVoice() {
        let configured = "com.apple.voice.compact.en-US.Samantha"
        let synth = SystemSynthesizer(voiceIdentifier: configured)

        XCTAssertEqual(
            synth.identity.engineID, "system",
            "the system synthesizer's engine key is \"system\" — the engine the chunks came from")
        XCTAssertEqual(
            synth.identity.voiceName, configured,
            "the voice name is the configured system voice's identifier")
        XCTAssertEqual(
            synth.identity, VoiceIdentity(engineID: "system", voiceName: configured),
            "the identity is the whole value downstream attribution matches on")

        let unconfigured = SystemSynthesizer(voiceIdentifier: nil)
        XCTAssertEqual(unconfigured.identity.engineID, "system")
        XCTAssertNil(
            unconfigured.identity.voiceName,
            "a synthesizer without a configured voice carries voiceName == nil, never a sentinel")
    }

    // MARK: - Cancel over a real invocation (env-gated)

    /// Cancel over a minimal real invocation, where the environment allows: speak a short
    /// fixture, cancel mid-stream, assert prompt termination and a safe immediate re-invoke.
    ///
    /// This is the adapter's one leg that needs a renderer, so it is env-gated exactly like the
    /// C3 real-engine tests: CI runs the skip path, the founder's machine runs the leg.
    ///
    /// The fixture's first sentence is short and its tail long: the system renderer runs far
    /// ahead of its consumer (measured 2026-09-13 — it renders an ~8 s utterance in ~0.4 s wall),
    /// so the cancel must land at a sentence boundary the consumer can reach inside the
    /// renderer's slack. The short first sentence yields the first chunk quickly; the long tail
    /// keeps the renderer busy while the consumer cancels — which is what makes
    /// "no chunk after cancel()" a measurement rather than a scheduling race.
    func testCancelOverARealInvocationHaltsPromptlyAndReinvokeIsSafe() async throws {
        guard ProcessInfo.processInfo.environment["VOCCA_RUN_REAL_SPEECH"] != nil else {
            throw XCTSkip(
                "set VOCCA_RUN_REAL_SPEECH=1 to run the real-invocation cancel pin — CI has no "
                    + "speech rendering environment")
        }

        let synth = SystemSynthesizer(voiceIdentifier: nil)
        var iterator = synth.speak(
            "Hello there. The quick brown fox jumps over the lazy dog, and then it rests under "
                + "the old oak tree. Finally it sleeps until the morning light arrives."
        ).makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertNotNil(first, "the stream must yield its first chunk before the cancel leg")

        let clock = ContinuousClock()
        let start = clock.now
        await synth.cancel()
        let afterCancel = try await iterator.next()
        let elapsed = start.duration(to: clock.now)

        XCTAssertNil(
            afterCancel,
            "no chunk may arrive after cancel() — the stream must terminate at the cancel, not one more chunk later")
        XCTAssertLessThanOrEqual(
            elapsed, .milliseconds(50),
            "cancel must halt output within 50 ms, got \(elapsed)")

        var received: [AudioChunk] = []
        for try await chunk in synth.speak("Hello there.") {
            received.append(chunk)
        }
        XCTAssertFalse(
            received.isEmpty,
            "the re-invoked speak must render — a deadlocked or half-cancelled session renders nothing")
        XCTAssertGreaterThan(
            received.reduce(0, { $0 + $1.duration }), 0,
            "the re-invoked render carries audio, not an empty stream")
    }
}