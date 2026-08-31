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

@testable import VoccaASR
import VoccaCore
import XCTest

/// The Parakeet engine's testable core (`parakeet-engine` plan Phase 2): every decision the
/// adapter contains, headless, with **no FluidAudio name in sight** — the mapping rules, the
/// load-once state, the timing recorder, and the identity constant.
///
/// The adapter file (`ParakeetEngine.swift`) is thin glue that CI never executes; everything it
/// *decides* is this suite, runnable forever on a plain runner.
final class ParakeetCoreTests: XCTestCase {

    private let identity = EngineIdentity(
        id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", isLocal: true)

    private func buffer(_ samples: [Float] = [1, 2, 3]) -> AudioBuffer {
        AudioBuffer(samples: samples, sampleRate: 16_000)
    }

    // MARK: - Identity

    /// The identity constant carries the three fields with `isLocal == true` — no egress badge
    /// (`ARCHITECTURE.md:152-156`), and the directory key matches the model store's engineID.
    func testTheIdentityConstantCarriesItsFieldsAndIsLocal() {
        XCTAssertEqual(ParakeetEngineIdentity.parakeet.id, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(ParakeetEngineIdentity.parakeet.displayName, "Parakeet TDT 0.6B v3")
        XCTAssertTrue(ParakeetEngineIdentity.parakeet.isLocal)
    }

    // MARK: - Mapper

    /// The mapping: text + buffer + identity → Transcript with the identity, one segment
    /// spanning the whole utterance, duration from the buffer — never from the text.
    func testTheMapperProducesOneSegmentedTranscriptAttributedToTheEngine() {
        let transcript = ParakeetTranscriptMapper.transcript(
            text: "hello world", for: buffer(), engine: identity)

        XCTAssertEqual(transcript.text, "hello world")
        XCTAssertEqual(transcript.engine, identity)
        XCTAssertEqual(
            transcript.audioDuration, 3.0 / 16_000,
            "the duration must come from the buffer's samples, not the text")
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].text, "hello world")
        XCTAssertEqual(
            transcript.segments[0].range, 0..<(3.0 / 16_000),
            "the single segment must span the whole utterance")
        XCTAssertNil(
            transcript.segments[0].confidence,
            "the batch result exposes no confidence — nil is the 'engine exposes none' signal")
        XCTAssertTrue(transcript.isFinal, "batch transcription is always final")
        XCTAssertEqual(
            transcript.missingSampleCount, 0,
            "the mapper defaults to complete; the bridge's count overrides it")
    }

    /// The sub-minimum guard: FluidAudio's transcribe guard refuses anything shorter than
    /// 0.3 s (4 800 samples at 16 kHz) with `ASRError.invalidAudioData`, so the adapter answers
    /// empty above it instead of letting that throw reach the user as "Voice processing failed".
    ///
    /// The boundary is asserted at concrete sample counts rather than against the SDK constant
    /// the implementation reads, so that a change in the SDK's own guard fails here loudly rather
    /// than being silently tracked — the numbers below were measured against the real engine
    /// (4 799 threw, 4 800 transcribed), not read off the header.
    func testTheSDKMinimumGuardMatchesTheMeasuredBoundary() {
        XCTAssertTrue(
            ParakeetEngine.isBelowSDKMinimum(buffer([])),
            "the empty buffer is below the minimum, as it always was")
        XCTAssertTrue(
            ParakeetEngine.isBelowSDKMinimum(buffer(Array(repeating: 0.1, count: 320))),
            "a 20 ms press — the seam contract's own worked example — is 320 samples, not zero")
        XCTAssertTrue(
            ParakeetEngine.isBelowSDKMinimum(buffer(Array(repeating: 0.1, count: 4_799))),
            "4 799 samples is the last count the SDK refuses")
        XCTAssertFalse(
            ParakeetEngine.isBelowSDKMinimum(buffer(Array(repeating: 0.1, count: 4_800))),
            "4 800 samples (0.3 s) is the first count the SDK accepts — never answer empty here")
        XCTAssertFalse(
            ParakeetEngine.isBelowSDKMinimum(buffer(Array(repeating: 0.1, count: 32_000))),
            "ordinary speech-length audio is never short-circuited")
    }

    /// Empty text — the SDK's answer to near-silent audio — maps to a valid empty transcript,
    /// never an error (PRD M3's policy, kept above the SDK).
    func testTheMapperTurnsEmptyTextIntoAValidEmptyTranscript() {
        let transcript = ParakeetTranscriptMapper.transcript(
            text: "", for: buffer([]), engine: identity)

        XCTAssertEqual(transcript.text, "")
        XCTAssertEqual(transcript.audioDuration, 0)
        XCTAssertEqual(transcript.engine, identity)
        XCTAssertTrue(transcript.isFinal)
    }

    /// The completeness count is carried, never dropped — the I1 link the bridge (asr-seam
    /// Phase 3) feeds through the buffer.
    func testTheMapperCarriesTheMissingSampleCount() {
        let transcript = ParakeetTranscriptMapper.transcript(
            text: "hi", for: buffer(), engine: identity, missingSampleCount: 42)
        XCTAssertEqual(transcript.missingSampleCount, 42)
    }

    // MARK: - Streaming surface

    /// The engine reports streaming support — the seam's promise (`ASREngine.swift:51-54`) is
    /// that a conformer with `supportsStreaming == true` implements `stream(_:)` itself, and the
    /// pipeline never branches on the flag: the flag is the adapter's contract with the route,
    /// `true` since the sliding-window streaming adapter landed.
    ///
    /// Construction is headless and performs no network — a stub store over a temp root, an
    /// unused transport base URL (never reached), the shipped manifest, the offline flag set in
    /// `init` — exactly the `ParakeetEngineWERTests` construction minus the model.
    func testTheEngineReportsStreamingSupport() throws {
        let manifestURL = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaASR/Models/Manifests/parakeet-tdt-0.6b-v3.json")
        let manifest = try ModelManifest.load(from: Data(contentsOf: manifestURL))
        let engine = ParakeetEngine(
            store: ModelStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("vocca-streaming-pin-\(UUID().uuidString)")),
            manifest: manifest,
            transport: DefaultModelTransport(baseURL: URL(string: "https://unused.invalid")!),
            clock: ContinuousMonotonicClock())

        XCTAssertTrue(
            engine.supportsStreaming,
            "the Parakeet adapter streams — the seam's batch default is a batch engine's "
                + "degradation, not a streaming one's")
    }

    /// The partial form: every SDK sliding-window update — confirmed or volatile alike — maps to
    /// a provisional transcript. `isFinal == false`, no segmentation (a partial has no stable
    /// segmentation), `audioDuration == 0` (provisional by nature — the ``StreamingStubEngine``
    /// partial shape, `ASRTestDoubles.swift:220-222`), completeness 0 (only the final carries the
    /// capture's count). The form cannot produce a final: the seam's "partials then exactly one
    /// final" is structural in the mapper, not a caller discipline.
    func testThePartialFormYieldsANonFinalTranscriptWithoutSegmentsOrDuration() {
        let transcript = ParakeetTranscriptMapper.partial(text: "hello wor", engine: identity)

        XCTAssertEqual(transcript.text, "hello wor")
        XCTAssertEqual(transcript.engine, identity)
        XCTAssertFalse(
            transcript.isFinal,
            "a partial is never final — only the final transcript carries isFinal == true")
        XCTAssertTrue(
            transcript.segments.isEmpty,
            "a partial has no stable segmentation — its text can change with the next window")
        XCTAssertEqual(transcript.audioDuration, 0)
        XCTAssertEqual(transcript.missingSampleCount, 0)
    }

    /// The final form: one segment spanning the whole utterance, duration from the sample count
    /// (`sampleCount / 16_000`) — never from the text's length, which says nothing about time.
    func testTheFinalFormYieldsOneSegmentedFinalWithDurationFromTheSampleCount() {
        let transcript = ParakeetTranscriptMapper.final(
            text: "hello world", forSampleCount: 32_000, engine: identity)

        XCTAssertEqual(transcript.text, "hello world")
        XCTAssertEqual(transcript.engine, identity)
        XCTAssertTrue(transcript.isFinal)
        XCTAssertEqual(
            transcript.audioDuration, 2.0,
            "the duration must come from the sample count — 32 000 samples at 16 kHz is 2 s")
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].text, "hello world")
        XCTAssertEqual(transcript.segments[0].range, 0..<2.0)
        XCTAssertNil(
            transcript.segments[0].confidence,
            "the SDK's updates expose no stable confidence on the final — nil is the 'none' signal")
    }

    /// Empty text maps to a valid empty final transcript, never an error — the batch precedent
    /// (the SDK's answer to near-silent audio is empty, and the seam's stream form promises the
    /// same: silence is a transcript, `ParakeetCoreTests`' empty-text row).
    func testTheFinalFormTurnsEmptyTextIntoAValidEmptyFinalTranscript() {
        let transcript = ParakeetTranscriptMapper.final(
            text: "", forSampleCount: 0, engine: identity)

        XCTAssertEqual(transcript.text, "")
        XCTAssertEqual(transcript.audioDuration, 0)
        XCTAssertEqual(transcript.engine, identity)
        XCTAssertTrue(transcript.isFinal)
    }

    /// The sample-count form of the below-minimum decision — the stream's contract, headless:
    /// a **total** below 4 800 samples must answer a single empty final regardless of anything
    /// the SDK says (the stream form of the seam's empty-buffer policy, `ASREngine.swift:28-37`).
    ///
    /// The boundary is the measured one (4 799 below / 4 800 above — the batch rows above), and
    /// the buffer form delegates to this one, so the two cannot drift apart: the stream's total
    /// and the batch's buffer ask the same question.
    func testTheSampleCountMinimumMatchesTheMeasuredBoundaryAndTheBufferForm() {
        XCTAssertTrue(ParakeetEngine.isBelowSDKMinimum(sampleCount: 0, sampleRate: 16_000))
        XCTAssertTrue(ParakeetEngine.isBelowSDKMinimum(sampleCount: 320, sampleRate: 16_000))
        XCTAssertTrue(ParakeetEngine.isBelowSDKMinimum(sampleCount: 4_799, sampleRate: 16_000))
        XCTAssertFalse(ParakeetEngine.isBelowSDKMinimum(sampleCount: 4_800, sampleRate: 16_000))
        XCTAssertFalse(ParakeetEngine.isBelowSDKMinimum(sampleCount: 32_000, sampleRate: 16_000))

        for total in [0, 320, 4_799, 4_800, 32_000] {
            XCTAssertEqual(
                ParakeetEngine.isBelowSDKMinimum(sampleCount: total, sampleRate: 16_000),
                ParakeetEngine.isBelowSDKMinimum(buffer(Array(repeating: 0.1, count: total))),
                "the buffer form and the sample-count form must agree — one decision, two carriers")
        }
    }

    // MARK: - Load state

    /// Two `prepare`s load once: the state's whole reason to exist.
    func testLoadStateLoadsOnceAcrossRepeatedPrepares() {
        var state = ParakeetLoadState()
        XCTAssertFalse(state.hasLoaded)
        XCTAssertEqual(state.loadAttempts, 0)

        state.beginAttempt()
        state.complete()
        XCTAssertTrue(state.hasLoaded)

        state.beginAttempt()
        state.complete()
        XCTAssertEqual(
            state.loadAttempts, 2,
            "beginAttempt records every entry — the ledger is exact")
        XCTAssertTrue(state.hasLoaded)
    }

    /// A failed load leaves the state not-loaded, so the next `prepare` retries.
    func testLoadStateRetriesAfterAFailure() {
        var state = ParakeetLoadState()
        state.beginAttempt()
        state.fail()
        XCTAssertFalse(state.hasLoaded, "a failed load must not mark loaded")
        XCTAssertEqual(state.loadAttempts, 1)

        state.beginAttempt()
        state.complete()
        XCTAssertTrue(state.hasLoaded)
        XCTAssertEqual(state.loadAttempts, 2)
    }

    // MARK: - Timing

    /// The timing recorder stores exactly what it is given, per kind, in order — the local-only
    /// latency ledger (PRD S1) the C7 work inherits.
    func testTimingRecordsPerKindInOrder() async {
        let timing = EngineTiming()
        await timing.record(.coldLoad, elapsed: .milliseconds(281_000))
        await timing.record(.warmTranscribe, elapsed: .milliseconds(110))
        await timing.record(.firstAfterLaunch, elapsed: .milliseconds(120))

        let cold = await timing.samples(for: .coldLoad)
        XCTAssertEqual(cold, [.milliseconds(281_000)])

        let warm = await timing.samples(for: .warmTranscribe)
        XCTAssertEqual(warm, [.milliseconds(110)])

        let first = await timing.samples(for: .firstAfterLaunch)
        XCTAssertEqual(first, [.milliseconds(120)])
    }

    /// Distinct kinds stay distinct: a first-after-launch reading is not a warm reading, and the
    /// recorder must not conflate them.
    func testTimingKindsDoNotLeakIntoEachOther() async {
        let timing = EngineTiming()
        await timing.record(.coldLoad, elapsed: .seconds(1))
        await timing.record(.warmTranscribe, elapsed: .seconds(2))
        await timing.record(.firstAfterLaunch, elapsed: .seconds(3))

        let cold = await timing.samples(for: .coldLoad)
        let warm = await timing.samples(for: .warmTranscribe)
        let first = await timing.samples(for: .firstAfterLaunch)
        XCTAssertEqual(cold, [.seconds(1)])
        XCTAssertEqual(warm, [.seconds(2)])
        XCTAssertEqual(first, [.seconds(3)])
        XCTAssertEqual(cold.count, 1)
    }
}
