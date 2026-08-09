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

/// The pure mapping from the SDK's batch answer to the seam's `Transcript` — every *decision* the
/// adapter's transcription path contains, in primitives so that no `FluidAudio` name lives here.
///
/// The adapter (`ParakeetEngine.swift`) extracts `text` from the SDK's result and calls this; the
/// seam's contract is then satisfied by construction: attribution (``Transcript/engine`` is
/// non-optional and set here), the empty-buffer policy (empty text is a valid empty transcript,
/// never an error), and the completeness count (carried, never dropped — the I1 link the bridge
/// feeds through the buffer).
public enum ParakeetTranscriptMapper {

    /// Builds the `Transcript` for one batch transcription.
    ///
    /// - Parameters:
    ///   - text: The SDK's transcribed text. Empty is legitimate — near-silent audio is a valid
    ///     empty transcript, per PRD M3.
    ///   - buffer: The buffer that was transcribed. Its sample count is the source of
    ///     `audioDuration` — never the text's length, which says nothing about time.
    ///   - engine: This engine's identity; every transcript must be attributed
    ///     (`ARCHITECTURE.md:140-141`).
    ///   - missingSampleCount: The capture-completeness count the bridge (asr-seam Phase 3)
    ///     feeds through the buffer; 0 means complete.
    public static func transcript(
        text: String,
        for buffer: AudioBuffer,
        engine: EngineIdentity,
        missingSampleCount: Int = 0
    ) -> Transcript {
        Transcript(
            text: text,
            segments: [
                TranscriptSegment(
                    text: text,
                    range: 0..<buffer.audioDuration,
                    confidence: nil)
            ],
            engine: engine,
            isFinal: true,
            audioDuration: buffer.audioDuration,
            missingSampleCount: missingSampleCount)
    }
}
