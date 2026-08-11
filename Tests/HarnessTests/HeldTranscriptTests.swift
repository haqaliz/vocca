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

import VoccaCore
import XCTest

/// The held-transcript custody seam — ``TranscriptHolder``, and its one load-bearing contract.
///
/// Phase D of `injector-seam` (`docs/planning/injection-ladder/injector-seam/plan_20260809.md` §4).
/// The types shipped in Phase A; what is tested here is the *contract* they declare, over fakes —
/// the `ModelDownloadSession` pattern the seam was shaped on: the core owns the contract, the
/// adapters and the UI implement it, and until the recovery journal (`failsafe-surface` aspect)
/// exists, the contract is held by tests over an in-memory holder.
///
/// The load-bearing test is the durability ordering. PRD R6: the journal write is committed *as
/// part of* the failsafe hand-off, not after it — a crash between ladder exhaustion and the
/// journal write is a lost transcript, the one window I1's floor must close. The seam documents
/// the rule ("`hold` is durable before it returns" — ``TranscriptHolder``), and the assertion here
/// is made across a boundary a real holder must also cross: the holder's write is a separate
/// order-recording store, and the check reads a shared ledger the two ends append to. A negative
/// control runs the same check against a holder that answers before the write commits — the exact
/// silent violation the protocol's own documentation names — and proves the check can fail.
///
/// The seam's shape is single-slot: `current()` is single-valued, so a second `hold` before a
/// `release` replaces the first — one unresolved transcript at a time, which is the failsafe's
/// shape (the window renders one transcript; the journal is bounded, oldest dropped first).
/// Replacement and any-order usage are pinned here so a later journal implementation cannot hand
/// the window a shape the seam never admitted.
final class HeldTranscriptTests: XCTestCase {

    // MARK: - The lifecycle

    /// hold → current: the transcript the ladder handed over comes back whole.
    ///
    /// Every field asserted by hand rather than only by `Equatable`, so a holder that rebuilt the
    /// payload — text for the copy, reason for the window's copy table, the app name for the
    /// "{app}" phrasing, the monotonic instant for the "captured at" note — fails by naming the
    /// field it lost. `Equatable` equality on top, so the round trip is whole.
    func testHoldMakesCurrentReturnTheHeldTranscript() async throws {
        let log = TranscriptEventLog()
        let holder = FakeTranscriptHolder(store: RecordingDurableStore(log: log), log: log)
        let held = HeldTranscript(
            text: "the words", reason: .exhausted, targetAppName: "Slack",
            capturedAt: .seconds(3))

        try await holder.hold(held)

        let current = await holder.current()
        XCTAssertEqual(current?.text, "the words")
        XCTAssertEqual(current?.reason, .exhausted)
        XCTAssertEqual(current?.targetAppName, "Slack")
        XCTAssertEqual(current?.capturedAt, .seconds(3))
        XCTAssertEqual(current, held, "the held transcript must survive the round trip whole")
    }

    /// A second hold before a release replaces the first.
    ///
    /// `current()` is single-valued, so the seam admits exactly one unresolved transcript at a
    /// time — the failsafe's shape: the window renders one transcript, and retry/copy/dismiss
    /// resolves it. Replacement is the only semantics the shape permits; the test pins it so a
    /// journal that (say) refused a second hold could not land without this suite noticing.
    func testAHoldReplacesThePreviousHold() async throws {
        let log = TranscriptEventLog()
        let holder = FakeTranscriptHolder(store: RecordingDurableStore(log: log), log: log)
        let first = HeldTranscript(
            text: "first", reason: .exhausted, targetAppName: "Slack", capturedAt: .seconds(1))
        let second = HeldTranscript(
            text: "second", reason: .secureInput, targetAppName: nil, capturedAt: .seconds(2))

        try await holder.hold(first)
        try await holder.hold(second)

        let current = await holder.current()
        XCTAssertEqual(
            current, second,
            "the seam is single-slot: current must reflect the latest hold")
        XCTAssertNotEqual(
            current, first,
            "a replaced hold must not linger in the slot")
    }

    /// release → current is nil: the user copied it, a retry delivered it, or they dismissed it.
    func testReleaseEmptiesTheSlot() async throws {
        let log = TranscriptEventLog()
        let holder = FakeTranscriptHolder(store: RecordingDurableStore(log: log), log: log)
        try await holder.hold(
            HeldTranscript(
                text: "the words", reason: .exhausted, targetAppName: nil, capturedAt: .zero))

        await holder.release()

        let current = await holder.current()
        XCTAssertNil(current, "release must empty the slot")
    }

    /// release with nothing held is a no-op, not a crash and not an invented state.
    ///
    /// The seam must be safe to use in any order, and this is the degenerate corner of that
    /// claim: the window can dismiss at any moment, including one where nothing was ever held.
    func testReleaseWithNothingHeldIsANoOp() async {
        let log = TranscriptEventLog()
        let holder = FakeTranscriptHolder(store: RecordingDurableStore(log: log), log: log)

        await holder.release()

        let current = await holder.current()
        XCTAssertNil(current, "release with nothing held must leave the slot empty")
    }

    /// hold → hold → release → hold → release: no crash, no lost state, in any order.
    ///
    /// The one thing the window depends on is that the last released transcript is the one that
    /// was current at the time — a released transcript must never resurface.
    func testHoldReleaseHoldAgainLosesNothing() async throws {
        let log = TranscriptEventLog()
        let holder = FakeTranscriptHolder(store: RecordingDurableStore(log: log), log: log)
        let first = HeldTranscript(
            text: "first", reason: .noFocusedField, targetAppName: nil, capturedAt: .seconds(1))
        let second = HeldTranscript(
            text: "second", reason: .exhausted, targetAppName: "Mail", capturedAt: .seconds(2))

        try await holder.hold(first)
        try await holder.hold(second)
        await holder.release()
        let afterFirstCycle = await holder.current()
        XCTAssertNil(afterFirstCycle)

        try await holder.hold(first)
        let reHeld = await holder.current()
        XCTAssertEqual(reHeld, first)
        await holder.release()
        let afterSecondCycle = await holder.current()
        XCTAssertNil(
            afterSecondCycle,
            "a released transcript must not resurface")
    }

    // MARK: - The durability contract (PRD R6)

    /// **The load-bearing contract: hold must not return before the transcript is durable.**
    ///
    /// `TranscriptHolder` documents this as its own enforcement: the ladder neither knows nor
    /// checks whether the transcript is durable, so a conformer that returns before committing is
    /// "a silent I1 violation no caller can detect" — the write must therefore be part of the
    /// hand-off itself. Over the order-recording store, the assertion reads the shared ledger:
    /// the durable write must precede the hold's return, and both must carry the same transcript.
    func testHoldIsDurableBeforeItReturns() async throws {
        let log = TranscriptEventLog()
        let holder = FakeTranscriptHolder(store: RecordingDurableStore(log: log), log: log)
        let held = HeldTranscript(
            text: "the words", reason: .exhausted, targetAppName: "Slack",
            capturedAt: .seconds(3))

        try await holder.hold(held)

        await assertDurablyHeld(held, in: log)
    }

    /// The negative control: the ordering check can fail.
    ///
    /// A holder that answers before the write commits is the exact violation PRD R6 exists to
    /// close, runnable rather than described — the `LyingSource` precedent. The caller cannot see
    /// it; the ledger can, and the check in this file is only load-bearing because it detects
    /// this holder.
    func testTheOrderingCheckDetectsAReturnBeforeTheDurableWrite() async throws {
        let log = TranscriptEventLog()
        let holder = ReturningBeforeWriteHolder(store: RecordingDurableStore(log: log), log: log)
        let held = HeldTranscript(
            text: "the words", reason: .exhausted, targetAppName: nil, capturedAt: .zero)

        try await holder.hold(held)

        let durablyHeld = await isDurablyHeld(held, in: log)
        XCTAssertFalse(
            durablyHeld,
            "a holder that returns before the write commits must fail the durability check")
    }

    /// `hold` throws when the transcript cannot be made durable, and the slot stays empty.
    ///
    /// The protocol documents "throws when it cannot be made so": a journal that cannot commit
    /// must surface as a throw, not as a successful return — the caller is relying on the answer
    /// meaning "safe against process death".
    func testHoldThrowsWhenTheWriteCannotBeMadeDurable() async throws {
        let log = TranscriptEventLog()
        let store = RecordingDurableStore(log: log)
        let holder = FakeTranscriptHolder(store: store, log: log)
        let held = HeldTranscript(
            text: "the words", reason: .exhausted, targetAppName: nil, capturedAt: .zero)
        await store.refuseNextWrite()

        do {
            try await holder.hold(held)
            XCTFail("hold must throw when the transcript cannot be made durable")
        } catch {
            // Expected — the throw is the contract.
        }

        let current = await holder.current()
        XCTAssertNil(current, "a failed hold must not leave a transcript in the slot")
        let events = await log.events
        XCTAssertEqual(
            events, [],
            "a failed write must record no durability and no return")
    }

    // MARK: - The durability check

    /// Whether the ledger shows `transcript` durably written before `hold` returned — PRD R6's
    /// ordering, as a value, so the same check is asserted `true` against the conforming holder
    /// and `false` against the mutant.
    private func isDurablyHeld(_ transcript: HeldTranscript, in log: TranscriptEventLog) async -> Bool {
        let events = await log.events
        guard events.count == 2,
              case .durableWrite(let written) = events[0],
              case .holdReturned(let returned) = events[1] else {
            return false
        }
        return written == transcript && returned == transcript
    }

    /// The same fact, as an assertion — the form the load-bearing test uses.
    private func assertDurablyHeld(_ transcript: HeldTranscript, in log: TranscriptEventLog) async {
        let durablyHeld = await isDurablyHeld(transcript, in: log)
        if !durablyHeld {
            let ledger = await log.events
            XCTFail(
                "hold must not answer before the durable write commits (PRD R6); ledger: \(ledger)")
        }
    }
}

// MARK: - The ledger and the fakes

/// What the two ends of the custody seam record, in order.
///
/// Two events and nothing else: the moment the durable write commits, and the moment `hold`
/// answers. The ordering of the two is the contract under test.
enum HeldTranscriptEvent: Equatable {
    /// The store committed `transcript` — the journal write a crash after it cannot undo.
    case durableWrite(HeldTranscript)
    /// `hold` answered for `transcript`.
    case holdReturned(HeldTranscript)
}

/// A ledger the fake holder and the fake store both append to, from behind their own actor
/// boundaries.
///
/// An actor rather than a plain class carrying `@unchecked Sendable`: the doubles conform to
/// `Sendable` seams, and the `StubEngine` precedent (`ASRTestDoubles.swift:36-37`) puts the honest
/// actor on the boundary instead of an unchecked annotation — "measuring Sendability" is not this
/// file's job.
actor TranscriptEventLog {
    private(set) var events: [HeldTranscriptEvent] = []

    func append(_ event: HeldTranscriptEvent) {
        events.append(event)
    }
}

/// The journal's half of the custody seam: the write `hold` must await before it answers.
///
/// Not the shipped seam — ``TranscriptHolder`` is. This is the seam *within* the conformance, the
/// boundary the journal implementation crosses once per hold: written, then answered. The
/// order-recording fake conforms to it so the durability contract is asserted across a boundary a
/// real holder must also cross, rather than inside one object that could reorder its own two lines
/// and still pass its own test.
protocol DurableTranscriptStore: Sendable {
    /// Durably commits `transcript` — what survives process death.
    func writeDurably(_ transcript: HeldTranscript) async throws
}

/// The journal's write, recorded in the shared ledger at the moment it would have committed.
actor RecordingDurableStore: DurableTranscriptStore {
    private var failsNextWrite = false

    private let log: TranscriptEventLog
    private(set) var writeCount = 0

    init(log: TranscriptEventLog) {
        self.log = log
    }

    /// Refuses the next write, once — a journal failure the test injects, so `hold` must throw
    /// rather than answer (the protocol documents "throws when it cannot be made so").
    func refuseNextWrite() {
        failsNextWrite = true
    }

    func writeDurably(_ transcript: HeldTranscript) async throws {
        if failsNextWrite {
            failsNextWrite = false
            throw TestDurabilityError.storeUnavailable
        }
        writeCount += 1
        await log.append(.durableWrite(transcript))
    }
}

/// The holder the seam documents, as a double: write first, hold second, answer third.
///
/// The order of the awaits is the contract under test — nothing in this file's other assertions
/// is stronger than this one. A holder that answered first is the exact violation the protocol's
/// documentation names, and ``ReturningBeforeWriteHolder`` exists so the check can be shown to
/// catch it.
actor FakeTranscriptHolder: TranscriptHolder {
    private let store: any DurableTranscriptStore
    private let log: TranscriptEventLog
    private var current: HeldTranscript?

    init(store: any DurableTranscriptStore, log: TranscriptEventLog) {
        self.store = store
        self.log = log
    }

    func hold(_ transcript: HeldTranscript) async throws {
        try await store.writeDurably(transcript)
        current = transcript
        await log.append(.holdReturned(transcript))
    }

    func current() async -> HeldTranscript? { current }

    func release() async {
        current = nil
    }
}

/// **The mutant the ordering check exists to kill**: a holder that answers before the write
/// commits.
///
/// The crash-window I1 violation PRD R6 exists to close, runnable rather than described — the
/// `LyingSource` precedent. The ``TranscriptHolder`` documentation says a conformer shaped like
/// this one is "a silent I1 violation no caller can detect": the caller cannot see it, and the
/// shared ledger can.
actor ReturningBeforeWriteHolder: TranscriptHolder {
    private let store: any DurableTranscriptStore
    private let log: TranscriptEventLog
    private var current: HeldTranscript?

    init(store: any DurableTranscriptStore, log: TranscriptEventLog) {
        self.store = store
        self.log = log
    }

    func hold(_ transcript: HeldTranscript) async throws {
        // The answer is out while the write is still pending on the caller's stack.
        await log.append(.holdReturned(transcript))
        current = transcript
        try await store.writeDurably(transcript)
    }

    func current() async -> HeldTranscript? { current }

    func release() async {
        current = nil
    }
}

/// What a journal failure is, for the throw test. The value is that `hold` throws and the slot
/// stays empty — the specific error is the journal's business.
enum TestDurabilityError: Error {
    case storeUnavailable
}
