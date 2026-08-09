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

/// The download window's decision table (`download-ui` Phase 2): every event × state
/// transition, pinned headlessly — the window itself is thin glue "executed by nothing in
/// CI" (it needs a window server session), so this table is the decision.
final class DownloadStateReducerTests: XCTestCase {

    private func reduce(_ events: [ModelDownloadEvent]) -> DownloadState {
        events.reduce(DownloadState.idle) { DownloadStateReducer.reduce($0, event: $1) }
    }

    /// Progress moves the state; monotonicity is enforced by clamping (a backwards value
    /// cannot regress the bar).
    func testProgressClampsMonotonically() {
        let state = reduce([.progress(0.25), .progress(0.1), .progress(0.9)])
        XCTAssertEqual(state, .downloading(0.9), "a backwards progress must be clamped")
    }

    /// Progress outside 0...1 is clamped into range.
    func testProgressIsClampedIntoUnitRange() {
        XCTAssertEqual(reduce([.progress(-1)]), .downloading(0))
        XCTAssertEqual(reduce([.progress(2)]), .downloading(1))
    }

    /// `.committed` is terminal: nothing after it moves the state.
    func testCommittedIsTerminal() {
        let state = reduce([.progress(0.5), .committed, .progress(0.75), .failed("late")])
        XCTAssertEqual(state, .committed, "committed is terminal — late events are ignored")
    }

    /// `.failed` and `.cancelled` are terminal; `.cancelled` reads as `.skipped` at the UI.
    func testFailedAndCancelledAreTerminalAndCancelledReadsAsSkipped() {
        XCTAssertEqual(
            reduce([.progress(0.5), .failed("weights.bin")]), .failed("weights.bin"))
        let afterFailed = reduce([.progress(0.5), .failed("x"), .progress(0.9)])
        XCTAssertEqual(afterFailed, .failed("x"), "failed is terminal")

        XCTAssertEqual(reduce([.progress(0.3), .cancelled]), .skipped)
        let afterCancelled = reduce([.progress(0.3), .cancelled, .committed])
        XCTAssertEqual(afterCancelled, .skipped, "cancelled is terminal — a late commit is ignored")
    }

    /// The full happy path: progress to 1.0 then committed.
    func testTheHappyPath() {
        XCTAssertEqual(
            reduce([.progress(0.25), .progress(0.5), .progress(1.0), .committed]),
            .committed)
    }
}
