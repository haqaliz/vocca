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

/// **The Actions tab** — where servers are configured, their tools discovered by an explicit
/// user action, enabled one at a time (**off by default**, M7), and armed into the
/// confirmation state the wiring's card reads.
///
/// Thin glue over ``ActionsTabReducer`` — the ``AppsSettingsPage`` split. Every gesture folds
/// an action; writes fold the whole draft through the same binding, so what the table shows
/// and what `action-config.json` holds cannot drift; the write's outcome folds back as
/// `saveSucceeded`/`saveFailed`.
///
/// **The arm path's whole is the card signal.** The page folds `.armRequested` and calls
/// ``SettingsBindings/confirmationPresented()`` only when the folded state is
/// `awaitingConfirmation` — a refused arm (a disabled tool) changes nothing and therefore
/// signals nothing. The tab never calls the gate; that is the wiring's half, behind the card.
///
/// Executed by nothing in CI (the window-server rule). Every decision is tested in
/// `ActionsTabTests` and every word in the same file's copy pins.
struct ActionsTabPage: View {

    let bindings: SettingsBindings

    @State private var state = ActionsTabState.initial

    var body: some View {
        Form {
            Section(ActionsTabCopy.serversSectionTitle) {
                if state.isLoaded && state.servers.isEmpty {
                    Text(ActionsTabCopy.emptyServers)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(state.servers) { server in
                    if state.editingServerID == server.id {
                        serverEditor(server)
                    } else {
                        serverRow(server)
                    }
                }
                if state.editingServerID == nil {
                    addServerForm()
                }
            }

            Section(ActionsTabCopy.toolsSectionTitle) {
                // The D2 copy at the moment of spawn: this section's buttons start a child
                // program, and the narrowed promise — that configuring a server is trust
                // extended to its author — belongs where the spawn is initiated, not elsewhere
                // on the page where it could be read after the fact.
                Text(ActionsTabCopy.d2TrustCopy)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(state.servers) { server in
                    HStack {
                        Text(server.name)
                        Spacer()
                        Button(ActionsTabCopy.discoverButton) { discover(serverID: server.id) }
                    }
                }

                discoveryContent()

                if case .awaitingConfirmation = state.arm {
                    Text(ActionsTabCopy.awaitingConfirmation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let saveError = state.saveError {
                Section {
                    Text(ActionsTabCopy.saveError(saveError))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    // MARK: - The servers section

    /// One configured server: its name and path, and the two row actions.
    private func serverRow(_ server: ActionsServerRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                Text(server.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(ActionsTabCopy.editServerButton) {
                state = ActionsTabReducer.reduce(state, .serverEditStarted(id: server.id))
            }
            Button(ActionsTabCopy.removeServerButton) {
                remove(server)
            }
        }
    }

    /// The open editor — the row's own fields, with the two ways out.
    private func serverEditor(_ server: ActionsServerRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                ActionsTabCopy.nameFieldLabel,
                text: Binding(
                    get: { state.serverNameDraft },
                    set: { state = ActionsTabReducer.reduce(state, .serverNameFieldEdited($0)) }))
            TextField(
                ActionsTabCopy.pathFieldLabel,
                text: Binding(
                    get: { state.serverPathDraft },
                    set: { state = ActionsTabReducer.reduce(state, .serverPathFieldEdited($0)) }))
            HStack {
                Button(ActionsTabCopy.saveServerButton) {
                    state = ActionsTabReducer.reduce(state, .serverEdited)
                    persist()
                }
                .disabled(state.serverNameDraft.isEmpty || state.serverPathDraft.isEmpty)
                Button(ActionsTabCopy.cancelButton) {
                    state = ActionsTabReducer.reduce(state, .serverEditCancelled)
                }
            }
        }
    }

    /// The add form — the same two fields the editor uses, and the commit button.
    private func addServerForm() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                ActionsTabCopy.nameFieldLabel,
                text: Binding(
                    get: { state.serverNameDraft },
                    set: { state = ActionsTabReducer.reduce(state, .serverNameFieldEdited($0)) }))
            TextField(
                ActionsTabCopy.pathFieldLabel,
                text: Binding(
                    get: { state.serverPathDraft },
                    set: { state = ActionsTabReducer.reduce(state, .serverPathFieldEdited($0)) }))
            Button(ActionsTabCopy.addServerButton) {
                state = ActionsTabReducer.reduce(state, .serverAdded)
                persist()
            }
            .disabled(state.serverNameDraft.isEmpty || state.serverPathDraft.isEmpty)
        }
    }

    // MARK: - The tools section

    /// The discovery's rendering: what is in flight, what came back, and what went wrong.
    @ViewBuilder
    private func discoveryContent() -> some View {
        switch state.discovery {
        case .idle:
            EmptyView()
        case .discovering:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(ActionsTabCopy.discoveringLabel)
                    .font(.callout)
            }
        case .succeeded(_, let tools):
            if tools.isEmpty {
                Text(ActionsTabCopy.noToolsFound)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tools) { row in
                    toolRow(row)
                }
                Text(ActionsTabCopy.defaultOffDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let serverID, let key):
            Text(ActionsTabCopy.discoveryFailed(key))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(ActionsTabCopy.tryAgainButton) { discover(serverID: serverID) }
        }
    }

    /// One discovered tool: the provider/tool identifiers and the claimed radius, the enablement
    /// toggle (**off by default**), and — for an enabled tool only — the Invoke and Preview rows.
    private func toolRow(_ row: ActionsToolRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { row.isEnabled },
                        set: { enabled in
                            setEnabled(row, enabled)
                        })
                )
                .labelsHidden()
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(row.providerID) / \(row.toolID)")
                        .font(.callout)
                    Text(ActionsTabCopy.radiusLabel(row.radius))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if row.isEnabled {
                HStack {
                    Button(ActionsTabCopy.previewButton) { preview(row) }
                    Button(ActionsTabCopy.invokeButton) { arm(row) }
                }
                .controlSize(.small)
            }
            if case .showing(_, _, let sentence) = state.preview {
                Text(ActionsTabCopy.previewSentence(sentence))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - The gestures

    /// The explicit, user-initiated spawn: fold `discovering`, ask the wiring, fold the answer.
    private func discover(serverID: String) {
        state = ActionsTabReducer.reduce(state, .discoveryStarted(serverID: serverID))
        Task {
            switch await bindings.discoverTools(serverID) {
            case .succeeded(let tools):
                state = ActionsTabReducer.reduce(
                    state, .discoverySucceeded(serverID: serverID, tools: tools))
            case .failed(let key):
                state = ActionsTabReducer.reduce(
                    state, .discoveryFailed(serverID: serverID, key: key))
            }
        }
    }

    /// The dry-run half of the seam: ask the wiring for the provider's sentence, fold it as the
    /// preview row — or clear the row when nothing can be said. No acting half is ever reached
    /// from here; that is the gate's, behind the confirmation card.
    private func preview(_ row: ActionsToolRow) {
        Task {
            if let sentence = await bindings.previewAction(row.providerID, row.toolID) {
                state = ActionsTabReducer.reduce(
                    state,
                    .previewShown(
                        providerID: row.providerID, toolID: row.toolID, sentence: sentence))
            } else {
                state = ActionsTabReducer.reduce(state, .previewCleared)
            }
        }
    }

    /// The arm path's whole: fold `.armRequested`, and emit the card signal **only** when the
    /// folded state is `awaitingConfirmation`. A refused arm — a disabled or absent tool —
    /// leaves the state untouched, so no signal can be emitted from it (the M7 never-read rule
    /// at the surface). The gate itself is never called here.
    private func arm(_ row: ActionsToolRow) {
        let next = ActionsTabReducer.reduce(
            state, .armRequested(providerID: row.providerID, toolID: row.toolID))
        state = next
        if case .awaitingConfirmation = next.arm {
            bindings.confirmationPresented()
        }
    }

    /// Folds the toggle's flip and writes the folded truth through — the row and the persisted
    /// set move together, so what the table shows and what the file holds cannot drift.
    private func setEnabled(_ row: ActionsToolRow, _ enabled: Bool) {
        state = ActionsTabReducer.reduce(
            state,
            .toolEnabledChanged(providerID: row.providerID, toolID: row.toolID, enabled: enabled))
        persist()
    }

    /// Removes the server; its tool rows and enablement rows go with it, on both halves.
    private func remove(_ server: ActionsServerRow) {
        state = ActionsTabReducer.reduce(state, .serverRemoved(id: server.id))
        persist()
    }

    /// Writes the whole draft through — the `AppsSettingsPage` rule: a write the user asked for
    /// that did not reach the file must say so.
    private func persist() {
        let draft = ActionsConfigDraft(servers: state.servers, enablement: state.enablement)
        Task {
            do {
                try await bindings.saveActionsConfig(draft)
                state = ActionsTabReducer.reduce(state, .saveSucceeded)
            } catch {
                state = ActionsTabReducer.reduce(
                    state, .saveFailed(error.localizedDescription))
            }
        }
    }

    /// The config as the file holds it — the servers and the persisted enablement, folded once
    /// per opening.
    private func load() async {
        let config = await bindings.loadActionsConfig()
        state = ActionsTabReducer.reduce(
            state, .configLoaded(servers: config.servers, enablement: config.enablement))
    }
}