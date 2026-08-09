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
import VoccaASR
import VoccaCore
import XCTest

/// The whisper.cpp engine's testable core (`whisper-engine` plan Phase 1): every decision the
/// adapter contains, headless, with **no C-API name in sight** — the mapping rules, the load-once
/// state, the parameter defaults, and the identity constant.
///
/// The bridge file (`WhisperCAPI.swift`, a later phase) is thin translation that CI never
/// executes; everything it *decides* is this suite, runnable forever on a plain runner. It feeds
/// this suite's `[WhisperSegment]` values — the abstract segment shape is what makes the mapper
/// buildable and testable before the C API exists.
final class WhisperCoreTests: XCTestCase {

    // MARK: - Identity

    /// The identity constant carries the three fields with `isLocal == true` — no egress badge
    /// (`ARCHITECTURE.md:152-156`), and the `id` is the machine key `EngineIdentity.swift:28`'s
    /// doc names: the model store keys its directory by it, and persisted settings decode back.
    func testTheIdentityConstantCarriesItsFieldsAndIsLocal() {
        XCTAssertEqual(WhisperCppEngineIdentity.whisper.id, "whisper-large-v3-turbo")
        XCTAssertEqual(WhisperCppEngineIdentity.whisper.displayName, "Whisper turbo")
        XCTAssertTrue(WhisperCppEngineIdentity.whisper.isLocal)
    }

    // MARK: - Mapper

    /// Empty segments — the engine's answer to near-silent audio — map to a valid empty
    /// transcript, never an error (the seam's policy, kept above the C API), with the real
    /// audio duration and the engine's own identity.
    func testTheMapperTurnsEmptySegmentsIntoAValidEmptyTranscript() {
        let transcript = WhisperTranscriptMapper.map(segments: [], duration: 2.5)

        XCTAssertEqual(transcript.text, "")
        XCTAssertEqual(transcript.segments, [])
        XCTAssertEqual(transcript.engine, WhisperCppEngineIdentity.whisper)
        XCTAssertTrue(transcript.isFinal, "batch transcription is always final")
        XCTAssertEqual(
            transcript.audioDuration, 2.5,
            "the duration is the audio's real length, carried even when nothing was transcribed")
    }

    /// Whisper segments carry their own timestamps, so the mapped `TranscriptSegment` ranges are
    /// half-open `start..<end` seconds — each segment spans exactly the audio it transcribes, and
    /// adjacent segments meet without overlap or gap.
    func testTheMapperMapsSegmentsToHalfOpenRanges() {
        let transcript = WhisperTranscriptMapper.map(
            segments: [
                WhisperSegment(text: "Hello", start: 0.0, end: 0.72, tokenProbability: nil),
                WhisperSegment(text: "world", start: 0.72, end: 1.34, tokenProbability: nil),
            ],
            duration: 1.34)

        XCTAssertEqual(transcript.text, "Hello world", "the segments join with a single space")
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].text, "Hello")
        XCTAssertEqual(
            transcript.segments[0].range, 0.0..<0.72,
            "the range is half-open: the segment covers exactly start..<end")
        XCTAssertEqual(transcript.segments[1].text, "world")
        XCTAssertEqual(transcript.segments[1].range, 0.72..<1.34)
        XCTAssertEqual(transcript.engine, WhisperCppEngineIdentity.whisper)
        XCTAssertTrue(transcript.isFinal)
        XCTAssertEqual(transcript.audioDuration, 1.34)
    }

    /// The confidence policy: the segment's token probability is surfaced as confidence when the
    /// bridge supplies it, and `nil` when it is absent — nil means "the engine exposed none", a
    /// fact about the engine, never a fabricated number.
    func testTheMapperSurfacesTokenProbabilityAsConfidenceWhenPresent() {
        let certain = WhisperTranscriptMapper.map(
            segments: [WhisperSegment(text: "hello", start: 0.0, end: 0.5, tokenProbability: 0.85)],
            duration: 0.5)
        XCTAssertEqual(
            certain.segments[0].confidence, 0.85,
            "the raw value passes through when present")

        let unknown = WhisperTranscriptMapper.map(
            segments: [WhisperSegment(text: "hello", start: 0.0, end: 0.5, tokenProbability: nil)],
            duration: 0.5)
        XCTAssertNil(
            unknown.segments[0].confidence,
            "an absent token probability maps to nil, never to a made-up number")
    }

    /// The completeness count is carried, never dropped — the I1 link the capture bridge feeds
    /// through the buffer; 0 means complete.
    func testTheMapperCarriesTheMissingSampleCount() {
        let short = WhisperTranscriptMapper.map(
            segments: [WhisperSegment(text: "hi", start: 0.0, end: 0.25, tokenProbability: nil)],
            duration: 0.25,
            missingSampleCount: 42)
        XCTAssertEqual(short.missingSampleCount, 42)

        let complete = WhisperTranscriptMapper.map(segments: [], duration: 0)
        XCTAssertEqual(
            complete.missingSampleCount, 0,
            "the mapper defaults to complete; the capture bridge's count overrides it")
    }

    // MARK: - Load state

    /// A fresh state reads unloaded and not-ready; a successful prepare lands on prepared.
    func testLoadStateTransitionsUnloadedToPrepared() {
        var state = WhisperLoadState()
        XCTAssertEqual(state, .unloaded)
        XCTAssertFalse(state.hasLoaded)

        state.beginAttempt()
        state.complete()
        XCTAssertEqual(state, .prepared)
        XCTAssertTrue(state.hasLoaded)
    }

    /// A failed load leaves the state failed and not-ready, so the next `prepare` retries — a
    /// missing model is an honest failure, not a permanent dead end.
    func testLoadStateFailureLandsOnFailedAndRetries() {
        var state = WhisperLoadState()
        state.beginAttempt()
        state.fail()
        XCTAssertEqual(state, .failed)
        XCTAssertFalse(state.hasLoaded, "a failed load must not read as a ready engine")

        state.beginAttempt()
        state.complete()
        XCTAssertEqual(state, .prepared)
        XCTAssertTrue(state.hasLoaded)
    }

    /// Re-`prepare` from prepared is a no-op: the state's whole reason to exist is that a loaded
    /// engine stays loaded, and an in-flight re-prepare must not clobber it into unloaded.
    func testLoadStateReprepareIsIdempotent() {
        var state = WhisperLoadState()
        state.beginAttempt()
        state.complete()
        XCTAssertEqual(state, .prepared)

        state.beginAttempt()
        XCTAssertEqual(
            state, .prepared,
            "beginAttempt on a loaded engine must not unload it — the second prepare is a no-op")
        state.complete()
        XCTAssertEqual(state, .prepared)
        XCTAssertTrue(state.hasLoaded)
    }

    // MARK: - Parameters

    /// The thread-count rule, as a pure function over the CPU count — the same shape as
    /// `AudioBuffer.isValidFormat`: the rule is testable on its own rather than only observable
    /// through the machine's actual core count.
    func testTheDefaultThreadsFormulaIsCappedAtEight() {
        for (cpuCount, expected) in [
            (16, 8),  // many-core machine — capped at the ceiling
            (10, 8),  // exactly the ceiling
            (8, 6),  // below it, the formula is cpuCount - 2
            (6, 4),
            (4, 2),
            (3, 1),
        ] {
            XCTAssertEqual(
                WhisperCppParameters.defaultThreads(cpuCount: cpuCount), expected,
                "min(8, cpuCount - 2) with cpuCount \(cpuCount)")
        }
    }

    /// The defaults: threads from the live core count, language nil (auto-detect), tier turbo —
    /// the configuration a fresh engine is constructed with.
    func testTheParameterDefaultsAreSane() {
        let parameters = WhisperCppParameters()

        XCTAssertEqual(
            parameters.threads,
            WhisperCppParameters.defaultThreads(
                cpuCount: ProcessInfo.processInfo.activeProcessorCount),
            "the default thread count comes from the machine's live core count")
        XCTAssertNil(
            parameters.language,
            "nil means auto-detect — whisper picks the language from the audio")
        XCTAssertEqual(parameters.tier, .turbo)
    }

    /// The tier set is exactly {turbo, turboQ5} — the switch is exhaustive, so a third case
    /// added later fails to compile this file, and the two cases are distinct values.
    func testTheTierSetIsExactlyTurboAndTurboQ5() {
        let tiers: [WhisperCppParameters.Tier] = [.turbo, .turboQ5]
        XCTAssertEqual(Set(tiers).count, 2, "the two tiers are distinct values")
        XCTAssertNotEqual(WhisperCppParameters.Tier.turbo, .turboQ5)

        for tier in tiers {
            switch tier {
            case .turbo, .turboQ5:
                break
            }
        }

        XCTAssertNotEqual(
            WhisperCppParameters(threads: 4, tier: .turbo),
            WhisperCppParameters(threads: 4, tier: .turboQ5),
            "tier participates in equality — a q5 engine is not the fp16 engine")
    }

    /// Compile-time, not runtime: `requireSendable` constrains its parameter to `Sendable`, so a
    /// type that loses the conformance fails to build this file rather than failing an assertion.
    ///
    /// These values cross the engine actor's boundary on every transcription.
    func testTheParametersAreEquatableAndSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        let parameters = WhisperCppParameters(threads: 4, language: "en", tier: .turboQ5)
        XCTAssertEqual(requireSendable(parameters), parameters)
        XCTAssertEqual(requireSendable(WhisperCppParameters.Tier.turbo), .turbo)
        XCTAssertEqual(
            requireSendable(WhisperSegment(text: "hi", start: 0, end: 1, tokenProbability: 0.5)),
            WhisperSegment(text: "hi", start: 0, end: 1, tokenProbability: 0.5))
        XCTAssertEqual(requireSendable(WhisperLoadState()), .unloaded)
    }
}
