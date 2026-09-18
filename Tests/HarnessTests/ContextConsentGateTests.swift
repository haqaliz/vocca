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

import VoccaContext
import VoccaCore
import XCTest

/// The never-read gate — the `consent-store` aspect's Phase 3 acceptance (D5/D6,
/// `plan_20260918.md`; PRD M4/M5): **with consent off for an app, no content read of that app
/// occurs at all**, and the ordering that guarantees it is a first-class contract, not a
/// hope. Written before the gate exists — every reference below is a compile pin, failing to
/// compile is the red state.
///
/// What is pinned here:
///
/// - the truth table (D5): `allows(bundleID:)` answers nil → false, invalid → false,
///   valid-but-unconsented → false, consented → true;
/// - the ordering contract (D6): the gate sits **between** the metadata read (bundle ID +
///   window title — allowed, M5's scoping) and the content read (selected text). The composed
///   probe runs the **production gate** over a recording ``ContextAXReading`` fake: consent off
///   → the content read records **zero** calls and the result is the refusal; consent on →
///   exactly one content read;
/// - the planted-violation control: a composed probe that consults the content read **before**
///   the gate is caught — its content-read call count is non-zero with consent off, and the
///   acceptance's zero-call expectation is itself asserted to fail against it (the
///   `KokoroSeamBoundaryTests` planted-control shape). The ordering is a contract, not a hope.
///
/// The fakes record call counts — a count rather than a flag, because "read twice" and "read
/// at all" are different bugs. The gate is the production gate in every probe: no test here
/// may pass by discipline.
final class ContextConsentGateTests: XCTestCase {

    /// The truth table (D5), over the production gate: nil → false; invalid → false;
    /// valid-but-unconsented → false; consented → true.
    ///
    /// The decline-before-any-AX-read precedent (`AccessibilityRungStrategy.swift:99-104`):
    /// there is no read-then-discard path — an unconsented app is refused as a *decision*,
    /// before any content read could happen. The invalid row matters because the vocabulary is
    /// the privacy boundary: a content-shaped string must not even be *asked about*.
    func testTheTruthTableRefusesEverythingButAConsentedValidBundleID() {
        let gate = ContextConsentGate(consented: ["com.example.app"])

        XCTAssertFalse(
            gate.allows(bundleID: nil),
            "no bundle identifier at all is refused — the nil row of the truth table")
        XCTAssertFalse(
            gate.allows(bundleID: "meeting at noon with Alice"),
            "a string that is not a bundle ID is refused — the vocabulary is the privacy boundary")
        XCTAssertFalse(
            gate.allows(bundleID: "com.example.unconsented"),
            "a valid but unconsented bundle ID is refused — consent is off by default")
        XCTAssertTrue(
            gate.allows(bundleID: "com.example.app"),
            "a consented bundle ID is the one thing allowed")
    }

    /// **The acceptance (M5), structural form.** With consent off, the metadata read may
    /// happen — the bundle ID and window title are already read by the dictate path — but the
    /// content read records **zero** calls, and the resolution is the refusal.
    ///
    /// The composed probe (D6) is the ordering contract the bootstrap wiring must satisfy:
    /// metadata (the probe's inputs — already read upstream) → the gate → the content read.
    /// The gate is the production gate and the fake records: if the composition ever consulted
    /// the content read before the gate, this test sees the call count move.
    func testConsentOffRefusesBeforeAnyContentRead() {
        let gate = ContextConsentGate(consented: [])
        let contentRead = RecordingContentRead()
        let probe = ConsentGatedProbe(gate: gate, contentRead: contentRead)

        let result = probe.resolve(
            bundleID: "com.example.app", windowTitle: "Untitled")

        XCTAssertNil(
            result,
            "an unconsented app resolves to the refusal — never to a read")
        XCTAssertEqual(
            contentRead.contentReadCount, 0,
            """
            with consent off, the content read must record zero calls: the gate declines before \
            any content read — not read-then-discard, never read
            """)
    }

    /// With consent on, the content read happens — exactly once — and the selection is carried.
    func testConsentOnAllowsExactlyOneContentRead() {
        let gate = ContextConsentGate(consented: ["com.example.app"])
        let contentRead = RecordingContentRead()
        let probe = ConsentGatedProbe(gate: gate, contentRead: contentRead)

        let result = probe.resolve(
            bundleID: "com.example.app", windowTitle: "Untitled")

        XCTAssertEqual(
            contentRead.contentReadCount, 1,
            "a consented app's content is read exactly once — the grant is for this app's selection")
        XCTAssertEqual(
            result?.selectedText, "the quick brown fox",
            "the selection read through the gate is what the snapshot carries")
    }

    /// The planted-violation control: a composed probe that consults the content read
    /// **before** the gate is caught — with consent off it still reads, and the acceptance's
    /// zero-call expectation is itself asserted to fail against it.
    ///
    /// This is what makes the ordering a contract rather than a hope: a future composition
    /// that gets the order wrong fails the acceptance test, and this control proves the
    /// detector can see the wrong order — the probe's read count is non-zero where the
    /// ordering test demands zero. The gate is still the production gate, so the planted
    /// probe's *decision* stays correct; its violation is the read, and that is the point.
    func testThePlantedViolationIsCaught() {
        let gate = ContextConsentGate(consented: [])
        let contentRead = RecordingContentRead()
        let planted = PlantedOrderViolationProbe()

        let result = planted.resolve(
            bundleID: "com.example.app", windowTitle: "Untitled",
            gate: gate, contentRead: contentRead)

        XCTAssertEqual(
            contentRead.contentReadCount, 1,
            "the planted probe consults the content read before the gate — with consent off it "
                + "still reads, and the detector sees it")
        XCTAssertNil(
            result,
            "the planted probe's decision is still the refusal — its violation is the read, "
                + "never the decision")
        XCTAssertNotEqual(
            contentRead.contentReadCount, 0,
            """
            the acceptance's zero-call expectation must fail against the planted probe: an \
            ordering that reads before the gate cannot pass testConsentOffRefusesBeforeAnyContentRead
            """)
    }
}

/// A content read the test dictates, counting its calls — a count rather than a flag, because
/// "read twice" and "read at all" are different bugs. `final class` + `@unchecked Sendable`:
/// the reads are synchronous and single-threaded in these tests — the
/// `AccessibilityContextSeamTests` double shape.
private final class RecordingContentRead: ContextAXReading, @unchecked Sendable {
    private(set) var contentReadCount = 0

    func readContext() -> RawContextRead? {
        contentReadCount += 1
        return RawContextRead(
            bundleID: "com.example.app", windowTitle: "Untitled",
            selectedText: "the quick brown fox")
    }
}

/// The composed probe (D6) — the ordering contract `bootstrap-wiring` must satisfy, owned by
/// this test: the metadata read (the probe's inputs — already read upstream, M5's scoping)
/// may happen, then the **production gate**, then the content read.
private final class ConsentGatedProbe {
    private let gate: ContextConsentGate
    private let contentRead: RecordingContentRead

    init(gate: ContextConsentGate, contentRead: RecordingContentRead) {
        self.gate = gate
        self.contentRead = contentRead
    }

    /// The metadata read happens (the inputs arrive), the gate decides, and only a consented
    /// app's content is read. The refusal is `nil` — never a read-then-discard.
    func resolve(bundleID: String?, windowTitle: String?) -> ContextSnapshot? {
        guard gate.allows(bundleID: bundleID) else { return nil }
        let selectedText = contentRead.readContext()?.selectedText
        return ContextSnapshot(
            bundleID: bundleID, windowTitle: windowTitle, selectedText: selectedText)
    }
}

/// The planted violation: the same composed shape with the order inverted — the content read
/// happens **before** the gate. Its decision is still the gate's (the production gate); its
/// read is the violation the control exists to catch.
private final class PlantedOrderViolationProbe {
    func resolve(
        bundleID: String?, windowTitle: String?,
        gate: ContextConsentGate, contentRead: RecordingContentRead
    ) -> ContextSnapshot? {
        let selectedText = contentRead.readContext()?.selectedText
        guard gate.allows(bundleID: bundleID) else { return nil }
        return ContextSnapshot(
            bundleID: bundleID, windowTitle: windowTitle, selectedText: selectedText)
    }
}