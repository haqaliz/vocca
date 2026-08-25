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
/// ## What this view holds, and what it still does not
///
/// It holds a **history**: the last `barCount` readings, so the bars can plot level against time
/// the way `PRODUCT_SPEC.md:41-47`'s `▁▃▅█▆▃▁▂▅█▇▄▂` does. That is the one piece of state the
/// waveform genuinely needs — a single reading cannot have a shape, and the earlier version, which
/// held nothing and scaled a fixed hump by the current level, could only ever pulse as a whole.
///
/// It still holds no *processing*: readings go into the ring exactly as ``LiveLevelSource`` gave
/// them, with no envelope and no smoothing (the aspect spec's "waveform smoothing/audio processing
/// beyond the level mapping" remains out of scope), and the source's 0...1 contract is enforced by
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

    /// The readings behind the bars, oldest first — the last ``barCount`` of them. Frozen in
    /// place when `isLive` is false, which is what holds TRANSCRIBING's waveform still.
    @State private var levels: [Float] = []

    /// The level refresh cadence — the plan's ~60 ms (`spec.md` open question; plan-level).
    private static let refreshInterval: TimeInterval = 0.06

    /// The number of bars — `PRODUCT_SPEC.md:41-47`'s art, `▁▃▅█▆▃▁▂▅█▇▄▂`, is thirteen. At the
    /// refresh cadence below that is about 0.8 s of speech on screen at once, which is roughly a
    /// word: long enough for the shape to read as *this* utterance rather than as a flicker.
    private static let barCount = 13

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
        // No initial reading: an empty history renders as silence, and the first refresh fills it
        // from the right rather than opening on a full-width shape nothing measured.
        self._levels = State(initialValue: [])
    }

    public var body: some View {
        let bars = WaveformMapping.barHeights(
            levels: levels,
            barCount: LevelWaveformView.barCount,
            reduceMotion: reduceMotion)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.primary)
                    .frame(width: 3, height: 2 + CGFloat(height) * 10)
            }
        }
        .frame(height: 14)
        .onReceive(refresh) { _ in
            guard isLive else { return }
            levels.append(level.latestLevel())
            if levels.count > LevelWaveformView.barCount {
                levels.removeFirst(levels.count - LevelWaveformView.barCount)
            }
        }
    }
}
