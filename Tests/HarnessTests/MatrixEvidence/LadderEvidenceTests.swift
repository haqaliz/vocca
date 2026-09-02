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
import VoccaInject
import XCTest

actor CapturingMatrixEvidenceRecorder: MatrixEvidenceRecording {
    private(set) var events: [MatrixEvidenceEvent] = []

    init() {}

    func record(_ event: MatrixEvidenceEvent) async {
        events.append(event)
    }
}

@MainActor
final class LadderEvidenceTests: XCTestCase {

    func testInjectEmitsExactlyOneDeliveryEventMatchingTheResult() async throws {
        let handoff = RecordingFailsafeHandoff()
        let evidence = CapturingMatrixEvidenceRecorder()
        let strategies: [InjectionRung: any InjectionRungStrategy] = [
            .accessibility: FakeInjectionStrategy(rung: .accessibility, outcome: .failed),
            .clipboardPaste: FakeInjectionStrategy(rung: .clipboardPaste, outcome: .succeeded(verified: false)),
            .keystrokeSynthesis: FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .failed),
        ]
        let injector = LadderInjector(
            strategies: strategies,
            order: DefaultInjectionStrategyOrder(allowlist: EmptyInjectionAllowlist()),
            handoff: handoff,
            clock: StepAdvancingClock(step: .milliseconds(20)),
            evidence: evidence)

        let result = await injector.inject(
            "the words",
            into: TargetContext(bundleID: "com.example.Other", windowTitle: nil, isSecureInput: false))

        XCTAssertEqual(result.rung, .clipboardPaste)
        let events = await evidence.events
        XCTAssertEqual(events.count, 1, "the ladder must emit exactly one evidence event per inject call")
        guard case .delivery(let bundleID, let recorded) = events[0] else {
            XCTFail("the emitted event must be a delivery event, not \(events[0])")
            return
        }
        XCTAssertEqual(bundleID, "com.example.Other", "the event names the target the inject ran against")
        XCTAssertEqual(recorded, result, "the event carries the injector's own result, verbatim")
        XCTAssertEqual(recorded.attempted, [.clipboardPaste])
        XCTAssertFalse(recorded.verified)
        XCTAssertEqual(
            MatrixEvidenceLine.format(events[0]),
            "delivery target=com.example.Other rung=clipboardPaste attempted: [clipboardPaste] verified=false",
            "the emitted event must render through the tested line vocabulary")
    }

    func testASecureInputRefusalEmitsTheEmptyTrace() async throws {
        let handoff = RecordingFailsafeHandoff()
        let evidence = CapturingMatrixEvidenceRecorder()
        let injector = LadderInjector(
            strategies: [:],
            order: FakeInjectionStrategyOrder(rungs: [.accessibility, .clipboardPaste, .keystrokeSynthesis]),
            handoff: handoff,
            clock: TestClock(),
            evidence: evidence)

        let result = await injector.inject(
            "the words",
            into: TargetContext(bundleID: "com.example.Notes", windowTitle: nil, isSecureInput: true))

        XCTAssertEqual(result.rung, .widgetFailsafe)
        XCTAssertEqual(result.attempted, [])
        let events = await evidence.events
        XCTAssertEqual(events.count, 1, "the refusal must still emit exactly one evidence event")
        guard case .delivery(let bundleID, let recorded) = events[0] else {
            XCTFail("the emitted event must be a delivery event, not \(events[0])")
            return
        }
        XCTAssertEqual(bundleID, "com.example.Notes")
        XCTAssertEqual(recorded.attempted, [], "the refusal's empty trace must reach the event")
        XCTAssertEqual(
            MatrixEvidenceLine.format(events[0]),
            "delivery target=com.example.Notes rung=widgetFailsafe attempted: [] verified=false",
            "step 92's artifact must render from the emitted event")
    }
}