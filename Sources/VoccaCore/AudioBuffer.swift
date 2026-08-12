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

/// Immutable PCM in the one format the ASR seam speaks: **16 kHz mono Float32**
/// (`ARCHITECTURE.md:129-135`).
///
/// Engines that want something else convert internally, never the caller — that is what makes the
/// two engines (and the future hosted one) swappable without either one learning about
/// microphones. The type is deliberately not `AVAudioFormat` (an AVFoundation type, which this
/// module may not import): a `Sendable` value that needs nothing below the seam.
///
/// ## The format is asserted, not checked at runtime
///
/// The initializer traps on any sample rate other than 16 kHz. The rule it enforces lives in
/// ``isValidFormat(sampleRate:channelCount:)`` so that it is testable on its own — a `precondition`
/// cannot be caught in-process, and a trap that cannot be tested was satisfiable by any predicate
/// at all (the `AudioRingBuffer.isValidCapacity` pattern). Every near miss — 44.1 kHz, 48 kHz,
/// stereo, zero rate — is one field away from correct and is a real regression somebody could
/// ship.
///
/// Channel count is not a stored field because mono is *structural*: a flat `[Float]` of frames
/// has no way to carry more than one channel, so the claim "mono" cannot be false about a value of
/// this type. The predicate still takes a `channelCount` so that the mono half of the seam's
/// claim can be pinned by a test rather than trusted.
public struct AudioBuffer: Sendable, Hashable {
    /// Frames per second at the seam. The only legal value; see ``isValidFormat(sampleRate:channelCount:)``.
    public static let interchangeSampleRate = 16_000

    /// Channels at the seam. The only legal value; mono is structural in ``samples``.
    public static let interchangeChannelCount = 1

    /// The frames, sampled at ``interchangeSampleRate`` Hz, mono. Nothing about the amplitude
    /// range is enforced — a -1.0...1.0 convention is the producer's contract, not this type's.
    public let samples: [Float]

    /// Always ``interchangeSampleRate`` at seam boundaries; asserted by the initializer.
    public let sampleRate: Int

    /// How many samples the capture ring refused before this buffer was handed over — the
    /// completeness link (I1): `0` means the buffer holds everything that was captured, `N`
    /// means the transcript produced from it is short by exactly N samples.
    ///
    /// The value travels with the audio so that short audio can never masquerade as complete:
    /// the capture bridge (asr-seam Phase 3) populates it from the ring's `refusedSampleCount`,
    /// and the engine carries it onto the ``Transcript``. The default of `0` is the honest
    /// value for every buffer that is not known to be short.
    public let missingSampleCount: Int

    /// Whether `(sampleRate, channelCount)` is exactly the interchange format.
    ///
    /// The testable half of the seam's claim. The initializer enforces this for the mono case the
    /// type can actually hold; this predicate exists so that the near misses — including the
    /// stereo one, which the type's structure already rules out — can be shown to be rejected.
    public static func isValidFormat(sampleRate: Int, channelCount: Int) -> Bool {
        sampleRate == interchangeSampleRate && channelCount == interchangeChannelCount
    }

    /// The duration of the audio in seconds.
    public var audioDuration: Double {
        Double(samples.count) / Double(sampleRate)
    }

    public init(samples: [Float], sampleRate: Int, missingSampleCount: Int = 0) {
        precondition(
            Self.isValidFormat(sampleRate: sampleRate, channelCount: Self.interchangeChannelCount),
            """
            AudioBuffer speaks exactly \(Self.interchangeSampleRate) Hz mono. \(sampleRate) Hz was \
            supplied. Engines convert internally, never the caller — a buffer in any other format \
            is a bug at the boundary, not a request to resample.
            """)
        precondition(
            missingSampleCount >= 0,
            "a negative missing-sample count is a caller bug: the ring cannot have refused fewer than zero samples")
        self.samples = samples
        self.sampleRate = sampleRate
        self.missingSampleCount = missingSampleCount
    }
}

/// The session machine's buffer, once the capture bridge exists to fill it.
///
/// ``CapturedAudio`` was written while "the buffer type belongs to `VoccaAudio`" — the ASR seam
/// landed first, so the one buffer that must cross every seam lives here instead. This conformance
/// is what lets `SessionMachine<AudioBuffer>` hold the real capture path: a session's hand-over is
/// the ASR seam's own type, completeness link included, which is the C1→C2 bridge the asr seam
/// recorded as gated on the capture merge (`missingSampleCount` populated from the ring's
/// `refusedSampleCount`).
extension AudioBuffer: CapturedAudio {}
