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

// The probe's half of the zero-network invariant for the `intent-layer` voice path (C13 slice
// 6, `probe` aspect): **two reports, one drive** —
//
// - **PROBE-INTENT** — the composed intent recipe's full voice round trip over probe doubles:
//   real temp-directory stores, a call-logged probe provider, the real `KeywordIntentResolver`
//   over a probe-seeded synonym table, the composed intent wiring, and the **existing**
//   `composeActionWiring` closures answering the card (the human leg is the surface's own, R5).
//   The trip is utterance → resolve → gate → `.confirmationRequired` → card → confirm → the
//   provider's `invoke` counted → the audit row reconstructing off the disk.
// - **PROBE-INTENT-DEFAULT** — the composed default's facts, read off the **composed root**
//   `AppBootstrap.configure` built: the `NullIntentResolver` fact carrier (R7's unwired
//   posture), one resolution through the composed wiring resolving nothing (`intentResolved=0`
//   as an effect, distinguishable from "the drive didn't run" by the counted `resolves=1` next
//   to it), and the composed wiring's declared `spawnsSubprocess=false` (the D2 narrowed
//   promise extended to the voice leg).
//
// ## Why the default leg reads the composed root
//
// `intentResolved=0` is only an *effect of the composed root's Null resolver* if the resolution
// runs through the wiring `configure` actually composed. The drive reads `composedRoot.intentWiring`
// and `composedRoot.intentResolver` — the slots `configure` fills — so a composition that wired a
// resolver (N1's flip) flips the report and the guard-the-guard refuses the flip as a reviewed
// edit. The one read this costs is the real `action-config.json`; `ActionConfigStore.load()`
// never creates or rewrites anything ("empty config" is a reading, never a repair), and the Null
// resolver answers `.none` for every catalog, so the field is deterministic even on a machine
// with tools enabled.
//
// ## What a green PROBE-INTENT does NOT prove
//
// It proves the composed voice path reaches no network name **while a full round trip runs** —
// the same D2 limit as `ActionAuditDrive`: it says nothing about a future transport, and the
// `transport-prohibition` lint is what keeps wiring one a reviewed edit. The round trip's own
// composition names no `Process` and no transport.
//
// ## The report, and where each field comes from
//
// PROBE-INTENT: `store=real store.location=temporary store.isDefaultLocation=false
// resolved=1 card=yes invoked=1 decisions=refused,confirmed ordinals=1-2 binding=matched` —
// every field an effect of the run:
//
// - `store` / `store.location` / `store.isDefaultLocation` — the real store and the
//   temp-directory promise (no probe run writes to `~/Library/Application Support/Vocca/`).
// - `resolved` — the wiring's resolve answered `.toolCall`: the round trip has a first leg.
// - `card` — the gate asked: the widget store's confirmation was non-nil after `performAction`.
// - `invoked` — the provider's own call log: confirm → invoke **exactly once**, counted.
// - `decisions` — the audit store's own decoded answer, in ordinal order: the withheld stop
//   (`refused` — the round trip's recorded foundation) then the confirmed invoke.
// - `ordinals` — the write ordinals the reader read back, rebuilt from the directory.
// - `binding` — the confirmed entry's summary is the card's shown sentence: the N2 binding
//   live in the voice path.
//
// PROBE-INTENT-DEFAULT: `resolver=NullIntentResolver resolves=1 intentResolved=0
// spawnsSubprocess=false intentShellRows=0` — `resolver` derived from the composed root's
// slot's own dynamic type, `resolves`/`intentResolved` from the resolution the drive actually
// performed through the composed wiring, `spawnsSubprocess` from the composed wiring's
// declared fact, and `intentShellRows` counted off the shipped resolver catalog — the
// arm-surface-only decision (shell is never composed into the intent seam, the `shell-provider`
// founder decision) as a reported fact: the voice leg has no learned phrase that could ever
// resolve to a shell command.
extension VoccaNetworkProbe {

    /// The intent drive's observation: the round trip and the composed default's facts, as two
    /// lines of `key=value` fields.
    struct IntentDrive {
        /// The PROBE-INTENT line — the voice round trip's effects.
        let report: String

        /// The PROBE-INTENT-DEFAULT line — the composed default's facts.
        let defaultReport: String

        /// The PROBE-INTENT-PHRASE line — the seeded phrase round trip's effects.
        let phraseReport: String

        /// A type minted **by this drive**, from which the composition it drove derives its
        /// module's coverage entry — the witness rule every sibling drive follows.
        let moduleWitness: Any.Type
    }

    /// **Drives the intent voice round trip and the composed default's facts, and reports what
    /// happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every
    /// other drive gives: an assertion living in the observed process can be deleted by the
    /// same edit that breaks what it observes.
    static func exerciseIntent(composedRoot: DictationLoopRoot) -> IntentDrive {
        // The `exerciseActionAudit()` bridge: `main()` is the process entry point and is
        // already on the main thread, so the async work is handed to a Task and the run loop is
        // pumped until it lands — inside the observation window rather than after it.
        let semaphore = DispatchSemaphore(value: 0)
        let box = IntentDriveBox()
        Task { @MainActor in
            box.value = await runIntentRoundTrip(composedRoot: composedRoot)
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary — the `ActionAuditDriveBox`
    /// shape.
    private final class IntentDriveBox: @unchecked Sendable {
        var value: IntentDrive?
    }

    /// The probe's own provider for the voice round trip — the one tool the probe is allowed to
    /// "run", on the probe's own provider id.
    ///
    /// Its sentence names nothing real, for the `ProbeActionProvider` reason: an entry
    /// attributed to a shipped provider would be indistinguishable from one produced by a
    /// process that had actually done something. The radius is destructive because the round
    /// trip needs a tool the gate will stop without a yes — the withheld stop is the log's
    /// refused entry, and the granted confirm is its confirmed one. The call log is a `Mutex`-
    /// backed counter (the `RecordingActionProvider` shape): the "confirm → invoke exactly
    /// once" effect is a counted fact, never an inference from the log's shape.
    private final class IntentProbeProvider: ActionProvider {
        static let providerID = "dev.vocca.probe"
        static let toolID = "probe-tool"

        let toolIDs = [IntentProbeProvider.toolID]

        private let log = Mutex(0)

        /// How many times the acting half of the seam was reached — the round trip's counted
        /// proof.
        var invokeCount: Int { log.withLock { $0 } }

        func describe(_ invocation: ActionInvocation) async -> ActionSummary {
            ActionSummary(
                sentence: "The probe would run its own tool, which does nothing.",
                blastRadius: .destructive)
        }

        func invoke(_ invocation: ActionInvocation, confirmation: ActionConfirmation) async
            -> ActionOutcome
        {
            log.withLock { $0 += 1 }
            return .succeeded
        }
    }

    /// The round trip and the default facts, over real temp-directory stores and the composed
    /// root's slots.
    @MainActor
    private static func runIntentRoundTrip(composedRoot: DictationLoopRoot) async -> IntentDrive {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-probe-intent-\(UUID().uuidString)")
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
        let provider = IntentProbeProvider()

        // The round trip's root over the probe's shared fakes — the widget folds land here,
        // never on the composed root's real store.
        let root = makeIntentDriveRoot()

        // The human leg is the surface's own: the same existing confirm/decline closures the
        // Actions tab's card answers through, composed over the same stores and the same
        // provider — the composition `configure` makes, driven once under the interposer.
        let surface = AppBootstrap.composeActionWiring(
            configStore: configStore,
            auditStore: auditStore,
            provider: provider,
            sessionActive: { false },
            root: root)

        // The intent recipe over the same stores and the same provider, with the REAL keyword
        // resolver over a probe-seeded synonym table: the seeded table targets the audit tools,
        // and the probe owns a tool of its own, so its row is the drive's injection — the
        // resolver's own machinery (token scoring, the threshold, the invocation construction)
        // is the shipped one.
        let resolver = KeywordIntentResolver(synonyms: [
            KeywordSynonym(
                phrase: "run the probe tool",
                providerID: IntentProbeProvider.providerID,
                toolID: IntentProbeProvider.toolID),
        ])
        let wiring = AppBootstrap.composeIntentWiring(
            configStore: configStore,
            provider: provider,
            executor: ActionExecutor(provider: provider, store: auditStore),
            resolver: resolver,
            root: root)
        try? await surface.setToolEnabled(
            IntentProbeProvider.providerID, IntentProbeProvider.toolID, true)

        // The round trip: utterance → resolve → gate → `.confirmationRequired` → card → the
        // existing confirm closure → the provider's `invoke` counted → the audit row
        // reconstructing off the disk.
        var resolved = 0
        var card = "no"
        var shownSentence = ""
        if case .toolCall(let invocation) = await wiring.resolve("run the probe tool") {
            resolved = 1
            _ = await wiring.performAction(invocation)
            if let signal = root.widgetStore.state.confirmation?.signal {
                card = "yes"
                shownSentence = signal.sentence
            }
            await surface.confirm()
        }

        // The composed default's facts — read off the root `configure` built, never off a
        // composition this drive made for itself: the resolver fact carrier's own dynamic type,
        // one resolution through the composed wiring (the real config store answers; the Null
        // resolver answers `.none` for every catalog), and the composed wiring's declared
        // no-spawn fact.
        var resolverFact = "none"
        var resolves = 0
        var intentResolved = 0
        var spawnsSubprocess = "none"
        // `phrase-intent-resolver`: the slot is the per-turn provider, so the fact is the
        // dynamic type of what calling it builds — the resolver the next turn would use.
        var composedTable: [PhraseIntentRow] = []
        if let resolverProvider = composedRoot.intentResolverProvider {
            let built = await resolverProvider()
            resolverFact =
                String(reflecting: type(of: built)).contains("PhraseIntentResolver")
                ? "PhraseIntentResolver" : "other"
            composedTable = (built as? PhraseIntentResolver)?.rows ?? []
        }
        if let composedWiring = composedRoot.intentWiring {
            if case .toolCall = await composedWiring.resolve("run the probe tool") {
                intentResolved = 1
            }
            resolves = 1
            spawnsSubprocess = "\(composedWiring.spawnsSubprocess)"
        }

        // The arm-surface-only fact (`shell-provider`, founder decision): the shipped
        // resolver catalog never names a `dev.vocca.shell` row — counted off the shipped
        // synonym table, the only resolver catalog the voice leg can learn phrases from. A
        // composition that wired a shell synonym flips this count, and the guard-the-guard
        // refuses the flip as a reviewed edit. Since `phrase-intent-resolver` the count also
        // covers the table the composed default was actually built over (the machine's real
        // phrase file, read, never written): the store refuses a shell row at load, so this
        // stays zero on any machine whatever the file holds.
        let shellRows =
            KeywordIntentResolver.shippedSynonyms.filter {
                $0.providerID == ShellProvider.providerID
            }.count
            + composedTable.filter { $0.providerID == ShellProvider.providerID }.count

        let phraseReport = await runPhraseRoundTrip(base: base)

        // A second store over the same directory: the reader shares nothing with the writer, so
        // what it returns came off the disk.
        let reader = FileSystemActionAuditStore(directory: auditDirectory)
        let reloaded = await reader.load()
        let ordinals = reloaded.map(\.id)
        let decisions = reloaded.map(\.decision.rawValue).joined(separator: ",")
        let binding =
            reloaded.contains { $0.decision == .confirmed && $0.summary == shownSentence }
            ? "matched" : "refused"

        let storeName = String(reflecting: type(of: auditStore))
        return IntentDrive(
            report: [
                "store=\(storeName.contains("FileSystemActionAuditStore") ? "real" : "other")",
                "store.location=\(auditDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path) ? "temporary" : "elsewhere")",
                "store.isDefaultLocation=\(auditDirectory == defaultLocation)",
                "resolved=\(resolved)",
                "card=\(card)",
                "invoked=\(provider.invokeCount)",
                "decisions=\(decisions)",
                "ordinals=\(ordinals.first ?? 0)-\(ordinals.last ?? 0)",
                "binding=\(binding)",
            ].joined(separator: " "),
            defaultReport: [
                "resolver=\(resolverFact)",
                "resolves=\(resolves)",
                "intentResolved=\(intentResolved)",
                "spawnsSubprocess=\(spawnsSubprocess)",
                "intentShellRows=\(shellRows)",
            ].joined(separator: " "),
            phraseReport: phraseReport,
            moduleWitness: type(of: wiring))
    }

    /// **The seeded phrase round trip** (`phrase-intent-resolver` R8): a real
    /// `intent-phrases.json` in a temp directory — one phrase for the probe's own tool, and one
    /// **hand-edited** shell row written as raw bytes (the threat is an edit, so the drive does
    /// not go through `save`) — loaded by the real store, resolved by the real
    /// `PhraseIntentResolver` through the per-turn recipe, carried to the card and confirmed
    /// through the surface's own closure. Every field is an effect of the run: `phrases` is the
    /// store's own answer, `shellRefused` its refusal log counted, `invoked` the provider's own
    /// call log.
    @MainActor
    private static func runPhraseRoundTrip(base: URL) async -> String {
        let phraseDirectory = base.appendingPathComponent("phrases")
        let configStore = ActionConfigStore(directory: base.appendingPathComponent("phrase-config"))
        let auditStore = FileSystemActionAuditStore(
            directory: base.appendingPathComponent("phrase-audit"))
        let provider = IntentProbeProvider()
        let defaultLocation = IntentPhraseStore.defaultDirectory(
            applicationSupport: FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first,
            home: FileManager.default.homeDirectoryForCurrentUser)

        let file = """
            {"version": 1, "phrases": [\
            {"phrase": "run the probe tool", "providerID": "\(IntentProbeProvider.providerID)", \
            "toolID": "\(IntentProbeProvider.toolID)"}, \
            {"phrase": "empty my downloads", "providerID": "\(ShellProvider.providerID)", \
            "toolID": "empty-downloads"}]}
            """
        try? FileManager.default.createDirectory(
            at: phraseDirectory, withIntermediateDirectories: true)
        try? Data(file.utf8).write(
            to: phraseDirectory.appendingPathComponent("intent-phrases.json"))

        let refusals = Mutex(0)
        let phraseStore = IntentPhraseStore(
            directory: phraseDirectory,
            log: { message in
                if message.contains("shell") { refusals.withLock { $0 += 1 } }
            })
        let loadedCount = Mutex(0)

        let root = makeIntentDriveRoot()
        let surface = AppBootstrap.composeActionWiring(
            configStore: configStore,
            auditStore: auditStore,
            provider: provider,
            sessionActive: { false },
            root: root)
        let wiring = AppBootstrap.composeIntentWiring(
            configStore: configStore,
            provider: provider,
            executor: ActionExecutor(provider: provider, store: auditStore),
            resolverProvider: {
                let table = await phraseStore.load().phrases
                loadedCount.withLock { $0 = table.count }
                return PhraseIntentResolver(rows: table)
            },
            root: root)
        try? await surface.setToolEnabled(
            IntentProbeProvider.providerID, IntentProbeProvider.toolID, true)

        var resolved = 0
        var card = "no"
        if case .toolCall(let invocation) = await wiring.resolve("Run the probe tool.") {
            resolved = 1
            _ = await wiring.performAction(invocation)
            if root.widgetStore.state.confirmation != nil {
                card = "yes"
            }
            await surface.confirm()
        }

        return [
            "store.location=\(phraseDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path) ? "temporary" : "elsewhere")",
            "store.isDefaultLocation=\(phraseDirectory == defaultLocation)",
            "phrases=\(loadedCount.withLock { $0 })",
            "resolved=\(resolved)",
            "card=\(card)",
            "invoked=\(provider.invokeCount)",
            "shellRefused=\(refusals.withLock { $0 })",
        ].joined(separator: " ")
    }

    /// The minimal real root over the probe's shared fakes — the fold surfaces the wiring needs
    /// (`widgetStore.presentActionConfirmation`), and nothing that starts, reads or provisions.
    /// No pipeline: the drive never presses.
    @MainActor
    private static func makeIntentDriveRoot() -> DictationLoopRoot {
        DictationLoopRoot(
            configuration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: ProbeClock(),
            audioSource: ProbeIntentMicrophone(),
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
            toggleSource: ProbeIntentMicrophone(),
            toggleTimer: ProbeTimer(),
            runningAppName: ProbeRunningAppName(),
            widgetClock: ProbeTimer(),
            liveLevel: ProbeIntentLevelSource(),
            sessionKind: .dictation)
    }

    /// The drive's own capture double — `AudioBuffer`-typed (the root's seam), never opened: the
    /// drive never presses, so the microphones' only obligation is to exist.
    private final class ProbeIntentMicrophone: SessionAudioSource {
        typealias Buffer = AudioBuffer

        func beginCapture() -> CaptureStart { .opened }

        func endCapture() -> AudioBuffer {
            AudioBuffer(samples: [], sampleRate: AudioBuffer.interchangeSampleRate)
        }
    }

    /// A level source that never moves — the root's live-level seam, satisfied without a graph.
    private struct ProbeIntentLevelSource: LiveLevelSource {
        func latestLevel() -> Float { 0 }
    }
}