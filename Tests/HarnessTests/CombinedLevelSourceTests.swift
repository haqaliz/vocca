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

/// ``CombinedLevelSource``: the waveform's answer to there being two capture graphs and one widget.
///
/// The regression these pin is not hypothetical. The widget's level was wired to the hold-to-talk
/// graph by name; when toggle became the shipped default that graph stopped being the one that
/// runs, `MicrophoneLevelSource` answered 0 from its `isRunning` guard, and the pill drew thirteen
/// identical dashes through a whole dictation — a picture of silence over a working microphone,
/// which is the exact opposite of the "it heard me" signal the waveform exists to be
/// (`PRODUCT_SPEC.md:87-88`).
final class CombinedLevelSourceTests: XCTestCase {

    /// A stand-in for one mode's level source. `0` is what a stopped graph reports, which is the
    /// contract the combination leans on.
    private struct FixedLevel: LiveLevelSource {
        let level: Float
        func latestLevel() -> Float { level }
    }

    /// The running graph's level wins, whichever position it is in — the failure was a source
    /// chosen by name, so order must not matter.
    func testTheRunningSourceIsReportedFromEitherPosition() {
        XCTAssertEqual(
            CombinedLevelSource([FixedLevel(level: 0), FixedLevel(level: 0.7)]).latestLevel(), 0.7,
            "the second graph is the live one")
        XCTAssertEqual(
            CombinedLevelSource([FixedLevel(level: 0.7), FixedLevel(level: 0)]).latestLevel(), 0.7,
            "the first graph is the live one — same answer")
    }

    /// Every source idle is silence, not a ghost: with no session running the waveform must draw
    /// nothing rather than the last thing it saw.
    func testAllIdleSourcesReportSilence() {
        XCTAssertEqual(
            CombinedLevelSource([FixedLevel(level: 0), FixedLevel(level: 0)]).latestLevel(), 0)
    }

    /// No sources at all — the Mac with no input device — is silence too, and must not trap on an
    /// empty reduction.
    func testNoSourcesIsSilence() {
        XCTAssertEqual(CombinedLevelSource([]).latestLevel(), 0)
    }

    /// One source behaves exactly like that source, so the combination is never a special case to
    /// reason about at the call site.
    func testASingleSourceIsPassedThrough() {
        XCTAssertEqual(CombinedLevelSource([FixedLevel(level: 0.42)]).latestLevel(), 0.42)
    }

    /// Two live sources — which construction forbids, since only the active mode's graph starts —
    /// track the louder input rather than picking by a rule the user cannot see.
    func testTwoLiveSourcesTrackTheLouderInput() {
        XCTAssertEqual(
            CombinedLevelSource([FixedLevel(level: 0.3), FixedLevel(level: 0.9)]).latestLevel(), 0.9)
    }
}
