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
import VoccaUI
import XCTest

/// The egress badge's reducer contract (spec B1–B3, B5): the widget carries a persistent marker
/// whenever the active cleanup provider has `requiresNetwork == true`
/// (`PRODUCT_SPEC.md:250-264`) — **non-dismissable** while the cloud provider is active, driven
/// by a new `WidgetAction` folded at wiring time from the resolved provider (`ARCHITECTURE.md:296`
/// — "the widget reads it directly").
///
/// The badge is reducer state, not view state (`spec.md:48-51`): the whole decision table runs
/// headless, and non-dismissable is **structural** — no action in the closed set other than the
/// wiring's own `egressChanged` can touch `egress`, and no timer or session effect can clear an
/// `.active` state (the `FailsafeStateReducer` never-auto-dismiss precedent). Because the
/// provider is resolve-once, the badge is static per launch: visible for every session while an
/// LLM rung is selected, absent otherwise.
final class EgressBadgeReducerTests: XCTestCase {

    // MARK: - B1: state + action shape

    /// **B1 — the reducer state defaults `.none`.** The rules path (and the zero-network probe)
    /// is byte-for-byte today: no network provider, no badge.
    func testTheReducerStateDefaultsToNoEgress() {
        let state = WidgetReducerState()
        XCTAssertEqual(state.egress, .none)
    }

    /// **B1 — the active state carries the endpoint.** The hover copy needs to know where the
    /// text goes; the endpoint travels on the state, never the key (`byok-provider` hygiene).
    func testTheActiveStateCarriesItsEndpoint() {
        XCTAssertEqual(
            WidgetEgressState.active(endpoint: "http://localhost:11434"),
            .active(endpoint: "http://localhost:11434"))
        XCTAssertNotEqual(
            WidgetEgressState.active(endpoint: "http://localhost:11434"),
            .none)
    }

    // MARK: - B2: the reducer table

    /// **B2 — `egressChanged` sets the state.** The wiring's one fold: after resolve-once, the
    /// root sends `.active(endpoint:)` (or `.none`), and the reducer stores it.
    func testEgressChangedSetsTheState() {
        let next = WidgetStateReducer.reduce(
            WidgetReducerState(),
            action: .egressChanged(.active(endpoint: "http://localhost:11434")),
            now: .zero)
        XCTAssertEqual(next.egress, .active(endpoint: "http://localhost:11434"))
    }

    /// **B2 — no other action touches egress.** Every action in the closed set except
    /// `egressChanged` — the projection's verdicts and the timer fires — leaves an active egress
    /// exactly where it was. The badge is not a session surface.
    func testNoOtherActionTouchesEgress() {
        let active = WidgetReducerState(egress: .active(endpoint: "https://api.example.com"))
        for (action, name) in Self.everyActionExceptEgressChanged {
            let next = WidgetStateReducer.reduce(active, action: action, now: .zero)
            XCTAssertEqual(
                next.egress, .active(endpoint: "https://api.example.com"),
                "\(name) must not touch egress")
        }
    }

    // MARK: - B3: no dismissal exists

    /// **B3 — the closed set cannot dismiss an active egress.** Non-dismissable is structural:
    /// enumerating the closed set minus the wiring's own `egressChanged`, none can move `.active`
    /// to `.none` — there is no time-based transition, no dismiss action, no session effect that
    /// clears the marker while the cloud provider is active.
    func testNoActionCanDismissAnActiveEgress() {
        let active = WidgetReducerState(egress: .active(endpoint: "https://api.example.com"))
        for (action, name) in Self.everyActionExceptEgressChanged {
            let next = WidgetStateReducer.reduce(active, action: action, now: .zero)
            XCTAssertEqual(
                next.egress, .active(endpoint: "https://api.example.com"),
                "\(name) dismissed an active egress — the badge must be non-dismissable")
        }
    }

    /// **B3 — `egressChanged(.none)` is the wiring's explicit clear, and the only one.** The root
    /// sends it exactly once at launch when the resolved provider is offline; no other path
    /// exists, so an `.active` badge can only ever be launched into, never dismissed by the UI.
    func testEgressChangedNoneIsTheWiringExplicitClear() {
        let next = WidgetStateReducer.reduce(
            WidgetReducerState(egress: .active(endpoint: "https://api.example.com")),
            action: .egressChanged(.none),
            now: .zero)
        XCTAssertEqual(next.egress, .none)
    }

    // MARK: - B5: the state survives the session

    /// **B5 — the egress state survives a full session.** Timer fires (elapsed, escape hint,
    /// ceiling) and the session's projection effects (recording → transcribing → delivered →
    /// collapse → notice) leave an active egress untouched — the badge is launch-derived, never
    /// per-session, so it cannot flip-flop while the user dictates.
    func testTheEgressStateSurvivesAFullSession() {
        var state = WidgetReducerState(egress: .active(endpoint: "https://api.example.com"))
        let steps: [(WidgetAction, Duration)] = [
            (.projection(.state(.opening(targetAppName: "Slack"))), .zero),
            (.projection(.state(.recording)), .zero),
            (.timerFired(.recording), .seconds(2)),
            (.timerFired(.recording), .seconds(3)),
            (.projection(.state(.transcribing)), .zero),
            (.projection(.state(.delivered(targetAppName: "Slack"))), .seconds(4)),
            (.timerFired(.deliveredCollapse), .seconds(5)),
            (.projection(.notice(.captureUnavailable)), .seconds(5)),
            (.projection(.state(.idle)), .seconds(6)),
        ]
        for (action, now) in steps {
            state = WidgetStateReducer.reduce(state, action: action, now: now)
            XCTAssertEqual(
                state.egress, .active(endpoint: "https://api.example.com"),
                "the badge must survive the session — it is launch-derived, never per-session")
        }
    }

    // MARK: - The store fold

    /// **The store folds `setEgress` through the reducer** — the composition root's one call,
    /// after resolve-once.
    @MainActor
    func testTheStoreFoldsSetEgressOverTheInjectedClock() {
        let clock = TestClock()
        let store = WidgetStateStore(clock: clock)
        XCTAssertEqual(store.state.egress, .none)

        store.setEgress(.active(endpoint: "http://localhost:11434"))
        XCTAssertEqual(store.state.egress, .active(endpoint: "http://localhost:11434"))

        store.setEgress(.none)
        XCTAssertEqual(store.state.egress, .none)
    }

    // MARK: - Fixtures

    /// Every action in the closed set except `egressChanged` — the B2/B3 enumeration.
    private static let everyActionExceptEgressChanged: [(WidgetAction, String)] = [
        (.projection(.noChange), "noChange"),
        (.projection(.state(.idle)), "project idle"),
        (.projection(.state(.opening(targetAppName: "Slack"))), "project opening"),
        (.projection(.state(.recording)), "project recording"),
        (.projection(.state(.transcribing)), "project transcribing"),
        (.projection(.state(.delivered(targetAppName: "Slack"))), "project delivered"),
        (.projection(.notice(.captureUnavailable)), "project notice"),
        (.timerFired(.recording), "recording timer"),
        (.timerFired(.deliveredCollapse), "collapse timer"),
    ]
}
