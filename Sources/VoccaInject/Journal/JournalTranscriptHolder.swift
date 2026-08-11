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

/// The recovery journal behind the core's ``TranscriptHolder`` seam — the failsafe rung's
/// durable custody, offered to the ladder and the window in the core's own vocabulary.
///
/// `VoccaUI` imports only `VoccaCore`, so the FAILSAFE window can never see the journal; it
/// speaks to this type only through the seam it implements — hold, current, release, and
/// nothing else. This file is the seam's one conformance, glue with no decisions in it: the
/// durability ordering (R6), the bounded eviction and the purge-on-resolve are all
/// ``RecoveryJournal``'s, and the file system is ``FileSystemJournalStore``'s one-file concern.
public actor JournalTranscriptHolder: TranscriptHolder {
    private let journal: RecoveryJournal

    /// A holder over `journal` — the composition root's construction: a journal over the
    /// default store, handed to the ladder for holds and to the window for reads.
    public init(journal: RecoveryJournal) {
        self.journal = journal
    }

    /// Durably holds `transcript` — awaits the journal's write before answering (PRD R6: the
    /// write is part of the hand-off, not after it). Throws when it cannot be made so.
    public func hold(_ transcript: HeldTranscript) async throws {
        try await journal.hold(transcript)
    }

    /// The currently held transcript — the newest held entry — or `nil` when nothing is held.
    public func current() async -> HeldTranscript? {
        await journal.current()
    }

    /// Releases the held transcript — the user copied it, a retry delivered it, or they
    /// dismissed it. Purges the held entry; a no-op when nothing is held.
    public func release() async {
        await journal.release()
    }
}
