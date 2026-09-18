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

import VoccaCore
import XCTest

/// The context seam: the `ContextProvider` protocol (the C12 PRD M1 seam) as code, with the
/// synchronous, non-throwing, plain-data handoff contract (PRD R1) and the `NullContext`
/// default pinned.
///
/// Where ``ReplySeamTests`` pinned the reply seam's shape and behaviour, this suite pins the
/// context seam's — against the seam itself and its one shipped implementation. **One**
/// implementation ships here, not two: the seam doctrine's two-implementations guardrail
/// (`CAPABILITY_ROADMAP.md:432`) is met across aspects — ``NullContext`` lives in `VoccaCore`,
/// and `AccessibilityContext` (every AX read) is `accessibility-context`'s aspect in the new
/// `VoccaContext` module (`ARCHITECTURE.md:151,281`). Everything here is a claim about the seam
/// as `accessibility-context` (the adapter) and `bootstrap-wiring` (the composition) will find
/// it:
///
/// - the seam is a `Sendable` protocol with exactly one requirement,
///   `func resolveCurrent() -> ContextSnapshot` — synchronous and non-throwing (R1: a failure
///   resolves to an empty snapshot, never throws);
/// - `NullContext` resolves to the all-nil snapshot — "empty" means every field absent — with
///   no input, no environment, and no hidden state (the observable half of "reads nothing";
///   the structural half is the empty `CoreBoundaryTests` allow-list: no AX name can compile in
///   the module);
/// - the vocabulary is three optional fields (`bundleID`, `windowTitle`, `selectedText`) with
///   distinct nil-vs-empty semantics — `nil` is absent (the `NullContext` case), `""` is
///   present-but-empty (a titleless window) — pinned by `Equatable` so the later adapter's
///   semantics cannot blur them;
/// - callers never branch on implementation: the seam is consumed as `any ContextProvider`
///   throughout, and the fixed provider below proves the protocol is what a caller speaks.
final class ContextSeamTests: XCTestCase {

    /// The seam exists as a `Sendable` protocol with exactly one requirement, and the shipped
    /// default exists as a type named `NullContext` — the compile pin `ReplySeamTests` applies:
    /// if the protocol's shape is ever weakened or renamed, this stops compiling rather than
    /// coercing. The `requireSendable` pin makes the `Sendable` conformance a compile
    /// obligation — the house's aversion to `@unchecked Sendable` is structural here, not
    /// stylistic.
    func testTheSeamIsASendableProtocolWithOneResolveRequirement() {
        func requireProvider(_ provider: any ContextProvider) -> any ContextProvider {
            provider
        }
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        let provider: any ContextProvider = requireSendable(
            requireProvider(NullContext()))

        let snapshot: ContextSnapshot = provider.resolveCurrent()
        XCTAssertEqual(snapshot.bundleID, nil)
        XCTAssertEqual(snapshot.windowTitle, nil)
        XCTAssertEqual(snapshot.selectedText, nil)
    }

    /// The `NullContext` contract's committed row: an empty snapshot is *all-absent* — every
    /// field nil, never `""`. The default reads nothing, so there is nothing to report.
    func testNullContextResolvesAnEmptySnapshot() {
        let provider: any ContextProvider = NullContext()

        let snapshot = provider.resolveCurrent()

        XCTAssertNil(snapshot.bundleID)
        XCTAssertNil(snapshot.windowTitle)
        XCTAssertNil(snapshot.selectedText)
    }

    /// The default is deterministic — two calls return equal snapshots. No hidden state, no
    /// environment: the observable half of "reads nothing" is that the answer cannot change.
    func testNullContextIsDeterministic() {
        let provider: any ContextProvider = NullContext()

        XCTAssertEqual(provider.resolveCurrent(), provider.resolveCurrent())
    }

    /// `resolveCurrent()` is non-throwing by signature and takes no arguments — the compile
    /// pin: a plain call with no `try` and an empty argument list. R1 (`prd.md:166-170`)
    /// expressed in the type system: a seam that never throws cannot be caught mid-turn, and
    /// the failure value is the empty snapshot.
    func testNullContextNeverThrowsAndNeedsNoInput() {
        let provider: any ContextProvider = NullContext()

        let snapshot = provider.resolveCurrent()
        XCTAssertNil(snapshot.bundleID)
    }

    /// The `Sendable` conformance is a compile obligation — plain data, automatic conformance,
    /// never `@unchecked`.
    func testNullContextIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        _ = requireSendable(NullContext())
    }

    /// Callers never branch on implementation: the driver below is written against the seam's
    /// existential alone — the shipped default is invisible to it — and the fixed provider
    /// proves the protocol (not a concrete implementation) is what a caller speaks. A caller
    /// that names `NullContext` at a decision point would not satisfy this shape (the Phase-3
    /// family lint confines that name to its file for the same reason).
    func testACallerResolvesThroughTheSeamOnly() {
        struct FixedContextProvider: ContextProvider {
            func resolveCurrent() -> ContextSnapshot {
                ContextSnapshot(bundleID: "dev.vocca.Fixed", windowTitle: nil, selectedText: nil)
            }
        }

        func drive(_ provider: any ContextProvider) -> String? {
            provider.resolveCurrent().bundleID
        }

        let provider: any ContextProvider = FixedContextProvider()
        XCTAssertEqual(
            drive(provider), "dev.vocca.Fixed",
            "the caller's contract is the protocol — the answer flows through the existential, "
                + "and the caller never names the implementation")
    }

    /// The vocabulary crosses actor boundaries and tests assert over it — `Sendable` by
    /// construction, and `Equatable` so snapshots compare by value.
    func testContextSnapshotIsSendableAndEquatable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        let first = requireSendable(
            ContextSnapshot(bundleID: "dev.vocca.Vocca", windowTitle: "Vocca", selectedText: "hi"))
        let second = ContextSnapshot(bundleID: "dev.vocca.Vocca", windowTitle: "Vocca", selectedText: "hi")
        XCTAssertEqual(first, second)
    }

    /// The D3 semantics pinned: for each of the three fields, a nil-valued snapshot differs
    /// from a `""`-valued one. `nil` is absent (nothing focused / no title / no selection);
    /// `""` is present-but-empty (a window with no title). The later adapter returns whichever
    /// is honest; the seam's consumers must not conflate them.
    func testContextSnapshotDistinguishesAbsentFromEmpty() {
        let absent = ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: nil)
        let emptyBundleID = ContextSnapshot(bundleID: "", windowTitle: nil, selectedText: nil)
        let emptyWindowTitle = ContextSnapshot(bundleID: nil, windowTitle: "", selectedText: nil)
        let emptySelectedText = ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: "")

        XCTAssertNotEqual(absent, emptyBundleID)
        XCTAssertNotEqual(absent, emptyWindowTitle)
        XCTAssertNotEqual(absent, emptySelectedText)
    }

    /// Each field round-trips through the memberwise init — a test builds these by hand, so
    /// the init is public and free of defaults that could hide a missing adapter read.
    func testContextSnapshotFieldsAreReadBack() {
        let snapshot = ContextSnapshot(
            bundleID: "com.example.App", windowTitle: "A Window", selectedText: "some selection")

        XCTAssertEqual(snapshot.bundleID, "com.example.App")
        XCTAssertEqual(snapshot.windowTitle, "A Window")
        XCTAssertEqual(snapshot.selectedText, "some selection")
    }
}