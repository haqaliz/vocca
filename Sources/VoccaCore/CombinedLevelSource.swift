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

/// The level of whichever source is actually live — the waveform's answer to there being **two
/// capture graphs and one widget**.
///
/// The composition root builds a graph per activation mode (hold-to-talk and toggle each own their
/// microphone, so the two can never disagree about who holds the input), but only the *active*
/// mode's graph is ever started. The widget has one waveform, and wiring it to a single named
/// graph is a standing bet that that graph is the one running.
///
/// That bet was lost the moment toggle became the shipped default: the level source still pointed
/// at the hold-to-talk graph, `MicrophoneLevelSource` gated on its `isRunning` and answered 0
/// forever, and the waveform drew thirteen identical dashes through an entire dictation — a
/// perfect picture of silence over a microphone that was working. The widget's one job here is to
/// be the "it heard me" signal (`PRODUCT_SPEC.md:87-88`), and it was reporting the opposite.
///
/// ## Why the maximum, rather than asking which mode is active
///
/// This type does not know about modes, and deliberately: it would be a second place to keep the
/// answer, and the failure above *was* two places disagreeing. Instead it leans on the contract
/// every ``LiveLevelSource`` already has — **a source whose graph is stopped or idle reports 0**
/// (`MicrophoneLevelSource`'s own guard). Given that, the maximum across the sources is exactly
/// the running one's level, because every other term is zero.
///
/// It also degrades sensibly rather than cleverly if that assumption is ever violated: with two
/// graphs somehow live at once, the waveform tracks the louder input instead of picking one by a
/// rule the user cannot see. And with no sources at all it is silence, which is the same answer a
/// Mac with no input device already gets.
public struct CombinedLevelSource: LiveLevelSource {

    /// The sources to read, in no particular order — the maximum is order-independent, which is
    /// the point.
    private let sources: [any LiveLevelSource]

    /// - Parameter sources: every level source the widget might need to reflect. Passing one is
    ///   legal and behaves exactly like that source.
    public init(_ sources: [any LiveLevelSource]) {
        self.sources = sources
    }

    /// The greatest level any source reports, or 0 when there are none.
    ///
    /// Still one synchronous read per source and nothing else — the seam's "never blocks the
    /// caller" half holds because each term already holds it.
    public func latestLevel() -> Float {
        sources.reduce(0) { peak, source in
            let level = source.latestLevel()
            return level > peak ? level : peak
        }
    }
}
