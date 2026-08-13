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
}
