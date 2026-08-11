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

/// One transcribed segment as the whisper bridge produces it — the abstract value the mapper
/// (and Phase 1's tests) consume, so that nothing here depends on the C API existing.
///
/// ``start`` and ``end`` are seconds from the start of the transcribed buffer — the bridge
/// converts the C API's centiseconds, exactly as it converts the sample format; the *mapper*
/// never sees the C units. ``tokenProbability`` is the segment-level probability the bridge
/// derives from the C API's per-token log-probabilities (translation, like the units): `nil`
/// means the C context exposed none, and the mapper surfaces exactly that.
public struct WhisperSegment: Sendable, Equatable, Hashable {
    /// The segment's transcribed text.
    public let text: String

    /// Where the segment starts, in seconds from the buffer's start.
    public let start: Double

    /// Where the segment ends, in seconds from the buffer's start.
    public let end: Double

    /// The segment's token probability in `0...1`, or `nil` where the API exposes none.
    public let tokenProbability: Float?

    public init(text: String, start: Double, end: Double, tokenProbability: Float?) {
        self.text = text
        self.start = start
        self.end = end
        self.tokenProbability = tokenProbability
    }
}
