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

/// What an ASR engine produced from one buffer of audio (`ARCHITECTURE.md:138-144`).
///
/// ``engine`` is **non-optional on purpose**: attribution is invariant I1, and a transcript with
/// no engine attached could be mis-attributed downstream, or credited to the wrong model in a
/// log. Making the field optional would put "which engine said this?" at the mercy of every
/// call site; making it non-optional means the answer is structural.
///
/// ``isFinal`` is `false` only for streaming partials (C7); batch transcription always yields a
/// final transcript.
///
/// ## The completeness count
///
/// ``missingSampleCount`` is the completeness link (I1) between capture and transcription: when
/// the captured audio was short by N samples, that fact travels on the transcript instead of
/// masquerading as complete. **0 means complete** — that is the documented meaning, and the
/// default. The count is an explicit, named parameter so that short audio says *how* short; it
/// is never skipped into a lie.
public struct Transcript: Sendable, Hashable {
    /// The full transcribed text — the segments joined, or the engine's plain output where it has
    /// no segments.
    public let text: String

    /// The segment-level breakdown, when the engine provides one. Empty when it does not.
    public let segments: [TranscriptSegment]

    /// The engine that produced this transcript. Never nil — see the type documentation.
    public let engine: EngineIdentity

    /// `false` for streaming partials (C7); batch transcription always yields `true`.
    public let isFinal: Bool

    /// How long the transcribed audio was, in seconds.
    public let audioDuration: Double

    /// How many samples of the captured audio never reached the engine. **0 = complete.**
    public let missingSampleCount: Int

    public init(
        text: String,
        segments: [TranscriptSegment],
        engine: EngineIdentity,
        isFinal: Bool,
        audioDuration: Double,
        missingSampleCount: Int = 0
    ) {
        self.text = text
        self.segments = segments
        self.engine = engine
        self.isFinal = isFinal
        self.audioDuration = audioDuration
        self.missingSampleCount = missingSampleCount
    }
}
