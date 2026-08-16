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
import Synchronization
import VoccaASR
import VoccaAudio
import VoccaBootstrap
import VoccaCore
import VoccaHotkey
import VoccaInject
import VoccaText

// The probe's half of the zero-network invariant for `VoccaAudio` and `VoccaASR`.
//
// While those two modules held placeholders, naming `VoccaAudioPlaceholder` and
// `VoccaASRPlaceholder` in the probe's module list was all the invariant could say about them —
// and it no longer is: `VoccaAudio` holds the capture path (graph, ring, converter,
// `MicrophoneSource`) and `VoccaASR` holds the engines and the model lifecycle, and a metatype
// reference says nothing about any of them. The coverage guard in `ZeroNetworkTests` is at module
// granularity by construction, so it cannot tell a module that was *reached* from a module whose
// work was *run*.
//
// So this file runs the work: one **complete dictation cycle through the composed root** — the
// `DictationLoopRoot` composition `AppBootstrap.configure` builds, driven with probe fakes in
// every adapter slot, exactly as `DictationLoopTests`'s harness drives it. The press goes through
// the real machine, the real watchdog and the real sink; the frames travel through the real
// `MicrophoneSource` over the scripted `ProbeGraph`; the stub `ProbeEngine` transcribes; the real
// `LadderInjector` over the probe's rung fakes delivers; and every surface the happy path must
// leave untouched — the failsafe panel, the handoff ledger, the download session, the toggle
// wiring's microphone — reports its silence. The suite asserts that observation, not the call.
// Deleting the drive takes the report with it and `ZeroNetworkTests` fails by name; that is the
// property the session and injection drives demonstrated.
//
// **Nothing here needs a permission and nothing here can reach the network.** No AX element is
// resolved (the focused-app and Secure Input reads are fakes), no pasteboard is touched (the
// ladder's rungs are fakes), no `CGEvent` is synthesized, no window server is reached (the panel
// is a ledger), and — the one the whole drive is arranged around — **no engine is ever built and
// no download session ever starts**: the resolver's builder is substituted so that every path
// that would construct `ParakeetEngine` or `WhisperCppEngine` constructs the stub instead, and the
// download-session seam is a ledger the report reads back as `download.starts=0`.

// MARK: - The seams the composed loop needs

/// The tap, answering as the probe's environment does: no Accessibility grant, so
/// ``HotkeyEventSourceStart/unavailable`` — the same answer the shipped `CGEventTapSource` gives
/// a hosted runner. The root arms it (and logs `permissionMissing`); **the drive never delivers
/// an event through it** — the cycle is driven through the sink directly, the existing pattern,
/// so the drive cannot depend on a tap that was never granted.
final class ProbeTap: RecoverableHotkeyEventSource {
    private(set) var startCalls = 0

    var isDelivering: Bool { false }

    func start(delivering sink: any HotkeyEventSink) -> HotkeyEventSourceStart {
        startCalls += 1
        return .unavailable
    }

    func stop() {}

    func resumeDelivery() -> TapResume { .failed }
}

/// A clock the drive never turns, because the cycle does not need one: the watchdog's timer is
/// never fired (the session ends on its key-up long before the ceiling), and the widget's clock
/// is never fired (the DELIVERED confirmation is read while it still shows). It exists to satisfy
/// the `RepeatingTimer` seam with a ledger, so the report can witness *what the root asked of its
/// timers* — the watchdog's schedule, the health poll's cadence — without any of them firing.
final class ProbeTimer: RepeatingTimer {
    /// The interval it is firing at, or `nil` when stopped. The root's routers read this to decide
    /// whether to start or stop; the ledger's answer is the timer's own truth.
    private(set) var interval: Duration?

    private(set) var starts = 0
    private(set) var stops = 0

    /// The due fire, held only while running — released by ``stop()``, as the seam demands.
    private var fire: (() -> Void)?

    func start(every interval: Duration, _ fire: @escaping () -> Void) {
        // A start on a running timer is a stop followed by a start — the seam's own obligation,
        // modelled so the root's callers are measured against a conformance that keeps the
        // contract.
        if self.fire != nil { stops += 1 }
        self.interval = interval
        self.fire = fire
        starts += 1
    }

    func stop() {
        if fire == nil { return }
        interval = nil
        fire = nil
        stops += 1
    }

    func stopWithoutAssertingIsolation() {
        // No isolation is asserted here, so the deinits that reach this from anywhere are safe.
        stop()
    }
}

/// The focused application, as a fixed fact: `com.example.WordProcessor` — an ordinary,
/// **non-seeded** application, so the shipped `SeededInjectionAllowlist` offers it the same order
/// actual users of unlisted apps run: clipboard first, keystroke second, accessibility absent.
/// Immutable, so the conformance is `Sendable` honestly (`let`-only, like the AX adapter's
/// identity).
final class ProbeFocusedApp: FocusedAppReading {
    let identity: FocusedAppIdentity

    init(identity: FocusedAppIdentity) {
        self.identity = identity
    }

    func focusedApp() async -> FocusedAppIdentity? {
        identity
    }
}

/// Secure Input, off: the injection-time read the ladder's rung-0 refusal depends on. Immutable
/// for the same reason ``ProbeFocusedApp``'s is.
final class ProbeSecureInputRead: SecureInputReading {
    let active: Bool

    init(active: Bool) {
        self.active = active
    }

    func isSecureInputActive() async -> Bool {
        active
    }
}

/// Secure Input, as the tap-health policy reads it: a plain `false` on a headless runner. Not
/// `Sendable`-constrained, so a plain class with a mutable flag is honest.
final class ProbeSecureInputState: SecureInputStateReader {
    var isSecureInputActive = false
}

/// The failsafe surface, as a ledger: every presentation recorded, so "nothing presented on the
/// happy path" is an assertion on a counter rather than a belief about a window. `@MainActor`,
/// like the seam it implements.
@MainActor
final class ProbePanel: FailsafePresenting {
    private(set) var heldPresentations = 0
    private(set) var reasons: [FailsafeReason] = []

    /// The two presentation kinds, summed: zero is the happy path.
    var presentationCount: Int { heldPresentations + reasons.count }

    func presentHeldTranscript() async -> HeldTranscript? {
        heldPresentations += 1
        return nil
    }

    func presentReasonOnly(_ reason: FailsafeReason) {
        reasons.append(reason)
    }
}

/// The display-name reader, as an empty table: the widget's "→ {app}" indicator falls back to the
/// window title, which the focused-app fake supplies.
final class ProbeRunningAppName: RunningAppNameReading {
    var names: [String: String] = [:]

    func displayName(bundleID: String) -> String? {
        names[bundleID]
    }
}

/// The download window's seam, as a ledger: ``start()`` is the one call that would make
/// `ModelStore` fetch bytes, and the report's `download.starts=0` is the probe's answer to "the
/// drive must never trigger a real model download" — the substitute engine makes a download
/// unnecessary, and this ledger proves none was attempted.
///
/// The protocol's requirements are nonisolated, so the counter is guarded by a ``Mutex`` rather
/// than actor state — the exact shape `StoreModelDownloadSession` uses for its task handle, for
/// the same reason: a conformance that satisfied the seam through actor isolation would have had
/// to cross it, which is the race this repository's boundary doctrine forbids.
actor ProbeDownloadSession: ModelDownloadSession {
    private let startsLock = Mutex(0)

    /// Never yielded from and never iterated: a session that starts nothing has no events. The
    /// stream must exist for the seam, and an empty one is the honest shape for a session that
    /// never starts.
    nonisolated let events = AsyncStream<ModelDownloadEvent> { _ in }

    nonisolated func start() async {
        startsLock.withLock { $0 += 1 }
    }

    nonisolated func cancel() {}

    /// The ledger read: how many times ``start()`` was called.
    func startCount() -> Int {
        startsLock.withLock { $0 }
    }
}

/// One recorded injection — the row the pipeline's injector call leaves in the ledger.
fileprivate struct InjectionObservation {
    let text: String
    let target: TargetContext
    let result: InjectionResult
}

/// The injector, with a ledger in front of the ladder: every call the pipeline made is recorded,
/// and the ladder's own answer is returned unchanged. The ladder is real — `LadderInjector` over
/// the probe's rung fakes — this type only makes its call observable, which is the whole point:
/// the report's `injected=`, `rung=` and `attempted=` fields are read from what the pipeline
/// actually handed over and what the ladder actually answered, not from what the drive believes.
actor ProbeInjectorLedger: TextInjector {
    private let inner: any TextInjector
    fileprivate var calls: [InjectionObservation] = []

    init(inner: any TextInjector) {
        self.inner = inner
    }

    func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
        let result = await inner.inject(text, into: target)
        calls.append(InjectionObservation(text: text, target: target, result: result))
        return result
    }
}

// MARK: - The drive

extension VoccaNetworkProbe {

    /// One complete dictation cycle driven through the composed root, and the post-conditions the
    /// suite asserts.
    struct CycleDrive {
        /// The observation, as one line of `key=value` fields. Asserted whole — see
        /// `ZeroNetworkTests.expectedCycleLifecycle`.
        let report: String

        /// The latency ledger's `describe()` output after the cycle — the `PROBE-LATENCY` line's
        /// payload. One finalized record's class, spans and engine attribution, in mint order.
        let latencyReport: String

        /// A type minted **by this drive**, from which `VoccaAudio`'s name is derived for the
        /// coverage list: the real `MicrophoneSource` instance the cycle captured through. This
        /// is why the module entry is not a metatype literal any more —
        /// `VoccaAudioPlaceholder` sitting in that list satisfied the coverage guard whether or
        /// not a single line of `VoccaAudio` ever ran.
        let audioModuleWitness: Any.Type

        /// The same, for `VoccaASR`: the `ModelManifest` the drive's shipped-manifest load
        /// returned — real loader and decoder work, executed, with the witness minted by the
        /// call that did it.
        let asrModuleWitness: Any.Type

        /// The same, for `VoccaText`: the real rules provider the cycle cleaned through — a
        /// `ShippingRulesCleanupProvider` over an isolated throwaway directory, constructed here
        /// in `buildDictationCycle` and cleaned the cycle's transcript. This is why the module
        /// entry is not a metatype literal any more — `VoccaTextPlaceholder` sitting in that
        /// list satisfied the coverage guard whether or not a line of `VoccaText` ever ran.
        let cleanupModuleWitness: Any.Type
    }

    /// The scripted utterance's three frames, as the hand-over should carry them — the `ProbeGraph`
    /// constant, spelled once here so the expected report and the script cannot drift.
    static let cycleFrames = ProbeGraph.scriptedFrames

    /// **Drives one complete dictation cycle through the composed root, and reports what
    /// happened.**
    ///
    /// The composition is the root `AppBootstrap.configure` builds — same type, same recipe
    /// (configuration, ceiling, wiring, ladder, panel, engine lifecycle) — with probe fakes in
    /// every adapter slot CI cannot touch. The cycle: press → the owner's synchronous deferral
    /// opens the microphone (the real `MicrophoneSource` over the scripted `ProbeGraph`) → the
    /// scripted frames land in the ring → release → `.ended` → the stub engine transcribes → the
    /// ladder delivers through the clipboard rung → the widget folds DELIVERED.
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the same reason every
    /// other drive gives: an assertion that lives in the observed process can be deleted in the
    /// same edit that breaks what it observes, and its failure would arrive as an exit status
    /// rather than as a named expectation. It also makes no network call, which is the point of
    /// running it here at all — see the file header.
    static func exerciseDictationCycle() -> CycleDrive {
        // The root is @MainActor, so the drive has to run on the main actor to touch it. We are
        // already on the main thread here — `main()` is the process entry point — so rather than
        // hop, hand the work to a MainActor-bound Task and pump the run loop until it lands: the
        // same mechanism `settle(for:)` relies on to service main queue work, and the exact shape
        // `exerciseInjectionLifecycle()` uses.
        let semaphore = DispatchSemaphore(value: 0)
        let box = CycleDriveBox()
        Task { @MainActor in
            box.value = await buildDictationCycle()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary. Main-thread-only; see the
    /// drive's own comment for why that makes the unchecked annotation honest.
    private final class CycleDriveBox: @unchecked Sendable {
        var value: CycleDrive?
    }

    /// Builds the composed root over probe fakes, drives one cycle through it, and assembles the
    /// report.
    @MainActor
    private static func buildDictationCycle() async -> CycleDrive {
        // The one clock the whole loop reads — the machine, the watchdog, the ladder and the
        // widget store all share it, mirroring `AppBootstrap.configure`'s "one clock" rule. The
        // probe moves it by hand; nothing in this drive needs it to move.
        let clock = ProbeClock()
        let keyState = ProbeKeyState()
        // The user is holding the whole binding, chord included — the same model the session
        // drive uses. No wake ever polls it (the session ends on its key-up), but a key state
        // that answered "released" would be modelling a user who let go.
        keyState.isHeld = true
        keyState.heldModifiers = [.option]

        // The latency ledger every span of the cycle records through, and the box the router
        // shares with the microphones — wired exactly as `AppBootstrap.configure` wires them:
        // the router begins the record at `.opening`, the microphones read the id from the box
        // at `endCapture`, and the pipeline finalizes it on its delivered route. The report's
        // `records=1` and the PROBE-LATENCY line are read from this ledger after the cycle.
        let ledger = LatencyLedger()
        let sessionBox = LatencySessionBox()

        // The microphone: the real `MicrophoneSource` over the scripted graph — `VoccaAudio`'s
        // capture path, run for real. `try!` because the failure it could report is a fact about
        // this build (a 16 kHz mono converter) rather than a runtime condition — the same posture
        // `MicrophoneSourceTests` takes with `try`.
        let graph = ProbeGraph()
        let microphone = try! MicrophoneSource(
            graph: graph,
            recorder: ledger,
            clock: clock,
            sessionIDProvider: { sessionBox.sessionID })
        // The toggle configuration's own microphone — constructed, never opened: only the active
        // configuration may hold the input, and the report's `toggle.opens=0` is read off this
        // graph's ledger.
        let toggleGraph = ProbeGraph()
        let toggleMicrophone = try! MicrophoneSource(
            graph: toggleGraph,
            recorder: ledger,
            clock: clock,
            sessionIDProvider: { sessionBox.sessionID })

        // The engine lifecycle, with the builder substituted: every path that would construct a
        // real engine constructs the stub instead, so a model download is structurally
        // unreachable from this composition. The stub's attribution on the transcript is the
        // proof in the report.
        let engine = ProbeEngine()
        let resolver = DictationEngineResolver(selection: .defaultSelection) { _ in engine }

        // The shipped manifest, loaded for real — `VoccaASR`'s trust-anchor loader and decoder,
        // run headless with no model bytes. `try!` for the same reason as above: a missing bundle
        // resource is a broken build, not a runtime condition.
        let manifest = try! ShippedModelManifest.load(for: .parakeetV3)

        // The ladder: the real `LadderInjector` over the probe's rung fakes, with the shipped
        // seeded allowlist and the shared probe handoff — the same custody the pipeline reads, so
        // "held nothing" is one ledger read. The target is an ordinary unlisted application, so
        // the shipped order offers clipboard first and the clipboard rung delivers.
        let handoff = ProbeInjectionHandoff()
        let ladder = LadderInjector(
            strategies: [
                .clipboardPaste: ProbeInjectionStrategy(
                    rung: .clipboardPaste, outcome: .succeeded(verified: false)),
                .keystrokeSynthesis: ProbeInjectionStrategy(
                    rung: .keystrokeSynthesis, outcome: .failed),
            ],
            order: DefaultInjectionStrategyOrder(allowlist: SeededInjectionAllowlist()),
            handoff: handoff,
            clock: clock)
        let injectorLedger = ProbeInjectorLedger(inner: ladder)

        // The cleanup stage: the real shipped rules provider over an isolated throwaway
        // directory whose missing `dictionary.json` is an empty rule set — the founder's real
        // `~/Library/Application Support/Vocca/dictionary.json` is never read or written by CI,
        // and the cycle's `"1 2 3"` passes through the empty-dictionary rules path with only
        // the terminal punctuation the engine appends. `requiresNetwork == false` is the hook
        // the zero-network invariant keys on.
        let cleanup = ShippingCleanup.make(
            store: FileSystemDictionaryStore(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "vocca-probe-\(UUID().uuidString)")))

        // The pipeline, injected — the `DictationLoopTests` shape: the root takes the assembled
        // pipeline and the drive opens the readiness gate itself, which is what makes the cycle
        // deterministic (the shipped launch path prepares a real engine, which the probe must
        // never trigger). The pipeline's ASR span is measured with the shipped
        // `ContinuousMonotonicClock` — the one `Sendable` clock the probe owns — so the span is
        // a real measurement rather than a fabricated constant.
        let pipeline = DictationPipeline(
            engine: engine, injector: injectorLedger, holder: handoff,
            recorder: ledger, clock: ContinuousMonotonicClock(), cleanup: cleanup)

        let targetResolution = TargetResolution(
            focusedApp: ProbeFocusedApp(
                identity: FocusedAppIdentity(
                    bundleID: "com.example.WordProcessor", windowTitle: "Document 1")),
            secureInput: ProbeSecureInputRead(active: false))

        let panel = ProbePanel()
        let downloadSession = ProbeDownloadSession()
        let appName = ProbeRunningAppName()

        let root = DictationLoopRoot(
            configuration: HotkeyConfiguration(
                keyCode: spaceKeyCode, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: clock,
            audioSource: microphone,
            keyState: keyState,
            watchdogTimer: ProbeTimer(),
            healthTimer: ProbeTimer(),
            deferOpening: { $0() },
            tap: ProbeTap(),
            secureInput: ProbeSecureInputState(),
            resolver: resolver,
            targetResolution: targetResolution,
            panel: panel,
            pipeline: pipeline,
            recorder: ledger,
            sessionBox: sessionBox,
            toggleConfiguration: HotkeyConfiguration(
                keyCode: spaceKeyCode, modifiers: [.option], activation: .toggle),
            toggleSource: toggleMicrophone,
            toggleTimer: ProbeTimer(),
            runningAppName: appName,
            widgetClock: ProbeTimer(),
            liveLevel: MicrophoneLevelSource(graph: graph))
        // The readiness gate: the test hook, and the launch path's last step — the session may
        // open the microphone and the router may route the ended session into the injected
        // pipeline.
        root.markEnginePrepared()

        // MARK: The cycle

        // Press. The press is swallowed — the focused application never sees the hotkey — and by
        // the time the call returns, the owner's synchronous deferral has completed the opening:
        // the machine is recording and the microphone is open.
        let pressDisposition = root.holdToTalk.scheduledWatchdog.receive(
            keyEvent(.keyDown, configuration: root.configuration, at: clock.now))
        // Read while the session is still recording, before the release: `recording=1` is the
        // "the cycle started" fact, and reading it after the release would report the idle answer
        // and prove nothing.
        let recordingAfterPress = root.holdToTalk.machine.state == .recording

        // The router's opening mints the record's id on the main actor and stores it in the box
        // the microphones read at `endCapture`. The key-up must not beat the mint: the
        // capture-close span is recorded only when the box already holds the id, so the drive
        // drains until the write lands — the W2 shape (`DictationLoopTests` drains the same way
        // between its press and its release).
        var mintTurns = 0
        while sessionBox.sessionID == nil && mintTurns < 20_000 {
            await Task.yield()
            mintTurns += 1
        }

        // The scripted utterance lands in the ring while the microphone is open, the way the
        // realtime producer would.
        graph.deliver(cycleFrames)

        // Release: the session ends through the custody funnel, and the hand-over — frames,
        // completeness link and all — travels to the router.
        _ = root.holdToTalk.scheduledWatchdog.receive(
            keyEvent(.keyUp, configuration: root.configuration, at: clock.now))

        // The router's half is async: the key-down's target resolution, the engine's transcribe,
        // the ladder's inject and the widget folds all hop the main actor. Drain until the
        // widget shows DELIVERED — the final fold of the happy path — so the ledgers are read
        // after the cycle settled, not in the middle of it.
        var turns = 0
        while !isDelivered(root.widgetStore.state.state) && turns < 20_000 {
            await Task.yield()
            turns += 1
        }

        let observation = await injectorLedger.calls.first
        let frames = await engine.lastBufferFrames
        let transcriptText = await engine.lastTranscriptText
        let transcriptMissing = await engine.lastTranscriptMissing
        let transcriptEngine = await engine.lastTranscriptEngine
        let transcribeCalls = await engine.transcribeCalls
        let holds = await handoff.held.count
        let downloadStarts = await downloadSession.startCount()

        // The cycle's own ledger, read through the root's inspection accessor — the loop's
        // numbers, reported headlessly (spec §5). A root wired without a recorder reports the
        // absence by name rather than asserting inside the observed process; the suite's
        // PROBE-LATENCY assertions fail on that report rather than on a crash.
        let recordCount: Int
        let latencyReport: String
        if let ledger = root.latencyLedger {
            recordCount = await ledger.snapshot().count
            latencyReport = await ledger.describe()
        } else {
            recordCount = 0
            latencyReport = "no-ledger"
        }

        let fields = [
            "press=\(describe(pressDisposition))",
            "recording=\(recordingAfterPress ? 1 : 0)",
            "mic.opens=\(graph.starts)",
            "mic.stops=\(graph.stops)",
            "frames=\(frames)",
            "transcript=\(spell(transcriptText))",
            "transcript.missing=\(transcriptMissing)",
            "engine=\(transcriptEngine)",
            "engine.transcribes=\(transcribeCalls)",
            "manifest.engine=\(manifest.engineID)",
            "cleanup.engine=\(cleanup.identity.id)",
            "injected=\(spell(observation?.text ?? ""))",
            "rung=\(describe(observation?.result.rung))",
            "attempted=\(describe(observation?.result.attempted))",
            "failsafe=\(panel.presentationCount)",
            "holds=\(holds)",
            "download.starts=\(downloadStarts)",
            "widget=\(describe(root.widgetStore.state.state))",
            "toggle.opens=\(toggleGraph.starts)",
            "state=\(describe(root.holdToTalk.machine.state))",
            "records=\(recordCount)",
        ]

        return CycleDrive(
            report: fields.joined(separator: " "),
            latencyReport: latencyReport,
            audioModuleWitness: type(of: microphone),
            asrModuleWitness: type(of: manifest),
            cleanupModuleWitness: type(of: cleanup))
    }

    // MARK: - Reading the observation

    /// The stub's transcript spelling, space-free: the report grammar is space-separated
    /// `key=value` fields, so the canonical `"1 2 3"` is reported as `1-2-3`.
    private static func spell(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "-")
    }

    /// Whether the widget is showing DELIVERED — the final fold of the happy path.
    private static func isDelivered(_ state: WidgetState) -> Bool {
        if case .delivered = state { return true }
        return false
    }

    // MARK: - Spelling the observation

    // Every `describe` below is an exhaustive switch written out by hand rather than
    // `String(describing:)`, for the reason the session and injection drives give: the markers the
    // suite matches on are this package's own vocabulary, so they cannot change under it when a
    // compiler or a framework relabels something.

    private static func describe(_ propagation: EventPropagation) -> String {
        switch propagation {
        case .passThrough: return "passThrough"
        case .swallow: return "swallow"
        }
    }

    private static func describe(_ rung: InjectionRung) -> String {
        switch rung {
        case .accessibility: return "accessibility"
        case .clipboardPaste: return "clipboardPaste"
        case .keystrokeSynthesis: return "keystrokeSynthesis"
        case .widgetFailsafe: return "widgetFailsafe"
        }
    }

    private static func describe(_ rung: InjectionRung?) -> String {
        rung.map(describe) ?? "none"
    }

    private static func describe(_ attempted: [InjectionRung]?) -> String {
        attempted?.map(describe).joined(separator: ",") ?? "none"
    }

    private static func describe(_ state: SessionState) -> String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .ending: return "ending"
        }
    }

    private static func describe(_ state: WidgetState) -> String {
        switch state {
        case .idle: return "idle"
        case .opening: return "opening"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .delivered: return "delivered"
        }
    }

    /// One keyboard event carrying the configured chord — plain data, as `RawKeyEvent`
    /// documents: no `CGEvent`, no event tap and no Accessibility grant is involved.
    private static func keyEvent(
        _ kind: RawKeyEvent.Kind, configuration: HotkeyConfiguration, at timestamp: Duration
    ) -> RawKeyEvent {
        RawKeyEvent(
            kind: kind,
            keyCode: configuration.keyCode,
            modifiers: configuration.modifiers,
            isAutorepeat: false,
            timestamp: timestamp)
    }
}
