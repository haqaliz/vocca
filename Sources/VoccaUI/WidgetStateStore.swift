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

import Combine
import Foundation
import VoccaCore

/// The live widget's observable state: the `@MainActor` store the later views observe, folding
/// the projection's verdicts and the timer fires through ``WidgetStateReducer`` over an injected
/// clock.
///
/// This is the `loop-wiring` Task 5 seam: the composition root folds every effect through
/// ``WidgetProjection`` and calls ``fold(_:)`` with the result; the views read ``state`` (and
/// ``timerFired(_:)`` is the input the view's own timers deliver, exactly as the reducer's
/// contract documents — "the view arms the timers named by ``WidgetTimer`` and the fold answers
/// their fires"). The reducer stays decision-pure; this type is the thin fold in front of it,
/// and the only thing it adds is the clock.
///
/// ## The injected clock
///
/// ``MonotonicClock`` is the same seam the session machine reads, and at ship the same instance
/// the root hands the machines — so the widget's time anchors (``WidgetReducerState/recordingStartedAt``,
/// ``WidgetReducerState/deliveredAt``) are minted by the same clock the ceiling is measured
/// against, and a timer driven by any other reading cannot move the state. A test hands it a
/// ``TestClock``-style clock and turns the cadence by hand.
///
/// ## Isolation
///
/// `@MainActor`, like the widget itself: `ObservableObject` state that views render belongs in the
/// one isolation domain the UI renders from, and every fold the root makes happens on the main
/// actor anyway.
@MainActor
public final class WidgetStateStore: ObservableObject {

    /// The reducer's state — the single thing the views render, published so SwiftUI observes it.
    @Published public private(set) var state: WidgetReducerState

    /// The only way time enters the fold.
    private let clock: any MonotonicClock

    /// - Parameters:
    ///   - clock: The fold's `now`. The root passes the same clock the session machines read.
    ///   - ceiling: The session ceiling the ceiling warning is derived from — the machine's own
    ///     `SessionMachine/ceiling` at ship, so a configured ceiling moves its own warning.
    public init(clock: any MonotonicClock, ceiling: Duration = SessionCeiling.default) {
        self.clock = clock
        self.state = WidgetReducerState(ceiling: ceiling)
    }

    /// Fold one projection verdict — the Core projection's answer to one machine effect or one
    /// pipeline event, exactly as produced.
    public func fold(_ result: WidgetProjectionResult) {
        state = WidgetStateReducer.reduce(
            state, action: .projection(result), now: clock.now)
    }

    /// One due timer fired, carrying this clock's reading — the view's timers land here.
    public func timerFired(_ timer: WidgetTimer) {
        state = WidgetStateReducer.reduce(
            state, action: .timerFired(timer), now: clock.now)
    }

    /// The wiring's egress fold — the resolved cleanup provider's `requiresNetwork` + endpoint,
    /// sent exactly once at launch (resolve-once). The only path that changes ``egress``.
    public func setEgress(_ egress: WidgetEgressState) {
        state = WidgetStateReducer.reduce(
            state, action: .egressChanged(egress), now: clock.now)
    }

    /// The wiring's context fold — the raw ``WidgetContextSignal`` facts folded at every context
    /// resolution (the `setEgress` shape: the reducer owns the badge rules, the store is the
    /// entry point). The only path that changes ``context``.
    public func setContext(_ signal: WidgetContextSignal) {
        state = WidgetStateReducer.reduce(
            state, action: .contextChanged(signal), now: clock.now)
    }

    /// The wiring's confirmation-card fold (`confirmation-card`, the `setContext` shape) — the
    /// gate's `confirmationRequired` sentence plus the provider/tool identity and the
    /// invocation's generation token. One card at a time: a presentation replaces the current
    /// card. The only paths that change ``confirmation`` are this, ``confirmActionConfirmation(_:)``
    /// and ``dismissActionConfirmation()`` — no timer and no projection can.
    public func presentActionConfirmation(_ signal: WidgetConfirmationSignal) {
        state = WidgetStateReducer.reduce(
            state, action: .confirmation(signal), now: clock.now)
    }

    /// The wiring's confirm fold: accepts the confirm iff the signal's generation is the current
    /// card's — the stale-card guard (spec acceptance 4), so a confirm for an already-replaced
    /// card is refused here and the wiring makes no gate call. An accepted confirm clears the
    /// card in the same fold (explicit confirm clears, exactly as dismiss/decline do); the
    /// wiring then submits to the executor with the sentence it showed, and re-presents a fresh
    /// card on a mismatch (the PRD review's re-prompt default).
    ///
    /// - Returns: `true` when the confirm was accepted (generation matched and the card cleared);
    ///   `false` when refused — a stale signal, or no card at all.
    @discardableResult
    public func confirmActionConfirmation(_ signal: WidgetConfirmationSignal) -> Bool {
        guard state.confirmation?.signal.generation == signal.generation else { return false }
        state = WidgetStateReducer.reduce(
            state, action: .confirmationDismissed, now: clock.now)
        return true
    }

    /// The explicit clear — dismiss and decline both land here (the wiring records the refused
    /// decision before calling it). The only fold that clears a presented card without
    /// confirming it.
    public func dismissActionConfirmation() {
        state = WidgetStateReducer.reduce(
            state, action: .confirmationDismissed, now: clock.now)
    }

    /// The widget-streaming sink's fold — one streaming partial from the pipeline's widget-only
    /// sink (``PartialTranscriptSink``), folded into the reducer's bounded partial state.
    ///
    /// The composition root wires the pipeline's `partialSink` to this method — the *only*
    /// destination a partial may reach, by the seam's own construction
    /// (`PartialTranscriptSink.swift:19-24`). The reducer owns the decisions (kept only while
    /// RECORDING/TRANSCRIBING, truncated at ``WidgetTiming/maxPartialCharacters``); this is the
    /// entry point, the `setEgress` shape, with the clock's reading as the fold's `now`.
    public func presentPartial(_ partial: String) {
        state = WidgetStateReducer.reduce(
            state, action: .partial(partial), now: clock.now)
    }
}
