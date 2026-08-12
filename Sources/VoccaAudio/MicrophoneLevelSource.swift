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

import Synchronization
import VoccaCore

/// **The real input level: the `LiveLevelSource` conformance over the capture graph.**
///
/// The widget's waveform comes from here — the "it heard me" signal (`PRODUCT_SPEC.md:87-88`)
/// made real. The level is computed in the capture graph's realtime callback
/// (``AudioBufferListInterleaver/interleave``, the `AVAudioSinkNode` block itself) over the
/// just-written window and published to an atomic; this type reads that atomic on the main actor
/// through the graph seam. The realtime discipline is the repo's own: the callback never allocates
/// or blocks — the peak accounting (``peak(of:count:)``) is marked with the `@realtime` marker and linted by
/// `RealtimeSafetyTests`, and the publish is a plain atomic store.
///
/// ## The two halves of the contract (`LiveLevelSource.swift`)
///
/// **The value is 0...1**: the peak is the greatest sample magnitude of the newest callback —
/// "how loud is the input right now", sign ignored — and a defensive clamp keeps a conformance
/// that lies about the range from lying about the voice. **The value is 0 when the graph is
/// stopped or idle**: the engine only runs during sessions (`AudioCaptureGraph`'s header: a warm
/// engine lights the orange dot), so a stopped graph has no callbacks and no level — the read
/// answers 0 the moment the session ends, which is the "decaying to 0 when the graph is
/// stopped/idle" half. The gate is the graph's own `isRunning` — read off the engine, not
/// remembered, the `AudioCaptureGraph` doctrine — forwarded through ``CaptureGraphSeam`` so the
/// decision runs in this file and in `MicrophoneLevelTests`, never in the one file CI cannot
/// execute a line of.
///
/// ## Why this is `@unchecked Sendable`
///
/// The seam is not `Sendable` (``AudioCaptureGraph`` holds an `AVAudioEngine`), and this type must
/// be — ``LiveLevelSource`` requires it, and the widget's ~60 ms refresh calls `latestLevel()`
/// across the seam. The annotation's claim is narrow and is the ``AppBootstrap`` `WeakBox` shape
/// rather than the ring's: **`latestLevel()` mutates nothing.** The two members it reads are
/// `levelPeak` (a single atomic load) and `isRunning` (the engine's own flag), and the calls
/// themselves are confined to the main actor — the widget's refresh, which is the seam's own
/// documented reader (`LiveLevelSource.swift`: "read on the main actor"). The graph lives in the
/// session's main-actor domain for its whole life (`AudioCaptureGraph`'s isolation paragraph), so
/// no other thread ever touches the object this type reads.
public final class MicrophoneLevelSource: LiveLevelSource, @unchecked Sendable {

    /// The graph, through the seam — the same seam ``MicrophoneSource`` captures through, so the
    /// level and the audio read one graph.
    private let graph: any CaptureGraphSeam

    /// - Parameter graph: the capture graph, already constructed with its configuration-change
    ///   callback. The level reads the graph's ``CaptureGraphSeam/levelPeak`` and
    ///   ``CaptureGraphSeam/isRunning`` — it never calls `start()` or `stop()` itself, because the
    ///   microphone's lifecycle belongs to the session, not to the widget.
    public init(graph: any CaptureGraphSeam) {
        self.graph = graph
    }

    /// The newest published input level, 0...1 — or 0 the moment the graph is stopped or idle.
    public func latestLevel() -> Float {
        guard graph.isRunning else { return 0 }
        return min(1, max(0, graph.levelPeak))
    }

    /// The realtime accounting: the greatest magnitude of `count` samples.
    ///
    /// **This runs on CoreAudio's thread** — called from ``AudioBufferListInterleaver/interleave``,
    /// the `AVAudioSinkNode` block, and marked with the `@realtime` marker so the four-pass lint checks it like
    /// any other realtime body (the F3 lesson: an unmarked helper is an allocation waiting to
    /// happen with every signal green). It allocates nothing and takes no lock: an
    /// `UnsafeBufferPointer` is a two-word non-owning view and `reduce` is the standard fold, which
    /// iterates and applies the closure on the stack.
    ///
    /// The body is deliberately expression-only: `RealtimeSafetyTests` pass 4 forbids mutating an
    /// accumulator on the realtime path, so the fold is the language's own rather than a hand-rolled
    /// loop.
    // @realtime — called from AudioBufferListInterleaver.interleave's realtime body; linted in its
    // own right so a later edit cannot hide an allocation inside the accounting (the `room`
    // precedent, AudioRingBuffer.swift).
    static func peak(of samples: UnsafePointer<Float>, count: Int) -> Float {
        UnsafeBufferPointer(start: samples, count: count).reduce(0) { peak, sample in
            let magnitude = sample < 0 ? -sample : sample
            return magnitude > peak ? magnitude : peak
        }
    }
}
