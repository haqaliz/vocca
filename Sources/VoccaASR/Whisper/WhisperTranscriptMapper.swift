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

/// The pure mapping from the bridge's `[WhisperSegment]` answer to the seam's `Transcript` — every
/// *decision* the adapter's transcription path contains, in primitives so that no C-API name lives
/// here.
///
/// The bridge (`WhisperCAPI.swift`, a later phase) extracts segments from the C context and calls
/// this; the seam's contract is then satisfied by construction: attribution (`Transcript/engine`
/// is non-optional and set here to this engine's own identity — a whisper mapper can only produce
/// whisper transcripts), the empty-segments policy (no segments is a valid empty transcript, never
/// an error), and the completeness count (carried, never dropped — the I1 link the capture bridge
/// feeds through the buffer).
public enum WhisperTranscriptMapper {

    /// Builds the `Transcript` for one batch transcription.
    ///
    /// - Parameters:
    ///   - segments: The bridge's per-segment answer. Empty is legitimate — near-silent audio is a
    ///     valid empty transcript, per PRD M3.
    ///   - duration: How long the transcribed audio was, in seconds — the engine passes the
    ///     buffer's `audioDuration`. It is the source of the transcript's duration, never the
    ///     segments' span, which whisper may pad or omit.
    ///   - missingSampleCount: The capture-completeness count the capture bridge feeds through
    ///     the buffer; 0 means complete.
    public static func map(
        segments: [WhisperSegment],
        duration: Double,
        missingSampleCount: Int = 0
    ) -> Transcript {
        Transcript(
            text: segments.map(\.text).joined(separator: " "),
            segments: segments.map { segment in
                TranscriptSegment(
                    text: segment.text,
                    range: segment.start..<segment.end,
                    confidence: segment.tokenProbability)
            },
            engine: WhisperCppEngineIdentity.whisper,
            isFinal: true,
            audioDuration: duration,
            missingSampleCount: missingSampleCount)
    }
}
