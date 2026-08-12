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

/// The level → bar-heights mapping the waveform view renders — a pure function, so the whole
/// visual contract runs headless (`WaveformMappingTests`); the view is thin glue over it.
///
/// ## The two renderings
///
/// **The waveform** (`reduceMotion: false`): the level is clamped into 0...1 and shaped by a
/// symmetric window — the edges of the bar set sit at a quarter of the level, the center carries
/// it whole — which is the `PRODUCT_SPEC.md:49` art's `▁▃▅█▅▃▁` read. Each bar is `level × window`,
/// so every bar is monotonic in the level (a waveform that shrank while the voice got louder would
/// be a lie about the input), zero is silence exactly, and the center bar is the truth of the
/// level.
///
/// **The static level meter** (`reduceMotion: true`, `PRODUCT_SPEC.md:289` — read from
/// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` by the view, injected here): every
/// bar sits at the clamped level — a flat read of the input, never the moving windowed shape. A
/// canned waveform is a spec violation (`PRODUCT_SPEC.md:88`), and a flat meter over a still level
/// is the honest Reduce Motion rendering of one.
///
/// The input contract is 0...1 (`LiveLevelSource.swift`); the clamp defends the bars against a
/// conformance that lies rather than drawing out of range, and keeps every bar in 0...1.
public enum WaveformMapping {

    /// The bar heights for one level reading.
    ///
    /// - Parameters:
    ///   - level: the input level from ``LiveLevelSource/latestLevel()``; clamped into 0...1.
    ///   - barCount: how many bars the view draws — the `PRODUCT_SPEC` art suggests 7; the view
    ///     picks its own. Must be at least 1.
    ///   - reduceMotion: render the static level meter instead of the windowed waveform
    ///     (`PRODUCT_SPEC.md:289`).
    /// - Returns: `barCount` heights, each in 0...1.
    public static func barHeights(
        level: Float,
        barCount: Int,
        reduceMotion: Bool
    ) -> [Float] {
        precondition(barCount >= 1, "a waveform needs at least one bar")
        let clamped = min(1, max(0, level))
        guard !reduceMotion else {
            return [Float](repeating: clamped, count: barCount)
        }
        guard barCount > 1 else { return [clamped] }
        return (0..<barCount).map { index in
            let window = 0.25 + 0.75 * Float(sin(Double.pi * Double(index) / Double(barCount - 1)))
            return clamped * window
        }
    }
}
