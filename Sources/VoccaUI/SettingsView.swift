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
    /// The hotkey, in the form a person reads.
    public var hotkeyDisplayName: String
    /// The engine currently transcribing, for the Speech tab.
    public var engineDisplayName: () -> String
    /// The cleanup provider's name and whether it sends text off the machine.
    public var cleanupSummary: () -> (name: String, endpoint: String?)
    /// Loads the user's replacements.
    public var loadDictionary: () async -> [ReplacementRule]
    /// Saves the user's replacements.
    public var saveDictionary: ([ReplacementRule]) async throws -> Void

    public init(
        isToggleMode: @escaping () -> Bool,
        setToggleMode: @escaping (Bool) -> Void,
        hotkeyDisplayName: String,
        engineDisplayName: @escaping () -> String,
        cleanupSummary: @escaping () -> (name: String, endpoint: String?),
        loadDictionary: @escaping () async -> [ReplacementRule],
        saveDictionary: @escaping ([ReplacementRule]) async throws -> Void
    ) {
        self.isToggleMode = isToggleMode
        self.setToggleMode = setToggleMode
        self.hotkeyDisplayName = hotkeyDisplayName
        self.engineDisplayName = engineDisplayName
        self.cleanupSummary = cleanupSummary
        self.loadDictionary = loadDictionary
        self.saveDictionary = saveDictionary
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
        case .cleanup: CleanupSettingsPage(bindings: bindings)
        case .dictionary: DictionarySettingsPage(bindings: bindings)
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
                LabeledContent("Dictation shortcut") {
                    Text(bindings.hotkeyDisplayName)
                        .font(.system(.body, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                }
                Text(SettingsCopy.hotkeyNotRebindable)
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

// MARK: - Speech

/// Which engine is transcribing. Read-only: switching engines is the picker's own surface and is
/// not wired into this window yet, so this reports rather than pretends.
private struct SpeechSettingsPage: View {

    let bindings: SettingsBindings

    var body: some View {
        Form {
            Section("Engine") {
                LabeledContent("Transcribing with", value: bindings.engineDisplayName())
                Text("Everything is transcribed on this Mac. Audio never leaves it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Cleanup

/// What polishes the text, and whether that leaves the machine.
///
/// The egress line is the point of this tab. The badge on the pill tells a user that text is
/// leaving *while it happens*; this is where they can check before it ever does.
private struct CleanupSettingsPage: View {

    let bindings: SettingsBindings

    var body: some View {
        let summary = bindings.cleanupSummary()
        return Form {
            Section("Cleanup") {
                LabeledContent("Using", value: summary.name)
                if let endpoint = summary.endpoint {
                    Label {
                        Text("Text is sent to \(endpoint).")
                    } icon: {
                        Image(systemName: "cloud")
                    }
                    .foregroundStyle(VoccaTheme.egress)
                    .font(.caption)
                } else {
                    Label("Runs on this Mac. Nothing is sent anywhere.", systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(SettingsCopy.cleanupNotEditable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
