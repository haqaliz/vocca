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
import VoccaASR
import VoccaBootstrap
import VoccaCore
import VoccaHotkey
import VoccaInject
import VoccaUI

// The probe's half of the zero-network invariant for `VoccaActions` — the module the `audit-log`
// aspect creates (`audit-log/spec.md`'s 2026-09-19 amendment), and the wiring aspect's close:
// **the drive now runs the composed action recipe** (`composeActionWiring`) over real
// temp-directory stores — the same composition `AppBootstrap.configure` makes — driven once
// under the interposer.
//
// ## Why this file exists at all
//
// `ZeroNetworkTests` requires the probe's reported module set to **equal** every drivable target
// in the manifest, and a target the package ships as a product cannot be excluded. So a new
// module is not allowed to exist until something proves it does not egress. That is the
// invariant working as designed rather than an obstacle: `VoccaActions` writes files, and file
// I/O is the half of it that could reach a network at all.
//
// It is also the one module in the tree with **no other witness on the dictation path**. Every
// sibling drive covers a module the dictation path already reaches; this one is wired into
// nothing except the composition this drive drives — so the drive and the coverage list together
// are the whole of what puts `VoccaActions` inside the invariant.
//
// ## What is driven, and what is not
//
// **The composed recipe's round trip through real bytes**: the real `AuditActionProvider` over
// the real store, the real config store, a real root over probe fakes for the widget folds, and
// the wiring's own arm/confirm/decline closures. Arm `audit.clear` (the sentence on the widget
// card), let the count drift, confirm — the gate's fresh render differs, the wiring re-presents a
// fresh card (the binding-mismatch re-prompt) — confirm the fresh card, the clear runs, and the
// clear's own record reconstructs. The composed default's facts (`servers=0`,
// `spawnsSubprocess=false`) ride the same report: the D2 narrowed promise, reported rather than
// commented.
//
// The **seed leg** keeps the drive's own `ProbeActionProvider` — the one tool the probe is
// allowed to "run", the log's content the real provider's sentence will name, and the
// `ActionSeamBoundaryTests` widening the executor aspect recorded (the drive names the five
// families its conformance's signatures force; that is the reviewed trade the aspect made on
// purpose, and it is unchanged by this aspect). The seed submissions are **withheld** — the
// destructive tool stops for want of a yes, recorded like any other decision.
//
// A construct-and-discard drive would satisfy the coverage list while touching no file, which is
// precisely the coverage this module needs; a drive that built decisions by hand would prove
// nothing about the shipped composition. This one runs the shipped recipe.
//
// ## What a green PROBE-ACTIONS does NOT prove
//
// It proves that **the audit store and the composed recipe** reach no network name: this store,
// writing these files, under the interposer. It says nothing whatever about a transport the
// actions layer may later acquire. Deviation **D2** measured the limit precisely —
// `DYLD_INSERT_LIBRARIES` is purged by a restricted child, so a stdio MCP server spawned as a
// subprocess is invisible to the interposer for its whole descendant tree, and the failure mode
// is a *green* suite while a child egresses. That is why `transport-prohibition` (PRD M8) exists
// and why it is not made redundant by this drive: the lint refuses the transport at review time,
// in the module, because this invariant cannot see one at run time. The wiring's own `discover`
// refuses by design — the spawn is a later slice's reviewed move — and `spawnsSubprocess=false`
// is the composed default's declared fact.
//
// ## The report, and where each field comes from
//
// `store=real store.location=temporary store.isDefaultLocation=false servers=0
// spawnsSubprocess=false recorded=5 reloaded=1 ordinals=1-1 decisions=confirmed binding=matched
// mismatch=reprompted cleared=0` — every field an effect of the run:
//
// - `store` — the shipped store's own type name, so a swapped-in double flips it.
// - `store.location` / `store.isDefaultLocation` — where the drive wrote, the `UsageLedgerDrive`
//   precedent and the standing promise that **no probe run writes to the founder's real
//   `~/Library/Application Support/Vocca/`**.
// - `servers` — the composed config store's own answer, read through the wiring's `loadConfig`
//   (a fresh directory answers the empty config: no server is configured out of the box, D2).
// - `spawnsSubprocess` — the wiring's declared fact: the composed default cannot create a child.
// - `recorded` — the audit log's peak before the clear: two seed stops, the arm's stop, the
//   drift entry, the mismatch's declined decision. The clear then wipes them all — which is the
//   real `audit.clear` running, and why the count is a peak rather than a running total.
// - `reloaded` — how many entries the **second** store found on disk after the clear. The
//   equality with the confirmed entry is the reconstruct: the clear is itself auditable, the
//   record lands after it, and exactly one entry survives.
// - `ordinals` — the write ordinals the reader read back, rebuilt from the directory.
// - `decisions` — the decisions as the reader decoded them: the invoked action reconstructs as
//   `confirmed`, the R8 distinction surviving the file rather than surviving memory.
// - `binding` — whether the final confirm carried the re-prompted card's shown sentence and
//   reached the provider: `matched` means the sentence a human would have seen is the sentence
//   the gate acted on (the N2 binding live in the wiring's path).
// - `mismatch` — whether the binding actually refused once: the drift between the first card and
//   the confirm made the gate render a different sentence, and the wiring re-prompted — the
//   refusal path observed rather than assumed.
// - `cleared` — the entries left behind. Zero: the drive does not leave an audit log on the
//   machine that ran it.
extension VoccaNetworkProbe {

    /// One round trip through the composed action recipe, as the post-condition coverage list
    /// reads it.
    struct ActionAuditDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String

        /// A type minted **by this drive**, from which `VoccaActions`' name is derived for the
        /// coverage list. Taken from the store this drive constructed and wrote through, so the
        /// entry cannot be kept while the call is deleted — the witness rule every sibling drive
        /// follows.
        let moduleWitness: Any.Type
    }

    /// **Drives a launch-shaped round trip through the composed action recipe, and reports what
    /// happened.**
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
        Task { @MainActor in
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
    /// radius is destructive because the seed leg needs tools the gate will stop without a yes:
    /// the withheld submissions record refusals, which are the log's content the real provider's
    /// sentence will name.
    ///
    /// This conformance is the widening `ActionSeamBoundaryTests` records: it names
    /// ``ActionProvider``, ``ActionInvocation``, ``ActionSummary``, ``ActionOutcome`` and
    /// ``ActionConfirmation`` — five of the families the lint confines — and every one of those
    /// rows is a reviewed edit in the same review that accepted the executor as the decision
    /// source. The wiring aspect leaves the widening in place: the drive still owns a provider,
    /// because the seed leg still needs one.
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

    /// The round trip itself: the seed leg, the composed recipe's arm → mismatch re-prompt →
    /// confirm → invoke → reconstruct, the facts, the re-open, the read-back, the clear.
    @MainActor
    private static func runActionAuditRoundTrip() async -> ActionAuditDrive {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-probe-actions-\(UUID().uuidString)")
        let configDirectory = base.appendingPathComponent("config")
        let auditDirectory = base.appendingPathComponent("audit")
        defer { try? FileManager.default.removeItem(at: base) }

        // Where a shipped install would have written, resolved the way the app resolves it — so
        // `isDefaultLocation` is a comparison against the real location rather than against a
        // path written out here.
        let defaultLocation = FileSystemActionAuditStore.defaultDirectory(
            applicationSupport: FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first,
            home: FileManager.default.homeDirectoryForCurrentUser)

        let configStore = ActionConfigStore(directory: configDirectory)
        let auditStore = FileSystemActionAuditStore(directory: auditDirectory)
        let probeExecutor = ActionExecutor(provider: ProbeActionProvider(), store: auditStore)

        var recorded = 0

        // The seed leg — two withheld stops over the probe provider, recorded like any other
        // decision: the log's content the real provider's sentence will name.
        if let invocation = ActionInvocation(providerID: "dev.vocca.probe", toolID: "probe-tool") {
            let enablement = ActionEnablement([invocation])
            for _ in 0..<2 {
                let seeded = await probeExecutor.submit(
                    invocation, enablement: enablement, policy: .none,
                    approval: .withheld, approvedSentence: nil, mode: .live)
                if seeded.auditRecorded { recorded += 1 }
            }
        }

        // The composed recipe — the same composition `AppBootstrap.configure` makes: the real
        // `AuditActionProvider` over the same store, the real config store over the temp
        // directory, a session-active flag that never refuses (the probe's composition has no
        // sessions — the flag is a closure, read lazily at arm time), and a real root over probe
        // fakes for the widget folds.
        let root = makeActionDriveRoot()
        let wiring = AppBootstrap.composeActionWiring(
            configStore: configStore,
            auditStore: auditStore,
            provider: AuditActionProvider(store: auditStore),
            sessionActive: { false },
            root: root)

        let servers = await wiring.loadConfig().servers.count
        var mismatch = "no"
        var binding = "refused"
        if ActionInvocation(
            providerID: AuditActionProvider.providerID,
            toolID: AuditActionProvider.clearToolID) != nil
        {
            try? await wiring.setToolEnabled(
                AuditActionProvider.providerID, AuditActionProvider.clearToolID, true)

            // Arm: the card carries the gate's current sentence (the wiring re-renders after
            // its own record, so the shown sentence is the count the confirm will face).
            try? await wiring.arm(
                AuditActionProvider.providerID, AuditActionProvider.clearToolID)
            let shown = root.widgetStore.state.confirmation?.signal.sentence

            // The sentence drifts: one more entry lands before the human answers — the real
            // provider's sentence names the count, so the gate's fresh render differs.
            if let probeInvocation = ActionInvocation(
                providerID: "dev.vocca.probe", toolID: "probe-tool")
            {
                let drifted = await probeExecutor.submit(
                    probeInvocation, enablement: ActionEnablement([probeInvocation]),
                    policy: .none, approval: .withheld, approvedSentence: nil, mode: .live)
                if drifted.auditRecorded { recorded += 1 }
            }

            // Confirm with the shown sentence: the gate's fresh render differs — the binding
            // refuses by attempting the call, and the wiring re-presents a fresh card.
            await wiring.confirm()
            let reprompted = root.widgetStore.state.confirmation?.signal.sentence
            if let shown, let reprompted, reprompted != shown {
                mismatch = "reprompted"
            }

            // The peak before the clear: the two seed stops, the arm's stop, the drift entry and
            // the mismatch's declined decision. The next confirm runs the real clear over them.
            recorded = await auditStore.list().count

            // Confirm the fresh card: bound to the current sentence, the gate renders the same,
            // and `audit.clear` runs — the record lands after the clear (the clear is itself
            // auditable), which is the reconstruct the reader below decodes.
            await wiring.confirm()
            let reloaded = await auditStore.load()
            if let final = reloaded.first,
                final.decision == .confirmed,
                let reprompted,
                final.summary == reprompted
            {
                binding = "matched"
            }
        }

        // A second store over the same directory: the reader shares nothing with the writer, so
        // what it returns came off the disk.
        let reader = FileSystemActionAuditStore(directory: auditDirectory)
        let reloaded = await reader.load()
        let ordinals = reloaded.map(\.id)
        try? await reader.clear()
        let cleared = await reader.list().count

        let storeName = String(reflecting: type(of: auditStore))
        return ActionAuditDrive(
            report: [
                "store=\(storeName.contains("FileSystemActionAuditStore") ? "real" : "other")",
                "store.location=\(auditDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path) ? "temporary" : "elsewhere")",
                "store.isDefaultLocation=\(auditDirectory == defaultLocation)",
                "servers=\(servers)",
                "spawnsSubprocess=\(wiring.spawnsSubprocess)",
                "recorded=\(recorded)",
                "reloaded=\(reloaded.count)",
                "ordinals=\(ordinals.first ?? 0)-\(ordinals.last ?? 0)",
                "decisions=\(reloaded.map(\.decision.rawValue).joined(separator: ","))",
                "binding=\(binding)",
                "mismatch=\(mismatch)",
                "cleared=\(cleared)",
            ].joined(separator: " "),
            moduleWitness: type(of: auditStore))
    }

    /// The minimal real root over the probe's shared fakes — the fold surfaces the wiring needs
    /// (`widgetStore.presentActionConfirmation`), and nothing that starts, reads or provisions.
    /// No pipeline: the drive never presses.
    @MainActor
    private static func makeActionDriveRoot() -> DictationLoopRoot {
        DictationLoopRoot(
            configuration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: ProbeClock(),
            audioSource: ProbeActionMicrophone(),
            keyState: ProbeKeyState(),
            watchdogTimer: ProbeTimer(),
            healthTimer: ProbeTimer(),
            deferOpening: { $0() },
            tap: ProbeTap(),
            secureInput: ProbeSecureInputState(),
            resolver: DictationEngineResolver(selection: .defaultSelection) { _ in ProbeEngine() },
            targetResolution: TargetResolution(
                focusedApp: ProbeFocusedApp(
                    identity: FocusedAppIdentity(
                        bundleID: "com.example.Editor", windowTitle: "Draft")),
                secureInput: ProbeSecureInputRead(active: false),
                frontmost: ProbeFrontmostApp()),
            panel: ProbePanel(),
            toggleConfiguration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .toggle),
            toggleSource: ProbeActionMicrophone(),
            toggleTimer: ProbeTimer(),
            runningAppName: ProbeRunningAppName(),
            widgetClock: ProbeTimer(),
            liveLevel: ProbeActionLevelSource(),
            sessionKind: .dictation)
    }

    /// The drive's own capture double — `AudioBuffer`-typed (the root's seam), never opened: the
    /// drive never presses, so the microphones' only obligation is to exist.
    private final class ProbeActionMicrophone: SessionAudioSource {
        typealias Buffer = AudioBuffer

        func beginCapture() -> CaptureStart { .opened }

        func endCapture() -> AudioBuffer {
            AudioBuffer(samples: [], sampleRate: AudioBuffer.interchangeSampleRate)
        }
    }

    /// A level source that never moves — the root's live-level seam, satisfied without a graph.
    private struct ProbeActionLevelSource: LiveLevelSource {
        func latestLevel() -> Float { 0 }
    }
}