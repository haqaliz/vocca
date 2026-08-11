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

/// The recovery journal — the failsafe rung's durable custody, and the first implementation of
/// the recovery half of `TranscriptCustody` (`ARCHITECTURE.md` §10).
///
/// When every rung of the ladder fails, ``JournalTranscriptHolder`` holds the transcript behind
/// the core's ``TranscriptHolder`` seam; this actor is where the holding is made durable. All of
/// the journal's decisions live here, over the injected ``JournalStore`` seam:
///
/// - **Which entry is current** — the newest. The seam is single-slot: `current()` is
///   single-valued, so the latest hold replaces the previous one in the slot, exactly as
///   `HeldTranscriptTests` pins. The journal itself stays bounded, so an older unresolved entry
///   is not lost by a replacement — it is evicted only when the cap demands it.
/// - **When the oldest is evicted** — on every hold beyond `capacity`, and at launch when a
///   smaller capacity is in force. Oldest first is a comparison of write ordinals
///   (``JournalEntry/id``), which is why the ordinal is monotonic rather than a clock: the
///   ordering is deterministic across relaunches, restarts and NTP steps.
/// - **What release resolves** — the current (newest) entry. The user copied it, a retry
///   delivered it, or they dismissed it; the journal purges it and nothing else.
///
/// The file-system half — path resolution, the atomic temp-write-then-rename commit, listing —
/// is ``FileSystemJournalStore``, the one file in `VoccaInject` permitted to name
/// `FileManager`. This file names none of it and knows no paths.
///
/// ## The load-bearing contract: `hold` is durable before it returns
///
/// PRD R6: a crash between ladder exhaustion and the journal write is a lost transcript, so the
/// write is committed *as part of* the hand-off. ``hold(_:)`` awaits ``JournalStore/save(_:)``
/// before it answers — the ordering is asserted by `RecoveryJournalTests`, over the same
/// two-ended ledger the seam's contract test uses.
public actor RecoveryJournal {
    private let store: any JournalStore
    private let capacity: Int
    private var entriesByID: [Int: JournalEntry] = [:]
    private var nextOrdinal = 1

    /// A journal over `store` that keeps at most `capacity` entries, oldest dropped first.
    ///
    /// Load-on-launch: the entries already committed to the store — the process's own
    /// pre-relaunch holds — are read in, the next ordinal is derived from them, and any excess
    /// over a newly smaller `capacity` is evicted. A capacity below one is clamped to one: a
    /// journal that evicted its own current entry would lose the transcript it exists to hold.
    public init(store: any JournalStore, capacity: Int) async throws {
        self.store = store
        self.capacity = max(capacity, 1)
        for entry in try await store.load() {
            entriesByID[entry.id] = entry
        }
        nextOrdinal = (entriesByID.keys.max() ?? 0) + 1
        try await evictOldestBeyondCapacity()
    }

    /// Durably holds `transcript`. Must not return before the store's save has committed; throws
    /// when it cannot be made so, with nothing held.
    public func hold(_ transcript: HeldTranscript) async throws {
        let entry = JournalEntry(id: nextOrdinal, transcript: transcript)
        try await store.save(entry)
        entriesByID[entry.id] = entry
        nextOrdinal += 1
        try await evictOldestBeyondCapacity()
    }

    /// The currently held transcript — the newest held entry — or `nil` when nothing is held.
    public func current() async -> HeldTranscript? {
        newestEntry()?.transcript
    }

    /// Releases the held transcript — the user copied it, a retry delivered it, or they
    /// dismissed it. Purges the current (newest) entry; a no-op when nothing is held.
    public func release() async {
        guard let newest = newestEntry() else { return }
        entriesByID[newest.id] = nil
        try? await store.remove(id: newest.id)
    }

    private func newestEntry() -> JournalEntry? {
        entriesByID.values.max(by: { $0.id < $1.id })
    }

    /// Drops the oldest entries, in ordinal order, until the journal fits `capacity` — both
    /// in memory and, durably, in the store.
    private func evictOldestBeyondCapacity() async throws {
        var ordered = entriesByID.keys.sorted()
        while ordered.count > capacity {
            let oldest = ordered.removeFirst()
            entriesByID[oldest] = nil
            try await store.remove(id: oldest)
        }
    }
}
