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

/// The live widget reducer's decision table (`widget-live-states` Task 2): a pure fold over
/// `(state, action, now)` with an injected clock, so every time-based transition — the 2 s escape
/// hint, the 3 s elapsed surface, the derived ceiling warning, the 600 ms DELIVERED collapse —
/// is driven by an explicit clock event and nothing else (`FailsafeStateReducerTests`' pattern,
/// with the `TestClock` precedent doing the clock injection).
///
/// Two invariants this suite pins structurally. **No time-based transition exists without a clock
/// event**: the fold's `now` is consulted only by ``WidgetAction/timerFired(_:)``, so a widget
/// left alone stays exactly where it is, whatever time a fold is handed. And the ceiling warning
/// is **derived** from the configured session ceiling via
/// ``WatchdogPolicy/warningThreshold(before:)`` — `SessionWatchdog.swift:118-128` forbids
/// hard-coding 110 s anywhere but the one place the number lives, so a configured ceiling moves
/// its own warning.
final class WidgetStateReducerTests: XCTestCase {

    private func fold(
        _ steps: [(action: WidgetAction, now: Duration)],
        from state: WidgetReducerState = WidgetReducerState()
    ) -> WidgetReducerState {
        steps.reduce(state) { WidgetStateReducer.reduce($0, action: $1.action, now: $1.now) }
    }

    // MARK: - The projection output is adopted

    /// Each projection state is adopted verbatim — the Core projection's answer is the reducer's
    /// truth about the machine, carried without reinterpretation.
    func testProjectionStatesAreAdoptedVerbatim() {
        XCTAssertEqual(
            fold([(.projection(.state(.opening(targetAppName: "Slack"))), .zero)]).state,
            .opening(targetAppName: "Slack"))
        XCTAssertEqual(
            fold([(.projection(.state(.recording)), .zero)]).state,
            .recording)
        XCTAssertEqual(
            fold([(.projection(.state(.transcribing)), .zero)]).state,
            .transcribing)
        XCTAssertEqual(
            fold([(.projection(.state(.delivered(targetAppName: "Mail"))), .zero)]).state,
            .delivered(targetAppName: "Mail"))
    }

    /// `.noChange` (the machine's ``SessionEffect/unchanged``) leaves the state untouched — the
    /// fold must not disturb in-flight bookkeeping over an event that changed nothing.
    func testNoChangeLeavesEverythingUntouched() {
        let busy = fold([
            (.projection(.state(.recording)), .zero),
            (.timerFired(.recording), .seconds(5)),
        ])
        XCTAssertEqual(
            fold([(.projection(.noChange), .seconds(10_000))], from: busy),
            busy,
            "a no-change fold must reproduce the state exactly, including elapsed and hints")
    }

    /// The recording start is anchored at the machine's own ``SessionEffect/started`` — the same
    /// instant the machine resets its own `elapsed` (`SessionMachine.swift:596-602`), which is what
    /// keeps the reducer's display total and the machine's ceiling total on one clock.
    func testRecordingAnchorsItsClockAtTheMachinesRecordingSignal() {
        let recording = fold([(.projection(.state(.recording)), .seconds(42))])
        XCTAssertEqual(recording.recordingStartedAt, .seconds(42))
    }

    // MARK: - The time-based transitions, via the injected clock

    /// The "esc to cancel" hint appears at 2 s of recording (`PRODUCT_SPEC.md:129`) — and not
    /// before, whatever the fold's `now` is.
    func testTheEscapeHintAppearsAtTwoSeconds() {
        let recording = fold([(.projection(.state(.recording)), .zero)])
        let before = WidgetStateReducer.reduce(
            recording, action: .timerFired(.recording),
            now: .seconds(1) + .milliseconds(999))
        XCTAssertFalse(before.showsEscapeHint)
        let at = WidgetStateReducer.reduce(
            recording, action: .timerFired(.recording), now: .seconds(2))
        XCTAssertTrue(at.showsEscapeHint, "the escape hint must surface exactly at 2 s")
    }

    /// The elapsed timer surfaces only after 3 s (`PRODUCT_SPEC.md:87`) — the value carried is the
    /// full elapsed reading at the clock event, so the view never invents time between fires.
    func testTheElapsedTimerSurfacesOnlyAfterThreeSeconds() {
        let recording = fold([(.projection(.state(.recording)), .zero)])
        let atTwoNine = WidgetStateReducer.reduce(
            recording, action: .timerFired(.recording),
            now: .seconds(2) + .milliseconds(900))
        XCTAssertNil(atTwoNine.elapsed, "no elapsed before 3 s, even with a hint showing")
        XCTAssertTrue(atTwoNine.showsEscapeHint)
        let atThree = WidgetStateReducer.reduce(
            recording, action: .timerFired(.recording), now: .seconds(3))
        XCTAssertEqual(atThree.elapsed, .seconds(3))
        let atFiveFive = WidgetStateReducer.reduce(
            recording, action: .timerFired(.recording),
            now: .seconds(5) + .milliseconds(500))
        XCTAssertEqual(atFiveFive.elapsed, .seconds(5) + .milliseconds(500))
    }

    /// The ceiling warning is **derived**, not hard-coded: against the shipped 120 s ceiling it
    /// appears at exactly 110 s (`WatchdogPolicy`'s `120 − 10`), and a configured 60 s ceiling
    /// moves its own warning to 50 s — `SessionWatchdog.swift:118-128`'s doctrine, enforced here.
    func testTheCeilingWarningTracksTheConfiguredCeiling() {
        let recording = fold([(.projection(.state(.recording)), .zero)])
        let atOneOhNine = WidgetStateReducer.reduce(
            recording, action: .timerFired(.recording), now: .seconds(109))
        XCTAssertFalse(atOneOhNine.showsCeilingWarning)
        let atOneTen = WidgetStateReducer.reduce(
            recording, action: .timerFired(.recording), now: .seconds(110))
        XCTAssertTrue(atOneTen.showsCeilingWarning, "the warning must appear at 110 s against the shipped ceiling")

        let shorter = WidgetReducerState(ceiling: .seconds(60))
        let shorterRecording = fold([(.projection(.state(.recording)), .zero)], from: shorter)
        XCTAssertFalse(
            WidgetStateReducer.reduce(shorterRecording, action: .timerFired(.recording), now: .seconds(49)).showsCeilingWarning,
            "a 60 s ceiling must not warn at 49 s")
        XCTAssertTrue(
            WidgetStateReducer.reduce(shorterRecording, action: .timerFired(.recording), now: .seconds(50)).showsCeilingWarning,
            "a 60 s ceiling must warn at 50 s — derived, never the default's 110")
    }

    /// DELIVERED collapses to IDLE exactly at 600 ms of the fold's clock (`PRODUCT_SPEC.md:50,98`):
    /// one millisecond early it still shows, at the deadline it collapses.
    func testDeliveredCollapsesToIdleExactlyAtSixHundredMilliseconds() {
        let delivered = fold([
            (.projection(.state(.delivered(targetAppName: "Slack"))), .seconds(1)),
        ])
        let before = WidgetStateReducer.reduce(
            delivered, action: .timerFired(.deliveredCollapse),
            now: .seconds(1) + .milliseconds(599))
        XCTAssertEqual(before.state, .delivered(targetAppName: "Slack"))
        let at = WidgetStateReducer.reduce(
            delivered, action: .timerFired(.deliveredCollapse),
            now: .seconds(1) + .milliseconds(600))
        XCTAssertEqual(at.state, .idle, "the collapse must land exactly at 600 ms")
        XCTAssertNil(at.deliveredAt, "the collapse must clear its own timer bookkeeping")
    }

    /// **No time-based transition without a clock event**: the fold's `now` is consulted only by
    /// `.timerFired`, so a fold with no clock event can be handed any time and nothing moves — and
    /// the first clock event after the fact drives the transition it was always owed.
    func testNoTimeBasedTransitionWithoutAClockEvent() {
        let lateRecording = WidgetStateReducer.reduce(
            WidgetReducerState(), action: .projection(.state(.recording)), now: .seconds(200))
        XCTAssertEqual(lateRecording.state, .recording)
        XCTAssertNil(lateRecording.elapsed, "no clock event, no elapsed surface, however late the fold")
        XCTAssertFalse(lateRecording.showsEscapeHint)
        XCTAssertFalse(lateRecording.showsCeilingWarning)

        let lateDelivered = WidgetStateReducer.reduce(
            lateRecording, action: .projection(.state(.delivered(targetAppName: "Slack"))), now: .seconds(300))
        XCTAssertEqual(lateDelivered.state, .delivered(targetAppName: "Slack"))
        let idle = WidgetStateReducer.reduce(
            lateDelivered, action: .projection(.noChange), now: .seconds(10_000))
        XCTAssertEqual(idle.state, .delivered(targetAppName: "Slack"),
            "a delivered widget left alone stays delivered, whatever time a non-clock fold is handed")

        let collapsed = WidgetStateReducer.reduce(
            lateDelivered, action: .timerFired(.deliveredCollapse),
            now: .seconds(300) + .milliseconds(600))
        XCTAssertEqual(collapsed.state, .idle, "the first clock event after the deadline drives the collapse")
    }

    // MARK: - Each timer only answers its own state

    /// The recording timer answers only RECORDING: a fire while DELIVERED must not surface an
    /// elapsed reading or hint that belong to a session long over.
    func testTheRecordingTimerIsIgnoredOutsideRecording() {
        let delivered = fold([
            (.projection(.state(.delivered(targetAppName: "Slack"))), .zero),
            (.timerFired(.recording), .seconds(30)),
        ])
        XCTAssertEqual(delivered.state, .delivered(targetAppName: "Slack"))
        XCTAssertNil(delivered.elapsed)
        XCTAssertFalse(delivered.showsEscapeHint)
        XCTAssertFalse(delivered.showsCeilingWarning)
        XCTAssertEqual(delivered.deliveredAt, .zero, "a foreign timer fire must not touch the collapse clock")
    }

    /// The collapse timer answers only DELIVERED: a fire while RECORDING must not end a live
    /// session's display.
    func testTheCollapseTimerIsIgnoredOutsideDelivered() {
        let recording = fold([
            (.projection(.state(.recording)), .zero),
            (.timerFired(.deliveredCollapse), .seconds(30)),
        ])
        XCTAssertEqual(recording.state, .recording)
        XCTAssertEqual(recording.recordingStartedAt, .zero)
        XCTAssertNil(recording.deliveredAt)
    }

    // MARK: - The captureUnavailable notice

    /// The notice path is **terminal**: `.captureUnavailable` shows the cause over IDLE, timer
    /// fires leave it alone, and only the next machine or pipeline signal replaces it — the
    /// no-time-based-dismissal rule the FAILSAFE already enforces, applied to the live widget.
    func testTheCaptureUnavailableNoticeIsTerminalUntilTheNextSignal() {
        let noticed = fold([(.projection(.notice(.captureUnavailable)), .zero)])
        XCTAssertEqual(noticed.state, .idle)
        XCTAssertEqual(noticed.notice, .captureUnavailable)

        let afterTicks = fold([
            (.timerFired(.recording), .seconds(5)),
            (.timerFired(.deliveredCollapse), .seconds(5)),
        ], from: noticed)
        XCTAssertEqual(afterTicks.notice, .captureUnavailable, "clock events must not dismiss the notice")

        let replaced = fold([(.projection(.state(.opening(targetAppName: "Slack"))), .seconds(6))], from: noticed)
        XCTAssertNil(replaced.notice, "the next press clears the notice")
    }

    // MARK: - The closed set

    /// The closed event set folds from every state: totality (every action × state × clock reading
    /// answers), and the bookkeeping invariants the fold must hold at every step — the time
    /// anchors exist exactly while their states do, the surfaces belong only to RECORDING, and a
    /// notice never rides over a live state.
    func testTheClosedEventSetFoldsFromEveryState() {
        let base = WidgetReducerState()
        let states: [(WidgetReducerState, String)] = [
            (base, "idle"),
            (fold([(.projection(.state(.opening(targetAppName: "Slack"))), .zero)]), "opening"),
            (fold([(.projection(.state(.recording)), .zero)]), "recording"),
            (fold([
                (.projection(.state(.recording)), .zero),
                (.projection(.state(.transcribing)), .zero),
            ]), "transcribing"),
            (fold([(.projection(.state(.delivered(targetAppName: "Slack"))), .zero)]), "delivered"),
            (fold([(.projection(.notice(.captureUnavailable)), .zero)]), "notice"),
        ]
        let actions: [(WidgetAction, String)] = [
            (.projection(.noChange), "noChange"),
            (.projection(.state(.idle)), "project idle"),
            (.projection(.state(.opening(targetAppName: "Slack"))), "project opening"),
            (.projection(.state(.recording)), "project recording"),
            (.projection(.state(.transcribing)), "project transcribing"),
            (.projection(.state(.delivered(targetAppName: "Slack"))), "project delivered"),
            (.projection(.notice(.captureUnavailable)), "project notice"),
            (.timerFired(.recording), "recording timer"),
            (.timerFired(.deliveredCollapse), "collapse timer"),
            (.egressChanged(.none), "egress none"),
            (.egressChanged(.active(endpoint: "http://localhost:11434")), "egress active"),
        ]
        let nows: [Duration] = [.zero, .milliseconds(599), .seconds(2), .seconds(3), .seconds(110)]

        for (state, stateName) in states {
            for (action, actionName) in actions {
                for now in nows {
                    let next = WidgetStateReducer.reduce(state, action: action, now: now)
                    assertInvariants(of: next, file: #filePath, line: #line)
                    if let violation = invariantViolation(
                        in: next,
                        when: actionName, on: stateName, at: now
                    ) {
                        XCTFail("\(actionName) on \(stateName) at \(now) violates the transition table: \(violation)")
                    }
                }
            }
        }
    }

    /// The plan's edge case: the 600 ms DELIVERED collapse must not drop a concurrently-presented
    /// FAILSAFE. The two surfaces are separate reducers over separate states, so the widget fold
    /// cannot touch the failsafe — pinned by running both machines on one timeline and asserting
    /// the held transcript survives the collapse, in both orders.
    func testTheDeliveredCollapseDoesNotDropAConcurrentFailsafe() {
        let transcript = HeldTranscript(
            text: "Never lose these words",
            reason: .exhausted,
            targetAppName: "Slack",
            capturedAt: .seconds(1))

        let delivered = fold([(.projection(.state(.delivered(targetAppName: "Slack"))), .seconds(2))])
        let collapseAt: Duration = .seconds(2) + .milliseconds(600)

        var widget = delivered
        var failsafe = FailsafeState.hidden
        failsafe = FailsafeStateReducer.reduce(failsafe, action: .transcriptHeld(transcript))
        widget = WidgetStateReducer.reduce(widget, action: .timerFired(.deliveredCollapse), now: collapseAt)
        XCTAssertEqual(widget.state, .idle, "the widget collapses on its own clock")
        XCTAssertEqual(failsafe, .presenting(transcript), "the collapse must not drop the concurrently-presented failsafe")

        let widgetLast = WidgetStateReducer.reduce(
            delivered, action: .timerFired(.deliveredCollapse), now: collapseAt)
        let failsafeLast = FailsafeStateReducer.reduce(
            FailsafeState.hidden, action: .transcriptHeld(transcript))
        XCTAssertEqual(widgetLast.state, .idle)
        XCTAssertEqual(failsafeLast, .presenting(transcript), "the order must not matter: the failsafe survives either way")
    }

    // MARK: - Invariant probes

    /// The invariants every fold must hold: the time anchors exist exactly while their states do,
    /// the time-derived surfaces belong only to RECORDING, and a notice never rides over a live
    /// state. Returns the first violation as a message, or `nil`.
    private func invariantViolation(
        in state: WidgetReducerState,
        when actionName: String,
        on stateName: String,
        at now: Duration
    ) -> String? {
        switch state.state {
        case .recording:
            if state.recordingStartedAt == nil { return "recording without a start anchor" }
            if state.deliveredAt != nil { return "recording with a delivery anchor" }
            if state.notice != nil { return "a notice riding over RECORDING" }
        case .delivered:
            if state.deliveredAt == nil { return "delivered without a delivery anchor" }
            if state.recordingStartedAt != nil { return "delivered with a recording anchor" }
            if state.notice != nil { return "a notice riding over DELIVERED" }
            if state.elapsed != nil { return "an elapsed reading riding over DELIVERED" }
            if state.showsEscapeHint || state.showsCeilingWarning { return "recording surfaces riding over DELIVERED" }
        case .idle, .opening, .transcribing:
            if state.recordingStartedAt != nil { return "a recording anchor over \(state.state)" }
            if state.deliveredAt != nil { return "a delivery anchor over \(state.state)" }
            if state.elapsed != nil { return "an elapsed reading over \(state.state)" }
            if state.showsEscapeHint || state.showsCeilingWarning { return "recording surfaces over \(state.state)" }
        }
        return nil
    }

    private func assertInvariants(
        of state: WidgetReducerState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let violation = invariantViolation(in: state, when: "", on: "", at: .zero) {
            XCTFail("state violates the invariants: \(violation)", file: file, line: line)
        }
    }
}
