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

import CoreAudioTypes
import Synchronization

/// **The channel policy, lifted out of the sink node so that a test can execute it.**
///
/// `plan_20260806.md`'s Phase 4 says of the choice between keeping channel 0 and interleaving every
/// channel: *"Nothing in `VoccaAudio` can check this; it is this phase's obligation and it is the one
/// thing here that no test will catch."* That was true of the shape the plan assumed — the whole copy
/// written inline in the `AVAudioSinkNode` block, in the file CI cannot execute a line of.
///
/// **It is not true of this shape, and that is the reason for this file.** `AudioBufferList` is a
/// plain C struct from `CoreAudioTypes`; nothing about it needs a microphone, an engine, or a
/// realtime thread. A test builds a deinterleaved two-channel list in memory, drives this type, and
/// reads the ring back — so *"the declared format matches what actually went into the ring"* stops
/// being an obligation on the implementer's care and becomes an assertion. The plan's own validation
/// rule invites exactly this: *"If review finds a branch worth testing here, it moves up."* This is
/// that branch, and it is the one whose failure is silent.
///
/// What is left below the seam, in `AudioCaptureGraph`, is the graph: build it, start it, stop it.
/// It contains no realtime code at all, because ``receive(timestamp:frameCount:audioBufferList:)``
/// below is the sink node's block itself.
///
/// ## Why the sink node's block lives here and not on the graph
///
/// **Not a matter of taste — `AVAudioSinkNode(receiverBlock: self.render)` on the graph leaks the
/// whole graph, measured rather than reasoned about.** `self.render` is a bound method reference,
/// which captures `self` strongly; the graph stores the node; so graph → node → block → graph is a
/// cycle and the graph's `deinit` never runs. A 30-line probe against the real framework confirmed
/// it: `deinit` did not run at all, and with the block moved to an object that holds no reference
/// back, both objects released normally.
///
/// **What that costs is the one thing this aspect cares about most.** The graph's `deinit` is what
/// stops the engine, and constraint 2 of `spec.md` is that a running engine with input enabled lights
/// macOS's orange microphone indicator (`AVAudioEngine.h:465-466`). A graph that can never be
/// released is an engine that can never be stopped by release — so the leak is not a memory
/// footnote, it is the privacy defect the constraint exists to prevent, reached by the one route no
/// test in this repository looks at.
///
/// So this object owns the block, and it holds the ring and its scratch and nothing else. It has no
/// reference to the graph, the engine or the node, which is what makes the graph releasable.
///
/// ## Interleave, not channel 0
///
/// `AudioBufferList.mBuffers` is buffer **0**. On a *deinterleaved* device — `mNumberBuffers == N`,
/// one channel each, which is the ordinary macOS input layout — that is **channel 0 alone**. Keeping
/// it would throw away half of every stereo capture, and would record silence outright on an
/// interface whose microphone is wired to a later channel: invisible to every test, every log and
/// the user, until the transcript is thin or empty. ``AudioFormatConverter``'s downmix exists to
/// prevent precisely that, and interleaving is what lets that tested code see the channels at all.
///
/// ## The one assumption, stated because it is not checkable at runtime
///
/// Channels are laid out at a **uniform stride**: buffer *b* carries channels
/// `b * mNumberChannels ..< (b + 1) * mNumberChannels`. Both layouts CoreAudio produces satisfy it —
/// interleaved is one buffer of N channels, deinterleaved is N buffers of one — and it is what lets
/// the destination channel be an expression rather than a running total, which matters because a
/// running total is a mutation and the realtime path may not have one.
///
/// A hypothetical mixed list (say two buffers of two channels, then one of one) would be mapped
/// wrongly rather than rejected. It is bounded — the destination index is clamped to
/// ``channelCount``, so nothing is written out of range — and it is **tested**, so the behaviour is
/// recorded rather than discovered. No CoreAudio input unit is known to produce one.
public final class AudioBufferListInterleaver {

    /// How many channels the ring is being told it contains.
    ///
    /// **This is the number that must agree with what is actually written**, and the whole reason
    /// this type exists as something a test can drive: `CapturedAudioFormat(channelCount: 2)` over a
    /// ring holding only channel 0 makes the downmix average channel 0 against itself — the mean of
    /// one number — silently, forever.
    public let channelCount: Int

    /// The largest frame count a single callback may deliver.
    public let maximumFrameCount: Int

    /// Where the samples go. Held rather than passed per callback, so that the sink node's block is a
    /// method on this object and the graph can be released — see this type's header.
    public let ring: AudioRingBuffer

    /// Interleaved scratch, allocated once for the object's lifetime.
    ///
    /// The realtime thread cannot allocate, and the ring takes a contiguous run of samples, so the
    /// strided read has to land somewhere first. `capacity` is `maximumFrameCount * channelCount`.
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int

    /// Byte offset of `mBuffers` inside `AudioBufferList`, resolved **once, here, off the realtime
    /// thread.**
    ///
    /// `MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)` is the documented way to reach the
    /// first buffer without a subscript — and `\.mBuffers` is a key path, whose materialisation is
    /// not something to do on the audio thread. Resolved at construction and stored as an `Int`, so
    /// the realtime body does pointer arithmetic and nothing else.
    private let firstBufferByteOffset: Int

    /// Samples a callback could not deliver because it was larger than ``maximumFrameCount``.
    ///
    /// **Counted, not asserted, for the same reason ``AudioRingBuffer/refusedSampleCount`` is**: the
    /// invariant *a transcript is never lost* is served by loss being **countable**, not by declaring
    /// it impossible. `AVAudioEngine` sizes its render blocks from the device's buffer frame size and
    /// this object is built from `maximumFramesToRender`, so this should never move — which is an
    /// argument, and arguments are what this counter exists to survive.
    ///
    /// A plain `load`-then-`store`, never `wrappingAdd`: there is exactly one writer, and
    /// `AudioRingBuffer` makes the same claim about its own counters for the same reason.
    private let oversizedSamples = Atomic<UInt64>(0)

    /// The newest published input level, 0...1 — the greatest sample magnitude of the most recent
    /// callback, written by the realtime body over the just-written window and read by the
    /// widget's level source (`MicrophoneLevelSource`) through the seam.
    ///
    /// A plain `store`/`load`, `.relaxed` in both directions, and the claim is exactly the ring's
    /// refusal counter's: the realtime body is the steady writer, `resetPublishedLevel()` is a
    /// second one that only ever stores 0 from `stop()` — never a read-modify-write, and a reset
    /// racing a callback's store is benign, because the reader sees one or the other and either is
    /// a valid level. Nothing hangs off the value, so there is nothing for an ordering pair to
    /// publish.
    private let publishedLevel = Atomic<Float>(0)

    /// - Parameters:
    ///   - channelCount: channels the input node delivers, and the number the ring's
    ///     ``CapturedAudioFormat`` must declare.
    ///   - maximumFrameCount: the largest frame count one callback can carry. From the input unit's
    ///     `maximumFramesToRender`, with headroom — see ``AudioCaptureGraph``.
    ///   - ring: where the interleaved samples go, for this object's lifetime.
    public init(channelCount: Int, maximumFrameCount: Int, ring: AudioRingBuffer) {
        precondition(
            channelCount > 0 && maximumFrameCount > 0,
            "AudioBufferListInterleaver needs at least one channel and one frame, got \(channelCount) × \(maximumFrameCount)"
        )
        guard let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) else {
            // Unreachable for a C struct, which has a fixed layout in every Swift version that can
            // import it. Trapping rather than guessing a byte offset: a wrong one reads the buffer
            // list off by a field and captures whatever is next in memory, which is the class of
            // defect this file exists to make testable rather than to introduce.
            preconditionFailure("AudioBufferList has no resolvable offset for mBuffers")
        }
        self.channelCount = channelCount
        self.maximumFrameCount = maximumFrameCount
        self.ring = ring
        self.firstBufferByteOffset = offset
        self.scratchCapacity = maximumFrameCount * channelCount
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        self.scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        // `Float` is trivial and `deallocate()` is `free(3)`, which asserts no isolation domain —
        // which is what a `deinit` requires, since it runs wherever the last release happens. The
        // rule has now been needed a fifth time; `DeinitIsolationTests` is the lint for it.
        scratch.deallocate()
    }

    /// Samples dropped because a callback exceeded ``maximumFrameCount``.
    public var oversizedSampleCount: Int { Int(oversizedSamples.load(ordering: .relaxed)) }

    /// The newest published input level, 0...1 — the level source's read, through the seam.
    public var levelPeak: Float { publishedLevel.load(ordering: .relaxed) }

    /// Clear the published level to 0 — the graph's `stop()` calls this so a fresh session's first
    /// reading is silence, never the previous session's peak (`MicrophoneLevelTests` pins that a
    /// session starts silent). A plain store off the realtime thread: `stop()` runs after
    /// `engine.stop()` has torn the I/O down, so no callback is in flight when the reset lands.
    public func resetPublishedLevel() {
        publishedLevel.store(0, ordering: .relaxed)
    }

    /// **The `AVAudioSinkNode` block itself**, in the shape the framework's `receiverBlock` takes.
    ///
    /// Handed to the node as `AVAudioSinkNode(receiverBlock: interleaver.receive)`, so that the
    /// strong reference the block holds is to *this* object and not to the graph — which is what
    /// keeps the graph releasable and therefore its engine stoppable. See this type's header for the
    /// leak that shape prevents and how it was measured.
    ///
    /// `frameCount` is spelled `UInt32` because that is exactly what the framework's parameter is:
    /// `AVAudioFrameCount` is a plain `typedef uint32_t` in `AVAudioTypes.h`, and naming it would
    /// require `import AVFoundation` in the one file this package's lint says must not — the
    /// parameter *is* `UInt32`, so a function written this way binds to the node's block unchanged.
    ///
    /// Two statements, and the return is always `noErr`: a sink node has nobody to report to, and a
    /// refusal is already counted where the count can be read.
    // @realtime — RealtimeSafetyTests lints the body below. CoreAudio calls this on its own thread
    // with a deadline of a few milliseconds and no way to report missing one, and **nothing in CI
    // executes it**, so the lint is the only check there is.
    func receive(
        timestamp: UnsafePointer<AudioTimeStamp>, frameCount: UInt32,
        audioBufferList: UnsafePointer<AudioBufferList>
    ) -> OSStatus {
        interleave(from: audioBufferList, frameCount: Int(frameCount))
        return noErr
    }

    /// Copy one callback's frames into ``ring``, interleaved, and report whether the ring took them.
    ///
    /// Separate from ``receive(timestamp:frameCount:audioBufferList:)`` because this is the half a
    /// test can drive: it takes an `AudioBufferList` and an `Int`, both of which a test can build,
    /// where the signature above is fixed by the framework and carries an `AudioTimeStamp` no test
    /// has any use for.
    ///
    /// - Returns: `true` when every sample reached the ring. `false` is a *counted* loss — either
    ///   the ring was full (``AudioRingBuffer/refusedSampleCount``) or the callback was larger than
    ///   this object was built for (``oversizedSampleCount``).
    // @realtime — RealtimeSafetyTests lints the body below. This runs on CoreAudio's audio thread,
    // called from `receive` above, and the lint is the only check there is: nothing in CI ever
    // executes the sink node that calls it.
    @discardableResult
    public func interleave(
        from list: UnsafePointer<AudioBufferList>, frameCount: Int
    ) -> Bool {
        let total = frameCount * channelCount
        guard frameCount > 0 else { return frameCount == 0 }
        guard total <= scratchCapacity else {
            oversizedSamples.store(
                oversizedSamples.load(ordering: .relaxed) &+ UInt64(total), ordering: .relaxed)
            return false
        }

        let buffers = UnsafeRawPointer(list)
            .advanced(by: firstBufferByteOffset)
            .assumingMemoryBound(to: AudioBuffer.self)
        let bufferCount = Int(list.pointee.mNumberBuffers)

        for bufferIndex in 0..<bufferCount {
            let buffer = buffers.advanced(by: bufferIndex).pointee
            let channelsHere = Int(buffer.mNumberChannels)
            let data = buffer.mData
            // A null `mData` is not a state an input render callback reaches; skipping rather than
            // trapping, because a trap here is a crash inside CoreAudio's thread with no way to
            // report and the frames are already counted as loss by the ring.
            if data == nil { continue }
            let source = data.unsafelyUnwrapped.assumingMemoryBound(to: Float.self)

            // The uniform-stride assumption, as an expression rather than a running total. A total
            // would be a mutation, and pass 4 of the realtime lint forbids those — correctly, since
            // the shapes it is really aimed at are a copy-on-write check and a property write.
            let channelBase = bufferIndex * channelsHere

            for channel in 0..<channelsHere {
                let destinationChannel = channelBase + channel
                // Clamps the exotic layout the header names. Nothing is written out of range.
                if destinationChannel >= channelCount { continue }
                for frame in 0..<frameCount {
                    scratch.advanced(by: frame * channelCount + destinationChannel).pointee =
                        source.advanced(by: frame * channelsHere + channel).pointee
                }
            }
        }

        // The callback body stays minimal: the copy, the write, and the one publish the widget's
        // level depends on — the accounting itself is `MicrophoneLevelSource.peak`, linted in its
        // own right (the "accounting above the callback" rule, widget-live-states Task 4).
        let accepted = ring.write(scratch, count: total)
        publishedLevel.store(
            MicrophoneLevelSource.peak(of: scratch, count: total), ordering: .relaxed)
        return accepted
    }
}
