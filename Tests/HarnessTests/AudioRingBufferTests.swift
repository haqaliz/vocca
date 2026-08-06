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

import Dispatch
import Foundation
import XCTest

@testable import VoccaAudio

/// Acceptance A1: the SPSC ring buffer's correctness, wraparound, overrun policy and capacity
/// bounds.
///
/// **The two concurrency tests below use two real threads**, not an interleaving a test drove by
/// hand. A simulated interleaving asks the hardware to reorder nothing, so it says nothing about
/// the discipline that makes `AudioRingBuffer`'s `@unchecked Sendable` sound.
///
/// `Scripts/test-under-tsan.sh` runs this file under ThreadSanitizer. **Read that script's header
/// before treating a green run as proof of the memory orderings — it is not, and the limit was
/// measured rather than assumed.** Weakening the producer's `.releasing` store to `.relaxed` leaves
/// TSan completely silent, because LLVM's ThreadSanitizer detects *missing* synchronisation and not
/// *insufficient* synchronisation. What the value assertions below catch and TSan does not, and
/// what TSan catches and they do not, are different failures; neither subsumes the other, and the
/// case for the orderings themselves is the argument written at the top of `AudioRingBuffer.swift`.
final class AudioRingBufferTests: XCTestCase {

    // MARK: - Capacity boundaries

    func testAnEmptyRingHasNothingToReadAndDrainsToNothing() {
        let ring = AudioRingBuffer(capacity: 8)

        XCTAssertEqual(ring.availableToRead, 0)
        XCTAssertEqual(ring.drain(), [])
        XCTAssertEqual(ring.refusedSampleCount, 0)

        var destination = [Float](repeating: .nan, count: 8)
        let taken = destination.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: 8)
        }
        XCTAssertEqual(taken, 0)
        XCTAssertTrue(
            destination.allSatisfy(\.isNaN),
            "read(into:) wrote into a destination it had nothing to fill")
    }

    func testASingleSampleRoundTrips() {
        let ring = AudioRingBuffer(capacity: 8)

        XCTAssertTrue(ring.write([0.25], count: 1))
        XCTAssertEqual(ring.availableToRead, 1)
        XCTAssertEqual(ring.drain(), [0.25])
        XCTAssertEqual(ring.availableToRead, 0, "a drained ring must be empty, not merely readable")
    }

    /// The capacity rule, as a pure function, because the `precondition` that enforces it cannot be
    /// caught in-process and so was satisfiable by any predicate at all: neutering either half of it
    /// left the whole suite green.
    func testOnlyAPositivePowerOfTwoIsALegalCapacity() {
        for legal in [1, 2, 4, 8, 64, 1024, 1 << 20] {
            XCTAssertTrue(
                AudioRingBuffer.isValidCapacity(legal), "\(legal) is a power of two and was refused")
        }
        for illegal in [0, 3, 5, 6, 7, 9, 63, 100, 1000, (1 << 20) + 1] {
            XCTAssertFalse(
                AudioRingBuffer.isValidCapacity(illegal),
                """
                \(illegal) was accepted as a capacity. The cursors are masked with `capacity - 1`, \
                so a non-power-of-two silently folds the ring onto itself and corrupts every sample \
                rather than crashing.
                """)
        }
        for negative in [-1, -8, Int.min] {
            XCTAssertFalse(
                AudioRingBuffer.isValidCapacity(negative),
                """
                \(negative) was accepted as a capacity. Int.min matters on its own: it satisfies \
                `capacity & (capacity - 1) == 0`, so the power-of-two half of the rule passes it and \
                only the positivity half rejects it.
                """)
        }
    }

    /// **The producer's arithmetic must not trap, including in the state the API cannot produce.**
    ///
    /// `Int(write &- read)` was the original form and it is a trapping conversion on the realtime
    /// thread. Reverting to it is invisible to every other test in this file — measured: the whole
    /// suite stays green — because the trap only fires once the SPSC discipline is already violated
    /// and the cursors have inverted. That is precisely the discipline `@unchecked Sendable` leaves
    /// unenforced, so "unreachable through the API" is not the same as "unreachable". The function
    /// exists to be callable in that state; this is the test that calls it there.
    func testTheProducersRoomArithmeticRefusesRatherThanTrappingOnInvertedCursors() {
        // Normal states first, so the function is known to compute the right answer at all.
        XCTAssertEqual(AudioRingBuffer.room(capacity: 8, write: 0, read: 0), 8, "an empty ring")
        XCTAssertEqual(AudioRingBuffer.room(capacity: 8, write: 3, read: 0), 5)
        XCTAssertEqual(AudioRingBuffer.room(capacity: 8, write: 8, read: 0), 0, "a full ring")
        XCTAssertEqual(AudioRingBuffer.room(capacity: 8, write: 8, read: 8), 8, "drained again")

        // Cursors that have wrapped past UInt64.max. Ordinary arithmetic, not an edge case, because
        // the cursors are monotonic and `&-` is exact across the wrap.
        XCTAssertEqual(
            AudioRingBuffer.room(capacity: 8, write: 2, read: UInt64.max - 2), 3,
            "the occupancy across a cursor wrap is (write &- read), which is 5 here")

        // And the states the API cannot produce. Every one of these would trap under `Int(_:)`.
        for (write, read) in [(0 as UInt64, 1 as UInt64), (5, 9), (0, UInt64.max / 2), (7, 4096)] {
            XCTAssertEqual(
                AudioRingBuffer.room(capacity: 8, write: write, read: read), 0,
                """
                room(write: \(write), read: \(read)) must be zero, so the producer refuses. With \
                inverted cursors `write &- read` is enormous; `Int(_:)` of it is a `Fatal error: Not \
                enough bits to represent the passed value` inside a CoreAudio callback, which is a \
                dead microphone in the middle of a sentence rather than a crash report.
                """)
        }
    }

    /// A one-slot ring. The smallest legal capacity, and the one where "full" and "empty" are one
    /// sample apart — the case a cursor scheme that sacrifices a slot cannot represent at all.
    func testARingOfOneHoldsExactlyOneSample() {
        let ring = AudioRingBuffer(capacity: 1)

        XCTAssertTrue(ring.write([1.5], count: 1))
        XCTAssertEqual(ring.availableToRead, 1)
        XCTAssertFalse(ring.write([2.5], count: 1), "a full ring of one accepted a second sample")
        XCTAssertEqual(ring.drain(), [1.5])
        XCTAssertTrue(ring.write([2.5], count: 1), "the slot was not released by the read")
        XCTAssertEqual(ring.drain(), [2.5])
    }

    /// Exactly full, then one past full.
    func testTheRingFillsToExactlyCapacityAndThenRefusesOneMoreSample() {
        let ring = AudioRingBuffer(capacity: 8)
        let full = (0..<8).map(Float.init)

        XCTAssertTrue(ring.write(full, count: 8), "a ring of 8 refused 8 samples into an empty ring")
        XCTAssertEqual(ring.availableToRead, 8)
        XCTAssertEqual(ring.refusedSampleCount, 0, "an accepted write must not be counted as dropped")

        XCTAssertFalse(ring.write([99], count: 1), "a full ring accepted a ninth sample")
        XCTAssertEqual(ring.refusedSampleCount, 1)
        XCTAssertEqual(ring.availableToRead, 8, "the refused sample changed the occupancy")
        XCTAssertEqual(ring.drain(), full, "the refused sample overwrote data already in the ring")
    }

    /// One past full, presented as a single block to an *empty* ring: it can never fit, and the
    /// distinction that matters is that nothing at all is written.
    func testABlockLargerThanTheWholeRingIsRefusedWhole() {
        let ring = AudioRingBuffer(capacity: 8)
        let tooMany = (0..<9).map(Float.init)

        XCTAssertFalse(ring.write(tooMany, count: 9))
        XCTAssertEqual(ring.refusedSampleCount, 9, "the whole block is the loss, not the overflowing tail of it")
        XCTAssertEqual(ring.availableToRead, 0, "a refused write left samples in the ring")
        XCTAssertEqual(ring.drain(), [])
    }

    func testAZeroLengthWriteSucceedsAndChangesNothing() {
        let ring = AudioRingBuffer(capacity: 8)
        let sample: [Float] = [7]

        XCTAssertTrue(ring.write(sample, count: 0), "an empty block is not a failure — it is nothing to do")
        XCTAssertEqual(ring.availableToRead, 0)
        XCTAssertEqual(ring.refusedSampleCount, 0, "an empty block was counted as lost audio")
    }

    /// A negative count is a caller bug that must not trap: this runs on the realtime thread, where
    /// a trap costs the user the whole session and the wrong answer costs them one callback.
    func testANegativeCountIsRefusedWithoutTouchingTheRing() {
        let ring = AudioRingBuffer(capacity: 8)
        let sample: [Float] = [7]

        XCTAssertFalse(ring.write(sample, count: -1))
        XCTAssertEqual(ring.availableToRead, 0)
        XCTAssertEqual(ring.refusedSampleCount, 0, "a nonsense count was counted as lost audio, which it is not")
    }

    // MARK: - Wraparound

    /// The straddling write: a block that begins near the end of storage and finishes at the
    /// beginning of it. Written as two runs by ``AudioRingBuffer/write(_:count:)``, and the order it
    /// reassembles into is the whole point.
    func testAWriteThatStraddlesTheEndOfStorageIsReassembledInOrder() {
        let ring = AudioRingBuffer(capacity: 8)

        // Advance the write cursor to offset 6 and clear the ring, so the next block must split.
        XCTAssertTrue(ring.write((0..<6).map(Float.init), count: 6))
        XCTAssertEqual(ring.drain().count, 6)

        let straddling: [Float] = [10, 11, 12, 13, 14]  // 2 samples at offsets 6-7, 3 at 0-2
        XCTAssertTrue(ring.write(straddling, count: 5))
        XCTAssertEqual(ring.availableToRead, 5)
        XCTAssertEqual(
            ring.drain(), straddling,
            "a block split across the end of storage came back out of order or incomplete")
    }

    /// The mirror image: the *read* straddles the end, because the write did not.
    func testAReadThatStraddlesTheEndOfStorageIsReassembledInOrder() {
        let ring = AudioRingBuffer(capacity: 8)

        XCTAssertTrue(ring.write((0..<5).map(Float.init), count: 5))
        XCTAssertEqual(ring.drain().count, 5)

        // Cursor at 5. Two writes that do not individually split, spanning a read that does.
        XCTAssertTrue(ring.write([20, 21, 22], count: 3))  // offsets 5, 6, 7
        XCTAssertTrue(ring.write([23, 24], count: 2))  // offsets 0, 1
        XCTAssertEqual(ring.drain(), [20, 21, 22, 23, 24])
    }

    /// Many laps of the storage, so that a cursor that is masked in the wrong place, rewound, or
    /// compared as a raw offset has somewhere to show it. Twenty-nine is deliberately coprime with
    /// the capacity, so every offset in storage is used as a block boundary.
    func testWraparoundHoldsOverManyLapsOfTheStorage() {
        let ring = AudioRingBuffer(capacity: 64)
        var next: Float = 0
        var expected: Float = 0

        for _ in 0..<500 {
            let block = (0..<29).map { Float(next) + Float($0) }
            XCTAssertTrue(ring.write(block, count: 29), "a ring drained every lap reported itself full")
            next += 29

            let read = ring.drain()
            XCTAssertEqual(read.count, 29)
            for value in read {
                XCTAssertEqual(value, expected, "samples came back out of order after wrapping")
                expected += 1
            }
        }
        XCTAssertEqual(expected, Float(500 * 29))
        XCTAssertEqual(ring.refusedSampleCount, 0)
    }

    // MARK: - The overrun policy: drop the newest block, whole, and count it

    /// The policy, stated as an assertion rather than as a doc comment: **the oldest audio survives
    /// and the newest block is the one lost.** For a dictation session the beginning of the
    /// utterance is the part the user is surest they said, and it is also the part already handed to
    /// the ASR by the time an overrun could occur.
    func testAnOverrunDropsTheNewestBlockWholeAndKeepsTheOldestAudio() {
        let ring = AudioRingBuffer(capacity: 8)
        let oldest: [Float] = [1, 2, 3, 4, 5, 6]

        XCTAssertTrue(ring.write(oldest, count: 6))
        XCTAssertFalse(ring.write([7, 8, 9], count: 3), "a block needing 3 slots fitted into 2")

        XCTAssertEqual(ring.refusedSampleCount, 3, "the refusal must count every sample in the block")
        XCTAssertEqual(
            ring.drain(), oldest,
            """
            The overrun policy is drop-newest. The ring must contain exactly the audio that was \
            already in it — no prefix of the refused block, and nothing evicted from the front.
            """)
    }

    /// Partial acceptance is the failure this policy exists to prevent: it would splice a
    /// discontinuity into a stream the consumer reads as contiguous, and the ASR would transcribe
    /// it confidently and wrongly.
    func testAnOverrunNeverWritesAPrefixOfTheRefusedBlock() {
        let ring = AudioRingBuffer(capacity: 8)

        XCTAssertTrue(ring.write([1, 2, 3, 4, 5, 6, 7], count: 7))
        XCTAssertFalse(ring.write([100, 200], count: 2), "one free slot accepted a two-sample block")

        let drained = ring.drain()
        XCTAssertEqual(drained.count, 7, "a prefix of the refused block was written after all")
        XCTAssertFalse(drained.contains(100), "the refused block's first sample reached the ring")
    }

    func testDroppedSamplesAccumulateAcrossSeparateRefusals() {
        let ring = AudioRingBuffer(capacity: 4)

        XCTAssertTrue(ring.write([1, 2, 3, 4], count: 4))
        XCTAssertFalse(ring.write([5], count: 1))
        XCTAssertFalse(ring.write([6, 7], count: 2))
        XCTAssertEqual(ring.refusedSampleCount, 3, "the counter is a total, not the last refusal")

        // And it is not reset by draining: the audio is still missing after the ring empties.
        XCTAssertEqual(ring.drain().count, 4)
        XCTAssertEqual(
            ring.refusedSampleCount, 3,
            "draining cleared the loss record, so a consumer would hand over short audio as complete")
    }

    /// The counter counts **refusals**, and a refusal the caller then makes good is still counted.
    ///
    /// This looks like over-counting and is the deliberate reading. The realtime producer calls
    /// `write` once per callback and cannot retry — spinning is the one thing the audio thread must
    /// never do — so on the shipped path a refusal *is* lost audio and the two numbers are the same.
    /// A retrying caller (only a test) inflates it, which errs towards claiming loss that did not
    /// happen. That direction is safe; the opposite one would let a consumer read zero and hand over
    /// short audio as complete.
    func testARetriedRefusalIsStillCounted() {
        let ring = AudioRingBuffer(capacity: 4)

        XCTAssertTrue(ring.write([1, 2, 3, 4], count: 4))
        XCTAssertFalse(ring.write([5, 6], count: 2))
        XCTAssertEqual(ring.drain(), [1, 2, 3, 4])
        XCTAssertTrue(ring.write([5, 6], count: 2), "the retry itself failed, so this proves nothing")

        XCTAssertEqual(ring.drain(), [5, 6], "no sample was lost — the retry made the refusal good")
        XCTAssertEqual(
            ring.refusedSampleCount, 2,
            """
            The refusal must remain on the record after a successful retry. It counts what the ring \
            would not take, which is the number the shipped producer — one call per callback, no \
            retry — needs to mean "this much audio no longer exists".
            """)
    }

    /// Space is reclaimed by the *read*, not by time passing. This is the producer's acquiring load
    /// of `readIndex` doing its job at the API level.
    func testSpaceIsReclaimedOnlyByReading() {
        let ring = AudioRingBuffer(capacity: 4)

        XCTAssertTrue(ring.write([1, 2, 3, 4], count: 4))
        XCTAssertFalse(ring.write([5], count: 1))

        var destination = [Float](repeating: 0, count: 2)
        let taken = destination.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: 2)
        }
        XCTAssertEqual(taken, 2)
        XCTAssertEqual(destination, [1, 2])

        XCTAssertTrue(ring.write([5, 6], count: 2), "two slots were freed and the producer did not see them")
        XCTAssertEqual(ring.drain(), [3, 4, 5, 6])
    }

    // MARK: - `read` and `drain`

    func testReadIntoASmallerDestinationTakesThePrefixAndLeavesTheRest() {
        let ring = AudioRingBuffer(capacity: 8)
        XCTAssertTrue(ring.write([1, 2, 3, 4, 5], count: 5))

        var destination = [Float](repeating: 0, count: 3)
        let taken = destination.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: 3)
        }

        XCTAssertEqual(taken, 3)
        XCTAssertEqual(destination, [1, 2, 3])
        XCTAssertEqual(ring.drain(), [4, 5], "the unread tail was consumed or reordered")
    }

    func testReadingMoreThanIsAvailableTakesOnlyWhatIsThere() {
        let ring = AudioRingBuffer(capacity: 8)
        XCTAssertTrue(ring.write([1, 2], count: 2))

        var destination = [Float](repeating: .nan, count: 8)
        let taken = destination.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: 8)
        }

        XCTAssertEqual(taken, 2)
        XCTAssertEqual(Array(destination.prefix(2)), [1, 2])
        XCTAssertTrue(
            destination.dropFirst(2).allSatisfy(\.isNaN),
            "read(into:) wrote past the samples it actually had")

        // The cursor must have advanced by what was *taken*, not by what was asked for. Advancing by
        // the request drives the read cursor past the write cursor, and `write &- read` then
        // underflows to an occupancy of about eighteen quintillion samples — after which the ring
        // reports itself permanently full, the producer refuses every block, and the session records
        // silence. A mutation battery found this held by nothing: the return value alone is
        // identical either way, and `drain()` never asks for more than it knows is there.
        XCTAssertEqual(
            ring.availableToRead, 0,
            "reading more than was available advanced the read cursor past the write cursor")
        XCTAssertEqual(ring.drain(), [])
        XCTAssertTrue(ring.write([3], count: 1), "the ring refused a sample after an over-long read")
        XCTAssertEqual(ring.drain(), [3])
    }

    /// The same defect at the boundary that matters most: an over-long read of an **empty** ring.
    /// Here the underflow is not merely wrong, it is unbounded — nothing was taken at all.
    func testAnOverLongReadOfAnEmptyRingLeavesTheCursorsWhereTheyWere() {
        let ring = AudioRingBuffer(capacity: 8)

        var destination = [Float](repeating: 0, count: 64)
        let taken = destination.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: 64)
        }

        XCTAssertEqual(taken, 0)
        XCTAssertEqual(ring.availableToRead, 0)
        XCTAssertTrue(ring.write([1, 2, 3], count: 3), "the ring believed itself full after reading nothing")
        XCTAssertEqual(ring.drain(), [1, 2, 3])
    }

    // MARK: - Two real threads

    /// **A1: SPSC correctness under real concurrency.** One producer thread, one consumer (this
    /// one), thousands of blocks of varying size, and not one sample lost, duplicated or reordered.
    ///
    /// The producer retries rather than giving up, so the accounting is exact: every sample sent
    /// must arrive, exactly once, in order. Block sizes come from a seeded generator so that block
    /// boundaries land on every offset in storage — a fixed block size that divides the capacity
    /// never exercises a straddling write at all.
    ///
    /// It deliberately does **not** assert that ``AudioRingBuffer/refusedSampleCount`` is zero. A
    /// retrying producer collects refusals it then makes good, and that counter counts refusals; see
    /// ``testARetriedRefusalIsStillCounted`` for why that is the honest reading and the shipped
    /// producer's number.
    func testASingleProducerAndSingleConsumerNeverLoseReorderOrDuplicateASample() {
        let ring = AudioRingBuffer(capacity: 256)
        let blockCount = 4_000
        let maximumBlock = 96

        var generator = SeededGenerator(seed: 0xA11D_10_5E_ED)
        var blocks: [[Float]] = []
        blocks.reserveCapacity(blockCount)
        var next: Float = 0
        for _ in 0..<blockCount {
            let size = Int.random(in: 1...maximumBlock, using: &generator)
            blocks.append((0..<size).map { Float(next) + Float($0) })
            next += Float(size)
        }
        let totalSamples = Int(next)
        XCTAssertLessThan(
            totalSamples, 1 << 24,
            "the sample values must stay exactly representable as Float, or a mismatch means nothing")

        let finished = DispatchSemaphore(value: 0)
        let deadline = Date().addingTimeInterval(120)

        Thread.detachNewThread { [blocks] in
            for block in blocks {
                // `abandoned` rather than a `return` inside the closure: a `return` there leaves
                // only `withUnsafeBufferPointer`, so a deadline breach would skip one block and go
                // on to re-breach on each of the remaining 3 999. The run still failed loudly, but
                // not for the reason a reader would assume.
                var abandoned = false
                block.withUnsafeBufferPointer { buffer in
                    // Spin rather than drop: this test is about the ordering, and a drop would make
                    // a lost sample indistinguishable from a legitimate refusal.
                    while !ring.write(buffer.baseAddress!, count: buffer.count) {
                        if Date() > deadline {
                            abandoned = true
                            return
                        }
                        sched_yield()
                    }
                }
                if abandoned { break }
            }
            finished.signal()
        }

        var received: [Float] = []
        received.reserveCapacity(totalSamples)
        while received.count < totalSamples {
            let chunk = ring.drain()
            if chunk.isEmpty {
                if Date() > deadline {
                    XCTFail(
                        "the consumer received \(received.count) of \(totalSamples) samples before the deadline")
                    break
                }
                sched_yield()
                continue
            }
            received.append(contentsOf: chunk)
        }

        XCTAssertEqual(
            finished.wait(timeout: .now() + 30), .success,
            "the producer thread did not finish, so the counts below describe a partial run")

        XCTAssertEqual(received.count, totalSamples, "samples were lost or duplicated")
        XCTAssertEqual(ring.availableToRead, 0, "the ring was not fully drained")

        var expected: Float = 0
        for (offset, value) in received.enumerated() {
            guard value == expected else {
                XCTFail("sample \(offset) was \(value), expected \(expected) — the stream reordered")
                return
            }
            expected += 1
        }
    }

    /// The same two threads with the producer refusing to wait, so that overruns happen **under
    /// real contention** rather than being staged by a single-threaded test.
    ///
    /// ## This test previously did not do what it says, and the fix is the shape of it
    ///
    /// The first version had the consumer wait on `finished.wait(timeout: .now() + 0.001)` between
    /// drains. The producer ran to completion inside that first millisecond: measured, the consumer
    /// received **48 of 96 000 samples — 0.05 %** — so the accounting assertion was satisfied almost
    /// entirely by the refusal counter, the strictly-increasing check ran over two blocks out of
    /// four thousand, and the vacuity guard (`received.count > 0`) was calibrated three orders of
    /// magnitude below what the doc comment claimed. It was a single-threaded producer with a drain
    /// bolted on the end, named for a property it did not exercise — the exact shape this project
    /// keeps finding.
    ///
    /// So now: the consumer drains in a tight loop with no wait at all, and the producer yields
    /// between blocks so both threads are live at once. And the claim is asserted in **both**
    /// directions, because each half is satisfiable while the other fails —
    ///
    /// - a real fraction of the audio must actually reach the consumer, or the test is measuring a
    ///   lone producer counting its own refusals, which
    ///   ``testDroppedSamplesAccumulateAcrossSeparateRefusals`` already covers single-threaded;
    /// - ``AudioRingBuffer/refusedSampleCount`` must be non-zero, or no overrun happened and the
    ///   test named for the overrun policy never reached it.
    func testUnderContentionEveryProducedSampleIsEitherReceivedOrCounted() {
        let ring = AudioRingBuffer(capacity: 64)
        let blockCount = 4_000
        let blockSize = 24

        var next: Float = 0
        var blocks: [[Float]] = []
        blocks.reserveCapacity(blockCount)
        for _ in 0..<blockCount {
            blocks.append((0..<blockSize).map { Float(next) + Float($0) })
            next += Float(blockSize)
        }
        let totalSent = blockCount * blockSize

        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [blocks] in
            for block in blocks {
                block.withUnsafeBufferPointer { buffer in
                    // No retry. A refusal here is the overrun policy firing for real.
                    _ = ring.write(buffer.baseAddress!, count: buffer.count)
                }
                // Pace the producer so the consumer is scheduled *during* the run rather than
                // after it. Without this the producer finishes before the consumer starts and the
                // whole test degenerates into the single-threaded case.
                sched_yield()
            }
            finished.signal()
        }

        // Drain in a tight loop, with no wait, until the producer has signalled — then drain the
        // tail. `wait(timeout: .now())` polls the semaphore without blocking.
        var received: [Float] = []
        received.reserveCapacity(totalSent)
        while finished.wait(timeout: .now()) != .success {
            received.append(contentsOf: ring.drain())
        }
        received.append(contentsOf: ring.drain())

        // The two directions of "this test contended". Both are deliberately generous — the point
        // is to exclude 0.05 %, not to pin a scheduler.
        XCTAssertGreaterThan(
            received.count, totalSent / 20,
            """
            The consumer received \(received.count) of \(totalSent) samples. Below a few per cent \
            this is not a contention test: the producer ran to completion before the consumer was \
            scheduled, and everything below is really a single-threaded producer counting its own \
            refusals.
            """)
        XCTAssertGreaterThan(
            ring.refusedSampleCount, 0,
            """
            No overrun occurred, so the test named for the overrun policy never exercised it. A ring \
            of \(ring.capacity) against \(blockCount) blocks of \(blockSize) must overrun; if it did \
            not, the consumer is somehow keeping up and the accounting assertion below proves \
            nothing it does not already prove single-threaded.
            """)

        XCTAssertEqual(
            received.count + ring.refusedSampleCount, totalSent,
            """
            \(received.count) received + \(ring.refusedSampleCount) refused != \(totalSent) sent. \
            Every sample is either stored or refused, and the refusal counter is the only thing \
            that tells a consumer the audio it holds is short.
            """)

        var previous: Float = -1
        for value in received {
            guard value > previous else {
                XCTFail("received \(value) after \(previous) — a drop reordered or duplicated the stream")
                return
            }
            previous = value
        }
    }

    // MARK: - The source, where the runtime cannot look

    /// `deinit` must free the ring's storage, and nothing at runtime pins that it does.
    ///
    /// Deleting `storage.deallocate()` leaves all of the tests above green — a review's mutation
    /// battery measured exactly that. At the capacities under discussion for this type (~23 MB for
    /// 120 s at 48 kHz) a ring leaked per session is not a rounding error. An RSS-watching test is
    /// fragile and an allocation counter is shipping code that exists only for a test, so this pins
    /// the source instead: the `deinit` is one line, and this asserts it is that line.
    func testTheRingBuffersDeinitFreesItsStorage() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let file = root.appendingPathComponent("Sources/VoccaAudio/AudioRingBuffer.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        let bodies = DeinitIsolationTests.deinitBodies(inSource: source)
        XCTAssertEqual(
            bodies.count, 1, "AudioRingBuffer.swift no longer has exactly one deinit to check")
        XCTAssertTrue(
            SwiftSourceScanner.callNames(inBody: bodies[0]).contains("deallocate"),
            """
            AudioRingBuffer.deinit does not call deallocate(). It owns a raw allocation of \
            `capacity` Floats — the only one in the package — and it is the only thing that frees \
            it. DeinitIsolationTests checks that this deinit reaches nothing that asserts its \
            isolation; it does not check that the deinit does the one thing it exists to do.
            """)
    }
}
