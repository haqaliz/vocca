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
import VoccaCore
import VoccaUsage

// The probe's half of the zero-network invariant for `VoccaUsage`, and the discharge of the debt
// `usage-store` recorded against itself.
//
// Adding a `.library` product made `VoccaUsage` a shipping target, which `ZeroNetworkTests`'
// `modulesRequiringCoverage` requires the probe to witness and `justifiedExclusions` refuses to let
// anyone exclude. With no format yet, `usage-store` Phase 1 satisfied that with a metatype
// reference — `PersistentUsageStore.self` sitting in the probe's module list beside the remaining
// placeholders. **That was bookkeeping, not proof.** A reference says the module was *reached*; it
// says nothing about whether the module opens a socket, which is the only question this invariant
// asks. Every other drive in this directory is written under an effect-not-reference rule, and that
// entry was the one exception to it.
//
// There is a real effect now. `usage-wiring` gave the ledger a launch-time load, a fold per
// finalized session and a write cadence, so this file runs them: the real `PersistentUsageStore`
// over the real `DefaultUsageFileSystem`, the real `SystemCalendarDayProvider`, the real
// `UsageRecorder`, and the real `LatencyLedger` sink that carries a finalized record between them.
// The load is exercised twice — once against a directory that does not exist (a first run, the
// empty window) and once against bytes this drive itself committed (the round trip) — and the
// report is what `ZeroNetworkTests` asserts. Deleting the call takes the whole line with it and the
// suite fails by name, which is exactly what a metatype literal could not do.
//
// ## Where it writes, and why that is not the founder's machine
//
// `PersistentUsageStore()`'s no-argument initializer points at
// `~/Library/Application Support/Vocca/usage.json` — a real install's history. **No drive here may
// write there**, so this one is built over a fresh directory under the process's temporary
// directory, removed when the drive returns, and it *reports* both facts (`store.location` and
// `store.isDefaultLocation`) so the suite pins them rather than trusting this comment. The one
// default-located store the probe process does construct is `AppBootstrap.configure`'s own, whose
// launch load is read-only by construction (`PersistentUsageStore.load()`: "Never throws and never
// writes"); nothing folds into that recorder in the probe, so its cadence never has anything
// unwritten to persist.

extension VoccaNetworkProbe {

    /// One launch-shaped round trip through the daily-use ledger, and the post-condition the suite
    /// asserts.
    struct UsageDrive {
        /// The observation, as one line of `key=value` fields. Asserted whole — see
        /// `ZeroNetworkTests.expectedUsageLedgerLifecycle`.
        let report: String

        /// A type minted **by this drive**, from which `VoccaUsage`'s name is derived for the
        /// coverage list.
        ///
        /// This is the line that replaces `PersistentUsageStore.self`. That literal satisfied the
        /// coverage guard whether or not a single line of `VoccaUsage` ever ran; a witness taken
        /// from the store this drive constructed and loaded through cannot be kept while the call
        /// is deleted.
        let moduleWitness: Any.Type
    }

    /// The engine attribution the drive files its one session under.
    ///
    /// The probe's own name, not a shipped engine's: a record attributed to Parakeet would be
    /// indistinguishable from one produced by a process that had just fetched a model, which is
    /// the opposite of what this invariant is for.
    static let usageProbeEngine = EngineIdentity(
        id: "probe-usage-engine", displayName: "Probe Usage Engine", isLocal: true)

    /// The span the drive's record carries. One is enough — the ledger's histogram is not what is
    /// under test here, the file system's silence is — and a fixed `Duration` keeps the reported
    /// line a constant rather than a measurement.
    static let usageProbeSpan: Duration = .milliseconds(120)

    /// **Drives a launch-shaped round trip through the daily-use ledger, and reports what
    /// happened.**
    ///
    /// First run → load (no directory, no file: the empty window) → a finalized record delivered by
    /// the real `LatencyLedger` sink → fold → the cadence declining to write → termination's flush →
    /// a *second* store over the same directory loading the committed bytes back.
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every other
    /// drive gives: an assertion living in the observed process can be deleted by the same edit
    /// that breaks what it observes, and its failure would arrive as an exit status rather than as
    /// a named expectation.
    static func exerciseUsageLedger() -> UsageDrive {
        // The same run-loop-pumped bridge `exerciseDictationCycle()` uses: `main()` is the process
        // entry point and is already on the main thread, so the async work is handed to a Task and
        // the loop is pumped until it lands — inside the observation window rather than after it.
        let semaphore = DispatchSemaphore(value: 0)
        let box = UsageDriveBox()
        Task {
            box.value = await runUsageLedgerRoundTrip()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary — the `CycleDriveBox` shape, and
    /// honest for the same reason: written once by the Task and read once after the semaphore.
    private final class UsageDriveBox: @unchecked Sendable {
        var value: UsageDrive?
    }

    /// Carries the record the ledger's sink delivered, out of the `@Sendable` closure.
    ///
    /// The sink runs **synchronously inside `finalize`** (`LatencyLedger.swift`: last, once the
    /// record is complete and appended), so this box is written on the same task that awaits the
    /// finalize and read after it returns. That ordering is what lets the drive fold and flush in a
    /// stated order instead of racing a detached task — the composition's `Task { … }` wrapper is
    /// `AppBootstrap`'s concern, and what is under test here is `VoccaUsage`.
    private final class SinkBox: @unchecked Sendable {
        var records: [SessionRecord] = []
    }

    /// The clock the recorder's debounce is measured against.
    ///
    /// Probe-local rather than the shipped `ContinuousMonotonicClock`, which lives in `VoccaASR` —
    /// importing the ASR module into the ledger's drive would tie this file to a module it has
    /// nothing to do with. It is a *real, advancing* monotonic clock and not a frozen one, so the
    /// cadence below declines to write because seconds have not passed rather than because time
    /// stopped: a stalled clock would make `file.afterFold=absent` true for the wrong reason.
    private struct UsageProbeClock: MonotonicClock, Sendable {
        private let origin = ContinuousClock().now
        var now: Duration { ContinuousClock().now - origin }
    }

    /// The round trip itself.
    private static func runUsageLedgerRoundTrip() async -> UsageDrive {
        // A directory that does not exist yet, under the process's temporary directory. Not
        // created here on purpose: a load against a missing directory is the first-run path, and
        // the store's own `save()` is what creates it.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "vocca-network-probe-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistentUsageStore(directory: directory)
        let fileURL = directory.appendingPathComponent("usage.json")

        // Where a real install keeps its history, resolved but never touched. Constructing this
        // store performs no I/O — the no-argument initializer only asks `FileManager` for two URLs —
        // and it exists so the drive can *report* that the store it drove is not that one. The
        // alternative is a comment promising it, which is the shape this whole file is replacing.
        let defaultLocation = await PersistentUsageStore().directory

        let day = SystemCalendarDayProvider()
        let recorder = UsageRecorder(
            store: store, day: day.provider, clock: UsageProbeClock())

        let fileBeforeLoad = FileManager.default.fileExists(atPath: fileURL.path)

        // The launch load, against a first run: no directory, no file. `load()` answers the empty
        // window for both, silently — a first run is not an error.
        await recorder.load()
        let daysAfterLoad = await recorder.currentWindow.days.count

        // The composition's seam, run rather than described: a real `LatencyLedger` with a sink,
        // and the record the sink carries is the one that gets folded.
        let sink = SinkBox()
        let ledger = LatencyLedger(sink: { record in sink.records.append(record) })
        let id = await ledger.beginSession()
        _ = await ledger.recordSpan(
            .recorded(name: .asr, elapsed: usageProbeSpan), for: id)
        let finalized = await ledger.finalize(
            id: id,
            outcome: .delivered(rung: .clipboardPaste, verified: true),
            engine: usageProbeEngine,
            kind: .dictation)

        for record in sink.records {
            await recorder.fold(record)
        }
        // Read here rather than after the write, so the day this drive compares against is the one
        // the fold resolved a moment earlier and not one a midnight crossed in between.
        let today = day.today()
        // The cadence, asked and expected to decline: one fold, seconds into the run, is neither a
        // rollover nor a `writeInterval` elapsed. The file's absence below is the effect that says
        // so — the probe's own echo of `UsageRecorderTests`' D3.
        await recorder.flushIfDue()
        let sessionsAfterFold = await recorder.currentWindow.days.first?.sessionCount ?? 0
        let fileAfterFold = FileManager.default.fileExists(atPath: fileURL.path)

        // Termination's write, the `AppBootstrap.main()` hook's half: whatever is unwritten goes
        // now, because there is no next tick.
        await recorder.flush()
        let fileAfterFlush = FileManager.default.fileExists(atPath: fileURL.path)

        // **The real load, over real bytes.** A second store, constructed fresh over the same
        // directory, reading back what the first one committed — the launch path of a machine that
        // has dictated before, which is the effect the metatype reference stood in for.
        let reloaded = await PersistentUsageStore(directory: directory).load()
        let reloadedDay = reloaded.days.first

        let fields = [
            // Where the drive wrote. Both halves matter: under the temporary directory, and *not*
            // the location a real install keeps its history.
            "store.location=\(directory.path.hasPrefix(FileManager.default.temporaryDirectory.path) ? "temporary" : "elsewhere")",
            "store.isDefaultLocation=\(directory == defaultLocation)",
            // The first run: no file, and the empty window the store answers for one.
            "file.beforeLoad=\(fileBeforeLoad ? "present" : "absent")",
            "load.days=\(daysAfterLoad)",
            // The ledger's sink delivered the finalized record — the seam the composition installs.
            "finalized=\(finalized)",
            "sink.records=\(sink.records.count)",
            // The fold landed, and the file system stayed silent for it.
            "fold.sessions=\(sessionsAfterFold)",
            "file.afterFold=\(fileAfterFold ? "present" : "absent")",
            // Termination wrote.
            "file.afterFlush=\(fileAfterFlush ? "present" : "absent")",
            // The round trip: a fresh store loaded the committed bytes and got the session back,
            // with its outcome, its rung and the day the provider named.
            "reload.days=\(reloaded.days.count)",
            "reload.sessions=\(reloadedDay?.sessionCount ?? 0)",
            "reload.delivered=\(reloadedDay?.realWork.delivered ?? 0)",
            "reload.clipboardPaste=\(reloadedDay?.realWork.deliveries(via: .clipboardPaste) ?? 0)",
            "reload.dayMatchesProvider=\(reloadedDay.map { $0.day == today } ?? false)",
        ]

        return UsageDrive(
            report: fields.joined(separator: " "), moduleWitness: type(of: store))
    }
}
