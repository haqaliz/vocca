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

import OSLog
import VoccaCore

/// **The live window** — the one object that holds all three halves of the daily-use ledger: the
/// ``UsageWindow`` in memory, the ``UsageStore`` it is loaded from and saved to, and the
/// ``CalendarDayProvider`` that says which day a session happened on.
///
/// It exists so that `AppBootstrap.configure` stays composition rather than logic. `configure` is
/// `@MainActor`, builds an audio graph and an event tap, and is executed by nothing in CI: every
/// decision left inside it is a decision no test can reach. Here, all of them are reachable —
/// `UsageRecorderTests` drives the real ``PersistentUsageStore`` over a temp directory and reads
/// the file system's own call log.
///
/// ## Three entry points, and the split between them is the whole design
///
/// - ``fold(_:)`` is the dictation loop's end of the seam, reached from ``LatencyLedger``'s sink.
///   It resolves the day, folds the record and marks the window unwritten. **It contains no
///   `await` and touches no file**, which is not a style preference: writing is not O(1), and the
///   loop this seam hangs off is the one the P2 latency gate reads. `UsageRecorderTests`'
///   D3 asserts the emptiness of the file system's call log across a run of folds rather than
///   asserting it by inspection.
/// - ``flushIfDue()`` is the cadence: it writes only when something is unwritten *and* either the
///   day has rolled over or ``writeInterval`` has elapsed since the last write.
/// - ``flush()`` is termination: it writes whatever is unwritten, whatever the clock says,
///   because there is no next opportunity.
///
/// ## What a crash costs, and why that is the right trade
///
/// Between two writes the counts live only in memory, so a crash loses them — bounded by
/// ``writeInterval``. That is acceptable here and nowhere else in this tree: **no transcript is
/// involved**. A lost transcript is the one failure `ROADMAP.md:95` fixes at exactly zero, and it
/// is why the recovery journal writes synchronously on the transcript's own path. A lost *count*
/// costs a day's tally a few sessions. Paying the transcript's price for the ledger's data would
/// put file I/O on the dictation path to protect something that does not need protecting.
///
/// ## The launch load, and the folds that beat it
///
/// ``load()`` is asynchronous — `configure` may not block — so a fast first dictation can finalize
/// before the file has been read. Both obvious arrangements lose data: seeding the window from
/// disk *over* an already-folded record drops that session, and folding onto an empty window and
/// then loading drops the whole history. So folds that arrive first are **held**, and ``load()``
/// applies them to the loaded window on its way in. Until the load has completed nothing is
/// written at all: the window in memory is not yet the window on disk, and committing it would
/// replace a real history with a partial one.
public actor UsageRecorder {

    /// **The write cadence: at most one save per minute.**
    ///
    /// The number is a bound on how much counting a crash can lose, and that is the only thing it
    /// decides — so it is chosen from that end. A minute of the heaviest dictation anyone does is
    /// a couple of sessions: invisible in a streak (`ROADMAP.md:102` counts *days*, and a day
    /// survives as long as one session on it was written) and a rounding error in a day's totals.
    ///
    /// What a minute costs is nothing, which is why it can be this short. The cadence writes only
    /// when something was folded, so an idle app writes nothing at all; a hypothetical eight-hour
    /// day of continuous dictation is a few hundred saves of a file measured in kilobytes,
    /// atomically, off the dictation path. Going longer would buy that nothing and start to make
    /// a crash cost an evening's counting.
    ///
    /// Stated once, in the ``UsageWindowConstants/maximumRetainedDays`` and
    /// ``LatencyLedger/maximumRetainedRecords`` shape, and pinned tree-wide by
    /// `UsageRecorderTests.testTheWriteIntervalLivesOnlyInItsNamedConstant`: a second literal
    /// would be a second answer to "how much may be lost".
    public static let writeInterval: Duration = .seconds(60)

    /// The window as it stands now — the loaded history plus everything folded since.
    private var window = UsageWindow()

    /// The ledger's persistence. Loaded once; saved whole.
    private let store: any UsageStore

    /// "What day is it, locally" — asked **per fold**, never cached, so an app left running past
    /// midnight starts a new day without a restart (PRD E3).
    private let day: CalendarDayProvider

    /// The monotonic clock the debounce is measured against. Monotonic, not wall-clock: the
    /// cadence is about elapsed time, and a wall clock that jumps (a time-zone change, an NTP
    /// correction) would either suppress a write for hours or fire one per fold.
    private let clock: any MonotonicClock

    /// The loud half of every failure here: a save that threw, and a day the provider could not
    /// name. Injected so the loudness is asserted rather than hoped
    /// (``PersistentUsageStore``'s shape).
    private let log: @Sendable (String) -> Void

    /// Whether ``load()`` has completed. Nothing is written before it has.
    private var hasLoaded = false

    /// Records folded before the load completed, with the day each was resolved to. Applied by
    /// ``load()`` on top of the loaded window and then dropped.
    ///
    /// Unbounded only in the sense that a load that never finished would let it grow; the load is
    /// one read of one small file at launch, and the sessions that can arrive during it are the
    /// ones a user managed to dictate in that window.
    private var heldUntilLoaded: [(day: CalendarDay, record: SessionRecord)] = []

    /// The day the last fold was filed under — the rollover detector. `nil` until the first fold,
    /// so a launch whose loaded window ends yesterday does not read as a rollover: nothing has
    /// happened yet that is worth committing.
    private var lastFoldedDay: CalendarDay?

    /// Whether the window holds anything the file does not. The debounce's first condition, and
    /// what keeps an idle cadence from rewriting an unchanged file.
    private var hasUnwrittenFolds = false

    /// Set when a fold crosses midnight: the previous day is complete and will never be added to
    /// again, so the next cadence tick commits it without waiting out the interval.
    private var dayRolledOver = false

    /// The clock reading at the last write — or at construction, so the first write is due one
    /// interval into the run rather than immediately.
    private var lastWrite: Duration

    public init(
        store: any UsageStore,
        day: @escaping CalendarDayProvider,
        clock: any MonotonicClock,
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "usage-ledger").error("\($0)")
        }
    ) {
        self.store = store
        self.day = day
        self.clock = clock
        self.log = log
        lastWrite = clock.now
    }

    /// The window as it stands — the loaded history plus everything folded since. The Usage tab's
    /// read, and what the tests assert against.
    public var currentWindow: UsageWindow { window }

    /// Seeds the window from the store, once, and applies anything folded while the read was in
    /// flight.
    ///
    /// Never throws and never blocks a dictation: ``UsageStore/load()`` answers the empty window
    /// for a missing file and for one this build cannot read, so a ledger that could not be read
    /// is a lost history and never a broken recorder (spec D8).
    public func load() async {
        guard !hasLoaded else { return }
        let persisted = await store.load()
        // Re-checked after the suspension: a second `load()` may have completed while this one
        // was reading, and seeding the window twice would discard whatever was folded in between.
        guard !hasLoaded else { return }
        window = persisted
        hasLoaded = true
        for held in heldUntilLoaded {
            apply(held.record, on: held.day)
        }
        heldUntilLoaded.removeAll()
    }

    /// Folds one finalized session into the day it happened on.
    ///
    /// **No `await`, no file.** See the type's doc comment: this is the dictation loop's end of
    /// the seam, and the write cadence is ``flushIfDue()``'s and ``flush()``'s alone.
    ///
    /// A record whose day the provider cannot name is **skipped**, not filed under a repaired
    /// one — ``CalendarDayProvider``'s optional is deliberate, and nothing downstream could tell
    /// a fabricated day from a real one.
    public func fold(_ record: SessionRecord) {
        guard let today = day() else {
            log("Usage ledger: a finalized session could not be dated, so it was not counted.")
            return
        }
        if let previous = lastFoldedDay, previous != today {
            dayRolledOver = true
        }
        lastFoldedDay = today
        guard hasLoaded else {
            heldUntilLoaded.append((day: today, record: record))
            hasUnwrittenFolds = true
            return
        }
        apply(record, on: today)
    }

    /// The cadence: write when something is unwritten *and* the write is due — either the day
    /// rolled over, or ``writeInterval`` has elapsed since the last write.
    public func flushIfDue() async {
        guard hasUnwrittenFolds else { return }
        guard dayRolledOver || clock.now - lastWrite >= Self.writeInterval else { return }
        await persist()
    }

    /// Termination's write: whatever is unwritten goes now, whatever the clock says, because
    /// there is no next tick.
    public func flush() async {
        guard hasUnwrittenFolds else { return }
        await persist()
    }

    /// **Forget everything** — the Usage tab's Clear, and the only destructive control the ledger
    /// has.
    ///
    /// Both halves, together, because either alone is a lie of a different shape: a window emptied
    /// without the file is a history that returns at the next launch, and a file deleted without
    /// the window is a run that goes on counting from what the user just erased and writes it
    /// back at the next tick.
    ///
    /// Marked **loaded** afterwards, whether or not ``load()`` ever ran. The flag's meaning is
    /// "the window in memory is the window on disk", which is now true by construction — both are
    /// empty — and it is what stops a launch read that is still in flight from seeding the
    /// deleted history back over an explicit erasure (``load()`` re-checks it after its
    /// suspension). The folds held for that read go the same way, for the same reason: they are
    /// that history's remainder.
    ///
    /// A deletion that fails is logged and leaves the counts marked **unwritten**, so the next
    /// cadence tick or the quit flush writes the empty window over the file. That is
    /// ``persist()``'s retry policy pointed the other way — the erasure lands either way, and
    /// never silently fails to.
    public func clear() async {
        window = UsageWindow()
        heldUntilLoaded.removeAll()
        lastFoldedDay = nil
        hasLoaded = true
        hasUnwrittenFolds = false
        dayRolledOver = false
        do {
            try await store.clear()
        } catch {
            log("Usage ledger: deleting the daily-use window failed (\(error)); the next write "
                + "will empty the file instead.")
            hasUnwrittenFolds = true
        }
    }

    /// Folds a record into its day and marks the window unwritten. The one place the window is
    /// mutated by a session.
    private func apply(_ record: SessionRecord, on today: CalendarDay) {
        var aggregate = window.aggregate(for: today) ?? DayAggregate(day: today)
        aggregate.fold(record)
        // Retention is the window's own rule, applied on the way in — a day older than every day
        // a full window holds is evicted here rather than admitted.
        window.insert(aggregate)
        hasUnwrittenFolds = true
    }

    /// Saves the whole window, and resets the cadence.
    ///
    /// **Nothing is written before the load has completed**: the window in memory is not yet the
    /// window on disk, and committing it would replace a real history with a partial one. The
    /// cadence flags are left set, so the write happens as soon as the load lands.
    ///
    /// A save that throws leaves the window exactly as it was and stays *unwritten*, so the next
    /// tick tries again — with one loud line, because the caller's window and the file have
    /// diverged and only a log can say so.
    private func persist() async {
        guard hasLoaded else { return }
        do {
            try await store.save(window)
            lastWrite = clock.now
            hasUnwrittenFolds = false
            dayRolledOver = false
        } catch {
            log("Usage ledger: saving the daily-use window failed (\(error)); it stays in memory.")
        }
    }
}
