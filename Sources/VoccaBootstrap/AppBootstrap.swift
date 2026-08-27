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
import Combine
import OSLog
import VoccaASR
import VoccaAudio
import VoccaCore
import VoccaHotkey
import VoccaInject
import VoccaText
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
        // The *resulting policy* is checked, not the return value. Vocca's named failure mode is
        // "takes focus and types into the wrong field"; an application left in `.regular` does
        // exactly that, and it does it silently — there is no exception, no crash, just a widget
        // that steals the frontmost slot at the moment the user starts dictating.
        //
        // `setActivationPolicy` answers `false` when it made no change, and with `LSUIElement` in
        // `Info.plist` the process is *already* `.accessory` before `main` runs — so the shipped
        // app takes that branch on every single launch and logged this error every time while the
        // policy was correct all along. The return value does not distinguish "could not" from
        // "did not need to"; the policy itself does, and it is the thing the comment above is
        // actually about. `ZeroNetworkTests` asserts the same resulting policy through the probe,
        // which is why CI stayed green while every real launch logged a failure.
        _ = application.setActivationPolicy(.accessory)
        if application.activationPolicy() != .accessory {
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

        // The latency ledger every session records through, and the box the router shares with
        // the microphone: the router begins a session's record at `.opening` and the microphone
        // closes the capture-close span at key-up through this box (spec §3 — the machine's
        // single-session invariant is what makes the box's one slot safe).
        let ledger = LatencyLedger()
        let sessionBox = LatencySessionBox()

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
        //
        // Two graphs, not one: the hold-to-talk and toggle machines each own their microphone, so
        // the two can never disagree about who holds the input — the same argument the machine
        // makes for its own audio source, applied one level up. Only the active machine ever
        // opens its graph.
        let rootBox = WeakBox<DictationLoopRoot>()
        let graph = try? AudioCaptureGraph(
            ringCapacity: Self.ringCapacity,
            onConfigurationChange: { [weak rootBox] in
                Task { @MainActor in
                    guard let root = rootBox?.value else { return }
                    root.observe(.audioConfigurationChanged)
                }
            })
        let toggleGraph = try? AudioCaptureGraph(
            ringCapacity: Self.ringCapacity,
            onConfigurationChange: { [weak rootBox] in
                Task { @MainActor in
                    guard let root = rootBox?.value else { return }
                    root.observe(.audioConfigurationChanged)
                }
            })

        let microphone: any SessionAudioSource<AudioBuffer>
        if let graph, let source = try? MicrophoneSource(
            graph: graph, recorder: ledger, clock: clock,
            sessionIDProvider: { sessionBox.sessionID })
        {
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
        let toggleMicrophone: any SessionAudioSource<AudioBuffer>
        if let toggleGraph, let source = try? MicrophoneSource(
            graph: toggleGraph, recorder: ledger, clock: clock,
            sessionIDProvider: { sessionBox.sessionID })
        {
            toggleMicrophone = source
        } else {
            toggleMicrophone = RefusingAudioSource()
        }

        // MARK: The live widget
        //
        // The pill's window is created **lazily** — `LiveWidget` constructs the panel on the
        // first non-IDLE state fold, so `configure` stays window-free (the probe's charter; the
        // window-server rows of SMOKE_CHECKLIST.md are smoke rows, not CI's). What is built here
        // is the level source the waveform draws: **both** graphs', combined, because only the
        // active mode's graph is ever started and the widget must track whichever that is
        // (`PRODUCT_SPEC.md:87-88`).
        //
        // Naming one graph here is what broke the waveform when toggle became the default: the
        // level stayed wired to the hold-to-talk graph, which no longer runs, so `latestLevel()`
        // answered 0 for the whole session and the pill drew thirteen identical dashes over a
        // working microphone. `CombinedLevelSource` removes the standing bet rather than moving
        // it — see its header for why the maximum is the running graph's level.
        //
        // A Mac with no input device has no graph to read, and the honest answer is the same 0 a
        // stopped graph publishes: silent bars, never a ghost.
        let liveLevel: any LiveLevelSource = CombinedLevelSource(
            [graph, toggleGraph].compactMap { $0 }.map { MicrophoneLevelSource(graph: $0) })

        // MARK: The cleanup resolver
        //
        // The one cleanup provider for the process, resolved once at launch from the hand-edited
        // `cleanup-config.json` (`cleanup-config` M7): absent file ⇒ rules (the zero-network
        // default); `ollama`/`byok` ⇒ a rules-then-LLM chain behind the same `CleanupProvider`
        // seam. The real transport and keychain adapters are wired here; the egress badge is
        // folded into the widget store from the resolved provider's `requiresNetwork` + endpoint
        // below (`egress-badge`, `root-wiring`).
        let cleanupStore = CleanupConfigStore()
        let cleanupResolver = CleanupResolver(
            store: cleanupStore,
            transport: { DefaultLLMTransport() },
            keyProvider: { SystemKeychainKeyProvider() })

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
                    engine: engine, injector: custody.ladder, holder: custody.holder,
                    recorder: ledger, clock: clock,
                    cleanup: try await cleanupResolver.resolve())
            },
            downloadSession: downloadSession,
            recorder: ledger,
            sessionBox: sessionBox,
            toggleConfiguration: HotkeyConfiguration(
                keyCode: Self.shippedHotkeyKeyCode, modifiers: [.option], activation: .toggle),
            toggleSource: toggleMicrophone,
            toggleTimer: MainRunLoopTimer(),
            runningAppName: SystemRunningAppName(),
            widgetClock: MainRunLoopTimer(),
            liveLevel: liveLevel)
        rootBox.value = root

        // The egress fold: the resolved provider's `requiresNetwork` + endpoint, folded into the
        // widget store exactly once at launch (resolve-once — a mid-session provider swap is
        // structurally impossible). `configure` is synchronous and the resolver is async, so the
        // fold runs on the main actor in a launch task, the `custodyTask` precedent. The default
        // path folds `.none` — also the reducer's default — so the zero-network probe's
        // `egress=none` is byte-for-byte correct before this task lands.
        Task {
            guard let cleanup = try? await cleanupResolver.resolve() else { return }
            let egress = WidgetEgressState.fromResolvedProvider(
                requiresNetwork: cleanup.requiresNetwork,
                endpoint: await cleanupResolver.egressEndpoint())
            root.widgetStore.setEgress(egress)
        }
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
        attachMenuBarItem(to: root)
        root.startEnginePreparation()
        application.run()
    }

    /// Creates the status item and binds it to the root's conditions.
    ///
    /// **In `main()`, never in `configure`.** `NSStatusBar.system` is a window-server object, and
    /// `configure` is what the zero-network probe drives — the same rule that keeps `LiveWidget`'s
    /// panel lazy. A hosted runner has no menu bar to attach to, so nothing below this line runs
    /// in CI; every decision it would make was taken above the seam in `MenuBarStateReducer` and
    /// `MenuBarCopy`, which are tested there.
    ///
    /// The item is retained by the root for the process's lifetime. A status item that is
    /// deallocated silently vanishes from the menu bar — which is precisely the disappearance this
    /// surface exists to end.
    @MainActor
    private static func attachMenuBarItem(to root: DictationLoopRoot) {
        let item = MenuBarItem(
            hotkey: shippedHotkeyDisplayName,
            onAction: { state in
                switch state {
                case .noAccessibility:
                    SystemSettingsPane.open(at: SystemSettingsPane.accessibilityPanePath)
                case .noMicrophone:
                    SystemSettingsPane.open(at: SystemSettingsPane.microphonePanePath)
                case .downloadingModel, .ready, .listening, .transcribing, .secureInput:
                    break
                }
            },
            onOpenSettings: { [weak root] in root?.showSettings() },
            onQuit: { NSApplication.shared.terminate(nil) })
        root.menuBarItem = item
        root.onMenuBarConditionsChanged = { [weak item] conditions in
            item?.apply(MenuBarStateReducer.state(for: conditions))
        }
        item.apply(MenuBarStateReducer.state(for: root.menuBarConditions))

        // The session's phase, taken from the widget's own store rather than tracked a second
        // time — so the icon and the pill can never disagree about whether Vocca is listening.
        // OPENING counts as capturing: the microphone is coming up and the system indicator is
        // about to light, and an icon still saying "ready" would be a beat behind the hardware.
        root.menuBarPhaseObservation = root.widgetStore.$state.sink { [weak root] state in
            MainActor.assumeIsolated {
                root?.updateMenuBarConditions { conditions in
                    switch state.state {
                    case .opening, .recording:
                        conditions.isCapturing = true
                        conditions.isTranscribing = false
                    case .transcribing:
                        conditions.isCapturing = false
                        conditions.isTranscribing = true
                    case .idle, .delivered:
                        conditions.isCapturing = false
                        conditions.isTranscribing = false
                    }
                }
            }
        }
    }

    /// The shipped chord, in the form a person reads.
    public static let shippedHotkeyDisplayName = "⌥Space"

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

// MARK: - The dictation modes

/// The two configurations of the same machine the root wires — the active one receives the tap's
/// events, the other is constructed and owned (R6; the mode-selection control is the settings
/// surface's, out of scope here).
public enum DictationMode: Sendable, Hashable {
    /// ⌥Space hold-to-talk: the user's finger is the endpointer.
    case holdToTalk
    /// ⌥Space toggle: bounded by the ceiling, `.tapDisabled` and the system triggers instead.
    case toggle
}

// MARK: - The display-name seam

/// The target application's display name, as the widget's "→ Slack" indicator needs it.
///
/// Resolved from a bundle identifier through `NSRunningApplication.localizedName` at ship; the
/// seam exists so the composed-loop tests can dictate the answer. Read at key-down for the
/// OPENING state and again at key-up for DELIVERED — both times from the same `TargetContext`,
/// per S1's "resolve at key-down, inject into that same context at key-up".
public protocol RunningAppNameReading: AnyObject {
    /// The focused application's localized name for `bundleID`, or `nil` when no running
    /// application carries it.
    func displayName(bundleID: String) -> String?
}

/// The shipped ``RunningAppNameReading``: `NSRunningApplication`'s own answer, in the one place
/// the composition root reads the running-app table.
public final class SystemRunningAppName: RunningAppNameReading {

    public init() {}

    public func displayName(bundleID: String) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.localizedName
    }
}

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
    /// The toggle wiring: the same composition, `activation: .toggle`, constructed and owned.
    /// It receives the tap's events only while it is the active mode.
    public let toggle: Wiring
    /// Which configuration currently receives the tap's events.
    ///
    /// **`.toggle` is the shipped default**: ⌥Space starts listening, ⌥Space again stops it. The
    /// founder chose it over hold-to-talk after the hold gesture's failure mode showed up on the
    /// first real dictation — a press too brief to capture 0.3 s of audio, which is easy to do
    /// when the key must be held for the whole utterance. Toggle removes the class of press that
    /// is accidentally short, because neither end of the session is a release the user has to
    /// sustain.
    ///
    /// It does not *replace* the sub-minimum guard, and must not be read as having fixed it: a
    /// press and an immediate second press still capture almost nothing. That case answers empty
    /// in the engine (`ASREngine`'s contract) rather than being made unreachable here.
    ///
    /// Hold-to-talk remains fully wired and is one `setActiveMode(_:)` away; the control that
    /// offers the choice is still the settings surface's, which is why this is a default rather
    /// than a preference.
    ///
    /// Read from ``defaultMode`` rather than written here, because this property and the routing
    /// sink's initial `active` must name the same wiring: set independently, `activeMode` would
    /// report a mode the tap's events were not going to, and `setActiveMode(_:)` would then refuse
    /// the very switch that would repair it (`mode != activeMode` is already false).
    public private(set) var activeMode: DictationMode = DictationLoopRoot.defaultMode

    /// The mode a freshly constructed root starts in — the one place the shipped default is
    /// written, read by both ``activeMode`` and the routing sink's initial target.
    public static let defaultMode: DictationMode = .toggle

    // MARK: - The menu bar's conditions

    /// What the menu bar item should be saying, recomputed whenever any input to it changes.
    ///
    /// Held here rather than in `VoccaUI` because this is the only object that can see all of the
    /// inputs at once: the tap's health, the engine's readiness, and the widget store's phase.
    /// The *reduction* is `MenuBarStateReducer`'s and is tested headlessly; this is only the
    /// gathering.
    public private(set) var menuBarConditions = MenuBarConditions(isEnginePrepared: false)

    /// The widget-store observation that keeps the menu bar's phase in step. Retained here so it
    /// outlives `attachMenuBarItem`.
    public var menuBarPhaseObservation: AnyCancellable?

    /// The settings window, built on first use and kept for the process's lifetime.
    ///
    /// Lazy for the reason every window in this app is lazy: `configure` is driven by the
    /// zero-network probe and may create nothing a window server is needed for.
    private var settingsWindow: SettingsWindow?

    /// Opens settings, building the window and its bindings the first time.
    ///
    /// The bindings are closures over what the root already holds, so the window never learns
    /// about the loop and the loop never learns about SwiftUI.
    public func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(
                bindings: SettingsBindings(
                    isToggleMode: { [weak self] in self?.activeMode == .toggle },
                    setToggleMode: { [weak self] isToggle in
                        // `setActiveMode` refuses mid-session and logs; the window does not need to
                        // know that, and a user who changes this while dictating gets the change on
                        // their next press rather than a broken session.
                        self?.setActiveMode(isToggle ? .toggle : .holdToTalk)
                    },
                    hotkeyDisplayName: AppBootstrap.shippedHotkeyDisplayName,
                    engineDisplayName: { EngineSelection.defaultSelection.tier.engine.displayName },
                    cleanupSummary: { ("Built-in rules", nil) },
                    // The same store the rules engine reads from, so an edit here is an edit the
                    // next dictation applies — not a second copy of the file that drifts from it.
                    loadDictionary: { await FileSystemDictionaryStore().load() },
                    saveDictionary: { try await FileSystemDictionaryStore().save($0) }))
        }
        settingsWindow?.show()
    }

    /// The status item, retained for the process's lifetime once `main()` has made one. `nil`
    /// under the probe and in every headless test, which is what keeps `configure` window-free.
    public var menuBarItem: MenuBarItem?

    /// Called on every change to ``menuBarConditions``. `main()` connects the status item here;
    /// `configure` leaves it nil, which is what keeps the composition root window-free for the
    /// zero-network probe — `NSStatusBar` is a window-server object like any panel.
    public var onMenuBarConditionsChanged: ((MenuBarConditions) -> Void)?

    /// Applies a change to the conditions and notifies, if anything actually moved.
    ///
    /// The guard matters: the health poll runs about once a second for as long as Vocca does, and
    /// an unconditional notify would rebuild the menu under a user who has it open.
    public func updateMenuBarConditions(_ mutate: (inout MenuBarConditions) -> Void) {
        var next = menuBarConditions
        mutate(&next)
        guard next != menuBarConditions else { return }
        menuBarConditions = next
        onMenuBarConditionsChanged?(next)
    }
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
    /// The live widget's observable state — the root folds every effect through the projection.
    public let widgetStore: WidgetStateStore
    /// The live pill's window, held for its lifetime and constructed lazily: no window exists
    /// until the store's first non-IDLE state fold (``LiveWidget`` — `configure` stays
    /// window-free). Bound to the same store the effect stream feeds, with the level source
    /// the root injected.
    public let liveWidget: LiveWidget
    /// The widget clock: the timer whose fires drive ``WidgetStateStore/timerFired(_:)`` while
    /// the widget is in a time-driven state.
    public let widgetClock: any RepeatingTimer
    /// The display-name reader behind the widget's "→ Slack" indicator.
    public let runningAppName: RunningAppNameReading
    /// The latency ledger, when the wired recorder is one — the loop's own numbers, inspectable
    /// but not writable through the root (spec §5, W5). Reading only, and honest about its
    /// type: a recorder that is not a ``LatencyLedger`` (none exists today) leaves this `nil`
    /// rather than pretending an actor behind a different seam is one.
    public let latencyLedger: LatencyLedger?

    /// The cadence the widget clock fires at — the display's refresh rate for the elapsed timer
    /// and the DELIVERED collapse's resolution. One hundred milliseconds: ~10 updates per second,
    /// which is a smooth-enough stopwatch against the 3 s surface threshold and a collapse
    /// deadline of 600 ms. Named here because it is the root's clock, not the reducer's.
    public static let widgetClockCadence: Duration = .milliseconds(100)

    private let clock: any MonotonicClock
    private let readiness: EngineReadiness
    private let gate: EngineReadinessGate
    private let toggleGate: EngineReadinessGate
    private let router: EffectRouter
    private let modeRouting: ModeRoutingSink
    /// The one object whose deallocation frees a `CFMachPort` — held for exactly that reason.
    private let disablementObserver: CallbackSafeTapDisablement
    /// The weak hand the tap's sink reaches the root's cancel router through. The graph is
    /// circular by construction — the root owns the sink and the sink routes the session's
    /// cancel key back to the root — so the box is filled as the last step of this initializer,
    /// the ``configure`` `WeakBox` pattern for exactly this shape.
    private let cancelRouterBox = WeakBox<DictationLoopRoot>()
    /// The pipeline's construction, run once the engine is prepared (`nil` when the pipeline was
    /// injected — the test shape).
    private let pipelineAssembly: (@MainActor () async throws -> DictationPipeline)?

    private let logger = Logger(subsystem: "dev.vocca.Vocca", category: "loop")

    /// - Parameters:
    ///   - audioSource: The microphone. The root wraps it in the readiness gate, so the machine
    ///     never opens the mic while the engine is unprepared.
    ///   - toggleSource: The toggle configuration's own microphone — the same gate, a separate
    ///     graph, so the two machines can never disagree about who owns the input.
    ///   - toggleTimer: The toggle wiring's watchdog timer.
    ///   - runningAppName: The display-name reader behind the widget's target indicator.
    ///   - widgetClock: The timer whose fires drive the widget store's time-based folds.
    ///   - liveLevel: The input level the widget's waveform draws. The shipped composition
    ///     injects `MicrophoneLevelSource` over the hold-to-talk capture graph; a test injects a
    ///     fake. No window is created here — the root's ``liveWidget`` constructs its panel
    ///     lazily, on the store's first non-IDLE fold.
    ///   - pipeline: The pipeline, when it can be built before the root — the test shape, where
    ///     the engine is a stub and the injector/holder are ledgers. Mutually exclusive with
    ///     `pipelineAssembly`.
    ///   - pipelineAssembly: The pipeline's construction, when the engine is not prepared yet —
    ///     the shipped shape, run by ``startEnginePreparation()`` after `prepare` succeeds.
    ///   - downloadSession: The download window's surface, `nil` when the shipped manifest could
    ///     not be loaded (a broken install — the download UI stays hidden).
    ///   - recorder: The latency ledger's seam, `nil` by default — the loop-wiring wiring
    ///     decision; the router begins a session's record at `.opening` and finalizes on every
    ///     terminal only when one is wired.
    ///   - sessionBox: The box the microphone reads the record's id from at `endCapture()`,
    ///     `nil` by default with the same absence effect.
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
        downloadSession: (any ModelDownloadSession)? = nil,
        recorder: (any LatencyRecorder)? = nil,
        sessionBox: LatencySessionBox? = nil,
        toggleConfiguration: HotkeyConfiguration,
        toggleSource: any SessionAudioSource<AudioBuffer>,
        toggleTimer: any RepeatingTimer,
        runningAppName: RunningAppNameReading,
        widgetClock: any RepeatingTimer,
        liveLevel: any LiveLevelSource
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
        self.latencyLedger = recorder as? LatencyLedger
        self.pipelineAssembly = pipelineAssembly
        self.readiness = readiness
        self.widgetClock = widgetClock
        self.runningAppName = runningAppName

        let gate = EngineReadinessGate(inner: audioSource, readiness: readiness)
        self.gate = gate
        let toggleGate = EngineReadinessGate(inner: toggleSource, readiness: readiness)
        self.toggleGate = toggleGate

        let widgetStore = WidgetStateStore(clock: clock, ceiling: ceiling)
        self.widgetStore = widgetStore

        // The live pill, bound to that store and the injected level source. The window itself is
        // created lazily on the first non-IDLE fold — see `LiveWidget` — so nothing here touches
        // the window server.
        let liveWidget = LiveWidget(store: widgetStore, level: liveLevel)
        self.liveWidget = liveWidget

        let router = EffectRouter(
            panel: panel, targetResolution: targetResolution, readiness: readiness,
            pipeline: pipeline, runningAppName: runningAppName, widgetStore: widgetStore,
            widgetClock: widgetClock, recorder: recorder, sessionBox: sessionBox)
        self.router = router

        let deliver: (SessionEffect<AudioBuffer>) -> Void = { [weak router] in
            router?.deliver($0)
        }
        let holdToTalk = Wiring(
            configuration: configuration, ceiling: ceiling, clock: clock,
            source: gate, keyState: keyState, timer: watchdogTimer, deferOpening: deferOpening,
            deliverEffect: deliver)
        self.holdToTalk = holdToTalk
        let toggle = Wiring(
            configuration: toggleConfiguration, ceiling: ceiling, clock: clock,
            source: toggleGate, keyState: keyState, timer: toggleTimer, deferOpening: deferOpening,
            deliverEffect: deliver)
        self.toggle = toggle

        // The tap delivers into whichever configuration is active; the inactive one receives
        // nothing, so its machine can never open the microphone. The session's cancel key —
        // Escape — is intercepted before the fan-out and routed to the root's cancel router,
        // which knows what is in flight and what to cancel (PRODUCT_SPEC.md:129). The router is
        // reached through a weak box filled at the end of this initializer: the graph is circular
        // by construction (the root owns the sink, the sink routes back to the root), and the
        // box is the pattern `configure` uses for exactly this shape.
        // Derived from the same `defaultMode` as `activeMode`, never named directly: the two are
        // one fact, and a root whose reported mode and actual route disagree is a hotkey that
        // silently drives the wrong machine.
        let initialRoute: ScheduledWatchdog<AudioBuffer>
        switch Self.defaultMode {
        case .holdToTalk: initialRoute = holdToTalk.scheduledWatchdog
        case .toggle: initialRoute = toggle.scheduledWatchdog
        }
        let modeRouting = ModeRoutingSink(
            active: initialRoute,
            sessionCancelKey: { [weak cancelRouterBox] event in
                cancelRouterBox?.value?.handleSessionCancelKey(event) ?? .passThrough
            })
        self.modeRouting = modeRouting

        // The tap-health graph: policy → source, observer → policy, and the timer retains the
        // observer so the weak edge back to the source never goes dangling. See
        // `TapHealthTimer`'s documentation — the observer is the root of the graph and this
        // object is the root's hand on it.
        let policy = TapHealthPolicy(
            source: tap, sink: modeRouting, clock: clock,
            secureInput: secureInput,
            note: { note in
                Self.logTapHealthNote(note)
            })
        let disablementObserver = CallbackSafeTapDisablement(
            policy: policy, deferRecovery: deferOpening)
        self.disablementObserver = disablementObserver
        let tapHealth = TapHealthTimer(
            policy: policy, timer: healthTimer, retaining: disablementObserver,
            reportHealth: { [weak cancelRouterBox] health in
                Self.logTapHealth(health)
                // The translation from `TapHealth` to the menu's plain facts lives here, in the
                // one place that already knows both the tap and the widget. `VoccaUI` stays free
                // of any dependency on `VoccaHotkey` for it.
                cancelRouterBox?.value?.updateMenuBarConditions { conditions in
                    conditions.isHotkeyDeafForPermission = health == .permissionMissing
                    conditions.isBlockedBySecureInput = health == .blockedBySecureInput
                }
            })
        self.tapHealth = tapHealth

        // The tap is created here. Without an Accessibility grant `tapCreate` returns nil and the
        // answer is `.permissionMissing` — logged, and the loop stays idle until the grant (the
        // ~1 s poll and the grant notification are the recovery, already wired above).
        Self.logTapHealth(tapHealth.arm())

        // The last step: the tap's sink can now reach this object's cancel router. The box is
        // deliberately filled last, so no path that could fire before the initializer finished —
        // none exists, but the ordering is the point — would find a half-built root.
        cancelRouterBox.value = self
    }

    // MARK: - The modes

    /// Switches which configuration receives the tap's events.
    ///
    /// The mode-selection control belongs to the settings surface (out of scope); this is the
    /// wiring seam the tests drive. A switch is refused while either machine has a session in
    /// flight — moving the tap's route mid-session would orphan the microphone — and logged.
    public func setActiveMode(_ mode: DictationMode) {
        guard mode != activeMode else { return }
        guard holdToTalk.machine.state == .idle, toggle.machine.state == .idle else {
            logger.error(
                "refusing to switch mode while a session is in flight — end it first")
            return
        }
        activeMode = mode
        switch mode {
        case .holdToTalk:
            modeRouting.active = holdToTalk.scheduledWatchdog
        case .toggle:
            modeRouting.active = toggle.scheduledWatchdog
        }
    }

    /// The wiring the current mode drives.
    private var activeWiring: Wiring {
        switch activeMode {
        case .holdToTalk: return holdToTalk
        case .toggle: return toggle
        }
    }

    // MARK: - The launch path

    /// Opens the readiness gate — the test hook, and the launch path's last step.
    ///
    /// In production this is called by ``startEnginePreparation()`` *after* the pipeline is
    /// installed, so a session that passes the gate always finds a pipeline to route into. A test
    /// calls it directly after constructing the root with an injected pipeline.
    public func markEnginePrepared() {
        readiness.markReady()
        updateMenuBarConditions { $0.isEnginePrepared = true }
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
        let active = activeWiring
        let effect = active.watchdog.cancel()
        router.deliver(effect)
        active.scheduledWatchdog.reconsider()
        return effect
    }

    /// **The tap's Escape key-down, routed** (`PRODUCT_SPEC.md:129` — "Esc during `OPENING`,
    /// `RECORDING` or `TRANSCRIBING` aborts and discards").
    ///
    /// The sink intercepts the session's cancel key before the machine's rule path — which would
    /// pass a non-binding key straight through — and calls here. Two halves of the loop can be
    /// in flight, and this answers each:
    ///
    /// - **A session** (the machine is opening or recording): ``cancel()`` — the machine's own
    ///   discard path, `.userCancelled`, the one `EndReason` permitted to throw the audio away.
    ///   An Escape inside the opening window is held by the machine's deferred-stop funnel and
    ///   applied the instant the session exists (`SessionMachine.swift:619-626`).
    /// - **A transcription** (the session ended, the pipeline is in the engine's hands):
    ///   ``EffectRouter/cancelTranscription()`` — the in-flight route task is cancelled, and a
    ///   cancelled transcription never injects (`DictationPipeline` checks its own cancellation
    ///   at every decision boundary).
    ///
    /// Nothing in flight: the Escape is the user's own key and passes through untouched. The
    /// disposition is ``SessionKeyPolicy``'s own answer, in both directions.
    private func handleSessionCancelKey(_ event: RawKeyEvent) -> EventPropagation {
        let wiring = activeWiring
        let sessionInFlight =
            wiring.machine.hasPendingOpening || wiring.machine.state == .recording
        let transcriptionInFlight = router.hasTranscriptionInFlight
        if sessionInFlight {
            cancel()
        } else if transcriptionInFlight {
            router.cancelTranscription()
        }
        return SessionKeyPolicy.propagation(
            for: event, sessionInFlight: sessionInFlight || transcriptionInFlight)
    }

    /// A system event that makes continuing impossible or wrong — `NSWorkspace`'s sleep/resign
    /// notifications and the capture graph's configuration change. Wired by the owner of the
    /// notifications; the capture graph's callback is wired in `configure`.
    @discardableResult
    public func observe(_ trigger: SystemTrigger) -> SessionEffect<AudioBuffer> {
        let active = activeWiring
        let effect = active.watchdog.observe(trigger)
        router.deliver(effect)
        active.scheduledWatchdog.reconsider()
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

/// The session record's id, shared between the router (writes it at `.opening`) and the
/// microphone (reads it at `endCapture`) — the one slot of mutable state the composition root
/// is allowed.
///
/// `@unchecked Sendable` is permitted here because the lint is Core-only, and this class is
/// the spec's sanctioned exception (spec "Isolation decisions"): the router writes the slot on
/// the main actor at `.opening` and the microphone reads it on the stop path — ordered because
/// `.opening` delivery happens-before `beginCapture`, which happens-before `endCapture` at
/// key-up (spec §3). The single slot is safe only under the machine's **single-session
/// invariant** — one session at a time, from every terminal path — which the machine
/// guarantees; a second concurrent session would clobber the slot, and is impossible by
/// construction.
public final class LatencySessionBox: @unchecked Sendable {
    /// The in-flight session's record id, `nil` between sessions.
    public var sessionID: SessionRecord.ID?

    public init() {}
}

/// The consumer side of the effect stream: where every effect from every wiring goes, and what it
/// does about it.
///
/// The router owns the loop's hand-off points, all above the machine:
///
/// - **Every effect feeds the widget projection** — ``WidgetProjection/project(effect:targetAppName:)``
///   folded into the ``WidgetStateStore``, so the live widget and the dictation half read the same
///   stream.
/// - **`.opening`** — the key-down: the target is resolved **now**, for S1's "resolve at key-down,
///   inject into that same context at key-up". The resolution is async (the AX read), so it is
///   spawned as a task the `.ended` route awaits; the OPENING name fills in when the resolution
///   lands, guarded so a later fold never regresses a session that has already started.
/// - **`.ended`** — the key-up: the session's outcome is routed through the pipeline **into the
///   context resolved at key-down**, and the surface is presented on the panel. The pipeline's
///   two finishes become the projection's two events: a delivered transcript shows the DELIVERED
///   confirmation with the target's name; anything else returns the widget to IDLE.
/// - **`.captureUnavailable`** — the machine's refusal: when the readiness gate is what refused,
///   the honest cause is `.modelUnavailable` (PRD R5); a genuine microphone failure is the
///   widget's notice.
///
/// ## The widget clock
///
/// The router also drives the store's time-based folds: while the widget is in a time-driven
/// state (RECORDING or DELIVERED), the injected ``RepeatingTimer`` fires both ``WidgetTimer``
/// events each turn — each a no-op outside its own state, per the reducer's contract — and stops
/// when the state leaves them (the DELIVERED collapse ends the clock by itself).
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
/// resolver, the store, the pipeline's holder) lives in the session domain, and the `Task`s it
/// spawns inherit it.
@MainActor
private final class EffectRouter {
    private let panel: any FailsafePresenting
    private let targetResolution: TargetResolution
    private let readiness: EngineReadiness
    private let runningAppName: RunningAppNameReading
    private let widgetStore: WidgetStateStore
    private let widgetClock: any RepeatingTimer
    /// The latency ledger, when the composition wired one — `nil` keeps the router exactly as it
    /// was before the loop-wiring phase: no session begins, nothing finalizes.
    private let recorder: (any LatencyRecorder)?
    /// The box the microphone reads the session's record id from at `endCapture()` — written by
    /// the mint below, cleared with ``pendingSessionID`` on every terminal.
    private let sessionBox: LatencySessionBox?
    private var pipelineTask: Task<DictationPipeline, Never>?
    private var pendingResolution: Task<(target: TargetContext, name: String), Never>?
    /// **The in-flight session's record id** — the router's own copy of the box's slot, written
    /// by the mint once `beginSession` answers. `nil` between sessions and on the no-recorder
    /// composition.
    private var pendingSessionID: SessionRecord.ID?
    /// **The mint**: `beginSession` for the session whose `.opening` was delivered. Every
    /// terminal awaits the same mint — so a `.captureUnavailable` arriving before the mint
    /// answered still finalizes the id it will mint, never a stale or a missing one.
    private var pendingBeginSession: Task<SessionRecord.ID, Never>?
    /// **The in-flight transcription**: the task that runs an ended session's audio through the
    /// pipeline. Esc during TRANSCRIBING cancels it (`PRODUCT_SPEC.md:129`); the handle is what
    /// makes the in-flight transcribe cancellable at all.
    private var transcriptionTask: Task<Void, Never>?

    /// Whether a transcription is in flight — the router's half of "something is in flight" for
    /// the session's cancel key, read *before* any cancellation clears it.
    var hasTranscriptionInFlight: Bool { transcriptionTask != nil }

    /// **Esc during TRANSCRIBING**: cancel the in-flight transcription and return the widget to
    /// IDLE.
    ///
    /// The cancelled task's own body returns before it presents anything (see `.ended`'s guard),
    /// so without this fold the pill would sit in TRANSCRIBING forever — the waveform frozen over
    /// a discard the user asked for. The pipeline itself honours the cancellation at every
    /// decision boundary (`DictationPipeline`), so a cancelled transcription never injects.
    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        widgetStore.fold(WidgetProjection.project(event: .finishedWithoutDelivery))
        settleWidgetClock()
    }

    /// The context an `.ended` without any key-down resolves to — unreachable under
    /// `whenTheOwnerAsks` (every session begins with `.opening`), and the "nothing focused" shape
    /// if it ever is reached.
    private static let nothingFocused = TargetContext(
        bundleID: nil, windowTitle: nil, isSecureInput: false)

    init(
        panel: any FailsafePresenting,
        targetResolution: TargetResolution,
        readiness: EngineReadiness,
        pipeline: DictationPipeline?,
        runningAppName: RunningAppNameReading,
        widgetStore: WidgetStateStore,
        widgetClock: any RepeatingTimer,
        recorder: (any LatencyRecorder)?,
        sessionBox: LatencySessionBox?
    ) {
        self.panel = panel
        self.targetResolution = targetResolution
        self.readiness = readiness
        self.runningAppName = runningAppName
        self.widgetStore = widgetStore
        self.widgetClock = widgetClock
        self.recorder = recorder
        self.sessionBox = sessionBox
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
            // injected into the same context the user was looking at when they pressed. The
            // OPENING state is folded immediately with a placeholder name — the widget must react
            // within a frame, and the name is display-only — and the resolution's guarded re-fold
            // fills it in.
            //
            // The session's latency record begins here too: `beginSession` mints the id, and the
            // mint's completion stores it in the box — where the microphone's `endCapture` reads
            // it at key-up — and in router state. The ledger is an actor, so the mint is a task;
            // `.opening` delivery happens-before `beginCapture` happens-before `endCapture`
            // (spec §3), and the terminals below await the same mint rather than assuming the
            // write landed.
            if let recorder {
                let box = sessionBox
                let mint = Task { await recorder.beginSession() }
                pendingBeginSession = mint
                Task { [weak self] in
                    guard let self else { return }
                    let id = await mint.value
                    box?.sessionID = id
                    self.pendingSessionID = id
                }
            }
            pendingResolution = Task { await resolveTarget() }
            foldEffect(effect, appName: "")
        case .ended(let outcome):
            let resolution = pendingResolution
            pendingResolution = nil
            let mint = pendingBeginSession
            // The effect fold: `.ended(.cancelled)` → IDLE, `.ended(.completed)` → TRANSCRIBING
            // (the waveform freeze — `WidgetProjection`'s own table).
            foldEffect(effect, appName: "")
            let task = Task { [weak self] in
                guard let self else { return }
                defer { self.transcriptionTask = nil }
                let (target, name) = await resolution?.value ?? (Self.nothingFocused, "")
                let sessionID = await mint?.value
                guard let pipeline = await self.pipelineTask?.value else {
                    self.logger.error(
                        "an ended session found no pipeline — surfacing the transcript as a reason rather than dropping it")
                    // The one terminal that never reaches the pipeline still owes its record:
                    // finalized failed, attributed to no engine.
                    if let sessionID, let recorder = self.recorder {
                        _ = await recorder.finalize(id: sessionID, outcome: .failed, engine: nil)
                    }
                    self.clearPendingSession()
                    self.panel.presentReasonOnly(.exhausted)
                    return
                }
                let surface = await pipeline.route(.ended(outcome), target: target, sessionID: sessionID)
                // The route finalized the record on every path it ran (its own table, W1) — the
                // router's half is only to let the id go, so the next session begins a fresh
                // record rather than inheriting this one's.
                self.clearPendingSession()
                guard !Task.isCancelled else {
                    // Esc during TRANSCRIBING: the cancel router already folded IDLE and a
                    // cancelled transcription must never present — least of all as DELIVERED.
                    return
                }
                await self.present(surface, outcome: outcome, target: target, name: name)
            }
            // Held so that the cancel key can reach it: the handle *is* the cancellable
            // transcription (`cancelTranscription`), and it is cleared by the task's own defer.
            transcriptionTask = task
        case .captureUnavailable:
            if let recorder, let mint = pendingBeginSession {
                // The one terminal that never reaches the pipeline: a capture that never
                // happened still owes its record — finalized failed, attributed to no engine.
                // Awaited through the same mint, so the finalize lands even when the refusal
                // arrives before the mint answered (the deferred-opening shape).
                Task { [weak self] in
                    guard let self else { return }
                    let id = await mint.value
                    _ = await recorder.finalize(id: id, outcome: .failed, engine: nil)
                    self.clearPendingSession()
                }
            }
            if readiness.isReady {
                // A genuine microphone failure: the widget's notice.
                foldEffect(effect, appName: "")
            } else {
                // The readiness gate refused — the honest cause is the model not being ready
                // (PRD R5's .modelUnavailable), shown by the panel.
                panel.presentReasonOnly(.modelUnavailable)
            }
        case .unchanged, .started:
            foldEffect(effect, appName: "")
        }
    }

    /// The terminal half of a record: release the id from the box and from router state. The
    /// finalize is the caller's — every terminal finalizes before it clears.
    private func clearPendingSession() {
        pendingSessionID = nil
        pendingBeginSession = nil
        sessionBox?.sessionID = nil
    }

    // MARK: - The widget fold

    /// Fold one machine effect through the projection.
    private func foldEffect(_ effect: SessionEffect<AudioBuffer>, appName: String) {
        widgetStore.fold(WidgetProjection.project(effect: effect, targetAppName: appName))
        settleWidgetClock()
    }

    /// Fold one pipeline-phase event through the projection.
    private func foldPipelineEvent(_ event: WidgetProjectionEvent) {
        widgetStore.fold(WidgetProjection.project(event: event))
        settleWidgetClock()
    }

    /// Make the widget clock match the store's state: time-driven states run it, everything else
    /// stops it.
    private func settleWidgetClock() {
        switch widgetStore.state.state {
        case .recording, .delivered:
            guard widgetClock.interval == nil else { return }
            widgetClock.start(every: DictationLoopRoot.widgetClockCadence) { [weak self] in
                self?.widgetClockFire()
            }
        case .idle, .opening, .transcribing:
            widgetClock.stop()
        }
    }

    /// One turn of the widget clock: fire both timers — each a no-op outside its own state, per
    /// the reducer's contract — and stop when the state has left the time-driven ones (the
    /// DELIVERED collapse ends the clock by itself).
    private func widgetClockFire() {
        widgetStore.timerFired(.recording)
        widgetStore.timerFired(.deliveredCollapse)
        switch widgetStore.state.state {
        case .recording, .delivered:
            break
        case .idle, .opening, .transcribing:
            widgetClock.stop()
        }
    }

    // MARK: - The key-down resolution

    /// The S1 key-down resolution: the focused context, and the display name the widget shows.
    /// The name is re-folded into OPENING when the resolution lands — guarded, so a session that
    /// has already started is never regressed back to OPENING by a slow name.
    private func resolveTarget() async -> (target: TargetContext, name: String) {
        let target = await targetResolution.resolve()
        let name = displayName(for: target)
        if case .opening = widgetStore.state.state {
            widgetStore.fold(.state(.opening(targetAppName: name)))
        }
        return (target, name)
    }

    /// The display name for a resolved context: the running application's localized name, then
    /// the window title, then nothing — the widget's "→ Slack" indicator.
    private func displayName(for target: TargetContext) -> String {
        target.bundleID.flatMap { runningAppName.displayName(bundleID: $0) }
            ?? target.windowTitle ?? ""
    }

    // MARK: - The pipeline surface

    /// The panel and projection halves of a pipeline surface.
    private func present(
        _ surface: PipelineSurface,
        outcome: SessionOutcome<AudioBuffer>,
        target: TargetContext,
        name: String
    ) async {
        switch surface {
        case .idle:
            switch outcome.content {
            case .cancelled:
                // The effect fold already landed IDLE — the discard is the user's instruction.
                break
            case .completed(_, let audio, _):
                // The two finishes, split on the empty-buffer policy (empty audio is the empty
                // text, decided before transcribe): a non-empty completed session that ended
                // IDLE delivered its text; an empty one has nothing to confirm.
                if audio.samples.isEmpty {
                    foldPipelineEvent(.finishedWithoutDelivery)
                } else {
                    foldPipelineEvent(.textDelivered(targetAppName: displayName(for: target)))
                }
            }
        case .transcriptHeld:
            await panel.presentHeldTranscript()
            foldPipelineEvent(.finishedWithoutDelivery)
        case .reasonOnly(let reason):
            panel.presentReasonOnly(reason)
            foldPipelineEvent(.finishedWithoutDelivery)
        }
    }

    private let logger = Logger(subsystem: "dev.vocca.Vocca", category: "loop")
}

    /// The tap's sink, fanned out to whichever configuration is active.
    ///
    /// The tap delivers into one wiring at a time; the inactive machine receives nothing, so its
    /// microphone can never open (`DictationLoopRoot/setActiveMode(_:)` is the only writer).
    ///
    /// **One key is intercepted before the fan-out: Escape.** `PRODUCT_SPEC.md:129` — "Esc during
    /// `OPENING`, `RECORDING` or `TRANSCRIBING` aborts and discards" — is not a session rule the
    /// machine can carry: the machine's `cancel()` is a separate entry point (`SessionMachine.swift:440-445`)
    /// and an in-flight transcription belongs to the router, not to any machine. So the session's
    /// cancel key is routed here, to the root's cancel router, instead of down the ordinary rule path
    /// — which would pass a non-binding key straight through (`SessionRules.swift:115-128`). The
    /// classification is ``SessionKeyPolicy``'s (a fresh Escape key-down, `VoccaHotkey`); the routing
    /// is the root's; this object is the one point that has both.
    ///
    /// Not annotated `@MainActor`, for the same reason the readiness gate is not: it conforms to the
    /// nonisolated ``HotkeyEventSink`` seam, and the annotation would make the conformance illegal.
    /// The confinement is a fact about how the sink is *used* — `receive` runs on the tap callback's
    /// main actor and `active` is written only by `setActiveMode`, also on the main actor. The
    /// cancel router is reached through `MainActor.assumeIsolated` for the same reason the tap
    /// callback itself asserts it: the tap is attached to the main run loop, so every event delivered
    /// here is already on the one actor the root lives in (`CGEventTapSource.swift:442-493`).
    final class ModeRoutingSink: HotkeyEventSink {
        var active: any HotkeyEventSink

        /// Where the session's cancel key goes — the root's cancel router, which knows what is in
        /// flight and what to cancel.
        private let sessionCancelKey: @MainActor (RawKeyEvent) -> EventPropagation

        init(
            active: any HotkeyEventSink,
            sessionCancelKey: @escaping @MainActor (RawKeyEvent) -> EventPropagation
        ) {
            self.active = active
            self.sessionCancelKey = sessionCancelKey
        }

        func receive(_ event: RawKeyEvent) -> EventPropagation {
            guard !SessionKeyPolicy.isSessionKey(event) else {
                // Read out first: the closure is main-actor-isolated, and the assumeIsolated
                // body must not capture `self` — this sink is deliberately not annotated, so a
                // main-actor use inside the closure could race a later nonisolated read.
                let cancel = sessionCancelKey
                return MainActor.assumeIsolated { cancel(event) }
            }
            return active.receive(event)
        }
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
