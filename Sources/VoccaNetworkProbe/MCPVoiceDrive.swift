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

// The probe's half of the zero-network invariant for the `mcp-intent-routing` slice
// (`probe-and-pins` aspect): the composed MCP arm driven once under the interposer, over an
// **in-memory** transport — the `ShellDrive`/`CodingAgentDrive` sibling for the third (and last)
// wiring whose provider could one day reach a child.
//
// ## Why this file exists at all
//
// The MCP composition is the third wiring whose provider **can** spawn: `MCPProvider` over a
// transport the factory returns. The wiring aspect composed it behind explicit configuration, so
// the composed default's fact carriers (`servers=0`, `spawnsSubprocess=false`) are exactly the
// claim the invariant must read off a live composition — and the seeded round trip is the one
// time this process exercises the whole arm. Neither is observable from a unit test: the promise
// is about the composition the root makes, and the round trip is about real behaviour under the
// shim.
//
// ## The transport is in-memory, and that is the point
//
// The drive substitutes `InMemoryMCPTransport` at the factory seam — the `MCPWiringTests`
// shape — so the whole round trip runs inside the interposer and makes **zero syscalls**. Unlike
// the shell and agent drives, this one starts **no child at all**: the seeded server's transport
// appends to an array and removes from one, so the line is a statement about the composed MCP arm
// rather than about a spawned peer. A configured **stdio** server is where the child (and D2)
// would live, and the probe cannot be that — no server is configured out of the box (D2), and the
// `transport-prohibition` lint keeps wiring one a reviewed edit.
//
// ## What is driven, and what is not
//
// **Two compositions, one report.** The composed default's facts are read off a wiring composed
// over an **absent** config — the true first-launch default (an absent file is the empty config,
// and nothing is configured out of the box, D2): `servers=0` is the config's own answer,
// `spawnsSubprocess=false` is the wiring's declared fact, `launched=0` is the factory never
// being called, and `providers=0` is an unconfigured providerID resolving to nothing. Then the
// config is seeded with one server (two tools, one enabled), and a second composition — the
// wiring over the seeded config, its server discovered through the in-memory factory — runs the
// voice round trip: a phrase resolved by the real `PhraseIntentResolver` → the sentence-bound
// card → confirm with the exact sentence shown → the tool called **exactly once** on the wire →
// the audit reconstructing off the disk. Two more refusals round out the slice's claims: a
// disabled tool is refused **by attempting the call** (the gate's enablement decline — a recorded
// refused entry, no card), and a foreign providerID never reaches this server's executor (no
// record, no card, no call).
//
// A construct-and-discard drive would satisfy the coverage list while touching no file, which is
// precisely the coverage this composition needs; a drive that fabricated decisions by hand would
// prove nothing about the shipped recipe. This one runs the shipped recipe.
//
// ## What a green PROBE-MCP-VOICE does NOT prove
//
// It proves the **composed default** reads zero servers and declares no spawn — under the
// interposer, over the in-memory transport. It proves NOTHING about a configured **stdio** server:
// `StdioMCPTransport` starts a real child, and that child — like every restricted child — ignores
// `DYLD_INSERT_LIBRARIES` *and purges it from the environment it passes on*, so the interposer is
// blind to its whole descendant tree. Deviation **D2**, measured in the slice-1 dig: the probe
// proves the default cannot spawn, never that an enabled server cannot egress. That is why
// `ActionTransportProhibitionTests` exists and why it is not made redundant by this drive. The
// wiring's own `spawnsSubprocess=false` is the composed default's declared fact — capability vs
// configuration, and the probe reads the configuration.
//
// ## The report, and where each field comes from
//
// `store=real store.location=temporary store.isDefaultLocation=false servers=0
// spawnsSubprocess=false launched=0 providers=0 seeded=1 tools=2 card=yes invoked=1
// decisions=refused,confirmed ordinals=1-2 binding=matched disabledRefused=1 foreignRefused=1` —
// every field an effect of the run:
//
// - `store` — the shipped store's own type name, so a swapped-in double flips it.
// - `store.location` / `store.isDefaultLocation` — where the drive wrote, the standing promise
//   that **no probe run writes to the founder's real `~/Library/Application Support/Vocca/`**.
// - `servers` — the composed default's fact: the absent config holds zero servers — nothing is
//   configured out of the box (D2).
// - `spawnsSubprocess` — the wiring's declared fact: the composed default cannot create a child.
// - `launched` — the factory's own call count for the default: zero configured servers means the
//   factory is never called, which is what makes "the default cannot spawn" structural.
// - `providers` — the default lookup's own answer: an unconfigured providerID resolves to nothing.
// - `seeded` — the seeded config's own answer: the round trip had a server to reach.
// - `tools` — the discovered tool list, off the server's `tools/list`.
// - `card` — the gate asked: the widget store's confirmation was non-nil after the voice arm.
// - `invoked` — the transport's own record of `tools/call`: the confirm called the tool
//   **exactly once**, and neither refusal reached a call.
// - `decisions` — the audit store's own decoded answer, in ordinal order: the arm's withheld stop
//   (`refused`) and the confirmed call (`confirmed`).
// - `ordinals` — the write ordinals the reader read back, rebuilt from the directory.
// - `binding` — the confirmed entry's summary is the card's shown sentence: the N2 binding live
//   in the MCP path.
// - `disabledRefused` — the disabled tool was refused by attempting the call (G3): one more
//   recorded refused decision and no card.
// - `foreignRefused` — a foreign providerID never reached this server's executor (G4): nothing
//   recorded, no card, no call.
extension VoccaNetworkProbe {

    /// One drive of the composed MCP configuration, as the post-condition coverage list reads it.
    struct MCPVoiceDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String

        /// A type minted **by this drive**, from which the composition it drove derives its
        /// module's coverage entry — the witness rule every sibling drive follows.
        let moduleWitness: Any.Type
    }

    /// **Drives the composed MCP configuration, and reports what happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every other
    /// drive gives: an assertion living in the observed process can be deleted by the same edit
    /// that breaks what it observes.
    static func exerciseMCPVoice() -> MCPVoiceDrive {
        // The `exerciseCodingAgent()` bridge: `main()` is the process entry point and is already
        // on the main thread, so the async work is handed to a Task and the run loop is pumped
        // until it lands — inside the observation window rather than after it.
        let semaphore = DispatchSemaphore(value: 0)
        let box = MCPVoiceDriveBox()
        Task { @MainActor in
            box.value = await runMCPVoiceDrive()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary — the `CodingAgentDriveBox`
    /// shape.
    private final class MCPVoiceDriveBox: @unchecked Sendable {
        var value: MCPVoiceDrive?
    }

    /// A scripted in-memory transport factory: a transport per server id, and a log of which
    /// servers were launched — the count that proves the composed default launches nothing.
    ///
    /// The `ScriptedFactory` shape from `MCPWiringTests`, reproduced here because the probe is a
    /// separate module and cannot see a test target's private double.
    private final class MCPVoiceFactory: Sendable {
        private let transports: [String: InMemoryMCPTransport]
        private let calls = Mutex<[String]>([])

        init(transports: [String: InMemoryMCPTransport]) {
            self.transports = transports
        }

        func make(_ server: MCPServerConfiguration) async -> MCPTransportLaunch {
            calls.withLock { $0.append(server.id) }
            guard let transport = transports[server.id] else {
                return .failed("probe.noTransport")
            }
            return .launched(transport)
        }

        var calledIDs: [String] {
            calls.withLock { $0 }
        }
    }

    /// The composed default's facts and the seeded round trip, over real temp-directory config
    /// and audit stores and the in-memory transport.
    @MainActor
    private static func runMCPVoiceDrive() async -> MCPVoiceDrive {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-probe-mcp-voice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        // Where a shipped install would have written, resolved the way the app resolves it — so
        // `isDefaultLocation` is a comparison against the real location rather than against a
        // path written out here.
        let defaultLocation = FileSystemActionAuditStore.defaultDirectory(
            applicationSupport: FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first,
            home: FileManager.default.homeDirectoryForCurrentUser)

        // The in-memory peer, one per server id. Discovery negotiates once and asks once; the
        // confirm is the one call. The second tool ("quiet") is declared but never enabled, so
        // the disabled-tool refusal has a real tool to name.
        let transport = InMemoryMCPTransport(replies: [
            Data(
                """
                {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"\(MCPSession.protocolVersion)",\
                "capabilities":{"tools":{}},"serverInfo":{"name":"probe-mcp-server","version":"1.0"}}}
                """.utf8),
            Data(
                """
                {"jsonrpc":"2.0","id":2,"result":{"tools":[\
                {"name":"ping","description":"Answers."},\
                {"name":"quiet","description":"Says nothing about itself."}]}}
                """.utf8),
            Data(
                """
                {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"pong"}],\
                "isError":false}}
                """.utf8),
        ])
        let server = MCPServerConfiguration(
            id: "probe", name: "probe-mcp-server", executablePath: "/usr/bin/echo")
        let factory = MCPVoiceFactory(transports: [server.id: transport])
        let providerID = MCPProvider.providerID(forServer: server)

        // THE COMPOSED DEFAULT: a wiring over the **absent** config — the true first-launch
        // default, the configuration the zero-network promise is about. The facts are read before
        // anything is seeded.
        let defaultConfig = ActionConfigStore(directory: base.appendingPathComponent("default-config"))
        let defaultAudit = FileSystemActionAuditStore(
            directory: base.appendingPathComponent("default-audit"))
        let defaultRoot = makeMCPVoiceDriveRoot()
        let defaultWiring = AppBootstrap.composeMCPWiring(
            configStore: defaultConfig,
            auditStore: defaultAudit,
            transportFactory: factory.make,
            sessionActive: { false },
            root: defaultRoot)
        let defaultServers = await defaultConfig.load().servers.count
        let defaultSpawns = await defaultWiring.spawnsSubprocess()
        let defaultLookup = await defaultWiring.lookup("dev.vocca.mcp.anything")
        let defaultLaunched = factory.calledIDs.count

        // THE SEED: one server (two tools) and an enablement row for `ping` only, in the shared
        // config store (absent is off until this row lands). `quiet` is declared but not enabled.
        let configStore = ActionConfigStore(directory: base.appendingPathComponent("config"))
        let auditDirectory = base.appendingPathComponent("audit")
        let auditStore = FileSystemActionAuditStore(directory: auditDirectory)
        try? await configStore.save(
            ActionConfig(
                servers: [server],
                enablement: [ActionConfigEnablementRow(providerID: providerID, toolID: "ping")]))

        // THE SEEDED COMPOSITION: the wiring over the seeded config, its server discovered
        // through the in-memory factory — a distinct composition from the default's, exactly as
        // a user's launch would build it after the file exists.
        let seededRoot = makeMCPVoiceDriveRoot()
        let seededWiring = AppBootstrap.composeMCPWiring(
            configStore: configStore,
            auditStore: auditStore,
            transportFactory: factory.make,
            sessionActive: { false },
            root: seededRoot)
        let serverWiring = await seededWiring.lookup(providerID)
        let seeded = await configStore.load().servers.count
        let discoveredTools = serverWiring?.toolRows.count ?? 0

        // THE ROUND TRIP: a phrase resolved by the real `PhraseIntentResolver` over the enabled
        // catalog → the voice arm → the sentence-bound card → confirm with the shown sentence →
        // the tool called on the wire → the audit reconstructs.
        var card = "no"
        var shownSentence = ""
        var roundDecisions = ""
        var ordinals: [Int] = []
        var binding = "none"
        if let serverWiring {
            let resolver = PhraseIntentResolver(rows: [
                PhraseIntentRow(phrase: "run the probe ping", providerID: providerID, toolID: "ping")
            ])
            let catalog = [ToolReference(providerID: providerID, toolID: "ping", displayName: "")]
            if case .toolCall(let invocation) = resolver.resolve(
                "run the probe ping", against: catalog)
            {
                _ = await serverWiring.performAction(invocation, "run the probe ping")
                if let signal = seededRoot.widgetStore.state.confirmation?.signal {
                    card = "yes"
                    shownSentence = signal.sentence
                }
                await serverWiring.confirm()

                // The round-trip facts, read off the disk by a second store before the refusal
                // scenarios add their own entries.
                let reader = FileSystemActionAuditStore(directory: auditDirectory)
                let reloaded = await reader.load()
                ordinals = reloaded.map(\.id)
                roundDecisions = reloaded.map(\.decision.rawValue).joined(separator: ",")
                binding =
                    reloaded.contains { $0.decision == .confirmed && $0.summary == shownSentence }
                    ? "matched" : "mismatch"
            }
        }

        // THE DISABLED REFUSAL (G3): a declared but un-enabled tool is refused by attempting the
        // call — the gate declines before any provider call, one more recorded refused decision,
        // and no card. The transport's `tools/call` count is unchanged.
        var disabledRefused = 0
        if let serverWiring,
            let quiet = ActionInvocation(providerID: providerID, toolID: "quiet")
        {
            let before = await auditStore.load().count
            _ = await serverWiring.performAction(quiet, "")
            let after = await auditStore.load()
            let noCard = seededRoot.widgetStore.state.confirmation == nil
            if after.count == before + 1, after.last?.decision == .refused, noCard {
                disabledRefused = 1
            }
        }

        // THE FOREIGN REFUSAL (G4): an invocation naming another providerID never reaches this
        // server's executor — the wiring's own guard returns before any submission, so nothing is
        // recorded, no card appears and no call leaves.
        var foreignRefused = 0
        if let serverWiring,
            let foreign = ActionInvocation(providerID: "dev.vocca.mcp.other", toolID: "ping")
        {
            let before = await auditStore.load().count
            let reply = await serverWiring.performAction(foreign, "")
            let after = await auditStore.load().count
            let noCard = seededRoot.widgetStore.state.confirmation == nil
            if reply == nil, after == before, noCard {
                foreignRefused = 1
            }
        }

        let invoked = await transport.sentMethods.filter { $0 == "tools/call" }.count
        let storeName = String(reflecting: type(of: auditStore))
        return MCPVoiceDrive(
            report: [
                "store=\(storeName.contains("FileSystemActionAuditStore") ? "real" : "other")",
                "store.location=\(auditDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path) ? "temporary" : "elsewhere")",
                "store.isDefaultLocation=\(auditDirectory == defaultLocation)",
                "servers=\(defaultServers)",
                "spawnsSubprocess=\(defaultSpawns)",
                "launched=\(defaultLaunched)",
                "providers=\(defaultLookup == nil ? 0 : 1)",
                "seeded=\(seeded)",
                "tools=\(discoveredTools)",
                "card=\(card)",
                "invoked=\(invoked)",
                "decisions=\(roundDecisions)",
                "ordinals=\(ordinals.first ?? 0)-\(ordinals.last ?? 0)",
                "binding=\(binding)",
                "disabledRefused=\(disabledRefused)",
                "foreignRefused=\(foreignRefused)",
            ].joined(separator: " "),
            moduleWitness: type(of: seededWiring))
    }

    /// The minimal real root over the probe's shared fakes — the fold surfaces the wiring needs
    /// (`widgetStore.presentActionConfirmation`), and nothing that starts, reads or provisions.
    /// No pipeline: the drive never presses.
    @MainActor
    private static func makeMCPVoiceDriveRoot() -> DictationLoopRoot {
        DictationLoopRoot(
            configuration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: ProbeClock(),
            audioSource: ProbeMCPVoiceMicrophone(),
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
            toggleSource: ProbeMCPVoiceMicrophone(),
            toggleTimer: ProbeTimer(),
            runningAppName: ProbeRunningAppName(),
            widgetClock: ProbeTimer(),
            liveLevel: ProbeMCPVoiceLevelSource(),
            sessionKind: .dictation)
    }

    /// The drive's own capture double — `AudioBuffer`-typed (the root's seam), never opened: the
    /// drive never presses, so the microphones' only obligation is to exist.
    private final class ProbeMCPVoiceMicrophone: SessionAudioSource {
        typealias Buffer = AudioBuffer

        func beginCapture() -> CaptureStart { .opened }

        func endCapture() -> AudioBuffer {
            AudioBuffer(samples: [], sampleRate: AudioBuffer.interchangeSampleRate)
        }
    }

    /// A level source that never moves — the root's live-level seam, satisfied without a graph.
    private struct ProbeMCPVoiceLevelSource: LiveLevelSource {
        func latestLevel() -> Float { 0 }
    }
}
