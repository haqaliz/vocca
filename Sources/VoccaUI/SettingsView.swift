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
    /// The hotkey, in the form a person reads — **read, never captured**.
    ///
    /// A `String` here was a defect waiting for the recorder: the window is built once and kept
    /// for the process's lifetime, so a chord captured at construction would go on naming the old
    /// binding until the next launch — including on the very page the user had just changed it on.
    /// The `engineSelection` argument, applied to the fact this tab exists to show.
    public var hotkeyDisplayName: () -> String
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

    public init(
        isToggleMode: @escaping () -> Bool,
        setToggleMode: @escaping (Bool) -> Void,
        hotkeyDisplayName: @escaping () -> String,
        engineDisplayName: @escaping () -> String,
        cleanupSummary: @escaping () async -> CleanupSummary?,
        // The cleanup defaults claim **nothing** and change **nothing**, for the reason the Speech
        // defaults do: a default that pretended to work would let a page report a provider and
        // save a choice that nothing is behind. Unacknowledged is the safe direction too — the
        // worst case is a dialog shown once more.
        loadCleanupConfig: @escaping () async -> CleanupConfigDraft = { .empty },
        saveCleanupConfig: @escaping (CleanupConfigDraft) async throws -> Void = { _ in },
        isCloudCleanupAcknowledged: @escaping () -> Bool = { false },
        setCloudCleanupAcknowledged: @escaping (Bool) -> Void = { _ in },
        loadDictionary: @escaping () async -> [ReplacementRule],
        saveDictionary: @escaping ([ReplacementRule]) async throws -> Void,
        loadStrategies: @escaping () async -> [AppStrategyEntry] = { [] },
        saveStrategies: @escaping ([AppStrategyEntry]) async throws -> Void = { _ in },
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
        downloadActivityChanged: @escaping (EngineTier, Bool) -> Void = { _, _ in }
    ) {
        self.isToggleMode = isToggleMode
        self.setToggleMode = setToggleMode
        self.hotkeyDisplayName = hotkeyDisplayName
        self.engineDisplayName = engineDisplayName
        self.cleanupSummary = cleanupSummary
        self.loadCleanupConfig = loadCleanupConfig
        self.saveCleanupConfig = saveCleanupConfig
        self.isCloudCleanupAcknowledged = isCloudCleanupAcknowledged
        self.setCloudCleanupAcknowledged = setCloudCleanupAcknowledged
        self.loadDictionary = loadDictionary
        self.saveDictionary = saveDictionary
        self.loadStrategies = loadStrategies
        self.saveStrategies = saveStrategies
        self.engineSelection = engineSelection
        self.setEngineSelection = setEngineSelection
        self.engineReadiness = engineReadiness
        self.modelSnapshot = modelSnapshot
        self.makeDownloadSession = makeDownloadSession
        self.removeModel = removeModel
        self.isSessionInFlight = isSessionInFlight
        self.downloadActivityChanged = downloadActivityChanged
    }
}

/// The settings window's content: a macOS preferences window, tabs across the top.
public struct SettingsView: View {

    private let bindings: SettingsBindings
    @State private var tab: SettingsTab = .general

    public init(bindings: SettingsBindings) {
        self.bindings = bindings
    }

    public var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases) { tab in
                page(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbolName) }
                    .tag(tab)
            }
        }
        .frame(width: 520, height: 380)
    }

    @ViewBuilder
    private func page(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsPage(bindings: bindings)
        case .speech: SpeechSettingsPage(bindings: bindings)
        case .cleanup:
            CleanupSettingsPage(bindings: bindings, openDictionary: { self.tab = .dictionary })
        case .dictionary: DictionarySettingsPage(bindings: bindings)
        case .apps: AppsSettingsPage(bindings: bindings)
        }
    }
}

// MARK: - General

/// The hotkey and how it activates — the one tab whose controls are fully live today.
private struct GeneralSettingsPage: View {

    let bindings: SettingsBindings
    @State private var isToggle = true

    var body: some View {
        Form {
            Section("Hotkey") {
                LabeledContent(SettingsCopy.hotkeyLabel) {
                    Text(bindings.hotkeyDisplayName())
                        .font(.system(.body, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                }
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
        }
        .formStyle(.grouped)
        .onAppear { isToggle = bindings.isToggleMode() }
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
