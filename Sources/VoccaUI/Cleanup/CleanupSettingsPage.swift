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

/// **The Cleanup tab** (`PRODUCT_SPEC.md:263-274`): what polishes the text, whether that leaves
/// the machine, and the one-time dialog in front of the rung that does.
///
/// Thin glue over ``CleanupTabReducer`` — the ``AppsSettingsPage``/``SpeechSettingsPage`` split.
/// Every gesture asks the reducer for a plan and folds the outcome back; nothing here decides.
///
/// The "Using" line is the point of this tab. The badge on the pill tells a user that text is
/// leaving *while it happens*; this is where they can check before it ever does — and it reports
/// the **resolved** provider, so a hand-edited block that degraded says the truth rather than what
/// the file asked for.
///
/// Executed by nothing in CI (the window-server rule). Every decision it renders is tested in
/// `CleanupTabReducerTests` and `CleanupCloudConfirmationTests`, and every word in
/// `CleanupTabCopyTests`.
struct CleanupSettingsPage: View {

    let bindings: SettingsBindings

    /// Switches the window to the Dictionary tab — the spec's `[ Custom dictionary… ]` affordance
    /// (`PRODUCT_SPEC.md:270`). A jump rather than a second editor: the dictionary already has a
    /// tab, and two surfaces onto one file is how they disagree.
    let openDictionary: () -> Void

    @State private var state = CleanupTabState.initial
    @State private var contextGrant = false

    var body: some View {
        Form {
            Section(SettingsTab.cleanup.title) {
                ForEach(state.rows) { row in
                    rungRow(row, mode: .dictation)
                }
            }

            Section {
                if let summary = state.summary {
                    LabeledContent(CleanupTabCopy.usingLabel, value: summary.name)
                    if summary.sendsTextOffTheMac {
                        Label {
                            Text(
                                summary.endpoint.map(CleanupTabCopy.textIsSentTo)
                                    ?? CleanupTabCopy.textLeavesThisMac)
                        } icon: {
                            Image(systemName: "cloud")
                        }
                        .foregroundStyle(VoccaTheme.egress)
                        .font(.caption)
                    } else {
                        Label(CleanupTabCopy.runsOnThisMac, systemImage: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(CleanupTabCopy.appliesAtNextLaunch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = state.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            // The context grant, surfaced beside the egress summary (`prd.md:102-107`): what a
            // cloud cleanup may carry is decided on the surface that already says what leaves —
            // the "Closing" toggle's shape (`SettingsView.swift`), off by default.
            Section {
                Toggle(CleanupTabCopy.contextGrantTitle, isOn: $contextGrant)
                    .onChange(of: contextGrant) { _, next in bindings.setContextGrantEnabled(next) }
                Text(CleanupTabCopy.contextGrantDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(CleanupTabCopy.converseSectionTitle) {
                Text(CleanupTabCopy.converseSectionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(state.converseRows) { row in
                    rungRow(row, mode: .conversing)
                }
                if let summary = state.converseSummary {
                    LabeledContent(CleanupTabCopy.usingLabel, value: summary.name)
                    if summary.sendsTextOffTheMac {
                        Label {
                            Text(
                                summary.endpoint.map(CleanupTabCopy.textIsSentTo)
                                    ?? CleanupTabCopy.textLeavesThisMac)
                        } icon: {
                            Image(systemName: "cloud")
                        }
                        .foregroundStyle(VoccaTheme.egress)
                        .font(.caption)
                    } else {
                        Label(CleanupTabCopy.runsOnThisMac, systemImage: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button(CleanupTabCopy.customDictionaryButton, action: openDictionary)
                    Text(CleanupTabCopy.customDictionaryHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .task {
            state = CleanupTabReducer.reduce(
                state, .acknowledgementLoaded(bindings.isCloudCleanupAcknowledged()))
            state = CleanupTabReducer.reduce(
                state, .configLoaded(await bindings.loadCleanupConfig()))
            state = CleanupTabReducer.reduce(
                state, .summaryLoaded(await bindings.cleanupSummary()))
            state = CleanupTabReducer.reduce(
                state, .converseSummaryLoaded(await bindings.cleanupConversingSummary()))
        }
        .onAppear {
            contextGrant = bindings.isContextGrantEnabled()
        }
        .confirmationDialog(
            CleanupTabCopy.cloudConfirmationTitle,
            isPresented: Binding(
                get: { state.pendingConfirmation != nil },
                // A dismissal that did not come through a button — Escape, or a click outside — is
                // a decline. The safe direction: never an acknowledgement, and never a write.
                set: { isPresented in
                    if !isPresented { state = CleanupTabReducer.reduce(state, .confirmationDeclined) }
                }),
            titleVisibility: .visible
        ) {
            Button(CleanupTabCopy.cloudConfirmAccept) { accept() }
            Button(CleanupTabCopy.cloudConfirmDecline, role: .cancel) {
                state = CleanupTabReducer.reduce(state, .confirmationDeclined)
            }
        } message: {
            Text(CleanupTabCopy.cloudConfirmationBody(endpoint: state.draft.byokEndpoint))
        }
    }

    /// One rung: the radio, the spec's two sentences, and the fields the rung needs to be
    /// choosable at all. The mode names which picker the row belongs to.
    @ViewBuilder
    private func rungRow(_ row: CleanupTabRow, mode: SessionMode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                pick(row.kind, mode: mode)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(
                        row.isSelected
                            ? CleanupTabCopy.radioSelected : CleanupTabCopy.radioUnselected)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(CleanupTabCopy.rungName(row.kind))
                        Text(CleanupTabCopy.rungDetail(row.kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(CleanupTabCopy.rungEgressNote(row.kind))
                        .font(.caption)
                        .foregroundStyle(
                            row.kind.sendsTextOffTheMac ? VoccaTheme.egress : .secondary)
                }
            }
            .buttonStyle(.plain)

            fields(for: row.kind)
        }
    }

    /// The endpoint and model a rung needs. Shown for the LLM rungs whether or not they are
    /// selected: a rung a user cannot configure without first selecting it is a rung they cannot
    /// select, and the refusal would be all they ever saw.
    @ViewBuilder
    private func fields(for kind: CleanupProviderKind) -> some View {
        switch kind {
        case .rules:
            EmptyView()
        case .ollama:
            VStack(alignment: .leading, spacing: 2) {
                TextField(
                    CleanupTabCopy.endpointLabel,
                    text: binding(for: kind, endpoint: true))
                TextField(CleanupTabCopy.modelLabel, text: binding(for: kind, endpoint: false))
            }
            .textFieldStyle(.roundedBorder)
            .padding(.leading, 22)
        case .byok:
            VStack(alignment: .leading, spacing: 2) {
                TextField(
                    CleanupTabCopy.endpointLabel,
                    text: binding(for: kind, endpoint: true))
                TextField(CleanupTabCopy.modelLabel, text: binding(for: kind, endpoint: false))
                Text(CleanupTabCopy.modelOptionalNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(CleanupTabCopy.keychainNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.leading, 22)
        }
    }

    /// A field's binding — reads the draft, folds an edit. Never writes: typing an endpoint is not
    /// choosing the rung, and a file rewritten on every keystroke would carry half-typed hosts.
    private func binding(for kind: CleanupProviderKind, endpoint: Bool) -> Binding<String> {
        Binding(
            get: {
                switch (kind, endpoint) {
                case (.ollama, true): return state.draft.ollamaEndpoint
                case (.ollama, false): return state.draft.ollamaModel
                case (.byok, true): return state.draft.byokEndpoint
                case (.byok, false): return state.draft.byokModel
                case (.rules, _): return ""
                }
            },
            set: { value in
                state = CleanupTabReducer.reduce(
                    state, endpoint ? .endpointEdited(kind, value) : .modelEdited(kind, value))
            })
    }

    /// Picking a rung for a picker: ask the reducer, then do exactly what it said.
    private func pick(_ kind: CleanupProviderKind, mode: SessionMode) {
        switch CleanupTabReducer.plan(state, picking: kind, mode: mode) {
        case .refuse(let message):
            state = CleanupTabReducer.reduce(state, .selectionRefused(message))
        case .confirm(let kind):
            state = CleanupTabReducer.reduce(state, .confirmationRequested(kind, for: mode))
        case .write(let draft):
            persist(draft, mode: mode)
        }
    }

    /// The dialog's accepting button: acknowledge, remember it across launches, then ask again for
    /// the plan — which is now a write, because the acknowledgement is what was missing. Re-plans
    /// the same picker the dialog was asked for, so the write moves the right half of the draft.
    private func accept() {
        guard let pending = state.pendingConfirmation else { return }
        state = CleanupTabReducer.reduce(state, .confirmationAccepted)
        bindings.setCloudCleanupAcknowledged(true)
        pick(pending.kind, mode: pending.mode)
    }

    /// Writes the draft and folds the outcome into the picker that asked. A failure is surfaced,
    /// never swallowed: a cleanup choice that silently fails to save is one the user makes again
    /// next launch having been told it worked — and on the cloud rung, that is the difference
    /// between believing text stays on the Mac and it not.
    private func persist(_ draft: CleanupConfigDraft, mode: SessionMode) {
        Task {
            do {
                try await bindings.saveCleanupConfig(draft)
                switch mode {
                case .dictation:
                    state = CleanupTabReducer.reduce(state, .saveSucceeded(draft.provider))
                case .conversing:
                    state = CleanupTabReducer.reduce(
                        state, .converseSaveSucceeded(draft.converseProvider))
                }
            } catch {
                state = CleanupTabReducer.reduce(
                    state, .saveFailed(error.localizedDescription))
            }
        }
    }
}
