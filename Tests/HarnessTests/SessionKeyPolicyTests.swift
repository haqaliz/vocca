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

import Carbon.HIToolbox
import VoccaCore
import VoccaHotkey
import XCTest

// MARK: - Fixtures

/// One event, as the tap's translation would build it — plain data, no `CGEvent` and no grant.
private func event(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet = [],
    isAutorepeat: Bool = false
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: isAutorepeat,
        timestamp: .zero)
}

/// **"Escape is a session key" — the tap-policy rule behind `PRODUCT_SPEC.md:129`, pinned
/// two-sided.**
///
/// The machine's `cancel()` and the pipeline's discard were shipped and CI-driven before the
/// route from the physical key to them existed: the tap passed every non-binding key through
/// (`TapEventDispatch.swift:34`), so an Escape during a session typed into the focused app and
/// the session ran on. This suite pins the rule that closes the route — a **fresh** Escape
/// key-down is the session's cancel gesture (`PRODUCT_SPEC.md:129`; the "fresh" is the start
/// rule's own autorepeat exclusion, for the same reason a held key must not re-cancel), and what
/// the focused application gets is decided here, in both directions, at the last decision point
/// before the sink:
///
/// - while a session or a transcription is in flight the Escape is **swallowed** — the session
///   acted on it, so the application must not be double-acted on by one press;
/// - while nothing is in flight it **passes through** — an Escape pressed over an idle Vocca is
///   the user's own key, in their own app.
///
/// The rule lives in the tap-policy layer (`VoccaHotkey`, beside ``TapEventTranslation``) for the
/// same reason every tap decision does: it is above the C ABI, so it runs in CI, and the adapter
/// stays decision-free (the H7 seam rule). What the rule's answer *does* — which half of the loop
/// it cancels — is the composition root's, where the machine's `cancel()` and the router's
/// transcription task are reachable; that routing is driven by `DictationLoopTests`.
final class SessionKeyPolicyTests: XCTestCase {

    // MARK: - The classification, in both directions

    /// A fresh Escape key-down is the cancel gesture — the one key the session owns besides its
    /// own binding's.
    func testAFreshEscapeKeyDownIsTheSessionsCancelKey() {
        XCTAssertTrue(
            SessionKeyPolicy.isSessionKey(event(.keyDown, UInt16(kVK_Escape))),
            "a fresh Escape key-down is the session's cancel gesture")
    }

    /// Everything else passes through — the closed set of near-misses, each a separate row so a
    /// mutation has to be made in a named direction rather than in an unnamed one.
    func testNothingElseIsTheSessionsCancelKey() {
        let escape = UInt16(kVK_Escape)
        let notTheCancelKey: [(label: String, event: RawKeyEvent)] = [
            (
                "an autorepeat of a held Escape is not a fresh press",
                event(.keyDown, escape, isAutorepeat: true)
            ),
            (
                "the key-up of a swallowed press is inert — the gesture is the press",
                event(.keyUp, escape)
            ),
            (
                "a modifier event on Escape is not a gesture",
                event(.flagsChanged, escape)
            ),
            (
                "the hotkey's own key is the machine's claim, not this policy's",
                event(.keyDown, 49)
            ),
            (
                "an ordinary letter is the user's",
                event(.keyDown, 0)
            ),
            (
                "a key-up of the hotkey is the session rules' business",
                event(.keyUp, 49)
            ),
        ]

        for row in notTheCancelKey {
            XCTAssertFalse(
                SessionKeyPolicy.isSessionKey(row.event),
                "\(row.label): \(row.event.kind) on key code \(row.event.keyCode) must not be "
                    + "the session's cancel key")
        }
    }

    // MARK: - The disposition, in both directions

    /// While something is in flight, the session's Escape is claimed — the application must not
    /// receive a key the session acted on.
    func testTheSessionKeyIsSwallowedWhileSomethingIsInFlight() {
        XCTAssertEqual(
            SessionKeyPolicy.propagation(
                for: event(.keyDown, UInt16(kVK_Escape)), sessionInFlight: true),
            .swallow,
            "an Escape the session acted on must not also reach the focused application")
    }

    /// Over an idle Vocca, an Escape is the user's own — a tool that eats a key it did not claim
    /// makes the whole machine feel broken.
    func testTheSessionKeyPassesThroughWhenNothingIsInFlight() {
        XCTAssertEqual(
            SessionKeyPolicy.propagation(
                for: event(.keyDown, UInt16(kVK_Escape)), sessionInFlight: false),
            .passThrough,
            "an idle Escape is the user's own key, in their own app")
    }

    /// A non-session key passes through in **both** states — the two-sided pin's complement: a
    /// routing that swallowed any other key whenever a session ran would be eating the user's
    /// keyboard in exactly the case the session rules need events to keep flowing (stop rule (c)).
    func testANonSessionKeyPassesThroughInBothStates() {
        for sessionInFlight in [false, true] {
            XCTAssertEqual(
                SessionKeyPolicy.propagation(
                    for: event(.keyDown, 49), sessionInFlight: sessionInFlight),
                .passThrough,
                "a non-session key must pass through whether or not something is in flight")
        }
    }

    /// The distinction form of the two-sided pin: a single answer for both states satisfies every
    /// equality above — and is the mutation that either leaks a claimed Escape into the app or
    /// swallows the user's idle one.
    func testTheTwoDispositionsAreNotCollapsedIntoOne() {
        let inFlight = SessionKeyPolicy.propagation(
            for: event(.keyDown, UInt16(kVK_Escape)), sessionInFlight: true)
        let idle = SessionKeyPolicy.propagation(
            for: event(.keyDown, UInt16(kVK_Escape)), sessionInFlight: false)

        XCTAssertNotEqual(
            inFlight, idle,
            "one disposition for both states is a mutation hiding behind the equalities")
    }
}
