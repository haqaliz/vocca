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

/// The widget projection's decision table (`widget-live-states` Task 1): every machine effect maps
/// to exactly one widget result, and the two invariants the whole aspect is written under —
/// **`.recording` comes only from the machine's own recording signal** (``SessionEffect/started``,
/// `SessionEffect.swift:29-30`, produced in exactly one place, `SessionMachine.openTheMicrophone()`
/// at `SessionMachine.swift:596-603`), and **`.opening` never shows a waveform** (`PRODUCT_SPEC.md:33-38`).
///
/// The projection consumes the machine's effect stream directly — the machine is the sole source
/// of truth about sessions, so the translation that claims a microphone state must live here, over
/// the machine's own vocabulary, not in a caller that could re-type an effect as it pleases. The
/// pipeline-phase finishes (``WidgetProjectionEvent``) are the only non-machine inputs, and they
/// carry no microphone claims at all.
final class WidgetProjectionTests: XCTestCase {

    // MARK: - The closed effect table

    /// Every machine effect maps to exactly one result, and `.recording` appears in the table
    /// exactly once — from ``SessionEffect/started``, the machine's own recording signal.
    func testEveryMachineEffectMapsToExactlyOneResult() {
        let rows: [(Effect, WidgetProjectionResult, String)] = [
            (.unchanged, .noChange, "unchanged"),
            (.opening, .state(.opening(targetAppName: "Slack")), "opening"),
            (.started, .state(.recording), "started — the machine's recording signal"),
            (.captureUnavailable, .notice(.captureUnavailable), "captureUnavailable"),
            (ended(.retained(.ceilingReached)), .state(.transcribing), "ended completed"),
            (ended(.userCancelled), .state(.idle), "ended cancelled"),
        ]
        for (effect, expected, name) in rows {
            XCTAssertEqual(
                WidgetProjection.project(effect: effect, targetAppName: "Slack"),
                expected,
                "\(name) must map to exactly its row in the table")
        }

        let recordingRows = rows.filter { $0.1 == .state(.recording) }
        XCTAssertEqual(
            recordingRows.count, 1,
            "`.recording` must appear exactly once in the closed table — the machine's `.started` is the only recording signal")
    }

    /// The projection never claims `.recording` from any effect but ``SessionEffect/started``:
    /// a waveform over a dead mic is the spec's named lie (`PRODUCT_SPEC.md:88`), and `.opening` is
    /// the exact case that would tell it — the microphone is not open yet, so `OPENING` must not
    /// show a waveform (`PRODUCT_SPEC.md:33-38`).
    func testRecordingNeverComesFromANonRecordingSignal() {
        let effects: [(Effect, String)] = [
            (.unchanged, "unchanged"),
            (.opening, "opening"),
            (.captureUnavailable, "captureUnavailable"),
            (ended(.retained(.ceilingReached)), "ended completed"),
            (ended(.userCancelled), "ended cancelled"),
        ]
        for (effect, name) in effects {
            let result = WidgetProjection.project(effect: effect, targetAppName: "Slack")
            switch result {
            case .state(.recording):
                XCTFail("\(name) must never claim `.recording` — only the machine's `.started` does")
            case .state, .notice, .noChange:
                break
            }
        }
    }

    /// `.captureUnavailable` maps to the terminal notice path — the microphone refused to open, no
    /// session began (`SessionEffect.swift:48-51`), and the widget has a cause to say rather than
    /// a state to show.
    func testCaptureUnavailableMapsToTheTerminalNoticePath() {
        let result = WidgetProjection.project(effect: Effect.captureUnavailable, targetAppName: "Slack")
        XCTAssertEqual(result, .notice(.captureUnavailable))
    }

    /// The machine's `.ended` carries the outcome into terminal handling: a completed session's
    /// audio is in the pipeline's hands, so the widget freezes the waveform into TRANSCRIBING
    /// (`PRODUCT_SPEC.md:93-95` — the freeze is a fact about the microphone closing, which `.ended`
    /// is the machine's statement of, not about the pipeline's progress); an Escape-cancelled
    /// session has nothing to show, so the widget returns to IDLE.
    func testEndedMapsToTerminalHandlingThroughTheOutcome() {
        XCTAssertEqual(
            WidgetProjection.project(effect: ended(.retained(.keyUp)), targetAppName: "Slack"),
            .state(.transcribing),
            "a completed ending must freeze the waveform into TRANSCRIBING whatever the stop rule")
        XCTAssertEqual(
            WidgetProjection.project(effect: ended(.userCancelled), targetAppName: "Slack"),
            .state(.idle),
            "an Escape-cancelled ending must return to IDLE")
    }

    // MARK: - The pipeline-phase inputs

    /// The full IDLE → OPENING → RECORDING → TRANSCRIBING → DELIVERED → IDLE path over the seam:
    /// the machine's effects drive the first four legs, the pipeline's ``WidgetProjectionEvent``s
    /// the last two, and every leg is a headless fold over the projection's own vocabulary.
    /// (The 600 ms DELIVERED → IDLE *collapse* is the reducer's clock fold — `WidgetStateReducerTests`
    /// owns it; `.finishedWithoutDelivery` is the skip/empty-buffer exit and the widget's way back
    /// to IDLE when there is nothing to confirm.)
    func testTheFullLifecyclePathOverTheSeam() {
        XCTAssertEqual(
            projectedState(WidgetProjection.project(effect: Effect.opening, targetAppName: "Slack")),
            .opening(targetAppName: "Slack"))
        XCTAssertEqual(
            projectedState(WidgetProjection.project(effect: Effect.started, targetAppName: "Slack")),
            .recording)
        XCTAssertEqual(
            projectedState(WidgetProjection.project(effect: ended(.retained(.ceilingReached)), targetAppName: "Slack")),
            .transcribing)
        XCTAssertEqual(
            projectedState(WidgetProjection.project(event: .textDelivered(targetAppName: "Slack"))),
            .delivered(targetAppName: "Slack"))
        XCTAssertEqual(
            projectedState(WidgetProjection.project(event: .finishedWithoutDelivery)),
            .idle)
    }

    /// The opening state carries the target name the composition root resolved — the machine never
    /// sees a target, so the name arrives with the fold and surfaces verbatim (`PRODUCT_SPEC.md:38`).
    func testOpeningCarriesTheTargetNameVerbatim() {
        XCTAssertEqual(
            WidgetProjection.project(effect: Effect.opening, targetAppName: "Mail"),
            .state(.opening(targetAppName: "Mail")))
        XCTAssertEqual(
            WidgetProjection.project(effect: Effect.opening, targetAppName: "Xcode"),
            .state(.opening(targetAppName: "Xcode")))
    }

    /// The delivered state carries the *pipeline's* name, not a replayed opening name — the ladder
    /// typed into what its `TargetContext` said, and focus can move between the press and the
    /// delivery, so the confirmation must name the actual recipient.
    func testDeliveredCarriesThePipelinesOwnTargetName() {
        XCTAssertEqual(
            WidgetProjection.project(event: .textDelivered(targetAppName: "Notes")),
            .state(.delivered(targetAppName: "Notes")))
        XCTAssertEqual(
            WidgetProjection.project(event: .textDelivered(targetAppName: "Terminal")),
            .state(.delivered(targetAppName: "Terminal")))
    }

    /// A pipeline that finishes without a delivery returns the widget to IDLE from anywhere: the
    /// empty-buffer policy skips the transcript (`ASREngine`'s silence-is-a-transcript rule) and a
    /// failed run is routed to the FAILSAFE surface, so in both cases the live widget has nothing
    /// left to show.
    func testFinishedWithoutDeliveryReturnsToIdleFromAnyState() {
        let result = WidgetProjection.project(event: .finishedWithoutDelivery)
        XCTAssertEqual(result, .state(.idle))
    }

    // MARK: - The LiveLevelSource seam

    /// A `LiveLevelSource` fake round-trips its latest level — the seam is one synchronous read of
    /// a value the real conformance (`VoccaAudio`'s capture-graph peak) already published, so the
    /// widget's ~60 ms refresh never reaches into the realtime graph.
    func testALiveLevelSourceFakeRoundTripsItsLatestLevel() {
        let source = FakeLevelSource(level: 0.5)
        XCTAssertEqual(source.latestLevel(), 0.5)
    }

    /// The read is a read of the current value, not a snapshot: the conformance publishes from the
    /// realtime callback and the widget reads whatever is latest at refresh time.
    func testTheLevelSourceReadIsAReadOfTheCurrentValue() {
        var source = FakeLevelSource(level: 0)
        XCTAssertEqual(source.latestLevel(), 0)
        source.level = 0.25
        XCTAssertEqual(source.latestLevel(), 0.25)
        source.level = 1
        XCTAssertEqual(source.latestLevel(), 1)
    }

    /// The seam is `Sendable` — pinned at compile time by capturing the existential in a
    /// `@Sendable` closure, which stops compiling the day the conformance requirement weakens.
    func testTheLevelSourceSeamIsSendable() {
        let source: any LiveLevelSource = FakeLevelSource(level: 0.5)
        let read: @Sendable () -> Float = { source.latestLevel() }
        XCTAssertEqual(read(), 0.5)
    }

    // MARK: - Fixtures

    private func ended(_ reason: EndReason) -> Effect {
        .ended(SessionOutcome.make(reason: reason, audio: RecordingSource.Buffer(session: 1, frames: [])))
    }

    private func projectedState(
        _ result: WidgetProjectionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WidgetState {
        switch result {
        case .state(let state):
            return state
        case .notice, .noChange:
            XCTFail("expected a state, got a non-state result", file: file, line: line)
            return .idle
        }
    }
}

/// The level-source fake the projection tests drive: a plain value conformer, exactly what the
/// seam promises (`LiveLevelSource.swift` — one synchronous read, no graph reach).
private struct FakeLevelSource: LiveLevelSource {
    var level: Float
    func latestLevel() -> Float { level }
}
