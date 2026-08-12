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

/// The live widget's state as the reducer owns it: the ``WidgetState`` projection plus the
/// bookkeeping a pure fold needs to answer the time-based transitions — and nothing the fold
/// cannot derive.
///
/// The reducer is a **pure fold** over `(state, action, now)` with an injected clock, so the whole
/// UI decision table runs headlessly (`WidgetStateReducerTests`, the `FailsafeState`/`EnginePickerState`
/// precedent with the `TestClock` mechanism doing the injection). There are no timers inside it:
/// the *view* arms the timers named by ``WidgetTimer`` and the fold answers their fires with the
/// `now` they carry. **No time-based transition exists without a clock event** — a widget left
/// alone stays exactly where it is, whatever time a fold is handed — which is the same structural
/// pin the FAILSAFE's never-auto-dismiss uses, applied to the live widget.
///
/// The time facts this state derives have one source-of-truth caveat worth stating where it lives.
/// The *display* elapsed is computed here as `now − recordingStartedAt`, and ``recordingStartedAt``
/// is anchored at the fold that adopted ``WidgetState/recording`` — the same instant the machine
/// resets its own `elapsed` (`SessionMachine.swift:596-602`). The machine's `elapsed` remains the
/// ceiling's truth; this reading is display-only and agrees with it because both are anchored at
/// mic-open on the same clock. A second *accumulator* would be the Handy #840 shape the machine
/// warns about (`SessionMachine.swift:101-105`); an anchored difference between two readings of
/// one clock is not one.
///
/// The ``WidgetNotice`` carried here is **terminal**: it is set only by the projection's
/// ``WidgetProjectionResult/notice(_:)``, no timer dismisses it, and only the next machine or
/// pipeline signal (another ``WidgetProjectionResult`` fold) replaces it.
public struct WidgetReducerState: Equatable, Sendable {
    /// The projection's verdict on the machine — the five live states.
    public var state: WidgetState

    /// A terminal notice, `nil` except between ``WidgetProjectionResult/notice(_:)`` and the next
    /// signal.
    public var notice: WidgetNotice?

    /// This session machine's ceiling, from which the ceiling warning is **derived** via
    /// ``WatchdogPolicy/warningThreshold(before:)`` — `SessionWatchdog.swift:118-128` forbids
    /// hard-coding 110 s anywhere but the one place that number lives.
    public var ceiling: Duration

    /// The fold's clock reading at the ``WidgetState/recording`` adoption; `nil` outside
    /// RECORDING. Exists exactly while ``state`` is `.recording` — the closed-set test enforces it.
    public var recordingStartedAt: Duration?

    /// The fold's clock reading at the ``WidgetState/delivered(targetAppName:)`` adoption; `nil`
    /// outside DELIVERED. Exists exactly while ``state`` is `.delivered`.
    public var deliveredAt: Duration?

    /// The elapsed reading surfaced to the view, `nil` until 3 s of recording
    /// (`PRODUCT_SPEC.md:87`). Display-only — see the type's documentation.
    public var elapsed: Duration?

    /// Whether the "esc to cancel" hint is showing (`PRODUCT_SPEC.md:129`), true from 2 s of
    /// recording and only while RECORDING.
    public var showsEscapeHint: Bool

    /// Whether the ceiling-approach warning is showing (`PRODUCT_SPEC.md:87-90`), true from
    /// ``WatchdogPolicy/warningThreshold(before:`` ``WidgetReducerState/ceiling```)`.
    public var showsCeilingWarning: Bool

    /// The resting state: IDLE, no notice, no timer bookkeeping, the shipped session ceiling.
    ///
    /// The composition root passes the machine's own `ceiling` (`SessionMachine.ceiling`) so a
    /// configured ceiling moves its own warning; `SessionCeiling.default` is what a caller gets
    /// for not saying so.
    public init(
        state: WidgetState = .idle,
        ceiling: Duration = SessionCeiling.default
    ) {
        self.state = state
        self.ceiling = ceiling
        self.recordingStartedAt = nil
        self.deliveredAt = nil
        self.elapsed = nil
        self.showsEscapeHint = false
        self.showsCeilingWarning = false
        self.notice = nil
    }
}

/// The due timers the view arms and the fold answers.
///
/// The view reads the reducer state to know which timer to run — a recording session arms the
/// recording timer, a delivered one arms the collapse timer — and sends
/// ``WidgetAction/timerFired(_:)`` with the injected clock's reading on each fire. Each timer is
/// a no-op outside its own state.
public enum WidgetTimer: Equatable, Sendable, CaseIterable {
    /// Drives the RECORDING time-derived surfaces: the escape hint at
    /// ``WidgetTiming/escapeHintDelay``, the elapsed surface at ``WidgetTiming/elapsedSurfaceDelay``,
    /// and the derived ceiling warning. Fires periodically while RECORDING (the view's cadence).
    case recording
    /// Drives the DELIVERED → IDLE collapse at ``WidgetTiming/deliveredCollapseDelay``. Fires once,
    /// at the deadline.
    case deliveredCollapse
}

/// The intents and injected answers the live widget offers the reducer.
///
/// **The set is closed**: the Core projection's verdict on one machine effect or pipeline event
/// (``WidgetAction/projection(_:)``), and a due timer (``WidgetAction/timerFired(_:)``). There is
/// no other input, so the exhaustive switch in ``WidgetStateReducer`` cannot hide a transition no
/// action can carry — and the fold's `now` is consulted only by the timer action, which is the
/// structural pin on "no time-based transition without a clock event".
public enum WidgetAction: Equatable, Sendable {
    /// The Core projection's verdict — ``WidgetProjection/project(effect:targetAppName:)`` or
    /// ``WidgetProjection/project(event:)`` folded by the composition root, exactly as produced.
    case projection(WidgetProjectionResult)
    /// A due timer fired, carrying the injected clock's reading at the fire.
    case timerFired(WidgetTimer)
}

/// The plan's time constants (`widget-live-states` Task 2), in exactly one place each.
///
/// The ceiling warning is *not* here: it is derived from the configured ceiling via
/// ``WatchdogPolicy/warningThreshold(before:)`` — against the shipped 120 s ceiling that number is
/// 110 s (`PRODUCT_SPEC.md:87-90`), and a configured ceiling must move its own warning
/// (`SessionWatchdog.swift:118-128`).
public enum WidgetTiming {
    /// The "esc to cancel" hint appears at 2 s of recording (`PRODUCT_SPEC.md:129`).
    public static let escapeHintDelay: Duration = .seconds(2)
    /// The elapsed timer surfaces at 3 s of recording (`PRODUCT_SPEC.md:87`).
    public static let elapsedSurfaceDelay: Duration = .seconds(3)
    /// The DELIVERED confirmation collapses to IDLE after 600 ms (`PRODUCT_SPEC.md:50,98`).
    public static let deliveredCollapseDelay: Duration = .milliseconds(600)
}

/// The live widget's transition table: a pure fold over `(state, action, now)`.
///
/// - ``WidgetAction/projection(_:)`` adopts the Core projection's verdict. Adopting a state
///   re-anchors the bookkeeping: RECORDING records ``WidgetReducerState/recordingStartedAt`` at
///   `now`, DELIVERED records ``WidgetReducerState/deliveredAt`` at `now`, and every other state
///   clears both plus the time-derived surfaces. ``WidgetProjectionResult/noChange`` leaves
///   everything untouched. ``WidgetProjectionResult/notice(_:)`` shows the terminal notice over
///   IDLE.
/// - ``WidgetAction/timerFired(_:)`` answers only its own state. The recording timer computes
///   `elapsed = now − recordingStartedAt` (clamped at zero against a backwards clock) and flips
///   the escape hint at ``WidgetTiming/escapeHintDelay``, the elapsed surface at
///   ``WidgetTiming/elapsedSurfaceDelay`` and the derived ceiling warning. The collapse timer ends
///   DELIVERED exactly at ``WidgetTiming/deliveredCollapseDelay`` after ``deliveredAt``.
///
/// The DELIVERED collapse cannot drop a concurrently-presented FAILSAFE, and it does not need a
/// transition-table row to say so: the FAILSAFE is ``FailsafeStateReducer``'s state machine, a
/// different type this fold has no handle on — the widget's collapse rewrites this state alone,
/// and `WidgetStateReducerTests.testTheDeliveredCollapseDoesNotDropAConcurrentFailsafe` pins the
/// interleave on one timeline.
public enum WidgetStateReducer {

    public static func reduce(
        _ state: WidgetReducerState,
        action: WidgetAction,
        now: Duration
    ) -> WidgetReducerState {
        switch action {
        case .projection(let result):
            switch result {
            case .noChange:
                return state
            case .state(let projected):
                return adopting(projected, in: state, at: now)
            case .notice(let notice):
                var next = WidgetReducerState(state: .idle, ceiling: state.ceiling)
                next.notice = notice
                return next
            }
        case .timerFired(let timer):
            switch timer {
            case .recording:
                return recordingTick(state, now: now)
            case .deliveredCollapse:
                return collapseTick(state, now: now)
            }
        }
    }

    /// Adopt a projected state and re-anchor the bookkeeping it owns.
    private static func adopting(
        _ projected: WidgetState,
        in state: WidgetReducerState,
        at now: Duration
    ) -> WidgetReducerState {
        var next = state
        next.state = projected
        next.notice = nil
        switch projected {
        case .recording:
            next.recordingStartedAt = now
            next.deliveredAt = nil
            next.elapsed = nil
            next.showsEscapeHint = false
            next.showsCeilingWarning = false
        case .delivered:
            next.deliveredAt = now
            next.recordingStartedAt = nil
            next.elapsed = nil
            next.showsEscapeHint = false
            next.showsCeilingWarning = false
        case .idle, .opening, .transcribing:
            next.recordingStartedAt = nil
            next.deliveredAt = nil
            next.elapsed = nil
            next.showsEscapeHint = false
            next.showsCeilingWarning = false
        }
        return next
    }

    /// The recording timer's fire: recompute the display elapsed from the anchor and the clock.
    ///
    /// A no-op outside RECORDING or without an anchor — a fire the view let slip after the state
    /// moved on must not conjure surfaces that belong to a session long over.
    private static func recordingTick(
        _ state: WidgetReducerState, now: Duration
    ) -> WidgetReducerState {
        guard case .recording = state.state, let started = state.recordingStartedAt else {
            return state
        }
        let elapsed = max(.zero, now - started)
        var next = state
        next.showsEscapeHint = elapsed >= WidgetTiming.escapeHintDelay
        next.elapsed = elapsed >= WidgetTiming.elapsedSurfaceDelay ? elapsed : nil
        next.showsCeilingWarning = elapsed >= WatchdogPolicy.warningThreshold(before: state.ceiling)
        return next
    }

    /// The collapse timer's fire: end DELIVERED exactly at the deadline.
    private static func collapseTick(
        _ state: WidgetReducerState, now: Duration
    ) -> WidgetReducerState {
        guard case .delivered = state.state, let deliveredAt = state.deliveredAt else {
            return state
        }
        guard now - deliveredAt >= WidgetTiming.deliveredCollapseDelay else { return state }
        var next = state
        next.state = .idle
        next.deliveredAt = nil
        return next
    }
}
