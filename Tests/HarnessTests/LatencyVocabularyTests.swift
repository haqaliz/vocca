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
/// - the outcome classes are exactly the six routes the P0 pipeline can exit by, and they are
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

    /// Exactly the six classes, each constructed by hand — the ``InjectionResult`` precedent.
    ///
    /// The exhaustive switch has no default case, so a seventh class is a compile error in this
    /// file: the compiler makes the suite grow, not the prose.
    func testSessionOutcomeClassHasExactlyTheSixClasses() {
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
            case .lost:
                return "lost"
            case .emptySkip:
                return "emptySkip"
            }
        }
        let classes: [SessionOutcomeClass] = [
            .delivered(rung: .accessibility, verified: true),
            .failsafeHeld,
            .aborted,
            .failed,
            .lost,
            .emptySkip,
        ]
        XCTAssertEqual(classes.count, 6)
        XCTAssertEqual(
            classes.map(label(of:)),
            [
                "delivered(accessibility, true)", "failsafeHeld", "aborted", "failed", "lost",
                "emptySkip",
            ])
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
        _ = requireSendable(SessionOutcomeClass.lost)
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

    // MARK: - The single loss site (`loss-observability` A6)

    /// **The source scan.** Exactly one line under `Sources/` hands
    /// ``SessionOutcomeClass/lost`` to a `finalize` call — the failsafe arm of
    /// `DictationPipeline.swift`, where the ladder reached ``InjectionRung/widgetFailsafe`` and
    /// the journal refused custody.
    ///
    /// One *site*, not one *way in*. That line has two callers — the ordinary dictation route
    /// and the onboarding injector, whose refused `OnboardingSink` leaves the holder empty by
    /// construction — and both arrive at the same cause, so the count below is a claim about
    /// where a loss can be recorded, never about how many ways a session can reach it.
    ///
    /// The count is what the scan is for. `.lost` is the class the P0 transcript-loss metric
    /// counts, and `ROADMAP.md:96` fixes that count at zero with no acceptable non-zero value —
    /// so a second site is a second way for the product to lose a transcript, and it must be a
    /// reviewed decision rather than a line that arrived with something else. The compiler
    /// cannot force that: an enum's exhaustiveness constrains `switch`es, and nothing at all
    /// constrains call sites. This scan is the only thing in the tree that can.
    ///
    /// Vacuity is guarded in both directions, the ``InjectionStrategyStoreTests`` precedent: the
    /// scan must have seen files at all and must find the site that exists, and the matcher is
    /// then run over hand-written source that violates the rule and over source that keeps it,
    /// so a matcher that had quietly stopped matching anything could not read as a pass.
    func testExactlyOneSourceLineRecordsATranscriptAsLost() throws {
        // `[^)]*` cannot cross a closing paren, so the match is confined to one `finalize(`
        // argument list; comments are stripped first, so a doc comment naming the class is not
        // a site.
        let pattern = #"finalize\([^)]*outcome:\s*\.lost"#
        func lossSites(in source: String) -> Int {
            let stripped = SwiftSourceScanner.stripComments(from: source)
            var count = 0
            var searchFrom = stripped.startIndex
            while let found = stripped.range(
                of: pattern, options: .regularExpression,
                range: searchFrom..<stripped.endIndex)
            {
                count += 1
                searchFrom = found.upperBound
            }
            return count
        }

        let root = try PackageRootLocator.find(from: #filePath)
        let namedFile = "DictationPipeline.swift"
        var scannedFiles = 0
        var sightings: [String: Int] = [:]
        for file in SwiftSourceScanner.swiftFiles(under: root.appendingPathComponent("Sources")) {
            scannedFiles += 1
            let sites = lossSites(in: try String(contentsOf: file, encoding: .utf8))
            if sites > 0 { sightings[file.lastPathComponent] = sites }
        }

        XCTAssertGreaterThan(scannedFiles, 0, "vacuity guard: the scan saw no files at all")
        XCTAssertEqual(
            sightings, [namedFile: 1],
            """
            A transcript may be recorded as lost from exactly one place — the failsafe arm that \
            found the journal holding nothing. The P0 gate counts transcript loss at exactly \
            zero (ROADMAP.md:96), so a second site is a second way the product can lose a \
            transcript and has to be a decision somebody made on purpose. Got: \(sightings)
            """)

        // The matcher's own control, in both directions: source that violates the rule must be
        // seen to violate it, and source that keeps it must not be counted as a site.
        let twoSites = """
            await finalize(sessionID: sessionID, outcome: .lost, engine: transcript.engine)
            await finalize(sessionID: other, outcome: .lost, engine: nil)
            """
        XCTAssertEqual(
            lossSites(in: twoSites), 2,
            "the matcher must see a second site — a scan that cannot fail proves nothing about "
                + "the tree it passed on")
        let noSite = """
            await finalize(sessionID: sessionID, outcome: .failed, engine: engine.identity)
            // await finalize(sessionID: sessionID, outcome: .lost, engine: nil)
            case .lost: classLabel = "lost"
            """
        XCTAssertEqual(
            lossSites(in: noSite), 0,
            "neither a `.failed` finalize, nor a commented-out one, nor a `switch` arm naming "
                + "the class is a site — a matcher that counted them would fail the tree for "
                + "lines that record nothing")
    }
}
