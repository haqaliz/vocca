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
import Synchronization
import VoccaActions
import VoccaCore
import XCTest

/// The executor — the one caller of ``ActionGate/submit(_:to:enablement:policy:approval:mode:approvedSentence:)``
/// in the shipped configuration (`executor` aspect, `action-surface-wiring` C13 slice 5).
///
/// ## Why a caller of the gate has to exist at all
///
/// ``ActionGate`` cannot write the audit store: `VoccaCore` is Foundation-free and the log is a
/// file. Before this aspect, the only witness that connected "submitted through the gate" with
/// "recorded in the store" was the probe, which built audit decisions **directly** — so no shipped
/// code path made the round trip, and R8's acceptance ("every executed action must appear in the
/// audit log, asserted by reconstruction") had a seam with one implementation. The executor is
/// that caller: it submits, and it records every decision the gate returns, including the refusals
/// the log exists to hold.
///
/// ## What is asserted here, and how
///
/// The acceptances are driven **through the executor** against ``RecordingActionProvider`` — the
/// executing stub — rather than by calling the gate and the store separately, for the same reason
/// `ActionAuditStoreTests` drives real submissions: a round trip assembled from both halves in the
/// test would prove the halves work, not that the executor connects them.
///
/// Reconstruction is read back through a **second store** over the same directory, so the first
/// store's memory plays no part — the claim is that the file alone carries the decision.
///
/// ## The two obligations this file pins
///
/// The executor is where the no-dropped-audit-record rule lives: a store that refuses to write is
/// a surfaced `auditRecorded == false` and a loud log, **never a throw** — the action already
/// happened, and failing the turn would lose the record without saving the action. And the
/// approved-sentence obligation: the sentence a caller showed a human is passed to the gate
/// verbatim, so an approval cannot be replayed against a sentence nobody saw (the N2 binding's
/// caller side), asserted by attempting the call and reading the refusal.
final class ActionExecutorTests: XCTestCase {

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-action-executor-\(UUID().uuidString)")
    }

    private func makeInvocation(
        providerID: String = "dev.vocca.executor", toolID: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(providerID: providerID, toolID: toolID),
            "a non-empty provider id and tool id must construct an invocation", file: file,
            line: line)
    }

    /// The sentence the stub's `describe` renders — written out **here** rather than read from the
    /// stub, so a test that agrees with the gate by construction proves nothing
    /// (`ActionGateSentenceBindingTests`' convention).
    private func stubSentence(for invocation: ActionInvocation) -> String {
        "Stub would run \(invocation.toolID) on \(invocation.providerID)."
    }

    /// The declined-without-describe keys, spelled out so the reconstruction assertions pin the
    /// audit vocabulary rather than deriving it.
    private let toolNotEnabledKey = "gate.toolNotEnabled"
    private let approvedSentenceMismatchKey = "gate.approvedSentenceMismatch"

    // MARK: - 1 + 2. Every decision class records exactly one reconstructable entry

    /// **Every decision class the gate can produce records exactly one entry, and a second store
    /// over the same directory reconstructs each decision from the entry fields.**
    ///
    /// Five submissions through the executor, covering the whole of ``ActionDecision``: a read-only
    /// tool that auto-ran, a destructive one that ran on a confirmed approval, a tool that was
    /// declined for want of enablement (never described), a granted approval whose sentence no
    /// longer matches, and a dry-run — the full ``ActionAuditDecision`` vocabulary
    /// (`autoRanReadOnly` / `confirmed` / `refused` × 2 / `dryRun`).
    ///
    /// The reconstruction claim is the same one `ActionAuditStoreTests` makes, now through the
    /// executor: the reloaded entries carry the provider and tool ids, the decision class, the
    /// bounded summary (the sentence, or the decline key where nothing was described), the radius
    /// the gate acted on (or `nil` where nothing was ever described) and the outcome.
    func testEveryDecisionClassRecordsExactlyOneReconstructableEntry() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let listFiles = try makeInvocation(toolID: "list-files")
        let deleteDownloads = try makeInvocation(toolID: "delete-downloads")

        let store = FileSystemActionAuditStore(directory: directory)

        // 1. autoRanReadOnly: read-only needs no confirmation, so it ran without a human.
        let readOnlyProvider = RecordingActionProvider(
            toolIDs: ["list-files"], describedRadius: .readOnly)
        let readOnlyExecutor = ActionExecutor(provider: readOnlyProvider, store: store)
        let autoRan = await readOnlyExecutor.submit(
            listFiles,
            enablement: ActionEnablement([listFiles]), policy: .none,
            approval: .withheld, approvedSentence: nil, mode: .live)

        // 2. confirmed: destructive needs a yes, and had one — bound to the shown sentence.
        let destructiveProvider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive)
        let destructiveExecutor = ActionExecutor(provider: destructiveProvider, store: store)
        let confirmed = await destructiveExecutor.submit(
            deleteDownloads,
            enablement: ActionEnablement([deleteDownloads]), policy: .none,
            approval: .granted, approvedSentence: stubSentence(for: deleteDownloads),
            mode: .live)

        // 3. refused — toolNotEnabled: absent enablement is off, and the tool is never described.
        let disabledProvider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive)
        let disabledExecutor = ActionExecutor(provider: disabledProvider, store: store)
        let declined = await disabledExecutor.submit(
            deleteDownloads,
            enablement: ActionEnablement(), policy: .none,
            approval: .withheld, approvedSentence: nil, mode: .live)

        // 4. refused — approvedSentenceMismatch: the approval was bound to a sentence the gate no
        //    longer renders, so it cannot be replayed against this submission.
        let mismatchedProvider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive)
        let mismatchedExecutor = ActionExecutor(provider: mismatchedProvider, store: store)
        let mismatched = await mismatchedExecutor.submit(
            deleteDownloads,
            enablement: ActionEnablement([deleteDownloads]), policy: .none,
            approval: .granted, approvedSentence: "Delete 3 files in ~/Downloads.",
            mode: .live)

        // 5. dryRun: a rehearsal stops before the acting half, approved or not.
        let dryRunProvider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive)
        let dryRunExecutor = ActionExecutor(provider: dryRunProvider, store: store)
        let previewed = await dryRunExecutor.submit(
            deleteDownloads,
            enablement: ActionEnablement([deleteDownloads]), policy: .none,
            approval: .granted, approvedSentence: stubSentence(for: deleteDownloads),
            mode: .dryRun)

        // Every decision was recorded — including the two refusals, which are events the log
        // exists to hold rather than absences of one.
        for (label, result) in [
            ("autoRan", autoRan), ("confirmed", confirmed), ("declined", declined),
            ("mismatched", mismatched), ("previewed", previewed),
        ] {
            XCTAssertTrue(
                result.auditRecorded, "\(label): the decision must be recorded — a gate decision "
                    + "that reaches no file is the seam's one real silence")
        }

        // The reconstruction: a second store over the same directory reads what the first wrote.
        let reader = FileSystemActionAuditStore(directory: directory)
        let reloaded = await reader.load()
        XCTAssertEqual(
            reloaded.count, 5,
            "exactly one entry per submission — the executor must not drop, duplicate or merge "
                + "decisions")

        let autoRanEntry = try XCTUnwrap(reloaded[safe: 0])
        XCTAssertEqual(autoRanEntry.providerID, "dev.vocca.executor")
        XCTAssertEqual(autoRanEntry.toolID, "list-files")
        XCTAssertEqual(autoRanEntry.decision, .autoRanReadOnly)
        XCTAssertEqual(autoRanEntry.summary, stubSentence(for: listFiles))
        XCTAssertEqual(autoRanEntry.blastRadius, .readOnly)
        XCTAssertEqual(autoRanEntry.outcome, .succeeded)
        XCTAssertTrue(autoRan.decision.reachedTheProvider, "vacuity guard: the read-only leg really ran")

        let confirmedEntry = try XCTUnwrap(reloaded[safe: 1])
        XCTAssertEqual(confirmedEntry.decision, .confirmed)
        XCTAssertEqual(confirmedEntry.summary, stubSentence(for: deleteDownloads))
        XCTAssertEqual(confirmedEntry.blastRadius, .destructive)
        XCTAssertEqual(confirmedEntry.outcome, .succeeded)
        XCTAssertTrue(confirmed.decision.reachedTheProvider, "vacuity guard: the confirmed leg really ran")

        let declinedEntry = try XCTUnwrap(reloaded[safe: 2])
        XCTAssertEqual(declinedEntry.decision, .refused)
        XCTAssertEqual(
            declinedEntry.summary, toolNotEnabledKey,
            "an action declined before anything was described records the bounded decline key in "
                + "the sentence's place")
        XCTAssertNil(
            declinedEntry.blastRadius,
            "nothing was described, so no radius was ever classified — a fabricated readOnly "
                + "would be the dangerous value to invent")
        XCTAssertEqual(declinedEntry.outcome, .notInvoked)
        XCTAssertFalse(declined.decision.reachedTheProvider)
        XCTAssertEqual(
            disabledProvider.describeCount, 0,
            "the never-read property held on the executor's path too: an unenabled tool is not "
                + "asked what it would do")

        let mismatchedEntry = try XCTUnwrap(reloaded[safe: 3])
        XCTAssertEqual(mismatchedEntry.decision, .refused)
        XCTAssertEqual(mismatchedEntry.summary, approvedSentenceMismatchKey)
        XCTAssertNil(mismatchedEntry.blastRadius)
        XCTAssertEqual(mismatchedEntry.outcome, .notInvoked)
        XCTAssertFalse(mismatched.decision.reachedTheProvider)
        XCTAssertEqual(mismatchedProvider.invokeCount, 0)
        XCTAssertEqual(
            mismatchedProvider.describeCount, 1,
            "the binding compared against the decision's own freshly-rendered sentence — the "
                + "mismatch cost one describe and no extra provider calls")

        let previewedEntry = try XCTUnwrap(reloaded[safe: 4])
        XCTAssertEqual(previewedEntry.decision, .dryRun)
        XCTAssertEqual(previewedEntry.summary, stubSentence(for: deleteDownloads))
        XCTAssertEqual(previewedEntry.blastRadius, .destructive)
        XCTAssertEqual(previewedEntry.outcome, .notInvoked)
        XCTAssertFalse(previewed.decision.reachedTheProvider)
        XCTAssertEqual(dryRunProvider.invokeCount, 0, "a rehearsal never reaches the acting half")
    }

    // MARK: - 3. Recording failure is surfaced, never thrown

    /// **A store whose commit throws yields `auditRecorded == false`, a loud log, and the
    /// decision still returns — nothing throws through.**
    ///
    /// The no-dropped-audit-record rule is about the surface being **honest** about a failed
    /// record, not about failing the action: the gate already ran the provider by the time the
    /// record is attempted, and throwing would lose the record without undoing the action.
    /// Injected via the file-system seam (`UncreatableDirectoryActionAuditFileSystem`), so the
    /// failure is real rather than simulated in the executor.
    func testARecordingFailureSurfacesAuditRecordedFalseAndTheDecisionStands() async throws {
        let directory = Self.tempDirectory()
        let invocation = try makeInvocation(toolID: "delete-downloads")
        let recorder = ExecutorLogRecorder()
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive)
        let store = FileSystemActionAuditStore(
            directory: directory, fileSystem: UncreatableDirectoryActionAuditFileSystem())
        let executor = ActionExecutor(provider: provider, store: store, log: recorder.log)

        let result = await executor.submit(
            invocation,
            enablement: ActionEnablement([invocation]), policy: .none,
            approval: .granted, approvedSentence: stubSentence(for: invocation), mode: .live)

        XCTAssertEqual(
            result.decision,
            .invoked(
                summary: ActionSummary(
                    sentence: stubSentence(for: invocation), blastRadius: .destructive),
                outcome: .succeeded),
            "the decision stands — the gate's answer does not depend on the store accepting it")
        XCTAssertEqual(
            result.auditRecorded, false,
            "the surface must say the record failed — a caller that cannot tell will report a "
                + "clean history of an action that happened")
        XCTAssertEqual(
            recorder.recorded.count, 1,
            "the failure was logged loudly — the injected log is the loud half, asserted rather "
                + "than hoped")
        XCTAssertTrue(
            recorder.recorded.first?.contains("record") ?? false,
            "the log names the failure that happened, not a generic line")
        XCTAssertEqual(
            provider.invokeCount, 1,
            "the action already happened by the time the record failed — the failure is a lost "
                + "record, never an unrun action")
    }

    // MARK: - 4. The submitted approved sentence reaches the gate

    /// **The executor's `approvedSentence` parameter is the gate's binding, live — a sentence
    /// that differs from what the gate renders is refused, by attempting the call.**
    ///
    /// The executor accepts the sentence the caller **showed a human** and hands it to the gate
    /// verbatim (the N2 binding's caller-side obligation). If the executor dropped the sentence,
    /// the grant would proceed against whatever the gate renders now — replaying the approval
    /// against a different action. The stub is in fail-if-invoked mode, so a regression fails at
    /// the violation rather than at the assertion afterwards. The refusal is recorded like every
    /// other decision: the entry says why, in the bounded vocabulary.
    func testTheSubmittedApprovedSentenceReachesTheGateAndAMismatchIsRefused() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let invocation = try makeInvocation(toolID: "delete-downloads")
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive,
            behavior: .failsTheTestIfInvoked)
        let store = FileSystemActionAuditStore(directory: directory)
        let executor = ActionExecutor(provider: provider, store: store)

        let result = await executor.submit(
            invocation,
            enablement: ActionEnablement([invocation]), policy: .none,
            approval: .granted, approvedSentence: "Delete 3 files in ~/Downloads.",
            mode: .live)

        XCTAssertEqual(
            result.decision, .declined(.approvedSentenceMismatch),
            "a granted approval bound to a sentence the gate no longer renders must come back "
                + "declined — the binding travelled through the executor, not past it")
        XCTAssertEqual(
            result.auditRecorded, true,
            "a refusal is a decision the log exists to hold — dropping it would hide every "
                + "stopped action from the audit")
        XCTAssertFalse(result.decision.reachedTheProvider)
        XCTAssertEqual(provider.invokeCount, 0)
        XCTAssertEqual(provider.executionCount, 0)

        let reloaded = await FileSystemActionAuditStore(directory: directory).load()
        let entry = try XCTUnwrap(reloaded.first)
        XCTAssertEqual(reloaded.count, 1, "exactly one entry for the one submission")
        XCTAssertEqual(entry.decision, .refused)
        XCTAssertEqual(entry.summary, approvedSentenceMismatchKey)
        XCTAssertNil(entry.blastRadius)
        XCTAssertEqual(entry.outcome, .notInvoked)
    }

    // MARK: - 5. Dry-run records dryRun and invokes zero times

    /// **`mode: .dryRun` through the executor records `dryRun` and calls `invoke` zero times** —
    /// asserted on the stub's call log, the number the dry-run acceptance reads (PRD M5/G2).
    ///
    /// The submission is granted and bound to the matching sentence, so a dry-run that reached
    /// the acting half would have had every permission it needed — only the mode stopped it,
    /// which is the claim being made.
    func testADryRunRecordsDryRunAndInvokesZeroTimes() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let invocation = try makeInvocation(toolID: "delete-downloads")
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive)
        let store = FileSystemActionAuditStore(directory: directory)
        let executor = ActionExecutor(provider: provider, store: store)

        let result = await executor.submit(
            invocation,
            enablement: ActionEnablement([invocation]), policy: .none,
            approval: .granted, approvedSentence: stubSentence(for: invocation),
            mode: .dryRun)

        XCTAssertEqual(
            result.decision,
            .previewed(
                ActionSummary(
                    sentence: stubSentence(for: invocation), blastRadius: .destructive)),
            "a dry-run describes and stops — the acting half was not reached")
        XCTAssertEqual(result.auditRecorded, true, "the rehearsal is recorded like every decision")
        XCTAssertEqual(
            provider.invokeCount, 0,
            "the number the acceptance reads: dry-run is allowed to describe, never to invoke")
        XCTAssertEqual(provider.describeCount, 1, "a preview that could not render would have "
            + "nothing to preview")
        XCTAssertEqual(provider.executionCount, 0)

        let reloaded = await FileSystemActionAuditStore(directory: directory).load()
        let entry = try XCTUnwrap(reloaded.first)
        XCTAssertEqual(reloaded.count, 1, "exactly one entry for the one submission")
        XCTAssertEqual(entry.decision, .dryRun)
        XCTAssertEqual(entry.summary, stubSentence(for: invocation))
        XCTAssertEqual(entry.blastRadius, .destructive)
        XCTAssertEqual(entry.outcome, .notInvoked)
    }

    // MARK: - 7. The executor names no transport or subprocess family

    /// **The executor's own file names none of the forbidden transport families** — the module
    /// lints stay green (`ActionTransportProhibitionTests`, deviation D2: the interposer follows
    /// a socket and goes blind through a child, so `VoccaActions` may name neither).
    ///
    /// The module-wide lint already scans every file under `VoccaActions/`; this is the
    /// per-file reading of the same detector against the file this aspect ships, so acceptance 7
    /// is a named assertion in this suite rather than only an inherited property.
    func testTheExecutorFileNamesNoTransportOrSubprocessFamily() throws {
        let packageRoot = try PackageRootLocator.find(from: #filePath)
        let url = packageRoot.appendingPathComponent("Sources/VoccaActions/ActionExecutor.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            source.contains("ActionExecutor"),
            "the executor file must still exist and name its subject — otherwise this test "
                + "watches nothing")
        XCTAssertEqual(
            ActionTransportProhibitionTests.transportIdentifiers(inSource: source), [],
            "the executor must not name URLSession, NW, Network, Process, posix_spawn, NSTask or "
                + "system — a caller of the gate that can open a socket or spawn a child is the "
                + "one file this module may not contain")
    }
}

// MARK: - Test doubles

/// A recorder for the executor's injected log — the loud half of the recording-failure policy,
/// made observable so that "the failure is logged loudly" is asserted rather than hoped
/// (`ActionAuditStoreTests`' `ComplaintRecorder` shape).
private final class ExecutorLogRecorder: Sendable {
    private let messages = Mutex<[String]>([])

    var recorded: [String] { messages.withLock { $0 } }

    /// Captures `self` rather than the lock: `Mutex` is noncopyable, so it cannot be lifted into
    /// a local for the closure to hold.
    var log: @Sendable (String) -> Void {
        { message in self.messages.withLock { $0.append(message) } }
    }
}

// MARK: - Bounds

private extension Array {
    /// The element at `index`, or `nil` — so a reconstruction loop can `XCTUnwrap` each entry
    /// and name which one is missing instead of crashing on a short array.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}