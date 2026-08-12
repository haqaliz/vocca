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

import AVFAudio
import CoreAudioTypes
import XCTest

@testable import VoccaAudio

/// **Phase 4's channel policy, driven by hand-built `AudioBufferList` values and read back out of
/// the ring.**
///
/// `plan_20260806.md`'s correction names the defect it said no test would catch: *"the declared
/// format must match what actually went into the ring"* — a `CapturedAudioFormat(channelCount: 2)`
/// over a ring holding only channel 0 makes Phase 2's downmix average channel 0 against itself,
/// silently, forever. That was true of the shape the plan assumed, the whole copy written inline in
/// the `AVAudioSinkNode` block in a file CI cannot execute a line of. It is not true of this
/// shape: `AudioBufferList` is a plain C struct, so a test builds the exact lists CoreAudio's
/// input render callback produces and reads the ring back. The one assumption this relies on is
/// stated in ``AudioBufferListInterleaver``'s header and pinned by the last test here.
///
/// These tests are also the only execution the Phase 4 realtime path will ever get. The sink node
/// that calls ``AudioBufferListInterleaver/receive(timestamp:frameCount:audioBufferList:)`` is
/// unsupported in manual rendering mode and there is no microphone on a hosted runner, so the A3
/// lint asserts the realtime bodies' *shape* by source and this file asserts their *correctness*
/// by driving the copy itself.
final class AudioBufferListInterleavingTests: XCTestCase {

    /// A deinterleaved list — the ordinary macOS input layout: `mNumberBuffers == N`, one channel
    /// per buffer. Every channel must land in the declared order, and the ring must accept exactly
    /// frames × channels samples. An interleaver that keeps only channel 0 would pass a "is the
    /// ring non-empty" check and fail here on three assertions.
    func testADeinterleavedTwoChannelListInterleavesInDeclaredChannelOrder() {
        let ring = AudioRingBuffer(capacity: 64)
        let interleaver = AudioBufferListInterleaver(channelCount: 2, maximumFrameCount: 16, ring: ring)

        withList([
            (channels: 1, samples: [1, 3, 5]),
            (channels: 1, samples: [2, 4, 6]),
        ]) { list in
            XCTAssertTrue(interleaver.interleave(from: list, frameCount: 3))
        }

        XCTAssertEqual(
            ring.availableToRead, 6,
            "the ring accepted fewer or more than frames × channels, so the declared format and "
                + "the samples already disagree")
        XCTAssertEqual(ring.drain(), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(interleaver.oversizedSampleCount, 0)
    }

    /// An interleaved list — `mNumberBuffers == 1`, `mNumberChannels == N`: the whole frame is one
    /// buffer. The other half of the layouts CoreAudio produces, and the one where `.mBuffers`
    /// alone *is* the whole frame rather than channel 0 of it.
    func testAnInterleavedListCarriesWholeFramesInOneBuffer() {
        let ring = AudioRingBuffer(capacity: 64)
        let interleaver = AudioBufferListInterleaver(channelCount: 2, maximumFrameCount: 16, ring: ring)

        withList([(channels: 2, samples: [1, 2, 3, 4, 5, 6])]) { list in
            XCTAssertTrue(interleaver.interleave(from: list, frameCount: 3))
        }

        XCTAssertEqual(ring.drain(), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(interleaver.oversizedSampleCount, 0)
    }

    /// A null `mData` is not a state an input render callback reaches; the interleaver's choice is
    /// to skip rather than trap, because a trap is a crash inside CoreAudio's thread with no way to
    /// report. What must hold then is that the loss stays **countable**: the ring's count is still
    /// exactly frames × channels (the skip must not shorten what the ring believes it holds), and
    /// a refused write still counts the whole block, nil buffer included.
    func testANullDataBufferIsSkippedWithoutTrappingAndTheLossStaysCountable() {
        let ring = AudioRingBuffer(capacity: 64)
        let interleaver = AudioBufferListInterleaver(channelCount: 2, maximumFrameCount: 16, ring: ring)

        withList([
            (channels: 1, samples: [1, 2]),
            (channels: 1, samples: nil),
        ]) { list in
            XCTAssertTrue(interleaver.interleave(from: list, frameCount: 2))
        }
        XCTAssertEqual(
            ring.availableToRead, 4,
            "a skipped buffer shortened the ring's count, so the accounting no longer matches the "
                + "declared format")
        XCTAssertEqual(ring.drain(), [1, 0, 2, 0], "the skipped channel's slots are silent, not garbage")

        // The countable half: with the ring full, the same callback is refused whole and counted
        // whole — the nil buffer must not make the refusal record a short block.
        let full = AudioRingBuffer(capacity: 4)
        let second = AudioBufferListInterleaver(channelCount: 2, maximumFrameCount: 16, ring: full)
        withList([
            (channels: 1, samples: [9, 9]),
            (channels: 1, samples: [8, 8]),
        ]) { list in
            XCTAssertTrue(second.interleave(from: list, frameCount: 2))
        }
        withList([
            (channels: 1, samples: [1, 2]),
            (channels: 1, samples: nil),
        ]) { list in
            XCTAssertFalse(second.interleave(from: list, frameCount: 2))
        }
        XCTAssertEqual(
            full.refusedSampleCount, 4,
            "the refused count is the whole block, not just the buffers that carried data")
    }

    /// A callback larger than the interleaver was built for is **dropped whole and counted**, never
    /// partially written — the ring's own policy (drop-newest, whole block, counted) applied one
    /// stage earlier. `maximumFramesToRender` is what the engine is configured for and a device
    /// whose buffer size changes underneath a running engine is a real thing, so the count exists
    /// to be read, exactly like the ring's refusal counter.
    func testACallbackLargerThanTheInterleaverWasBuiltForIsCountedAndWritesNothing() {
        let ring = AudioRingBuffer(capacity: 64)
        // maximumFrameCount 4 × 2 channels = 8 samples of scratch; a 5-frame callback wants 10.
        let interleaver = AudioBufferListInterleaver(channelCount: 2, maximumFrameCount: 4, ring: ring)

        withList([
            (channels: 1, samples: [1, 2, 3, 4, 5]),
            (channels: 1, samples: [6, 7, 8, 9, 10]),
        ]) { list in
            XCTAssertFalse(interleaver.interleave(from: list, frameCount: 5))
        }

        XCTAssertEqual(
            interleaver.oversizedSampleCount, 10,
            "the oversized block's samples were not counted, so the loss is not countable")
        XCTAssertEqual(ring.availableToRead, 0, "a partially-written oversized block reached the ring")
        XCTAssertEqual(ring.refusedSampleCount, 0, "nothing was refused by the ring; nothing was offered")
    }

    /// Zero frames is a no-op that reports success: the callback ran, there was nothing in it. It
    /// must not touch the ring, must not count as oversized, and must not return failure — a sink
    /// node has nobody to report to, and a refusal is already counted where the count can be read.
    func testZeroFramesIsANoOpReturningSuccess() {
        let ring = AudioRingBuffer(capacity: 64)
        let interleaver = AudioBufferListInterleaver(channelCount: 2, maximumFrameCount: 16, ring: ring)

        withList([(channels: 1, samples: [])]) { list in
            XCTAssertTrue(interleaver.interleave(from: list, frameCount: 0))
        }

        XCTAssertEqual(ring.availableToRead, 0)
        XCTAssertEqual(interleaver.oversizedSampleCount, 0)
        XCTAssertEqual(ring.refusedSampleCount, 0)
    }

    /// **The "declared format matches the samples" assertion the plan calls the one thing no test
    /// will catch.** The same source channels are interleaved at `channelCount` 1 and 2 and read
    /// back: at 2 the frames must alternate channels, so a channel-0-only interleaver — which
    /// declares 2 while writing one channel — lands `[1, 1, 2, 2, 3, 3]` against the expected
    /// `[1, 10, 2, 20, 3, 30]` and fails loudly, and at 1 the ring must hold channel 0 alone, which
    /// is the mean-of-one-number trap the plan names.
    func testTheDeclaredChannelCountMatchesTheSamplesAtOneAndTwoChannels() {
        let channel0: [Float] = [1, 2, 3]
        let channel1: [Float] = [10, 20, 30]

        let mono = AudioRingBuffer(capacity: 64)
        let monoInterleaver = AudioBufferListInterleaver(
            channelCount: 1, maximumFrameCount: 16, ring: mono)
        withList([
            (channels: 1, samples: channel0),
            (channels: 1, samples: channel1),
        ]) { list in
            XCTAssertTrue(monoInterleaver.interleave(from: list, frameCount: 3))
        }
        XCTAssertEqual(
            mono.availableToRead, 3,
            "at channelCount 1 the ring must hold exactly the frames, one sample each")
        XCTAssertEqual(
            mono.drain(), [1, 2, 3],
            "at channelCount 1 the ring must hold channel 0 alone — declaring mono over stereo "
                + "audio must select the first channel, and this is the assertion that knows it")

        let stereo = AudioRingBuffer(capacity: 64)
        let stereoInterleaver = AudioBufferListInterleaver(
            channelCount: 2, maximumFrameCount: 16, ring: stereo)
        withList([
            (channels: 1, samples: channel0),
            (channels: 1, samples: channel1),
        ]) { list in
            XCTAssertTrue(stereoInterleaver.interleave(from: list, frameCount: 3))
        }
        XCTAssertEqual(stereo.availableToRead, 6)
        XCTAssertEqual(
            stereo.drain(), [1, 10, 2, 20, 3, 30],
            "at channelCount 2 the frames must alternate channels; a channel-0-only interleaver "
                + "declares 2 and writes [1, 1, 2, 2, 3, 3] — the downmix would then average "
                + "channel 0 against itself")
    }

    /// The oversized path returns before touching the scratch, so the callback written after it
    /// must be exactly its own samples — no residue from the refused one.
    func testAnOversizedCallbackDoesNotCorruptSubsequentWrites() {
        let ring = AudioRingBuffer(capacity: 64)
        let interleaver = AudioBufferListInterleaver(channelCount: 2, maximumFrameCount: 4, ring: ring)

        withList([
            (channels: 1, samples: [1, 2, 3, 4, 5]),
            (channels: 1, samples: [6, 7, 8, 9, 10]),
        ]) { list in
            XCTAssertFalse(interleaver.interleave(from: list, frameCount: 5))
        }

        withList([
            (channels: 1, samples: [1, 2]),
            (channels: 1, samples: [3, 4]),
        ]) { list in
            XCTAssertTrue(interleaver.interleave(from: list, frameCount: 2))
        }

        XCTAssertEqual(
            ring.drain(), [1, 3, 2, 4],
            "a subsequent callback carried residue from the refused one — the oversized block was "
                + "partially written")
        XCTAssertEqual(interleaver.oversizedSampleCount, 10)
        XCTAssertEqual(ring.refusedSampleCount, 0)
    }

    /// The one exotic layout the interleaver's uniform-stride assumption does not cover — a mixed
    /// list — is bounded rather than undefined: a buffer whose channels would land beyond the
    /// declared `channelCount` is skipped whole, and nothing is written out of range. The
    /// interleaver's header names this case and says it is tested; this is the test.
    func testAChannelBeyondTheDeclaredCountIsClampedAndNothingIsWrittenOutOfRange() {
        let ring = AudioRingBuffer(capacity: 64)
        let interleaver = AudioBufferListInterleaver(channelCount: 2, maximumFrameCount: 16, ring: ring)

        withList([
            (channels: 2, samples: [1, 2, 3, 4]),  // channels 0 and 1 — inside the declared count
            (channels: 2, samples: [9, 9, 9, 9]),  // channels 2 and 3 — beyond it, must not land
        ]) { list in
            XCTAssertTrue(interleaver.interleave(from: list, frameCount: 2))
        }

        XCTAssertEqual(
            ring.drain(), [1, 2, 3, 4],
            "a channel beyond the declared count was written, or one inside it was lost")
    }

    // MARK: - Building an AudioBufferList

    /// Runs `body` with a hand-built `AudioBufferList`: `mNumberBuffers` buffers, each carrying the
    /// given channel count and sample run — or a null `mData` for `samples: nil`. The sample
    /// storage lives for the duration of the call and is freed on exit.
    private func withList<T>(
        _ buffers: [(channels: Int, samples: [Float]?)],
        _ body: (UnsafePointer<AudioBufferList>) throws -> T
    ) rethrows -> T {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        var storage: [UnsafeMutableRawPointer] = []
        for (index, buffer) in buffers.enumerated() {
            list[index].mNumberChannels = UInt32(buffer.channels)
            if let samples = buffer.samples {
                let memory = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
                memory.initialize(from: samples, count: samples.count)
                storage.append(UnsafeMutableRawPointer(memory))
                list[index].mData = storage.last
                list[index].mDataByteSize = UInt32(samples.count * MemoryLayout<Float>.size)
            } else {
                list[index].mData = nil
                list[index].mDataByteSize = 0
            }
        }
        defer {
            for memory in storage { memory.deallocate() }
        }
        return try body(UnsafePointer(list.unsafeMutablePointer))
    }
}
