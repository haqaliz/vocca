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

/// The context badge's reducer contract (`widget-indicator` D1/D2): the persistent badge that
/// shows while Vocca reads the focused app's content (`context-provider` M8) — the signal →
/// state transition table, the two rules the reducer owns, the carry-forward the egress badge
/// established, and the one closed `WidgetAction` case that carries it.
///
/// The badge never lights on a Secure Input field (M5b/M8): `secureInputActive` is a **reducer
/// row** over the raw signal facts — the wiring folds a signal, the reducer decides — so the
/// never-on guarantee lives in the tested half. And the kill (M9) is **one fold**: the wiring
/// folds a `consentActive: false` signal and the badge clears in that same fold — no
/// intermediate state, no timer (D2).
final class WidgetContextReducerTests: XCTestCase {

    private func fold(
        _ steps: [(action: WidgetAction, now: Duration)],
        from state: WidgetReducerState = WidgetReducerState()
    ) -> WidgetReducerState {
        steps.reduce(state) { WidgetStateReducer.reduce($0, action: $1.action, now: $1.now) }
    }

    // MARK: - The badge contract

    /// The badge lights iff consent is active and Secure Input is not: a signal with both
    /// consent and a clean keyboard folds `.reading(appName:)` in one fold.
    func testConsentActiveAndNotSecureInputLightsTheBadge() {
        let after = fold([
            (.contextChanged(
                .init(consentActive: true, secureInputActive: false, appName: "Slack")), .zero),
        ])
        XCTAssertEqual(after.context, .reading(appName: "Slack"))
    }

    /// **The M5b/M8 row** — the badge never lights for a Secure Input field: the app is
    /// consented, the field is a password field, and the badge must not light — and a signal
    /// with `secureInputActive: true` from an already-`.reading` state clears to `.off` in the
    /// same fold (the badge never lies while a password field is focused).
    func testSecureInputNeverLightsTheBadge() {
        let fromOff = fold([
            (.contextChanged(
                .init(consentActive: true, secureInputActive: true, appName: "Slack")), .zero),
        ])
        XCTAssertEqual(fromOff.context, .off, "a consented app behind Secure Input must not light")

        let lit = fold([
            (.contextChanged(
                .init(consentActive: true, secureInputActive: false, appName: "Slack")), .zero),
        ])
        let cleared = fold([
            (.contextChanged(
                .init(consentActive: true, secureInputActive: true, appName: "Slack")), .zero),
        ], from: lit)
        XCTAssertEqual(
            cleared.context, .off,
            "Secure Input mid-turn clears a reading badge in the same fold — never a stale light")
    }

    /// No consent, whatever else the signal says, folds `.off`.
    func testNoConsentStaysOff() {
        let cases: [WidgetContextSignal] = [
            .init(consentActive: false, secureInputActive: false, appName: "Slack"),
            .init(consentActive: false, secureInputActive: true, appName: "Slack"),
            .init(consentActive: false, secureInputActive: false, appName: nil),
        ]
        for signal in cases {
            let after = fold([(.contextChanged(signal), .zero)])
            XCTAssertEqual(after.context, .off, "\(signal) must fold off without consent")
        }
    }

    /// **The M9 mid-turn leg** — the kill is one fold of the signal: from `.reading`, a
    /// `consentActive: false` fold lands `.off` immediately — no intermediate state, no timer
    /// needed; the fold is the only writer.
    func testTheKillFoldClearsTheBadgeInTheSameFold() {
        let lit = fold([
            (.contextChanged(
                .init(consentActive: true, secureInputActive: false, appName: "Slack")), .zero),
        ])
        let after = fold([
            (.contextChanged(
                .init(consentActive: false, secureInputActive: false, appName: "Slack")), .zero),
        ], from: lit)
        XCTAssertEqual(after.context, .off, "the kill clears the badge in the same fold")
    }

    /// **The carry-forward pin (the egress precedent)** — a session fold never clears an active
    /// badge: the badge is derived from a folded fact, not from the session, so a projection
    /// adoption and a projection notice must both carry `.reading` forward.
    func testASessionFoldNeverClearsAnActiveBadge() {
        let lit = fold([
            (.contextChanged(
                .init(consentActive: true, secureInputActive: false, appName: "Slack")), .zero),
        ])
        let afterAdoption = fold([
            (.projection(.state(.opening(targetAppName: "Slack"))), .zero),
        ], from: lit)
        XCTAssertEqual(
            afterAdoption.context, .reading(appName: "Slack"),
            "a session fold must not clear the badge")
        let afterNotice = fold([
            (.projection(.notice(.captureUnavailable)), .zero),
        ], from: lit)
        XCTAssertEqual(
            afterNotice.context, .reading(appName: "Slack"),
            "a session notice must not clear the badge")
    }

    /// A fresh `WidgetReducerState` carries `.off` — the badge defaults dark.
    func testTheInitialStateIsOff() {
        XCTAssertEqual(WidgetReducerState().context, .off)
    }

    // MARK: - The closed set

    /// **The closed-set pin (D1)** — `WidgetAction` is exactly
    /// `{projection, timerFired, partial, egressChanged, contextChanged, confirmation,
    /// confirmationDismissed}`: an exhaustive switch without a `default:` over the seven cases,
    /// so an eighth case breaks this test at compile time before it can hide a transition no
    /// signal can carry (the `SessionEffect` discipline; the two confirmation cases grew the set
    /// with `confirmation-card`, whose own closed-set test pins the same seven).
    func testTheActionSetStaysClosed() {
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

    // MARK: - The store fold

    /// The store's context fold — the `setEgress` shape: `setContext(_:)` folds the signal
    /// through the reducer with the injected clock's reading, the only path that changes
    /// ``WidgetReducerState/context``.
    @MainActor
    func testTheStoreFoldsContextLikeEgress() {
        let clock = TestClock()
        let store = WidgetStateStore(clock: clock)
        XCTAssertEqual(store.state.context, .off)

        store.setContext(.init(consentActive: true, secureInputActive: false, appName: "Slack"))
        XCTAssertEqual(store.state.context, .reading(appName: "Slack"))

        store.setContext(.init(consentActive: false, secureInputActive: false, appName: "Slack"))
        XCTAssertEqual(store.state.context, .off, "the kill fold through the store clears")
    }
}