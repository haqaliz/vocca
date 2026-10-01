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
import VoccaASR
import VoccaBootstrap
import VoccaCore
import VoccaHotkey
import VoccaInject
import VoccaUI

// The probe's half of the zero-network invariant for the `coding-agent-handoff` slice
// (`agent-probe` aspect): the composed coding-agent configuration driven once under the
// interposer — the `ShellDrive` sibling, and the slice's second route to a real child.
//
// ## Why this file exists at all
//
// The agent composition is the second wiring whose provider **can** spawn: `CodingAgentProvider`
// over the real `ShellExecutor` runs a configured argv on the user's machine. The wiring aspect
// composed it behind explicit configuration, so the composed default's fact carriers
// (`agents=0`, `spawnsSubprocess=false`) are exactly the claim the invariant must read off a
// live composition — and the seeded round trip is the second spawn this process ever makes
// under the interposer. Neither is observable from a unit test: the promise is about the
// composition `configure` makes, and the round trip is about real bytes under the shim.
//
// ## What is driven, and what is not
//
// **Two compositions, one report.** The composed default's facts are read off a wiring
// composed over an **absent** registry file — the true first-launch default (an absent file
// is the empty registry, and nothing is configured out of the box, D2): `agents=0` is the
// wiring's `listAgents` answer and `spawnsSubprocess=false` is the wiring's declared fact.
// Then the registry is seeded with one benign agent (`/bin/echo`, `outwardFacing` by
// construction — the row has no `readOnly` field, so the gate demands the card before
// anything runs), the enablement row lands in the shared config store, and a second
// composition — the provider loaded from the seeded file, toolIDs fixed at construction —
// runs the round trip: arm → the outwardFacing sentence on the widget card → confirm with
// the shown sentence → the **real** engine runs the child → the audit reconstructs off the
// disk (the arm's refused stop, the confirmed run, the dry-run row). The dry-run row is the
// `preview` path: it records but never invokes — asserted on the engine's own call log, the
// counted `invoked=1` next to the three decisions.
//
// The engine is the shipped one — `ShellExecutor` with the shipped clock and sleeper — behind
// a counting closure, the `IntentProbeProvider` shape: the count is a fact of the run, and a
// dry run that invoked would flip it.
//
// A construct-and-discard drive would satisfy the coverage list while touching no file, which
// is precisely the coverage this composition needs; a drive that fabricated decisions by hand
// would prove nothing about the shipped recipe. This one runs the shipped recipe.
//
// ## What a green PROBE-CODING-AGENT does NOT prove
//
// It proves that the **composed default** reads zero agents and declares no spawn — under
// the interposer, over real bytes. It proves NOTHING about an **enabled** agent: the seeded
// round trip spawns a real child, and that child — like every restricted child — ignores
// `DYLD_INSERT_LIBRARIES` *and purges it from the environment it passes on*, so the
// interposer is blind to the child's whole descendant tree. Deviation **D2**, measured in the
// slice-1 dig, stated here because this is the second probe line that ever sat beside a
// spawn: **the probe proves the default cannot spawn, never that an enabled agent cannot
// egress.** The agent child is the same blind hop the shell drive's `/bin/echo` is — and the
// drive runs `/bin/echo`, which makes no network call anyway, so the interposer's blindness
// costs this line nothing it needed to see. That is why
// `ActionTransportProhibitionTests` exists and why it is not made redundant by this drive:
// the lint refuses a second spawn site at review time, in the module, because this invariant
// cannot see one at run time. The wiring's own `spawnsSubprocess=false` is the composed
// default's declared fact — capability vs configuration, and the probe reads the
// configuration.
//
// ## The report, and where each field comes from
//
// `store=real store.location=temporary store.isDefaultLocation=false agents=0
// spawnsSubprocess=false seeded=1 card=yes invoked=1 decisions=refused,confirmed,dryRun
// ordinals=1-3 binding=matched` — every field an effect of the run:
//
// - `store` — the shipped store's own type name, so a swapped-in double flips it.
// - `store.location` / `store.isDefaultLocation` — where the drive wrote, the standing
//   promise that **no probe run writes to the founder's real
//   `~/Library/Application Support/Vocca/`**.
// - `agents` — the composed default's fact: `listAgents` over an absent registry answers
//   zero rows — nothing is configured out of the box (D2).
// - `spawnsSubprocess` — the wiring's declared fact: the composed default cannot create a
//   child.
// - `seeded` — the seeded registry's own answer: the round trip had an agent to arm.
// - `card` — the gate asked: the widget store's confirmation was non-nil after the arm.
// - `invoked` — the engine's own call log: the confirm ran the child **exactly once**, and
//   the dry-run row reached it zero times.
// - `decisions` — the audit store's own decoded answer, in ordinal order: the arm's withheld
//   stop (`refused`), the confirmed run (`confirmed`) and the rehearsal (`dryRun`).
// - `ordinals` — the write ordinals the reader read back, rebuilt from the directory.
// - `binding` — the confirmed entry's summary is the card's shown sentence: the N2 binding
//   live in the agent path.
extension VoccaNetworkProbe {

    /// One drive of the composed coding-agent configuration, as the post-condition coverage
    /// list reads it.
    struct CodingAgentDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String

        /// A type minted **by this drive**, from which the composition it drove derives its
        /// module's coverage entry — the witness rule every sibling drive follows.
        let moduleWitness: Any.Type
    }

    /// **Drives the composed coding-agent configuration, and reports what happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every
    /// other drive gives: an assertion living in the observed process can be deleted by the
    /// same edit that breaks what it observes.
    static func exerciseCodingAgent() -> CodingAgentDrive {
        // The `exerciseShell()` bridge: `main()` is the process entry point and is already on
        // the main thread, so the async work is handed to a Task and the run loop is pumped
        // until it lands — inside the observation window rather than after it.
        let semaphore = DispatchSemaphore(value: 0)
        let box = CodingAgentDriveBox()
        Task { @MainActor in
            box.value = await runCodingAgentDrive()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary — the `ShellDriveBox` shape.
    private final class CodingAgentDriveBox: @unchecked Sendable {
        var value: CodingAgentDrive?
    }

    /// The engine's call log — the counted "the child ran exactly once" fact.
    ///
    /// A `Mutex`-backed counter (the `ShellInvocationCounter` shape): the confirm's invoke and
    /// the dry-run's zero invokes are counted facts, never inferences from the audit's shape.
    private final class CodingAgentInvocationCounter: Sendable {
        private let count = Mutex(0)

        func bump() {
            count.withLock { $0 += 1 }
        }

        var value: Int {
            count.withLock { $0 }
        }
    }

    /// The composed default's facts and the seeded round trip, over real temp-directory
    /// stores and the real engine.
    @MainActor
    private static func runCodingAgentDrive() async -> CodingAgentDrive {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-probe-agent-\(UUID().uuidString)")
        let configDirectory = base.appendingPathComponent("config")
        let auditDirectory = base.appendingPathComponent("audit")
        let registryDirectory = base.appendingPathComponent("agents")
        defer { try? FileManager.default.removeItem(at: base) }

        // Where a shipped install would have written, resolved the way the app resolves it —
        // so `isDefaultLocation` is a comparison against the real location rather than
        // against a path written out here.
        let defaultLocation = FileSystemActionAuditStore.defaultDirectory(
            applicationSupport: FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first,
            home: FileManager.default.homeDirectoryForCurrentUser)

        let configStore = ActionConfigStore(directory: configDirectory)
        let auditStore = FileSystemActionAuditStore(directory: auditDirectory)
        let registry = CodingAgentRegistry(directory: registryDirectory)

        // The engine: the shipped `ShellExecutor` with the shipped clock and sleeper, behind
        // the counting closure — the real child, and a counted fact for every run. The same
        // engine the shell slice uses, inherited for the agent child (`agent-execution`).
        let counter = CodingAgentInvocationCounter()
        let engine: @Sendable (ShellExecutor.Configuration) async -> ShellExecutionResult = {
            configuration in
            counter.bump()
            return await ShellExecutor(
                configuration: configuration,
                clock: ContinuousStdioClock(),
                sleeper: TaskStdioPollSleeper()).run()
        }

        // THE COMPOSED DEFAULT: a wiring over the **absent** registry file — the true
        // first-launch default, the configuration the zero-network promise is about. The
        // facts are read before anything is seeded.
        let defaultRoot = makeCodingAgentDriveRoot()
        let defaultWiring = AppBootstrap.composeCodingAgentWiring(
            configStore: configStore,
            auditStore: auditStore,
            registry: registry,
            provider: CodingAgentProvider(agents: [], run: engine),
            sessionActive: { false },
            root: defaultRoot)
        let agents = await defaultWiring.listAgents().count
        let spawnsSubprocess = defaultWiring.spawnsSubprocess

        // THE SEED: one benign agent (`/bin/echo` — a real child of the probe process that
        // makes no network call; `outwardFacing` by construction, the row declares no
        // `readOnly`, so the gate demands the card before anything runs) and the enablement
        // row in the shared config store (providerID `dev.vocca.agent`; absent is off until
        // this row lands).
        let projectDirectory = base.appendingPathComponent("project")
        // The row is valid by construction — every field is within the registry's caps — so
        // the failable initializer's `nil` is the one branch this seed can never take.
        let fixture = CodingAgentDefinition(
            id: "echo-agent",
            executablePath: "/bin/echo",
            arguments: ["vocca-agent-round-trip"],
            projectDirectory: projectDirectory.path,
            timeoutSeconds: CodingAgentRegistry.defaultTimeoutSeconds)!
        try? await registry.save(CodingAgentFile(agents: [fixture]))
        try? await configStore.save(
            ActionConfig(
                servers: [],
                enablement: [
                    ActionConfigEnablementRow(
                        providerID: CodingAgentProvider.providerID, toolID: fixture.id)
                ]))

        // THE SEEDED COMPOSITION: the provider loaded from the seeded file — toolIDs are
        // fixed at construction, so the round trip's wiring is a distinct composition from
        // the default's, exactly as a user's launch would build it after the file exists.
        let seededRoot = makeCodingAgentDriveRoot()
        let seededProvider = await CodingAgentProvider.load(
            registry: registry, run: engine)
        let seededWiring = AppBootstrap.composeCodingAgentWiring(
            configStore: configStore,
            auditStore: auditStore,
            registry: registry,
            provider: seededProvider,
            sessionActive: { false },
            root: seededRoot)
        let seeded = await seededWiring.listAgents().count

        // THE ROUND TRIP: arm → the outwardFacing sentence on the card → confirm with the
        // shown sentence → the real child runs → the audit reconstructs.
        var card = "no"
        var shownSentence = ""
        try? await seededWiring.arm(CodingAgentProvider.providerID, fixture.id)
        if let signal = seededRoot.widgetStore.state.confirmation?.signal {
            card = "yes"
            shownSentence = signal.sentence
        }
        await seededWiring.confirm()

        // THE DRY-RUN ROW: preview renders the sentence and records the rehearsal — and
        // reaches the engine zero times (the counted `invoked` stays at the confirm's one).
        _ = await seededWiring.preview(CodingAgentProvider.providerID, fixture.id)

        // A second store over the same directory: the reader shares nothing with the writer,
        // so what it returns came off the disk.
        let reader = FileSystemActionAuditStore(directory: auditDirectory)
        let reloaded = await reader.load()
        let ordinals = reloaded.map(\.id)
        let decisions = reloaded.map(\.decision.rawValue).joined(separator: ",")
        let binding =
            reloaded.contains { $0.decision == .confirmed && $0.summary == shownSentence }
            ? "matched" : "refused"

        let storeName = String(reflecting: type(of: auditStore))
        return CodingAgentDrive(
            report: [
                "store=\(storeName.contains("FileSystemActionAuditStore") ? "real" : "other")",
                "store.location=\(auditDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path) ? "temporary" : "elsewhere")",
                "store.isDefaultLocation=\(auditDirectory == defaultLocation)",
                "agents=\(agents)",
                "spawnsSubprocess=\(spawnsSubprocess)",
                "seeded=\(seeded)",
                "card=\(card)",
                "invoked=\(counter.value)",
                "decisions=\(decisions)",
                "ordinals=\(ordinals.first ?? 0)-\(ordinals.last ?? 0)",
                "binding=\(binding)",
            ].joined(separator: " "),
            moduleWitness: type(of: seededWiring))
    }

    /// The minimal real root over the probe's shared fakes — the fold surfaces the wiring
    /// needs (`widgetStore.presentActionConfirmation`), and nothing that starts, reads or
    /// provisions. No pipeline: the drive never presses.
    @MainActor
    private static func makeCodingAgentDriveRoot() -> DictationLoopRoot {
        DictationLoopRoot(
            configuration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: ProbeClock(),
            audioSource: ProbeCodingAgentMicrophone(),
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
            toggleSource: ProbeCodingAgentMicrophone(),
            toggleTimer: ProbeTimer(),
            runningAppName: ProbeRunningAppName(),
            widgetClock: ProbeTimer(),
            liveLevel: ProbeCodingAgentLevelSource(),
            sessionKind: .dictation)
    }

    /// The drive's own capture double — `AudioBuffer`-typed (the root's seam), never opened:
    /// the drive never presses, so the microphones' only obligation is to exist.
    private final class ProbeCodingAgentMicrophone: SessionAudioSource {
        typealias Buffer = AudioBuffer

        func beginCapture() -> CaptureStart { .opened }

        func endCapture() -> AudioBuffer {
            AudioBuffer(samples: [], sampleRate: AudioBuffer.interchangeSampleRate)
        }
    }

    /// A level source that never moves — the root's live-level seam, satisfied without a
    /// graph.
    private struct ProbeCodingAgentLevelSource: LiveLevelSource {
        func latestLevel() -> Float { 0 }
    }
}