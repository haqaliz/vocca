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
@testable import VoccaInject
import VoccaCore

/// What the journal's file-system seam records, in order — the **atomic-pair protocol** the
/// durability claim is carried by.
///
/// The write protocol of a durable journal store is two events, not one: the temp file is
/// written, then it is renamed over the entry name. A crash between the two leaves a `.tmp` file
/// that ``JournalStore/load()`` and ``JournalStore/list()`` never see — which is the whole point
/// of the pair, and which is why the fake records it as two events rather than one: a store whose
/// save was one step (write straight to the entry name) would be a store that can leave a
/// readable *partial* entry behind, and the pair is what proves this one cannot.
enum JournalStoreEvent: Equatable {
    /// The temp file was written — not yet readable, not yet committed.
    case tempWrite(String)
    /// The temp file was renamed over the entry name — the commit point.
    case rename(String)
}

/// The journal's write and ledger, in one actor: an in-memory ``JournalStore`` whose every save
/// is recorded as the atomic temp-write/rename pair, and whose committed entries are only ever
/// the renamed ones.
///
/// Two failure modes a real disk can hit are injectable, and they are the two sides of the
/// durability claim:
///
/// - ``simulateCrashAfterTempWrite()`` — the save writes its temp file and stops: the pair
///   never completes, and nothing becomes readable. This is a *crash*, not a refusal — the
///   store is not misbehaving, it simply died between the two steps.
/// - ``refuseNextSave()`` — the store refuses the write outright (disk full, permissions):
///   `hold` must throw and the slot must stay empty.
///
/// The optional ``TranscriptEventLog`` ledger appends the contract test's own `.durableWrite`
/// event at the moment the rename would have landed, so the durability ordering is asserted
/// across the same two-ended ledger the seam's contract test uses — the real journal commits
/// here, and the marker holder appends `.holdReturned` when `hold` answers.
actor RecordingJournalStore: JournalStore {
    private(set) var events: [JournalStoreEvent] = []
    private(set) var committed: [Int: JournalEntry] = [:]
    private var crashAfterTempWrite = false
    private var refusesNextSave = false
    private let ledger: TranscriptEventLog?

    init(ledger: TranscriptEventLog? = nil) {
        self.ledger = ledger
    }

    /// The next save dies between temp-write and rename, once.
    func simulateCrashAfterTempWrite() {
        crashAfterTempWrite = true
    }

    /// The next save refuses the write outright, once.
    func refuseNextSave() {
        refusesNextSave = true
    }

    func save(_ entry: JournalEntry) async throws {
        let name = Self.fileName(for: entry.id)
        events.append(.tempWrite(name))
        if crashAfterTempWrite {
            crashAfterTempWrite = false
            throw JournalTestError.crashBetweenTempWriteAndRename
        }
        if refusesNextSave {
            refusesNextSave = false
            throw JournalTestError.storeUnavailable
        }
        events.append(.rename(name))
        committed[entry.id] = entry
        await ledger?.append(.durableWrite(entry.transcript))
    }

    func load() async throws -> [JournalEntry] {
        committed.values.sorted { $0.id < $1.id }
    }

    func list() async throws -> [Int] {
        committed.keys.sorted()
    }

    func remove(id: Int) async throws {
        committed[id] = nil
    }

    /// The entry file name for a write ordinal — the same zero-padded convention the real store
    /// uses, so the recorded pair names are deterministic assertions rather than layout trivia.
    static func fileName(for id: Int) -> String {
        let digits = String(id)
        return String(repeating: "0", count: max(0, 8 - digits.count)) + digits + ".json"
    }
}

/// `hold`'s return marker, on the real journal.
///
/// The shipped ``JournalTranscriptHolder`` is a one-line passthrough to ``RecoveryJournal`` and
/// cannot know about test ledgers; the contract test needs the moment `hold` answers recorded
/// beside the moment the store committed. This double mirrors the shipped holder's exact shape
/// (`try await journal.hold(t)`, then answer) and appends the return marker — the
/// `FakeTranscriptHolder`/`RecordingDurableStore` pattern from `HeldTranscriptTests`, moved one
/// level down so the *journal's* ordering is what the ledger asserts, not a fake holder's.
struct LedgerMarkingHolder: TranscriptHolder {
    private let journal: RecoveryJournal
    private let ledger: TranscriptEventLog

    init(journal: RecoveryJournal, ledger: TranscriptEventLog) {
        self.journal = journal
        self.ledger = ledger
    }

    func hold(_ transcript: HeldTranscript) async throws {
        try await journal.hold(transcript)
        await ledger.append(.holdReturned(transcript))
    }

    func current() async -> HeldTranscript? {
        await journal.current()
    }

    func release() async {
        await journal.release()
    }
}

/// **The mutant the ordering check exists to kill, in the journal's own shape**: `hold` answers
/// before the journal's commit has happened.
///
/// The caller cannot see the difference — which is exactly why the ordering is asserted by
/// ledger rather than documented. The check in `RecoveryJournalTests` is only load-bearing
/// because this double fails it.
struct ReturningBeforeCommitHolder: TranscriptHolder {
    private let journal: RecoveryJournal
    private let ledger: TranscriptEventLog

    init(journal: RecoveryJournal, ledger: TranscriptEventLog) {
        self.journal = journal
        self.ledger = ledger
    }

    func hold(_ transcript: HeldTranscript) async throws {
        await ledger.append(.holdReturned(transcript))
        try await journal.hold(transcript)
    }

    func current() async -> HeldTranscript? {
        await journal.current()
    }

    func release() async {
        await journal.release()
    }
}

/// What a journal failure is, for the throw tests. The values are that `hold` throws and the
/// slot stays empty — the specific error is the store's business.
enum JournalTestError: Error {
    /// The crash between temp-write and rename — the save died mid-pair.
    case crashBetweenTempWriteAndRename
    /// The store refused the write outright.
    case storeUnavailable
}
