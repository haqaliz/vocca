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

/// The level-to-waveform mapping's table (`widget-live-states` Task 2): a pure function, so the
/// whole visual contract — monotonicity in the level, silence at zero, the 0...1 clamp, and the
/// Reduce Motion flat meter (`PRODUCT_SPEC.md:289`) — runs headless; the view is thin glue over it.
///
/// Levels are chosen as binary-exact fractions so the bar products are exact and the monotonicity
/// assertion is about the mapping, not about Float rounding.
final class WaveformMappingTests: XCTestCase {

    /// Zero level produces silent bars — every bar exactly 0, whatever the bar count and the
    /// motion flag. Silence is not a shape; it is zeros.
    func testZeroLevelProducesSilentBars() {
        for count in [1, 2, 7, 12] {
            for reduceMotion in [false, true] {
                XCTAssertEqual(
                    WaveformMapping.barHeights(level: 0, barCount: count, reduceMotion: reduceMotion),
                    [Float](repeating: 0, count: count),
                    "zero level must be silent at \(count) bars (reduceMotion: \(reduceMotion))")
            }
        }
    }

    /// Monotonic level produces monotonic bars: each bar's height never regresses as the level
    /// rises — a waveform that shrank while the voice got louder would be a lie about the input.
    func testMonotonicLevelProducesMonotonicBars() {
        let levels: [Float] = [0, 0.125, 0.25, 0.5, 0.75, 0.875, 1]
        let barSets = levels.map {
            WaveformMapping.barHeights(level: $0, barCount: 7, reduceMotion: false)
        }
        for bar in 0..<7 {
            let heights = barSets.map { $0[bar] }
            XCTAssertEqual(
                heights, heights.sorted(),
                "bar \(bar) must be monotonic in the level across \(levels)")
        }
    }

    /// The level is clamped into 0...1: anything above 1 renders as 1, anything below 0 renders as
    /// 0 — the source's contract is 0...1 (`LiveLevelSource.swift`), and the mapping defends the
    /// bar against anything else rather than drawing out of range.
    func testTheLevelIsClampedIntoTheValidRange() {
        let atOne = WaveformMapping.barHeights(level: 1, barCount: 7, reduceMotion: false)
        XCTAssertEqual(
            WaveformMapping.barHeights(level: 1.25, barCount: 7, reduceMotion: false), atOne)
        XCTAssertEqual(
            WaveformMapping.barHeights(level: 3.14159, barCount: 7, reduceMotion: false), atOne)

        let atZero = WaveformMapping.barHeights(level: 0, barCount: 7, reduceMotion: false)
        XCTAssertEqual(
            WaveformMapping.barHeights(level: -0.25, barCount: 7, reduceMotion: false), atZero)
        XCTAssertEqual(
            WaveformMapping.barHeights(level: -1, barCount: 7, reduceMotion: false), atZero)
    }

    /// Reduce Motion replaces the waveform with a static level meter (`PRODUCT_SPEC.md:289`): every
    /// bar sits at the clamped level — a flat read of the input, never the moving windowed shape —
    /// and the two renderings are deliberately different at a mid-range level.
    func testReduceMotionProducesAStaticFlatMeter() {
        XCTAssertEqual(
            WaveformMapping.barHeights(level: 0.5, barCount: 7, reduceMotion: true),
            [Float](repeating: 0.5, count: 7))
        XCTAssertEqual(
            WaveformMapping.barHeights(level: 0, barCount: 12, reduceMotion: true),
            [Float](repeating: 0, count: 12))
        XCTAssertEqual(
            WaveformMapping.barHeights(level: 2, barCount: 12, reduceMotion: true),
            [Float](repeating: 1, count: 12))
        XCTAssertNotEqual(
            WaveformMapping.barHeights(level: 0.5, barCount: 7, reduceMotion: true),
            WaveformMapping.barHeights(level: 0.5, barCount: 7, reduceMotion: false),
            "the flat meter must differ from the waveform's windowed shape")
    }

    /// The waveform's windowed shape mirrors around its center — the `PRODUCT_SPEC.md:49` art's
    /// `▁▃▅█▅▃▁` read, symmetric by construction.
    func testTheWaveformShapeIsSymmetric() {
        let bars = WaveformMapping.barHeights(level: 1, barCount: 7, reduceMotion: false)
        XCTAssertEqual(bars, Array(bars.reversed()), "the windowed shape must mirror around its center")
    }

    /// The center bar carries the level; the edges sit lower — the shape that reads as a waveform,
    /// not as a flat meter.
    func testTheCenterBarIsTallerThanTheEdges() {
        let bars = WaveformMapping.barHeights(level: 1, barCount: 7, reduceMotion: false)
        XCTAssertEqual(bars[3], 1, "the center bar must carry the full level")
        XCTAssertLessThan(bars[0], bars[3], "the left edge must sit lower than the center")
        XCTAssertLessThan(bars[6], bars[3], "the right edge must sit lower than the center")
        XCTAssertEqual(bars[0], bars[6], "the edges must sit at the same height")
    }

    /// A single-bar waveform is the level itself — no window to apply, so the bar is the honest
    /// read either way.
    func testASingleBarIsTheLevelItself() {
        XCTAssertEqual(
            WaveformMapping.barHeights(level: 0.75, barCount: 1, reduceMotion: false), [0.75])
        XCTAssertEqual(
            WaveformMapping.barHeights(level: 0.75, barCount: 1, reduceMotion: true), [0.75])
        XCTAssertEqual(
            WaveformMapping.barHeights(level: 2, barCount: 1, reduceMotion: false), [1])
    }

    /// Every bar stays within 0...1 across the level range, both modes — a drawing contract the
    /// view can render without clipping logic.
    func testEveryBarStaysWithinZeroAndOne() {
        let levels: [Float] = [0, 0.125, 0.5, 1, 1.5, -0.5]
        for level in levels {
            for reduceMotion in [false, true] {
                let bars = WaveformMapping.barHeights(
                    level: level, barCount: 12, reduceMotion: reduceMotion)
                XCTAssertTrue(
                    bars.allSatisfy { $0 >= 0 && $0 <= 1 },
                    "bars must stay within 0...1 at level \(level) (reduceMotion: \(reduceMotion))")
            }
        }
    }
}
