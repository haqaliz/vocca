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

import VoccaASR
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
