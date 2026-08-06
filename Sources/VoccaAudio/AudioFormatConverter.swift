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

import AVFoundation

/// Everything that can go wrong turning captured audio into the interchange format.
///
/// All of it is thrown on the **consumer** side. Nothing in this file runs on the realtime thread —
/// see ``AudioFormatConverter`` for why that is the whole point of the phase.
public enum AudioFormatConversionError: Error, Equatable, CustomStringConvertible {

    /// The hardware format cannot describe audio that exists.
    case unsupportedInputFormat(CapturedAudioFormat)

    /// AVFoundation would not build a format or a converter for a rate it should have accepted.
    case resamplerUnavailable(from: CapturedAudioFormat, to: CapturedAudioFormat)

    /// The output format read back out of AVFoundation is not ``CapturedAudioFormat/interchange``.
    case outputIsNotTheInterchangeFormat(CapturedAudioFormat)

    /// `AVAudioConverter` reported an error.
    case conversionFailed(String)

    /// The drain loop hit its iteration ceiling. See ``AudioFormatConverter`` for the bound.
    case conversionDidNotTerminate(producedFrames: Int)

    public var description: String {
        switch self {
        case .unsupportedInputFormat(let format):
            return """
                \(format) is not a capture format Vocca can read: the sample rate must be finite and \
                positive and there must be at least one channel.
                """
        case .resamplerUnavailable(let input, let output):
            return """
                AVFoundation would not build a converter from \(input) to \(output). Both are mono \
                Float32 formats, which is the case AVAudioFormat is reliable for — a failure here \
                means the input sample rate itself is one AVFoundation refuses.
                """
        case .outputIsNotTheInterchangeFormat(let format):
            return """
                The output format read back from AVFoundation is \(format), not \
                \(CapturedAudioFormat.interchange). This is acceptance A8 failing at construction, \
                which is the loud end: the alternative is a stream that is labelled 16 kHz mono and \
                is not, handed to an ASR engine that has no way to tell.
                """
        case .conversionFailed(let detail):
            return "AVAudioConverter failed: \(detail)"
        case .conversionDidNotTerminate(let produced):
            return """
                The conversion drain loop did not terminate after producing \(produced) frames. \
                AVAudioConverter is being driven in a loop, and a loop with no ceiling on the \
                consumer thread is a hang rather than a glitch. If a legitimate conversion ever \
                needs more iterations than the ceiling allows, raise the ceiling deliberately.
                """
        }
    }
}

/// Turns captured audio into **16 kHz mono Float32** — the format the ASR seam speaks.
///
/// ## This runs on the consumer side, and that is the whole shape of it
///
/// `AVAudioConverter` allocates: it builds output buffers, it holds filter state, and its
/// `convert(to:error:withInputFrom:)` calls back into Swift. Not one line of it may run on
/// CoreAudio's realtime thread, where an allocation is an audible click with nothing in any log.
/// So the split is: the realtime producer writes raw hardware-rate samples into
/// ``AudioRingBuffer``, and a consumer drains the ring and calls this. No declaration in this file
/// carries the realtime marker `RealtimeSafetyTests` selects on, and none should.
///
/// That marker is deliberately **not spelled out** in this file. The lint searches the *raw* source
/// for it — it must, since the marker is itself a comment — so writing it in prose creates a marker
/// that resolves to no declaration, which the lint then reports as a realtime function nothing is
/// checking. Measured: naming it in this paragraph failed eight tests. Phase 4 will want to know
/// that before it writes the sink node's documentation.
///
/// ## Three regimes, and the middle one is why "always resample" is wrong
///
/// | Input | What happens | ``isPassThrough`` | ``resampledFrameCount`` grows |
/// |---|---|---|---|
/// | 16 kHz mono | the samples are returned unchanged | `true` | no |
/// | 16 kHz multi-channel | downmix only | `false` | no |
/// | any other rate | downmix if needed, then resample | `false` | yes |
///
/// **The 16 kHz case is a Bluetooth HFP headset, and it is ordinary rather than exotic** — it is
/// what a built-in input becomes the moment someone wearing AirPods takes a call. Sending it
/// through a 16 kHz → 16 kHz resampler is lossy for no reason. Measured on this platform, that
/// particular round trip happens to be bit-exact today (an impulse survives as a single sample), so
/// **comparing output to input cannot tell the two implementations apart** — which is exactly why
/// ``isPassThrough`` and ``resampledFrameCount`` exist as observable state and why the test asserts
/// them rather than asserting equality alone.
///
/// ## Downmix: the arithmetic mean of every channel
///
/// Vocca owns this rather than delegating it to `AVAudioConverter`, for two measured reasons and one
/// design one:
///
/// - `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` **returns `nil` above two
///   channels**, so an `AVAudioConverter` that downmixes a four-channel interface cannot even be
///   constructed through the ordinary initialiser.
/// - Apple documents no downmix rule, so what a multi-channel conversion does is an OS-version
///   detail. A capture path whose channel handling changes under a system update is not one anyone
///   can test.
/// - The mean is the choice that does not lose a microphone. **Taking channel 0** — the other
///   obvious rule, and the one a naive `mBuffers.mData` read performs by accident — ships silence
///   for every interface whose microphone is wired to channel 2, and does it with no error
///   anywhere. The mean keeps a signal present on any channel, and it keeps a mono source that was
///   duplicated across channels at its original amplitude rather than summing it into clipping.
///
/// Its one real cost, named rather than discovered: two channels in **opposite phase** cancel to
/// silence. That is a broken or deliberately-decorrelated stereo pair, not a microphone array, and
/// no downmix rule handles it — first-channel selection merely fails differently.
///
/// ## Streaming, and the `reset()` that is not optional
///
/// ``convert(_:)`` never signals end-of-stream, so the resampler's filter state carries across
/// calls: chunked input produces **bit-identical** output to one-shot input (measured, 100 chunks of
/// 480 frames against a single 48000-frame call, max absolute difference 0). ``finish(_:)`` is the
/// only thing that flushes the tail.
///
/// And the reset that follows is **required, not hygiene**. Measured: a converter that has been
/// flushed to end-of-stream and is then handed a fresh session's audio produces **zero frames** —
/// the second session is entirely silent, with no error raised, on an object that looks perfectly
/// alive. `testASecondSessionProducesTheSameAudioAsTheFirst` is the test that holds this.
///
/// ## One session's audio must never reach another's, and `finish(_:)` alone cannot guarantee that
///
/// Three ways this type used to carry audio across the boundary, all silent and all worse than a
/// glitch — the user reads words they spoke into a different application, minutes earlier:
///
/// - **``finish(_:)`` threw.** Its cleanup ran only after the flush succeeded, so a throw left the
///   filter state and the partial frame in place for the next session to emit.
/// - **``convert(_:)`` threw**, which is the same defect at the site it is *likelier* at: once per
///   poll of the ring rather than once per session. It was missed in the round that fixed
///   ``finish(_:)`` — the reasoning written down in one place and not applied in the other.
/// - **Neither was called.** A session can end six ways and only one is a normal key-up; the other
///   five reach no teardown at all.
///
/// The rule is now applied at **every** throwing entry point: both `convert` and `finish` discard
/// the stream on their error paths, via the one `discardStreamState()`, and ``beginSession()``
/// anchors the reset at the point in a session's life that cannot be skipped — its start.
///
/// None of the three is detectable downstream: contaminated audio is indistinguishable from long
/// audio. ``isHoldingAudio`` makes the state observable so that an owner can assert on it.
///
/// ## Thread confinement
///
/// Not `Sendable`, deliberately: `AVAudioConverter` is not, and this type holds mutable filter
/// state. One consumer owns it. That mirrors ``AudioRingBuffer``'s consumer-side discipline — the
/// difference being that the ring must document an invariant the compiler cannot check, and this
/// type simply lets the compiler check it.
public final class AudioFormatConverter {

    /// The ceiling on the drain loop below.
    ///
    /// A loop around `AVAudioConverter` on the consumer thread is a hang if it never ends, and a
    /// hang is worse than a thrown error: the session never hands over and the user's audio is
    /// gone. Sized against the product's own limit — the 120 s session ceiling is 1,920,000 frames
    /// at 16 kHz, which is 235 iterations at ``drainChunkFrames`` — so this is roughly four times
    /// the largest legitimate demand, and in practice the loop runs two or three times.
    private static let maximumDrainIterations = 1024

    /// Output frames requested per iteration of the drain loop.
    ///
    /// **These two constants are a pair, and the earlier version of this comment claimed an
    /// independence they do not have.** What was measured is that the *output* does not depend on
    /// the chunk size — capacities of 1, 7, 100 and 8192 all produce the same 16000 frames from a
    /// one-second 48 kHz input — but that was measured with an effectively unbounded iteration
    /// count. The ceiling above is expressed in **iterations**, so halving this doubles the
    /// iterations the same audio needs: at a capacity of 1, a one-second capture would need 16000
    /// of them and would throw ``AudioFormatConversionError/conversionDidNotTerminate(producedFrames:)``
    /// on a perfectly correct conversion.
    ///
    /// What actually bounds the pair is their product: 1024 × 8192 is 8,388,608 output frames, or
    /// **524 s of 16 kHz audio** against the product's 120 s session ceiling — a 4.4× margin.
    /// `testTheDrainCeilingIsReachableAndReportsItself` drives past it deliberately, which is what
    /// makes that number a measurement rather than a claim. Change either constant with the product
    /// in front of you.
    private static let drainChunkFrames: AVAudioFrameCount = 8192

    /// The format this converter was built for.
    public let inputFormat: CapturedAudioFormat

    /// Always ``CapturedAudioFormat/interchange``. Named as a property so a caller reads the
    /// contract from the object rather than assuming it.
    public var outputFormat: CapturedAudioFormat { .interchange }

    /// `true` when the input is already the interchange format and ``convert(_:)`` returns its
    /// argument untouched.
    ///
    /// Load-bearing for the Bluetooth HFP case above, and observable so that the pass-through can be
    /// asserted rather than hoped for.
    public var isPassThrough: Bool { resampler == nil && inputFormat.channelCount == 1 }

    /// Mono frames handed to the sample-rate converter over this object's lifetime.
    ///
    /// Zero forever when ``isPassThrough``, and zero for a 16 kHz multi-channel input too — the
    /// downmix is not a resample. Cumulative rather than per-session: take a difference across a
    /// session if a per-session figure is wanted.
    public private(set) var resampledFrameCount = 0

    /// Samples dropped because they did not complete a frame.
    ///
    /// Always zero for a mono input, where every sample *is* a frame. For interleaved multi-channel
    /// input a drain of the ring can end mid-frame; ``convert(_:)`` carries the partial frame over to
    /// the next call, so the only samples counted here are the ones **still held when the stream
    /// ends** — at ``finish(_:)``, at ``beginSession()``, or on the error path of a `convert` that
    /// threw.
    ///
    /// ## The bound is what makes discarding them acceptable, and it is asserted
    ///
    /// **Fewer than `channelCount` per stream** — at most 3 samples for a four-channel interface,
    /// under 200 µs at any real rate — because ``convert(_:)`` retains only the remainder that is
    /// too short to be a frame. That bound is the entire reason a reset may throw the remainder
    /// away instead of carrying it: if a whole frame could ever be held, resetting would trade
    /// cross-session contamination for silent truncation, which is not a trade worth making.
    ///
    /// It is not left as a claim. `testEverySampleIsEitherConvertedOrCounted` asserts the exact
    /// conservation law over randomised chunk sizes and channel counts:
    /// `outputSamples × channelCount + discarded == samplesFed`. That is the same standard
    /// `AudioRingBuffer`'s "received + refused == sent" is held to, and for the same reason — the
    /// ring's overrun policy is defensible only because its loss is countable, and an uncounted
    /// loss on this path would undo that argument by arithmetic.
    ///
    /// Cumulative across streams. Take a difference for a per-session figure.
    public private(set) var discardedPartialFrameSampleCount = 0

    /// `nil` when the input rate is already the interchange rate — the case that must not resample.
    private let resampler: AVAudioConverter?

    /// Mono at the input rate. `nil` in the pass-through and downmix-only regimes.
    private let resamplerInputFormat: AVAudioFormat?

    /// Mono at 16 kHz. `nil` in the pass-through and downmix-only regimes.
    private let resamplerOutputFormat: AVAudioFormat?

    /// Whether this converter is holding audio that would otherwise reach the next session.
    ///
    /// **Computed from what is actually held, not from whether `convert` has been called.** The
    /// stored flag this replaced answered a different question — "has audio been through here" —
    /// and so reported `true` for a pass-through converter, which retains nothing at any point and
    /// can contaminate nothing. A hazard flag that is `true` where there is no hazard is one an
    /// owner learns to ignore.
    ///
    /// The two things that can be held are the resampler's filter state and a partial frame, so
    /// those are the two things this reads. It follows — correctly — that a 16 kHz mono
    /// pass-through is *never* holding, and that a 16 kHz multi-channel converter is holding
    /// exactly when a drain of the ring ended mid-frame.
    ///
    /// It exists so that an **abandoned** session is observable rather than silent: a session can
    /// end five ways that never reach ``finish(_:)``. See ``beginSession()``.
    public var isHoldingAudio: Bool { !partialFrame.isEmpty || resamplerHoldsState }

    /// Samples left over from the previous ``convert(_:)`` that did not complete a frame.
    ///
    /// **Always fewer than `inputFormat.channelCount`.** See ``discardedPartialFrameSampleCount``
    /// for why that bound is load-bearing and where it is asserted.
    private var partialFrame: [Float] = []

    /// Whether frames have been pushed into the resampler since it was last reset.
    ///
    /// `AVAudioConverter` cannot be asked whether it holds filter state, so it is tracked here.
    /// Conservative in the safe direction: set when frames are handed over, cleared only by a reset
    /// that has actually happened.
    private var resamplerHoldsState = false

    /// - Throws: ``AudioFormatConversionError`` if the format cannot be read, or if AVFoundation
    ///   will not produce the interchange format on the other side.
    public init(inputFormat: CapturedAudioFormat) throws {
        guard inputFormat.isValidCaptureFormat else {
            throw AudioFormatConversionError.unsupportedInputFormat(inputFormat)
        }
        self.inputFormat = inputFormat

        let interchange = CapturedAudioFormat.interchange
        guard inputFormat.sampleRate != interchange.sampleRate else {
            // The Bluetooth HFP case, and the mono case that needs nothing at all. No
            // `AVAudioConverter` is built, so none can be used by accident later.
            self.resampler = nil
            self.resamplerInputFormat = nil
            self.resamplerOutputFormat = nil
            return
        }

        // Both formats are **mono**, which is the case AVAudioFormat is reliable for — the channel
        // work has already happened by the time anything reaches here.
        guard
            let avInput = Self.monoFloat32Format(sampleRate: inputFormat.sampleRate),
            let avOutput = Self.monoFloat32Format(sampleRate: interchange.sampleRate)
        else {
            throw AudioFormatConversionError.resamplerUnavailable(from: inputFormat, to: interchange)
        }

        // A8, checked at construction by **reading the format back out of AVFoundation** rather
        // than by trusting the constant that was just written into it. It catches a rate
        // AVFoundation normalises, a channel count it will not honour, and a sample type that is
        // not Float32 — the three ways the seam boundary could move while every label still said
        // 16 kHz mono. It does not catch someone editing `CapturedAudioFormat.interchange` itself;
        // the count-versus-ratio tests are what catch that, because they read the rate off the
        // data.
        //
        // The decision is `isUsableInterchangeOutput` rather than an inline `guard`, for the reason
        // `AudioRingBuffer.isValidCapacity(_:)` is a function: **no test can make AVFoundation
        // return the wrong format here**, so as an inline condition it was satisfiable by any
        // predicate at all — measured, deleting it failed nothing. Extracted, the rule is tested
        // even though the path that consults it cannot be driven.
        let readBack = CapturedAudioFormat(
            sampleRate: avOutput.sampleRate, channelCount: Int(avOutput.channelCount))
        guard
            Self.isUsableInterchangeOutput(
                format: readBack, isFloat32: avOutput.commonFormat == .pcmFormatFloat32)
        else {
            throw AudioFormatConversionError.outputIsNotTheInterchangeFormat(readBack)
        }

        guard let resampler = AVAudioConverter(from: avInput, to: avOutput) else {
            throw AudioFormatConversionError.resamplerUnavailable(from: inputFormat, to: interchange)
        }

        self.resampler = resampler
        self.resamplerInputFormat = avInput
        self.resamplerOutputFormat = avOutput
    }

    /// Whether an output format AVFoundation actually built is one this seam may hand to ASR.
    ///
    /// Both halves are load-bearing and neither implies the other. ``CapturedAudioFormat`` carries
    /// the rate and the channel count; it deliberately has no sample-type field, because `[Float]`
    /// already says Float32 — so the sample type has to be checked separately, against the format
    /// AVFoundation built rather than against the array that will hold the result.
    ///
    /// - Parameter isFloat32: whether the built format's `commonFormat` is `.pcmFormatFloat32`.
    ///   Passed as a `Bool` rather than as the AVFoundation enum so that this rule, and the test on
    ///   it, need no import.
    public static func isUsableInterchangeOutput(
        format: CapturedAudioFormat, isFloat32: Bool
    ) -> Bool {
        format.isInterchange && isFloat32
    }

    // MARK: - Converting

    /// Convert a run of captured samples, returning whatever the interchange format has ready.
    ///
    /// Streaming: the resampler's filter state is kept, so the caller may hand over the ring's
    /// drains in whatever sizes they arrive in. The returned count is therefore **not** a fixed
    /// ratio of the argument's — the resampler holds a tail back — and the totals only line up once
    /// ``finish(_:)`` has flushed.
    ///
    /// **A throw ends the stream.** The frames this call had already produced are lost with the
    /// error and the resampler's position becomes indeterminate, so there is nothing to continue;
    /// what is held is discarded rather than carried into the next session, and any partial frame
    /// goes to ``discardedPartialFrameSampleCount``. The loss is loud — the caller gets the error —
    /// which is the whole difference between this and the silent contamination it replaced.
    ///
    /// - Parameter samples: interleaved frames in ``inputFormat``. See ``CapturedAudioFormat`` for
    ///   what interleaved means here and whose obligation it is.
    public func convert(_ samples: [Float]) throws -> [Float] {
        // **The error path, and this is the site that matters most.** `finish(_:)` was made
        // exception-safe first, but it runs once per session while this runs once per poll — so
        // this is where a throw is far likelier, and it was left unprotected while a test in this
        // module asserted the standard it failed to meet. A throw here already loses the frames
        // this call produced (`drain` accumulates locally and the error discards them) and leaves
        // the resampler's position indeterminate, so the stream cannot be continued. What it must
        // not do is carry that wreckage into the *next* session.
        //
        // The loss is loud rather than silent: the caller gets a thrown error, and whatever partial
        // frame was held is added to ``discardedPartialFrameSampleCount``.
        var completed = false
        defer { if !completed { discardStreamState() } }

        let mono = downmixToMono(samples)
        guard !mono.isEmpty else {
            completed = true
            return []
        }
        guard let resampler, let resamplerInputFormat, let resamplerOutputFormat else {
            // Pass-through, or downmix only. Nothing is resampled and nothing is counted as
            // resampled — which is what the pass-through test reads.
            completed = true
            return mono
        }

        resampledFrameCount += mono.count
        resamplerHoldsState = true

        // `nonisolated(unsafe)`, twice, and this is the concurrency cost of `import AVFoundation`
        // rather than a shortcut. `AVAudioConverterInputBlock` is imported as `@Sendable`, so a
        // block that captures a mutable flag or an `AVAudioPCMBuffer` — which is what supplying
        // input *is* — will not compile under strict concurrency without one of three things: this
        // annotation, `@preconcurrency import`, or a second `@unchecked Sendable` type.
        //
        // The last two are both worse. `@preconcurrency` would downgrade every Sendable diagnostic
        // from the whole of AVFAudio to a warning, in the module that is about to acquire an
        // `AVAudioEngine`; and `AudioRingBuffer`'s comment opens by stating that it is the only
        // `@unchecked Sendable` in the codebase, which is a claim worth more than this convenience.
        //
        // What makes it sound: `convert(to:error:withInputFrom:)` calls this block **synchronously,
        // on the calling thread, before it returns**. There is no second thread, so there is
        // nothing for `@Sendable` to protect against here. The annotation is narrow — two locals in
        // one function, not a type-wide escape — and it does not travel.
        nonisolated(unsafe) let inputBuffer = try Self.makeBuffer(mono, format: resamplerInputFormat)
        nonisolated(unsafe) var supplied = false
        let output = try drain(resampler, into: resamplerOutputFormat) { _, status in
            if supplied {
                // **`.noDataNow`, never `.endOfStream`.** End-of-stream here would flush the filter
                // on every drain of the ring, splicing a discontinuity into the middle of the
                // user's sentence once per poll.
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inputBuffer
        }
        completed = true
        return output
    }

    /// Begin a session, discarding anything a previous one left behind.
    ///
    /// ## Why the anchor is the *start* of a session and not the end
    ///
    /// A session can end six ways — `session-lifecycle` has six stop rules and only one of them is a
    /// normal key-up. The ceiling fires, the tap dies, a configuration change ends it, the user
    /// cancels. **Assume ``finish(_:)`` is not called**, because most of the time something other
    /// than a key-up is what ended the capture.
    ///
    /// There is exactly one thing every session does, and it is starting. So that is where the
    /// reset lives. Calling this is the owner's obligation, and it is the *only* obligation of its
    /// kind on the non-optional path — where anchoring cleanup to ``finish(_:)`` alone puts it on
    /// five paths that can be skipped.
    ///
    /// ## Call it *between* sessions, never inside one
    ///
    /// Idempotent and non-throwing, and safe on a converter that has never been used — but **not**
    /// safe in the middle of a capture, and the earlier wording ("safe to call at any time") invited
    /// exactly the over-correction this method exists to avoid. Called mid-stream it discards the
    /// stream in flight: the resampler's filter state and the partial frame belonging to the
    /// session *currently being recorded*. That trades cross-session contamination for silent
    /// truncation of the session in hand, which is not an improvement — it is the same class of
    /// defect pointed at a different session.
    ///
    /// Whatever it discards is added to ``discardedPartialFrameSampleCount``, so abandoning a
    /// session is countable rather than silent — the same standard ``AudioRingBuffer``'s overrun
    /// policy is held to. ``isHoldingAudio`` says whether there is anything to discard.
    ///
    /// **What this prevents is not a rounding error.** Audio held from one session and emitted into
    /// the next is the user reading words they spoke into a different application, minutes earlier,
    /// in a different context. Nothing downstream can tell contaminated audio from long audio.
    public func beginSession() {
        discardStreamState()
    }

    /// Flush the resampler's tail and end the stream.
    ///
    /// It does leave the converter clean — but **do not read that as "so ``beginSession()`` is
    /// optional"**, which is what the earlier wording ("make this object ready for the next
    /// session") invited. This is one of six ways a session ends and the only one that runs here;
    /// the reset is anchored at ``beginSession()`` precisely because the other five never reach
    /// this method.
    ///
    /// - Parameter samples: a final run of captured samples, converted before the flush. Defaults to
    ///   empty; the parameter exists so that the last drain of the ring and the flush are one call
    ///   and cannot be separated by an early `return`.
    ///
    /// **The cleanup is in a `defer`, and that is the fix rather than a tidiness.** Both `try`s
    /// below can throw, and the earlier version cleaned up only after the second one succeeded — so
    /// a throw left the resampler's filter state and any partial frame in place, and the *next*
    /// session's first `convert` emitted the failed session's audio ahead of its own. A `defer`
    /// runs on the throwing path too, which is the only version of this that a failure cannot skip.
    public func finish(_ samples: [Float] = []) throws -> [Float] {
        defer { discardStreamState() }

        var output = try convert(samples)
        guard let resampler, let resamplerOutputFormat else { return output }

        output += try drain(resampler, into: resamplerOutputFormat) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        return output
    }

    /// Drop everything held on behalf of a stream: the partial frame, and the resampler's state.
    ///
    /// The single implementation behind **all three** exits — ``beginSession()``, ``finish(_:)``'s
    /// `defer`, and ``convert(_:)``'s error path — so they cannot drift into cleaning up different
    /// amounts. That is the point: the standard is applied at every throwing entry point rather
    /// than written down at one of them.
    private func discardStreamState() {
        // Counted, because an uncounted loss on this path is the one thing `AudioRingBuffer`'s
        // overrun argument cannot survive. Always fewer than `channelCount` samples, and zero for
        // mono — asserted as an exact conservation law, not assumed. See
        // ``discardedPartialFrameSampleCount``.
        discardedPartialFrameSampleCount += partialFrame.count
        partialFrame.removeAll(keepingCapacity: true)

        // **Required, and not only after a flush.** A converter that has been flushed to
        // end-of-stream produces zero frames for the next session until it is reset — measured, no
        // error raised, the object apparently healthy. A converter *abandoned* mid-stream is worse:
        // it carries real audio forward rather than nothing.
        resampler?.reset()
        resamplerHoldsState = false
    }

    // MARK: - The pieces

    /// The arithmetic mean of every channel, frame by frame.
    ///
    /// Returns its argument untouched for mono input — not a copy with extra steps, and not a
    /// division by one.
    private func downmixToMono(_ samples: [Float]) -> [Float] {
        let channels = inputFormat.channelCount
        guard channels > 1 else { return samples }

        let pending = partialFrame.isEmpty ? samples : partialFrame + samples
        let frames = pending.count / channels
        let consumed = frames * channels
        partialFrame = Array(pending[consumed...])
        guard frames > 0 else { return [] }

        let scale = 1 / Float(channels)
        return pending.withUnsafeBufferPointer { source in
            [Float](unsafeUninitializedCapacity: frames) { destination, initializedCount in
                for frame in 0..<frames {
                    var sum: Float = 0
                    let base = frame * channels
                    for channel in 0..<channels { sum += source[base + channel] }
                    destination[frame] = sum * scale
                }
                initializedCount = frames
            }
        }
    }

    /// Pull from `resampler` until it stops producing, and return everything it produced.
    private func drain(
        _ resampler: AVAudioConverter,
        into outputFormat: AVAudioFormat,
        supply: @escaping AVAudioConverterInputBlock
    ) throws -> [Float] {
        var output: [Float] = []
        for _ in 0..<Self.maximumDrainIterations {
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat, frameCapacity: Self.drainChunkFrames)
            else {
                throw AudioFormatConversionError.conversionFailed(
                    "AVAudioPCMBuffer would not allocate \(Self.drainChunkFrames) frames")
            }

            var conversionError: NSError?
            let status = resampler.convert(to: buffer, error: &conversionError, withInputFrom: supply)
            if let conversionError {
                throw AudioFormatConversionError.conversionFailed(conversionError.description)
            }
            if status == .error {
                throw AudioFormatConversionError.conversionFailed(
                    "AVAudioConverter reported .error without populating an NSError")
            }

            let produced = Int(buffer.frameLength)
            if produced > 0, let channelData = buffer.floatChannelData {
                output.append(
                    contentsOf: UnsafeBufferPointer(start: channelData[0], count: produced))
            }
            // `.haveData` means the output buffer filled before the input ran out, so there is more
            // waiting. Anything else — `.inputRanDry`, `.endOfStream` — means this pull is done.
            if status != .haveData { return output }
        }
        throw AudioFormatConversionError.conversionDidNotTerminate(producedFrames: output.count)
    }

    /// A mono Float32 `AVAudioFormat`, or `nil` if AVFoundation refuses the rate.
    ///
    /// Deinterleaved, which for one channel is a distinction without a difference and is stated
    /// only so that every `floatChannelData[0]` in this file is unambiguously the whole signal.
    private static func monoFloat32Format(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// Copy `samples` into a fresh `AVAudioPCMBuffer`.
    ///
    /// Allocates, which is exactly what this side of the seam is for.
    private static func makeBuffer(
        _ samples: [Float], format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channelData = buffer.floatChannelData
        else {
            throw AudioFormatConversionError.conversionFailed(
                "AVAudioPCMBuffer would not allocate \(samples.count) frames at \(format.sampleRate) Hz")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channelData[0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
