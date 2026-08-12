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

import Combine
import SwiftUI
import VoccaCore

/// The waveform: bars rendered from the ``LiveLevelSource`` on a ~60 ms main-actor refresh.
///
/// This view is **glue, and it is executed by nothing in CI** (the window-server precedent): every
/// decision it could make is above it and tested headlessly — the level → bar-heights mapping in
/// ``WaveformMapping`` (`WaveformMappingTests`), the Reduce Motion flag's effect in the same
/// function's injected `reduceMotion` parameter, and the level source's contract in
/// ``LiveLevelSource``. What is left here is a timer, a read, and a row of bars.
///
/// ## The waveform freezes because the refresh stops, not because the view forgets
///
/// `isLive: false` renders the **last** reading's bars: the timer keeps running but the read stops,
/// so the TRANSCRIBING waveform is the RECORDING waveform held in place (`PRODUCT_SPEC.md:93-95`).
/// The view stays mounted across the RECORDING → TRANSCRIBING transition — ``WidgetView`` renders
/// both states in one branch — so `@State` survives and the freeze is a pause, not a reset. A reset
/// would show silence over a session whose audio is in the pipeline's hands, which is the same lie
/// as a canned waveform.
///
/// ## Why the level is never held by this view
///
/// The bars are recomputed from ``LiveLevelSource/latestLevel()`` on every refresh and nothing else
/// is stored — no envelope, no smoothing (the aspect spec's "waveform smoothing/audio processing
/// beyond the level mapping" is out of scope), and the source's 0...1 contract is enforced by
/// ``WaveformMapping``'s defensive clamp rather than trusted. The refresh runs on the main run loop
/// in its common modes — the H10 lesson: a `.default`-mode timer delivers none of its fires through
/// an event-tracking gesture, which is exactly when the user's finger is on the window.
public struct LevelWaveformView: View {

    /// The input level — the widget's only window into the microphone.
    public let level: any LiveLevelSource
    /// Whether the level maps to the static meter instead of the windowed waveform
    /// (`PRODUCT_SPEC.md:289`). The caller reads `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`;
    /// injected here so the mapping's own flag is the same flag the tests drove.
    public let reduceMotion: Bool
    /// Whether the waveform is live. `false` freezes the last reading — TRANSCRIBING's waveform.
    public let isLive: Bool

    /// The bars being drawn: the last live reading's heights, or the frozen ones.
    @State private var bars: [Float]

    /// The level refresh cadence — the plan's ~60 ms (`spec.md` open question; plan-level).
    private static let refreshInterval: TimeInterval = 0.06

    /// The number of bars — the `PRODUCT_SPEC.md:49` art's `▁▃▅█▅▃▁` is seven; the view picks its
    /// own, per ``WaveformMapping``.
    private static let barCount = 7

    /// The refresh tick. Fires on the main run loop in `.common` modes and is harmless while
    /// frozen: `isLive` gates the read, not the timer — the timer is what makes the freeze cheap
    /// to lift.
    private let refresh = Timer.publish(
        every: LevelWaveformView.refreshInterval, on: .main, in: .common).autoconnect()

    /// - Parameters:
    ///   - level: The input level source — the real `VoccaAudio` conformance at ship.
    ///   - reduceMotion: Render the static level meter instead of the moving waveform
    ///     (`PRODUCT_SPEC.md:289`).
    ///   - isLive: Refresh from the level source; `false` freezes the last reading.
    public init(
        level: any LiveLevelSource,
        reduceMotion: Bool,
        isLive: Bool
    ) {
        self.level = level
        self.reduceMotion = reduceMotion
        self.isLive = isLive
        self._bars = State(
            initialValue: WaveformMapping.barHeights(
                level: 0, barCount: LevelWaveformView.barCount, reduceMotion: reduceMotion))
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.primary)
                    .frame(width: 3, height: 2 + CGFloat(height) * 10)
            }
        }
        .frame(height: 14)
        .onReceive(refresh) { _ in
            guard isLive else { return }
            bars = WaveformMapping.barHeights(
                level: level.latestLevel(),
                barCount: LevelWaveformView.barCount,
                reduceMotion: reduceMotion)
        }
    }
}
