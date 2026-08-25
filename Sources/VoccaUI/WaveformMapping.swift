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

import Foundation
import VoccaCore

/// The level-history → bar-heights mapping the waveform view renders — a pure function, so the
/// whole visual contract runs headless (`WaveformMappingTests`); the view is thin glue over it.
///
/// ## The bars are a time history, not one instant shaped into a hump
///
/// `PRODUCT_SPEC.md:41-47` draws the waveform, in both RECORDING and TRANSCRIBING, as
/// `▁▃▅█▆▃▁▂▅█▇▄▂` — **thirteen bars, and irregular**. That irregularity is the whole content of
/// the picture: it is what a level looks like *plotted against time*, one bar per past reading,
/// scrolling left as new readings arrive. It is what makes the waveform "track input level, not a
/// canned animation" (`PRODUCT_SPEC.md:88`) legible to a user — you can see your own speech in it.
///
/// This mapping originally read that art as `▁▃▅█▅▃▁`: seven bars, symmetric, every bar the *same*
/// instant's level scaled by a fixed positional window. That renders a hump that only ever grows
/// and shrinks as a whole — it does respond to the microphone, so it was not a canned animation,
/// but it can never show *shape*, because there is only one number in it. Speaking a word and
/// speaking a sentence produce the same picture at different heights. The symmetric spec art it
/// was written against does not appear anywhere in `PRODUCT_SPEC.md`.
///
/// So the input is a **window of recent levels**, oldest first, newest last, and each bar is one
/// reading. Nothing is shaped, smoothed or enveloped on the way through — the aspect spec's
/// "waveform smoothing/audio processing beyond the level mapping" stays out of scope, and a bar is
/// still exactly the level the microphone reported at that moment.
///
/// **The static level meter** (`reduceMotion: true`, `PRODUCT_SPEC.md:289` — read from
/// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` by the view, injected here): every
/// bar sits at the *newest* level — a flat read of the input, never a scrolling history, because
/// a wave travelling across the widget is precisely the motion the setting asks to be spared. A
/// canned waveform is a spec violation (`PRODUCT_SPEC.md:88`), and a flat meter over a live level
/// is the honest Reduce Motion rendering of one.
///
/// The input contract is 0...1 (`LiveLevelSource.swift`); the clamp defends the bars against a
/// conformance that lies rather than drawing out of range, and keeps every bar in 0...1.
public enum WaveformMapping {

    /// The bar heights for a window of recent level readings.
    ///
    /// - Parameters:
    ///   - levels: recent readings, **oldest first, newest last** — the view's history ring. Fewer
    ///     than `barCount` readings are right-aligned and the missing older bars read as silence,
    ///     so a freshly opened microphone fills from the right instead of jumping to a full-width
    ///     shape it has no data for. More than `barCount` keeps the newest `barCount`.
    ///   - barCount: how many bars the view draws — `PRODUCT_SPEC.md:41-47`'s art is thirteen; the
    ///     view picks its own. Must be at least 1.
    ///   - reduceMotion: render the static level meter over the newest reading instead of the
    ///     scrolling history (`PRODUCT_SPEC.md:289`).
    /// - Returns: `barCount` heights, each in 0...1.
    public static func barHeights(
        levels: [Float],
        barCount: Int,
        reduceMotion: Bool
    ) -> [Float] {
        precondition(barCount >= 1, "a waveform needs at least one bar")
        let clamp = { (value: Float) in min(1, max(0, value)) }
        // The newest reading is the meter's whole content, and an empty history is silence rather
        // than a crash — the view asks for bars before the first refresh has run.
        let newest = clamp(levels.last ?? 0)
        guard !reduceMotion else {
            return [Float](repeating: newest, count: barCount)
        }
        let window = levels.suffix(barCount).map(clamp)
        // Right-aligned: the padding is *older* than every real reading, so it goes in front.
        return [Float](repeating: 0, count: barCount - window.count) + window
    }
}
