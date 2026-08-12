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
    // 2. SINGLE WRITER PER ATOMIC. `writeIndex` is written only by the producer and read by both.
    //    `readIndex` is written only by the consumer and read by both. `refusedSamples` is written
    //    only by the producer. **No atomic in this file has two writers, and therefore no atomic in
    //    this file is ever the target of a read-modify-write** — every one of them is a plain load
    //    or a plain store, including the refusal counter, which is why it is `load`-then-`store`
    //    below rather than the `wrappingAdd` that would read more naturally.
    //
    //    That claim is checked rather than counted by hand, by `testTheRingBuffersAtomicsAreOnly
    //    EverLoadedAndStored`: exactly three stores to atomics in the code of this file, one per
    //    atomic, and no read-modify-write spelling anywhere in it. The earlier version of this
    //    paragraph told a reader to run a `grep` and gave the answer three — the `grep` says four,
    //    because the sentence counted itself. A warrant for the only `@unchecked Sendable` in the
    //    codebase should not hand its reader an instruction that disagrees with it.
    //
    //    It is also why the overrun policy is drop-newest and not drop-oldest: dropping the oldest
    //    sample means the *producer* advancing `readIndex`, which gives that cursor two writers and
    //    forces a compare-exchange loop onto the realtime thread. That is the load-bearing argument
    //    for the policy — see ``write(_:count:)``, which does not rest it on which end of an
    //    utterance matters more.
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
    //    there is no other value it could observe. The one exception is `availableToRead`, whose
    //    `.acquiring` load of `writeIndex` is conservative rather than necessary: it touches no
    //    storage, so nothing sequenced after it depends on sample visibility, and every path that
    //    *does* read storage performs its own acquire. It is kept for uniformity, and named here so
    //    that "own cursor relaxed, the other acquiring" is not read as load-bearing at a site where
    //    it carries no weight.
    //
    //    THE ORDERINGS ARE COMPILER BARRIERS BEFORE THEY ARE CPU BARRIERS, and that is the half of
    //    the argument that survives a change of platform. `storage` is a separate allocation from
    //    the atomics' inline words, so LLVM can prove the two do not alias; with a `.relaxed` cursor
    //    store there is nothing in the IR stopping it from sinking the sample copies past that store
    //    — at `-O`, on x86 as much as on arm64. Only then is it also a hardware argument: on arm64
    //    `.acquiring` and `.releasing` lower to `ldar` and `stlr`, and the all-relaxed version
    //    *happened to pass* on the x86 build it was tried on, where the hardware supplies what the
    //    compiler did not — happened to, because by the paragraph above the compiler may sink the
    //    copies there too, so that pass was luck and not a property of x86. A reader who concludes
    //    that a strong enough memory model makes these optional has stopped at the second half.
    //
    //    AND NOTHING AUTOMATED CHECKS THEM. Measured, not assumed, and independently reproduced in
    //    review: **six** weakenings — each of the four load-bearing orderings on its own, the
    //    unnecessary one, and all four at once — leave the whole suite and the ThreadSanitizer run
    //    completely clean. LLVM's TSan detects *missing* synchronisation, not *insufficient*
    //    synchronisation. And a seventh defect of the same family — publishing the cursor *before*
    //    copying the samples in, three lines below — is caught only intermittently: 2 of 12 plain
    //    runs, 0 of 2 under TSan. So the orderings in this file are held up by this comment and by
    //    whoever reads it. Change one only with the paragraphs above in front of you.
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
    ///
    /// Not padded away from ``readIndex``, and that is a decision rather than an omission. The two
    /// are adjacent stored properties, so the producer's store and the consumer's store contend for
    /// one cache line — at roughly one callback every 10 ms against a ~10 ms drain poll, that is a
    /// few hundred coherence events a second, which is nothing measurable. Padding would cost a
    /// hand-rolled layout in the one file that most needs to be readable.
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

    /// Whether `capacity` is a legal ring size: a power of two, greater than zero.
    ///
    /// Split out of the precondition below so that the *rule* is testable. A `precondition` cannot
    /// be caught in-process, so a test can only watch it fire by spawning a subprocess — with the
    /// result that both preconditions here were, on review, satisfiable by any predicate at all:
    /// neutering each of them left the whole suite green. The trap stays where it is; the decision
    /// it makes is now a pure function with tests on it.
    public static func isValidCapacity(_ capacity: Int) -> Bool {
        capacity > 0 && capacity & (capacity - 1) == 0
    }

    /// How many samples a ring of `capacity` has room for, given the two cursors.
    ///
    /// Split out for the same reason as ``isValidCapacity(_:)``: the behaviour that matters is the
    /// one in a state no test can reach through the API. `Int(write &- read)` used to compute this,
    /// and that is a **trapping** conversion — in a function whose own documentation rejects
    /// trapping, on the one thread in Vocca where a trap is a dead microphone mid-sentence rather
    /// than a crash report. It is reachable the moment the SPSC discipline is violated and the
    /// cursors invert, which is exactly the discipline `@unchecked Sendable` leaves unenforced.
    ///
    /// So: all `UInt64`, and the occupancy clamped to `capacity`. Inverted cursors give zero room
    /// and therefore a refusal — the loudest thing an audio callback may safely do — instead of a
    /// `Fatal error` inside a CoreAudio callback. Reverting this to the trapping form is invisible
    /// to every runtime test, because the trap only fires in a state the API cannot produce; the
    /// tests on *this function* are what hold it.
    ///
    /// `max(capacity, 0)` for the same reason one level down, and it is not theoretical: this
    /// function is `public` and `UInt64(capacity)` traps on a negative one with `Fatal error:
    /// Negative value is not representable`. A constructed ring cannot reach it — `init` refuses a
    /// non-positive capacity — but "unreachable through the API" is the exact reasoning the trapping
    /// conversion this function replaced was defended with, and it was wrong then too.
    ///
    // @realtime — `write` calls this on every callback, so it is realtime-path code and is linted
    // as such. It was not, for one round: the F3 fix moved arithmetic off a linted body onto an
    // unlinted one, and an allocation and a `print` inside here passed all 361 tests.
    public static func room(capacity: Int, write: UInt64, read: UInt64) -> UInt64 {
        let limit = UInt64(max(capacity, 0))
        return limit &- min(write &- read, limit)
    }

    /// - Parameter capacity: samples the ring holds. Must be a power of two greater than zero.
    ///
    /// Traps on a bad capacity. That is deliberate and it is safe *here*, unlike on the producer
    /// path: `init` runs on whatever thread builds the capture graph, long before the engine
    /// starts, so the trap is a programming error a test catches rather than a crash on the audio
    /// thread. See ``write(_:count:)``, which is the same file's argument for why nothing on the
    /// realtime path may trap.
    public init(capacity: Int) {
        precondition(
            Self.isValidCapacity(capacity),
            """
            AudioRingBuffer capacity must be a power of two greater than zero, got \(capacity). The \
            cursors are monotonic and masked, which is what lets a full ring be told apart from an \
            empty one without wasting a slot; the mask requires a power of two.
            """)

        self.capacity = capacity
        self.mask = UInt64(capacity - 1)
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)

        // Not required — no slot can be read before it is written, and `Float` is trivial, so
        // `allocate` alone would be sound. It is here so that a *violated* SPSC invariant produces
        // silence rather than whatever was previously on the heap: a reader that gets ahead of the
        // writer hears nothing, not a burst of noise into the user's ears. That is worth one pass
        // over the buffer at construction, which happens once for the app's lifetime.
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
    ///   writers and forces a compare-exchange loop onto the realtime thread. **That is the whole
    ///   argument, and it is a mechanism argument.** It is deliberately not "the beginning of the
    ///   utterance matters more than the end": drop-newest throws away the words the user has just
    ///   spoken and is watching for, and pretending that is the cheaper loss would be rhetoric
    ///   propping up a decision the invariant in claim 2 already makes on its own.
    ///
    /// - *Write what fits* splices a discontinuity into the middle of a stream that the consumer
    ///   has no way to see. The ASR would receive a waveform that is contiguous in memory and skips
    ///   time, and would transcribe it confidently and wrongly. Vocca's invariant is that a
    ///   transcript is never lost; a transcript that is quietly wrong is a worse failure than one
    ///   that is visibly short.
    ///
    /// - *Trap* kills the app mid-sentence and loses the entire session, which is precisely the
    ///   loss the invariant forbids. Nothing on this path traps — see "which side traps" below.
    ///
    /// So the loss is aligned to a whole callback block, and it is **countable**.
    ///
    /// ## Countable is not yet counted, and this is the honest state of it
    ///
    /// ``refusedSampleCount`` is read by nothing today. The conclusion that makes drop-newest safe
    /// for a product whose invariant is *a transcript is never lost* — that the audio handed over is
    /// known to be short by exactly N samples, and can be presented as incomplete rather than as
    /// complete — needs a consumer that reads it, and the first consumer is the
    /// `SessionAudioSource` conformance in Phase 5. The obligation is written into
    /// `docs/planning/audio-capture-hotkey/audio-capture/plan_20260806.md` rather than left as a
    /// sentence here describing a reader nobody is building. Until that phase lands nothing at all
    /// drains this buffer, so nothing can present its contents as anything.
    ///
    /// No claim is made that overruns are unreachable. Whether they are depends on the capacity,
    /// which is still the aspect's open question 1 and which this type does not choose.
    ///
    /// ## Which side traps
    ///
    /// **Nothing on the producer path does.** A negative `count` returns `false` and stores nothing.
    /// The occupancy arithmetic below is done in `UInt64` and the offset conversion truncates, so
    /// there is no trapping conversion here even if the SPSC invariant is violated and the cursors
    /// invert — in that state the producer computes zero room and refuses, which is the loudest
    /// thing an audio callback may safely do. The consumer side is the opposite and deliberately
    /// so: ``availableToRead`` and ``read(into:count:)`` convert with `Int(_:)` and will trap on
    /// inverted cursors, because they run where a crash is a bug report rather than a dead
    /// microphone in the middle of a sentence.
    ///
    // @realtime — RealtimeSafetyTests lints the body below. Moving or deleting this marker changes
    // what is linted, and the lint asserts the exact set of markers it found.
    @discardableResult
    public func write(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return count == 0 }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)

        // Non-trapping by construction, and tested as a function rather than only as a path — see
        // `room(capacity:write:read:)`, which explains what used to be here and why.
        guard UInt64(count) <= Self.room(capacity: capacity, write: write, read: read) else {
            // `load`-then-`store`, not `wrappingAdd`. This atomic has exactly one writer, so the
            // read-modify-write buys nothing — and claim 2 above says no atomic in this file is
            // ever the target of one. A comment that is the sole warrant for an `@unchecked
            // Sendable` does not get to have a carve-out ten lines below itself.
            refusedSamples.store(
                refusedSamples.load(ordering: .relaxed) &+ UInt64(count), ordering: .relaxed)
            return false
        }

        // `truncatingIfNeeded` rather than `Int(_:)` for the same reason as above: the masked value
        // provably fits, but "provably" is doing work a future edit could invalidate, and the cost
        // of not relying on it is nil.
        let offset = Int(truncatingIfNeeded: write & mask)
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
