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

/// The converse start-tick selection (`dual-mode` widget-converse D6): `PRODUCT_SPEC.md:339`'s
/// "lower tick, clearly different from dictate" — the seam's **tested half**, the pure decision
/// of *when* a sound plays. The audible character of the tone is the `SystemWidgetSoundPlayer`
/// glue's, executed by nothing in CI and SMOKE-verified; what CI can reach is this selection,
/// and this suite pins it exactly.
///
/// The contract: `.converseStarted` plays **only** on a transition *into* `.conversing` from a
/// non-converse state — including the first entry from IDLE, and a re-entry after the session
/// ended. The listening ↔ speaking phase change plays nothing (it is one continuous session, not
/// a new cue), and every other transition plays nothing — the dictation transitions are silent
/// because the dictate tick is not built yet (recorded against the unbuilt dictate tick,
/// `PRODUCT_SPEC.md:196,339`; the converse tone is defined at the low end, the dictate slot
/// reserved higher).
final class WidgetSoundSelectionTests: XCTestCase {

    /// Entering converse plays the start tick from **any** non-converse state — the first entry
    /// from IDLE and a re-entry after IDLE included; the phase the session lands in does not
    /// matter, the *entry* is the cue.
    func testEnteringConversingPlaysTheStartTickFromAnyNonConverseState() {
        let nonConverse: [(WidgetState, String)] = [
            (.idle, "idle"),
            (.opening(targetAppName: "Slack"), "opening"),
            (.recording, "recording"),
            (.transcribing, "transcribing"),
            (.delivered(targetAppName: "Slack"), "delivered"),
        ]
        for (from, name) in nonConverse {
            XCTAssertEqual(
                WidgetSoundSelection.sound(from: from, to: .conversing(.listening)),
                .converseStarted,
                "entering converse from \(name) must play the start tick")
            XCTAssertEqual(
                WidgetSoundSelection.sound(from: from, to: .conversing(.speaking)),
                .converseStarted,
                "entering converse from \(name) must play the start tick")
        }
    }

    /// The phase change plays nothing: listening → speaking (the reply starts) and back (the
    /// reply stops, the capture continues) are one continuous session — a new tick would read as
    /// a new session, and the pill must not re-cue mid-conversation.
    func testThePhaseChangePlaysNothing() {
        XCTAssertNil(
            WidgetSoundSelection.sound(from: .conversing(.listening), to: .conversing(.speaking)))
        XCTAssertNil(
            WidgetSoundSelection.sound(from: .conversing(.speaking), to: .conversing(.listening)))
    }

    /// The whole table: every `(from, to)` pair answers, and the only pair family that plays is
    /// the entry into converse. The closed seven-state set makes this total — a future state that
    /// forgets its row breaks the switch here.
    func testNoOtherTransitionPlaysAnything() {
        let states: [(WidgetState, String)] = [
            (.idle, "idle"),
            (.opening(targetAppName: "Slack"), "opening"),
            (.recording, "recording"),
            (.transcribing, "transcribing"),
            (.delivered(targetAppName: "Slack"), "delivered"),
            (.conversing(.listening), "conversing listening"),
            (.conversing(.speaking), "conversing speaking"),
        ]
        for (from, fromName) in states {
            for (to, toName) in states {
                if isConverse(from) || !isConverse(to) {
                    XCTAssertNil(
                        WidgetSoundSelection.sound(from: from, to: to),
                        "\(fromName) → \(toName) must play nothing")
                } else {
                    XCTAssertEqual(
                        WidgetSoundSelection.sound(from: from, to: to),
                        .converseStarted,
                        "\(fromName) → \(toName) is an entry into converse and must play the tick")
                }
            }
        }
    }

    /// `WidgetSound` is closed over exactly the one case: the exhaustive switch below stops
    /// compiling if the vocabulary grows — a new sound case is a decision that must be recorded,
    /// not a silent addition (the §9 reserved slots for recording-start/delivered/failsafe are
    /// future cases, added empty by the aspect that ships them, never here).
    func testTheSoundVocabularyIsExactlyTheConverseStartTick() {
        func name(_ sound: WidgetSound) -> String {
            switch sound {
            case .converseStarted: return "converseStarted"
            }
        }
        XCTAssertEqual(name(.converseStarted), "converseStarted")
    }

    /// The seam is `Sendable` with exactly one synchronous `play(_:)` — pinned at compile time by
    /// capturing the existential in a `@Sendable` closure, the `LiveLevelSource` seam shape
    /// (`LiveLevelSource.swift:30-33`).
    func testTheSoundPlayingSeamIsSendableWithOneSynchronousPlay() {
        let player: any WidgetSoundPlaying = SilentSoundPlayer()
        let play: @Sendable () -> Void = { player.play(.converseStarted) }
        play()
    }

    private func isConverse(_ state: WidgetState) -> Bool {
        if case .conversing = state { return true }
        return false
    }
}

/// The stateless seam conformance the `Sendable` pin drives — a struct, so it is `Sendable` by
/// construction (the blessed stateless-struct form; the *recording* fake lives with the panel
/// tests, where the panel hook is driven).
private struct SilentSoundPlayer: WidgetSoundPlaying {
    func play(_ sound: WidgetSound) {}
}