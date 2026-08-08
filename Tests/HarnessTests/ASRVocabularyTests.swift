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

/// The ASR vocabulary: the types `ARCHITECTURE.md` §4 names, as code, in `VoccaCore`.
///
/// This is the first phase of the `asr-seam` aspect, and like ``SessionVocabularyTests`` it tests
/// *shape* — there is no engine and no audio pipeline yet, so nothing here can test behaviour. The
/// shape is load-bearing for different reasons than the session's was:
///
/// - the seam is pluggable, so the vocabulary has to be implementable by any adapter — no system
///   framework may be needed to build a `Transcript`;
/// - attribution is invariant I1, so `Transcript.engine` is non-optional and this suite pins it at
///   compile time;
/// - the completeness link (I1) means a transcript that is missing samples must say so, so
///   `missingSampleCount` defaults to 0 and this suite pins what 0 means.
final class ASRVocabularyTests: XCTestCase {

    // MARK: - EngineIdentity

    /// The identity round-trips its three fields, and `id` — not `displayName` — distinguishes
    /// engines.
    ///
    /// `displayName` is for humans and can collide; `id` is the machine's key. Two engines that
    /// share a display name (both called "Whisper", say) must still be different values, because
    /// ``Transcript`` carries the identity and downstream code will match on it.
    func testEngineIdentityRoundTripsItsFieldsAndDistinguishesEngines() {
        let parakeet = EngineIdentity(
            id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", isLocal: true)
        XCTAssertEqual(parakeet.id, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(parakeet.displayName, "Parakeet TDT 0.6B v3")
        XCTAssertTrue(parakeet.isLocal, "the egress-badge flag must be carried, not dropped")

        // The `id` is what distinguishes engines: same display name, different id — not equal.
        let renamed = EngineIdentity(
            id: "whisper-large-v3-turbo", displayName: "Parakeet TDT 0.6B v3", isLocal: true)
        XCTAssertNotEqual(parakeet, renamed)
        XCTAssertEqual(Set([parakeet, renamed]).count, 2)

        // And `isLocal` distinguishes the same model hosted vs on-device: `false` mandates the
        // egress badge, so a hosted identity must not compare equal to the local one.
        let hosted = EngineIdentity(
            id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", isLocal: false)
        XCTAssertNotEqual(parakeet, hosted)
        XCTAssertEqual(Set([parakeet, hosted]).count, 2)
    }

    /// The identity works as a dictionary key and survives a Codable round trip.
    ///
    /// Both are forward contracts, not conveniences: the model store will key its directory by
    /// engine `id` (C8), and a persisted settings/profile file will decode identities back (C14).
    /// A dictionary key that collapsed two engines together, or a round trip that dropped a field,
    /// would fail here long before either capability shipped.
    func testEngineIdentityIsHashableAndCodable() {
        let local = EngineIdentity(
            id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", isLocal: true)
        let whisper = EngineIdentity(
            id: "whisper-large-v3-turbo", displayName: "Whisper large-v3-turbo", isLocal: true)

        var byID: [String: EngineIdentity] = [:]
        byID[local.id] = local
        byID[whisper.id] = whisper
        XCTAssertEqual(byID[local.id], local)
        XCTAssertEqual(byID[whisper.id], whisper)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try! encoder.encode(local)
        let decoded = try! decoder.decode(EngineIdentity.self, from: data)
        XCTAssertEqual(decoded, local)
        XCTAssertEqual(decoded.id, local.id)
        XCTAssertEqual(decoded.displayName, local.displayName)
        XCTAssertEqual(decoded.isLocal, local.isLocal)
    }

    // MARK: - AudioBuffer

    /// The seam accepts exactly 16 kHz mono: a 16 000 Hz construction succeeds and carries its
    /// fields.
    func testAudioBufferAcceptsExactlySixteenKilohertzMono() {
        let samples: [Float] = [0.1, -0.2, 0.3]
        let buffer = AudioBuffer(samples: samples, sampleRate: 16_000)
        XCTAssertEqual(buffer.samples, samples)
        XCTAssertEqual(buffer.sampleRate, 16_000)
    }

    /// The format rule, as a pure function — because the `precondition` that enforces it cannot be
    /// caught in-process, so any predicate at all satisfied the first version of such a check.
    ///
    /// The `AudioRingBuffer.isValidCapacity` pattern, applied to the seam's format claim: the rule
    /// is testable on its own rather than only observable as a trap. Every near miss is one field
    /// away from correct and is a real regression somebody could ship — a 44.1 kHz stream resampled
    /// at the wrong stage, a stereo capture fed straight through, a zero rate from a
    /// not-yet-opened device.
    func testTheFormatPredicateRejectsEveryNearMiss() {
        let interchange = (sampleRate: 16_000, channelCount: 1)
        XCTAssertTrue(
            AudioBuffer.isValidFormat(sampleRate: interchange.sampleRate, channelCount: interchange.channelCount))

        for (rate, channels) in [
            (44_100, 1),  // CD rate, mono
            (48_000, 1),  // video rate, mono
            (16_000, 2),  // right rate, stereo
            (0, 1),  // no rate at all
        ] {
            XCTAssertFalse(
                AudioBuffer.isValidFormat(sampleRate: rate, channelCount: channels),
                """
                \(rate) Hz × \(channels) ch was accepted as the interchange format. The seam speaks \
                16 kHz mono and nothing else: an engine converts internally, never the caller, so a \
                buffer in any other format is a bug at the boundary, not a request to resample.
                """)
        }
    }

    /// The duration is the sample count over the rate — 16 kHz, so 16 000 samples is exactly one
    /// second.
    func testAudioDurationIsTheSampleCountOverSixteenThousand() {
        let oneSecond = AudioBuffer(
            samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
        XCTAssertEqual(oneSecond.audioDuration, 1.0)

        let halfSecond = AudioBuffer(
            samples: [Float](repeating: 0, count: 8_000), sampleRate: 16_000)
        XCTAssertEqual(halfSecond.audioDuration, 0.5)

        let empty = AudioBuffer(samples: [], sampleRate: 16_000)
        XCTAssertEqual(empty.audioDuration, 0)
    }

    // MARK: - Transcript

    /// The transcript requires an engine, and carries it — pinned at compile time, because the
    /// point of the non-optional field is that mis-attribution is *structurally* impossible.
    func testTranscriptRequiresAndCarriesItsEngine() {
        let engine = EngineIdentity(
            id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", isLocal: true)
        let transcript = Transcript(
            text: "hello world",
            segments: [],
            engine: engine,
            isFinal: true,
            audioDuration: 0.75)

        // An annotated binding, not `XCTAssertEqual`: if `engine` ever becomes optional, the
        // `EngineIdentity` annotation fails to compile — the same pin SessionVocabularyTests applies
        // to the custody payload. Assertion alone would coerce and pass.
        let carriedEngine: EngineIdentity = transcript.engine
        XCTAssertEqual(carriedEngine, engine)
    }

    /// The transcript carries its text, segments, finality and duration, and the completeness
    /// count defaults to 0 — which is pinned as *"0 means complete"*.
    ///
    /// The default is deliberate and documented, and it is the honest default: an engine that
    /// transcribed everything it was given has nothing missing to report, and requiring a call site
    /// to spell `missingSampleCount: 0` would make the lie *more* likely by making "complete" look
    /// like an afterthought. What the default must never become is a way to skip the count for
    /// audio that was actually short — the count is an explicit, named parameter, and the C1→C2
    /// bridge (phase 3) is what sets it from the ring's `refusedSampleCount`.
    func testTranscriptCarriesItsFieldsAndDefaultsToComplete() {
        let engine = EngineIdentity(
            id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", isLocal: true)
        let segment = TranscriptSegment(text: "hello", range: 0.0..<0.75, confidence: 0.9)
        let transcript = Transcript(
            text: "hello",
            segments: [segment],
            engine: engine,
            isFinal: true,
            audioDuration: 0.75)

        XCTAssertEqual(transcript.text, "hello")
        XCTAssertEqual(transcript.segments, [segment])
        XCTAssertEqual(transcript.isFinal, true)
        XCTAssertEqual(transcript.audioDuration, 0.75)
        XCTAssertEqual(
            transcript.missingSampleCount, 0,
            "a transcript constructed without a completeness count must read as complete")

        let short = Transcript(
            text: "hello",
            segments: [],
            engine: engine,
            isFinal: true,
            audioDuration: 0.75,
            missingSampleCount: 7)
        XCTAssertEqual(
            short.missingSampleCount, 7,
            "the count must be explicit and carried: short audio says how short, it never defaults")
    }

    /// A segment carries its text, its range, and its confidence — nil being the "engine exposes
    /// none" signal, not an omission.
    func testTranscriptSegmentCarriesTextRangeAndConfidence() {
        let confident = TranscriptSegment(text: "hello", range: 0.0..<0.5, confidence: 0.95)
        XCTAssertEqual(confident.text, "hello")
        XCTAssertEqual(confident.range, 0.0..<0.5)
        XCTAssertEqual(confident.confidence, 0.95)

        let none = TranscriptSegment(text: "world", range: 0.5..<1.0, confidence: nil)
        XCTAssertNil(
            none.confidence,
            """
            nil must mean 'the engine exposes no confidence', which is a fact about the engine — \
            not a missing value a caller should paper over with a fabricated number
            """)
    }

    // MARK: - VoccaError

    /// Both error cases carry the engine identity, because an error that cannot be attributed is an
    /// error that cannot be acted on — "which engine is unavailable?" is the same question as
    /// "which download do I offer?".
    ///
    /// Pattern-matched, not compared: the payload includes an `Error`, and forcing `Equatable` on
    /// it would throw away the very thing being carried.
    func testVoccaErrorCarriesTheEngineIdentityInBothCases() {
        let engine = EngineIdentity(
            id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", isLocal: true)

        let unavailable = VoccaError.modelUnavailable(engine, reason: "not downloaded")
        if case .modelUnavailable(let carried, let reason) = unavailable {
            XCTAssertEqual(carried, engine)
            XCTAssertEqual(reason, "not downloaded")
        } else {
            XCTFail("modelUnavailable did not carry (engine, reason): \(unavailable)")
        }

        let underlying = SentinelUnderlyingError(code: 42)
        let failed = VoccaError.transcriptionFailed(engine, underlying: underlying)
        if case .transcriptionFailed(let carried, let error) = failed {
            XCTAssertEqual(carried, engine)
            XCTAssertTrue(
                error as AnyObject === underlying,
                "transcriptionFailed must carry the underlying error itself, not a string of it")
        } else {
            XCTFail("transcriptionFailed did not carry (engine, underlying): \(failed)")
        }
    }

    // MARK: - Sendable

    /// Compile-time, not runtime: `requireSendable` constrains its parameter to `Sendable`, so a
    /// type that loses the conformance fails to build this file rather than failing an assertion.
    ///
    /// These types cross actor boundaries on every path: the engine's transcription runs wherever
    /// the engine's actor runs, and the transcript comes back to the session and the widget.
    func testTheASRVocabularyIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        let engine = EngineIdentity(
            id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", isLocal: true)
        XCTAssertEqual(requireSendable(engine), engine)
        XCTAssertEqual(requireSendable(AudioBuffer(samples: [], sampleRate: 16_000)), AudioBuffer(samples: [], sampleRate: 16_000))
        XCTAssertEqual(
            requireSendable(TranscriptSegment(text: "", range: 0.0..<0.0, confidence: nil)),
            TranscriptSegment(text: "", range: 0.0..<0.0, confidence: nil))
        XCTAssertEqual(
            requireSendable(Transcript(text: "", segments: [], engine: engine, isFinal: true, audioDuration: 0)),
            Transcript(text: "", segments: [], engine: engine, isFinal: true, audioDuration: 0))
        _ = requireSendable(VoccaError.modelUnavailable(engine, reason: ""))
        _ = requireSendable(VoccaError.transcriptionFailed(engine, underlying: SentinelUnderlyingError(code: 1)))
    }
}

/// A class so that the "same instance, carried intact" claim is checkable with `===`.
private final class SentinelUnderlyingError: Error {
    let code: Int
    init(code: Int) {
        self.code = code
    }
}
