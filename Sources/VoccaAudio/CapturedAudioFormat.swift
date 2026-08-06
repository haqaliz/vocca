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

/// The shape of a run of `Float` samples: how fast they were sampled, and how many channels are
/// interleaved into them.
///
/// **Deliberately not `AVAudioFormat`.** `AVAudioFormat` is an AVFoundation type, and the aspect
/// plan forbids AVFoundation types escaping the adapter that speaks to the framework — a rule with
/// three concrete payoffs here rather than one architectural sentiment:
///
/// 1. `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` **returns `nil` for any channel
///    count above two** (measured: 3, 4, 6, 8 and 16 all fail, interleaved or not). A capture format
///    type that cannot represent a four-channel interface is not a capture format type. This struct
///    represents any channel count, and ``AudioFormatConverter`` only ever hands AVFoundation the
///    *mono* formats it is reliable for.
/// 2. It is a `Sendable` value. `AVAudioFormat` is a class, and the format has to be readable from
///    wherever the session is assembled.
/// 3. It keeps `import AVFoundation` inside a single file, which
///    `AudioFormatConverterTests.testTheFilesThatImportAVFoundationAreExactlyTheExpectedSet` pins.
///
/// ## What the sample *type* is, and why it is not a field here
///
/// Float32, always — because the samples are `[Float]` and `Float` is `Float32` on every platform
/// Vocca targets. Adding a `sampleType` field would let a caller *describe* Int16 samples that the
/// array cannot hold. The type system already carries this half of the format; this struct carries
/// only the half it cannot.
///
/// ## Interleaving, which is a claim about the samples and not about this struct
///
/// When ``channelCount`` is greater than one, a run of samples in this format is **interleaved**:
/// frame 0's channels, then frame 1's, and so on. That is not a preference — a single flat
/// `[Float]`, which is what `AudioRingBuffer` yields, has no other way to carry more than one
/// channel.
///
/// **This is an obligation on whoever fills the ring, and it is Phase 4's to discharge.** A
/// CoreAudio `AudioBufferList` for a *deinterleaved* multi-channel device carries one buffer per
/// channel, and the realtime block the plan describes reaches `.pointee.mBuffers.mData` — the first
/// buffer, which is channel 0 alone. Writing that into the ring and then declaring
/// `channelCount: 2` would make this type describe audio the ring does not contain, and the
/// downmix would average channel 0 against itself, silently, forever. Phase 4 must either
/// interleave (work on the realtime thread) or declare `channelCount: 1` because it kept only the
/// first channel. Nothing here can check which it did.
public struct CapturedAudioFormat: Sendable, Equatable, CustomStringConvertible {

    /// Frames per second.
    public let sampleRate: Double

    /// Channels interleaved into each frame. `1` means the samples *are* the frames.
    public let channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// **The one format the ASR seam speaks: 16 kHz, mono, Float32.**
    ///
    /// Acceptance A8 is that this boundary does not move without something failing loudly. Two
    /// mechanisms hold it, and they are different in kind:
    ///
    /// - ``AudioFormatConverter`` reads this constant to build its output format and then reads that
    ///   format *back* out of AVFoundation and compares — so a rate AVFoundation will not honour is
    ///   a construction failure rather than a wrong-rate stream.
    /// - The tests measure the **produced sample count against the ratio**, for every plausible
    ///   hardware rate. One second of input at 44.1 kHz must yield 16000 samples, not 44100 and not
    ///   48000. That is the assertion that reads the rate off the data instead of off this label,
    ///   and it is the one that survives someone editing both this constant and a test that merely
    ///   restates it.
    ///
    /// 16 kHz is not a Vocca preference. It is what Parakeet and whisper.cpp both take
    /// (`ARCHITECTURE.md`), and resampling to it here rather than in the ASR engine is what lets the
    /// two engines be swapped without either one learning about microphones.
    public static let interchange = CapturedAudioFormat(sampleRate: 16_000, channelCount: 1)

    /// Whether this is exactly ``interchange``.
    ///
    /// A predicate rather than an inlined comparison so that it can be shown *rejecting* a
    /// near-miss: 16 kHz stereo and 44.1 kHz mono are each one field away from correct, and each is
    /// a real regression somebody could ship.
    public var isInterchange: Bool { self == Self.interchange }

    /// Whether this describes audio that can exist: a positive rate and at least one channel.
    ///
    /// Split out for the same reason `AudioRingBuffer.isValidCapacity(_:)` is: the rule is then
    /// testable on its own, rather than only observable as a thrown error from a constructor.
    public var isValidCaptureFormat: Bool {
        sampleRate > 0 && sampleRate.isFinite && channelCount > 0
    }

    public var description: String {
        "\(sampleRate) Hz × \(channelCount) ch Float32"
    }
}
