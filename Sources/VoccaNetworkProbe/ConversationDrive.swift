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
import VoccaConversation

// The probe's half of the zero-network invariant for `VoccaConversation`, the adapter module
// the `history-store` aspect reserves for the conversation store — and the third instance of
// the D1 rule (`plan_20261011.md`): a module, not a folder in `VoccaBootstrap`, because rooting
// a FileManager seam in the composition root would force permitting `AppBootstrap.swift`.
//
// Adding a `.library` product made `VoccaConversation` a shipping target, which
// `ZeroNetworkTests`' `modulesRequiringCoverage` requires the probe to witness and
// `justifiedExclusions` refuses to let anyone exclude. Phase 1 satisfied that with a scaffold
// drive (the store type constructed, the witness taken from it). This is the real drive: the
// store's launch-shaped round trip, run rather than referenced — a load against a directory
// that does not exist (a first run, the empty history), a record, a **reload through a second
// store over the committed bytes**, and a clear that deletes the file. Everything rides the
// real `ConversationHistoryStore` over the real `DefaultConversationFileSystem`.
//
// ## Where it writes, and why that is not the founder's machine
//
// `ConversationHistoryStore()`'s no-argument initializer points at
// `~/Library/Application Support/Vocca/conversation.json` — a real install's history. **No
// drive here may write there**, so this one is built over a fresh directory under the process's
// temporary directory, removed when the drive returns, and it *reports* both facts
// (`store.location` and `store.isDefaultLocation`) so the evidence is in the line rather than
// in this comment. The round trip is the only conversation file the probe process touches, and
// it is gone before the drive returns.
//
// ## What this drive does not prove
//
// Module granularity: the report says the store ran, not that every branch did — the suite
// (`ConversationHistoryStoreTests`) is where the caps, the truncation and the tolerant decode
// are asserted. And the drive's report prints **counts and booleans only, never the text**:
// the probe's output is a diagnostic, and a conversation store's text has no business in it.

extension VoccaNetworkProbe {

    /// One launch-shaped round trip through the conversation history, and the post-condition the
    /// coverage list reads.
    struct ConversationDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String

        /// A type minted **by this drive**, from which `VoccaConversation`'s name is derived
        /// for the coverage list — the store this drive loaded, recorded and cleared through,
        /// never a type literal.
        let moduleWitness: Any.Type
    }

    /// **Drives a launch-shaped round trip through the conversation history, and reports what
    /// happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every other
    /// drive gives: an assertion living in the observed process can be deleted by the same edit
    /// that breaks what it observes, and its failure would arrive as an exit status rather than
    /// as a named expectation.
    static func exerciseConversation() -> ConversationDrive {
        // The same run-loop-pumped bridge `exerciseUsageLedger()` uses: `main()` is the process
        // entry point and is already on the main thread, so the async work is handed to a Task
        // and the loop is pumped until it lands — inside the observation window rather than
        // after it.
        let semaphore = DispatchSemaphore(value: 0)
        let box = ConversationDriveBox()
        Task {
            box.value = await runConversationRoundTrip()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary — the `UsageDriveBox` shape,
    /// and honest for the same reason: written once by the Task and read once after the
    /// semaphore.
    private final class ConversationDriveBox: @unchecked Sendable {
        var value: ConversationDrive?
    }

    /// The round trip itself.
    private static func runConversationRoundTrip() async -> ConversationDrive {
        // A directory that does not exist yet, under the process's temporary directory. Not
        // created here on purpose: a load against a missing directory is the first-run path, and
        // the store's own persist is what creates it.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "vocca-network-probe-conversation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConversationHistoryStore(directory: directory)
        let fileURL = directory.appendingPathComponent("conversation.json")

        // Where a real install keeps its history, resolved but never touched. Constructing this
        // store performs no I/O — the no-argument initializer only asks `FileManager` for two
        // URLs — and it exists so the drive can *report* that the store it drove is not that one.
        let defaultLocation = await ConversationHistoryStore().directory

        let fileBeforeLoad = FileManager.default.fileExists(atPath: fileURL.path)

        // The launch load, against a first run: no directory, no file. `load()` answers the
        // empty history for both, silently — a first run is not an error.
        let loadedEmpty = await store.load()

        // One real turn, through the real store. The text is the probe's own — never a user's —
        // and it is never printed.
        await store.recordTurn(
            utterance: "probe conversation utterance", reply: "probe conversation reply")
        let recorded = await store.currentTurns()
        let fileAfterRecord = FileManager.default.fileExists(atPath: fileURL.path)

        // **The real load, over real bytes.** A second store, constructed fresh over the same
        // directory, reading back what the first one committed — the launch path of a machine
        // that has conversed before.
        let reloaded = await ConversationHistoryStore(directory: directory).load()

        // The forget path, through the same seam: the file goes.
        try? await store.clear()
        let afterClear = await store.currentTurns()
        let fileAfterClear = FileManager.default.fileExists(atPath: fileURL.path)

        let fields = [
            // Where the drive wrote. Both halves matter: under the temporary directory, and
            // *not* the location a real install keeps its history.
            "store.location=\(directory.path.hasPrefix(FileManager.default.temporaryDirectory.path) ? "temporary" : "elsewhere")",
            "store.isDefaultLocation=\(directory == defaultLocation)",
            // The first run: no file, and the empty history the store answers for one.
            "file.beforeLoad=\(fileBeforeLoad ? "present" : "absent")",
            "load.turns=\(loadedEmpty.count)",
            // The record committed, and the file is on disk.
            "record.turns=\(recorded.count)",
            "file.afterRecord=\(fileAfterRecord ? "present" : "absent")",
            // The round trip: a fresh store loaded the committed bytes and got the turn back —
            // compared as a value, so the report carries no text.
            "reload.turns=\(reloaded.count)",
            "reload.matchesRecorded=\(reloaded == recorded)",
            // The forget path deleted the file and emptied the store.
            "clear.turns=\(afterClear.count)",
            "file.afterClear=\(fileAfterClear ? "present" : "absent")",
        ]

        return ConversationDrive(
            report: fields.joined(separator: " "), moduleWitness: type(of: store))
    }
}