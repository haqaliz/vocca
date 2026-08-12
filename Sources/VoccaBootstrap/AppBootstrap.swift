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

import AppKit
import OSLog
import VoccaASR
import VoccaAudio
import VoccaCore
import VoccaHotkey
import VoccaInject
import VoccaUI

/// Vocca's composition root: everything the process does before it starts taking events.
///
/// ## Why this is a package module and not `App/VoccaApp.swift`
///
/// The Xcode app target's sources sit outside the SwiftPM package, which means outside every
/// guarantee this repository has. They are not seen by `ModuleBoundaryTests`, and — the one that
/// matters — they are not driven by `VoccaNetworkProbe`, so the zero-network invariant, a permanent
/// release blocker, says nothing whatsoever about them. That is not a hypothetical gap: `App/` is
/// exactly where an update checker, a crash reporter or a Sparkle integration lands by convention,
/// and those are the archetypal network callers.
///
/// So the bootstrap lives here, where the probe can reach it, and `App/VoccaApp.swift` is reduced
/// to a single call that a test pins character for character.
///
/// ## Why `configure` and `main` are separate
///
/// The split is structural, not stylistic. ``main()`` ends in `NSApplication.run()`, which does not
/// return — no test can call it. ``configure(_:)`` is therefore where all the start-up work goes,
/// so that the drivable seam stops just short of the run loop and the probe can exercise the real
/// thing rather than a copy of it.
///
/// **When a capability adds start-up work, it goes in ``configure(_:)``.** Work added to
/// ``main()`` around the `run()` call is invisible to the invariant.
///
/// ## What `configure` does, and what it deliberately does not
///
/// `configure` builds the whole dictation loop — tap, session machines, engine lifecycle, ladder,
/// failsafe panel — and returns the ``DictationLoopRoot`` that owns it. Three obligations shape
/// where each piece is built:
///
/// - **The probe drives `configure`, so nothing it spawns may touch the network.** The model
///   *download* (`DictationEngineResolver.prepareIfNeeded`) is therefore not started here — it is
///   `DictationLoopRoot.startEnginePreparation()`'s, called from ``main()`` on the real launch
///   path. The journal assembly (`RecoveryJournal`'s load) is FileManager-only and is started here.
/// - **`configure` must not block.** The recovery journal's initializer is asynchronous (it reads
///   the journal from disk), so the journal → holder → ladder chain is assembled in a background
///   task the root awaits per use; the tap's creation is synchronous and its failure (no
///   Accessibility grant) is logged, not fatal.
/// - **The tap never waits for the model.** The microphone is gated on engine readiness
///   (``EngineReadinessGate``): until `prepare` succeeds, a press is swallowed and answered with
///   the `.modelUnavailable` reason-only notice, and the microphone is never asked.
public enum AppBootstrap {

    /// Everything the app sets up before the run loop starts. Safe to call from a test or from the
    /// network probe: it registers state, builds the loop, arms the tap, and touches no run loop.
    ///
    /// `.accessory` alongside `LSUIElement` in `Info.plist`. Both are set on purpose: the plist key
    /// is what the Dock and Launch Services read before the process starts, and the activation
    /// policy is what `NSApplication` honours once it has. Setting only one leaves a window between
    /// launch and this call during which the app can take focus — and for a tool whose job is
    /// typing into *another* app's text field, taking focus means typing into the wrong place.
    ///
    /// `@discardableResult` because the probe legitimately discards the root: its assertion about
    /// this call is the activation policy, and it cannot hold the app's composition. The app's own
    /// launch path (`main`) uses the return value.
    @discardableResult
    @MainActor
    public static func configure(_ application: NSApplication) -> DictationLoopRoot {
        // The return value is checked rather than discarded because of what `false` would mean
        // here. Vocca's named failure mode is "takes focus and types into the wrong field"; an
        // application left in `.regular` does exactly that, and it does it silently — there is no
        // exception, no crash, just a widget that steals the frontmost slot at the moment the user
        // starts dictating. `ZeroNetworkTests` asserts the resulting policy through the probe, so
        // this is caught in CI; the log is for the case where it happens on a user's machine.
        if !application.setActivationPolicy(.accessory) {
            logger.error(
                """
                Failed to enter the .accessory activation policy; the app is \
                \(String(describing: application.activationPolicy()), privacy: .public). Vocca will \
                take keyboard focus when it should not, and text injection will go to the wrong \
                window.
                """)
        }

        // The one clock the whole loop reads. The machines, the watchdog, the tap, the ladder and
        // the engines all take this same instance, so every Duration in the system is minted the
        // same way.
        let clock = ContinuousMonotonicClock()

        // The model store every engine loads through — one store, keyed by engine id and version,
        // so the Parakeet and whisper artifacts share the verified-marker machinery and the
        // single-flight download guard.
        let store = ModelStore()

        // MARK: The journal-backed custody chain
        //
        // `RecoveryJournal`'s initializer is asynchronous — it loads the journal from disk — and
        // `configure` may not block, so the journal → holder → ladder chain is assembled once, in
        // the background, and reached through the two forwarding types below. Nothing in this chain
        // touches the network; it is FileManager only, which is what makes it probe-safe.
        //
        // The ladder's handoff **and** the FAILSAFE panel's holder are the same custody: the panel
        // reads through `DeferredCustody` (a forward to the assembled `JournalTranscriptHolder`),
        // so "held by the ladder" and "shown by the panel" can never be two different journals.
        let custodyTask: Task<AssembledCustody, Error> = Task {
            let journal = try await RecoveryJournal(
                store: FileSystemJournalStore(), capacity: Self.recoveryJournalCapacity)
            let holder = JournalTranscriptHolder(journal: journal)
            let ladder = ShippingLadder.make(
                allowlist: SeededInjectionAllowlist(), handoff: holder, clock: clock)
            return AssembledCustody(holder: holder, ladder: ladder)
        }
        let deferredHolder = DeferredCustody(assembly: custodyTask)
        let deferredLadder = DeferredLadder(assembly: custodyTask)

        // MARK: Target resolution
        //
        // The two shipped adapters (AX + Carbon) need no grant to construct — the grants gate the
        // calls, not the objects.
        let targetResolution = TargetResolution(
            focusedApp: AXSource(), secureInput: SystemSecureInputRead())

        // MARK: The FAILSAFE window
        //
        // Built here with the panel's two handlers wired to the shipped adapters: ⌘C writes the
        // held text to the pasteboard (`ShippingPasteboard`), and ⏎ re-runs the ladder against
        // current focus, releasing the hold on a delivery and re-presenting the fresh hold on a
        // re-hold (`PRODUCT_SPEC.md:116`). The retry handler reaches the panel back through a weak
        // box filled after construction — the panel is the thing being built, so the handler cannot
        // capture it directly.
        let panelBox = WeakBox<FailsafePanel>()
        let panel = FailsafePanel(
            holder: deferredHolder,
            copyHandler: { transcript in
                Task { await ShippingPasteboard.write(transcript.text) }
            },
            retryHandler: { transcript in
                Task {
                    let target = await targetResolution.resolve()
                    let result = await deferredLadder.inject(transcript.text, into: target)
                    switch result.rung {
                    case .widgetFailsafe:
                        // The ladder re-held — present the fresh entry, returning the panel to
                        // presenting with the text intact.
                        await panelBox.value?.presentHeldTranscript()
                    case .accessibility, .clipboardPaste, .keystrokeSynthesis:
                        // Delivered — the held transcript is redundant; release it and take the
                        // panel away.
                        await deferredHolder.release()
                        panelBox.value?.hideWindow()
                    }
                }
            })
        panelBox.value = panel

        // MARK: The engine lifecycle
        //
        // The resolver is built here, but its builder runs only when `prepareIfNeeded` does — and
        // that is `main`'s job, not `configure`'s: the engine's `prepare` is where model bytes
        // arrive, which is the one thing the probe must never trigger.
        let resolver = DictationEngineResolver(selection: .defaultSelection) { selection in
            try await engine(for: selection, store: store, clock: clock)
        }

        // The download window's surface: the same store, manifest and transport the engine will
        // use, so a download the UI starts and a download the launch starts are single-flight.
        let downloadSession: (any ModelDownloadSession)?
        do {
            downloadSession = try StoreModelDownloadSession(
                store: store,
                manifest: ShippedModelManifest.load(for: EngineSelection.defaultSelection.tier),
                transport: DefaultModelTransport(
                    baseURL: repositoryURL(for: EngineSelection.defaultSelection.tier)))
        } catch {
            logger.error(
                "the download session could not be built: \(String(describing: error), privacy: .public)")
            downloadSession = nil
        }

        // MARK: The microphone
        //
        // A Mac with no input device — and every hosted CI runner — refuses the graph at
        // construction (`AudioCaptureGraphError.noInputFormat`), so construction is tolerated: the
        // loop still exists, and every press is answered with `.captureUnavailable` by the
        // fallback source. The configuration-change callback ends the session through the root's
        // system-trigger route; the root does not exist yet, so it is reached through a weak box
        // filled below.
        let rootBox = WeakBox<DictationLoopRoot>()
        let graph = try? AudioCaptureGraph(
            ringCapacity: Self.ringCapacity,
            onConfigurationChange: { [weak rootBox] in
                Task { @MainActor in
                    guard let root = rootBox?.value else { return }
                    root.observe(.audioConfigurationChanged)
                }
            })

        let microphone: any SessionAudioSource<AudioBuffer>
        if let graph, let source = try? MicrophoneSource(graph: graph) {
            microphone = source
        } else {
            logger.error(
                """
                The microphone could not be built (no input device, or a format no audio can arrive \
                in). The dictation loop is up, but every press will be answered with \
                capture-unavailable until the capture graph exists.
                """)
            microphone = RefusingAudioSource()
        }

        // MARK: The root
        //
        // The pipeline is assembled after the engine is prepared (it needs a *prepared* engine),
        // so `configure` hands the root the assembly recipe instead of a pipeline. `main`'s
        // `startEnginePreparation` runs it.
        let root = DictationLoopRoot(
            configuration: HotkeyConfiguration(
                keyCode: Self.shippedHotkeyKeyCode, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: clock,
            audioSource: microphone,
            keyState: SystemPhysicalKeyState(),
            watchdogTimer: MainRunLoopTimer(),
            healthTimer: MainRunLoopTimer(),
            deferOpening: ShippingEventTap.deferToALaterMainRunLoopTurn,
            tap: ShippingEventTap.make(clock: clock),
            secureInput: SystemSecureInputState(),
            resolver: resolver,
            targetResolution: targetResolution,
            panel: panel,
            pipeline: nil,
            pipelineAssembly: {
                let custody = try await custodyTask.value
                guard let engine = await resolver.engineIfReady() else {
                    throw PipelineAssemblyError.engineNotPrepared
                }
                return DictationPipeline(
                    engine: engine, injector: custody.ladder, holder: custody.holder)
            },
            downloadSession: downloadSession)
        rootBox.value = root
        return root
    }

    /// Subsystem matches the bundle identifier so `log stream --subsystem dev.vocca.Vocca` picks up
    /// everything Vocca writes.
    private static let logger = Logger(subsystem: "dev.vocca.Vocca", category: "bootstrap")

    /// Configures the shared application, starts the engine's background preparation, and hands
    /// control to its run loop. Does not return.
    ///
    /// Deliberately two lines of work and one line of run loop: everything beyond the preparation
    /// kick-off is `configure`'s, because `configure` is what the zero-network probe drives.
    @MainActor
    public static func main() {
        let application = NSApplication.shared
        let root = configure(application)
        root.startEnginePreparation()
        application.run()
    }

    // MARK: - The shipped numbers

    /// The hotkey's virtual key code: Space, as in ⌥Space (`PRODUCT_SPEC.md:127`).
    public static let shippedHotkeyKeyCode: UInt16 = 49

    /// The capture ring's capacity: the 120 s ceiling at the hardware rate, rounded up to a power
    /// of two (`AudioRingBuffer` requires one). 120 s × 48 kHz = 5 760 000 samples; the next power
    /// of two is 2²³ = 8 388 608, about 175 s of headroom at 48 kHz mono.
    public static let ringCapacity = 8_388_608

    /// The recovery journal's cap — the bounded custody floor (`RecoveryJournal`'s own
    /// oldest-first eviction). Five is the test convention (`RecoveryJournalTests`) and the journal
    /// stays bounded either way; the number is named here so the composition root and the tests
    /// read one constant.
    public static let recoveryJournalCapacity = 5

    // MARK: - The model repositories

    /// The Parakeet artifact's file tree: the SDK's own registry name
    /// (`FluidInference/parakeet-tdt-0.6b-v3-coreml`, from FluidAudio's `ModelNames`), resolved
    /// through Hugging Face's `resolve` API. The manifest's file names resolve against this root.
    public static let parakeetModelRepository =
        URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/main")!

    /// The whisper artifact's file tree: the official download script's host
    /// (`docs/planning/second-asr-engine/understanding.md:41`). Both the turbo and the q5_0 GGUFs
    /// live in this repo's root.
    public static let whisperModelRepository =
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main")!

    /// The repository whose file tree serves `tier`'s manifest.
    public static func repositoryURL(for tier: EngineTier) -> URL {
        switch tier.engine {
        case .parakeetV3: return parakeetModelRepository
        case .whisperTurbo: return whisperModelRepository
        }
    }

    // MARK: - The engine builder

    /// Maps an ``EngineSelection`` to the real engine behind the seam — the recipe the resolver
    /// runs exactly once per process.
    ///
    /// Construction is side-effect-free and probe-safe: `ModelHub.offlineMode` is set inside the
    /// engines, `ModelStore()` and `DefaultModelTransport` touch no network at construction, and
    /// the manifest is loaded from this package's own bundle. The *download* happens later, inside
    /// `prepare()`, which is why this builder is public: a test may run it to pin the construction
    /// recipe (the `loop-wiring` Task 4 assembly-recipe assertion) without ever preparing.
    ///
    /// - Throws: ``ShippedModelManifestError`` when the shipped manifest is missing from the
    ///   bundle — a broken build, not a runtime condition.
    public static func engine(
        for selection: EngineSelection,
        store: ModelStore,
        clock: sending any MonotonicClock
    ) async throws -> any ASREngine {
        switch selection.tier {
        case .parakeetV3:
            return ParakeetEngine(
                store: store,
                manifest: try ShippedModelManifest.load(for: selection.tier),
                transport: DefaultModelTransport(baseURL: parakeetModelRepository),
                clock: clock)
        case .whisperTurbo, .whisperTurboQ5:
            return WhisperCppEngine(
                store: store,
                manifest: try ShippedModelManifest.load(for: selection.tier),
                transport: DefaultModelTransport(baseURL: whisperModelRepository),
                clock: clock)
        }
    }

    /// Why the pipeline assembly could not produce a pipeline.
    private enum PipelineAssemblyError: Error {
        /// `prepare` reported success but the resolver answered no engine — unreachable by
        /// construction (`prepareIfNeeded` sets `prepared` only after the engine answers).
        case engineNotPrepared
    }
}

// MARK: - The failsafe surface the loop presents on

/// The FAILSAFE presentation seam: what the loop's router may do to the window.
///
/// `FailsafePanel` itself is an `NSPanel` — window chrome CI structurally cannot execute — so the
/// router (and the headless composed-loop tests) speak to this two-method surface instead, and the
/// panel conforms behind it. The two methods are exactly the two surfaces ``PipelineSurface``
/// carries: a held transcript to present, or a reason-only notice.
@MainActor
public protocol FailsafePresenting: AnyObject {
    /// Read the holder and present what it holds. `nil` when nothing is held.
    @discardableResult
    func presentHeldTranscript() async -> HeldTranscript?
    /// Show a reason-only notice — no text was ever held (PRD R5).
    func presentReasonOnly(_ reason: FailsafeReason)
}

extension FailsafePanel: FailsafePresenting {}

// MARK: - The session wiring

/// One configured session wiring: the machine, its watchdog, the sink the tap delivers into, and
/// the timer that wakes the watchdog.
///
/// The composition root builds two of these — hold-to-talk and toggle — over the same injected
/// pieces (the `loop-wiring` Task 5 second configuration). What is here is the assembly both
/// configurations share: `machine → watchdog → ScheduledWatchdog(timer, deferral, deliverEffect)`,
/// with every effect leaving through the single `deliverEffect` closure.
///
/// ## Isolation
///
/// `@MainActor`, like everything else on the tap's side of the seam: the machine and watchdog are
/// deliberately non-`Sendable`, and this is the one isolation domain they live in.
@MainActor
public final class Wiring {
    /// The binding this wiring listens for.
    public let configuration: HotkeyConfiguration
    /// The session machine, untouched by the loop wiring — every decision routes through its
    /// `deliverEffect` hand-off point.
    public let machine: SessionMachine<AudioBuffer>
    /// The watchdog that polls the physical key and ticks the ceiling.
    public let watchdog: SessionWatchdog<AudioBuffer>
    /// The sink the tap delivers into — the only door into this wiring's session.
    public let scheduledWatchdog: ScheduledWatchdog<AudioBuffer>
    /// The timer the watchdog is woken with.
    public let timer: any RepeatingTimer
    /// The audio source the machine captures through (the readiness-gated microphone at ship).
    public let source: any SessionAudioSource<AudioBuffer>

    /// - Parameters:
    ///   - source: The microphone, through the readiness gate — the root builds the gate before
    ///     this wiring, so the machine's `beginCapture` already refuses while the engine is not
    ///     prepared.
    ///   - deliverEffect: Where every effect goes — the loop's router, which routes ended sessions
    ///     through the pipeline and presents the surfaces. One closure, so a transcript cannot
    ///     arrive by a route the owner forgot to wire.
    public init(
        configuration: HotkeyConfiguration,
        ceiling: Duration,
        clock: any MonotonicClock,
        source: any SessionAudioSource<AudioBuffer>,
        keyState: any PhysicalKeyStateReader,
        timer: any RepeatingTimer,
        deferOpening: @escaping RunLoopDeferral,
        deliverEffect: @escaping (SessionEffect<AudioBuffer>) -> Void
    ) {
        self.configuration = configuration
        self.timer = timer
        self.source = source
        let machine = SessionMachine(
            configuration: configuration, ceiling: ceiling, clock: clock,
            audioSource: source, captureStartTiming: .whenTheOwnerAsks)
        self.machine = machine
        let watchdog = SessionWatchdog(machine: machine, keyState: keyState)
        self.watchdog = watchdog
        self.scheduledWatchdog = ScheduledWatchdog(
            watchdog: watchdog, timer: timer, deferOpening: deferOpening,
            deliverEffect: deliverEffect)
    }
}

// MARK: - The composition root

/// The dictation loop, owned: the tap, the machines, the engine lifecycle, the ladder, the panel
/// and the routing between them.
///
/// This is the `loop-wiring` Task 4 composition — the thing `AppBootstrap.configure` returns and
/// the thing the composed-loop acceptance drives with fakes substituted. Every system-touching
/// component is injected, so a test builds the root with `RecordingAudioSource`-style fakes in the
/// microphone's place, a `FakeHotkeyEventSource` in the tap's, a fake key state, fake timers, a
/// synchronous deferral, a fake target resolution, ledger injector/holder fakes, a recording panel
/// and the real pipeline over the shared `StubEngine` — and the real machine, watchdog, sink and
/// pipeline run unchanged.
///
/// ## The readiness gate
///
/// The microphone is gated on engine readiness: until ``markEnginePrepared()`` (the launch path's
/// last step), `beginCapture` answers `.unavailable` and the router presents the `.modelUnavailable`
/// reason-only notice — the spec's "the mic never opens". The gate is a single main-actor flag
/// written *after* the pipeline is installed, so a session that passes the gate always finds a
/// pipeline to route its transcript into; a false "not ready" is an honest refusal, and the gate
/// can never report ready over an unprepared engine.
///
/// ## What is deliberately not here
///
/// The engine *preparation* (`startEnginePreparation`) is the one thing `main` calls and
/// `configure` does not — it is where model bytes arrive, and the probe must never trigger it.
@MainActor
public final class DictationLoopRoot {

    /// The binding this process listens for — the shipped ⌥Space hold-to-talk configuration.
    public let configuration: HotkeyConfiguration
    /// The hold-to-talk wiring: machine, watchdog, sink, timer.
    public let holdToTalk: Wiring
    /// The watchdog's timer, exposed so a test can turn it.
    public let watchdogTimer: any RepeatingTimer
    /// The ~1 s tap-health poll's timer.
    public let healthTimer: any RepeatingTimer
    /// The event tap, held for its lifetime (the unretained-context rule).
    public let tap: any RecoverableHotkeyEventSource
    /// The tap-health policy with its clock attached — the root's one object that keeps the
    /// disablement observer alive.
    public let tapHealth: TapHealthTimer
    /// The engine lifecycle: resolve-once, single-flight prepare, the readiness gate's truth.
    public let resolver: DictationEngineResolver
    /// Focused-app resolution — the key-down half of S1.
    public let targetResolution: TargetResolution
    /// The FAILSAFE surface the loop presents on.
    public let panel: any FailsafePresenting
    /// The download window's surface — the same store/manifest/transport the engine uses.
    public let downloadSession: (any ModelDownloadSession)?

    private let clock: any MonotonicClock
    private let readiness: EngineReadiness
    private let gate: EngineReadinessGate
    private let router: EffectRouter
    /// The one object whose deallocation frees a `CFMachPort` — held for exactly that reason.
    private let disablementObserver: CallbackSafeTapDisablement
    /// The pipeline's construction, run once the engine is prepared (`nil` when the pipeline was
    /// injected — the test shape).
    private let pipelineAssembly: (@MainActor () async throws -> DictationPipeline)?

    private let logger = Logger(subsystem: "dev.vocca.Vocca", category: "loop")

    /// - Parameters:
    ///   - audioSource: The microphone. The root wraps it in the readiness gate, so the machine
    ///     never opens the mic while the engine is unprepared.
    ///   - pipeline: The pipeline, when it can be built before the root — the test shape, where
    ///     the engine is a stub and the injector/holder are ledgers. Mutually exclusive with
    ///     `pipelineAssembly`.
    ///   - pipelineAssembly: The pipeline's construction, when the engine is not prepared yet —
    ///     the shipped shape, run by ``startEnginePreparation()`` after `prepare` succeeds.
    ///   - downloadSession: The download window's surface, `nil` when the shipped manifest could
    ///     not be loaded (a broken install — the download UI stays hidden).
    public init(
        configuration: HotkeyConfiguration,
        ceiling: Duration,
        clock: any MonotonicClock,
        audioSource: any SessionAudioSource<AudioBuffer>,
        keyState: any PhysicalKeyStateReader,
        watchdogTimer: any RepeatingTimer,
        healthTimer: any RepeatingTimer,
        deferOpening: @escaping RunLoopDeferral,
        tap: any RecoverableHotkeyEventSource,
        secureInput: any SecureInputStateReader,
        resolver: DictationEngineResolver,
        targetResolution: TargetResolution,
        panel: any FailsafePresenting,
        pipeline: DictationPipeline? = nil,
        pipelineAssembly: (@MainActor () async throws -> DictationPipeline)? = nil,
        downloadSession: (any ModelDownloadSession)? = nil
    ) {
        precondition(
            pipeline == nil || pipelineAssembly == nil,
            "the pipeline is either injected or assembled — both is a composition bug")

        let readiness = EngineReadiness()
        self.configuration = configuration
        self.clock = clock
        self.watchdogTimer = watchdogTimer
        self.healthTimer = healthTimer
        self.tap = tap
        self.resolver = resolver
        self.targetResolution = targetResolution
        self.panel = panel
        self.downloadSession = downloadSession
        self.pipelineAssembly = pipelineAssembly
        self.readiness = readiness

        let gate = EngineReadinessGate(inner: audioSource, readiness: readiness)
        self.gate = gate

        let router = EffectRouter(
            panel: panel, targetResolution: targetResolution, readiness: readiness,
            pipeline: pipeline)
        self.router = router

        let wiring = Wiring(
            configuration: configuration, ceiling: ceiling, clock: clock,
            source: gate, keyState: keyState, timer: watchdogTimer, deferOpening: deferOpening,
            deliverEffect: { [weak router] in router?.deliver($0) })
        self.holdToTalk = wiring

        // The tap-health graph: policy → source, observer → policy, and the timer retains the
        // observer so the weak edge back to the source never goes dangling. See
        // `TapHealthTimer`'s documentation — the observer is the root of the graph and this
        // object is the root's hand on it.
        let policy = TapHealthPolicy(
            source: tap, sink: wiring.scheduledWatchdog, clock: clock,
            secureInput: secureInput,
            note: { note in
                Self.logTapHealthNote(note)
            })
        let disablementObserver = CallbackSafeTapDisablement(
            policy: policy, deferRecovery: deferOpening)
        self.disablementObserver = disablementObserver
        let tapHealth = TapHealthTimer(
            policy: policy, timer: healthTimer, retaining: disablementObserver,
            reportHealth: { health in
                Self.logTapHealth(health)
            })
        self.tapHealth = tapHealth

        // The tap is created here. Without an Accessibility grant `tapCreate` returns nil and the
        // answer is `.permissionMissing` — logged, and the loop stays idle until the grant (the
        // ~1 s poll and the grant notification are the recovery, already wired above).
        Self.logTapHealth(tapHealth.arm())
    }

    // MARK: - The launch path

    /// Opens the readiness gate — the test hook, and the launch path's last step.
    ///
    /// In production this is called by ``startEnginePreparation()`` *after* the pipeline is
    /// installed, so a session that passes the gate always finds a pipeline to route into. A test
    /// calls it directly after constructing the root with an injected pipeline.
    public func markEnginePrepared() {
        readiness.markReady()
    }

    /// The launch half of the engine lifecycle: `prepare` in the background, then assemble the
    /// pipeline, then open the gate.
    ///
    /// **Not called by `configure`** — this is where model bytes arrive (a download when the
    /// artifact is missing), which is the one thing the zero-network probe must never trigger. It
    /// is `main`'s call, on the real launch path only.
    public func startEnginePreparation() {
        Task { await prepareAndAssemble() }
    }

    private func prepareAndAssemble() async {
        do {
            try await resolver.prepareIfNeeded()
        } catch {
            logger.error(
                "the engine could not be prepared: \(String(describing: error), privacy: .public)")
            // The readiness gate stays closed — sessions refuse honestly with .modelUnavailable
            // until a later preparation succeeds.
            return
        }
        if let assembly = pipelineAssembly {
            do {
                router.install(pipeline: try await assembly())
            } catch {
                logger.error(
                    "the dictation pipeline could not be assembled: \(String(describing: error), privacy: .public)")
                return
            }
        }
        // Installed before the gate opens: no session that passes the gate can find itself without
        // a pipeline when it ends.
        markEnginePrepared()
    }

    // MARK: - The inputs the sink does not carry

    /// The user abandoned the session — Escape.
    @discardableResult
    public func cancel() -> SessionEffect<AudioBuffer> {
        let effect = holdToTalk.watchdog.cancel()
        router.deliver(effect)
        holdToTalk.scheduledWatchdog.reconsider()
        return effect
    }

    /// A system event that makes continuing impossible or wrong — `NSWorkspace`'s sleep/resign
    /// notifications and the capture graph's configuration change. Wired by the owner of the
    /// notifications; the capture graph's callback is wired in `configure`.
    @discardableResult
    public func observe(_ trigger: SystemTrigger) -> SessionEffect<AudioBuffer> {
        let effect = holdToTalk.watchdog.observe(trigger)
        router.deliver(effect)
        holdToTalk.scheduledWatchdog.reconsider()
        return effect
    }

    // MARK: - The diagnostics

    private static func logTapHealth(_ health: TapHealth) {
        switch health {
        case .delivering:
            Logger(subsystem: "dev.vocca.Vocca", category: "loop")
                .info("the event tap is delivering")
        case .permissionMissing:
            Logger(subsystem: "dev.vocca.Vocca", category: "loop")
                .error("no Accessibility grant — the hotkey is deaf until it is granted")
        case .blockedBySecureInput:
            Logger(subsystem: "dev.vocca.Vocca", category: "loop")
                .info("Secure Input is in force — the hotkey is blocked until the other application lets go")
        case .notArmed, .notDelivering:
            Logger(subsystem: "dev.vocca.Vocca", category: "loop")
                .error("the event tap is not delivering")
        }
    }

    private static func logTapHealthNote(_ note: TapHealthNote) {
        Logger(subsystem: "dev.vocca.Vocca", category: "loop")
            .info("tap health: \(String(describing: note), privacy: .public)")
    }
}

// MARK: - The effect router

/// The consumer side of the effect stream: where every effect from every wiring goes, and what it
/// does about it.
///
/// The router owns the loop's hand-off points, all above the machine:
///
/// - **`.opening`** — the key-down: the target is resolved **now**, for S1's "resolve at key-down,
///   inject into that same context at key-up". The resolution is async (the AX read), so it is
///   spawned as a task the `.ended` route awaits.
/// - **`.ended`** — the key-up: the session's outcome is routed through the pipeline **into the
///   context resolved at key-down**, and the surface is presented on the panel.
/// - **`.captureUnavailable`** — the machine's refusal: when the readiness gate is what refused,
///   the honest cause is `.modelUnavailable` (PRD R5); a genuine microphone failure is the widget's
///   notice, not the failsafe's.
///
/// ## The one guard this class exists to justify
///
/// `.ended` with no pipeline installed is unreachable through the shipped graph — the readiness
/// gate opens only after ``DictationLoopRoot/prepareAndAssemble()`` installs the pipeline — but
/// the guard exists and is visible: the transcript is surfaced as the exhaustion reason rather
/// than dropped, so "never lost" holds even where the composition is wrong.
///
/// ## Isolation
///
/// `@MainActor`, like the sink that feeds it: everything the router touches (the panel, the
/// resolver, the pipeline's holder) lives in the session domain, and the `Task`s it spawns inherit
/// it.
@MainActor
private final class EffectRouter {
    private let panel: any FailsafePresenting
    private let targetResolution: TargetResolution
    private let readiness: EngineReadiness
    private var pipelineTask: Task<DictationPipeline, Never>?
    private var pendingResolution: Task<TargetContext, Never>?

    /// The context an `.ended` without any key-down resolves to — unreachable under
    /// `whenTheOwnerAsks` (every session begins with `.opening`), and the "nothing focused" shape
    /// if it ever is reached.
    private static let nothingFocused = TargetContext(
        bundleID: nil, windowTitle: nil, isSecureInput: false)

    init(
        panel: any FailsafePresenting,
        targetResolution: TargetResolution,
        readiness: EngineReadiness,
        pipeline: DictationPipeline?
    ) {
        self.panel = panel
        self.targetResolution = targetResolution
        self.readiness = readiness
        self.pipelineTask = pipeline.map { pipeline in Task { pipeline } }
    }

    /// Installs the assembled pipeline — the launch path, after `prepare` succeeds.
    func install(pipeline: DictationPipeline) {
        pipelineTask = Task { pipeline }
    }
    /// One effect from a wiring's sink.
    func deliver(_ effect: SessionEffect<AudioBuffer>) {
        switch effect {
        case .opening:
            // S1's key-down half: resolve the focused application now, so the transcript is
            // injected into the same context the user was looking at when they pressed.
            pendingResolution = Task { await targetResolution.resolve() }
        case .ended(let outcome):
            let resolution = pendingResolution
            pendingResolution = nil
            Task { [weak self] in
                guard let self else { return }
                let target = await resolution?.value ?? Self.nothingFocused
                guard let pipeline = await self.pipelineTask?.value else {
                    self.logger.error(
                        "an ended session found no pipeline — surfacing the transcript as a reason rather than dropping it")
                    self.panel.presentReasonOnly(.exhausted)
                    return
                }
                let surface = await pipeline.route(.ended(outcome), target: target)
                await self.present(surface)
            }
        case .captureUnavailable:
            if !readiness.isReady {
                panel.presentReasonOnly(.modelUnavailable)
            }
        case .unchanged, .started:
            // Nothing for the dictation half — the widget projection reads these (Task 5).
            break
        }
    }

    /// The panel half of a pipeline surface.
    private func present(_ surface: PipelineSurface) async {
        switch surface {
        case .idle:
            break
        case .transcriptHeld:
            await panel.presentHeldTranscript()
        case .reasonOnly(let reason):
            panel.presentReasonOnly(reason)
        }
    }

    private let logger = Logger(subsystem: "dev.vocca.Vocca", category: "loop")
}

// MARK: - The readiness gate

/// The single truth behind the readiness gate: is the prepared engine installed yet?
///
/// Deliberately not `@MainActor`-annotated, for the same reason ``MicrophoneSource`` is not: it is
/// read by the readiness gate, which conforms to the nonisolated ``SessionAudioSource`` seam, so
/// the annotation would make the gate's conformance illegal. The confinement is a fact about how
/// the flag is *used* — every read and write happens on the main actor (the gate's `beginCapture`
/// runs in the machine's domain, the router and `markEnginePrepared` are the root's) — and is
/// documented here because the compiler cannot see it.
final class EngineReadiness {
    private(set) var isReady = false

    func markReady() {
        isReady = true
    }
}

/// The microphone, gated on engine readiness — the "the mic never opens" half of the spec.
///
/// `beginCapture` is the machine's own refusal funnel (a `.unavailable` answer produces
/// ``SessionEffect/captureUnavailable`` with the machine left healthy), so this gate refuses
/// *through* the machine rather than beside it: the hotkey keeps working, and the router tells the
/// user the honest cause (`.modelUnavailable`) when it sees the refusal while the gate is closed.
///
/// The gate reads the same ``EngineReadiness`` the router reads, on the same actor, so the two can
/// never disagree about whether the engine is ready.
///
/// Not annotated `@MainActor`, like ``MicrophoneSource``: the seam it conforms to is nonisolated,
/// and the machine that calls it lives in the main-actor domain.
final class EngineReadinessGate: SessionAudioSource {
    typealias Buffer = AudioBuffer

    private let inner: any SessionAudioSource<AudioBuffer>
    private let readiness: EngineReadiness

    init(inner: any SessionAudioSource<AudioBuffer>, readiness: EngineReadiness) {
        self.inner = inner
        self.readiness = readiness
    }

    func beginCapture() -> CaptureStart {
        guard readiness.isReady else { return .unavailable }
        return inner.beginCapture()
    }

    func endCapture() -> AudioBuffer {
        inner.endCapture()
    }
}

/// The microphone, refusing: `configure`'s fallback when the capture graph cannot be built (a Mac
/// with no input device — every hosted CI runner). Every press is answered with
/// `.captureUnavailable`, and the machine stays healthy.
final class RefusingAudioSource: SessionAudioSource {
    typealias Buffer = AudioBuffer

    func beginCapture() -> CaptureStart {
        .unavailable
    }

    func endCapture() -> AudioBuffer {
        AudioBuffer(samples: [], sampleRate: AudioBuffer.interchangeSampleRate)
    }
}

// MARK: - The deferred custody chain

/// The journal-backed custody, assembled: the holder the ladder hands off to and the panel reads.
private struct AssembledCustody: Sendable {
    let holder: JournalTranscriptHolder
    let ladder: LadderInjector
}

/// The FAILSAFE panel's holder, when the journal is still assembling.
///
/// `configure` may not block on the journal's disk load, but the panel is built by `configure` and
/// needs a ``TranscriptHolder`` at construction. This forwards every call to the assembled holder,
/// awaiting the assembly; a journal that cannot be read answers `nil` (nothing held) on reads and
/// throws on holds, exactly as the journal itself would.
@MainActor
private final class DeferredCustody: TranscriptHolder {
    private let assembly: Task<AssembledCustody, Error>

    init(assembly: Task<AssembledCustody, Error>) {
        self.assembly = assembly
    }

    func hold(_ transcript: HeldTranscript) async throws {
        try await assembly.value.holder.hold(transcript)
    }

    func current() async -> HeldTranscript? {
        guard let custody = try? await assembly.value else { return nil }
        return await custody.holder.current()
    }

    func release() async {
        guard let custody = try? await assembly.value else { return }
        await custody.holder.release()
    }
}

/// The retry handler's ladder, when the journal is still assembling.
///
/// The same forwarding as ``DeferredCustody``, for the ⏎ affordance: a retry lands on the
/// assembled ladder, or reports the failsafe outcome if the journal could not be assembled.
@MainActor
private final class DeferredLadder: TextInjector {
    private let assembly: Task<AssembledCustody, Error>

    init(assembly: Task<AssembledCustody, Error>) {
        self.assembly = assembly
    }

    func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
        guard let custody = try? await assembly.value else {
            return InjectionResult(
                rung: .widgetFailsafe, attempted: [], verified: false, elapsed: .zero)
        }
        return await custody.ladder.inject(text, into: target)
    }
}

/// A weak reference a caller fills after construction — the two places in `configure` where the
/// graph is circular by construction (the panel's retry handler, the capture graph's
/// configuration-change callback).
///
/// `@unchecked Sendable` because the capture graph's callback is `@Sendable` and arrives on
/// whatever thread `NotificationCenter` delivers on: the box is written on the main actor and read
/// *inside* a main-actor task, so every access is confined to the main actor — the annotation is
/// the compiler's view of that confinement, not a substitute for it.
private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init() {}
}
