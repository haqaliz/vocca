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

/// One piece of a transcript, with where it came from and how sure the engine is
/// (`ARCHITECTURE.md:146-150`).
///
/// The ``range`` is relative to the audio that was transcribed — seconds from the start of the
/// buffer, as ``AudioBuffer/audioDuration`` measures it. It is a `Range` (not a `ClosedRange`)
/// deliberately: the spec chose the explicit, no-empty-range-ambiguity representation
/// (`spec.md:120-121`).
///
/// ``confidence`` is `nil` when the engine exposes no confidence at all. That is a fact about the
/// engine, not a missing value — a caller must not paper it over with a fabricated number.
public struct TranscriptSegment: Sendable, Hashable {
    /// The text of this segment.
    public let text: String

    /// The segment's position in the transcribed audio, in seconds.
    public let range: Range<Double>

    /// The engine's confidence in this segment, `0...1`, or `nil` where the engine exposes none.
    public let confidence: Float?

    public init(text: String, range: Range<Double>, confidence: Float?) {
        self.text = text
        self.range = range
        self.confidence = confidence
    }
}
