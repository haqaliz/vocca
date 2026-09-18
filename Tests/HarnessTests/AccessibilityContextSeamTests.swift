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

/// Pins the `AccessibilityContext` adapter's contract (the `accessibility-context` aspect, PRD
/// M2/M5b, R1-R3), written **before the type exists** — every reference below is a compile pin,
/// the mode-machine precedent for a new adapter.
///
/// The vocabulary these tests compile against is the **merged** `context-seam`'s:
/// ``ContextProvider``'s `resolveCurrent()` is synchronous and non-throwing (`ContextProvider.swift:47`
/// — "a failure resolves to an empty snapshot, never throws — expressed in the type system").
/// D1 pinned the resolution `async`; the plan's Setup governs — "the exact signature is
/// `context-seam`'s", so this aspect compiles against what the seam shipped, and the module's
/// internal read seams (`ContextAXReading`, `ContextSecureInputReading`) are synchronous for the
/// same reason, with their AX calls confined to a serial queue under a per-call timeout in the
/// permitted file.
///
/// What is pinned here, over the stub reads:
///
/// - resolution carries the raw answers through to the ``ContextSnapshot`` verbatim;
/// - a failed **or** timed-out read resolves to the all-absent snapshot, never a throw (R1);
/// - `""` is present-but-empty and passes through as itself;
/// - Secure Input refusal resolves to the empty snapshot, **ordered before the AX read is ever
///   consulted** (M5b/D3 — for a password field, never *ask*);
/// - the adapter is `Sendable` end to end.
final class AccessibilityContextSeamTests: XCTestCase {

    /// A raw context read the test dictates, counting its calls — a count rather than a flag,
    /// because "consulted twice" and "consulted at all" are different bugs. `final class` +
    /// `@unchecked Sendable`: the reads are synchronous and the adapter's witness is
    /// `nonisolated` (single-threaded resolution, no race) — the `EphemeralSettingsStore`
    /// shape for a synchronous seam double.
    private final class StubContextAXRead: ContextAXReading, @unchecked Sendable {
        private let answer: RawContextRead?
        private(set) var readCount = 0

        init(answer: RawContextRead? = nil) {
            self.answer = answer
        }

        func readContext() -> RawContextRead? {
            readCount += 1
            return answer
        }
    }

    /// A Secure Input read the test dictates — the same shape as ``StubContextAXRead``.
    private final class StubContextSecureInputRead: ContextSecureInputReading, @unchecked Sendable {
        private let active: Bool
        private(set) var readCount = 0

        init(active: Bool = false) {
            self.active = active
        }

        func isSecureInputActive() -> Bool {
            readCount += 1
            return active
        }
    }

    /// The adapter under test — `com.apple.Notes` with a title and a selection, Secure Input
    /// inactive.
    private func notesContext() -> AccessibilityContext {
        AccessibilityContext(
            axRead: StubContextAXRead(
                answer: RawContextRead(
                    bundleID: "com.apple.Notes", windowTitle: "Untitled",
                    selectedText: "the quick brown fox")),
            secureInputRead: StubContextSecureInputRead())
    }

    // MARK: - Compile pins

    /// `AccessibilityContext` satisfies the seam, and the seam's input is nothing — a provider
    /// is handed across an existential the same way the composition root hands it.
    func testAccessibilityContextConformsToTheContextProviderSeam() {
        func requireContextProvider(_ provider: any ContextProvider) -> any ContextProvider {
            provider
        }

        let provider = requireContextProvider(notesContext())
        XCTAssertEqual(
            provider.resolveCurrent(),
            ContextSnapshot(
                bundleID: "com.apple.Notes", windowTitle: "Untitled",
                selectedText: "the quick brown fox"),
            "the adapter must satisfy the seam and resolve the stub's answers")
    }

    /// The snapshot's members are exactly the seam's three — `bundleID`, `windowTitle`,
    /// `selectedText` — and nothing else is carried. A fourth member would fail this file to
    /// compile at the member reference below.
    func testTheSnapshotCarriesExactlyTheSeamsThreeMembers() {
        let snapshot = ContextSnapshot(bundleID: "a", windowTitle: "b", selectedText: "c")
        XCTAssertEqual(snapshot.bundleID, "a")
        XCTAssertEqual(snapshot.windowTitle, "b")
        XCTAssertEqual(snapshot.selectedText, "c")
    }

    // MARK: - Resolution behaviour over the stub reads

    /// The stub answers `{com.apple.Notes, "Untitled", "the quick brown fox"}` — the snapshot
    /// carries all three, translated and nothing more.
    func testResolutionCarriesTheStubAnswers() {
        XCTAssertEqual(
            notesContext().resolveCurrent(),
            ContextSnapshot(
                bundleID: "com.apple.Notes", windowTitle: "Untitled",
                selectedText: "the quick brown fox"))
    }

    /// A failed read (`nil` at the seam) resolves to the all-absent snapshot — and never throws
    /// (R1: "returns an empty snapshot rather than throwing on failure").
    func testAFailedReadResolvesToTheEmptySnapshot() {
        let context = AccessibilityContext(
            axRead: StubContextAXRead(answer: nil),
            secureInputRead: StubContextSecureInputRead())
        XCTAssertEqual(
            context.resolveCurrent(),
            ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: nil),
            "a failed read is the empty snapshot — the honest 'nothing to report', never a throw")
    }

    /// A timed-out read is the raw file's translation property — a nil answer at the seam — so
    /// the CI-testable contract is exactly that nil → empty. The 0.5 s constant itself is
    /// asserted by review and the two-sided pin, recorded like `AXSource`'s.
    func testATimedOutReadResolvesToTheEmptySnapshot() {
        let context = AccessibilityContext(
            axRead: StubContextAXRead(answer: nil),
            secureInputRead: StubContextSecureInputRead())
        XCTAssertEqual(
            context.resolveCurrent(),
            ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: nil),
            "a timed-out read answers nil at the seam, and nil resolves to the empty snapshot")
    }

    /// `""` is present-but-empty, not "no selection": it passes through as `""`.
    func testAnEmptySelectionResolvesToAnEmptySelection() {
        let context = AccessibilityContext(
            axRead: StubContextAXRead(
                answer: RawContextRead(
                    bundleID: "com.apple.Notes", windowTitle: "Untitled", selectedText: "")),
            secureInputRead: StubContextSecureInputRead())
        XCTAssertEqual(
            context.resolveCurrent().selectedText, "",
            "a collapsed selection is present-but-empty and must not be conflated with nil")
    }

    /// Secure Input refusal resolves to the empty snapshot — a password field reports nothing.
    func testSecureInputRefusalReturnsTheEmptySnapshot() {
        let context = AccessibilityContext(
            axRead: StubContextAXRead(
                answer: RawContextRead(
                    bundleID: "com.apple.Notes", windowTitle: "Untitled",
                    selectedText: "secret")),
            secureInputRead: StubContextSecureInputRead(active: true))
        XCTAssertEqual(
            context.resolveCurrent(),
            ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: nil),
            "Secure Input active means nothing may be read — the empty snapshot")
    }

    /// The refusal is ordered **before** the AX read (D3): for a password field, never *ask*.
    /// The recording fake's call count is zero when the secure-input fake answers true.
    func testSecureInputRefusalNeverConsultsTheAXRead() {
        let axRead = StubContextAXRead(
            answer: RawContextRead(
                bundleID: "com.apple.Notes", windowTitle: "Untitled", selectedText: "secret"))
        let context = AccessibilityContext(
            axRead: axRead, secureInputRead: StubContextSecureInputRead(active: true))

        _ = context.resolveCurrent()

        XCTAssertEqual(
            axRead.readCount, 0,
            "when Secure Input is active the AX read must never be consulted — the refusal "
                + "happens before any AX call")
    }

    /// The adapter is `Sendable` across an actor boundary — the strict-concurrency build is the
    /// real assertion; this test pins the claim in code by crossing a `Sendable` requirement.
    func testTheAdapterIsSendableAcrossAnActorBoundary() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        let sent = requireSendable(notesContext())
        XCTAssertEqual(sent.resolveCurrent().bundleID, "com.apple.Notes")
    }
}