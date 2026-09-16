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

private typealias Effect = SessionEffect<RecordingSource.Buffer>

/// The converse leg of the widget projection (`dual-mode` C11, widget-converse D2): the
/// `TurnState` → `WidgetState` mapping the loop's `onStateChange` hook feeds, folded by
/// `converse-wiring`.
///
/// The projection doctrine (`ARCHITECTURE.md:408`) applied to the loop: `TurnState` is the loop's
/// own state vocabulary, so the converse projection is a **total function over it** — the widget
/// renders what the loop says, phase-collapsed into the two states the widget can honestly show,
/// and never invents a state the machine did not emit (`widget-live-states/spec.md:46`).
///
/// Two invariants this suite pins. **`.conversing` comes only from this leg** — the dictation
/// effect table (`WidgetProjectionTests`) maps no `SessionEffect` to it, and this suite asserts
/// the same from the other side over the closed effect set. **Converse never carries a target
/// name** (`PRODUCT_SPEC.md:200`): `.conversing`'s only payload is the phase, structurally — the
/// absence of `→ AppName` is itself the mode signal, so the type cannot express one.
final class WidgetConverseProjectionTests: XCTestCase {

    // MARK: - The decision table

    /// D2's five rows, written by hand: each of the loop's five states projects to exactly one
    /// widget result. `.uttering` and `.committed` collapse into the listening phase — the
    /// widget's honest statement is "listening" until the reply is actually being rendered.
    func testTheFiveTurnStatesProjectToTheirRows() {
        let rows: [(TurnState, WidgetProjectionResult, String)] = [
            (.idle, .state(.idle), "idle — the loop stopped, the converse session ended"),
            (.listening, .state(.conversing(.listening)), "listening — continuous capture + VAD"),
            (
                .uttering, .state(.conversing(.listening)),
                "uttering — the user is mid-sentence, the widget still listens"
            ),
            (
                .committed, .state(.conversing(.listening)),
                "committed — handed over, reply pending, nothing being spoken: still listening"
            ),
            (.playing, .state(.conversing(.speaking)), "playing — the reply is being rendered"),
        ]
        for (turnState, expected, name) in rows {
            XCTAssertEqual(
                WidgetProjection.project(turnState: turnState),
                expected,
                "\(name) must map to exactly its row in the table")
        }
    }

    /// The two-phase collapse is pinned by name: `.uttering` and `.committed` land on the same
    /// phase as `.listening` — a mid-sentence user, a committed turn awaiting its reply, and a
    /// loop idly listening are all "listening" from the widget's side.
    func testUtteringAndCommittedCollapseIntoTheListeningPhase() {
        XCTAssertEqual(
            WidgetProjection.project(turnState: .uttering),
            WidgetProjection.project(turnState: .listening))
        XCTAssertEqual(
            WidgetProjection.project(turnState: .committed),
            WidgetProjection.project(turnState: .listening))
        XCTAssertNotEqual(
            WidgetProjection.project(turnState: .playing),
            WidgetProjection.project(turnState: .listening),
            "playing is the one phase that reads as speaking")
    }

    // MARK: - Totality

    /// The leg is total over the closed five-case `TurnState` set: every state answers with a
    /// state, never a notice and never a no-change — a caller's switch over the loop's vocabulary
    /// stays exhaustive, exactly as the five-case pin in `TurnState.swift:25-27` promises.
    func testTheProjectionIsTotalOverTheClosedTurnStateSet() {
        let all: [TurnState] = [.idle, .listening, .uttering, .committed, .playing]
        for turnState in all {
            guard case .state = WidgetProjection.project(turnState: turnState) else {
                return XCTFail("\(turnState) must project to a state, never a notice or noChange")
            }
        }
    }

    // MARK: - The never-a-target rule (PRODUCT_SPEC.md:200)

    /// The structural pin: `.conversing`'s only associated value is the phase — the type itself
    /// cannot express a target app name, which is the strongest form of "converse never shows a
    /// target". A second payload, or a target-carrying case, fails to compile here.
    func testConversingCarriesOnlyThePhase() {
        let listening = WidgetState.conversing(phase: .listening)
        let speaking = WidgetState.conversing(phase: .speaking)
        guard case .conversing(let phase) = listening else {
            return XCTFail("the conversing case must carry exactly one associated value, the phase")
        }
        XCTAssertEqual(phase, .listening)
        XCTAssertEqual(listening, .conversing(phase: .listening))
        XCTAssertEqual(speaking, .conversing(phase: .speaking))
        XCTAssertNotEqual(listening, speaking, "the two phases are distinct states")
    }

    /// The asserted half of the rule: no converse projection output is a state that carries a
    /// target name, and the only converse output is `.conversing` with a phase — the exhaustive
    /// switch below breaks at compile time if converse ever gains a target payload or a second
    /// converse case.
    func testConverseProjectionsNeverCarryATargetName() {
        let all: [TurnState] = [.idle, .listening, .uttering, .committed, .playing]
        for turnState in all {
            guard case .state(let projected) = WidgetProjection.project(turnState: turnState)
            else {
                return XCTFail("\(turnState) must project to a state")
            }
            switch projected {
            case .conversing(let phase):
                _ = phaseName(phase)
            case .opening, .delivered:
                XCTFail(
                    "\(turnState) projected to a target-carrying state — converse must never show "
                        + "a target app name (PRODUCT_SPEC.md:200)")
            case .idle, .recording, .transcribing:
                break
            }
        }
    }

    // MARK: - The converse input is the turn-state leg alone

    /// `.conversing` comes **only** from `project(turnState:)` — never from a `SessionEffect`
    /// fold. The dictation table's rows are untouched, and this suite asserts the closed effect
    /// set maps to no converse state from the other side (the `WidgetProjectionTests`
    /// `testRecordingNeverComesFromANonRecordingSignal` shape).
    func testConversingNeverComesFromASessionEffectFold() {
        let effects: [(Effect, String)] = [
            (.unchanged, "unchanged"),
            (.opening, "opening"),
            (.started, "started"),
            (.captureUnavailable, "captureUnavailable"),
            (ended(.retained(.ceilingReached)), "ended completed"),
            (ended(.userCancelled), "ended cancelled"),
        ]
        for (effect, name) in effects {
            let result = WidgetProjection.project(effect: effect, targetAppName: "Slack")
            if case .state(.conversing) = result {
                XCTFail(
                    "\(name) must never project to `.conversing` — the turn-state leg is the only "
                        + "source of the converse state")
            }
        }
    }

    // MARK: - The phase vocabulary

    /// `ConversePhase` is closed over the two cases — an exhaustive switch over it, so a third
    /// phase stops compiling here (the same compile pin `TurnState` carries for its five).
    private func phaseName(_ phase: ConversePhase) -> String {
        switch phase {
        case .listening: return "listening"
        case .speaking: return "speaking"
        }
    }

    // MARK: - Fixture

    private func ended(_ reason: EndReason) -> Effect {
        .ended(SessionOutcome.make(reason: reason, audio: RecordingSource.Buffer(session: 1, frames: [])))
    }
}