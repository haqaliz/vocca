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

final class MatrixEvidenceLineTests: XCTestCase {

    func testSessionOpenedLineSpellsTheMode() {
        XCTAssertEqual(
            MatrixEvidenceLine.format(.sessionOpened(mode: .dictation)),
            "session opened mode=dictation")
        XCTAssertEqual(
            MatrixEvidenceLine.format(.sessionOpened(mode: .conversing)),
            "session opened mode=conversing")
    }

    func testAccessibilityDeliveryVerifiedRendersTheFullLine() {
        let result = InjectionResult(
            rung: .accessibility, attempted: [.accessibility], verified: true,
            elapsed: .milliseconds(9))
        XCTAssertEqual(
            MatrixEvidenceLine.format(
                .delivery(targetBundleID: "com.apple.Notes", result: result)),
            "delivery target=com.apple.Notes rung=accessibility attempted: [accessibility] verified=true")
    }

    func testClipboardPasteDeliveryUnverifiedRendersTheFullTrace() {
        let result = InjectionResult(
            rung: .clipboardPaste, attempted: [.accessibility, .clipboardPaste],
            verified: false, elapsed: .milliseconds(21))
        XCTAssertEqual(
            MatrixEvidenceLine.format(
                .delivery(targetBundleID: "com.apple.mail", result: result)),
            "delivery target=com.apple.mail rung=clipboardPaste attempted: [accessibility, clipboardPaste] verified=false")
    }

    func testKeystrokeSynthesisDeliveryRendersItsOwnLine() {
        let result = InjectionResult(
            rung: .keystrokeSynthesis,
            attempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            verified: false, elapsed: .milliseconds(13))
        XCTAssertEqual(
            MatrixEvidenceLine.format(
                .delivery(targetBundleID: "com.apple.Terminal", result: result)),
            "delivery target=com.apple.Terminal rung=keystrokeSynthesis attempted: [accessibility, clipboardPaste, keystrokeSynthesis] verified=false")
    }

    func testWidgetFailsafeOutcomeRendersItsLine() {
        let result = InjectionResult(
            rung: .widgetFailsafe,
            attempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis, .widgetFailsafe],
            verified: false, elapsed: .milliseconds(41))
        XCTAssertEqual(
            MatrixEvidenceLine.format(
                .delivery(targetBundleID: "com.apple.Notes", result: result)),
            "delivery target=com.apple.Notes rung=widgetFailsafe attempted: [accessibility, clipboardPaste, keystrokeSynthesis, widgetFailsafe] verified=false")
    }

    func testRefusalWithAnEmptyTraceRendersTheExactAttemptedSpelling() {
        let result = InjectionResult(
            rung: .widgetFailsafe, attempted: [], verified: false, elapsed: .zero)
        XCTAssertEqual(
            MatrixEvidenceLine.format(
                .delivery(targetBundleID: "com.apple.Terminal", result: result)),
            "delivery target=com.apple.Terminal rung=widgetFailsafe attempted: [] verified=false")
    }

    func testTheAttemptedTraceRendersInTraceOrder() {
        let forward = InjectionResult(
            rung: .clipboardPaste, attempted: [.accessibility, .clipboardPaste],
            verified: false, elapsed: .zero)
        let backward = InjectionResult(
            rung: .clipboardPaste, attempted: [.clipboardPaste, .accessibility],
            verified: false, elapsed: .zero)
        let forwardLine = MatrixEvidenceLine.format(
            .delivery(targetBundleID: "com.apple.Notes", result: forward))
        let backwardLine = MatrixEvidenceLine.format(
            .delivery(targetBundleID: "com.apple.Notes", result: backward))
        XCTAssertEqual(
            forwardLine,
            "delivery target=com.apple.Notes rung=clipboardPaste attempted: [accessibility, clipboardPaste] verified=false")
        XCTAssertEqual(
            backwardLine,
            "delivery target=com.apple.Notes rung=clipboardPaste attempted: [clipboardPaste, accessibility] verified=false")
        XCTAssertNotEqual(
            forwardLine, backwardLine,
            "the trace must render in attempt order, not a fixed ordering")
    }
}