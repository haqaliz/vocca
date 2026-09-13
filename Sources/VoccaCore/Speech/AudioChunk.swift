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

/// One piece of rendered speech, as PCM — the unit the speech seam speaks
/// (`ARCHITECTURE.md:301-305`).
///
/// The synthesizers convert internally to this shape, never the caller — that is what makes
/// Kokoro-82M and `AVSpeechSynthesizer` (and a future hosted provider) swappable without the
/// consumer learning about their formats. The type is deliberately not `AVAudioPCMBuffer` (an
/// AVFoundation type, which this module may not import): a `Sendable` value that needs nothing
/// below the seam.
///
/// ``bytes`` is the PCM payload. The format it encodes — sample rate, channels, bit depth,
/// endianness — is the producer's contract, named by ``sampleRate`` and ``channelCount``; the
/// seam does not decode audio, it moves it. ``duration`` is in seconds, computed by the
/// producer as frames ÷ rate (the seam's "is this plausible audio?" checks, and the second
/// aspect's env-gated benchmark, both read it).
public struct AudioChunk: Sendable, Hashable {
    /// The PCM payload.
    public let bytes: [UInt8]

    /// Frames per second of ``bytes``, as the producer rendered it.
    public let sampleRate: Double

    /// Channels of ``bytes``, as the producer rendered it.
    public let channelCount: Int

    /// How long ``bytes`` sounds for, in seconds — computed by the producer as frames ÷ rate.
    public let duration: Double

    public init(bytes: [UInt8], sampleRate: Double, channelCount: Int, duration: Double) {
        self.bytes = bytes
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
    }
}