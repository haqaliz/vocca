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

import Foundation
import XCTest

// Plain, not `@testable`: everything asserted here is the API a caller gets, which is what makes
// the missing `import AVFoundation` above a claim about the public surface rather than about this
// file's privileges.
import VoccaAudio

/// **Acceptance A2 and A8: captured audio becomes 16 kHz mono Float32, off the realtime thread.**
///
/// Every test here is headless. No microphone, no `AVAudioEngine`, no TCC grant, no device of any
/// kind — the input is a synthesised array of `Float`. That is the point of putting the seam above
/// the node: this is the half of the capture path CI can actually execute, and the plan's rule is
/// that all the branches live here.
///
/// ## This file does not `import AVFoundation`, and that is a check rather than a style choice
///
/// The plan forbids AVFoundation types escaping the adapter. Every input to
/// ``AudioFormatConverter`` in this file is constructed without that import, so no AVFoundation
/// type is *required* to use the API — the compiler enforces that much on every build.
///
/// It is not the whole guarantee, and the gap is worth naming: Swift will let a caller bind the
/// result of a function returning an un-imported type with `let`, so a return value could still
/// smuggle one out. ``testTheFilesThatImportAVFoundationAreExactlyTheExpectedSet`` is what closes
/// that, by bounding where the framework may be named at all.
///
/// ## What "not vacuous" means here
///
/// A conversion test that asserts only "the output is non-empty" passes for a converter that emits
/// garbage, and one that asserts only the sample count passes for a converter that emits silence.
/// So every case below pins the output by at least two independent measures — the count *and* the
/// signal — and the per-test doc comments name the wrong implementation each one kills.
final class AudioFormatConverterTests: XCTestCase {

    // MARK: - Signal helpers

    /// `frames` samples of a sine at `frequency`, sampled at `sampleRate`.
    private static func sine(
        frequency: Double, sampleRate: Double, frames: Int, amplitude: Float = 0.5
    ) -> [Float] {
        (0..<frames).map {
            amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate))
        }
    }

    /// Interleave `channels` equal-length signals into one run of frames.
    private static func interleave(_ channels: [[Float]]) -> [Float] {
        guard let frames = channels.first?.count else { return [] }
        var out: [Float] = []
        out.reserveCapacity(frames * channels.count)
        for frame in 0..<frames {
            for channel in channels { out.append(channel[frame]) }
        }
        return out
    }

    /// Sign changes in `samples`. A 1 kHz tone observed for one second has ~2000 of them, whatever
    /// the sample rate — which is what makes this a measurement of the *signal* rather than of the
    /// array's length.
    private static func zeroCrossings(_ samples: [Float]) -> Int {
        guard samples.count > 1 else { return 0 }
        var count = 0
        for index in 1..<samples.count where (samples[index - 1] < 0) != (samples[index] < 0) {
            count += 1
        }
        return count
    }

    /// The frequency implied by the zero-crossing count.
    private static func estimatedFrequency(_ samples: [Float], sampleRate: Double) -> Double {
        let seconds = Double(samples.count) / sampleRate
        guard seconds > 0 else { return 0 }
        return Double(zeroCrossings(samples)) / 2 / seconds
    }

    /// The magnitude of one DFT bin, computed directly.
    ///
    /// A single Goertzel-style bin rather than a whole FFT, because only two bins are ever wanted
    /// and a hand-rolled FFT in a test is a second thing that can be wrong. It is the check that
    /// zero-crossings cannot make on its own: a square wave, or a tone with its harmonics
    /// intermodulated by a broken resampler, crosses zero exactly as often as the sine it should
    /// have been, and this does not confuse the two.
    private static func binMagnitude(
        _ samples: [Float], atFrequency frequency: Double, sampleRate: Double
    ) -> Double {
        guard !samples.isEmpty else { return 0 }
        let omega = 2 * Double.pi * frequency / sampleRate
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in samples.enumerated() {
            real += Double(sample) * cos(omega * Double(index))
            imaginary += Double(sample) * sin(omega * Double(index))
        }
        return (real * real + imaginary * imaginary).squareRoot() / Double(samples.count)
    }

    private static func rootMeanSquare(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
            .squareRoot()
    }

    /// One whole capture: convert the input, then flush.
    private static func captureWhole(
        _ samples: [Float], from format: CapturedAudioFormat
    ) throws -> (audio: [Float], converter: AudioFormatConverter) {
        let converter = try AudioFormatConverter(inputFormat: format)
        var audio = try converter.convert(samples)
        audio += try converter.finish()
        return (audio, converter)
    }

    // MARK: - A2: the resampling cases

    /// **48 kHz → 16 kHz.** The commonest built-in and USB rate, and an exact 3:1 ratio.
    ///
    /// Kills: a converter that returns its input untouched (48000 samples, and a zero-crossing
    /// estimate of 1000 Hz read against a 16 kHz clock would come out at 333 Hz); one that emits
    /// silence or a buffer of zeros (the DFT bin and the RMS both collapse); one that never flushes
    /// the resampler's tail (15994, six short — the exact defect the streaming design creates and
    /// ``AudioFormatConverter/finish(_:)`` exists to close); and one that resamples to the wrong
    /// rate (the count moves and the recovered frequency moves with it).
    func testASynthetic48kHzSineConvertsTo16kHzWithItsFrequencyIntact() throws {
        let input = Self.sine(frequency: 1000, sampleRate: 48_000, frames: 48_000)
        let (output, converter) = try Self.captureWhole(
            input, from: CapturedAudioFormat(sampleRate: 48_000, channelCount: 1))

        XCTAssertEqual(
            output.count, 16_000,
            "one second of 48 kHz audio must be exactly one second of 16 kHz audio")
        XCTAssertFalse(converter.isPassThrough, "48 kHz is not the interchange rate")
        XCTAssertEqual(
            converter.resampledFrameCount, 48_000,
            "every input frame must have reached the sample-rate converter")

        XCTAssertEqual(
            Self.estimatedFrequency(output, sampleRate: 16_000), 1000, accuracy: 5,
            """
            The recovered tone is not 1 kHz. Read against the 16 kHz clock this is what a converter \
            that skipped the resample entirely reports as ~333 Hz, and what one that resampled by \
            the reciprocal ratio reports as ~9 kHz.
            """)

        let signal = Self.binMagnitude(output, atFrequency: 1000, sampleRate: 16_000)
        let decoy = Self.binMagnitude(output, atFrequency: 3000, sampleRate: 16_000)
        XCTAssertEqual(
            signal, 0.25, accuracy: 0.01,
            "a 0.5-amplitude sine has a 0.25 bin magnitude; a silent or attenuated output has none")
        XCTAssertGreaterThan(
            signal, decoy * 100,
            """
            The 1 kHz bin does not dominate a bin where nothing was sent. Zero-crossing counting \
            alone cannot see that: a square wave and a resampler ringing at its own filter rate \
            both cross zero exactly as often as the sine they should have been.
            """)
        XCTAssertEqual(
            Self.rootMeanSquare(output), Self.rootMeanSquare(input), accuracy: 0.005,
            "the resample must preserve level, not merely bandwidth")
    }

    /// **44.1 kHz → 16 kHz.** The non-integer ratio, and the one most likely to be off by a sample.
    ///
    /// Kills everything the 48 kHz case does, plus the family that only shows up on a ratio that is
    /// not a whole number: computing the output length with integer division (`count * 16000 /
    /// 44100` truncating at each chunk), rounding the wrong way, or dropping the fractional
    /// remainder each call so that a long session drifts short by a growing number of samples.
    ///
    /// The second half is the demanding one: four input lengths whose ideal output is **not** a
    /// whole number of samples. The measured behaviour is that the converter lands within one
    /// sample of the exact ratio in every case, so that is what is asserted — not a tolerance loose
    /// enough to hide the drift this test exists to find.
    func testA44100HzSineConvertsTo16kHzWithoutDriftingBySamples() throws {
        let input = Self.sine(frequency: 1000, sampleRate: 44_100, frames: 44_100)
        let (output, converter) = try Self.captureWhole(
            input, from: CapturedAudioFormat(sampleRate: 44_100, channelCount: 1))

        XCTAssertEqual(
            output.count, 16_000,
            "one second at 44.1 kHz must be exactly 16000 samples, not 15999 and not 16001")
        XCTAssertEqual(converter.resampledFrameCount, 44_100)
        XCTAssertEqual(
            Self.estimatedFrequency(output, sampleRate: 16_000), 1000, accuracy: 5,
            "the tone did not survive the non-integer ratio")
        XCTAssertEqual(
            Self.binMagnitude(output, atFrequency: 1000, sampleRate: 16_000), 0.25, accuracy: 0.01)
        XCTAssertEqual(
            Self.rootMeanSquare(output), Self.rootMeanSquare(input), accuracy: 0.005)

        // Lengths whose exact output is fractional. This is where an off-by-one hides.
        for frames in [1000, 4410, 22_050, 44_107] {
            let signal = Self.sine(frequency: 1000, sampleRate: 44_100, frames: frames)
            let (converted, _) = try Self.captureWhole(
                signal, from: CapturedAudioFormat(sampleRate: 44_100, channelCount: 1))
            let ideal = Double(frames) * 16_000 / 44_100
            XCTAssertEqual(
                Double(converted.count), ideal, accuracy: 1,
                """
                \(frames) frames at 44.1 kHz should yield \(ideal) samples at 16 kHz and yielded \
                \(converted.count). More than a sample out on one call is a per-call rounding \
                error, and a per-call rounding error over a 120 s session is audio that is \
                measurably short with nothing reporting it.
                """)
        }
    }

    // MARK: - The pass-through, which is a Bluetooth headset and not an edge case

    /// **Input already 16 kHz mono must not be re-converted.**
    ///
    /// This is what a Bluetooth HFP device gives — an ordinary state, reached by wearing AirPods
    /// and taking a call — so "always resample" is wrong, not merely wasteful.
    ///
    /// **Bit-equality alone would be a vacuous assertion here, and that is measured rather than
    /// assumed.** Driving 16 kHz mono through `AVAudioConverter` on this platform is bit-exact: an
    /// impulse comes out as the same single sample at the same index. So an implementation that
    /// pointlessly round-trips every HFP session through a resampler would pass an equality check
    /// today, and would silently start losing quality the day Apple changes the identity path. The
    /// assertions that actually distinguish the two are the structural ones —
    /// ``AudioFormatConverter/isPassThrough`` and ``AudioFormatConverter/resampledFrameCount`` — and
    /// the positive control below proves the counter is capable of moving at all, so that reading
    /// zero here means something.
    func testAlreadySixteenKilohertzMonoAudioIsNotResampled() throws {
        let input = Self.sine(frequency: 1000, sampleRate: 16_000, frames: 16_000)
        let converter = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 16_000, channelCount: 1))

        XCTAssertTrue(
            converter.isPassThrough,
            "16 kHz mono is the interchange format; there is nothing for a converter to do")

        let converted = try converter.convert(input)
        XCTAssertEqual(
            converted, input,
            "the pass-through must return the samples it was given, unaltered and in full")
        XCTAssertEqual(
            converter.resampledFrameCount, 0,
            """
            Frames reached the sample-rate converter on a path that has nothing to resample. A \
            16 kHz round trip through AVAudioConverter is bit-exact on this platform, so the output \
            would have looked correct — this counter is the only thing that can tell the two \
            implementations apart.
            """)

        let tail = try converter.finish()
        XCTAssertEqual(tail, [], "there is no resampler tail to flush on the pass-through path")
        XCTAssertEqual(converter.resampledFrameCount, 0, "finish() must not resample either")
        XCTAssertEqual(converter.discardedPartialFrameSampleCount, 0, "mono has no partial frames")

        // The positive control: the same counter, on a path that should move it. Without this,
        // `resampledFrameCount == 0` above is satisfied by a counter that is never incremented
        // anywhere, and the assertion that carries this whole test would prove nothing.
        let resampling = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 48_000, channelCount: 1))
        _ = try resampling.convert(Self.sine(frequency: 1000, sampleRate: 48_000, frames: 4800))
        XCTAssertEqual(
            resampling.resampledFrameCount, 4800,
            "the counter does not move on a resampling path, so reading zero elsewhere means nothing")
    }

    /// 16 kHz multi-channel: the channels must be mixed, and **still** nothing resampled.
    ///
    /// Kills an implementation that treats "pass-through" as a property of the sample rate alone
    /// and hands two interleaved channels straight through — which would double the length, halve
    /// the apparent pitch, and reach the ASR as noise.
    func testSixteenKilohertzMultiChannelInputIsMixedButNotResampled() throws {
        let left = Self.sine(frequency: 1000, sampleRate: 16_000, frames: 16_000)
        let right = Self.sine(frequency: 1000, sampleRate: 16_000, frames: 16_000)
        let converter = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 16_000, channelCount: 2))

        XCTAssertFalse(
            converter.isPassThrough,
            "two channels are not the interchange format, whatever the rate says")

        var output = try converter.convert(Self.interleave([left, right]))
        output += try converter.finish()

        XCTAssertEqual(output.count, 16_000, "two interleaved channels must become one")
        XCTAssertEqual(
            converter.resampledFrameCount, 0,
            "the downmix is not a resample and must not be counted or performed as one")
        XCTAssertEqual(
            Self.estimatedFrequency(output, sampleRate: 16_000), 1000, accuracy: 5,
            "handing interleaved stereo through unmixed halves the apparent pitch")
    }

    // MARK: - Downmix

    /// **Multi-channel input becomes the arithmetic mean of its channels.**
    ///
    /// Stated so it can be asserted exactly: every value below is exact in binary floating point,
    /// so these are equalities and not tolerances.
    ///
    /// Kills, by name:
    /// - **Take channel 0** — the rule a naive `mBuffers.mData` read performs by accident. It gives
    ///   `[1, 5]` for the stereo case and `[1, 10]` for the four-channel one, and, in the third
    ///   case, **complete silence for a microphone wired to channel 2**. That case is asserted on
    ///   its own because it is the one that ships a product which records nothing at all for some
    ///   users and works perfectly for whoever tested it.
    /// - **Sum without dividing** — `[4, 12]` instead of `[2, 6]`: twice the level, clipping into
    ///   the ASR on anything loud.
    /// - **Take the last channel** — `[3, 7]`, the mirror of the first-channel bug.
    /// - **Divide by the wrong count** — any fixed divisor fails the four-channel case.
    func testMultiChannelInputIsDownmixedToTheArithmeticMeanOfItsChannels() throws {
        let stereo = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 16_000, channelCount: 2))
        let stereoOutput = try stereo.convert([1, 3, 5, 7])
        XCTAssertEqual(
            stereoOutput, [2, 6],
            """
            Stereo frames (1,3) and (5,7) must average to 2 and 6. `[1, 5]` is first-channel \
            selection, `[3, 7]` is last-channel selection, `[4, 12]` is a sum that forgot to divide.
            """)

        let quad = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 16_000, channelCount: 4))
        XCTAssertEqual(
            try quad.convert([1, 2, 3, 4, 10, 20, 30, 40]), [2.5, 25],
            "a four-channel interface must divide by four, not by a hardcoded two")

        // The failure the mean exists to prevent, asserted directly: a silent channel 0 and a real
        // signal on channel 1. First-channel selection returns zeros here — a product that records
        // nothing, for exactly the users whose interface is wired that way, with no error anywhere.
        let offsetMicrophone = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 16_000, channelCount: 2))
        let recovered = try offsetMicrophone.convert([0, 1, 0, -1, 0, 1])
        XCTAssertEqual(
            recovered, [0.5, -0.5, 0.5],
            """
            A microphone on channel 2 was lost. First-channel selection returns [0, 0, 0] here and \
            reports success, which is silence shipped as a working capture.
            """)
        XCTAssertNotEqual(
            recovered, [0, 0, 0], "the downmix discarded every channel but the first")

        // An odd channel count, where the scale factor is not exact in binary.
        let threeChannel = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 16_000, channelCount: 3))
        let mixed = try threeChannel.convert([1, 2, 3, 30, 60, 90])
        XCTAssertEqual(mixed.count, 2)
        XCTAssertEqual(Double(mixed[0]), 2, accuracy: 1e-5)
        XCTAssertEqual(Double(mixed[1]), 60, accuracy: 1e-4)
    }

    /// A drain of the ring can end mid-frame. The remainder is carried, not dropped.
    ///
    /// Kills: an implementation that truncates each call to whole frames and throws the remainder
    /// away — which, for a stereo device drained on a 10 ms poll, silently deletes a sample every
    /// time the boundary lands odd and leaves the two channels **permanently swapped** from that
    /// point on, turning every later frame's mean into a mix of two different instants.
    func testAPartialFrameIsCarriedToTheNextCallRatherThanDropped() throws {
        let converter = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 16_000, channelCount: 2))

        XCTAssertEqual(
            try converter.convert([1, 3, 5]), [2],
            "only the complete frame may be emitted; the lone 5 belongs to a frame not yet whole")
        XCTAssertEqual(
            try converter.convert([7]), [6],
            """
            The carried sample was lost. Had it been dropped, this call would return [] and every \
            later frame would pair channel 1 with channel 0 of the next instant, for the rest of \
            the session.
            """)
        XCTAssertEqual(converter.discardedPartialFrameSampleCount, 0, "nothing was dropped")

        // A stream that ends mid-frame has nowhere to carry to. The remainder dies, and is counted
        // — because `AudioRingBuffer`'s overrun policy is defensible only on the grounds that its
        // loss is countable, and a second, silent loss on the same path would undo that by
        // arithmetic.
        XCTAssertEqual(try converter.convert([9]), [], "one sample is not a stereo frame")
        XCTAssertEqual(try converter.finish(), [])
        XCTAssertEqual(
            converter.discardedPartialFrameSampleCount, 1,
            "the sample stranded at end of stream must be counted, not silently discarded")

        // **The stranded sample must not survive into the next session.** If it did, the first
        // frame of the next dictation would be averaged against a sample from the previous one —
        // and every frame after it would be one sample out of alignment, pairing channel 1 with
        // channel 0 of the following instant for the rest of the session. A converter that carries
        // 9 across would return [(9 + 1) / 2] = [5] here.
        XCTAssertEqual(
            try converter.convert([1, 3]), [2],
            "audio from the previous session leaked into this one through the partial-frame carry")

        // And the count accumulates across sessions rather than being overwritten by the latest
        // one. A counter that reports "1" forever, however many sessions strand a sample, is not a
        // record of how much audio was lost.
        XCTAssertEqual(try converter.convert([5]), [], "one sample is not a stereo frame")
        XCTAssertEqual(try converter.finish(), [])
        XCTAssertEqual(
            converter.discardedPartialFrameSampleCount, 2,
            "the discarded-sample count did not accumulate over two sessions that each stranded one")
    }

    /// The A8 read-back rule, tested where the path that consults it cannot be driven.
    ///
    /// ``AudioFormatConverter/init(inputFormat:)`` reads its output format back out of AVFoundation
    /// and refuses to proceed unless it is 16 kHz mono Float32. Nothing can make AVFoundation return
    /// anything else for that request, so the guard is unreachable from a test — and measured, as an
    /// inline condition it was satisfiable by any predicate at all: deleting it failed nothing in
    /// this file. Extracting the rule is what gives it a test.
    ///
    /// Both terms are checked failing on their own, because either one alone accepts a format the
    /// other rejects: the rate and channel count come from ``CapturedAudioFormat``, and the sample
    /// type does not — the struct has no field for it.
    func testTheInterchangeOutputRuleRequiresBothTheFormatAndFloat32() {
        XCTAssertTrue(
            AudioFormatConverter.isUsableInterchangeOutput(
                format: .interchange, isFloat32: true),
            "the rule rejects the only format it should accept")

        XCTAssertFalse(
            AudioFormatConverter.isUsableInterchangeOutput(
                format: .interchange, isFloat32: false),
            """
            16 kHz mono of some other sample type was accepted. `[Float]` is the only thing this \
            seam can hold, so a non-Float32 format would be reinterpreted rather than converted.
            """)

        for wrongFormat in [
            CapturedAudioFormat(sampleRate: 48_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: 44_100, channelCount: 1),
            CapturedAudioFormat(sampleRate: 16_000, channelCount: 2),
        ] {
            XCTAssertFalse(
                AudioFormatConverter.isUsableInterchangeOutput(
                    format: wrongFormat, isFloat32: true),
                "\(wrongFormat) was accepted as an interchange output because it was Float32")
        }
    }

    // MARK: - Streaming, and the reset that is not optional

    /// The ring is drained in chunks. Chunked input must produce **exactly** the audio a single
    /// call would.
    ///
    /// Kills the most plausible wrong implementation of the streaming path: signalling
    /// `.endOfStream` on every `convert` call. That flushes the resampler's filter once per poll,
    /// so its state restarts at every chunk boundary. It is nearly invisible to a length check —
    /// 100 chunks of 480 frames at 48 kHz flush to 160 samples each, for exactly the same 16000
    /// total — and it splices a discontinuity into the middle of the user's sentence a hundred
    /// times a second. Only sample-for-sample equality sees it.
    ///
    /// It also kills the same mistake *without* a reset, which is worse and easier: measured, a
    /// converter flushed to end-of-stream and then handed more audio returns **nothing at all**.
    func testChunkedConversionProducesExactlyTheSameAudioAsASingleCall() throws {
        let format = CapturedAudioFormat(sampleRate: 48_000, channelCount: 1)
        let signal = Self.sine(frequency: 1000, sampleRate: 48_000, frames: 48_000)

        let (oneShot, _) = try Self.captureWhole(signal, from: format)

        let streaming = try AudioFormatConverter(inputFormat: format)
        var chunked: [Float] = []
        for chunk in 0..<100 {
            chunked += try streaming.convert(Array(signal[(chunk * 480)..<((chunk + 1) * 480)]))
        }
        chunked += try streaming.finish()

        XCTAssertEqual(oneShot.count, 16_000, "the one-shot control did not itself convert correctly")
        XCTAssertEqual(
            chunked, oneShot,
            """
            Draining the ring in chunks produced different audio from converting it whole. The \
            resampler's filter state must survive across calls: flushing it per chunk gives the \
            same total length and a discontinuity at every boundary, which no length assertion can \
            see.
            """)
    }

    /// **A second session must convert as well as the first.**
    ///
    /// Measured, and the reason ``AudioFormatConverter/finish(_:)`` calls `reset()`: an
    /// `AVAudioConverter` that has been flushed to end-of-stream and is then handed a fresh
    /// session's audio produces **zero frames**. No error is raised and the object looks healthy.
    ///
    /// Kills exactly that: an implementation that flushes and does not reset ships a product where
    /// the first dictation of the day works and every one after it is silent — the failure mode
    /// hardest to notice in a manual smoke test, because the first press always works.
    ///
    /// Three sessions rather than two, because a converter that resets in the wrong place could
    /// alternate.
    func testASecondSessionProducesTheSameAudioAsTheFirst() throws {
        let converter = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 48_000, channelCount: 1))
        let signal = Self.sine(frequency: 1000, sampleRate: 48_000, frames: 4800)

        var sessions: [[Float]] = []
        for _ in 0..<3 {
            var audio = try converter.convert(signal)
            audio += try converter.finish()
            sessions.append(audio)
        }

        XCTAssertEqual(sessions[0].count, 1600, "the first session did not convert correctly")
        XCTAssertEqual(
            sessions[1], sessions[0],
            """
            The second session did not reproduce the first. A flushed AVAudioConverter yields zero \
            frames until it is reset — so this is the shape of a product whose first dictation \
            works and whose every later one is silent.
            """)
        XCTAssertEqual(sessions[2], sessions[0], "the third session diverged from the first")
    }

    /// **A session at the product's 120 s ceiling, which is what makes the drain loop a loop.**
    ///
    /// Added because a mutation survived the rest of this file: making
    /// ``AudioFormatConverter``'s drain return after a *single* pull, ignoring the status that says
    /// more output is waiting, failed nothing. Every other case here produces at most 16000 samples,
    /// which needs two pulls, and the second pull's leftover was picked up by the flush — so the
    /// totals came out right and the truncation was invisible.
    ///
    /// It stops being invisible the moment the output exceeds what two pulls can carry. At the
    /// ceiling the loop runs a couple of hundred times, and a converter that stops after one returns
    /// a fraction of a two-minute dictation while reporting success — audio silently truncated to
    /// its first seconds, which is precisely the loss the transcript invariant forbids.
    ///
    /// It also puts a number under ``AudioFormatConverter``'s iteration ceiling: that bound is
    /// justified against this session length, and this is the test that runs one.
    func testASessionAtTheCeilingIsDrainedWholeRatherThanOnePullDeep() throws {
        let seconds = 120
        let input = Self.sine(
            frequency: 1000, sampleRate: 48_000, frames: 48_000 * seconds)

        let converter = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 48_000, channelCount: 1))
        let converted = try converter.convert(input)
        let flushed = try converter.finish()

        XCTAssertGreaterThan(
            converted.count, 1_000_000,
            """
            A single convert() call returned \(converted.count) samples for a \(seconds) s capture. \
            The drain pulls a bounded number of frames per iteration, so a figure this small means \
            it stopped after one or two pulls and left the rest inside AVAudioConverter.
            """)
        XCTAssertEqual(
            converted.count + flushed.count, 16_000 * seconds,
            """
            \(seconds) seconds in, \(converted.count + flushed.count) samples out, against the \
            \(16_000 * seconds) that \(seconds) seconds at 16 kHz is. A drain that stops early does \
            not glitch — it truncates the dictation and reports success.
            """)
        XCTAssertEqual(
            Self.estimatedFrequency(converted + flushed, sampleRate: 16_000), 1000, accuracy: 5,
            "the tone did not survive a session at the ceiling")
    }

    // MARK: - One session's audio must never reach another's

    /// **A session abandoned without `finish()` must not leak into the next one.**
    ///
    /// This is the common case, not the exotic one. `session-lifecycle` has six stop rules and only
    /// one of them is a normal key-up: the 120 s ceiling fires, the tap dies, a configuration change
    /// ends the session, the user cancels. Most endings never reach ``AudioFormatConverter/finish(_:)``,
    /// so a converter whose only cleanup lives there carries the previous capture forward — the
    /// resampler's filter state *and* a partial frame.
    ///
    /// Kills: a ``AudioFormatConverter/beginSession()`` that does not reset the resampler, one that
    /// does not drop the partial frame, and one that resets neither.
    ///
    /// **Asserted by content, not by length.** The second session is compared sample-for-sample
    /// against what a brand-new converter produces from the same input. Equal lengths with wrong
    /// contents is precisely the failure — a leaked filter state changes the leading samples without
    /// changing how many there are.
    func testASessionAbandonedWithoutFinishDoesNotLeakIntoTheNext() throws {
        // Stereo, so the abandoned session strands a partial frame as well as filter state.
        let format = CapturedAudioFormat(sampleRate: 48_000, channelCount: 2)
        let converter = try AudioFormatConverter(inputFormat: format)

        // Session one: a second of loud DC, ended by something that is not a key-up. The odd
        // trailing sample is a drain of the ring that stopped mid-frame.
        let abandoned = [Float](repeating: 1.0, count: 96_000) + [0.75]
        _ = try converter.convert(abandoned)
        XCTAssertTrue(
            converter.isHoldingAudio,
            "a converter holding an unfinished session's state must say so")

        // The next session begins. This is the only point in a session's life that cannot be
        // skipped, which is why the reset is anchored here.
        converter.beginSession()
        XCTAssertFalse(converter.isHoldingAudio, "beginSession() must clear the abandoned state")

        let voice = Self.interleave([
            Self.sine(frequency: 1000, sampleRate: 48_000, frames: 48_000),
            Self.sine(frequency: 1000, sampleRate: 48_000, frames: 48_000),
        ])
        var second = try converter.convert(voice)
        second += try converter.finish()

        let (reference, _) = try Self.captureWhole(voice, from: format)
        XCTAssertEqual(reference.count, 16_000, "the reference conversion is itself wrong")
        XCTAssertEqual(
            second, reference,
            """
            The second session did not match what a fresh converter produces from the same audio, \
            so it contains something from the session before it. That is the user reading words \
            they spoke into a different application, minutes earlier — and nothing downstream can \
            tell contaminated audio from long audio.
            """)
    }

    /// **A `finish(_:)` that throws must not carry its session into the next one.**
    ///
    /// The cleanup used to run only after the flush succeeded, so a throw left the resampler's
    /// filter state and the partial frame in place. It is now in a `defer`, and this is the test
    /// that a throwing path cannot skip it.
    ///
    /// The throw is a real one, driven end to end rather than injected: the drain's iteration
    /// ceiling. 4 kHz input is not a device — it is the cheapest way to make one `convert` call
    /// exceed 1024 pulls of 8192 frames, at 8.8 MB and milliseconds instead of the 100 MB it would
    /// take at 48 kHz. The capture it represents is ~550 s, four and a half times the product's own
    /// 120 s ceiling, which is the margin the two drain constants are chosen for.
    ///
    /// Kills: cleanup written after the `try` instead of in a `defer` — which is what shipped, and
    /// which passes every other test in this file.
    func testAThrowingFinishDoesNotCarryItsSessionIntoTheNext() throws {
        let format = CapturedAudioFormat(sampleRate: 4_000, channelCount: 1)
        let converter = try AudioFormatConverter(inputFormat: format)

        let pastTheCeiling = [Float](repeating: 0.9, count: 2_200_000)
        XCTAssertThrowsError(try converter.finish(pastTheCeiling)) { error in
            guard
                case .conversionDidNotTerminate = error as? AudioFormatConversionError
            else {
                return XCTFail("expected the drain ceiling to be reported, got \(error)")
            }
        }

        // No `beginSession()` here, deliberately: the point is that `finish(_:)` itself left the
        // converter clean, on the path where it failed.
        XCTAssertFalse(
            converter.isHoldingAudio,
            "finish() threw and left the converter mid-stream, so its cleanup was skipped")

        let voice = Self.sine(frequency: 500, sampleRate: 4_000, frames: 4_000)
        var second = try converter.convert(voice)
        second += try converter.finish()

        let (reference, _) = try Self.captureWhole(voice, from: format)
        XCTAssertEqual(reference.count, 16_000, "the reference conversion is itself wrong")
        XCTAssertEqual(
            second, reference,
            """
            After a finish() that threw, the next session did not match a fresh converter's output \
            on the same audio — so the failed session's samples were emitted into it. A throw that \
            leaves state behind is how one dictation ends up inside another.
            """)
    }

    /// **A `convert(_:)` that throws mid-session must not carry its session into the next one.**
    ///
    /// `finish(_:)` got this treatment first and `convert(_:)` did not — while a test in this file
    /// asserted the standard for one and not the other. `convert(_:)` is the **higher-frequency**
    /// throw site by a wide margin: once per poll of the ring against once per session.
    ///
    /// The throw is mid-session on purpose. Real audio is converted first, so the converter holds
    /// genuine filter state and a genuine partial frame when the failing call arrives — which is
    /// what makes contamination possible at all. A test that threw on the very first call would
    /// have nothing to carry forward and would pass against the unprotected code.
    ///
    /// Kills: cleanup applied to `finish(_:)` alone. Asserted by content against a fresh
    /// converter's output, because equal lengths with wrong contents is the failure.
    func testAThrowingConvertDoesNotCarryItsSessionIntoTheNext() throws {
        // Stereo, so the failing session holds a partial frame as well as filter state.
        let format = CapturedAudioFormat(sampleRate: 4_000, channelCount: 2)
        let converter = try AudioFormatConverter(inputFormat: format)

        // Real audio first, ending mid-frame: this is what the throw must not carry forward.
        let opening = Self.interleave([
            Self.sine(frequency: 500, sampleRate: 4_000, frames: 4_000),
            Self.sine(frequency: 500, sampleRate: 4_000, frames: 4_000),
        ]) + [0.75]
        _ = try converter.convert(opening)
        XCTAssertTrue(
            converter.isHoldingAudio,
            "the session must be holding something, or this test cannot prove anything")

        // Now a call that fails: past the drain's iteration ceiling.
        XCTAssertThrowsError(try converter.convert([Float](repeating: 0.9, count: 4_400_000))) {
            error in
            guard case .conversionDidNotTerminate = error as? AudioFormatConversionError else {
                return XCTFail("expected the drain ceiling to be reported, got \(error)")
            }
        }

        // No `beginSession()`, deliberately — the point is that `convert(_:)` cleaned up after
        // itself on the path where it failed.
        XCTAssertFalse(
            converter.isHoldingAudio,
            "convert() threw and left audio held, so its cleanup was skipped")

        let voice = Self.interleave([
            Self.sine(frequency: 800, sampleRate: 4_000, frames: 4_000),
            Self.sine(frequency: 800, sampleRate: 4_000, frames: 4_000),
        ])
        var second = try converter.convert(voice)
        second += try converter.finish()

        let (reference, _) = try Self.captureWhole(voice, from: format)
        XCTAssertEqual(reference.count, 16_000, "the reference conversion is itself wrong")
        XCTAssertEqual(
            second, reference,
            """
            After a convert() that threw, the next session did not match a fresh converter's output \
            on the same audio — so the failed session's samples were emitted into it. This is the \
            throw site that fires once per poll, not once per session.
            """)
    }

    // MARK: - The accounting the reset rests on

    /// **Every sample handed in is either converted or counted. Nothing is silently dropped.**
    ///
    /// This is the premise the whole reset rests on and it was, until now, held by no test.
    /// ``AudioFormatConverter/beginSession()`` and the two error paths discard whatever partial
    /// frame is held — and that is only acceptable because what is held is always **less than one
    /// frame**. If a whole frame could ever be retained, the reset would trade cross-session
    /// contamination for silent truncation of the session in hand, which is the same defect pointed
    /// at a different session.
    ///
    /// So the law is asserted exactly, not bounded loosely:
    /// `outputSamples × channelCount + discarded == samplesFed`. It is the analogue of
    /// `AudioRingBuffer`'s `received + refused == sent`, and it is checked at 16 kHz so that no
    /// resampler filter delay stands between the input and the arithmetic — the partial-frame
    /// handling is the whole subject.
    ///
    /// Randomised chunk sizes over a seeded generator, because the defect only appears when a drain
    /// boundary lands mid-frame, and a fixed chunk size either always lands there or never does.
    ///
    /// Kills: a partial frame that is dropped without being counted; one that is counted twice; one
    /// retained across a reset; and any implementation that can hold a whole frame back.
    func testEverySampleIsEitherConvertedOrCounted() throws {
        var generator = SeededGenerator(seed: 0x5EED_A1D0)

        for channelCount in 1...8 {
            let format = CapturedAudioFormat(sampleRate: 16_000, channelCount: channelCount)
            let converter = try AudioFormatConverter(inputFormat: format)
            var discardedBefore = 0

            // Several sessions on the one converter, so the reset is inside the measurement.
            for _ in 0..<5 {
                converter.beginSession()
                discardedBefore = converter.discardedPartialFrameSampleCount

                var fed = 0
                var produced = 0
                for _ in 0..<12 {
                    let chunk = Int.random(in: 0...97, using: &generator)
                    fed += chunk
                    produced += try converter.convert(
                        (0..<chunk).map { Float($0) * 0.01 }
                    ).count

                    XCTAssertLessThan(
                        converter.discardedPartialFrameSampleCount - discardedBefore, channelCount,
                        """
                        More than a frame's worth was discarded mid-session at \(channelCount) \
                        channels. The reset may only ever throw away a remainder too short to be a \
                        frame — anything more is real audio deleted without a transcript being \
                        marked short.
                        """)
                }

                produced += try converter.finish().count
                let discarded = converter.discardedPartialFrameSampleCount - discardedBefore

                XCTAssertEqual(
                    produced * channelCount + discarded, fed,
                    """
                    \(channelCount) channels: \(fed) samples in, \(produced) frames out, \
                    \(discarded) counted as discarded. Every sample must be one or the other — a \
                    sample that is neither is audio deleted with nothing recording that it was.
                    """)
                XCTAssertEqual(
                    discarded, fed % channelCount,
                    "the discarded count is not the remainder, so the boundary is being mishandled")
                XCTAssertLessThan(discarded, channelCount, "a whole frame was discarded")
            }
        }
    }

    /// **`isHoldingAudio` reports what is actually held, term by term.**
    ///
    /// Two things can be held — a partial frame and the resampler's filter state — and each has a
    /// regime where it is the *only* one that can be. Asserting the flag only where both are true
    /// (which is what the contamination tests do, since they use a multi-channel resampling
    /// converter) leaves an implementation reading either term alone indistinguishable from the
    /// correct one. Measured: dropping either term from the disjunction failed nothing.
    ///
    /// The third regime is the one that prompted the rename. A 16 kHz mono pass-through holds
    /// nothing at any point in its life, so the flag must stay `false` through a whole session — the
    /// stored flag this replaced answered "has audio been through here" and said `true`, which is a
    /// hazard flag raised where there is no hazard.
    func testIsHoldingAudioReflectsWhatIsActuallyHeld() throws {
        // A partial frame and nothing else: 16 kHz multi-channel builds no resampler at all.
        let partialOnly = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 16_000, channelCount: 2))
        XCTAssertFalse(partialOnly.isHoldingAudio, "nothing has been converted yet")
        _ = try partialOnly.convert([1, 2, 3, 4])
        XCTAssertFalse(
            partialOnly.isHoldingAudio,
            "two whole frames leave no remainder, so nothing is held")
        _ = try partialOnly.convert([5])
        XCTAssertTrue(
            partialOnly.isHoldingAudio,
            """
            A stranded half-frame is held and would reach the next session, but the flag says \
            nothing is. This regime has no resampler, so the partial frame is the only term that \
            can be true here.
            """)
        partialOnly.beginSession()
        XCTAssertFalse(partialOnly.isHoldingAudio, "beginSession() did not clear the partial frame")

        // Resampler state and nothing else: mono input never strands a partial frame.
        let resamplerOnly = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 48_000, channelCount: 1))
        XCTAssertFalse(resamplerOnly.isHoldingAudio, "nothing has been converted yet")
        _ = try resamplerOnly.convert(Self.sine(frequency: 1000, sampleRate: 48_000, frames: 4800))
        XCTAssertTrue(
            resamplerOnly.isHoldingAudio,
            """
            The resampler holds filter state and a tail that a flush would emit, but the flag says \
            nothing is held. Mono input strands no partial frame, so the resampler is the only term \
            that can be true here.
            """)
        _ = try resamplerOnly.finish()
        XCTAssertFalse(resamplerOnly.isHoldingAudio, "finish() did not clear the resampler state")

        // Neither, ever: the pass-through retains nothing at any point.
        let passThrough = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 16_000, channelCount: 1))
        for _ in 0..<3 {
            _ = try passThrough.convert(Self.sine(frequency: 500, sampleRate: 16_000, frames: 1600))
            XCTAssertFalse(
                passThrough.isHoldingAudio,
                """
                A 16 kHz mono pass-through copies its argument and keeps nothing, so it can \
                contaminate nothing — reporting otherwise is a hazard flag raised where there is no \
                hazard, which is one an owner learns to ignore.
                """)
        }
        XCTAssertTrue(passThrough.isPassThrough, "the pass-through control is not passing through")
    }

    /// A press that captures nothing is a real session, and must behave like one.
    ///
    /// `CapturedAudio`'s own doc makes the case: "a 20 ms tap that captures almost nothing is a real
    /// session that ended for a real reason, and its outcome is `.completed`, not a discard." So the
    /// empty press must not throw, must not produce audio, must not count a loss, and must leave the
    /// converter exactly as clean as it found it.
    ///
    /// Kills: a `finish(_:)` that assumes at least one `convert(_:)` ran; a reset that counts a
    /// discard when nothing was held; and any state left behind that the next real press would
    /// inherit.
    func testAPressThatCapturesNothingIsACleanSession() throws {
        for format in [
            CapturedAudioFormat(sampleRate: 48_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: 16_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: 44_100, channelCount: 2),
        ] {
            let converter = try AudioFormatConverter(inputFormat: format)

            converter.beginSession()
            XCTAssertFalse(converter.isHoldingAudio, "\(format): a fresh session holds nothing")
            XCTAssertEqual(
                try converter.finish(), [],
                "\(format): a press with no audio produced audio")
            XCTAssertEqual(
                converter.discardedPartialFrameSampleCount, 0,
                "\(format): an empty press counted a loss it did not have")
            XCTAssertFalse(converter.isHoldingAudio, "\(format): an empty press left state behind")

            // And the next, real press is unaffected by having followed an empty one.
            let frames = Int(format.sampleRate)
            let voice = Self.interleave(
                (0..<format.channelCount).map { _ in
                    Self.sine(frequency: 440, sampleRate: format.sampleRate, frames: frames)
                })
            converter.beginSession()
            var audio = try converter.convert(voice)
            audio += try converter.finish()

            let (reference, _) = try Self.captureWhole(voice, from: format)
            XCTAssertEqual(
                audio, reference,
                "\(format): a real press following an empty one did not convert normally")
        }
    }

    /// The drain ceiling is reachable, reports itself, and is not merely a comment.
    ///
    /// It also pins where the boundary is: the two drain constants multiply out to 524 s of 16 kHz
    /// audio against a 120 s product ceiling, and a test that never crosses it would let either
    /// constant be changed until a legitimate capture threw.
    func testTheDrainCeilingIsReachableAndReportsItself() throws {
        let converter = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 4_000, channelCount: 1))

        XCTAssertThrowsError(try converter.convert([Float](repeating: 0.9, count: 2_200_000))) {
            error in
            guard
                case .conversionDidNotTerminate(let produced) = error as? AudioFormatConversionError
            else {
                return XCTFail("expected conversionDidNotTerminate, got \(error)")
            }
            XCTAssertGreaterThan(
                produced, 8_000_000,
                "the ceiling reported a frame count far below the one it is set at")
        }

        // A capture at the product's real ceiling must be nowhere near it. If this ever throws, the
        // margin has been spent and one of the two constants moved.
        let atTheProductCeiling = try AudioFormatConverter(
            inputFormat: CapturedAudioFormat(sampleRate: 48_000, channelCount: 1))
        XCTAssertNoThrow(
            try atTheProductCeiling.convert([Float](repeating: 0.5, count: 48_000 * 120)),
            "a 120 s capture — the product's own ceiling — hit the drain's iteration limit")
    }

    /// Nothing in, nothing out — and no throw, because a poll of an empty ring is ordinary.
    func testConvertingNothingYieldsNothing() throws {
        for format in [
            CapturedAudioFormat(sampleRate: 48_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: 16_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: 44_100, channelCount: 2),
        ] {
            let converter = try AudioFormatConverter(inputFormat: format)
            XCTAssertEqual(try converter.convert([]), [], "\(format) produced audio from nothing")
            XCTAssertEqual(try converter.finish(), [], "\(format) flushed audio from nothing")
            XCTAssertEqual(converter.resampledFrameCount, 0)
        }
    }

    /// ``AudioFormatConverter/finish(_:)`` may carry the last drain, so the final samples and the
    /// flush cannot be separated by an early return.
    func testFinishConvertsItsArgumentBeforeFlushing() throws {
        let format = CapturedAudioFormat(sampleRate: 48_000, channelCount: 1)
        let signal = Self.sine(frequency: 1000, sampleRate: 48_000, frames: 4800)

        let (separately, _) = try Self.captureWhole(signal, from: format)

        let combined = try AudioFormatConverter(inputFormat: format)
        let together = try combined.finish(signal)

        XCTAssertEqual(together.count, 1600)
        XCTAssertEqual(
            together, separately,
            "finish(samples) must equal convert(samples) followed by finish()")
    }

    // MARK: - A8: the seam boundary is 16 kHz mono, and moving it fails loudly

    /// **A8, measured off the data rather than read off a label.**
    ///
    /// One second of audio in, for every plausible hardware format, must be 16000 samples out. That
    /// figure is derived from nothing this code declares — it is what one second at 16 kHz mono
    /// *is* — so the assertion survives someone editing
    /// ``CapturedAudioFormat/interchange`` and a test that merely restates it.
    ///
    /// Kills: an output rate changed to 48 kHz (48000 samples); a channel count changed to 2 (32000
    /// for every input); a downmix that forgets to divide the sample count by the channel count
    /// (32000 for the stereo rows and 16000 for the mono ones, so the stereo rows are what catch
    /// it); and an upsample path that was never wired, since 8 kHz input must grow rather than
    /// shrink.
    func testTheSeamBoundaryIsSixteenKilohertzMonoForEveryPlausibleHardwareFormat() throws {
        let formats = [
            CapturedAudioFormat(sampleRate: 48_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: 48_000, channelCount: 2),
            CapturedAudioFormat(sampleRate: 44_100, channelCount: 1),
            CapturedAudioFormat(sampleRate: 44_100, channelCount: 2),
            CapturedAudioFormat(sampleRate: 16_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: 16_000, channelCount: 2),
            CapturedAudioFormat(sampleRate: 16_000, channelCount: 4),
            CapturedAudioFormat(sampleRate: 8_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: 22_050, channelCount: 1),
            CapturedAudioFormat(sampleRate: 32_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: 96_000, channelCount: 1),
        ]

        for format in formats {
            let frames = Int(format.sampleRate)  // exactly one second
            let channels = (0..<format.channelCount).map { _ in
                Self.sine(frequency: 440, sampleRate: format.sampleRate, frames: frames)
            }
            let (output, converter) = try Self.captureWhole(
                Self.interleave(channels), from: format)

            XCTAssertEqual(
                converter.outputFormat, .interchange,
                "\(format) declares an output format that is not the interchange format")
            XCTAssertEqual(
                Double(output.count), 16_000, accuracy: 1,
                """
                One second of \(format) produced \(output.count) samples. At the seam boundary one \
                second is 16000 samples, mono — 32000 means the channels were never mixed, 48000 \
                means the output rate is not 16 kHz, and 8000 means it is half of it. This figure \
                is not read from any constant in Sources/, which is why editing one cannot make it \
                agree.
                """)
            XCTAssertEqual(
                Self.estimatedFrequency(output, sampleRate: 16_000), 440, accuracy: 5,
                "\(format) produced 16000 samples that are not the 440 Hz tone that went in")
        }
    }

    /// The constant itself, pinned with the reason.
    func testTheInterchangeFormatIsSixteenKilohertzMono() {
        XCTAssertEqual(
            CapturedAudioFormat.interchange.sampleRate, 16_000,
            """
            The interchange sample rate moved. Both ASR engines Vocca ships behind `ASREngine` — \
            Parakeet and whisper.cpp — take 16 kHz, and resampling here rather than inside each \
            engine is what lets them be swapped without either learning about microphones.
            """)
        XCTAssertEqual(
            CapturedAudioFormat.interchange.channelCount, 1,
            "the interchange format is mono; a stereo buffer reaches ASR as interleaved noise")
        XCTAssertTrue(CapturedAudioFormat.interchange.isInterchange)
    }

    /// The predicate, shown rejecting the near-misses rather than only accepting the right answer.
    ///
    /// Each row below is one field away from correct, and each is a regression somebody could
    /// plausibly ship. A predicate that has only ever been run against a value that satisfies it is
    /// a predicate nobody has watched work.
    func testTheInterchangePredicateRejectsEveryNearMiss() {
        XCTAssertTrue(CapturedAudioFormat(sampleRate: 16_000, channelCount: 1).isInterchange)

        for nearMiss in [
            CapturedAudioFormat(sampleRate: 16_000, channelCount: 2),
            CapturedAudioFormat(sampleRate: 16_000, channelCount: 0),
            CapturedAudioFormat(sampleRate: 44_100, channelCount: 1),
            CapturedAudioFormat(sampleRate: 48_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: 8_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: 16_001, channelCount: 1),
        ] {
            XCTAssertFalse(
                nearMiss.isInterchange, "\(nearMiss) was accepted as the interchange format")
        }
    }

    /// A format that cannot describe audio is refused at construction, loudly.
    ///
    /// Kills a converter that accepts a zero sample rate and then divides by it, and one that
    /// accepts zero channels and produces an empty stream for every session — both of which look
    /// like "no audio was captured" rather than like a bug.
    func testAnImpossibleCaptureFormatIsRefusedRatherThanConverted() {
        for impossible in [
            CapturedAudioFormat(sampleRate: 0, channelCount: 1),
            CapturedAudioFormat(sampleRate: -48_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: .infinity, channelCount: 1),
            CapturedAudioFormat(sampleRate: .nan, channelCount: 1),
            CapturedAudioFormat(sampleRate: 48_000, channelCount: 0),
            CapturedAudioFormat(sampleRate: 48_000, channelCount: -2),
        ] {
            XCTAssertFalse(
                impossible.isValidCaptureFormat, "\(impossible) was accepted as a capture format")
            XCTAssertThrowsError(try AudioFormatConverter(inputFormat: impossible)) { error in
                // Matched on the case and then on the fields, rather than compared whole. The NaN
                // row is why: `CapturedAudioFormat`'s synthesised `==` compares `Double`s, and NaN
                // is not equal to itself, so `.unsupportedInputFormat(nan) == .unsupportedInputFormat(nan)`
                // is false. That is ordinary Swift and not a defect in the type — every struct with
                // a `Double` field behaves this way, `isValidCaptureFormat` rejects NaN by
                // `isFinite` rather than by comparison, and `isInterchange` correctly refuses it —
                // but it does mean an equality assertion here would fail on a correct build.
                guard
                    case .unsupportedInputFormat(let reported) = error
                        as? AudioFormatConversionError
                else {
                    return XCTFail(
                        "\(impossible) threw \(error), not an unsupported-format error")
                }
                XCTAssertEqual(reported.channelCount, impossible.channelCount)
                XCTAssertEqual(
                    reported.sampleRate.isNaN, impossible.sampleRate.isNaN,
                    "the rate reported back was not the rate refused")
                if !impossible.sampleRate.isNaN {
                    XCTAssertEqual(reported.sampleRate, impossible.sampleRate)
                }
            }
        }

        // And the rule accepts what it must, or it is simply "reject everything".
        for legitimate in [
            CapturedAudioFormat(sampleRate: 48_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: 16_000, channelCount: 1),
            CapturedAudioFormat(sampleRate: 8_000, channelCount: 8),
        ] {
            XCTAssertTrue(
                legitimate.isValidCaptureFormat, "\(legitimate) is a real device and was refused")
        }
    }

    // MARK: - Bounding what `import AVFoundation` costs

    /// **The set of files in `Sources/` that may name AVFoundation, asserted as an equality.**
    ///
    /// `VoccaAudio` was framework-free until this phase. Importing AVFoundation is what buys
    /// `AVAudioConverter`, and it is not free: the framework and its dependency graph now load into
    /// every process that links `VoccaAudio` — including `VoccaNetworkProbe`, which is the process
    /// the zero-network invariant observes.
    ///
    /// So the import is bounded the way the H7 seam bounds CoreGraphics: one reviewed list, checked
    /// both ways. **Too many** means an AVFoundation type is being named somewhere the plan says it
    /// may not go, which is how `AVAudioFormat` ends up in a signature `VoccaCore` has to read.
    /// **Too few** means the adapter stopped speaking to the framework and the seam has quietly
    /// moved.
    ///
    /// Phase 4 added the `AVAudioEngine` graph and edited this line to do it, exactly as promised:
    /// the graph (`AudioCaptureGraph.swift`) is the one new file with a reason to name the
    /// framework, and it is the only one added. That is the intended cost.
    ///
    /// The `first-run-permissions` unit (A2, `permission-reads`) adds the third file: the
    /// microphone-permission adapter (`MicrophoneAuthorization.swift`). Its status read and
    /// request are PRD M5/M5b's permission surface — `AVCaptureDevice` is where the TCC
    /// authorization answer and the request live — and R6's planned amendment is this reviewed
    /// row, exactly as the R6 row of `docs/planning/first-run-permissions/prd.md` promises.
    func testTheFilesThatImportAVFoundationAreExactlyTheExpectedSet() throws {
        let expected: Set<String> = [
            "VoccaAudio/AudioFormatConverter.swift",
            "VoccaAudio/AudioCaptureGraph.swift",
            "VoccaAudio/MicrophoneAuthorization.swift",
        ]

        let sources = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources")
        let files = SwiftSourceScanner.swiftFiles(under: sources)
        XCTAssertFalse(
            files.isEmpty,
            "No .swift files were found under \(sources.path) — this lint ran against nothing.")

        var importers: Set<String> = []
        for file in files {
            let modules = Set(try SwiftSourceScanner.importedModuleNames(in: file))
            guard !modules.isDisjoint(with: Self.avFoundationModules) else { continue }
            let relative = file.path.replacingOccurrences(of: sources.path + "/", with: "")
            importers.insert(relative)
        }

        XCTAssertEqual(
            importers, expected,
            """
            The set of files under Sources/ that import AVFoundation changed.

            Too many: AVFoundation types must not escape the adapter. A file that imports it can \
            name AVAudioFormat in a signature, and the plan's rule exists because the moment one \
            does, every caller — up to and including VoccaCore, which imports nothing at all — has \
            to import it to read that signature.
            Too few: the adapter no longer speaks to the framework, so either the conversion moved \
            somewhere unreviewed or it stopped happening.
            """)
    }

    /// The submodule spellings of AVFoundation, so that `import AVFAudio` is not a way past the
    /// list above.
    ///
    /// `AVFoundation` re-exports `AVFAudio`, which is where `AVAudioConverter`, `AVAudioFormat` and
    /// `AVAudioPCMBuffer` actually live — so importing the inner module gets every type this lint
    /// is about while naming none of the string it would otherwise match on.
    private static let avFoundationModules: Set<String> = [
        "AVFoundation", "AVFAudio", "AVKit",
    ]

    /// A re-export would hand AVFoundation to every importer of `VoccaAudio` at once.
    ///
    /// This is the same hole the H7 lint found for CoreGraphics: `@_exported import AVFoundation`
    /// in the one permitted file satisfies the file-set assertion above exactly, and reopens the
    /// rule across the entire module — every consumer of `VoccaAudio` would then be able to name
    /// `AVAudioFormat` without importing anything, so nothing downstream could be caught doing it.
    func testNoFileReExportsAVFoundation() throws {
        let sources = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources")
        let files = SwiftSourceScanner.swiftFiles(under: sources)
        XCTAssertFalse(files.isEmpty, "this lint ran against nothing")

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let reExported = SwiftSourceScanner.importStatements(inSource: source)
                .filter(\.isReExported)
                .map(\.module)
            XCTAssertTrue(
                Set(reExported).isDisjoint(with: Self.avFoundationModules),
                """
                \(file.lastPathComponent) re-exports AVFoundation. That makes every AVFoundation \
                type visible to everything importing this module, so the file-set lint above still \
                passes while the rule it enforces no longer holds anywhere.
                """)
        }

        // The scan's own control: it must be able to see the shape it is looking for.
        XCTAssertEqual(
            SwiftSourceScanner.importStatements(inSource: "@_exported import AVFAudio"),
            [SwiftSourceScanner.ImportStatement(module: "AVFAudio", isReExported: true)],
            "the re-export scan cannot see the form it exists to reject")
    }
}
