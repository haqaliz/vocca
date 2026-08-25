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

/// The level-history-to-waveform mapping's table (`widget-live-states` Task 2): a pure function, so
/// the whole visual contract — the history plotted against time, silence at zero, right-aligned
/// fill, the 0...1 clamp, and the Reduce Motion flat meter (`PRODUCT_SPEC.md:289`) — runs headless;
/// the view is thin glue over it.
///
/// Levels are chosen as binary-exact fractions so the assertions are about the mapping, not about
/// Float rounding.
final class WaveformMappingTests: XCTestCase {

    /// Zero levels produce silent bars — every bar exactly 0, whatever the bar count and the
    /// motion flag. Silence is not a shape; it is zeros.
    func testZeroLevelsProduceSilentBars() {
        for count in [1, 2, 7, 13] {
            for reduceMotion in [false, true] {
                XCTAssertEqual(
                    WaveformMapping.barHeights(
                        levels: [Float](repeating: 0, count: count), barCount: count,
                        reduceMotion: reduceMotion),
                    [Float](repeating: 0, count: count),
                    "zero levels must be silent at \(count) bars (reduceMotion: \(reduceMotion))")
            }
        }
    }

    /// An empty history is silence, not a crash: the view asks for bars before its first refresh
    /// has run, and a freshly mounted waveform has nothing to plot yet.
    func testAnEmptyHistoryIsSilence() {
        XCTAssertEqual(
            WaveformMapping.barHeights(levels: [], barCount: 13, reduceMotion: false),
            [Float](repeating: 0, count: 13))
        XCTAssertEqual(
            WaveformMapping.barHeights(levels: [], barCount: 13, reduceMotion: true),
            [Float](repeating: 0, count: 13),
            "the flat meter over an empty history is silent too, never a crash on `last`")
    }

    /// **The point of the whole mapping**: each bar is one reading, in order, verbatim. The bars
    /// plot level against time — that is what makes `PRODUCT_SPEC.md:41-47`'s irregular
    /// `▁▃▅█▆▃▁▂▅█▇▄▂` possible at all.
    func testEachBarIsItsOwnReadingInOrder() {
        let history: [Float] = [0, 0.25, 0.5, 1, 0.75, 0.5, 0.25]
        XCTAssertEqual(
            WaveformMapping.barHeights(levels: history, barCount: 7, reduceMotion: false),
            history,
            "the history is plotted as given — nothing is shaped, smoothed or enveloped")
    }

    /// The regression test for the defect this mapping was rewritten to fix.
    ///
    /// The previous mapping took a single level and scaled a fixed symmetric window by it, so the
    /// *shape* was a constant and only its height varied: two utterances as different as a rising
    /// note and a falling one produced the same picture whenever their peaks matched. Speech that
    /// looks identical on screen while sounding completely different is the same failure as a
    /// canned animation (`PRODUCT_SPEC.md:88`), just harder to notice.
    ///
    /// So: same peak, same mean, opposite time order — the bars must differ.
    func testHistoriesWithTheSamePeakButDifferentShapesRenderDifferently() {
        let rising: [Float] = [0, 0.25, 0.5, 0.75, 1]
        let falling: [Float] = rising.reversed()

        let risingBars = WaveformMapping.barHeights(
            levels: rising, barCount: 5, reduceMotion: false)
        let fallingBars = WaveformMapping.barHeights(
            levels: falling, barCount: 5, reduceMotion: false)

        XCTAssertEqual(risingBars.max(), fallingBars.max(), "the peaks are equal by construction")
        XCTAssertNotEqual(
            risingBars, fallingBars,
            "a waveform that cannot tell a rise from a fall is not showing the input's shape")
    }

    /// Fewer readings than bars fill from the **right**: the padding is older than every real
    /// reading, so it belongs in front. A microphone that just opened grows into the widget
    /// instead of opening on a full-width shape it has measured nothing for.
    func testAShortHistoryIsRightAlignedAndPaddedWithSilence() {
        XCTAssertEqual(
            WaveformMapping.barHeights(levels: [0.5, 1], barCount: 5, reduceMotion: false),
            [0, 0, 0, 0.5, 1])
    }

    /// More readings than bars keeps the **newest**: the waveform scrolls, and what scrolls off
    /// the left is the oldest audio.
    func testALongHistoryKeepsTheNewestReadings() {
        XCTAssertEqual(
            WaveformMapping.barHeights(
                levels: [0.125, 0.25, 0.375, 0.5, 0.75, 1], barCount: 3, reduceMotion: false),
            [0.5, 0.75, 1])
    }

    /// Levels are clamped into 0...1: the source's contract is 0...1
    /// (`LiveLevelSource.swift`), and the mapping defends the bars against a conformance that lies
    /// rather than drawing out of range.
    func testLevelsAreClampedIntoTheValidRange() {
        XCTAssertEqual(
            WaveformMapping.barHeights(levels: [-1, 0.5, 2], barCount: 3, reduceMotion: false),
            [0, 0.5, 1])
        XCTAssertEqual(
            WaveformMapping.barHeights(levels: [0.5, 7], barCount: 3, reduceMotion: true),
            [1, 1, 1],
            "the flat meter clamps its newest reading too")
    }

    /// Reduce Motion renders a flat meter at the **newest** level — never the scrolling history,
    /// because a wave travelling across the widget is exactly the motion the setting asks to be
    /// spared (`PRODUCT_SPEC.md:289`).
    func testReduceMotionProducesAStaticFlatMeterOverTheNewestReading() {
        let bars = WaveformMapping.barHeights(
            levels: [0, 0.25, 1, 0.5], barCount: 4, reduceMotion: true)
        XCTAssertEqual(bars, [0.5, 0.5, 0.5, 0.5], "every bar is the newest reading, flat")
        XCTAssertEqual(Set(bars).count, 1, "a flat meter has exactly one height, by definition")
    }

    /// A single bar is the newest reading itself, in both renderings — there is no room for a
    /// history in one bar, and nothing to shape it with.
    func testASingleBarIsTheNewestReading() {
        XCTAssertEqual(
            WaveformMapping.barHeights(levels: [0.25, 0.75], barCount: 1, reduceMotion: false),
            [0.75])
        XCTAssertEqual(
            WaveformMapping.barHeights(levels: [0.25, 0.75], barCount: 1, reduceMotion: true),
            [0.75])
    }

    /// Every bar stays within 0...1 for any input, so the view can multiply a height by its frame
    /// without ever drawing outside it.
    func testEveryBarStaysWithinZeroAndOne() {
        let hostile: [Float] = [-99, 0, 0.5, 1, 99, -0.001, 1.001]
        for count in [1, 3, 13] {
            for reduceMotion in [false, true] {
                for height in WaveformMapping.barHeights(
                    levels: hostile, barCount: count, reduceMotion: reduceMotion)
                {
                    XCTAssertGreaterThanOrEqual(height, 0)
                    XCTAssertLessThanOrEqual(height, 1)
                }
            }
        }
    }

    /// The bar count is honoured exactly, whatever the history's length — the view lays out a
    /// fixed row and a short or long return would silently reshape the widget.
    func testTheBarCountIsAlwaysHonoured() {
        for historyLength in [0, 1, 5, 13, 40] {
            let history = [Float](repeating: 0.5, count: historyLength)
            for count in [1, 7, 13] {
                XCTAssertEqual(
                    WaveformMapping.barHeights(
                        levels: history, barCount: count, reduceMotion: false).count,
                    count,
                    "\(historyLength) readings into \(count) bars")
            }
        }
    }
}
