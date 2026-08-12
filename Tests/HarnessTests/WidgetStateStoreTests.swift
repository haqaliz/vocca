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

/// The `loop-wiring` Task 5 store fold: the `@MainActor` observable the later views will observe,
/// folding `WidgetProjectionResult`s and `WidgetTimer` fires through the reducer over an injected
/// clock.
///
/// The reducer is decision-pure (`WidgetStateReducerTests` owns its table); what is pinned here is
/// the **store**: that every input the views can make — a projection result, a timer fire —
/// reaches the reducer with the clock's reading, and nothing else can. The input set is the closed
/// one the reducer documents (`WidgetAction`'s two cases), which is what makes "the closed event
/// set" an assertion rather than a claim: a fold or a timer fire, and no third input.
///
/// `@MainActor` because the store is — `ObservableObject` state the views observe belongs in the
/// one isolation domain the widget renders from.
@MainActor
final class WidgetStateStoreTests: XCTestCase {

    /// The closed projection set, folded: every `WidgetProjectionResult` case lands in the state
    /// the reducer was given, with the clock's reading as the fold's `now`.
    func testTheStoreFoldsEveryProjectionResultOverTheInjectedClock() {
        let clock = TestClock()
        let store = WidgetStateStore(clock: clock)
        XCTAssertEqual(store.state.state, .idle, "a fresh store is IDLE")

        // .state — the five live states, folded through the projection so the fold is the real
        // one the root makes.
        let opening = WidgetProjection.project(
            effect: SessionEffect<AudioBuffer>.opening, targetAppName: "Notes")
        store.fold(opening)
        XCTAssertEqual(store.state.state, .opening(targetAppName: "Notes"))
        XCTAssertEqual(store.state.recordingStartedAt, nil, "OPENING holds no recording anchor")

        store.fold(.state(.recording))
        XCTAssertEqual(store.state.state, .recording)
        XCTAssertEqual(store.state.recordingStartedAt, .zero, "the anchor is the fold's clock reading")

        store.fold(.state(.transcribing))
        XCTAssertEqual(store.state.state, .transcribing)
        XCTAssertEqual(
            store.state.recordingStartedAt, nil,
            "leaving RECORDING drops the anchor — the closed-set test's invariant")

        store.fold(.state(.delivered(targetAppName: "Notes")))
        XCTAssertEqual(store.state.state, .delivered(targetAppName: "Notes"))
        XCTAssertEqual(store.state.deliveredAt, .zero, "the collapse deadline is the fold's clock reading")

        store.fold(.state(.idle))
        XCTAssertEqual(store.state.state, .idle)

        // .notice — terminal, over IDLE, never dismissed by the store.
        store.fold(.notice(.captureUnavailable))
        XCTAssertEqual(store.state.notice, .captureUnavailable)
        XCTAssertEqual(store.state.state, .idle)

        // .noChange — leaves everything exactly where it was, including a notice.
        store.fold(.noChange)
        XCTAssertEqual(store.state.notice, .captureUnavailable)
    }

    /// The recording timer's fires advance the display at the injected clock's cadence: the
    /// escape hint at 2 s and the elapsed surface at 3 s of the fold's clock — the `WidgetTiming`
    /// constants, measured against the store's `now` rather than restated.
    func testTheRecordingTimerAdvancesTheDisplayAtTheInjectedClocksCadence() {
        let clock = TestClock()
        let store = WidgetStateStore(clock: clock)
        store.fold(.state(.recording))
        XCTAssertNil(store.state.elapsed)
        XCTAssertFalse(store.state.showsEscapeHint)

        clock.now = .seconds(1)
        store.timerFired(.recording)
        XCTAssertNil(store.state.elapsed)
        XCTAssertFalse(store.state.showsEscapeHint, "the hint appears at 2 s, not before")

        clock.now = .seconds(2)
        store.timerFired(.recording)
        XCTAssertTrue(store.state.showsEscapeHint)
        XCTAssertNil(store.state.elapsed, "the elapsed surface appears at 3 s, not before")

        clock.now = .seconds(5)
        store.timerFired(.recording)
        XCTAssertEqual(store.state.elapsed, .seconds(5), "the display reads now − the fold's anchor")
        XCTAssertTrue(store.state.showsEscapeHint)
    }

    /// The DELIVERED → IDLE collapse lands **exactly** at the injected clock's 600 ms deadline —
    /// a fire before it leaves DELIVERED, a fire at it collapses — so a timer driven by a
    /// different clock cannot claim the collapse.
    func testTheDeliveredCollapseLandsExactlyAtTheInjectedClocksDeadline() {
        let clock = TestClock()
        let store = WidgetStateStore(clock: clock)
        store.fold(.state(.delivered(targetAppName: "Notes")))

        clock.now = .milliseconds(599)
        store.timerFired(.deliveredCollapse)
        XCTAssertEqual(
            store.state.state, .delivered(targetAppName: "Notes"),
            "a fire 1 ms before the deadline must not collapse")

        clock.now = .milliseconds(600)
        store.timerFired(.deliveredCollapse)
        XCTAssertEqual(store.state.state, .idle, "the collapse lands exactly at the deadline")
        XCTAssertNil(store.state.deliveredAt, "collapsing drops the deadline anchor")
    }

    /// A timer fire is a no-op outside its own state: the recording timer in DELIVERED, the
    /// collapse timer in RECORDING — the view's timers may slip a fire across a state change, and
    /// the store must not let it conjure a surface that belongs to another state.
    func testTimerFiresAreIgnoredOutsideTheirOwnState() {
        let clock = TestClock()
        let store = WidgetStateStore(clock: clock)

        clock.now = .seconds(10)
        store.timerFired(.recording)
        XCTAssertEqual(store.state.state, .idle, "the recording timer does nothing in IDLE")

        store.fold(.state(.delivered(targetAppName: "Notes")))
        clock.now = .seconds(30)
        store.timerFired(.recording)
        XCTAssertEqual(
            store.state.state, .delivered(targetAppName: "Notes"),
            "the recording timer does nothing in DELIVERED")

        store.fold(.state(.recording))
        clock.now = .seconds(40)
        store.timerFired(.deliveredCollapse)
        XCTAssertEqual(store.state.state, .recording, "the collapse timer does nothing in RECORDING")
    }
}
