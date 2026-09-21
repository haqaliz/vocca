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
import VoccaUI
import XCTest

/// The confirmation card's reducer contract (`confirmation-card`, spec acceptances 1-7): the
/// gate's `confirmationRequired` sentence as a widget surface — the C12 `contextChanged` shape,
/// a reducer row, never a wiring courtesy.
///
/// The card is the first human-in-the-loop safety surface: the gate returned
/// `.confirmationRequired(summary)` and nothing rendered it. What is pinned here is the reducer's
/// side of the promise — present replaces (one card at a time, the new signal's generation is the
/// current card's), the card survives every adoption exactly as the egress/context badges do, no
/// timer or projection clears it, and only the explicit dismiss/decline/confirm actions end it.
///
/// The rendered SwiftUI is executed by nothing in CI (the window-server precedent, exactly like
/// ``WidgetView``): CI asserts the reducer, the store, and the copy pins. The panel is glue; the
/// decision table is not.
///
/// M4a: per-invocation only. The suite pins the absence structurally — no affordance state exists
/// in the reducer or the type (a source scan over `WidgetStateReducer.swift` and
/// `WidgetConfirmationState.swift`), and no such string exists in `WidgetCopy.swift` (a source
/// scan, the copy pin half of the acceptance).
final class WidgetConfirmationStateTests: XCTestCase {

    /// The fixture signal the suite presents — a destructive sentence, since the card exists
    /// to gate exactly those.
    private func signal(generation: Int, sentence: String = "Permanently delete 12 entries.") -> WidgetConfirmationSignal {
        WidgetConfirmationSignal(
            sentence: sentence,
            providerID: "audit",
            toolID: "clear",
            generation: generation)
    }

    private func fold(
        _ steps: [(action: WidgetAction, now: Duration)],
        from state: WidgetReducerState = WidgetReducerState()
    ) -> WidgetReducerState {
        steps.reduce(state) { WidgetStateReducer.reduce($0, action: $1.action, now: $1.now) }
    }

    // MARK: - Acceptance 1: the exact sentence

    /// Presenting a confirmation renders the exact sentence — the reducer state carries the
    /// provider's words verbatim, leading and trailing whitespace and all. The sentence is the
    /// entire content of the card's body (M5a); nothing here may trim, re-wrap or paraphrase it.
    func testPresentingRendersTheExactSentenceVerbatim() {
        let sentence = "  Permanently delete 12 entries. This cannot be undone.  "
        let after = fold([(.confirmation(signal(generation: 1, sentence: sentence)), .zero)])
        XCTAssertEqual(after.confirmation?.signal.sentence, sentence)
    }

    /// The store's present entry point folds the same card — the wiring calls
    /// `presentActionConfirmation`, and the sentence that reaches the reducer state is the
    /// sentence the panel will show.
    @MainActor
    func testTheStorePresentsTheExactSentence() {
        let sentence = "Permanently delete 12 entries. This cannot be undone."
        let clock = TestClock()
        let store = WidgetStateStore(clock: clock)
        store.presentActionConfirmation(signal(generation: 1, sentence: sentence))
        XCTAssertEqual(store.state.confirmation?.signal.sentence, sentence)
    }

    // MARK: - Acceptance 2: the card survives; only the explicit clears end it

    /// The card survives every adoption — recording, conversing, delivered, idle, a notice —
    /// exactly as the egress/context badges do: the `adopting` carry is the C12 shape, and the
    /// notice branch must carry the card forward like the badges.
    func testTheCardSurvivesEveryAdoption() {
        let presented = fold([(.confirmation(signal(generation: 1)), .zero)])
        let adoptions: [WidgetAction] = [
            .projection(.state(.opening(targetAppName: "Slack"))),
            .projection(.state(.recording)),
            .projection(.state(.transcribing)),
            .projection(.state(.delivered(targetAppName: "Slack"))),
            .projection(.state(.conversing(phase: .listening))),
            .projection(.state(.conversing(phase: .speaking))),
            .projection(.state(.idle)),
            .projection(.notice(.captureUnavailable)),
        ]
        for adoption in adoptions {
            let after = fold([(adoption, .zero)], from: presented)
            XCTAssertEqual(
                after.confirmation?.signal.generation, 1,
                "\(adoption) must not clear the card")
        }
    }

    /// No timer collapses the card — the recording tick and the delivered-collapse fire both pass
    /// over a presented card without touching it. A confirm needs no timer race: the collapse that
    /// ends DELIVERED must end DELIVERED alone.
    func testNoTimerCollapsesTheCard() {
        let presented = fold([
            (.projection(.state(.recording)), .zero),
            (.confirmation(signal(generation: 1)), .zero),
        ])
        let afterTick = fold([(.timerFired(.recording), .seconds(3))], from: presented)
        XCTAssertEqual(
            afterTick.confirmation?.signal.generation, 1,
            "the recording timer must not clear the card")

        let delivered = fold([
            (.projection(.state(.recording)), .zero),
            (.confirmation(signal(generation: 1)), .zero),
            (.projection(.state(.delivered(targetAppName: "Slack"))), .seconds(1)),
        ])
        let afterCollapse = fold(
            [(.timerFired(.deliveredCollapse), .seconds(2))], from: delivered)
        XCTAssertEqual(
            afterCollapse.state, .idle,
            "the collapse ends DELIVERED as always")
        XCTAssertEqual(
            afterCollapse.confirmation?.signal.generation, 1,
            "the delivered collapse must not take the card with it")
    }

    // MARK: - Acceptance 3: decline/dismiss clears; a cleared card cannot confirm

    /// The explicit clear ends the card: the dismiss fold is the one writer that removes it
    /// (decline is the same fold at the reducer — the semantic difference lives in the wiring's
    /// executor call, not in the state).
    func testTheExplicitDismissClearsTheCard() {
        let presented = fold([(.confirmation(signal(generation: 1)), .zero)])
        let after = fold([(.confirmationDismissed, .zero)], from: presented)
        XCTAssertNil(after.confirmation)
    }

    /// A cleared card's confirm closure is never invoked — pinned by the store refusing the
    /// confirm for a card that is gone: after `dismissActionConfirmation`, the wiring's captured
    /// signal cannot pass the store's check, so no gate call happens (no executor, no gate —
    /// asserted at the store, the only seam the wiring has).
    @MainActor
    func testAClearedCardsConfirmIsRefused() {
        let clock = TestClock()
        let store = WidgetStateStore(clock: clock)
        store.presentActionConfirmation(signal(generation: 1))
        store.dismissActionConfirmation()
        XCTAssertNil(store.state.confirmation)
        XCTAssertFalse(
            store.confirmActionConfirmation(signal(generation: 1)),
            "a confirm for a cleared card must be refused — no gate call")
    }

    // MARK: - Acceptance 4: a stale card cannot confirm

    /// The generation mismatch is the card-level stale guard: a second presentation replaces the
    /// first, and the first's signal can no longer confirm — the store refuses by generation, and
    /// the refused confirm leaves the current card untouched (the human can still decide on it).
    @MainActor
    func testAStaleCardCannotConfirm() {
        let clock = TestClock()
        let store = WidgetStateStore(clock: clock)
        store.presentActionConfirmation(signal(generation: 1))
        store.presentActionConfirmation(signal(generation: 2))
        XCTAssertEqual(store.state.confirmation?.signal.generation, 2)

        XCTAssertFalse(
            store.confirmActionConfirmation(signal(generation: 1)),
            "the replaced card's generation must not confirm")
        XCTAssertEqual(
            store.state.confirmation?.signal.generation, 2,
            "a refused confirm must not clear the current card")

        XCTAssertTrue(
            store.confirmActionConfirmation(signal(generation: 2)),
            "the current card's generation confirms")
        XCTAssertNil(
            store.state.confirmation,
            "an accepted confirm clears the card in the same fold")
    }

    // MARK: - Acceptance 5: one card at a time

    /// One card at a time: a second presentation replaces the first — the state carries only the
    /// newest signal, and the first's closure is never invoked because the store refuses its
    /// generation (the panel renders only the current card's buttons, which is the structural
    /// half; this is the enforceable half, without the wiring).
    func testASecondPresentationReplacesTheFirst() {
        let after = fold([
            (.confirmation(signal(generation: 1, sentence: "First sentence.")), .zero),
            (.confirmation(signal(generation: 2, sentence: "Second sentence.")), .zero),
        ])
        XCTAssertEqual(after.confirmation?.signal.generation, 2)
        XCTAssertEqual(after.confirmation?.signal.sentence, "Second sentence.")
    }

    /// A fresh `WidgetReducerState` carries no card — the surface defaults to nothing pending.
    func testTheInitialStateCarriesNoCard() {
        XCTAssertNil(WidgetReducerState().confirmation)
    }

    // MARK: - Acceptance 6: M4a — the affordance does not exist

    /// **No affordance state exists in the reducer or the type (M4a).** The card is per-invocation
    /// only: the reducer state carries no "remember"/"ask again" row and neither type file names
    /// one — scanned over the sources themselves (the `SettingsCopyTests` shape), comments
    /// stripped, so a row added later breaks this test rather than shipping silently.
    func testNoAskAgainStateExistsInTheReducerOrTheType() throws {
        let root = PackageRootLocator.find(from: #filePath)
        for relativePath in [
            "Sources/VoccaUI/WidgetStateReducer.swift",
            "Sources/VoccaUI/WidgetConfirmationState.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            let stripped = SwiftSourceScanner.stripComments(from: source)
            let lower = stripped.lowercased()
            for forbidden in ["askagain", "dontask", "remember"] {
                XCTAssertFalse(
                    lower.contains(forbidden),
                    "\(relativePath) must carry no \(forbidden) affordance row (M4a)")
            }
        }
        let reducer = try String(
            contentsOf: root.appendingPathComponent("Sources/VoccaUI/WidgetStateReducer.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            reducer.contains("confirmation"),
            "the scan must find the card's reducer row — a rename would make this vacuous")
    }

    /// **No such string exists in the copy (M4a, the copy pin).** `WidgetCopy` is the only place
    /// the card's words live; an affordance string added there fails this scan. Non-vacuous: the
    /// scan asserts the pinned card rows are present in the same file.
    func testNoAskAgainStringExistsInTheCopy() throws {
        let source = try String(
            contentsOf: PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaUI/WidgetCopy.swift"),
            encoding: .utf8)
        let stripped = SwiftSourceScanner.stripComments(from: source)
        let lower = stripped.lowercased()
        for forbidden in ["don't ask", "don’t ask", "ask again", "remember"] {
            XCTAssertFalse(
                lower.contains(forbidden),
                "WidgetCopy must contain no '\(forbidden)' string (M4a)")
        }
        XCTAssertTrue(
            stripped.contains("Confirm"),
            "the scan must find the card's pinned rows — a rename would make this vacuous")
    }

    // MARK: - The copy pins

    /// The card's copy is pinned, exactly as the pill's is: the heading, the provider/tool
    /// identity line, and the two button labels. The sentence itself is the provider's own text
    /// (acceptance 1) and has no copy row.
    func testTheCopyPinsTheCardSurface() {
        XCTAssertEqual(WidgetCopy.confirmationHeading, "Actions")
        XCTAssertEqual(
            WidgetCopy.confirmationProviderLabel(providerID: "audit", toolID: "clear"),
            "audit · clear")
        XCTAssertEqual(WidgetCopy.confirmationConfirmButton, "Confirm")
        XCTAssertEqual(WidgetCopy.confirmationDeclineButton, "Decline")
    }

    // MARK: - The closed set

    /// **The closed-set pin** — `WidgetAction` is exactly
    /// `{projection, timerFired, partial, egressChanged, contextChanged, confirmation,
    /// confirmationDismissed}`: an exhaustive switch without a `default:` over the seven cases,
    /// so an eighth case breaks this test at compile time before it can hide a transition no
    /// action can carry (the `SessionEffect` discipline, grown to seven by this aspect).
    func testTheActionSetStaysClosedAtSeven() {
        let actions: [WidgetAction] = [
            .projection(.noChange),
            .timerFired(.recording),
            .partial("a provisional partial"),
            .egressChanged(.none),
            .contextChanged(
                .init(consentActive: false, secureInputActive: false, appName: nil)),
            .confirmation(
                .init(sentence: "Permanently delete 12 entries.", providerID: "audit",
                      toolID: "clear", generation: 1)),
            .confirmationDismissed,
        ]
        for action in actions {
            switch action {
            case .projection: break
            case .timerFired: break
            case .partial: break
            case .egressChanged: break
            case .contextChanged: break
            case .confirmation: break
            case .confirmationDismissed: break
            }
        }
        XCTAssertEqual(actions.count, 7, "the set stays exactly the seven closed cases")
    }
}