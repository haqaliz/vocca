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
import VoccaActions
import VoccaCore

// The probe's half of the zero-network invariant for `VoccaActions` — the module the `audit-log`
// aspect creates (`audit-log/spec.md`'s 2026-09-19 amendment).
//
// ## Why this file exists at all
//
// `ZeroNetworkTests` requires the probe's reported module set to **equal** every drivable target
// in the manifest, and a target the package ships as a product cannot be excluded. So a new
// module is not allowed to exist until something proves it does not egress. That is the
// invariant working as designed rather than an obstacle: `VoccaActions` writes files, and file
// I/O is the half of it that could reach a network at all.
//
// It is also the one module in the tree with **no other witness**. Every sibling drive covers a
// module the dictation path already reaches; this one is wired into nothing — deliberately, which
// is what keeps the G5 digest pin untouched — so the drive and the coverage list together are the
// whole of what puts `VoccaActions` inside the invariant.
//
// ## What is driven, and what is not
//
// A **round trip through real bytes**: the real store over a fresh temporary directory, two
// entries committed, a *second* store over the same directory reading them back, then a clear. A
// construct-and-discard drive would satisfy the coverage list while touching no file, which is
// precisely the coverage this module needs.
//
// The decisions are **not hand-built any more**: they come from ``ActionExecutor`` — the one
// caller of ``ActionGate`` in the shipped configuration (`executor` aspect, C13 slice 5) — driven
// through the whole of the surface's round trip: arm (withheld, so a destructive tool stops for
// want of a yes), then grant **with the sentence the arm rendered** (the sentence a human would
// have been shown), which is what turns the second submission into an invocation. That is the
// same path the confirmation card will drive, and it is the point of the change: the executor
// aspect's acceptance 6 asks the probe to prove that path reaches no network name, which a drive
// that kept building decisions directly could not.
//
// Driving the executor costs the widening `ActionSeamBoundaryTests` recorded when the drive
// chose not to conform to the seam: this file now owns a ``ProbeActionProvider``, whose
// signatures name five of the families that lint confines. That is the reviewed trade this
// aspect makes on purpose — a drive whose subject is the executor's path must hold the seam the
// executor submits to, and the lint rows record the cost in the same review that accepted it.
//
// ## What a green PROBE-ACTIONS does NOT prove
//
// It proves that **the audit store** reaches no network name: this store, writing these files,
// under the interposer. It says nothing whatever about a transport the actions layer may later
// acquire. Deviation **D2** measured the limit precisely — `DYLD_INSERT_LIBRARIES` is purged by a
// restricted child, so a stdio MCP server spawned as a subprocess is invisible to the interposer
// for its whole descendant tree, and the failure mode is a *green* suite while a child egresses.
// That is why `transport-prohibition` (PRD M8) exists and why it is not made redundant by this
// drive: the lint refuses the transport at review time, in the module, because this invariant
// cannot see one at run time.
//
// ## The report, and where each field comes from
//
// `store=real recorded=2 reloaded=2 ordinals=1-2 decisions=confirmed,refused binding=matched
// cleared=0` — every field an effect of the run:
//
// - `store` — the shipped store's own type name, so a swapped-in double flips it.
// - `store.location` / `store.isDefaultLocation` — where the drive wrote, the `UsageLedgerDrive`
//   precedent and the standing promise that **no probe run writes to the founder's real
//   `~/Library/Application Support/Vocca/`**. A drive that quietly took the shipped location
//   would fold probe entries into a real install's audit log, and these two fields are what make
//   that an asserted fact rather than a comment.
// - `recorded` — how many commits the store answered without throwing.
// - `reloaded` — how many entries the **second** store found on disk. The equality with
//   `recorded` is the round trip; without it the drive proves the store can be called.
// - `ordinals` — the first and last write ordinals the reader read back, which are rebuilt from
//   the directory rather than from any counter this drive holds.
// - `decisions` — the decisions as the reader decoded them, which is the R8 distinction
//   (confirmed vs refused) surviving the file rather than surviving memory. The refused entry is
//   the arm leg's — the gate stopped a destructive tool for want of a yes, and the stop is
//   recorded like any other decision.
// - `binding` — whether the grant leg carried the arm leg's shown sentence and reached the
//   provider: `matched` means the sentence a human would have seen is the sentence the gate
//   acted on (the N2 binding live in the executor's path), `refused` means the round trip broke.
// - `cleared` — the entries left behind. Zero: the drive does not leave an audit log on the
//   machine that ran it.
extension VoccaNetworkProbe {

    /// One round trip through the audit log, as the post-condition coverage list reads it.
    struct ActionAuditDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String

        /// A type minted **by this drive**, from which `VoccaActions`' name is derived for the
        /// coverage list. Taken from the store this drive constructed and wrote through, so the
        /// entry cannot be kept while the call is deleted — the witness rule every sibling drive
        /// follows.
        let moduleWitness: Any.Type
    }

    /// **Drives a launch-shaped round trip through the audit log, and reports what happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every other
    /// drive gives: an assertion living in the observed process can be deleted by the same edit
    /// that breaks what it observes, and its failure would arrive as an exit status rather than
    /// as a named expectation.
    static func exerciseActionAudit() -> ActionAuditDrive {
        // The `exerciseUsageLedger()` bridge: `main()` is the process entry point and is already
        // on the main thread, so the async work is handed to a Task and the run loop is pumped
        // until it lands — inside the observation window rather than after it.
        let semaphore = DispatchSemaphore(value: 0)
        let box = ActionAuditDriveBox()
        Task {
            box.value = await runActionAuditRoundTrip()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary — the `UsageDriveBox` shape, and
    /// honest for the same reason: written once by the Task and read once after the semaphore.
    private final class ActionAuditDriveBox: @unchecked Sendable {
        var value: ActionAuditDrive?
    }

    /// The probe's own provider — the one tool the probe is allowed to "run", on the probe's own
    /// provider id.
    ///
    /// Its sentence names nothing real, because an entry attributed to a shipped provider would
    /// be indistinguishable from one produced by a process that had actually done something. The
    /// radius is destructive because the round trip needs a tool the gate will stop without a
    /// yes: a read-only tool would auto-run on the arm leg and the refused half of the
    /// `decisions` field would be gone.
    ///
    /// This conformance is the widening the drive's header records: it names
    /// ``ActionProvider``, ``ActionInvocation``, ``ActionSummary``, ``ActionOutcome`` and
    /// ``ActionConfirmation`` — five of the families `ActionSeamBoundaryTests` confines — and
    /// every one of those rows is a reviewed edit in the same review that accepted the executor
    /// as the decision source.
    private struct ProbeActionProvider: ActionProvider {
        let toolIDs = ["probe-tool"]

        func describe(_ invocation: ActionInvocation) async -> ActionSummary {
            ActionSummary(
                sentence: "The probe would run its own tool, which does nothing.",
                blastRadius: .destructive)
        }

        func invoke(_ invocation: ActionInvocation, confirmation: ActionConfirmation) async
            -> ActionOutcome
        {
            .succeeded
        }
    }

    /// The round trip itself: arm, grant with the shown sentence, commit, re-open, read back,
    /// clear.
    private static func runActionAuditRoundTrip() async -> ActionAuditDrive {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-probe-actions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Where a shipped install would have written, resolved the way the app resolves it — so
        // `isDefaultLocation` is a comparison against the real location rather than against a
        // path written out here.
        let defaultLocation = FileSystemActionAuditStore.defaultDirectory(
            applicationSupport: FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first,
            home: FileManager.default.homeDirectoryForCurrentUser)

        let store = FileSystemActionAuditStore(directory: directory)
        let executor = ActionExecutor(provider: ProbeActionProvider(), store: store)

        var recorded = 0
        var binding = "refused"
        if let invocation = ActionInvocation(providerID: "dev.vocca.probe", toolID: "probe-tool") {
            let enablement = ActionEnablement([invocation])

            // Arm: withheld, so the destructive tool stops for want of a yes — and the stop is
            // recorded like any other decision.
            let armed = await executor.submit(
                invocation, enablement: enablement, policy: .none,
                approval: .withheld, approvedSentence: nil, mode: .live)
            if armed.auditRecorded { recorded += 1 }

            // Grant with the shown sentence: the sentence the arm leg rendered is the sentence a
            // human would have been shown, and the grant is bound to exactly that. `binding`
            // reports whether the grant reached the provider — the N2 binding live in the
            // executor's path, observed rather than claimed.
            if let shown = armed.decision.summary?.sentence {
                let granted = await executor.submit(
                    invocation, enablement: enablement, policy: .none,
                    approval: .granted, approvedSentence: shown, mode: .live)
                if granted.auditRecorded { recorded += 1 }
                if granted.decision.reachedTheProvider { binding = "matched" }
            }
        }

        // A second store over the same directory: the reader shares nothing with the writer, so
        // what it returns came off the disk.
        let reader = FileSystemActionAuditStore(directory: directory)
        let reloaded = await reader.load()
        let ordinals = reloaded.map(\.id)
        try? await reader.clear()
        let cleared = await reader.list().count

        let storeName = String(reflecting: type(of: store))
        return ActionAuditDrive(
            report: [
                "store=\(storeName.contains("FileSystemActionAuditStore") ? "real" : "other")",
                "store.location=\(directory.path.hasPrefix(FileManager.default.temporaryDirectory.path) ? "temporary" : "elsewhere")",
                "store.isDefaultLocation=\(directory == defaultLocation)",
                "recorded=\(recorded)",
                "reloaded=\(reloaded.count)",
                "ordinals=\(ordinals.first ?? 0)-\(ordinals.last ?? 0)",
                "decisions=\(reloaded.map(\.decision.rawValue).joined(separator: ","))",
                "binding=\(binding)",
                "cleared=\(cleared)",
            ].joined(separator: " "),
            moduleWitness: type(of: store))
    }
}