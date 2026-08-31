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
import Synchronization
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
            // C8's strategy memory joins the same chain, and for the same reason the journal is
            // here: its load reads a file, and `configure` may not block. An absent
            // `strategies.json` — every fresh install — is a silent empty memory whose
            // projection is the shipped C4 order, so this is probe-safe: FileManager only, no
            // network, and nothing written by the load.
            let assembled = await assembleShippingLadder(
                store: PersistentInjectionStrategyStore(), handoff: holder, clock: clock)
            return AssembledCustody(
                holder: holder, ladder: assembled.ladder, memory: assembled.memory)
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

        // MARK: The settings the user chose
        //
        // **Read once, here, and derived from everywhere else.** Five sites used to name
        // `EngineSelection.defaultSelection` outright — the resolver, the download session's
        // manifest, its base URL, the onboarding presence check and the Settings label — and the
        // failure that arrangement invites is not a site reading the wrong value but two sites
        // reading *different* ones: a download session fetching Parakeet's manifest while the
        // resolver builds Whisper. One read cannot produce it, and `EngineSelectionWiringTests`
        // pins the count.
        //
        // Reached through `ShippingSettings.store()` rather than by naming the adapter: the
        // `UserDefaults` seam permits exactly two files to name that family, and this is not one
        // of them (`InjectionSeamBoundaryTests`). The read is synchronous and cannot fail — an
        // absent or unreadable value degrades to the shipped default, which is a working
        // configuration.
        let settings = ShippingSettings.store()
        let selection = settings.engineSelection()
        // The bound chord, read **once**: both machines are configurations of one state machine
        // and must carry the same binding, and two reads can answer differently the moment a
        // rebind lands between them.
        let hotkey = Self.hotkeyConfigurations(chord: settings.hotkeyChord())

        // MARK: The engine lifecycle
        //
        // The resolver is built here, but its builder runs only when `prepareIfNeeded` does — and
        // that is `main`'s job, not `configure`'s: the engine's `prepare` is where model bytes
        // arrive, which is the one thing the probe must never trigger.
        //
        // Built through the same factory a *switch* uses, so the resolver the app launches with
        // and the resolver a selection change mints are one recipe rather than two that agree by
        // inspection.
        let makeResolver: @Sendable (EngineSelection) -> DictationEngineResolver = { selection in
            Self.makeResolver(selection: selection, store: store, clock: clock)
        }
        let resolver = makeResolver(selection)

        // The download window's surface: the same store, manifest and transport the engine will
        // use, so a download the UI starts and a download the launch starts are single-flight.
        let downloadSession: (any ModelDownloadSession)?
        do {
            downloadSession = try StoreModelDownloadSession(
                store: store,
                manifest: ShippedModelManifest.load(for: selection.tier),
                transport: DefaultModelTransport(
                    baseURL: repositoryURL(for: selection.tier)))
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
        var holdFeed: SpeculativeFeed?
        if let graph, let source = try? MicrophoneSource(
            graph: graph, recorder: ledger, clock: clock,
            sessionIDProvider: { sessionBox.sessionID },
            // The speculative feed's timer: the shipped main-run-loop timer behind the feed's
            // schedule/unschedule pair (the feed lives in VoccaAudio, which may not import
            // VoccaHotkey — see `SpeculativeFeed`). One timer per microphone, held by the
            // schedule closure for as long as the feed lives.
            feedSchedule: Self.mainRunLoopFeedSchedule(),
            feedSubMinimum: Self.feedSubMinimum(for: selection))
        {
            microphone = source
            holdFeed = source.feed
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
        var toggleFeed: SpeculativeFeed?
        if let toggleGraph, let source = try? MicrophoneSource(
            graph: toggleGraph, recorder: ledger, clock: clock,
            sessionIDProvider: { sessionBox.sessionID },
            feedSchedule: Self.mainRunLoopFeedSchedule(),
            feedSubMinimum: Self.feedSubMinimum(for: selection))
        {
            toggleMicrophone = source
            toggleFeed = source.feed
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

        // MARK: The injector composition (A4 — try-it-target)
        //
        // The one decision about the loop's injector, taken **once, here, at composition**:
        // onboarding incomplete ⇒ the onboarding sink — TRY IT's dictation lands in the
        // window's own field, not through the system-wide ladder (prd.md M6, whose allowlist is
        // seeded with three apps, not Vocca); complete ⇒ the shipping ladder, today's behavior.
        //
        // The flag is read synchronously here, once, before the pipeline assembly exists (the
        // `main()` precedent — a scalar read the root composition may make); `main()` reads the
        // same key again for its own, separate decision — whether the window auto-shows (M4).
        // A flag set later (TRY IT success) changes nothing for this process: the choice is
        // captured here, the assembly closure below only consults the captured value — the
        // resolve-once doctrine, `DictationEngineResolver`'s shape. The next launch composes
        // the ladder.
        //
        // The probe stays green by construction: `PROBE-CYCLE`'s post-condition is produced by
        // the probe's own cycle drive composing its own `LadderInjector` over probe rung fakes
        // (`DictationCycleDrive.swift:379-389`) — the probe never routes a session through this
        // root (it holds the root only to read its activation policy for `PROBE-BOOTSTRAP`), so
        // whichever branch the flag selects here, the probe's `PROBE-CYCLE`/`PROBE-LATENCY`
        // strings are byte-identical. No caller branches on the choice at session time.
        let injectorComposition = Self.injectorComposition(
            completionFlag: CompletionFlagStore().isComplete())

        // MARK: The onboarding flow (A5 — onboarding-window)
        //
        // The store and its delivery sink are **window-free objects** built here, so `configure`
        // stays window-free (the probe's charter): the store folds the flow over injected reads,
        // the sink is the TRY IT delivery end the loop's injector holds (A4), and the *window*
        // is lazy on the root — the `settingsWindow` shape — constructed only by `showOnboarding()`.
        //
        // The reads are A2's adapters plus the root's tap health: the AX trust `Bool`
        // (`AXSource.isProcessTrusted`), the armed fact (`TapHealth != .permissionMissing`,
        // read from the root's latest poll answer — the health poll is the live channel that
        // flips the ✓ the moment a grant lands, S1), and the raw mic status
        // (`MicrophoneAuthorization.authorizationStatus`). The completion write is A3's store,
        // the same key the `main()` show decision and the composition decision read.
        let onboardingStore = OnboardingStore(
            accessibilityTrusted: { AXSource().isProcessTrusted() },
            tapArmed: {
                guard let health = rootBox.value?.latestTapHealth else { return false }
                return health != .permissionMissing
            },
            microphoneStatus: { MicrophoneAuthorization.authorizationStatus() },
            markComplete: { CompletionFlagStore().markComplete() })

        // The model-presence read (S3's third input, fed asynchronously — the
        // `installedState(_:)` house pattern): `ModelStore.isPresent` is an actor read, so the
        // wiring answers it in a launch task, and a present model folds `.committed` — the flow
        // then resumes past the MODEL step. Disk-only: the zero-network probe stays green.
        if let manifest = try? ShippedModelManifest.load(for: selection.tier) {
            Task {
                if await store.isPresent(engineID: manifest.engineID, version: manifest.version) {
                    onboardingStore.fold(.modelStatusChanged(.committed))
                }
            }
        }

        // The onboarding delivery destination, owned by this composition (A5): the window's
        // field binding registers into it on construction (`OnboardingWindow.init`), so TRY
        // IT's real dictation lands in the window's own field — not through the system-wide
        // ladder (prd.md M6). A delivery with no registered destination fails honestly (the
        // window closed mid-dictation): the A4 documented refusal, never a swallowed transcript.
        let onboardingSink = OnboardingDeliverySink(store: onboardingStore)

        // MARK: The widget-streaming partial sink
        //
        // The pipeline's widget-only sink (`PartialTranscriptSink`), folded into the root's
        // widget store — the `WidgetStorePartialSink` shape: a mutex count, a weak store box
        // (the root owns the store; the sink must not extend its lifetime), and the fold
        // dispatched to the main actor — the store's one isolation domain. The box is filled
        // after the root is built, because the store is created by the root's initializer.
        let partialSink = BootstrapPartialSink()

        // MARK: The root
        //
        // The pipeline is assembled after the engine is prepared (it needs a *prepared* engine),
        // so `configure` hands the root the assembly recipe instead of a pipeline. `main`'s
        // `startEnginePreparation` runs it.
        let root = DictationLoopRoot(
            configuration: hotkey.holdToTalk,
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
            // The prepared engine arrives as a parameter, deliberately. This closure outlives every
            // resolver the process will build — a switch replaces the resolver, and a closure that
            // had captured one would keep assembling pipelines over the engine the app launched
            // with. Taking the engine leaves nothing here to go stale.
            pipelineAssembly: { engine in
                let custody = try await custodyTask.value
                let injector: any TextInjector
                switch injectorComposition {
                case .ladder:
                    injector = custody.ladder
                case .onboarding:
                    injector = OnboardingInjector(sink: onboardingSink)
                }
                return DictationPipeline(
                    engine: engine, injector: injector, holder: custody.holder,
                    recorder: ledger, clock: clock,
                    cleanup: try await cleanupResolver.resolve(),
                    partialSink: partialSink)
            },
            makeResolver: makeResolver,
            settings: settings,
            downloadSession: downloadSession,
            recorder: ledger,
            sessionBox: sessionBox,
            toggleConfiguration: hotkey.toggle,
            toggleSource: toggleMicrophone,
            toggleTimer: MainRunLoopTimer(),
            runningAppName: SystemRunningAppName(),
            widgetClock: MainRunLoopTimer(),
            liveLevel: liveLevel,
            holdFeed: holdFeed,
            toggleFeed: toggleFeed)
        rootBox.value = root
        // The partial sink's store box: filled now that the store exists — the `menuBarItem`
        // shape (assigned after construction, the box pattern for a circular graph).
        partialSink.store = root.widgetStore
        // The onboarding half of the root's surface: the store the window renders and the sink
        // the window's field registers into — filled after construction, the `menuBarItem`
        // shape (both are window-adjacent surfaces, neither exists for the probe).
        root.onboardingStore = onboardingStore
        root.onboardingSink = onboardingSink
        // The Speech tab's store: the same one every engine loads through, so a row's
        // `[ installed ]`, the bytes beside [Remove] and the model the engine opens are all one
        // directory. Assigned after construction, the `strategyMemory` shape.
        root.modelStore = store
        // The Cleanup tab's source of truth: the same resolver the pipeline cleans through and the
        // egress badge folds from, so the tab cannot report a provider Vocca is not using (F3).
        root.cleanupResolver = cleanupResolver

        // The strategy memory, reached back from the custody chain once it has assembled — the
        // Apps tab's write path (C8 R7). Without it a pin would reach the file and not the
        // ladder, and would take effect at the next launch rather than the next dictation.
        Task {
            root.strategyMemory = try? await custodyTask.value.memory
        }

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
    /// Deliberately three pieces of work and one line of run loop: everything beyond the
    /// preparation kick-off is `configure`'s, because `configure` is what the zero-network probe
    /// drives. The onboarding auto-show is here, not in `configure`, for the window-server rule
    /// (`main()` shows, `configure` never constructs a window): the completion flag is read
    /// **synchronously** (A3's store is UserDefaults-backed for exactly this decision), and the
    /// window re-shows at launch until the flag is set (M4).
    @MainActor
    public static func main() {
        let application = NSApplication.shared
        let root = configure(application)
        attachMenuBarItem(to: root)
        if !CompletionFlagStore().isComplete() {
            root.showOnboarding()
        }
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
            hotkey: { [weak root] in root?.hotkeyDisplayName ?? "" },
            onAction: { state in
                switch state {
                case .noAccessibility:
                    SystemSettingsPane.open(at: SystemSettingsPane.accessibilityPanePath)
                case .noMicrophone:
                    SystemSettingsPane.open(at: SystemSettingsPane.microphonePanePath)
                // The one blocker whose remedy is inside Vocca: the Speech tab is where the model
                // is fetched again, so the button opens it rather than System Settings.
                case .modelMissing:
                    root.showSettings()
                case .downloadingModel, .preparingEngine, .ready, .listening, .transcribing,
                    .secureInput:
                    break
                }
            },
            onOpenSettings: { [weak root] in root?.showSettings() },
            // The quit path ends the speculative feed explicitly, before `terminate` — the
            // "no feed left running" claim true in the code that runs, not only as a property of
            // process death (the OS releases the input device and stops the feed's timer
            // structurally at exit either way; this line is executed by nothing in CI — the
            // window-server rule — and is SMOKE_CHECKLIST step 123).
            onQuit: { [weak root] in
                root?.cancelFeeds()
                NSApplication.shared.terminate(nil)
            })
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

    // MARK: - The launch read

    /// The two configurations the root runs, built from **one** chord.
    ///
    /// A tuple from a single call rather than two independent constructions, and that is the
    /// whole reason this function exists: both machines are configurations of one state machine
    /// and must be bound to the same chord. Two call sites each building their own is how they
    /// come to disagree — and a hold-to-talk machine bound to a different chord than the toggle
    /// machine is one that can never end a session the other started.
    ///
    /// Pure, so the launch read is testable without an `NSApplication`: `configure` needs a run
    /// loop and no test in the suite calls it.
    public static func hotkeyConfigurations(
        chord: HotkeyChord
    ) -> (holdToTalk: HotkeyConfiguration, toggle: HotkeyConfiguration) {
        (
            HotkeyConfiguration(
                keyCode: chord.keyCode, modifiers: chord.modifiers, activation: .holdToTalk),
            HotkeyConfiguration(
                keyCode: chord.keyCode, modifiers: chord.modifiers, activation: .toggle)
        )
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

    /// The speculative feed's timer as the ``RepeatingTimer`` seam's two operations — a fresh
    /// `MainRunLoopTimer` per microphone, retained by the schedule closure for as long as the
    /// feed lives. `SpeculativeFeed` documents why the timer is a closure pair (the feed lives
    /// in `VoccaAudio`, which may not import `VoccaHotkey`); this is the pair's only production
    /// construction site.
    private static func mainRunLoopFeedSchedule() -> (
        schedule: (Duration, @escaping () -> Void) -> Void,
        unschedule: () -> Void
    ) {
        let timer = MainRunLoopTimer()
        return (schedule: { timer.start(every: $0, $1) }, unschedule: { timer.stop() })
    }

    /// **The sub-minimum suppression predicate for the resolved engine** — the policy carried
    /// by the predicate, never branched on by the feed itself. Parakeet's threshold is read
    /// **live** from the SDK through the one permitted line — `ParakeetEngine.minimumRequiredSamples`
    /// (the H8b lint keeps `ASRConstants` in that one file; the composition root names
    /// `ParakeetEngine` and never the SDK). Whisper's predicate is `false` — no suppression —
    /// because whisper's below-minimum behavior is unmeasured and never reasoned about (PRD M4,
    /// measured in the adapter aspect). Decided once here, from the same selection the resolver
    /// is built from.
    private static func feedSubMinimum(
        for selection: EngineSelection
    ) -> (@Sendable (Int) -> Bool)? {
        switch selection.tier {
        case .parakeetV3:
            return { count in
                count
                    < ParakeetEngine.minimumRequiredSamples(
                        sampleRate: AudioBuffer.interchangeSampleRate)
            }
        case .whisperTurbo, .whisperTurboQ5:
            return { _ in false }
        }
    }

    // MARK: - The Apps tab's read

    /// What the Apps tab shows: the stored strategies, each with a name a person recognises and
    /// the seeded allowlist's answer about it.
    ///
    /// The allowlist answer travels with the row because `VoccaUI` may import only `VoccaCore`
    /// (`ModuleBoundaryTests`) and the seeded list lives in `VoccaInject`. The name comes from
    /// LaunchServices; an application that no longer resolves — uninstalled since Vocca learned
    /// about it — shows its bundle identifier rather than a blank, so no row is ever nameless.
    @MainActor
    public static func readAppStrategies() async -> [AppStrategyEntry] {
        let seed = SeededInjectionAllowlist()
        let stored = await PersistentInjectionStrategyStore().load()
        return stored.map { strategy in
            AppStrategyEntry(
                bundleID: strategy.bundleID,
                displayName: displayName(forBundleID: strategy.bundleID),
                strategy: strategy,
                isAllowlisted: seed.contains(bundleID: strategy.bundleID))
        }
    }

    /// The installed application's name, or the bundle identifier when nothing resolves.
    @MainActor
    private static func displayName(forBundleID bundleID: String) -> String {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            return bundleID
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.isEmpty ? bundleID : name
    }

    // MARK: - The learning ladder

    /// **store → loaded snapshot → memory → ladder**, in that order — the custody chain's ladder
    /// assembly, extracted so the order is pinned by a test rather than asserted by a comment.
    ///
    /// The order is the whole content of this function. Building the ladder first and loading
    /// afterwards would leave the first dictation after every launch ordering from an empty
    /// memory — re-trying, once per launch, exactly the rung C8 exists to stop re-trying.
    ///
    /// Nothing here can block `configure`: the load is asynchronous, an absent `strategies.json`
    /// is a silent empty memory (every fresh install), and a load never writes. `now` is epoch
    /// seconds — the re-probe window's clock, injected so the suite does not wait a week.
    ///
    /// - Parameters:
    ///   - store: Where the per-app strategies live. ``PersistentInjectionStrategyStore`` at
    ///     ship, a temp-directory store under the probe and the suite.
    ///   - handoff: The failsafe floor, already assembled — the same custody the panel reads.
    ///   - clock: The ladder's monotonic clock, the one the whole loop shares.
    ///   - now: Epoch seconds for the strategy memory. Distinct from `clock` on purpose: a
    ///     monotonic reading is meaningless across launches, which is exactly the span a
    ///     re-probe window covers.
    @MainActor
    public static func assembleShippingLadder(
        store: any InjectionStrategyStore,
        handoff: any FailsafeHandoff,
        clock: any MonotonicClock,
        now: @escaping @Sendable () -> UInt64 = {
            UInt64(max(0, Date().timeIntervalSince1970))
        }
    ) async -> (ladder: LadderInjector, memory: MemoryBackedInjectionStrategyOrder) {
        let loaded = await store.load()
        let memory = MemoryBackedInjectionStrategyOrder(
            seed: SeededInjectionAllowlist(),
            strategies: loaded,
            store: store,
            now: now)
        return (
            ShippingLadder.makeWithMemory(memory: memory, handoff: handoff, clock: clock), memory
        )
    }

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

    /// The resolver recipe, in one place: an ``EngineSelection`` plus the process's model store
    /// and clock become the engine lifecycle that selection runs under.
    ///
    /// Extracted because there are now **two** callers and they must not drift: `configure` builds
    /// the launch resolver, and ``DictationLoopRoot/setEngineSelection(_:)`` builds a fresh one on
    /// every switch — `DictationEngineResolver.selection` is a `let` with no reset by design
    /// (resolve-once), so a switch is a new resolver or it is nothing.
    ///
    /// Construction is side-effect-free and probe-safe for the same reason ``engine(for:store:clock:)``
    /// is: the builder inside runs only when `prepareIfNeeded()` does.
    public static func makeResolver(
        selection: EngineSelection,
        store: ModelStore,
        clock: any MonotonicClock & Sendable
    ) -> DictationEngineResolver {
        DictationEngineResolver(selection: selection) { selection in
            try await engine(for: selection, store: store, clock: clock)
        }
    }

    /// The A4 composition decision — which injector the loop is composed with, chosen exactly
    /// once in ``configure(_:)`` (the resolve-once doctrine): the only branch about the
    /// injector that exists, so no caller checks completion state at session time.
    ///
    /// Pinned by `OnboardingInjectorTests` in both directions — including that the onboarding
    /// injector is never reachable when the flag is set, which is the half the zero-network
    /// probe's green run rests on: the probe's `PROBE-CYCLE` post-condition asserts the *real*
    /// ladder delivered (`ZeroNetworkTests.expectedCycleLifecycle`), and that report is
    /// produced by the probe's own drive composing its own ``LadderInjector`` — this decision
    /// cannot reach it, and the completed-machine direction below keeps the decision itself
    /// honest.
    public enum InjectorComposition: Sendable, Equatable {
        /// Onboarding incomplete: the loop's injector is the onboarding sink — TRY IT's
        /// dictation lands in the window's own field (prd.md M6).
        case onboarding
        /// Onboarding complete: the shipping ladder — today's behavior, byte for byte.
        case ladder
    }

    /// Maps the persisted completion flag (A3) to the injector composition. Pure — the one
    /// decision, taken once, at composition, in ``configure(_:)``.
    public static func injectorComposition(completionFlag: Bool) -> InjectorComposition {
        completionFlag ? .ladder : .onboarding
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

/// **A Speech-tab action asked of a composition that has no model store.**
///
/// Never reachable in the shipped graph — `configure` assigns the store the moment the root
/// exists. Surfaced rather than swallowed because the alternative is a [Remove] that reports
/// success and deletes nothing, which is the failure the whole tab's error path exists for.
public enum SpeechSettingsUnavailable: Error, CustomStringConvertible {
    /// No model store was composed.
    case noModelStore

    public var description: String {
        switch self {
        case .noModelStore: return "no model store is available in this composition"
        }
    }
}

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

    /// The binding this process listens for **now**.
    ///
    /// Read from the hold-to-talk wiring rather than remembered, because ``rebind(to:)`` replaces
    /// the wirings: a stored copy would go on naming the launch chord after a rebind, and a root
    /// describing a binding nothing is bound to is the same class of defect as a root reporting a
    /// mode its events do not reach.
    public var configuration: HotkeyConfiguration { holdToTalk.configuration }
    /// The hold-to-talk wiring: machine, watchdog, sink, timer.
    ///
    /// `private(set) var` rather than `let` since `rebind-boundary`, and that is the *only*
    /// mutability the rebind adds: every value stays immutable, and what changes is which immutable
    /// object the root points at. `HotkeyConfiguration`'s fields and `SessionMachine.configuration`
    /// gained no setter and must not — a binding mutated between a `keyDown` and its `keyUp` would
    /// leave `SessionRules.decide` and the watchdog's ~150 ms poll disagreeing about what is held,
    /// which is a session stranded on a key nobody is holding.
    public private(set) var holdToTalk: Wiring
    /// The toggle wiring: the same composition, `activation: .toggle`, constructed and owned.
    /// It receives the tap's events only while it is the active mode.
    public private(set) var toggle: Wiring
    /// The hold-to-talk microphone's speculative feed — the ring's mid-session consumer, armed
    /// by the router at `.opening` and terminated at every terminal. `nil` in a composition
    /// without feeds keeps the router on the batch route, byte for byte.
    private let holdFeed: SpeculativeFeed?
    /// The toggle microphone's own feed — the same absence semantics.
    private let toggleFeed: SpeculativeFeed?
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
    /// Assigned once in the initializer from the same local the routing sink's initial `active` is
    /// derived from, never written independently: this property and the tap's actual route must
    /// name the same wiring, or the root reports a mode its events are not going to and
    /// `setActiveMode(_:)` then refuses the very switch that would repair it (`mode != activeMode`
    /// is already false).
    ///
    /// Its launch value is the **persisted** mode when a store is wired, and ``defaultMode`` when
    /// none is — an absent store is a fresh install, not a failure.
    public private(set) var activeMode: DictationMode

    /// The mode a fresh install starts in — **derived**, not declared.
    ///
    /// This used to be a second literal `.toggle`, duplicating
    /// ``PersistedSettings/defaultActivation`` in a module `VoccaCore` may not import, with a test
    /// in the one target that can see both holding them together. That duplication existed only
    /// because the settings-store aspect could not reach the composition root; the root reads the
    /// store now, so the fact lives in one place and an exhaustive mapping carries it here. Two
    /// constants agreeing by test is a worse state than one constant, and the test that held them
    /// is deleted with the duplication it guarded.
    public static let defaultMode: DictationMode = mode(for: PersistedSettings.defaultActivation)

    /// The root's vocabulary for one of Core's activation modes. Total, with no `default:`: the
    /// third mode `Activation` anticipates (voice-activated, at P3) must say which wiring it drives
    /// or this file stops compiling.
    public static func mode(for activation: HotkeyConfiguration.Activation) -> DictationMode {
        switch activation {
        case .holdToTalk: return .holdToTalk
        case .toggle: return .toggle
        }
    }

    /// The inverse — what gets written when the mode changes. Total for the same reason.
    public static func activation(for mode: DictationMode) -> HotkeyConfiguration.Activation {
        switch mode {
        case .holdToTalk: return .holdToTalk
        case .toggle: return .toggle
        }
    }

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

    /// The ladder's strategy memory (C8), reached back from the custody chain after it assembles.
    ///
    /// `nil` only in the window between launch and the journal's disk load — and in the probe,
    /// which composes its own ladder. The Apps tab writes through this so a pin reaches the
    /// running ladder; the file underneath it is the same one the memory persists to.
    public var strategyMemory: MemoryBackedInjectionStrategyOrder?

    /// The model store every engine loads through, reached back from `configure` — the
    /// ``strategyMemory`` precedent, and for the same reason: the Speech tab needs it and the
    /// root's initializer is not where a composition detail belongs.
    ///
    /// `nil` only in a composition that built no store — every headless harness in the suite. The
    /// tab's fallback is to claim nothing (an empty snapshot renders
    /// ``SpeechTabInstall/unknown``, which is the honest "we could not ask") and to refuse a
    /// removal out loud rather than to report a success that did not happen.
    public var modelStore: ModelStore?

    /// The one cleanup resolver for the process, reached back from `configure` — the
    /// ``modelStore`` precedent, and for the same reason: the Cleanup tab needs it and the root's
    /// initializer is not where a composition detail belongs.
    ///
    /// `nil` only in a composition that built no resolver — every headless harness in the suite,
    /// and the tab's fallback there is to claim nothing rather than to invent an answer. The tab
    /// asks it what actually resolved, which is what makes the page and the widget's egress badge
    /// two renderings of one fact instead of two guesses (F3).
    public var cleanupResolver: CleanupResolver?

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
                    // Read, never captured — the window is built once and kept for the process's
                    // lifetime, so a chord captured here would go on naming the old binding on the
                    // very page the user changed it on (the `engineSelection` argument, applied to
                    // the fact this tab exists to show).
                    hotkeyDisplayName: { [weak self] in self?.hotkeyDisplayName ?? "" },
                    // The recorder reads a raw macOS modifier word and a key code off an NSEvent
                    // and translates neither: the `fn` rule — where the hardware sets the function
                    // bit by itself on the arrow keys and the navigation cluster — lives in the
                    // one translation the tap already runs on, driven against CoreGraphics' own
                    // constants by test. VoccaUI cannot import VoccaHotkey, so this is the seam
                    // that keeps it from growing a second copy of it.
                    chordForKeyEvent: { rawFlags, keyCode in
                        HotkeyChord(
                            keyCode: keyCode,
                            modifiers: HotkeyFlagTranslation.modifiers(
                                rawFlags: rawFlags, keyCode: keyCode))
                    },
                    // Asked once, and answered by Core: the rules plus what the system has already
                    // claimed, with the refusal outranking the collision. The preferences domain is
                    // read here, while a chord is being recorded — once per capture, never on the
                    // dictation path — because the user may have changed a shortcut since launch.
                    validateChord: { chord in
                        HotkeyBindingRules.validate(
                            chord, against: SystemShortcutDefaultsReader().occupiedChords())
                    },
                    // The answer is returned to the page, not left in a log: a rebind that appears
                    // not to have registered invites a second attempt, made on a keyboard whose
                    // binding the user is no longer sure of.
                    rebind: { [weak self] chord in
                        self?.rebind(to: chord) ?? .refused(.notBindable)
                    },
                    // The *live* selection, not the launch-time one: after a switch this label
                    // must name the engine Vocca is now using, and the resolver's selection is
                    // that fact rather than a copy of it.
                    // Empty rather than a shipped-default guess when the root is gone: the
                    // window cannot outlive the root in the shipped graph, and a label naming
                    // an engine the user did not choose is the exact failure the single read
                    // above exists to prevent.
                    engineDisplayName: { [weak self] in
                        self?.resolver.selection.tier.engine.displayName ?? ""
                    },
                    // Derived from the **resolved** provider, never a literal and never the file:
                    // an `ollama` block with an undialable endpoint has already degraded to rules
                    // by the time the resolver answers, and a tab echoing the file would tell a
                    // user their text goes to a machine nothing ever dials (F3). With no resolver
                    // — every headless harness — the page claims nothing rather than inventing an
                    // answer, which for a privacy surface is the only safe direction.
                    cleanupSummary: { [weak self] in
                        await self?.cleanupResolver?.summary()
                    },
                    // The same `cleanup-config.json` the resolver reads — one file, translated
                    // in one place (`CleanupConfig.draft` / `init(draft:)`), never a second copy
                    // that drifts from it. The resolver is resolve-once, so a write here lands at
                    // the next launch, which is what `CleanupTabCopy.appliesAtNextLaunch` says on
                    // the page rather than leaving the user to discover.
                    loadCleanupConfig: { await CleanupConfigStore().load().draft },
                    saveCleanupConfig: { draft in
                        try await CleanupConfigStore().save(CleanupConfig(draft: draft))
                    },
                    // The one-time cloud confirmation's memory, in the settings store beside the
                    // engine and activation choices — so "one-time" means once, not once per
                    // window.
                    isCloudCleanupAcknowledged: { [weak self] in
                        self?.settings?.hasAcknowledgedCloudCleanup() ?? false
                    },
                    setCloudCleanupAcknowledged: { [weak self] acknowledged in
                        self?.settings?.setAcknowledgedCloudCleanup(acknowledged)
                    },
                    // The same store the rules engine reads from, so an edit here is an edit the
                    // next dictation applies — not a second copy of the file that drifts from it.
                    loadDictionary: { await FileSystemDictionaryStore().load() },
                    saveDictionary: { try await FileSystemDictionaryStore().save($0) },
                    // The Apps tab reads the *store* — the seeded-hostile entries the memory
                    // mints at launch are seed rather than learning, and listing them as things
                    // Vocca worked out would be claiming knowledge it does not have.
                    loadStrategies: { await AppBootstrap.readAppStrategies() },
                    // ...and writes through the *memory*, so a pin applies to the next dictation
                    // rather than the next launch. The memory persists to the same file the read
                    // came from, so the two can never be two files.
                    saveStrategies: { [weak self] entries in
                        let strategies = entries.map(\.strategy)
                        guard let memory = self?.strategyMemory else {
                            // The custody chain has not assembled yet — write the file directly
                            // rather than dropping the user's edit. The memory loads from it.
                            try await PersistentInjectionStrategyStore().save(strategies)
                            return
                        }
                        try await memory.replaceAll(strategies)
                    },
                    // MARK: Speech
                    //
                    // The selection is read off the resolver, which *is* the fact rather than a
                    // copy of it — the window outlives every switch, so a captured value would
                    // leave the radio pointing at the launch engine for ever.
                    engineSelection: { [weak self] in
                        self?.resolver.selection ?? .defaultSelection
                    },
                    // Aspect 3's switch, unchanged: it refuses mid-session, persists the choice,
                    // replaces the resolver and prepares the new engine eagerly.
                    setEngineSelection: { [weak self] selection in
                        self?.setEngineSelection(selection)
                    },
                    engineReadiness: { [weak self] in
                        self?.engineReadinessState ?? .unavailable
                    },
                    // Asked every time the page opens, never cached: a model can be removed by
                    // this very page, and a stale answer is a row offering to remove bytes that
                    // are already gone. The version comes from the shipped manifest, which is the
                    // same one the engine and the downloader read — presence is version-scoped
                    // (`ModelStore.isPresent(tier:version:)`) and asking about any other version
                    // would answer about a directory nothing uses.
                    modelSnapshot: { [weak self] in
                        guard let store = self?.modelStore else { return [] }
                        return await DictationLoopRoot.modelSnapshot(store: store)
                    },
                    makeDownloadSession: { [weak self] tier in
                        guard let store = self?.modelStore else { return nil }
                        do {
                            return try StoreModelDownloadSession(
                                store: store,
                                manifest: ShippedModelManifest.load(for: tier),
                                transport: DefaultModelTransport(
                                    baseURL: AppBootstrap.repositoryURL(for: tier)))
                        } catch {
                            // Offered to nobody rather than offered and broken: the row shows no
                            // download it cannot perform.
                            return nil
                        }
                    },
                    // Removal, and the two reports the other surfaces need. `engineModelRemoved`
                    // is what keeps the menu bar from saying "ready" over a model that is gone —
                    // it closes the readiness gate when the removed tier is the one in use, so
                    // the next press refuses honestly (R5) instead of opening a microphone for an
                    // engine that cannot transcribe.
                    removeModel: { [weak self] tier in
                        guard let store = self?.modelStore else {
                            throw SpeechSettingsUnavailable.noModelStore
                        }
                        try await DictationLoopRoot.removeModel(tier: tier, store: store)
                        self?.engineModelRemoved(tier: tier)
                    },
                    isSessionInFlight: { [weak self] in
                        guard let self else { return false }
                        return self.holdToTalk.machine.state != .idle
                            || self.toggle.machine.state != .idle
                    },
                    // A download's start and finish, reported so the menu bar can tell the wait
                    // it can do nothing about from the one it can. Only the selected tier's
                    // download blocks anything; the root drops the rest.
                    downloadActivityChanged: { [weak self] tier, isRunning in
                        self?.engineDownloadChanged(tier: tier, isRunning: isRunning)
                    }))
        }
        settingsWindow?.show()
    }

    // MARK: - The Speech tab's store queries

    /// Every tier's presence and disk figure, asked of the store at the version its **shipped
    /// manifest** pins.
    ///
    /// Version-scoped because presence is: a verified version directory is immutable
    /// (`PRODUCT_SPEC.md:273`), so asking about any other version would answer about a directory
    /// nothing uses. A tier whose manifest will not load is **omitted** rather than reported
    /// absent — "we could not ask" and "it is not there" are different answers, and the tab has a
    /// state for the first one (``SpeechTabInstall/unknown``) precisely so it need not guess.
    static func modelSnapshot(store: ModelStore) async -> [SpeechTabTierSnapshot] {
        var snapshots: [SpeechTabTierSnapshot] = []
        for tier in EngineTier.allCases {
            guard let manifest = try? ShippedModelManifest.load(for: tier) else { continue }
            let isPresent = await store.isPresent(tier: tier, version: manifest.version)
            let bytes = await store.bytesOnDisk(tier: tier, version: manifest.version)
            snapshots.append(
                SpeechTabTierSnapshot(tier: tier, isPresent: isPresent, bytesOnDisk: bytes))
        }
        return snapshots
    }

    /// Deletes one tier's model, at the same version ``modelSnapshot(store:)`` reported the bytes
    /// for — so the number beside [Remove] and the directory it frees are the same directory.
    static func removeModel(tier: EngineTier, store: ModelStore) async throws {
        let manifest = try ShippedModelManifest.load(for: tier)
        try await store.remove(tier: tier, version: manifest.version)
    }

    // MARK: - The onboarding window (A5)

    /// The onboarding flow's store — built by `configure` (window-free), fed by A2's adapters
    /// and the root's tap health. `nil` never in the shipped graph; `configure` assigns it right
    /// after the root exists.
    public var onboardingStore: OnboardingStore?

    /// The TRY IT delivery end the loop's injector holds — the window's field registers into it.
    /// `nil` never in the shipped graph; `configure` assigns it right after the root exists.
    public var onboardingSink: OnboardingDeliverySink?

    /// The tap's latest health answer — the armed fact's source for the onboarding store
    /// (`TapHealth != .permissionMissing`), kept by the ~1 s poll's report.
    public private(set) var latestTapHealth: TapHealth?

    /// The onboarding window, built on first use and kept for the process's lifetime — the
    /// `settingsWindow` laziness, for the same reason.
    private var onboardingWindow: OnboardingWindow?

    /// Opens the five-step onboarding window, building it and its bindings the first time —
    /// `main()`'s auto-show until the completion flag is set (M4). The bindings are closures
    /// over what the root already holds: A2's pane paths and relaunch adapter, A5's mic request
    /// over ``MicrophoneAuthorization``, and the root's download session — user-initiated only,
    /// never from `configure` or `main` themselves.
    public func showOnboarding() {
        guard let onboardingStore, let onboardingSink else { return }
        if onboardingWindow == nil {
            let window = OnboardingWindow(
                store: onboardingStore,
                sink: onboardingSink,
                bindings: OnboardingBindings(
                    openAccessibilityPane: {
                        SystemSettingsPane.open(at: SystemSettingsPane.accessibilityPanePath)
                    },
                    openMicrophonePane: {
                        SystemSettingsPane.open(at: SystemSettingsPane.microphonePanePath)
                    },
                    requestMicrophoneAccess: {
                        // M5b: the TCC prompt lands at the moment the flow controls it, and the
                        // answer folds straight into the flow (the reducer's row).
                        Task {
                            let granted = await MicrophoneAuthorization.requestAccess()
                            onboardingStore.fold(.microphoneRequestResulted(granted))
                        }
                    },
                    makeDownloadSession: { [weak self] in self?.downloadSession },
                    restart: { AppRelaunch.relaunch() },
                    hotkeyDisplayName: { [weak self] in self?.hotkeyDisplayName ?? "" }))
            onboardingWindow = window
        }
        onboardingWindow?.show()
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
    /// The hold-to-talk watchdog's timer, exposed so a test can turn it.
    ///
    /// Read from the wiring for ``configuration``'s reason: ``rebind(to:)`` mints a fresh timer per
    /// wiring, and a stored copy would hand a caller the clock of a watchdog that no longer exists.
    public var watchdogTimer: any RepeatingTimer { holdToTalk.timer }
    /// The ~1 s tap-health poll's timer.
    public let healthTimer: any RepeatingTimer
    /// The event tap, held for its lifetime (the unretained-context rule).
    public let tap: any RecoverableHotkeyEventSource
    /// The tap-health policy with its clock attached — the root's one object that keeps the
    /// disablement observer alive.
    public let tapHealth: TapHealthTimer
    /// **The engine lifecycle currently in force** — resolve-once, single-flight prepare, the
    /// readiness gate's truth.
    ///
    /// A `var`, and the one slot in this class that a caller must read *at call time* rather than
    /// capture. `DictationEngineResolver.selection` is a `let` with no reset by design (resolve-once
    /// — its own `isPrepared` describes the engine it built), so switching engines replaces the
    /// resolver rather than mutating it, and anything holding the old instance is holding a
    /// resolver for an engine nobody selected.
    ///
    /// Nothing in the composition captures one: ``pipelineAssembly`` is handed the prepared
    /// *engine* precisely so that it has no resolver to go stale against, and
    /// ``prepareAndAssemble()`` re-reads this slot after every suspension.
    public private(set) var resolver: DictationEngineResolver

    /// **How many times the selected engine's model has been taken away**, bumped by
    /// ``engineModelRemoved(tier:)`` and captured by every preparation at its top.
    ///
    /// It exists because resolver identity cannot answer the question a removal asks. A *switch*
    /// mints a fresh resolver, so `===` is enough to spot a preparation for an engine nobody
    /// selected. A removal changes no selection at all — the same engine, with its bytes deleted —
    /// so the in-flight preparation is still holding the current resolver and would pass that
    /// check. This counter is what changes underneath it: a preparation whose captured value no
    /// longer matches prepared a model that has since been removed, and must open nothing.
    private var modelRemovalCount: UInt64 = 0

    /// The idle re-warm policy (`rewarm-after-idle`): observes the effect funnel's session
    /// starts and ends, and its tick rides the root's ~1 s health poll — the machine-idle window
    /// that re-warms the selected engine after five idle minutes. Main-actor-confined by this
    /// owner, exactly as the policy's contract requires (the annotation belongs to the driver).
    private let idleReWarm: IdleReWarmPolicy
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
    /// The four collaborators a rebuild needs and the initializer would otherwise have consumed.
    /// Held because ``rebind(to:)`` builds its replacement wirings from exactly what the launch
    /// pair was built from — everything but the configuration and the timers is reused, so a
    /// rebound graph differs from a launched one in the binding and in nothing else.
    private let ceiling: Duration
    private let keyState: any PhysicalKeyStateReader
    private let deferOpening: RunLoopDeferral
    private let deliverEffect: (SessionEffect<AudioBuffer>) -> Void
    /// Where a rebuild's **fresh** timers come from.
    ///
    /// A factory rather than the two injected timers, because handing an existing `RepeatingTimer`
    /// to a second `ScheduledWatchdog` is two owners on one clock: the discarded watchdog's `deinit`
    /// stops it, and if that release lands after the new session has started, the new machine is
    /// left with no ceiling and no physical-key poll — a session with nothing able to end it.
    private let makeWatchdogTimer: @MainActor () -> any RepeatingTimer
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
    ///
    /// It takes the prepared **engine** rather than reaching for a resolver. That is the whole of
    /// the defence against a closure calling a replaced resolver: `configure` builds this closure
    /// before the root exists and it lives for the process's lifetime, so a captured resolver would
    /// still be the launch one after every switch. There is nothing to capture.
    private let pipelineAssembly: (@MainActor (any ASREngine) async throws -> DictationPipeline)?

    /// How a selection becomes a resolver — the recipe a switch re-runs. `nil` in a composition
    /// with no factory wired, where ``setEngineSelection(_:)`` refuses loudly rather than pretending
    /// to switch.
    private let makeResolver: (@Sendable (EngineSelection) -> DictationEngineResolver)?

    /// Where a chosen setting is written so it survives the launch. `nil` in the headless shape,
    /// where a switch applies but is not persisted.
    private let settings: (any SettingsStore)?

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
    ///   - holdFeed: The hold-to-talk microphone's speculative feed — the router arms it at
    ///     `.opening` and terminates it at every terminal. `nil` (every headless composition)
    ///     keeps the router on the batch route, byte for byte.
    ///   - toggleFeed: The toggle microphone's own feed — the same absence semantics.
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
        pipelineAssembly: (@MainActor (any ASREngine) async throws -> DictationPipeline)? = nil,
        makeResolver: (@Sendable (EngineSelection) -> DictationEngineResolver)? = nil,
        settings: (any SettingsStore)? = nil,
        downloadSession: (any ModelDownloadSession)? = nil,
        recorder: (any LatencyRecorder)? = nil,
        sessionBox: LatencySessionBox? = nil,
        toggleConfiguration: HotkeyConfiguration,
        toggleSource: any SessionAudioSource<AudioBuffer>,
        toggleTimer: any RepeatingTimer,
        runningAppName: RunningAppNameReading,
        widgetClock: any RepeatingTimer,
        liveLevel: any LiveLevelSource,
        holdFeed: SpeculativeFeed? = nil,
        toggleFeed: SpeculativeFeed? = nil,
        makeWatchdogTimer: @escaping @MainActor () -> any RepeatingTimer = { MainRunLoopTimer() }
    ) {
        precondition(
            pipeline == nil || pipelineAssembly == nil,
            "the pipeline is either injected or assembled — both is a composition bug")

        let readiness = EngineReadiness()
        self.clock = clock
        self.ceiling = ceiling
        self.keyState = keyState
        self.deferOpening = deferOpening
        self.makeWatchdogTimer = makeWatchdogTimer
        self.healthTimer = healthTimer
        self.tap = tap
        self.resolver = resolver
        self.targetResolution = targetResolution
        self.panel = panel
        self.downloadSession = downloadSession
        self.latencyLedger = recorder as? LatencyLedger
        self.pipelineAssembly = pipelineAssembly
        self.makeResolver = makeResolver
        self.settings = settings
        self.readiness = readiness
        self.widgetClock = widgetClock
        self.runningAppName = runningAppName
        self.holdFeed = holdFeed
        self.toggleFeed = toggleFeed

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

        // The launch mode, read from the store exactly once and used for **both** the reported
        // mode and the tap's route — the two are one fact, and this local is where it lives.
        // Computed before the router below, which needs it for its active-feed slot (the feed
        // the mode routes to is the feed the router arms at `.opening`).
        let initialMode = settings.map { Self.mode(for: $0.activationMode()) } ?? Self.defaultMode

        let router = EffectRouter(
            panel: panel, targetResolution: targetResolution, readiness: readiness,
            pipeline: pipeline, runningAppName: runningAppName, widgetStore: widgetStore,
            widgetClock: widgetClock, recorder: recorder, sessionBox: sessionBox,
            activeFeed: initialMode == .holdToTalk ? holdFeed : toggleFeed)
        self.router = router

        let idleReWarm = IdleReWarmPolicy(clock: clock, trigger: { [weak cancelRouterBox] in
            await cancelRouterBox?.value?.rewarmEngineAfterIdle()
        })
        self.idleReWarm = idleReWarm

        let deliver: (SessionEffect<AudioBuffer>) -> Void = { [weak router] effect in
            // The idle re-warm's window is the effect funnel's single observer: a session start
            // (both modes, all terminals) closes it, a session end reopens it, and everything
            // else — a refused press included — leaves it (no session happened). The policy's
            // note rides this one closure so the hold-to-talk and toggle machines cannot
            // disagree about what the machine has been doing.
            switch effect {
            case .started, .opening:
                idleReWarm.noteSessionStarted()
            case .ended:
                idleReWarm.noteSessionEnded()
            default:
                break
            }
            router?.deliver(effect)
        }
        self.deliverEffect = deliver
        let wirings = Self.makeWirings(
            holdToTalk: configuration, toggle: toggleConfiguration, ceiling: ceiling, clock: clock,
            holdSource: gate, toggleSource: toggleGate, keyState: keyState,
            holdTimer: watchdogTimer, toggleTimer: toggleTimer, deferOpening: deferOpening,
            deliverEffect: deliver)
        let holdToTalk = wirings.holdToTalk
        self.holdToTalk = holdToTalk
        let toggle = wirings.toggle
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
        // The launch mode, read from the store exactly once and used for **both** the reported
        // mode and the tap's route — the two are one fact, and this local is where it lives.
        self.activeMode = initialMode
        let initialRoute: ScheduledWatchdog<AudioBuffer>
        switch initialMode {
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
                // The tap-armed fact's live source: every poll answer lands here, and the
                // onboarding store's armed-fact read (`TapHealth != .permissionMissing`) plus
                // its live ✓/✗ refresh ride on the same channel — the grant arriving mid-flow
                // flips the row within a poll (S1, M5).
                cancelRouterBox?.value?.latestTapHealth = health
                cancelRouterBox?.value?.onboardingStore?.refresh()
                // The translation from `TapHealth` to the menu's plain facts lives here, in the
                // one place that already knows both the tap and the widget. `VoccaUI` stays free
                // of any dependency on `VoccaHotkey` for it.
                cancelRouterBox?.value?.updateMenuBarConditions { conditions in
                    conditions.isHotkeyDeafForPermission = health == .permissionMissing
                    conditions.isBlockedBySecureInput = health == .blockedBySecureInput
                }
                // The idle re-warm policy's wake rides this same per-second housekeeping turn
                // (`rewarm-after-idle`): no new timer type, no new injectable surface, zero
                // marginal battery — the poll already runs for the app's life. Ticked only while
                // **both** machines are idle, so a session in flight never competes with it (the
                // effect funnel's notes already closed the window, and the state check keeps the
                // tick honest under a rebind that replaced the machines).
                if cancelRouterBox?.value?.holdToTalk.machine.state == .idle,
                    cancelRouterBox?.value?.toggle.machine.state == .idle
                {
                    cancelRouterBox?.value?.tickIdleReWarm()
                }
            })
        self.tapHealth = tapHealth

        // The tap is created here. Without an Accessibility grant `tapCreate` returns nil and the
        // answer is `.permissionMissing` — logged, and the loop stays idle until the grant (the
        // ~1 s poll and the grant notification are the recovery, already wired above). The
        // arm's answer is also the onboarding store's first armed fact — kept here so the read
        // is live from the instant the root exists, before the first poll.
        let armedHealth = tapHealth.arm()
        Self.logTapHealth(armedHealth)
        latestTapHealth = armedHealth

        // The last step: the tap's sink can now reach this object's cancel router. The box is
        // deliberately filled last, so no path that could fire before the initializer finished —
        // none exists, but the ordering is the point — would find a half-built root.
        cancelRouterBox.value = self
    }

    // MARK: - The two wirings, built in one place

    /// **Both session wirings, from one construction** — the aspect's central design move.
    ///
    /// `init` builds the launch pair and ``rebind(to:)`` builds the replacement pair. If those two
    /// call sites each constructed a `Wiring` inline they would drift, and a rebuilt wiring that
    /// differs from a launched one is a defect that appears only *after* a rebind — the hardest
    /// kind to see, because every test that never rebinds stays green.
    ///
    /// **Static, and it has to be.** The launch pair is assigned to stored properties, so this
    /// cannot be an instance method: Swift will not let an initializer call one before every
    /// property is initialized. Taking the collaborators as parameters is what lets `init` pass
    /// locals and ``rebind(to:)`` pass the ones the root has been holding since.
    ///
    /// **Each wiring gets its own timer, and the parameters are two rather than one for that
    /// reason.** A `RepeatingTimer` handed to a second ``ScheduledWatchdog`` while the first still
    /// holds it is two owners on one clock: `start` on either cancels the other's schedule, and the
    /// loser's machine is left with no ceiling and no physical-key poll — a session with nothing
    /// able to end it, which is the Fatal risk this aspect exists to make unrepresentable.
    private static func makeWirings(
        holdToTalk holdConfiguration: HotkeyConfiguration,
        toggle toggleConfiguration: HotkeyConfiguration,
        ceiling: Duration,
        clock: any MonotonicClock,
        holdSource: any SessionAudioSource<AudioBuffer>,
        toggleSource: any SessionAudioSource<AudioBuffer>,
        keyState: any PhysicalKeyStateReader,
        holdTimer: any RepeatingTimer,
        toggleTimer: any RepeatingTimer,
        deferOpening: @escaping RunLoopDeferral,
        deliverEffect: @escaping (SessionEffect<AudioBuffer>) -> Void
    ) -> (holdToTalk: Wiring, toggle: Wiring) {
        (
            Wiring(
                configuration: holdConfiguration, ceiling: ceiling, clock: clock,
                source: holdSource, keyState: keyState, timer: holdTimer,
                deferOpening: deferOpening, deliverEffect: deliverEffect),
            Wiring(
                configuration: toggleConfiguration, ceiling: ceiling, clock: clock,
                source: toggleSource, keyState: keyState, timer: toggleTimer,
                deferOpening: deferOpening, deliverEffect: deliverEffect)
        )
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
        // Written only once the change is actually adopted, below the refusals above: a store
        // describing a mode the running app never entered would be honoured by the next launch.
        settings?.setActivationMode(Self.activation(for: mode))
        activeMode = mode
        switch mode {
        case .holdToTalk:
            modeRouting.active = holdToTalk.scheduledWatchdog
            router.activeFeed = holdFeed
        case .toggle:
            modeRouting.active = toggle.scheduledWatchdog
            router.activeFeed = toggleFeed
        }
    }

    // MARK: - The binding

    /// **Binds the hotkey to a new chord, at an idle boundary** — `hotkey-rebinding` M4.
    ///
    /// ``setActiveMode(_:)``'s and ``setEngineSelection(_:)``'s shape, and for the same reason: a
    /// change while a session is in flight is refused, so a user who rebinds mid-dictation gets the
    /// new chord on their next press rather than a broken session. Nothing is ever swapped under a
    /// running microphone.
    ///
    /// **This is a rebuild, not a value update, and that is a safety choice rather than a
    /// limitation.** The binding is immutable end to end — `HotkeyConfiguration`'s fields are `let`
    /// and `SessionMachine.configuration` is a `let` — so a mutation path would have to be added.
    /// It would be smaller, and the watchdog would track it for free, since `theBindingIsStillHeld`
    /// re-reads the configuration on every ~150 ms poll. But a mutation landing between a `keyDown`
    /// and its `keyUp` leaves `SessionRules.decide` and that poll disagreeing about what is held,
    /// and a session stranded on a key nobody is holding is roadmap C1-A, *stuck recording*, rated
    /// Fatal for trust. Rebuilding on an idle boundary makes that unrepresentable rather than
    /// merely unlikely.
    ///
    /// The order of the seven steps below is the whole of the argument:
    ///
    /// 1. **Refuse a no-op.** Re-choosing the running chord must not cost two rebuilt watchdogs and
    ///    two discarded timers — which is exactly what a recorder's Save button does when a user
    ///    opens it, looks at the binding and saves it back.
    /// 2. **Refuse what the rules refuse**, before anything is built or written. The rules are
    ///    asked, never re-derived: the recorder, the launch read and this method give one answer or
    ///    they give three.
    /// 3. **Refuse unless both machines are quiet** — see ``isQuiet(_:)``. Both, not the routed
    ///    one: both are constructed at every launch, and a session in the unrouted machine is
    ///    still a session.
    /// 4. **Build both new wirings**, with nothing adopted yet.
    /// 5. **Persist.**
    /// 6. **Swap, and re-point the route** — one straight-line block with no suspension point in
    ///    it, which is what makes the rebuild atomic (M4a).
    /// 7. **Stop the retired timers**, after the swap.
    ///
    /// **Synchronous, and it must stay so.** A suspension point between step 3 and step 6 would let
    /// a session start into a wiring that is about to be discarded — which is the failure the idle
    /// guard exists to prevent, re-introduced one `await` at a time.
    ///
    /// The tap is not touched at all. It is binding-agnostic — its `eventsOfInterest` mask is built
    /// from event kinds, never key codes — and it is owned above the wirings; re-creating it would
    /// be a chance to lose a working tap, since `CGEvent.tapCreate` needs the Accessibility grant.
    ///
    /// - Returns: what happened, **returned rather than only logged** (M5), so the recorder can
    ///   tell the user why a rebind did not take. A rebind that appears not to have registered
    ///   invites a second attempt, made on a keyboard whose binding the user is no longer sure of.
    @discardableResult
    public func rebind(to chord: HotkeyChord) -> RebindOutcome {
        guard chord != boundChord else { return .unchanged }

        let validity = HotkeyBindingRules.validate(
            keyCode: chord.keyCode, modifiers: chord.modifiers)
        guard PersistedSettings.isAdoptable(validity) else {
            let refusal = HotkeyChordFormatter.describe(
                keyCode: chord.keyCode, modifiers: chord.modifiers)
                + " (\(validity))"
            logger.error("refusing to bind \(refusal, privacy: .public)")
            return .refused(.notBindable)
        }

        guard Self.isQuiet(holdToTalk), Self.isQuiet(toggle) else {
            logger.error(
                "refusing to rebind the hotkey while a session is in flight — end it first")
            return .refused(.sessionInFlight)
        }

        // Step 4. Everything fallible or expensive happens here, with nothing adopted yet: two new
        // machines, two new watchdogs, two fresh timers. If this were to fail, the previous pair is
        // still built and still routed.
        let configurations = AppBootstrap.hotkeyConfigurations(chord: chord)
        let rebuilt = Self.makeWirings(
            holdToTalk: configurations.holdToTalk, toggle: configurations.toggle,
            ceiling: ceiling, clock: clock, holdSource: gate, toggleSource: toggleGate,
            keyState: keyState, holdTimer: makeWatchdogTimer(), toggleTimer: makeWatchdogTimer(),
            deferOpening: deferOpening, deliverEffect: deliverEffect)

        // Step 5. Persisted only now, and this is where the order deviates from `setActiveMode`.
        // That method persists first because its adopt is infallible; this one does real
        // construction, so persisting first would risk a store describing a chord the running app
        // never adopted — the failure that method's own comment warns about, from the other side.
        settings?.setHotkeyChord(chord)

        // Step 6. **One straight-line block, with no `await` and no suspension point in it.** This
        // is what makes the rebuild atomic (M4a): there is no window in which one wiring is new and
        // the other old, and none in which the routing sink points at a discarded object. It is
        // also why this method is synchronous and must stay so — a suspension between the idle
        // guard above and these three lines would let a session start into a wiring about to be
        // thrown away.
        let previous = (holdToTalk: holdToTalk, toggle: toggle)
        holdToTalk = rebuilt.holdToTalk
        toggle = rebuilt.toggle
        switch activeMode {
        case .holdToTalk: modeRouting.active = rebuilt.holdToTalk.scheduledWatchdog
        case .toggle: modeRouting.active = rebuilt.toggle.scheduledWatchdog
        }

        // Step 7. After the swap, so a timer that refuses to stop cannot leave the new graph
        // unrouted: a leaked timer is a leak, and a dead hotkey on an `LSUIElement` app is
        // indistinguishable from a working one. `stop()` rather than the non-asserting form
        // because this is not a `deinit` — the method is `@MainActor` and the isolation the shipped
        // timer asserts is genuinely held.
        previous.holdToTalk.timer.stop()
        previous.toggle.timer.stop()

        return .rebound
    }

    /// **Whether this wiring has nothing in flight.**
    ///
    /// Two questions, because ``SessionState`` alone cannot answer the one that matters. A press
    /// under `CaptureStartTiming.whenTheOwnerAsks` — which is what ships, because
    /// `AVAudioEngine.start()` was measured at ~114 ms and a tap callback may not pay it — claims
    /// the key, delivers `.opening`, and leaves the machine in `.idle` with an opening *owed* until
    /// a later turn of the run loop. **Every press passes through that window**, and a rebuild
    /// inside it discards the wiring that owes the opening: the deferral holds its
    /// `ScheduledWatchdog` weakly, so the block finds nothing, the microphone never opens, and no
    /// `.ended` is ever delivered — the widget is stranded in OPENING with no time-based transition
    /// able to move it, which is the defect `settings-live-controls` found on the refused-press
    /// path arrived at from the other side.
    ///
    /// So both are asked, of **both** machines. `setActiveMode(_:)` asks only about `state`, and
    /// correctly: it re-points a route and discards nothing, so the pending opening it might race
    /// still completes into a wiring that is still there.
    private static func isQuiet(_ wiring: Wiring) -> Bool {
        wiring.machine.state == .idle && !wiring.machine.hasPendingOpening
    }

    /// **The bound chord as a person reads it** — the one answer all three surfaces render
    /// (`general-tab-recorder` M10): the General tab, the menu bar's VoiceOver label and
    /// onboarding's "Hold …" lines.
    ///
    /// Computed from ``boundChord`` through ``HotkeyChordFormatter`` on every read, so there is no
    /// stored string anywhere to go stale. All three surfaces are built once and kept for the
    /// process's lifetime, and until this aspect all three read one captured literal — so the first
    /// rebind would have left every one of them naming a chord nothing was bound to
    /// (`HotkeySurfaceAgreementTests`).
    public var hotkeyDisplayName: String {
        HotkeyChordFormatter.describe(
            keyCode: boundChord.keyCode, modifiers: boundChord.modifiers)
    }

    /// The chord the loop is listening for **now** — read from the wiring rather than remembered,
    /// so a rebind cannot leave it describing a binding nothing is bound to.
    private var boundChord: HotkeyChord {
        HotkeyChord(
            keyCode: holdToTalk.configuration.keyCode,
            modifiers: holdToTalk.configuration.modifiers)
    }

    // MARK: - The engine

    /// Switches the engine the **next** session will run.
    ///
    /// ``setActiveMode(_:)``'s shape, for the same reason: a change while a session is in flight is
    /// refused and logged, so a user who changes this while dictating gets the change on their next
    /// press rather than a broken session. Nothing is ever swapped under a running microphone.
    ///
    /// The order below is the whole of the safety argument, and it is deliberate:
    ///
    /// 1. **Refuse a no-op.** Re-choosing the running engine must not close the gate — otherwise
    ///    clicking the engine already in use costs the user a re-warm before their next press.
    /// 2. **Refuse mid-session**, both machines, exactly as the mode switch does.
    /// 3. **Persist**, so the choice survives the launch even if everything after this fails.
    /// 4. **Replace the resolver.** `DictationEngineResolver.selection` is a `let` and resolution is
    ///    never repeated (only preparation is), so a switch is a new resolver or it is nothing.
    /// 5. **Close the readiness gate.** The new engine is not prepared; until it is, a press must be
    ///    refused before the microphone opens. Closing is always the safe direction.
    /// 6. **Prepare eagerly** (PRD M10), so the first press after a switch is not refused for a
    ///    model that is already sitting on disk.
    ///
    /// A `prepare()` that fails leaves the gate closed with the selection **still switched**: the
    /// user asked for this engine, and silently reverting to the other one would be deciding for
    /// them. The next press then refuses honestly and says why.
    public func setEngineSelection(_ selection: EngineSelection) {
        guard selection != resolver.selection else { return }
        guard holdToTalk.machine.state == .idle, toggle.machine.state == .idle else {
            logger.error(
                "refusing to switch engine while a session is in flight — end it first")
            return
        }
        guard let makeResolver else {
            logger.error(
                "no resolver factory is wired — this composition cannot switch engines")
            return
        }
        settings?.setEngineSelection(selection)
        resolver = makeResolver(selection)
        markEnginePreparing()
        startEnginePreparation()
    }

    /// **The selected engine's model was deleted** — the Speech tab's [Remove], reported back.
    ///
    /// Removing a model the app has already loaded does not un-load it: the engine is in memory
    /// and would keep transcribing until the process ended. That is precisely the in-between
    /// window `spec.md` R5 forbids — a Settings page reading `[ download ]` over an engine that
    /// still works, and a next launch that suddenly refuses with no explanation on the page that
    /// promised otherwise. So the gate closes now, and the next press refuses honestly.
    ///
    /// A tier the user is **not** using changes nothing: deleting Whisper while dictating with
    /// Parakeet is housekeeping, and closing the gate for it would break a working Vocca.
    ///
    /// `isModelMissing` is set as a fact the app was *told*, never inferred from an unprepared
    /// engine — see ``MenuBarState/modelMissing``, whose whole distinction rests on that.
    public func engineModelRemoved(tier: EngineTier) {
        guard tier == resolver.selection.tier else { return }
        // Before the gate is closed, so that a preparation already in flight for these bytes can
        // never win a race against the close and reopen it — see ``modelRemovalCount``.
        modelRemovalCount &+= 1
        markEngineUnavailable()
        updateMenuBarConditions { $0.isModelMissing = true }
    }

    /// **A model download started or stopped**, so the surfaces that report waits can say which
    /// wait this is.
    ///
    /// Only a download of the tier dictation is waiting on blocks anything. A background fetch of
    /// the other engine must leave every surface saying "ready", or a working Vocca spends the
    /// whole transfer claiming otherwise (`EngineStateAgreementTests`).
    ///
    /// A download in flight also clears ``MenuBarState/modelMissing``: bytes really are moving now,
    /// so waiting *is* the remedy again.
    public func engineDownloadChanged(tier: EngineTier, isRunning: Bool) {
        guard tier == resolver.selection.tier else { return }
        updateMenuBarConditions {
            $0.isDownloadingModel = isRunning
            if isRunning { $0.isModelMissing = false }
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
        updateMenuBarConditions {
            $0.isEnginePrepared = true
            $0.isPreparingEngine = false
            // A prepared engine has its model: whatever was removed has been fetched again, or a
            // different tier was selected. Leaving the flag set would keep "No speech model" on
            // an icon over an engine that is transcribing.
            $0.isModelMissing = false
        }
    }

    /// **What the engine is doing** — the projection the menu bar and the Settings surfaces read.
    ///
    /// Three answers rather than the gate's two, because "warming up after a switch" and "there is
    /// no usable model" are the same thing to a microphone and completely different things to a
    /// person (PRD M11).
    public var engineReadinessState: EngineReadinessState { readiness.state }

    /// Closes the readiness gate: a preparation is under way and the engine behind it is not ready.
    ///
    /// The counterpart to ``markEnginePrepared()``, and the safe direction of the pair — a closed
    /// gate refuses a press before the microphone is asked for. Called by every preparation as it
    /// begins, and synchronously by ``setEngineSelection(_:)`` so that no turn of the main actor
    /// exists in which the gate is open over an engine the user has just replaced.
    private func markEnginePreparing() {
        readiness.markPreparing()
        updateMenuBarConditions {
            $0.isEnginePrepared = false
            $0.isPreparingEngine = true
            // A preparation in flight is the newer fact about the same engine, and it is a wait
            // with a remedy. Whatever was missing is either being fetched or is a different tier.
            $0.isModelMissing = false
        }
    }

    /// Closes the readiness gate with **nothing in flight**: the preparation failed, so waiting is
    /// not the remedy and no surface may say it is.
    private func markEngineUnavailable() {
        readiness.markUnavailable()
        updateMenuBarConditions {
            $0.isEnginePrepared = false
            $0.isPreparingEngine = false
        }
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

    /// The idle re-warm policy's wake, on the root's per-second housekeeping turn.
    ///
    /// The tick is synchronous and its fire is dispatched by the policy itself (the
    /// `CoreBoundaryTests` ban on `@MainActor` in `VoccaCore` made the policy's tick the owner's
    /// synchronous call); the re-warm's work runs on the resolver actor, never on this turn.
    func tickIdleReWarm() {
        _ = idleReWarm.tick()
    }

    /// The idle re-warm policy's fire — the trigger the policy was constructed with, reached
    /// through the weak box because it runs minutes after launch.
    ///
    /// The resolver is **re-read at fire time** (the ``prepareAndAssemble()`` capture precedent):
    /// a selection change mid-window re-points the fire at the new resolver, so the re-warm
    /// always hits the selected tier's engine — never the abandoned one — under the
    /// ``EngineTier/storageID`` keying. **No removals guard is needed**: a re-warm installs
    /// nothing and opens nothing, so it cannot race a removal the way a gate-opening preparation
    /// can (the stale-preparation analysis: only gate/pipeline installs needed guarding).
    ///
    /// It never touches ``EngineReadiness`` — ``markEnginePrepared()`` stays the only opener, a
    /// session starting mid-re-warm is never refused, and a failed re-warm never closes the gate
    /// (the old model stays resident; the next idle window retries).
    func rewarmEngineAfterIdle() async {
        let resolver = self.resolver
        logger.info("idle re-warm: firing")
        do {
            try await resolver.rewarmIfNeeded()
            logger.info("idle re-warm: complete")
        } catch {
            logger.error(
                "idle re-warm failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// One preparation, from the resolver that was current when it started.
    ///
    /// ## The stale-preparation race, and the guard that closes it
    ///
    /// This runs concurrently with itself. The launch preload can still be warming Parakeet — a
    /// cold CoreML load is seconds, and the model may be downloading — when the user picks Whisper
    /// in Settings; the switch replaces the resolver and starts a second run of this function.
    /// Then the *first* one's `prepare()` returns, successfully, for a resolver nobody is using.
    ///
    /// Replacing the resolver does not stop that completion from reaching ``markEnginePrepared()``,
    /// and if it reached it the gate would be open over an engine that was never prepared: the next
    /// press would open the microphone for an engine that cannot transcribe, which is the one
    /// outcome the readiness gate exists to prevent. So the resolver is captured **once**, at the
    /// top, and re-compared to the slot after **every** suspension point. A run that is no longer
    /// the current one abandons itself: it installs nothing and opens nothing.
    ///
    /// Identity is the right comparison because every switch mints a fresh resolver — including a
    /// switch back to the engine that was running, which is a different object with its own
    /// `isPrepared`. Check-then-act is atomic here because both this function and
    /// ``setEngineSelection(_:)`` are on the main actor, and no suspension separates a guard below
    /// from the statement it guards.
    ///
    /// ## The removal race, which identity alone cannot see
    ///
    /// Identity answers "is this still the selected engine?", and a **removal** does not change the
    /// selection: the user deletes the model of the engine they are using, from the Speech tab,
    /// while this preload is still warming it. ``engineModelRemoved(tier:)`` closes the gate, but
    /// the resolver it closed it over is the same object this run captured, so `===` says "still
    /// current" and the run would go on to reopen the gate over bytes that are gone — the menu bar
    /// back to "ready" while the Speech tab offers to download the model it is claiming to run.
    /// ``modelRemovalCount`` is captured alongside the resolver for exactly that case, and every
    /// guard below compares both.
    private func prepareAndAssemble() async {
        let resolver = self.resolver
        let removals = modelRemovalCount
        markEnginePreparing()
        do {
            try await resolver.prepareIfNeeded()
        } catch {
            logger.error(
                "the engine could not be prepared: \(String(describing: error), privacy: .public)")
            // The gate stays closed — sessions refuse honestly with .modelUnavailable until a later
            // preparation succeeds — and the reported state drops from `preparing` to
            // `unavailable`, because nothing is in flight any more and a surface still saying "a
            // moment" would be promising a wait that never ends.
            if isCurrent(resolver, removals) { markEngineUnavailable() }
            return
        }
        guard isCurrent(resolver, removals) else { return }
        if let assembly = pipelineAssembly {
            guard let engine = await resolver.engineIfReady() else {
                logger.error(
                    "the engine reported prepared but answered no engine — nothing was installed")
                markEngineUnavailable()
                return
            }
            let pipeline: DictationPipeline
            do {
                pipeline = try await assembly(engine)
            } catch {
                logger.error(
                    "the dictation pipeline could not be assembled: \(String(describing: error), privacy: .public)")
                if isCurrent(resolver, removals) { markEngineUnavailable() }
                return
            }
            guard isCurrent(resolver, removals) else { return }
            router.install(pipeline: pipeline)
        }
        // Installed before the gate opens: no session that passes the gate can find itself without
        // a pipeline when it ends. Guarded like every other step, and for the same reason: the
        // assembly above suspends, and a removal delivered inside that window would otherwise be
        // undone by the very next line.
        guard isCurrent(resolver, removals) else { return }
        markEnginePrepared()
    }

    /// Whether the preparation that captured `candidate` and `removals` is still the one this root
    /// is running — the stale-preparation guard, in its two halves: the resolver may have been
    /// **replaced** by a switch, or the model it prepared may have been **removed** underneath it.
    /// Either answers `false`, and each is logged with its own reason, because an abandoned
    /// preparation is a real event somebody reading a log deserves to see — and which of the two
    /// happened is the first thing they will want to know.
    private func isCurrent(_ candidate: DictationEngineResolver, _ removals: UInt64) -> Bool {
        guard candidate === resolver else {
            logger.info(
                "abandoning a preparation for an engine that is no longer selected — the gate stays closed for it")
            return false
        }
        guard removals == modelRemovalCount else {
            logger.info(
                "abandoning a preparation whose model was removed while it was in flight — the gate stays closed until the model is on disk again")
            return false
        }
        return true
    }

    // MARK: - The inputs the sink does not carry

    /// **The quit path's feed teardown** — the menu bar's Quit calls it before `terminate`
    /// (`speculative-feed` phase (d)). Cancelling both feeds is safe by construction (`cancel` is
    /// idempotent and a never-started feed's empty stream simply finishes), and it makes "no feed
    /// left running" true in the code that runs rather than only as a property of process death.
    ///
    /// Executed by nothing in CI (the window-server rule — `MenuBarItem` is built by `main()`);
    /// `SMOKE_CHECKLIST.md` step 123 is its only execution.
    func cancelFeeds() {
        holdFeed?.cancel()
        toggleFeed?.cancel()
    }

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
    /// **The feed the mode the tap routes to owns** — set by the root on mode-routing changes
    /// (init and ``DictationLoopRoot/setActiveMode(_:)``), read once at `.opening`. `nil` in a
    /// composition without feeds keeps every terminal on the batch route, byte for byte.
    var activeFeed: SpeculativeFeed?
    /// **The feed this session started** — stored at `.opening`, used by every terminal, never
    /// re-read from the slot: a terminal cannot stop the wrong feed.
    private var startedFeed: SpeculativeFeed?

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
        sessionBox: LatencySessionBox?,
        activeFeed: SpeculativeFeed? = nil
    ) {
        self.panel = panel
        self.targetResolution = targetResolution
        self.readiness = readiness
        self.runningAppName = runningAppName
        self.widgetStore = widgetStore
        self.widgetClock = widgetClock
        self.recorder = recorder
        self.sessionBox = sessionBox
        self.activeFeed = activeFeed
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
            //
            // The speculative feed's key-down half: arm the instance the mode-routing slot
            // points at, and store it — every terminal stops exactly the feed this session
            // started, never a re-read of the slot (a terminal cannot stop the wrong feed). A
            // session that reaches `.recording` has been draining since `.opening` — the
            // "key-down → `.recording`" the spec names.
            let feed = activeFeed
            startedFeed = feed
            feed?.start()
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
            let feed = startedFeed
            startedFeed = nil
            // **The feed's terminal, synchronously here in `deliver`** — ordering pin (2): the
            // feed stops at the terminal, never when the spawned task happens to be scheduled.
            // A completed session's `terminate(with:)` appends the outcome's audio — the
            // remainder `endCapture` drained, before this `.ended` was delivered
            // (`SessionMachine.swift:656-662`) — as the stream's final chunk and finishes the
            // stream; a cancelled session's `cancel()` finishes the stream with nothing
            // appended (routing a cancelled outcome through `routeStreaming` would transcribe
            // an empty buffer and finalize `.emptySkip`, changing the record class).
            switch outcome.content {
            case .completed(_, let audio, _): feed?.terminate(with: audio)
            case .cancelled: feed?.cancel()
            }
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
                let surface: PipelineSurface
                switch outcome.content {
                case .cancelled:
                    // The batch route's cancelled row — `.aborted`, engine nil — preserved
                    // exactly as before the feed.
                    surface = await pipeline.route(
                        .ended(outcome), target: target, sessionID: sessionID)
                case .completed:
                    if let feed {
                        // The feed's stream is already complete — `terminate` ran in `deliver`
                        // above — so the route consumes the whole audio through the seam's
                        // streaming shape. The route finalizes the record on every path, exactly
                        // as the batch route did; only the seam's default stream has moved.
                        surface = await pipeline.routeStreaming(
                            chunks: feed.chunks, target: target, sessionID: sessionID)
                    } else {
                        // A composition without a feed keeps the batch route, byte for byte.
                        surface = await pipeline.route(
                            .ended(outcome), target: target, sessionID: sessionID)
                    }
                }
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
            // The feed's terminal for a session that never began: nothing was captured, so the
            // stream is finished with nothing appended.
            let feed = startedFeed
            startedFeed = nil
            feed?.cancel()
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
                // **And the pill is returned to IDLE**, which it was not until
                // `EngineStateAgreementTests` asked. A press folds OPENING before the refusal is
                // known, and the widget reducer contains no time-based transition by design (the
                // never-auto-dismiss rule) — so the branch above left the pill claiming a
                // microphone was opening until the *next* press, over a session that never began.
                // A surface stuck mid-gesture while a panel explains the failure is this
                // repository's dominant bug class, in the one moment a user is looking.
                //
                // IDLE rather than the widget's own notice: that notice reads "The microphone
                // didn't open — try again", and for a model that is missing the microphone is not
                // the cause and trying again is not the remedy. The panel owns the explanation;
                // the pill owes only an honest resting state.
                widgetStore.fold(WidgetProjection.project(event: .finishedWithoutDelivery))
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
///
/// ## Why it closes as well as opens
///
/// This was a one-way latch while a process ran exactly one engine for its whole life. The engine
/// is now switchable at runtime (`settings-live-controls`, aspect 3), and a switch must be able to
/// **close** the gate again: the engine whose `prepare()` succeeded is not the engine now
/// selected, and leaving the gate open over the old one would let a press open the microphone for
/// an engine that cannot transcribe.
///
/// The two directions are not symmetric, and the asymmetry is the whole safety argument. **Closing
/// is always safe** — a closed gate refuses the press before the microphone is asked for, the user
/// gets the honest `.modelUnavailable` notice, and the worst a spurious close can do is make
/// someone wait. **Opening is the dangerous direction**, so it keeps exactly one caller:
/// ``markReady()``, reached only from ``DictationLoopRoot/markEnginePrepared()``, reached in turn
/// only after `prepareIfNeeded()` has succeeded. `EngineReadinessTests` pins that closed set by
/// scanning this file, because the hazard is an opener nobody has written yet.
final class EngineReadiness {
    /// The state itself — three answers, because two cannot tell a wait from a failure.
    private(set) var state: EngineReadinessState = .unavailable

    /// The gate's own question: may a session open the microphone? Only
    /// ``EngineReadinessState/ready`` answers yes, so a state added to that enum is closed by
    /// default rather than open by accident.
    var isReady: Bool { state == .ready }

    /// The one opener. See the type's note: every other transition closes.
    func markReady() {
        state = .ready
    }

    /// Closes the gate because a preparation is **under way** — a launch preload, or the eager
    /// preparation a selection change starts.
    ///
    /// Idempotent — a state assignment, not a counter. Nothing about a switch should depend on how
    /// many times either transition was called.
    func markPreparing() {
        state = .preparing
    }

    /// Closes the gate because there is **nothing in flight**: a preparation failed, or none has
    /// started. Identical to ``markPreparing()`` at the gate's own level, where both are simply
    /// "closed", and different everywhere a person is told about it — one is a wait, the other is
    /// something to act on.
    func markUnavailable() {
        state = .unavailable
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
    /// The strategy memory the ladder consults — kept so the Apps tab can write through to the
    /// *running* ladder, not only to the file it will read at the next launch.
    let memory: MemoryBackedInjectionStrategyOrder
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

/// **The production partial sink** — the pipeline's widget-only `PartialTranscriptSink` folded
/// into the root's `@MainActor` widget store, the `WidgetStorePartialSink` shape (the probe's
/// streaming drive owns a copy of the same type).
///
/// The pipeline is assembled *after* the root (the `pipelineAssembly` shape), and the store is
/// created *by* the root's initializer — so the store is reached through a weak box filled right
/// after the root is built. Weak, like every box in this module: the root owns the store, and
/// the sink must not extend its lifetime.
///
/// The dispatch is fire-and-forget by the seam's own contract (`PartialTranscriptSink`'s
/// documentation): emitting adds no suspension to the streaming path, and the fold lands on the
/// main actor — the store's one isolation domain.
///
/// `@unchecked Sendable` is the claim `LedgerPartialSink` makes for the same reason: the
/// protocol's `presentPartial` is synchronous, so an actor double cannot witness it honestly;
/// the mutex serializes the counter and the box is written once, before any partial can arrive.
private final class BootstrapPartialSink: PartialTranscriptSink, @unchecked Sendable {
    private let countLock = Mutex(0)

    /// The root's widget store, filled after the root is built. `nil` until then, and a sink
    /// whose box was never filled presents partials to nothing — the honest absent-store answer.
    weak var store: WidgetStateStore?

    func presentPartial(_ partial: String) {
        countLock.withLock { $0 += 1 }
        Task { @MainActor in
            store?.presentPartial(partial)
        }
    }
}
