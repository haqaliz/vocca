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

import SwiftUI
import VoccaCore

/// What the settings window can read and change, injected so the window knows nothing about the
/// composition root and the root knows nothing about SwiftUI.
///
/// Every closure here is a seam the app fills with something real and a test fills with a fake.
/// The window is then glue over them, which is the same division the widget already uses.
@MainActor
public struct SettingsBindings {

    /// Whether the shipped toggle mode is active. `false` means hold-to-talk.
    public var isToggleMode: () -> Bool
    /// Switches activation mode. Refused mid-session by the root, which logs and does nothing.
    public var setToggleMode: (Bool) -> Void
    /// Whether quitting from the Dock keeps Vocca running in the menu bar.
    public var isKeepInTray: () -> Bool
    /// Persists the keep-in-tray choice.
    public var setKeepInTray: (Bool) -> Void
    /// The hotkey, in the form a person reads — **read, never captured**.
    ///
    /// A `String` here was a defect waiting for the recorder: the window is built once and kept
    /// for the process's lifetime, so a chord captured at construction would go on naming the old
    /// binding until the next launch — including on the very page the user had just changed it on.
    /// The `engineSelection` argument, applied to the fact this tab exists to show.
    public var hotkeyDisplayName: () -> String
    /// The converse chord, in the form a person reads — **read, never captured**, the
    /// `hotkeyDisplayName` doctrine for the second mode (`dual-mode` D6): the window is built
    /// once and kept for the process's lifetime, so a captured string would go on naming the old
    /// converse binding until the next launch — on the very page the user had just changed it on.
    public var converseHotkeyDisplayName: () -> String
    /// **What a captured key event means as a chord.** The recorder reads a raw macOS modifier
    /// word and a virtual key code off an `NSEvent` and hands them straight here — it translates
    /// nothing itself.
    ///
    /// A seam rather than a local translation because the translation is not trivial: it carries
    /// the `fn` rule, where the hardware sets the function bit by itself on the arrow keys and the
    /// navigation cluster. That rule already exists, in `VoccaHotkey`, and is driven against
    /// CoreGraphics' own constants by test. `VoccaUI` may import only `VoccaCore`
    /// (`ModuleBoundaryTests`), so a second copy here would be a second dialect of the one
    /// translation the whole hotkey story rests on.
    public var chordForKeyEvent: (UInt64, UInt16) -> HotkeyChord

    /// Whether a candidate chord may be bound for a mode, and what to say about it — the rules
    /// plus what the system has already claimed plus what the **other** mode is wired to, asked
    /// once (`dual-mode` D5: the wiring closure computes the other chord; the recorder never
    /// re-derives it).
    public var validateChord: (HotkeyChord, SessionMode) -> HotkeyBindingValidity

    /// Binds a chord for a mode, and says what happened.
    ///
    /// Routed to `DictationLoopRoot.rebind(to:for:)`, which refuses mid-session — in either
    /// mode — and takes effect on the next press. **The answer is returned, not merely logged**:
    /// a rebind that appears not to have registered invites a second attempt, and the second
    /// attempt is made on a keyboard whose binding the user is no longer sure of.
    public var rebind: (HotkeyChord, SessionMode) -> RebindOutcome

    /// The engine currently transcribing, for the Speech tab.
    public var engineDisplayName: () -> String
    /// **What Vocca is actually cleaning with** — the resolved provider's name, its own egress
    /// declaration, and the endpoint when there is one to name.
    ///
    /// `nil` when nothing has resolved (a composition with no resolver, which is every headless
    /// harness): the page claims nothing rather than inventing an answer. Asynchronous because the
    /// resolver is an actor and the answer is a fact about the process, not a captured copy — the
    /// `engineDisplayName` argument, applied to the one tab whose wrong answer is a privacy claim.
    public var cleanupSummary: () async -> CleanupSummary?
    /// **What Vocca is actually cleaning conversations with** — the converse half of
    /// ``cleanupSummary``, for the Cleanup tab's "While conversing" section.
    ///
    /// Defaulted to claim **nothing**: the `converse-wiring` aspect fills this slot in its
    /// AppBootstrap re-anchor commit (one additive line, recorded handoff); until then the
    /// converse section renders no "Using" line, which is the safe direction — a surface claims
    /// no provider it cannot name.
    public var cleanupConversingSummary: () async -> CleanupSummary?
    /// The cleanup config as the tab edits it — the same `cleanup-config.json` the resolver
    /// reads, never a second copy that drifts from it.
    public var loadCleanupConfig: () async -> CleanupConfigDraft
    /// Writes it back. Throws what the store throws: a cleanup choice the user made that did not
    /// reach the disk must say so.
    public var saveCleanupConfig: (CleanupConfigDraft) async throws -> Void
    /// Whether the one-time cloud confirmation has already been read and accepted
    /// (`PRODUCT_SPEC.md:273`).
    public var isCloudCleanupAcknowledged: () -> Bool
    /// Records that it has. Best-effort: a failed write shows the dialog once more, which is the
    /// safe direction.
    public var setCloudCleanupAcknowledged: (Bool) -> Void
    /// Whether the separate, off-by-default global grant for sending app context with cloud
    /// cleanup is on (`byok-context-grant` M7) — the Cleanup tab's toggle.
    public var isContextGrantEnabled: () -> Bool
    /// Persists the grant choice. Best-effort: a failed write reverts to off, which is the safe
    /// direction.
    public var setContextGrantEnabled: (Bool) -> Void
    /// Whether the context kill switch is off — the runtime revoke state (`widget-indicator`
    /// D6), reflected by the General tab's Context toggle. **Read, never captured**: the window
    /// is built once and kept for the process's lifetime, so a captured value would go on
    /// showing the launch state after a mid-session kill. The wiring to the runtime revoked flag
    /// is `bootstrap-wiring`'s (recorded hand-off).
    public var isContextReading: () -> Bool
    /// The one-action revoke (M9): stops the reads, discards the in-flight snapshot, and folds
    /// the badge clear. Defaulted to claim **nothing** and change **nothing** — the "defaults
    /// claim nothing" doctrine; the wiring of the closure is `bootstrap-wiring`'s.
    public var setContextReading: (Bool) -> Void
    /// Loads the user's replacements.
    public var loadDictionary: () async -> [ReplacementRule]
    /// Saves the user's replacements.
    public var saveDictionary: ([ReplacementRule]) async throws -> Void
    /// What Vocca has learned or been told about each application, with names resolved and the
    /// seeded allowlist's answer folded in.
    ///
    /// Reads the **store**, not the ladder's live snapshot: the seeded-hostile entries the memory
    /// mints at launch are seed, not learning, and a table that listed them as things Vocca had
    /// worked out would be claiming knowledge it does not have.
    public var loadStrategies: () async -> [AppStrategyEntry]
    /// Writes the whole set back — the `saveDictionary` shape, for the same reason: the reducer
    /// has already computed the post-action truth, so a wholesale write cannot disagree with what
    /// the table shows. The wiring also hands it to the running ladder, so a pin applies to the
    /// next dictation rather than to the next launch.
    public var saveStrategies: ([AppStrategyEntry]) async throws -> Void

    // MARK: - Context consent (C12, M4)

    /// The per-app context consent as the Apps tab reads it: the consented bundle IDs — the
    /// store's own answer, bundle IDs only, nothing more. Asked every time the page opens,
    /// never cached: the tab's own toggle is what changes it.
    public var loadContextConsent: () async -> Set<String>
    /// Writes the whole consented set back — the store's wholesale `save(_:)`, the editing
    /// path the seam reserves for the Apps tab. A failed write is surfaced, never swallowed:
    /// a grant that silently failed to save is one the next resolution never honours.
    public var saveContextConsent: (Set<String>) async throws -> Void

    // MARK: - Usage

    /// The daily-use ledger as the Usage tab reads it: the days the window holds, and the streak
    /// off them.
    ///
    /// Asynchronous and asked once per opening, the ``loadStrategies`` shape — and answered from
    /// the **live** window rather than the file, which is the one place this tab is deliberately
    /// unlike the Apps one. The recorder holds folds the write cadence has not committed yet, so
    /// a page reading the file would tell a user who just dictated that it never happened, on the
    /// screen that exists to show them what Vocca recorded.
    ///
    /// The streak arrives in the snapshot rather than being computed here, because it is a fact
    /// about **today** and `VoccaCore` reads no clock: resolving a wall-clock instant into a
    /// ``CalendarDay`` — with the time zone and the day-rollover question that comes with it — is
    /// the wiring's job, where it can be seen and configured.
    public var loadUsageSnapshot: () async -> UsageSnapshot

    /// Forgets everything the ledger holds — **the window and the file together**.
    ///
    /// Routed to the one object that owns both halves. Clearing either alone is a Clear the
    /// user's history survives: the file reloads at the next launch, or the still-full window is
    /// written straight back at the next cadence tick.
    ///
    /// It reports no failure because the page offers no words for one: `PRODUCT_SPEC.md` §7 gives
    /// this control a button, a sentence and a confirmation, and nothing to say when a deletion
    /// does not take. The failure is not swallowed — the recorder logs it loudly and leaves the
    /// empty window marked unwritten, so the next write empties the file anyway.
    public var clearUsage: () async -> Void

    // MARK: - Speech

    /// The engine and tier in use **right now**, read rather than captured: the window is built
    /// once and kept for the process's lifetime, so a captured selection would leave the radio
    /// pointing at the launch engine for ever — including straight after the user changed it here.
    public var engineSelection: () -> EngineSelection
    /// Switches the engine. Routed to `DictationLoopRoot.setEngineSelection(_:)`, which already
    /// refuses mid-session, persists the choice and prepares the new engine eagerly (aspect 3).
    public var setEngineSelection: (EngineSelection) -> Void
    /// What the readiness gate says — the one fact the Speech tab, the menu bar and the next press
    /// all render (`EngineStateAgreementTests`).
    public var engineReadiness: () -> EngineReadinessState
    /// The store's presence and disk answers, per tier. Asked, never cached: a model can be
    /// removed by this very page.
    public var modelSnapshot: () async -> [SpeechTabTierSnapshot]
    /// A download session for one tier, or `nil` when one cannot be built (a manifest that will
    /// not load). `nil` is offered to nobody — the row shows no download it cannot perform.
    public var makeDownloadSession: (EngineTier) -> (any ModelDownloadSession)?
    /// Deletes one tier's model. Throws what the store throws: a removal the user asked for that
    /// did not happen must say so.
    public var removeModel: (EngineTier) async throws -> Void
    /// Whether a dictation is in flight — the R5 guard. Removal is refused while it is `true`.
    public var isSessionInFlight: () -> Bool
    /// A download for one tier started or stopped. Reported so the surfaces that describe waits
    /// can tell a download from a warm-up — and so the menu bar does not report a background fetch
    /// of an engine nobody selected as a reason dictation is unavailable.
    public var downloadActivityChanged: (EngineTier, Bool) -> Void

    // MARK: - Actions (C13, action-surface-wiring)

    /// The configured servers and persisted enablement as the Actions tab reads them — the
    /// tab's own plain model, mapped by the wiring from the store's `action-config.json`. The
    /// empty draft is the honest first-launch answer: no server is configured out of the box,
    /// and the default configuration cannot create a child (the D2 narrowed promise).
    public var loadActionsConfig: () async -> ActionsConfigDraft
    /// Writes the whole draft back — servers and enablement in one save, so what the table
    /// shows and what the file holds cannot drift. Throws what the store throws: a server the
    /// user believes configured must be configured.
    public var saveActionsConfig: (ActionsConfigDraft) async throws -> Void
    /// Discovers the tools of one server — the explicit, user-initiated spawn
    /// (`action-surface-wiring` D2). The answer is the tab's own model: the tool rows, or the
    /// bounded failure key.
    public var discoverTools: (String) async -> ActionsDiscoveryResult
    /// The shell registry's configured commands as tool rows — the shell leg's row source
    /// (`shell-provider` wiring). A registry read, never a discovery and never a spawn. The
    /// empty answer is the honest default: no command is configured out of the box.
    public var loadShellCommands: () async -> [ActionsToolRow]
    /// Flips one tool's enablement row. Persisted as membership; absent is off (PRD M7).
    public var setToolEnabled: (String, String, Bool) async throws -> Void
    /// Runs the armed action through the gate — the wiring's half of the arm path, behind the
    /// confirmation card. The tab itself never calls this; it emits `awaitingConfirmation` and
    /// ``confirmationPresented()`` and stops.
    public var armAction: (String, String) async throws -> Void
    /// Renders the provider's sentence for one tool, without acting — the dry-run half of the
    /// seam. `nil` when nothing can be said.
    public var previewAction: (String, String) async -> String?
    /// The wiring's signal that the confirmation card appeared — the arm path's observable half.
    public var confirmationPresented: () -> Void
    /// The wiring's signal that the confirmation card went away.
    public var confirmationDismissed: () -> Void

    public init(
        isToggleMode: @escaping () -> Bool,
        setToggleMode: @escaping (Bool) -> Void,
        isKeepInTray: @escaping () -> Bool = { false },
        setKeepInTray: @escaping (Bool) -> Void = { _ in },
        hotkeyDisplayName: @escaping () -> String,
        converseHotkeyDisplayName: @escaping () -> String = { "" },
        chordForKeyEvent: @escaping (UInt64, UInt16) -> HotkeyChord,
        validateChord: @escaping (HotkeyChord, SessionMode) -> HotkeyBindingValidity,
        rebind: @escaping (HotkeyChord, SessionMode) -> RebindOutcome,
        engineDisplayName: @escaping () -> String,
        cleanupSummary: @escaping () async -> CleanupSummary?,
        // The converse summary defaults claim **nothing**, for the reason the dictate defaults
        // do — and it is the `converse-wiring` handoff's slot: until the wiring fills it, no
        // surface reports a converse provider it cannot name.
        cleanupConversingSummary: @escaping () async -> CleanupSummary? = { nil },
        // The cleanup defaults claim **nothing** and change **nothing**, for the reason the Speech
        // defaults do: a default that pretended to work would let a page report a provider and
        // save a choice that nothing is behind. Unacknowledged is the safe direction too — the
        // worst case is a dialog shown once more.
        loadCleanupConfig: @escaping () async -> CleanupConfigDraft = { .empty },
        saveCleanupConfig: @escaping (CleanupConfigDraft) async throws -> Void = { _ in },
        isCloudCleanupAcknowledged: @escaping () -> Bool = { false },
        setCloudCleanupAcknowledged: @escaping (Bool) -> Void = { _ in },
        // The context-grant defaults claim **nothing** and change **nothing**: off is both the
        // fresh-install truth and the safe direction — a default that answered `true` would let
        // the toggle render a grant nobody gave.
        isContextGrantEnabled: @escaping () -> Bool = { false },
        setContextGrantEnabled: @escaping (Bool) -> Void = { _ in },
        // The context-kill defaults claim **nothing** and change **nothing** (`widget-indicator`
        // D8): a default that reported reading would render a badge nobody armed, and a default
        // that revoked would perform a kill nothing asked for. `false`/`{}` is the safe
        // direction of a revoke-shaped surface — the toggle renders off.
        isContextReading: @escaping () -> Bool = { false },
        setContextReading: @escaping (Bool) -> Void = { _ in },
        loadDictionary: @escaping () async -> [ReplacementRule],
        saveDictionary: @escaping ([ReplacementRule]) async throws -> Void,
        loadStrategies: @escaping () async -> [AppStrategyEntry] = { [] },
        saveStrategies: @escaping ([AppStrategyEntry]) async throws -> Void = { _ in },
        // The consent defaults claim **nothing** and write **nothing**, for the reason the
        // strategy defaults do: an empty answer renders the honest "nothing consented"
        // (which is the fresh-install truth and the safe direction), and a save that claims
        // success while writing nothing would let the page tell a user their grant was
        // stored when it was not.
        loadContextConsent: @escaping () async -> Set<String> = { [] },
        saveContextConsent: @escaping (Set<String>) async throws -> Void = { _ in },
        // The usage defaults claim **nothing** and delete **nothing**, for the reason the Speech
        // and cleanup defaults do. An empty snapshot renders the empty state — the honest "we
        // have nothing to show you" — where a fabricated day or streak would be this page's one
        // unforgivable failure: inventing the very numbers a sceptic opened it to check. And a
        // clear that deletes nothing is the safe direction of a destructive control: a default
        // that reported a deletion nothing performed would let the page tell a user their history
        // was gone while it sat on disk.
        loadUsageSnapshot: @escaping () async -> UsageSnapshot = {
            UsageSnapshot(days: [], streak: 0)
        },
        clearUsage: @escaping () async -> Void = {},
        // The Speech defaults claim **nothing**, and that is deliberate. A default that pretended
        // to work — a `ready` gate, a tier reported present — would let a page offer a dictation
        // and a download that nothing is behind. Closed and empty is the safe direction, exactly
        // as it is for the readiness gate itself.
        engineSelection: @escaping () -> EngineSelection = { .defaultSelection },
        setEngineSelection: @escaping (EngineSelection) -> Void = { _ in },
        engineReadiness: @escaping () -> EngineReadinessState = { .unavailable },
        modelSnapshot: @escaping () async -> [SpeechTabTierSnapshot] = { [] },
        makeDownloadSession: @escaping (EngineTier) -> (any ModelDownloadSession)? = { _ in nil },
        removeModel: @escaping (EngineTier) async throws -> Void = { _ in },
        isSessionInFlight: @escaping () -> Bool = { false },
        downloadActivityChanged: @escaping (EngineTier, Bool) -> Void = { _, _ in },
        // The Actions defaults claim **nothing** and change **nothing**, for the reason the
        // usage defaults do. An empty config renders the honest "nothing configured" (which is
        // the fresh-install truth and the safe direction — no server is configured out of the
        // box), an un-wired discovery claims no tools, an un-wired shell leg claims no
        // commands, an un-wired preview claims no sentence,
        // and saves, enablement flips, gate arms and card signals that go nowhere change
        // nothing. A default that reported a discovery or an arm nothing performed would let
        // the page tell a user something happened when it did not.
        loadActionsConfig: @escaping () async -> ActionsConfigDraft = { .empty },
        saveActionsConfig: @escaping (ActionsConfigDraft) async throws -> Void = { _ in },
        discoverTools: @escaping (String) async -> ActionsDiscoveryResult = { _ in .succeeded([]) },
        loadShellCommands: @escaping () async -> [ActionsToolRow] = { [] },
        setToolEnabled: @escaping (String, String, Bool) async throws -> Void = { _, _, _ in },
        armAction: @escaping (String, String) async throws -> Void = { _, _ in },
        previewAction: @escaping (String, String) async -> String? = { _, _ in nil },
        confirmationPresented: @escaping () -> Void = {},
        confirmationDismissed: @escaping () -> Void = {}
    ) {
        self.isToggleMode = isToggleMode
        self.setToggleMode = setToggleMode
        self.isKeepInTray = isKeepInTray
        self.setKeepInTray = setKeepInTray
        self.hotkeyDisplayName = hotkeyDisplayName
        self.converseHotkeyDisplayName = converseHotkeyDisplayName
        self.chordForKeyEvent = chordForKeyEvent
        self.validateChord = validateChord
        self.rebind = rebind
        self.engineDisplayName = engineDisplayName
        self.cleanupSummary = cleanupSummary
        self.cleanupConversingSummary = cleanupConversingSummary
        self.loadCleanupConfig = loadCleanupConfig
        self.saveCleanupConfig = saveCleanupConfig
        self.isCloudCleanupAcknowledged = isCloudCleanupAcknowledged
        self.setCloudCleanupAcknowledged = setCloudCleanupAcknowledged
        self.isContextGrantEnabled = isContextGrantEnabled
        self.setContextGrantEnabled = setContextGrantEnabled
        self.isContextReading = isContextReading
        self.setContextReading = setContextReading
        self.loadDictionary = loadDictionary
        self.saveDictionary = saveDictionary
        self.loadStrategies = loadStrategies
        self.saveStrategies = saveStrategies
        self.loadContextConsent = loadContextConsent
        self.saveContextConsent = saveContextConsent
        self.loadUsageSnapshot = loadUsageSnapshot
        self.clearUsage = clearUsage
        self.engineSelection = engineSelection
        self.setEngineSelection = setEngineSelection
        self.engineReadiness = engineReadiness
        self.modelSnapshot = modelSnapshot
        self.makeDownloadSession = makeDownloadSession
        self.removeModel = removeModel
        self.isSessionInFlight = isSessionInFlight
        self.downloadActivityChanged = downloadActivityChanged
        self.loadActionsConfig = loadActionsConfig
        self.saveActionsConfig = saveActionsConfig
        self.discoverTools = discoverTools
        self.loadShellCommands = loadShellCommands
        self.setToolEnabled = setToolEnabled
        self.armAction = armAction
        self.previewAction = previewAction
        self.confirmationPresented = confirmationPresented
        self.confirmationDismissed = confirmationDismissed
    }
}

/// The settings window's content: a macOS preferences window, sidebar across the left.
///
/// **Sidebar-based since the `DeckApp` shape** (`../deck/native/DeckApp/DeckApp.swift:121-199`):
/// a `NavigationSplitView` whose sidebar is the tab list and whose detail is the tab's page —
/// the settings idiom a macOS user reads as "preferences" with room for a row of controls,
/// rather than a toolbar of icons above a cramped pane. The sidebar reads straight off
/// ``SettingsTab/allCases`` (title + symbol), so a case that exists gets a row and a page or
/// the build fails — the contract ``SettingsTabTests`` describes, now rendered as a list.
public struct SettingsView: View {

    private let bindings: SettingsBindings
    @State private var selection: SettingsTab? = .general

    public init(bindings: SettingsBindings) {
        self.bindings = bindings
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selection) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbolName)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            // An opaque sidebar, not the vibrancy default. `.listStyle(.sidebar)` samples what
            // is *behind the window*, so on a coloured desktop the sidebar takes the wallpaper's
            // hue — the same list reads near-black over a dark backdrop and indigo over a bright
            // one. Deck's sidebar is the look this window is meant to have
            // (`../deck/native/DeckApp/DeckApp.swift:121-199`), and it only reads that way there
            // because of what happens to be behind it. Painting the background makes the sidebar
            // the same on every desktop instead of a function of the user's wallpaper.
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .underPageBackgroundColor))
            .navigationSplitViewColumnWidth(min: 190, ideal: 190, max: 190)
        } detail: {
            if let selection {
                page(for: selection)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 640, height: 500)
    }

    @ViewBuilder
    private func page(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsPage(bindings: bindings)
        case .speech: SpeechSettingsPage(bindings: bindings)
        case .cleanup:
            CleanupSettingsPage(bindings: bindings, openDictionary: { self.selection = .dictionary })
        case .dictionary: DictionarySettingsPage(bindings: bindings)
        case .apps: AppsSettingsPage(bindings: bindings)
        case .actions: ActionsTabPage(bindings: bindings)
        case .usage: UsageSettingsPage(bindings: bindings)
        }
    }
}

// MARK: - General

/// The hotkey and how it activates — the one tab whose controls are fully live today.
private struct GeneralSettingsPage: View {

    let bindings: SettingsBindings
    @State private var isToggle = true
    @State private var keepInTray = false
    @State private var isContextReading = false

    var body: some View {
        Form {
            Section("Hotkey") {
                // Two rows, one per mode (`dual-mode` D6): dictation first — the older surface,
                // the known row — converse second. Each instance holds its own recorder state,
                // so a recording in one row never arms the other.
                HotkeyRecorderView(bindings: bindings, mode: .dictation)
                HotkeyRecorderView(bindings: bindings, mode: .conversing)
                // Both limits, because the check has two separate holes and one sentence covering
                // them would leave a reader believing the untouched half is checked.
                Text(SettingsCopy.hotkeyOtherAppsUnknown)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(SettingsCopy.hotkeySystemShortcutsIncomplete)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Activation") {
                Picker("", selection: $isToggle) {
                    modeRow(
                        title: SettingsCopy.toggleTitle,
                        detail: SettingsCopy.toggleDetail).tag(true)
                    modeRow(
                        title: SettingsCopy.holdTitle,
                        detail: SettingsCopy.holdDetail).tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: isToggle) { _, next in bindings.setToggleMode(next) }
            }

            Section("Closing") {
                Toggle(SettingsCopy.keepInTrayTitle, isOn: $keepInTray)
                    .onChange(of: keepInTray) { _, next in bindings.setKeepInTray(next) }
                Text(SettingsCopy.keepInTrayDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(SettingsCopy.contextSectionTitle) {
                Toggle(SettingsCopy.contextReadingTitle, isOn: $isContextReading)
                    .onChange(of: isContextReading) { _, next in bindings.setContextReading(next) }
                Text(SettingsCopy.contextReadingDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            isToggle = bindings.isToggleMode()
            keepInTray = bindings.isKeepInTray()
            isContextReading = bindings.isContextReading()
        }
    }

    private func modeRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Dictionary

/// The user's replacements — the second tab whose edits are real: the store this reads has both a
/// `load` and a `save`, so this list writes through to the same file the cleanup rules read.
private struct DictionarySettingsPage: View {

    let bindings: SettingsBindings
    /// The rules with a stable identity for the table. `ReplacementRule` is a value with no id of
    /// its own — correct for a rule, useless for a row — so identity is minted here and lives only
    /// as long as the window.
    private struct Row: Identifiable {
        let id = UUID()
        var rule: ReplacementRule
    }

    @State private var rows: [Row] = []
    @State private var selection: Set<UUID> = []
    @State private var isLoaded = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            if rows.isEmpty && isLoaded {
                Spacer()
                Text(SettingsCopy.dictionaryEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            } else {
                Table(rows, selection: $selection) {
                    TableColumn("Vocca hears", value: \.rule.source)
                    TableColumn("Types instead", value: \.rule.replacement)
                }
            }

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }

            HStack(spacing: 8) {
                Button {
                    rows.append(
                        Row(rule: ReplacementRule(
                            source: "new phrase", replacement: "replacement",
                            caseSensitive: false, wordBoundary: true)))
                    persist()
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    rows.removeAll { selection.contains($0.id) }
                    selection.removeAll()
                    persist()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection.isEmpty)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .task {
            rows = await bindings.loadDictionary().map(Row.init(rule:))
            isLoaded = true
        }
    }

    /// Writes the list back, and surfaces a failure rather than swallowing it — a dictionary that
    /// silently fails to save is one the user rebuilds from scratch next launch.
    private func persist() {
        let snapshot = rows.map(\.rule)
        Task {
            do {
                try await bindings.saveDictionary(snapshot)
                saveError = nil
            } catch {
                saveError = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }
}
