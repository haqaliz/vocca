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

/// The live widget's six states, as a pure projection of the session machine's effects and the
/// turn-taking loop's states.
///
/// `VoccaUI` renders exactly this vocabulary; the FAILSAFE surface is a separate state machine
/// (``FailsafeState``) and is deliberately absent here. The mapping that produces these states is
/// ``WidgetProjection``, and the only sources of machine facts are ``SessionEffect`` — see
/// ``WidgetProjection/project(effect:targetAppName:)`` for which effect means what, and the two
/// invariants the mapping is written under — and, for the converse mode's one state, the loop's
/// ``TurnState`` (``WidgetProjection/project(turnState:)``).
///
/// The two payload cases name the application the user is dictating into (`PRODUCT_SPEC.md:38`).
/// The name is resolved by the composition root and handed to the projection at the `.opening`
/// fold — the machine never sees a target, so the projection cannot invent one — and the
/// pipeline's delivery re-names it at ``WidgetState/delivered(targetAppName:)``. The two names may
/// legitimately differ: focus can move between the press and the injection, and the delivered name
/// is the one the ladder actually typed into.
///
/// ``WidgetState/conversing(phase:)`` is the converse session's one state and carries **no
/// target payload** — the type itself cannot express a target app name, which is the strongest
/// form of `PRODUCT_SPEC.md:200`'s "the widget never shows a target app name" (the absence of
/// `→ AppName` is itself the mode signal).
public enum WidgetState: Equatable, Sendable {
    /// The dormant pill: no session, no microphone, nothing in flight.
    case idle
    /// The hotkey was pressed and the microphone has not opened yet
    /// (``SessionEffect/opening``). **No waveform here** — there is no audio to draw, and a
    /// waveform over a dead mic is the spec's named lie (`PRODUCT_SPEC.md:33-38,88`).
    case opening(targetAppName: String)
    /// The microphone is open and a session is recording — only ever from
    /// ``SessionEffect/started``, the machine's own recording signal (`SessionEffect.swift:29-30`).
    case recording
    /// The session ended and its audio is in the pipeline's hands: the waveform freezes and an
    /// indeterminate progress shows (`PRODUCT_SPEC.md:93-95`).
    case transcribing
    /// The pipeline typed the text into `targetAppName`: the brief ✓ confirmation that precedes
    /// the collapse to IDLE (`PRODUCT_SPEC.md:50,98`).
    case delivered(targetAppName: String)
    /// The converse session, one continuous loop: the mic is open, the loop is listening or the
    /// reply is being spoken (``ConversePhase``). **The only source is the turn-state
    /// projection** (``WidgetProjection/project(turnState:)``) — no ``SessionEffect`` maps here —
    /// and the phase is the case's only payload: converse never carries a target app name
    /// (`PRODUCT_SPEC.md:200`).
    case conversing(phase: ConversePhase)
}

/// The two widget-visible phases of a converse session (`dual-mode` C11, D1).
///
/// The loop's five ``TurnState``s collapse into these two (``WidgetProjection/project(turnState:)``):
/// **listening** — continuous capture + VAD, the user mid-sentence, or the committed turn awaiting
/// its reply — and **speaking** — the reply is being rendered. One `WidgetState` case with a phase
/// keeps the session's continuity in the type: the pill must not collapse or re-cue between
/// utterances, and the phase change is a phase of the same session, never a mode change.
///
/// Exactly two cases, by design — a caller's switch over the phase is exhaustive today and breaks
/// at compile time if the vocabulary ever grows.
public enum ConversePhase: Equatable, Sendable {
    /// The loop is listening: nothing is being spoken.
    case listening
    /// A reply is being rendered — Vocca is speaking.
    case speaking
}

/// A terminal notice the widget can surface: a machine effect that ends a gesture with a cause to
/// say rather than a state to show.
///
/// The FAILSAFE window's reason-only notice is the precedent (`FailsafeState.reasonOnly`); this is
/// the live widget's own, narrower instance. A notice is **terminal** — never dismissed by a
/// timer, exactly like every FAILSAFE state — and yields only to the next machine or pipeline
/// signal.
public enum WidgetNotice: Equatable, Sendable {
    /// The hotkey was pressed and the microphone did not open (``SessionEffect/captureUnavailable``,
    /// `SessionEffect.swift:48-51`): no session began, so there is nothing to record, transcribe
    /// or deliver — the widget says the cause out loud instead of letting the press appear to do
    /// nothing at all.
    case captureUnavailable
}

/// The pipeline-phase inputs the machine's effect stream cannot carry.
///
/// Everything about the *session* arrives as a ``SessionEffect``; everything about what the
/// *pipeline* did with the session's audio arrives here, from the composition root. The set is
/// closed over the two finishes — a pipeline run either typed the text or it did not.
public enum WidgetProjectionEvent: Equatable, Sendable {
    /// The pipeline typed the transcript into `targetAppName`. The name is the ladder's own
    /// answer (`TargetContext`), not a replay of the opening fold's name.
    case textDelivered(targetAppName: String)
    /// The pipeline finished with nothing to deliver — the session's audio was empty and the ASR
    /// empty-buffer policy made silence a skip, or the failure was routed to the FAILSAFE surface —
    /// and the live widget has nothing left to confirm, so it returns to IDLE.
    case finishedWithoutDelivery
}

/// What one input does to the widget: the verdict of ``WidgetProjection``.
public enum WidgetProjectionResult: Equatable, Sendable {
    /// The widget shows `state`.
    case state(WidgetState)
    /// The widget shows `notice` — a terminal notice, not a live state.
    case notice(WidgetNotice)
    /// Nothing changed (``SessionEffect/unchanged``): the widget keeps exactly what it had.
    case noChange
}

/// **The effect → widget mapping**, and the only translation that may claim a microphone state.
///
/// `ARCHITECTURE.md:355` puts session state in the machine and nowhere else, which makes this
/// mapping's job precise: it re-types the machine's own ``SessionEffect`` vocabulary into the
/// widget's, changing nothing and inventing nothing. It consumes the **effect stream directly** —
/// a caller that translated effects first would be a second, untested copy of this decision, which
/// is the shape this repository has twice found deletable.
///
/// The table, and the machine cites that pin it:
///
/// | Effect | Widget | Machine cite |
/// |---|---|---|
/// | ``SessionEffect/unchanged`` | ``WidgetProjectionResult/noChange`` | no session fact changed |
/// | ``SessionEffect/opening`` | ``WidgetState/opening(targetAppName:)`` | `SessionMachine.swift:544-545` — the deciding key event, the microphone not yet asked |
/// | ``SessionEffect/started`` | ``WidgetState/recording`` | **the recording signal** — `SessionEffect.swift:29-30` ("the microphone is open and a session is recording"), produced in exactly one place, `SessionMachine.openTheMicrophone()` when the source reports `.opened` (`SessionMachine.swift:596-603`), reached inline under `.immediately` (`SessionMachine.swift:532-534`) or through the owner's `completePendingOpening()` under `.whenTheOwnerAsks` (`SessionMachine.swift:567-571`) |
/// | ``SessionEffect/captureUnavailable`` | ``WidgetNotice/captureUnavailable`` | `SessionMachine.swift:591-594` — the microphone refused; no session began |
/// | ``SessionEffect/ended(_:)`` — `.cancelled` | ``WidgetState/idle`` | the user pressed Escape (`SessionOutcome.swift:100-101`) — nothing was retained, nothing to show |
/// | ``SessionEffect/ended(_:)`` — `.completed` | ``WidgetState/transcribing`` | `SessionMachine.swift:656-662`, the single funnel every stop route lands in |
///
/// The converse state is **not in this table**: its input is the turn-taking loop's own state, not
/// an effect — ``WidgetProjection/project(turnState:)`` is the converse leg (the `onStateChange`
/// hook's composition is `converse-wiring`'s).
///
/// ## The two invariants
///
/// 1. **`.recording` comes only from ``SessionEffect/started``.** The mapping never claims the
///    microphone is open from any other effect — most importantly not from `.opening`, where the
///    microphone is *not* open yet (`SessionMachine.swift:544-545`), and not from `.ended`, where
///    it has just been closed. `WidgetProjectionTests.testRecordingNeverComesFromANonRecordingSignal`
///    pins this over the closed effect set.
/// 2. **OPENING shows no waveform** (`PRODUCT_SPEC.md:33-38`) — a consequence of the first
///    invariant, stated separately because the widget's honesty is the whole point of the state.
///
/// ## The converse leg's invariants
///
/// 1. **`.conversing` comes only from ``WidgetProjection/project(turnState:)``** — never from a
///    `SessionEffect` fold (`WidgetConverseProjectionTests.testConversingNeverComesFromASessionEffectFold`
///    pins this over the closed effect set).
/// 2. **Converse never carries a target** (`PRODUCT_SPEC.md:200`) — the case's only payload is
///    the phase; the type cannot express a target app name.
///
/// ## Why TRANSCRIBING is derived from `.ended` rather than announced
///
/// The plan's latitude ("explicit projection events the root sends, **or derive them**") resolves
/// here to derivation, and the reason is the microphone. The waveform freeze is a fact about the
/// *microphone* — `.ended` is the machine's statement that it is closed — not about the pipeline's
/// progress: `PRODUCT_SPEC.md:93-95` freezes the waveform at the key-up, and a widget that stayed
/// in ``WidgetState/recording`` after `.ended` would claim a live mic while deaf (principle 1,
/// `PRODUCT_SPEC.md:24`). There is no fifth state to park an ended session in, and dropping to
/// IDLE would make the user's words vanish mid-processing. So `.ended(.completed)` *is* the
/// waveform-freeze signal, and the two pipeline finishes (``WidgetProjectionEvent``) are the only
/// inputs beyond the effect stream — there is no `.transcriptionBegan` event because the machine's
/// own `.ended` already marks the boundary. The 600 ms DELIVERED collapse is time, which is the
/// widget reducer's injected-clock fold, not this mapping's.
public enum WidgetProjection {

    /// Fold one machine effect into the widget.
    ///
    /// - Parameters:
    ///   - effect: the machine's own answer (`SessionMachine.observe(_:)`, `tick()`,
    ///     `completePendingOpening()` — every route that produces an effect).
    ///   - targetAppName: the focused application's name, as the composition root resolved it when
    ///     the session opened (`TargetContext`'s render). Read only by ``SessionEffect/opening`` —
    ///     the machine never sees a target, so a projected OPENING must be handed one — and
    ///     ignored for every other effect.
    public static func project<Audio: CapturedAudio>(
        effect: SessionEffect<Audio>,
        targetAppName: String
    ) -> WidgetProjectionResult {
        switch effect {
        case .unchanged:
            return .noChange
        case .opening:
            return .state(.opening(targetAppName: targetAppName))
        case .started:
            return .state(.recording)
        case .captureUnavailable:
            return .notice(.captureUnavailable)
        case .ended(let outcome):
            switch outcome.content {
            case .cancelled:
                return .state(.idle)
            case .completed:
                return .state(.transcribing)
            }
        }
    }

    /// Fold one pipeline-phase event into the widget.
    ///
    /// The other half of the seam: these are the only inputs that are not machine effects, and
    /// neither carries a microphone claim — the pipeline typed the text, or it did not.
    public static func project(event: WidgetProjectionEvent) -> WidgetProjectionResult {
        switch event {
        case .textDelivered(let targetAppName):
            return .state(.delivered(targetAppName: targetAppName))
        case .finishedWithoutDelivery:
            return .state(.idle)
        }
    }

    /// Fold the turn-taking loop's state into the widget — the converse leg (`dual-mode` C11, D2).
    ///
    /// The loop's `onStateChange` hook delivers ``TurnState`` (the loop's own vocabulary); this
    /// is the total mapping the widget renders, and `converse-wiring` folds its verdict through
    /// the store. The projection doctrine applied to the loop: the widget renders what the loop
    /// says, phase-collapsed into the two states it can honestly show, and never invents a state
    /// the machine did not emit (`widget-live-states/spec.md:46`).
    ///
    /// The table, final after Phase 2:
    ///
    /// | `TurnState` | Projected | Why |
    /// |---|---|---|
    /// | `.idle` | ``WidgetState/idle`` | The loop stopped — the converse session ended (the stop affordance or a system trigger), the panel hides. |
    /// | `.listening` | ``WidgetState/conversing(phase: .listening)`` | Continuous capture + VAD, nothing spoken. |
    /// | `.uttering` | ``WidgetState/conversing(phase: .listening)`` | The user is mid-sentence; the widget still listens (`◈ listening…`). |
    /// | `.committed` | ``WidgetState/conversing(phase: .listening)`` | The turn was handed over, the reply is pending, nothing is being spoken — the honest statement is still "listening". |
    /// | `.playing` | ``WidgetState/conversing(phase: .speaking)`` | The reply is being rendered; Vocca is speaking. |
    ///
    /// The session's *end* is `.idle` from `TurnState.idle` — the loop is stopped, the widget
    /// returns to IDLE, the panel hides.
    public static func project(turnState: TurnState) -> WidgetProjectionResult {
        switch turnState {
        case .idle:
            return .state(.idle)
        case .listening, .uttering, .committed:
            return .state(.conversing(phase: .listening))
        case .playing:
            return .state(.conversing(phase: .speaking))
        }
    }
}
