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

/// The injection vocabulary: the types `ARCHITECTURE.md` §4 and §9 name, as code, in `VoccaCore`.
///
/// This is the first phase of the `injector-seam` aspect, and like ``ASRVocabularyTests`` it tests
/// *shape* — there is no ladder and no rung adapter yet, so nothing here can test behaviour. The
/// shape is load-bearing for different reasons than the ASR's was:
///
/// - the seam is the floor under I1 — "a transcript is never lost" — so the vocabulary must make
///   a loss *unrepresentable*: `VoccaError.injectionExhausted` exists and no `transcriptLost`
///   case may (`ARCHITECTURE.md:199`);
/// - the rungs are the closed set the Phase C fault-injection suite iterates, so
///   `InjectionRung.allCases` is pinned to exactly the four, in ladder order — a fifth rung is a
///   deliberate change that re-tests the whole set;
/// - `HeldTranscript.capturedAt` is a monotonic reading, not a wall clock, so the failsafe
///   window's "captured at" note (`PRODUCT_SPEC.md:117`) survives sleep and clock steps.
final class InjectionVocabularyTests: XCTestCase {

    // MARK: - InjectionRung

    /// The rung set is exactly the four `ARCHITECTURE.md:398-403` names, in ladder order.
    ///
    /// `CaseIterable` exists for the fault-injection suite: every rung forced to fail, in every
    /// combination, with zero transcript loss asserted. The `allCases` equality pins the closed
    /// set in one line — a fifth case, a dropped case, or a reordering all fail this test — and
    /// the raw values are the journal's and strategy memory's persisted spelling, pinned the way
    /// the tap's magic numbers are: a renamed case would silently orphan stored state.
    func testInjectionRungIsExactlyTheFourRungsInLadderOrder() {
        XCTAssertEqual(
            InjectionRung.allCases,
            [.accessibility, .clipboardPaste, .keystrokeSynthesis, .widgetFailsafe])
        XCTAssertEqual(InjectionRung.allCases.count, 4)
        XCTAssertEqual(
            InjectionRung.allCases.map(\.rawValue),
            ["accessibility", "clipboardPaste", "keystrokeSynthesis", "widgetFailsafe"])
    }

    // MARK: - TargetContext

    /// The context carries everything the decision needs and nothing else: bundle id, window
    /// title and Secure Input state.
    ///
    /// `bundleID == nil` is the "nothing is focused" signal the decision refuses on before any
    /// rung runs (reason `.noFocusedField`); `isSecureInput` is the rung-0 refusal
    /// (`ARCHITECTURE.md:382-384`). `Equatable` is what lets the Phase C decision-table tests
    /// assert over contexts a test builds by hand.
    func testTargetContextCarriesBundleIDWindowTitleAndSecureInput() {
        let target = TargetContext(
            bundleID: "com.apple.Notes", windowTitle: "Untitled", isSecureInput: false)
        XCTAssertEqual(target.bundleID, "com.apple.Notes")
        XCTAssertEqual(target.windowTitle, "Untitled")
        XCTAssertFalse(target.isSecureInput)

        let secure = TargetContext(
            bundleID: "com.apple.Terminal", windowTitle: nil, isSecureInput: true)
        XCTAssertEqual(secure.bundleID, "com.apple.Terminal")
        XCTAssertTrue(secure.isSecureInput)
        XCTAssertNil(
            secure.windowTitle,
            "nil window title is a legitimate state — the failsafe copy falls back to the app name")

        XCTAssertNotEqual(
            target, secure,
            "a secure-input context must not compare equal to an ordinary one")
        XCTAssertEqual(
            target,
            TargetContext(bundleID: "com.apple.Notes", windowTitle: "Untitled", isSecureInput: false))
    }

    // MARK: - InjectionResult

    /// The result carries the winning rung, the full attempt trace, the read-back truth and the
    /// elapsed time — the four fields `ARCHITECTURE.md:172-177` names.
    ///
    /// `attempted` is the C8 strategy-memory input, so the trace must survive the round trip in
    /// order; `verified` is the read-back truth the *decision* interprets (an unverified AX
    /// "success" counts as failure, `ARCHITECTURE.md:400`) — this struct only carries the fact.
    func testInjectionResultCarriesRungAttemptTraceVerificationAndElapsed() {
        let result = InjectionResult(
            rung: .widgetFailsafe,
            attempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            verified: false,
            elapsed: .milliseconds(87))
        XCTAssertEqual(result.rung, .widgetFailsafe)
        XCTAssertEqual(
            result.attempted, [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            "the trace is the full ladder, in attempt order — C8 demotes on exactly this")
        XCTAssertEqual(result.attempted.count, 3)
        XCTAssertFalse(result.verified)
        XCTAssertEqual(result.elapsed, .milliseconds(87))
    }

    // MARK: - FailsafeReason

    /// The four declared reasons: the three the ladder can produce today, and
    /// `.accessibilityRevoked` — reserved for N1's mid-session revocation detection, a later
    /// unit — so the window's copy table and the journal's persisted schema are stable when
    /// detection lands.
    ///
    /// The raw spellings are the persisted vocabulary, pinned in both directions. The negative
    /// control names the one reason that must never exist: a transcript is never lost, so no
    /// loss-shaped reason may be spellable.
    func testFailsafeReasonCoversSecureInputExhaustionNoFocusAndTheReservedRevocation() {
        let spellings: [(FailsafeReason, String)] = [
            (.secureInput, "secureInput"),
            (.exhausted, "exhausted"),
            (.noFocusedField, "noFocusedField"),
            (.accessibilityRevoked, "accessibilityRevoked"),
        ]
        for (reason, raw) in spellings {
            XCTAssertEqual(reason.rawValue, raw, "\(reason) must keep its persisted spelling")
            XCTAssertEqual(
                FailsafeReason(rawValue: raw), reason,
                "\(raw) must decode back to \(reason)")
        }
        XCTAssertNil(
            FailsafeReason(rawValue: "transcriptLost"),
            "a loss-shaped reason must not be representable (I1)")
    }

    // MARK: - HeldTranscript

    /// The held transcript carries the undelivered text, the reason, the app name for the
    /// "{app}" copy (`PRODUCT_SPEC.md:112`), and a monotonic capture instant — never a wall
    /// clock.
    func testHeldTranscriptCarriesTextReasonTargetAppAndCaptureTime() {
        let held = HeldTranscript(
            text: "the words", reason: .exhausted, targetAppName: "Slack",
            capturedAt: .seconds(3))
        XCTAssertEqual(held.text, "the words")
        XCTAssertEqual(held.reason, .exhausted)
        XCTAssertEqual(held.targetAppName, "Slack")
        XCTAssertEqual(held.capturedAt, .seconds(3))

        let unnamed = HeldTranscript(
            text: "the words", reason: .noFocusedField, targetAppName: nil,
            capturedAt: .milliseconds(40))
        XCTAssertNil(unnamed.targetAppName)
        XCTAssertEqual(unnamed.reason, .noFocusedField)
        XCTAssertEqual(unnamed.capturedAt, .milliseconds(40))
    }

    // MARK: - VoccaError

    /// `injectionExhausted` carries the attempt trace — the same array an
    /// ``InjectionResult`` would have carried, so C8's strategy memory reads one shape wherever
    /// it looks. Pattern-matched, not compared: the enum already conforms to `Equatable`, but
    /// the payload is the point, and a payload change must fail here rather than silently
    /// compare.
    func testInjectionExhaustedCarriesTheAttemptTrace() {
        let error = VoccaError.injectionExhausted(
            attempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis])
        if case .injectionExhausted(let attempted) = error {
            XCTAssertEqual(
                attempted, [.accessibility, .clipboardPaste, .keystrokeSynthesis],
                "exhaustion must report which rungs were attempted, in order")
        } else {
            XCTFail("injectionExhausted did not carry the attempt trace: \(error)")
        }
    }

    // MARK: - Sendable

    /// Compile-time, not runtime: `requireSendable` constrains its parameter to `Sendable`, so a
    /// type that loses the conformance fails to build this file rather than failing an assertion.
    ///
    /// These types cross actor boundaries on every path: the injector runs on the latency path,
    /// and the held transcript travels from the journal to the window. The two seams must be
    /// `Sendable` themselves — a non-`Sendable` seam would be unusable from an actor-owned
    /// pipeline — so the protocols are pinned with a metatype binding, the same shape as the
    /// ASR vocabulary's value bindings.
    func testTheInjectionVocabularyIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        func requireSendableProtocol<T: Sendable>(_ type: T.Type) {}

        let target = TargetContext(
            bundleID: "com.apple.Notes", windowTitle: nil, isSecureInput: false)
        XCTAssertEqual(requireSendable(target), target)
        _ = requireSendable(InjectionRung.accessibility)
        _ = requireSendable(
            InjectionResult(
                rung: .widgetFailsafe, attempted: [], verified: false, elapsed: .zero))
        _ = requireSendable(FailsafeReason.exhausted)
        _ = requireSendable(
            HeldTranscript(
                text: "", reason: .secureInput, targetAppName: nil, capturedAt: .zero))
        _ = requireSendable(VoccaError.injectionExhausted(attempted: []))

        requireSendableProtocol(TextInjector.self)
        requireSendableProtocol(TranscriptHolder.self)
    }
}
