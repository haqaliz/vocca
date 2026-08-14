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

/// The latency vocabulary: the types the `core-ledger` aspect's acceptance list names, as code,
/// in `VoccaCore`.
///
/// Like ``InjectionVocabularyTests`` and ``ASRVocabularyTests`` this suite tests *shape* first —
/// there is no ledger yet, so nothing here can test behaviour. The shape is load-bearing for
/// three reasons:
///
/// - the span names are the closed four the histogram keys on, so `SpanName.allCases` is pinned
///   in one line — a fifth name is a deliberate change that re-tests every consumer;
/// - the presence state exists so C5's absence is *representable* without fabrication: the
///   ledger must never write a `0` for a span that never ran (spec A2), so `notPresent` is a
///   distinct state from a recorded zero — never a fake duration;
/// - the outcome classes are exactly the five routes the P0 pipeline can exit by, and they are
///   never force-labeled: the first-method-success metric is *derived* from `delivered` counts
///   (spec "Outcome classes", prd.md confirmed decision).
final class LatencyVocabularyTests: XCTestCase {

    // MARK: - SpanName

    /// The closed four: the spans the P0 loop can measure, in pipeline order.
    ///
    /// `allCases` equality pins the set in one line, the ``InjectionRung`` precedent — a fifth
    /// case is a deliberate change that re-tests every consumer.
    func testSpanNameIsTheClosedFourInPipelineOrder() {
        XCTAssertEqual(SpanName.allCases, [.captureClose, .asr, .cleanup, .inject])
        XCTAssertEqual(SpanName.allCases.count, 4)
    }

    // MARK: - LatencySpan

    /// A recorded span carries its name, presence and elapsed; the presence enum is `recorded`
    /// or `notPresent`.
    ///
    /// Zero is a *legitimate* measured duration — an instant capture-close is a real reading —
    /// so the state that distinguishes "ran in zero time" from "never ran" is the presence enum,
    /// never the elapsed.
    func testRecordedSpanOfZeroDurationIsStillRecorded() {
        let zero = LatencySpan.recorded(name: .captureClose, elapsed: .zero)
        XCTAssertEqual(zero.name, .captureClose)
        XCTAssertEqual(zero.presence, .recorded)
        XCTAssertEqual(zero.elapsed, .zero)
    }

    /// The cleanup span exists in every record as `notPresent` until a caller records it
    /// (spec A2): C5 is unbuilt, so the ledger must never fabricate a duration for it.
    ///
    /// `cleanupNotPresent` is the only factory that may produce that state, and the assertions
    /// pin the two things that must hold: the presence is `notPresent` — never `recorded`, even
    /// though the elapsed reads zero — and the span is *distinct* from a recorded zero, so a
    /// fabricated `0` can never be mistaken for a measured reading.
    func testNotPresentSpanNeverCarriesADuration() {
        let notPresent = LatencySpan.cleanupNotPresent()
        XCTAssertEqual(notPresent.name, .cleanup)
        XCTAssertEqual(notPresent.presence, .notPresent)
        XCTAssertEqual(notPresent.elapsed, .zero)
        XCTAssertNotEqual(
            notPresent, LatencySpan.recorded(name: .cleanup, elapsed: .zero),
            "a notPresent span is a distinct state from a recorded zero — never a fabricated 0 (spec A2/A3)")
    }

    // MARK: - SessionOutcomeClass

    /// Exactly the five classes, each constructed by hand — the ``InjectionResult`` precedent.
    ///
    /// The exhaustive switch has no default case, so a sixth class is a compile error in this
    /// file: the compiler makes the suite grow, not the prose.
    func testSessionOutcomeClassHasExactlyTheFiveClasses() {
        func label(of outcome: SessionOutcomeClass) -> String {
            switch outcome {
            case .delivered(let rung, let verified):
                return "delivered(\(rung), \(verified))"
            case .failsafeHeld:
                return "failsafeHeld"
            case .aborted:
                return "aborted"
            case .failed:
                return "failed"
            case .emptySkip:
                return "emptySkip"
            }
        }
        let classes: [SessionOutcomeClass] = [
            .delivered(rung: .accessibility, verified: true),
            .failsafeHeld,
            .aborted,
            .failed,
            .emptySkip,
        ]
        XCTAssertEqual(classes.count, 5)
        XCTAssertEqual(
            classes.map(label(of:)),
            ["delivered(accessibility, true)", "failsafeHeld", "aborted", "failed", "emptySkip"])
    }

    /// The `delivered` class carries the rung and verification state read off a hand-built
    /// ``InjectionResult`` (spec A6) — the fault-injection precedent: no real injector.
    func testDeliveredCarriesRungAndVerificationFromInjectionResult() {
        let result = InjectionResult(
            rung: .clipboardPaste,
            attempted: [.accessibility, .clipboardPaste],
            verified: false,
            elapsed: .milliseconds(41))
        if case .delivered(let rung, let verified) =
            SessionOutcomeClass.delivered(rung: result.rung, verified: result.verified)
        {
            XCTAssertEqual(rung, .clipboardPaste)
            XCTAssertFalse(verified)
        } else {
            XCTFail("delivered did not carry the rung and verification")
        }
    }

    // MARK: - SessionRecord

    /// The record is the ledger's unit (spec §3): one per session, carrying the id the ledger
    /// minted, the outcome class, the spans **in the order they were recorded** (spec A2), and
    /// the engine attribution.
    ///
    /// `delivered` as the outcome is set at finalize from a hand-built ``InjectionResult`` — the
    /// ``testDeliveredCarriesRungAndVerificationFromInjectionResult`` precedent above — so the
    /// rung and the read-back truth travel with the record.
    func testSessionRecordCarriesIDOutcomeSpansInRecordOrderAndEngine() {
        let id = SessionRecord.ID(rawValue: 1)
        let spans = [
            LatencySpan.recorded(name: .captureClose, elapsed: .milliseconds(3)),
            LatencySpan.recorded(name: .asr, elapsed: .milliseconds(120)),
            LatencySpan.cleanupNotPresent(),
            LatencySpan.recorded(name: .inject, elapsed: .milliseconds(9)),
        ]
        let record = SessionRecord(
            id: id,
            outcome: .delivered(rung: .accessibility, verified: true),
            spans: spans,
            engine: EngineIdentity(
                id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet", isLocal: true))
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.outcome, .delivered(rung: .accessibility, verified: true))
        XCTAssertEqual(
            record.spans, spans,
            "spans keep the order they were recorded in — the histogram keys on the sequence")
        XCTAssertEqual(record.engine?.id, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(record.engine?.isLocal, true)
    }

    /// Engine attribution is nil only for the two routes that never asked the engine (C2's rule,
    /// scoped honestly — spec Phase 2): `aborted` (Escape — nothing was asked) and `emptySkip`
    /// (no audio — the injector was skipped). Every other route attempted a transcription, so
    /// its record carries the engine.
    func testEngineAttributionIsNilOnlyForTheTwoNeverAskedPaths() {
        let engine = EngineIdentity(
            id: "whisper-large-v3-turbo", displayName: "Whisper", isLocal: true)

        let aborted = SessionRecord(
            id: SessionRecord.ID(rawValue: 1), outcome: .aborted, spans: [], engine: nil)
        let emptySkip = SessionRecord(
            id: SessionRecord.ID(rawValue: 2), outcome: .emptySkip, spans: [], engine: nil)
        XCTAssertNil(
            aborted.engine,
            "an aborted session never asked the engine — the record must not fabricate an engine")
        XCTAssertNil(
            emptySkip.engine,
            "an empty short press never asked the engine — the record must not fabricate one")

        let delivered = SessionRecord(
            id: SessionRecord.ID(rawValue: 3),
            outcome: .delivered(rung: .clipboardPaste, verified: false), spans: [], engine: engine)
        let failsafe = SessionRecord(
            id: SessionRecord.ID(rawValue: 4), outcome: .failsafeHeld, spans: [], engine: engine)
        let failed = SessionRecord(
            id: SessionRecord.ID(rawValue: 5), outcome: .failed, spans: [], engine: engine)
        XCTAssertEqual(delivered.engine, engine)
        XCTAssertEqual(failsafe.engine, engine)
        XCTAssertEqual(failed.engine, engine)
    }

    /// The id is a stable opaque handle: `Hashable` — the ledger's store key — and the same
    /// minted value compares equal every time it is handed back across calls. The seam's entry
    /// points refer to a session by the value `beginSession` returned; a fresh value with the
    /// same content must be indistinguishable from it.
    func testSessionRecordIDIsHashableAndStableAcrossCalls() {
        let id = SessionRecord.ID(rawValue: 7)
        let sameValueHandedBackAcrossCalls = SessionRecord.ID(rawValue: 7)
        XCTAssertEqual(id, sameValueHandedBackAcrossCalls)
        XCTAssertEqual(id.hashValue, sameValueHandedBackAcrossCalls.hashValue)

        var seen = Set<SessionRecord.ID>()
        seen.insert(id)
        XCTAssertTrue(
            seen.contains(sameValueHandedBackAcrossCalls),
            "the id must be usable as a set/dictionary key — mint once, hold it, use it twice")

        let first = SessionRecord(id: id, outcome: .aborted, spans: [], engine: nil)
        let second = SessionRecord(id: id, outcome: .aborted, spans: [], engine: nil)
        XCTAssertEqual(first.id, second.id)
    }

    // MARK: - LatencyRecorder

    /// The seam has exactly three entry points: begin (mints the id), record (a span for a
    /// session), finalize (the outcome class and engine attribution) — all `async` because the
    /// ledger is an actor (spec A8), and `Sendable` because the seam crosses module boundaries.
    ///
    /// If a fourth requirement appears, or any signature changes, this conformance stops
    /// compiling — the compiler pins the seam the way the exhaustive switch pins the outcome
    /// classes. The two mutating entry points return `Bool` so refusals (a duplicate span name,
    /// a write after finalize) are visible to the caller — spec A3, plan §6.
    func testLatencyRecorderIsExactlyTheThreeEntryPointSeam() {
        struct RecordingStub: LatencyRecorder {
            func beginSession() async -> SessionRecord.ID { SessionRecord.ID(rawValue: 1) }
            func recordSpan(_ span: LatencySpan, for sessionID: SessionRecord.ID) async -> Bool {
                true
            }
            func finalize(
                id: SessionRecord.ID, outcome: SessionOutcomeClass, engine: EngineIdentity?
            ) async -> Bool {
                true
            }
        }
        _ = RecordingStub()
    }

    // MARK: - Sendable

    /// Compile-time, not runtime: `requireSendable` constrains its parameter to `Sendable`, so a
    /// type that loses the conformance fails to build this file rather than failing an assertion.
    ///
    /// The vocabulary crosses actor boundaries on every path — the ledger is an actor (spec A8)
    /// and the spans travel from the engines' and the injector's own contexts — so every type
    /// here must be `Sendable` itself.
    func testTheLatencyVocabularyIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        _ = requireSendable(SpanName.captureClose)
        _ = requireSendable(LatencySpan.Presence.recorded)
        _ = requireSendable(LatencySpan.recorded(name: .asr, elapsed: .milliseconds(12)))
        _ = requireSendable(LatencySpan.cleanupNotPresent())
        _ = requireSendable(
            SessionOutcomeClass.delivered(rung: .keystrokeSynthesis, verified: false))
        _ = requireSendable(SessionOutcomeClass.failsafeHeld)
        _ = requireSendable(SessionOutcomeClass.aborted)
        _ = requireSendable(SessionOutcomeClass.failed)
        _ = requireSendable(SessionOutcomeClass.emptySkip)
    }

    /// The Phase 2 additions cross the same actor boundaries as the vocabulary: the record
    /// travels from the pipeline to the ledger, and the seam is the ledger's protocol. Both must
    /// be `Sendable` themselves; the seam is pinned with a metatype binding.
    func testSessionRecordAndRecorderAreSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        func requireSendableProtocol<T: Sendable>(_ type: T.Type) {}
        _ = requireSendable(SessionRecord.ID(rawValue: 1))
        _ = requireSendable(
            SessionRecord(
                id: SessionRecord.ID(rawValue: 1), outcome: .emptySkip, spans: [], engine: nil))
        _ = requireSendable(
            SessionRecord(
                id: SessionRecord.ID(rawValue: 2), outcome: .delivered(rung: .accessibility, verified: true),
                spans: [LatencySpan.cleanupNotPresent()],
                engine: EngineIdentity(id: "e", displayName: "E", isLocal: true)))
        requireSendableProtocol(LatencyRecorder.self)
    }
}
