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

    /// The C API's segment timestamps are **centiseconds** — each raw unit is 10 ms, verified
    /// against the pinned v1.9.2 header (token and VAD times documented "in centiseconds") and
    /// source (`seek = offset_ms/10`, segment times built from it) — and the transcript's ranges
    /// are seconds. The bridge never divides: it calls this pure conversion, so the unit knowledge
    /// lives here, in the headless core, where CI can reach it (`WhisperCoreTests`).
    ///
    /// The negative policy is decided and pinned: a negative count (a whisper anomaly — the C
    /// layer's own `std::max` guards usually prevent it — not a caller bug) clamps to zero, because
    /// a timestamp that cannot exist must never crash the process or surface as a negative range.
    public static func seconds(fromCentiseconds centiseconds: Int64) -> Double {
        Double(max(0, centiseconds)) / 100.0
    }

    /// Builds the `Transcript` for one transcription — batch or streaming pass.
    ///
    /// - Parameters:
    ///   - segments: The bridge's per-segment answer. Empty is legitimate — near-silent audio is a
    ///     valid empty transcript, per PRD M3.
    ///   - duration: How long the transcribed audio was, in seconds — the engine passes the
    ///     buffer's `audioDuration`. It is the source of the transcript's duration, never the
    ///     segments' span, which whisper may pad or omit.
    ///   - missingSampleCount: The capture-completeness count the capture bridge feeds through
    ///     the buffer; 0 means complete.
    ///   - isFinal: `false` for a streaming partial, `true` for a batch transcript and the
    ///     stream's final — the default keeps every existing batch call site byte-identical.
    public static func map(
        segments: [WhisperSegment],
        duration: Double,
        missingSampleCount: Int = 0,
        isFinal: Bool = true
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
            isFinal: isFinal,
            audioDuration: duration,
            missingSampleCount: missingSampleCount)
    }
}
