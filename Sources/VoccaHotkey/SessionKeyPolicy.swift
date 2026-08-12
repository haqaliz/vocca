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

/// **"Escape is a session key" — the tap-policy rule that closes the route to the machine's
/// cancel path (`PRODUCT_SPEC.md:129`).**
///
/// The machine's discard path was shipped and CI-driven long before the key that reaches it: the
/// tap passed every non-binding key through (`TapEventDispatch.swift:34`), so an Escape pressed
/// during a session typed into the focused application and the session ran on. This policy is
/// that route's classification half — *which key is the session's own, and what does the focused
/// application get of it* — in the tap-policy layer, beside ``TapEventTranslation``, for the same
/// reason every tap decision lives there: it is above the C ABI, so it runs in CI, and the
/// adapter stays decision-free (the H7 seam rule).
///
/// What the answer **does** is the composition root's, and deliberately not here: cancelling
/// requires the machine's `cancel()` (the `SessionWatchdog`/`SessionMachine` path) and the
/// router's in-flight transcription task, which no single policy object holds. The root routes
/// through ``SessionKeyPolicy/propagation(for:sessionInFlight:)`` and the closed set of what is
/// in flight is that routing's to know; what is pinned here, two-sided, is the rule both halves
/// are written against.
///
/// ## The classification
///
/// A **fresh Escape key-down** is the session's cancel gesture. "Fresh" is the start rule's own
/// autorepeat exclusion, for the same reason a held key must not re-cancel: the first key-down is
/// the press, and a repeating key is a key that was already pressed. Key-ups and modifier events
/// carry no gesture of their own; the key-up of a swallowed press is inert, exactly as an unpaired
/// key-up is everywhere else in this package.
///
/// ## The disposition
///
/// - While a session or a transcription is in flight, the Escape is **swallowed**: the loop acted
///   on it, and an application that also received it would be double-acted on by one press.
/// - While nothing is in flight, it **passes through**: an Escape pressed over an idle Vocca is
///   the user's own key, in their own app — the same claim discipline the session rules apply to
///   every key Vocca does not own.
public enum SessionKeyPolicy {

    /// The session's cancel key: **Escape** — `kVK_Escape`, 53.
    ///
    /// Written out rather than imported, exactly as ``TapEventTranslation`` writes its event-type
    /// numbers: this file imports no framework, and the two-sided tests pin the number against
    /// Carbon's `kVK_Escape` rather than leaving a transcription error to a reader.
    public static let escapeKeyCode: UInt16 = 53

    /// Whether this event is the session's cancel gesture: a fresh Escape key-down.
    public static func isSessionKey(_ event: RawKeyEvent) -> Bool {
        event.kind == .keyDown && event.keyCode == escapeKeyCode && !event.isAutorepeat
    }

    /// What the focused application gets of a cancel-key event, given what is in flight.
    ///
    /// - Parameters:
    ///   - event: the observed event.
    ///   - sessionInFlight: whether a session is recording/opening or a transcription is in
    ///     flight — the routing's own answer, supplied because no single policy object holds the
    ///     machine and the router at once.
    /// - Returns: ``EventPropagation/swallow`` when the loop acted on the key, `.passThrough`
    ///   otherwise — including for every non-session key, in both states.
    public static func propagation(
        for event: RawKeyEvent, sessionInFlight: Bool
    ) -> EventPropagation {
        guard isSessionKey(event) else { return .passThrough }
        return sessionInFlight ? .swallow : .passThrough
    }
}
