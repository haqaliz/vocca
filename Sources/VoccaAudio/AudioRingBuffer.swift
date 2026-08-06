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

import Synchronization

/// A single-producer / single-consumer lock-free ring of `Float` samples, preallocated once.
///
/// CoreAudio's realtime thread writes; a polling consumer drains. ``write(_:count:)`` is the only
/// member that runs on the realtime thread, and it allocates nothing, takes no lock, logs nothing,
/// touches no reference count and cannot throw — see ``write(_:count:)`` and the lint in
/// `RealtimeSafetyTests`, which asserts that by reading this file rather than by trusting this
/// paragraph.
///
/// ## Why the consumer polls instead of being signalled
///
/// Every mechanism available for waking a consumer is forbidden on the producer side: `Task`,
/// `DispatchQueue.async`, `AsyncStream.yield` and `DispatchSemaphore.signal` all allocate, take a
/// lock, or both. So nothing here signals. The consumer reads on a timer, and at a ~10 ms poll
/// against a 100 ms-scale pipeline the latency it costs is not measurable against anything the user
/// can perceive.
///
/// ## Capacity is a power of two, and that is load-bearing
///
/// The two cursors are **monotonic** 64-bit counters that are masked only when they index storage.
/// That is what makes "empty" and "full" distinguishable without sacrificing a slot: `write &- read`
/// is the exact occupancy, `0` when empty and `capacity` when full, and neither cursor is ever
/// rewound. The mask requires a power-of-two capacity, which ``init(capacity:)`` enforces — on the
/// caller's thread, at construction, where a trap is a programming error caught in a test rather
/// than a crash in the middle of a sentence.
///
/// At 48 kHz the counters wrap after roughly twelve million years of continuous capture, so the
/// `&-` and `&+` below are exact arithmetic in every reachable state, not a wrapping approximation.
public final class AudioRingBuffer: @unchecked Sendable {

    // MARK: - The invariant the compiler cannot verify
    //
    // THIS IS THE ONLY `@unchecked Sendable` IN THE CODEBASE. Everything else is checked. What the
    // annotation claims, precisely:
    //
    // 1. SPSC DISCIPLINE. At most one thread calls the producer API (`write`) and at most one
    //    thread calls the consumer API (`read`, `drain`, `availableToRead`, `refusedSampleCount`),
    //    and they are different roles. Either role may *move* between threads over the buffer's
    //    life — the audio device restarts, the drain task hops executors — but only with a
    //    happens-before edge between the outgoing and incoming occupant, which every mechanism
    //    that hands work between threads already provides. Two concurrent producers, or two
    //    concurrent consumers, break this type. There is no CAS anywhere here that would make them
    //    safe, and adding one is not a small change.
    //
    // 2. SINGLE WRITER PER CURSOR. `writeIndex` is written only by the producer and read by both.
    //    `readIndex` is written only by the consumer and read by both. No cursor has two writers,
    //    which is exactly why a plain load/store pair suffices and no read-modify-write is needed
    //    on the realtime thread. It is also why the overrun policy is drop-newest and not
    //    drop-oldest: dropping the oldest sample means the *producer* advancing `readIndex`, which
    //    gives that cursor two writers and forces a compare-exchange loop onto the realtime thread.
    //
    // 3. THE ORDERING PAIRS. `storage` is ordinary, non-atomic memory, and both roles touch it.
    //    What keeps that from being a data race is that every access to it is ordered behind an
    //    acquire/release pair on the cursors:
    //
    //      - The producer copies samples into `storage`, then stores `writeIndex` with
    //        `.releasing`. The consumer loads `writeIndex` with `.acquiring` before reading those
    //        slots. That release/acquire pair is what makes the sample writes visible; without it
    //        the consumer may observe an advanced cursor over stale bytes.
    //
    //      - The consumer copies samples out of `storage`, then stores `readIndex` with
    //        `.releasing`. The producer loads `readIndex` with `.acquiring` before deciding how
    //        much room it has. That pair is what stops the producer overwriting slots the consumer
    //        has not finished copying out of.
    //
    //    Each role loads *its own* cursor `.relaxed`, because it is the only writer of it, so
    //    there is no other value it could observe.
    //
    //    None of this is x86 folklore. On arm64 `.acquiring` and `.releasing` lower to `ldar` and
    //    `stlr`; the same code with both relaxed compiles and passes on x86, where the hardware
    //    supplies the ordering for free, and reorders on Apple silicon. The orderings are the
    //    correctness argument, not decoration on it.
    //
    //    AND NOTHING AUTOMATED CHECKS THEM. Measured, not assumed: weakening the `.releasing` store
    //    below to `.relaxed` leaves both the suite and the ThreadSanitizer run completely clean —
    //    LLVM's TSan detects *missing* synchronisation, not *insufficient* synchronisation. So the
    //    four orderings in this file are held up by this comment and by whoever reads it. Change one
    //    only with the paragraph above in front of you.
    //
    // 4. THE LIFETIME. `storage` is allocated once in `init` and freed once in `deinit`, and its
    //    address never changes. Nothing here reallocates, so no pointer the producer holds can be
    //    invalidated underneath it.
    //
    // What makes the annotation sound is (3) given (1) and (2): under that discipline no two
    // threads ever touch the same element of `storage` without an intervening release/acquire
    // edge, which is the definition of race-free. Swift cannot express "one producer, one
    // consumer" in the type system, so it cannot check it — hence `@unchecked`, and hence this
    // comment being the thing a reviewer has to agree with.

    /// The number of samples the ring holds. A power of two.
    public let capacity: Int

    /// The preallocated sample storage. A raw allocation and not an `Array`, so that the producer
    /// touches no Swift object and no reference count on the realtime thread.
    private let storage: UnsafeMutablePointer<Float>

    /// `capacity - 1`. Turns a monotonic cursor into a storage offset with one `&`.
    private let mask: UInt64

    /// Total samples ever written. Producer writes, both read. Never rewound.
    private let writeIndex = Atomic<UInt64>(0)

    /// Total samples ever read. Consumer writes, both read. Never rewound.
    private let readIndex = Atomic<UInt64>(0)

    /// Total samples refused because the ring was too full to take them whole.
    ///
    /// Producer-only, and `.relaxed` in both directions on purpose: no other data hangs off this
    /// value, so there is nothing for an acquire/release pair to publish. It answers one question —
    /// *how much audio did the producer offer that this ring would not take* — and it is asked after
    /// the producer has stopped, where the engine teardown already supplies the ordering edge.
    private let refusedSamples = Atomic<UInt64>(0)

    /// - Parameter capacity: samples the ring holds. Must be a power of two greater than zero.
    ///
    /// Traps on a bad capacity. That is deliberate and it is safe *here*: `init` runs on whatever
    /// thread builds the capture graph, long before the engine starts, so the trap is a programming
    /// error a test catches rather than a crash on the audio thread.
    public init(capacity: Int) {
        precondition(capacity > 0, "AudioRingBuffer capacity must be positive, got \(capacity)")
        precondition(
            capacity & (capacity - 1) == 0,
            """
            AudioRingBuffer capacity must be a power of two, got \(capacity). The cursors are \
            monotonic and masked, which is what lets a full ring be told apart from an empty one \
            without wasting a slot; the mask requires a power of two.
            """)

        self.capacity = capacity
        self.mask = UInt64(capacity - 1)
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        self.storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        // No `deinitialize` call: `Float` is trivial, so there is nothing to tear down, and
        // `deallocate()` is `free(3)` — it asserts no isolation domain, which is what a `deinit`
        // requires (see `DeinitIsolationTests`; a `deinit` runs wherever the last release happens).
        storage.deallocate()
    }

    // MARK: - Producer (the realtime thread)

    /// Append `count` samples read from `samples`. **This is the realtime path.**
    ///
    /// Returns `true` when every sample was stored and `false` when the write was refused whole.
    ///
    /// ## The overrun policy: refuse the newest block, whole, and count it
    ///
    /// When the ring has less room than the block needs, **nothing is written**, the block's
    /// samples are added to ``refusedSampleCount``, and `false` comes back. Three alternatives were
    /// available and each is worse for this product:
    ///
    /// - *Drop the oldest* means the producer advances `readIndex`, which gives that cursor two
    ///   writers and forces a compare-exchange loop onto the realtime thread. It also throws away
    ///   the **beginning** of the utterance, which is the part the user is most sure they said.
    ///
    /// - *Write what fits* splices a discontinuity into the middle of a stream that the consumer
    ///   has no way to see. The ASR would receive a waveform that is contiguous in memory and skips
    ///   time, and would transcribe it confidently and wrongly. Vocca's invariant is that a
    ///   transcript is never lost; a transcript that is quietly wrong is a worse failure than one
    ///   that is visibly short.
    ///
    /// - *Trap* kills the app mid-sentence and loses the entire session, which is precisely the
    ///   loss the invariant forbids.
    ///
    /// So the loss is aligned to a whole callback block, and it is **countable**: a consumer that
    /// finds ``refusedSampleCount`` non-zero knows exactly how many samples of audio the ring would
    /// not take, and can refuse to present the result as complete. "Cannot happen" is not available
    /// as an answer, even though at the shipped capacity an overrun means the consumer stalled for
    /// longer than the entire session ceiling.
    ///
    /// A negative `count` is a caller bug. It returns `false` and stores nothing, rather than
    /// trapping, because the realtime thread is the one place in Vocca where a trap is worse than a
    /// wrong answer.
    ///
    // @realtime — RealtimeSafetyTests lints the body below. Moving or deleting this marker changes
    // what is linted, and the lint asserts the exact set of markers it found.
    @discardableResult
    public func write(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return count == 0 }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let room = capacity - Int(write &- read)

        guard count <= room else {
            refusedSamples.wrappingAdd(UInt64(count), ordering: .relaxed)
            return false
        }

        let offset = Int(write & mask)
        let firstRun = min(count, capacity - offset)
        storage.advanced(by: offset).update(from: samples, count: firstRun)
        if firstRun < count {
            storage.update(from: samples.advanced(by: firstRun), count: count - firstRun)
        }

        writeIndex.store(write &+ UInt64(count), ordering: .releasing)
        return true
    }

    // MARK: - Consumer (the polling drain)

    /// Samples available to read right now.
    ///
    /// A snapshot. The producer may add more the instant after it is computed, so it is a lower
    /// bound on what a following ``read(into:count:)`` will yield — never an upper one.
    public var availableToRead: Int {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        return Int(write &- read)
    }

    /// Samples this ring has refused since it was created. See ``write(_:count:)`` for the policy
    /// that produces them.
    ///
    /// **Refusals, not losses — and on the shipped path those are the same number.** The realtime
    /// producer calls ``write(_:count:)`` once per callback and cannot retry: retrying means
    /// spinning on the audio thread, which is the one thing that thread must never do. So every
    /// refusal it takes is audio that no longer exists anywhere, and a non-zero count here means the
    /// buffer handed over at the end of the session is short by exactly this many samples.
    ///
    /// A caller that *does* retry — only the tests do — inflates this without losing anything. That
    /// error is in the safe direction: it can over-report loss, never under-report it, so nothing
    /// downstream can read a zero here and be wrong about the audio being whole.
    public var refusedSampleCount: Int {
        Int(refusedSamples.load(ordering: .relaxed))
    }

    /// Copy at most `count` samples into `destination`, returning how many were copied.
    ///
    /// The consumer side, and therefore the side allowed to be ordinary code.
    public func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }

        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let wanted = min(count, Int(write &- read))
        guard wanted > 0 else { return 0 }

        let offset = Int(read & mask)
        let firstRun = min(wanted, capacity - offset)
        destination.update(from: storage.advanced(by: offset), count: firstRun)
        if firstRun < wanted {
            destination.advanced(by: firstRun).update(from: storage, count: wanted - firstRun)
        }

        readIndex.store(read &+ UInt64(wanted), ordering: .releasing)
        return wanted
    }

    /// Everything readable right now, as an array. Allocates, so it is consumer-only.
    public func drain() -> [Float] {
        let available = availableToRead
        guard available > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: available) { buffer, initializedCount in
            initializedCount = read(into: buffer.baseAddress!, count: available)
        }
    }
}
