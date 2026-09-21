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

/// What the Actions tab is showing, at any moment: the servers, the persisted enablement, the
/// one discovery in flight, the arm state the wiring's card reads, and the preview row.
///
/// Everything a person can change on the page is here — including the add/edit drafts and the
/// identity of the server being edited — so the whole surface is reducer-testable with no store
/// and no window server, the `AppsTabState` pattern.
public struct ActionsTabState: Sendable, Equatable {
    /// The configured servers, in the order they were added.
    public var servers: [ActionsServerRow]
    /// The persisted enablement, keyed by the whole tool pair — **absent is off** (PRD M7).
    public var enablement: Set<ActionsToolKey>
    /// The rows the tools section renders: the last successful discovery's tools, with
    /// `isEnabled` folded from ``enablement``.
    public var toolRows: [ActionsToolRow]
    /// The discovery's one closed three-step, per server.
    public var discovery: ActionsDiscoveryState
    /// The arm state — `awaitingConfirmation` is the wiring's card signal; nothing else on this
    /// page may ever stand in for a human saying yes.
    public var arm: ActionsArmState
    /// The preview row — the provider's own sentence, rendered without acting.
    public var preview: ActionsPreviewState
    /// The add form's name field, shared by the server editor.
    public var serverNameDraft: String
    /// The add form's path field, shared by the server editor.
    public var serverPathDraft: String
    /// The server being edited, when the editor is open. `nil` otherwise.
    public var editingServerID: String?
    /// Whether the config has landed. `false` with no servers is "we haven't looked yet"; `true`
    /// with no servers is the empty state.
    public var isLoaded: Bool
    /// The last write failure, in the wiring's own words. `nil` once a write succeeds.
    public var saveError: String?

    /// The state the window opens in.
    public static let initial = ActionsTabState(
        servers: [], enablement: [], toolRows: [], discovery: .idle, arm: .idle, preview: .idle,
        serverNameDraft: "", serverPathDraft: "", editingServerID: nil, isLoaded: false,
        saveError: nil)

    public init(
        servers: [ActionsServerRow], enablement: Set<ActionsToolKey>,
        toolRows: [ActionsToolRow], discovery: ActionsDiscoveryState, arm: ActionsArmState,
        preview: ActionsPreviewState, serverNameDraft: String, serverPathDraft: String,
        editingServerID: String?, isLoaded: Bool, saveError: String?
    ) {
        self.servers = servers
        self.enablement = enablement
        self.toolRows = toolRows
        self.discovery = discovery
        self.arm = arm
        self.preview = preview
        self.serverNameDraft = serverNameDraft
        self.serverPathDraft = serverPathDraft
        self.editingServerID = editingServerID
        self.isLoaded = isLoaded
        self.saveError = saveError
    }
}

/// The discovery's closed set — the page renders exactly one of these.
public enum ActionsDiscoveryState: Sendable, Equatable {
    /// Nobody has asked. The tools section shows the discover control and nothing else.
    case idle
    /// A discovery is in flight for this server — the spawn has been requested.
    case discovering(serverID: String)
    /// This server listed these tools.
    case succeeded(serverID: String, tools: [ActionsToolRow])
    /// Discovery failed for this server, with the bounded key the wiring reported.
    case failed(serverID: String, key: String)
}

/// The arm path's closed set. The tab never calls the gate — it lands here, and the wiring's
/// confirmation card is the only way out.
public enum ActionsArmState: Sendable, Equatable {
    /// Nothing is armed.
    case idle
    /// An enabled tool is one confirmation away — the state the wiring observes to show the card.
    case awaitingConfirmation(providerID: String, toolID: String)
}

/// The preview row's closed set.
public enum ActionsPreviewState: Sendable, Equatable {
    /// Nothing is previewed.
    case idle
    /// The provider's own sentence for this tool, rendered without acting.
    case showing(providerID: String, toolID: String, sentence: String)
}

/// Everything that can happen to the Actions tab. A closed set, folded exhaustively, with no
/// time-based transition in it — the settings-window discipline: nothing here should change
/// while a user is reading it.
public enum ActionsTabAction: Sendable, Equatable {
    /// The config was read; these are its servers and its persisted enablement.
    case configLoaded(servers: [ActionsServerRow], enablement: Set<ActionsToolKey>)
    /// The add form's name field changed.
    case serverNameFieldEdited(String)
    /// The add form's path field changed.
    case serverPathFieldEdited(String)
    /// The user opened a server in the editor.
    case serverEditStarted(id: String)
    /// The user closed the editor without saving.
    case serverEditCancelled
    /// The user committed the add form.
    case serverAdded
    /// The user committed the editor.
    case serverEdited
    /// The user removed a server — its tool rows and enablement rows go with it.
    case serverRemoved(id: String)
    /// The user pressed "Discover tools" — the explicit, user-initiated spawn.
    case discoveryStarted(serverID: String)
    /// The server answered with its tool list.
    case discoverySucceeded(serverID: String, tools: [ActionsToolRow])
    /// The server could not be discovered, with the wiring's bounded reason.
    case discoveryFailed(serverID: String, key: String)
    /// The user flipped one tool's enablement row.
    case toolEnabledChanged(providerID: String, toolID: String, enabled: Bool)
    /// The user pressed Invoke on an enabled tool.
    case armRequested(providerID: String, toolID: String)
    /// The confirmation card went away without running the action.
    case armDismissed
    /// The provider's sentence for a tool landed.
    case previewShown(providerID: String, toolID: String, sentence: String)
    /// The preview row went away.
    case previewCleared
    /// The write-through landed.
    case saveSucceeded
    /// The write-through failed, with the wiring's message.
    case saveFailed(String)
}

/// The Actions tab's decisions — pure, clock-free, and holding no memory logic of its own.
public enum ActionsTabReducer {

    public static func reduce(
        _ state: ActionsTabState, _ action: ActionsTabAction
    ) -> ActionsTabState {
        var next = state
        switch action {
        case .configLoaded(let servers, let enablement):
            next.servers = servers
            next.enablement = enablement
            next.isLoaded = true
            next.saveError = nil

        case .serverNameFieldEdited(let name):
            next.serverNameDraft = name

        case .serverPathFieldEdited(let path):
            next.serverPathDraft = path

        case .serverEditStarted(let id):
            guard let server = next.servers.first(where: { $0.id == id }) else { return state }
            next.editingServerID = id
            next.serverNameDraft = server.name
            next.serverPathDraft = server.path

        case .serverEditCancelled:
            next.editingServerID = nil
            next.serverNameDraft = ""
            next.serverPathDraft = ""

        case .serverAdded:
            // A nameless server or a pathless one is not a server — the store refuses an empty
            // executable path, and the reducer refuses the add before the file ever sees it.
            guard !next.serverNameDraft.isEmpty, !next.serverPathDraft.isEmpty else {
                return state
            }
            // The id is minted once, here, and never again: it is what the config file and
            // every later reader identify the server by, so an edit must never look like a
            // delete plus a new server (`MCPServerConfiguration`).
            let server = ActionsServerRow(
                id: UUID().uuidString, name: next.serverNameDraft, path: next.serverPathDraft)
            next.servers.append(server)
            next.serverNameDraft = ""
            next.serverPathDraft = ""
            next.saveError = nil

        case .serverEdited:
            guard let editingID = next.editingServerID,
                let index = next.servers.firstIndex(where: { $0.id == editingID }),
                !next.serverNameDraft.isEmpty, !next.serverPathDraft.isEmpty
            else { return state }
            next.servers[index].name = next.serverNameDraft
            next.servers[index].path = next.serverPathDraft
            next.editingServerID = nil
            next.serverNameDraft = ""
            next.serverPathDraft = ""
            next.saveError = nil

        case .serverRemoved(let id):
            guard next.servers.contains(where: { $0.id == id }) else { return state }
            next.servers.removeAll { $0.id == id }
            // The server's tools and enablement go with it — on the state's side and on the
            // draft's side alike, so the next save cannot re-add a ghost server's enablement
            // (the store's stale-row tolerance would otherwise keep them forever). A server's
            // tools are keyed by the server's id as providerID — the wiring's mapping.
            next.toolRows.removeAll { $0.providerID == id }
            next.enablement = next.enablement.filter { $0.providerID != id }
            if next.discovery.serverID == id {
                next.discovery = .idle
            }
            next.saveError = nil

        case .discoveryStarted(let serverID):
            next.discovery = .discovering(serverID: serverID)
            // A new discovery invalidates the previous rows — a failed or restarted discovery
            // must not keep offering a tool list nobody confirmed.
            next.toolRows = []

        case .discoverySucceeded(let serverID, let tools):
            // Default off is the reducer's rule, not the wiring's: a row that arrives enabled
            // is off unless the persisted enablement holds its key (M7). The wiring may hand
            // the list; the tab decides what may act.
            next.discovery = .succeeded(serverID: serverID, tools: tools)
            next.toolRows = tools.map { row in
                var resolved = row
                resolved.isEnabled = next.enablement.contains(
                    ActionsToolKey(providerID: row.providerID, toolID: row.toolID))
                return resolved
            }

        case .discoveryFailed(let serverID, let key):
            next.discovery = .failed(serverID: serverID, key: key)
            next.toolRows = []

        case .toolEnabledChanged(let providerID, let toolID, let enabled):
            // One tool at a time, and only a tool that exists: absent is off, so a flip for a
            // row nobody discovered mints nothing and enables nothing.
            guard let index = next.toolRows.firstIndex(where: {
                $0.providerID == providerID && $0.toolID == toolID
            }) else { return state }
            next.toolRows[index].isEnabled = enabled
            let key = ActionsToolKey(providerID: providerID, toolID: toolID)
            if enabled {
                next.enablement.insert(key)
            } else {
                next.enablement.remove(key)
            }
            next.saveError = nil

        case .armRequested(let providerID, let toolID):
            // The M7 never-read rule at the surface: arming a disabled tool is refused by the
            // reducer — the state does not change, so no confirmation signal can be emitted
            // from it. Only an enabled row, and only from an idle arm, may land on the card.
            guard next.arm == .idle,
                let row = next.toolRows.first(where: {
                    $0.providerID == providerID && $0.toolID == toolID
                }),
                row.isEnabled
            else { return state }
            next.arm = .awaitingConfirmation(providerID: providerID, toolID: toolID)

        case .armDismissed:
            next.arm = .idle

        case .previewShown(let providerID, let toolID, let sentence):
            next.preview = .showing(
                providerID: providerID, toolID: toolID, sentence: sentence)

        case .previewCleared:
            next.preview = .idle

        case .saveSucceeded:
            next.saveError = nil

        case .saveFailed(let message):
            next.saveError = message
        }
        return next
    }
}

extension ActionsDiscoveryState {
    /// The server this discovery is about, when there is one.
    fileprivate var serverID: String? {
        switch self {
        case .idle: return nil
        case .discovering(let serverID): return serverID
        case .succeeded(let serverID, _): return serverID
        case .failed(let serverID, _): return serverID
        }
    }
}