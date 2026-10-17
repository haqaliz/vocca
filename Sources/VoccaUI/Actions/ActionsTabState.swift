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
    /// The rows the shell section renders (`shell-provider` wiring): the registry's configured
    /// commands, with `isEnabled` folded from ``enablement`` exactly like discovery rows —
    /// default off (M7), absent is off. A registry read, never a discovery and never a spawn.
    public var shellRows: [ActionsToolRow]
    /// Whether the shell registry's commands have landed — `false` with no rows is "we haven't
    /// looked yet"; `true` with no rows is the honest empty state (nothing configured).
    public var isShellLoaded: Bool
    /// The rows the **Audit tools** section renders (`audit-enablement` wiring): the audit
    /// provider's two tools (`audit.count`, `audit.clear`), with `isEnabled` folded from
    /// ``enablement`` exactly like the shell rows — default off (M7), absent is off. A static
    /// list read, never a discovery and never a spawn. The section is **toggle-only** (D-1): the
    /// rows carry no arm/preview affordance.
    public var auditRows: [ActionsToolRow]
    /// Whether the audit tools' rows have landed — `false` with no rows is "we haven't looked
    /// yet"; `true` with no rows is the honest empty state (the provider serves none).
    public var isAuditToolsLoaded: Bool
    /// The rows the Agents section renders (`coding-agent-handoff` wiring): the registry's
    /// configured agents, with `isEnabled` folded from ``enablement`` exactly like discovery
    /// rows — default off (M7), absent is off. A registry read, never a discovery and never a
    /// spawn.
    public var agentRows: [ActionsToolRow]
    /// Whether the agent registry's rows have landed — `false` with no rows is "we haven't
    /// looked yet"; `true` with no rows is the honest empty state (nothing configured).
    public var isAgentLoaded: Bool
    /// The agent registry's full rows — the authoring surface's row source (edit/remove and
    /// the editor's pre-fill read these; the arm surface reads ``agentRows``). The file is
    /// the memory, so these are the table's truth for the next save.
    public var agentDefinitions: [ActionsAgentDefinition]
    /// The known presets the chooser renders, in the catalog's order (`agent-presets`).
    public var agentPresets: [ActionsAgentPreset]
    /// Whether the presets have landed — `false` with no presets is "we haven't looked yet".
    public var isAgentCatalogLoaded: Bool
    /// Each preset's detection fact, keyed by preset id — the chooser's honest
    /// "detected — <path>" / "not detected" rows.
    public var agentDetection: ActionsAgentDetectionResult
    /// The agent editor's id draft.
    public var agentIDDraft: String
    /// The agent editor's executable path draft.
    public var agentExecutablePathDraft: String
    /// The agent editor's arguments draft — the fixed argv, space-separated as the user
    /// types it; the fold splits on whitespace, so the row saved is exactly the words typed.
    public var agentArgumentsDraft: String
    /// The agent editor's project directory draft.
    public var agentProjectDirectoryDraft: String
    /// The agent editor's timeout draft — text, resolved to seconds at save (empty means the
    /// 30-second default, exactly as the definition's own init treats absent).
    public var agentTimeoutDraft: String
    /// The agent editor's environment entries, as key/value pairs.
    public var agentEnvironmentDrafts: [ActionsAgentEnvironmentPairDraft]
    /// The agent editor's clause draft.
    public var agentClauseDraft: String
    /// Whether the agent editor is open — an add (``editingAgentID`` nil) or an edit.
    public var isAgentEditorOpen: Bool
    /// The definition being edited, by its current id. `nil` for an add.
    public var editingAgentID: String?
    /// The last project directory a save committed — the S2 in-memory pre-fill, never
    /// persisted this slice.
    public var lastAgentProjectDirectory: String

    // MARK: - The phrase authoring surface (phrase-authoring)

    /// The phrase rows the Phrases section renders and edits — the draft, in the table's order.
    public var phraseRows: [ActionsPhraseRow]
    /// **The file the section loaded** — the read-before-write guard's snapshot. `nil` until the
    /// load lands; a save compares the committed file against it and refuses on a mismatch.
    public var phraseSnapshot: ActionsPhraseFile?
    /// Whether the phrase table has landed — `false` with no rows is "we haven't looked yet";
    /// `true` with no rows is the honest empty state.
    public var isPhrasesLoaded: Bool
    /// The version the draft carries — read from the file and written back unchanged.
    public var phraseVersion: Int
    /// The `keywordFallback` switch's draft value — read from the file, written back on a save.
    public var keywordFallbackDraft: Bool
    /// The phrase editor's phrase draft.
    public var phrasePhraseDraft: String
    /// The phrase editor's provider draft.
    public var phraseProviderIDDraft: String
    /// The phrase editor's tool draft.
    public var phraseToolIDDraft: String
    /// Whether the phrase editor is open — an add (``editingPhraseID`` nil) or an edit.
    public var isPhraseEditorOpen: Bool
    /// The row being edited, by its current phrase (its identity). `nil` for an add.
    public var editingPhraseID: String?
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
        saveError: nil, shellRows: [], isShellLoaded: false, agentRows: [], isAgentLoaded: false)

    public init(
        servers: [ActionsServerRow], enablement: Set<ActionsToolKey>,
        toolRows: [ActionsToolRow], discovery: ActionsDiscoveryState, arm: ActionsArmState,
        preview: ActionsPreviewState, serverNameDraft: String, serverPathDraft: String,
        editingServerID: String?, isLoaded: Bool, saveError: String?,
        shellRows: [ActionsToolRow] = [], isShellLoaded: Bool = false,
        auditRows: [ActionsToolRow] = [], isAuditToolsLoaded: Bool = false,
        agentRows: [ActionsToolRow] = [], isAgentLoaded: Bool = false,
        agentDefinitions: [ActionsAgentDefinition] = [],
        agentPresets: [ActionsAgentPreset] = [], isAgentCatalogLoaded: Bool = false,
        agentDetection: ActionsAgentDetectionResult = [:],
        agentIDDraft: String = "", agentExecutablePathDraft: String = "",
        agentArgumentsDraft: String = "", agentProjectDirectoryDraft: String = "",
        agentTimeoutDraft: String = "",
        agentEnvironmentDrafts: [ActionsAgentEnvironmentPairDraft] = [],
        agentClauseDraft: String = "", isAgentEditorOpen: Bool = false,
        editingAgentID: String? = nil, lastAgentProjectDirectory: String = "",
        phraseRows: [ActionsPhraseRow] = [], phraseSnapshot: ActionsPhraseFile? = nil,
        isPhrasesLoaded: Bool = false, phraseVersion: Int = 1,
        keywordFallbackDraft: Bool = false, phrasePhraseDraft: String = "",
        phraseProviderIDDraft: String = "", phraseToolIDDraft: String = "",
        isPhraseEditorOpen: Bool = false, editingPhraseID: String? = nil
    ) {
        self.servers = servers
        self.enablement = enablement
        self.toolRows = toolRows
        self.shellRows = shellRows
        self.isShellLoaded = isShellLoaded
        self.auditRows = auditRows
        self.isAuditToolsLoaded = isAuditToolsLoaded
        self.agentRows = agentRows
        self.isAgentLoaded = isAgentLoaded
        self.agentDefinitions = agentDefinitions
        self.agentPresets = agentPresets
        self.isAgentCatalogLoaded = isAgentCatalogLoaded
        self.agentDetection = agentDetection
        self.agentIDDraft = agentIDDraft
        self.agentExecutablePathDraft = agentExecutablePathDraft
        self.agentArgumentsDraft = agentArgumentsDraft
        self.agentProjectDirectoryDraft = agentProjectDirectoryDraft
        self.agentTimeoutDraft = agentTimeoutDraft
        self.agentEnvironmentDrafts = agentEnvironmentDrafts
        self.agentClauseDraft = agentClauseDraft
        self.isAgentEditorOpen = isAgentEditorOpen
        self.editingAgentID = editingAgentID
        self.lastAgentProjectDirectory = lastAgentProjectDirectory
        self.phraseRows = phraseRows
        self.phraseSnapshot = phraseSnapshot
        self.isPhrasesLoaded = isPhrasesLoaded
        self.phraseVersion = phraseVersion
        self.keywordFallbackDraft = keywordFallbackDraft
        self.phrasePhraseDraft = phrasePhraseDraft
        self.phraseProviderIDDraft = phraseProviderIDDraft
        self.phraseToolIDDraft = phraseToolIDDraft
        self.isPhraseEditorOpen = isPhraseEditorOpen
        self.editingPhraseID = editingPhraseID
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
    /// The shell registry answered with its configured commands — the shell leg's row source
    /// (`shell-provider` wiring): a registry read, never a discovery and never a spawn.
    case shellConfigLoaded([ActionsToolRow])
    /// The audit provider answered with its two tools — the audit leg's row source
    /// (`audit-enablement` wiring): a static list read, never a discovery and never a spawn.
    case auditToolsLoaded([ActionsToolRow])
    /// The agent registry answered with its configured agents — the agent leg's row source
    /// (`coding-agent-handoff` wiring): a registry read, never a discovery and never a spawn.
    case agentConfigLoaded([ActionsToolRow])
    /// The agent registry's full rows landed — the authoring surface's row source.
    case agentDefinitionsLoaded([ActionsAgentDefinition])
    /// The known presets landed — the chooser's rows.
    case agentPresetsLoaded([ActionsAgentPreset])
    /// The presets' detection facts landed — the chooser's honest per-preset facts.
    case agentDetectionLoaded(ActionsAgentDetectionResult)
    /// The user picked a preset (or blank) — the add editor opens, pre-filled.
    case agentEditorOpened(presetID: String?)
    /// The user closed the add editor without saving.
    case agentEditorClosed
    /// One draft field changed — the closed set of editor fields, the environment pairs by
    /// their position in the draft list.
    case agentDraftFieldEdited(AgentDraftField, String)
    /// The user added an environment entry to the draft.
    case agentEnvironmentPairAdded
    /// The user removed an environment entry from the draft.
    case agentEnvironmentPairRemoved(Int)
    /// The user committed the editor — validated here, before anything reaches the file.
    case agentSaveRequested
    /// The user opened an existing row in the editor.
    case agentEditStarted(id: String)
    /// The user closed the edit editor without saving.
    case agentEditCancelled
    /// The user removed an agent — its enablement row goes with it.
    case agentRemoved(id: String)
    /// The phrase table was read — the Phrases section's row source and its snapshot: the file
    /// the section loads is what a later save compares against (the read-before-write guard).
    case phrasesConfigLoaded(ActionsPhraseFile)
    /// The user opened the blank add editor.
    case phraseEditorOpened
    /// One phrase draft field changed — the closed set of editor fields.
    case phraseDraftFieldEdited(PhraseDraftField, String)
    /// The user committed the phrase editor — validated here, before anything reaches the file.
    case phraseSaveRequested
    /// The user opened an existing phrase row in the editor.
    case phraseEditStarted(phrase: String)
    /// The user closed the phrase editor without saving (add or edit).
    case phraseEditCancelled
    /// The user removed a phrase row from the draft.
    case phraseRemoved(phrase: String)
    /// The user flipped the keyword-fallback switch.
    case keywordFallbackToggled(Bool)
    /// The phrase save reached the file — the snapshot advances to the saved table and the
    /// drafts clear (the dedicated success signal, so a server or agent save cannot move the
    /// phrase snapshot out from under an in-flight edit).
    case phrasesSaved(ActionsPhraseFile)
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

        case .shellConfigLoaded(let tools):
            // Default off is the reducer's rule, not the wiring's — the same fold discovery
            // rows obey: a command that arrives enabled is off unless the persisted enablement
            // holds its key (M7).
            next.shellRows = tools.map { row in
                var resolved = row
                resolved.isEnabled = next.enablement.contains(
                    ActionsToolKey(providerID: row.providerID, toolID: row.toolID))
                return resolved
            }
            next.isShellLoaded = true

        case .auditToolsLoaded(let tools):
            // Default off is the reducer's rule, not the wiring's — the same fold discovery
            // rows obey: an audit tool that arrives enabled is off unless the persisted
            // enablement holds its key (M7).
            next.auditRows = tools.map { row in
                var resolved = row
                resolved.isEnabled = next.enablement.contains(
                    ActionsToolKey(providerID: row.providerID, toolID: row.toolID))
                return resolved
            }
            next.isAuditToolsLoaded = true

        case .agentConfigLoaded(let tools):
            // Default off is the reducer's rule, not the wiring's — the same fold discovery
            // rows obey: an agent that arrives enabled is off unless the persisted enablement
            // holds its key (M7).
            next.agentRows = tools.map { row in
                var resolved = row
                resolved.isEnabled = next.enablement.contains(
                    ActionsToolKey(providerID: row.providerID, toolID: row.toolID))
                return resolved
            }
            next.isAgentLoaded = true

        case .agentDefinitionsLoaded(let definitions):
            next.agentDefinitions = definitions

        case .agentPresetsLoaded(let presets):
            next.agentPresets = presets
            next.isAgentCatalogLoaded = true

        case .agentDetectionLoaded(let detection):
            next.agentDetection = detection

        case .agentEditorOpened(let presetID):
            // The add editor, pre-filled from the preset — or blank. The drafts are re-minted
            // on every open, so a failed earlier save can never leak its values into a fresh
            // row; the project directory is the S2 remembered value, in memory only.
            next.isAgentEditorOpen = true
            next.editingAgentID = nil
            next.agentEnvironmentDrafts = []
            next.agentTimeoutDraft = "\(AgentAuthoringConstants.defaultTimeoutSeconds)"
            next.agentProjectDirectoryDraft = next.lastAgentProjectDirectory
            next.agentClauseDraft = ""
            if let presetID, let preset = next.agentPresets.first(where: { $0.id == presetID }) {
                next.agentIDDraft = preset.id
                // The editor-side render: every `<task>` placeholder in the draft becomes the
                // concrete default task, so a pick-then-save commits a row that means
                // something — the catalog's pinned templates are never substituted.
                next.agentArgumentsDraft = preset.arguments
                    .joined(separator: " ")
                    .replacingOccurrences(
                        of: AgentAuthoringConstants.taskPlaceholder,
                        with: ActionsTabCopy.agentDefaultTask)
                switch next.agentDetection[presetID] {
                case .detected(let path):
                    // The honest pre-fill: the binary exists at that path.
                    next.agentExecutablePathDraft = path
                case .notDetected, nil:
                    // The first candidate name, unresolved — a visible marker the user must
                    // make absolute; Save refuses until then (never a claim that it runs).
                    next.agentExecutablePathDraft = preset.candidateNames.first ?? ""
                }
            } else {
                next.agentIDDraft = ""
                next.agentArgumentsDraft = ""
                next.agentExecutablePathDraft = ""
            }

        case .agentEditorClosed, .agentEditCancelled:
            next.isAgentEditorOpen = false
            next.editingAgentID = nil
            next.agentIDDraft = ""
            next.agentExecutablePathDraft = ""
            next.agentArgumentsDraft = ""
            next.agentProjectDirectoryDraft = ""
            next.agentTimeoutDraft = ""
            next.agentEnvironmentDrafts = []
            next.agentClauseDraft = ""

        case .agentDraftFieldEdited(let field, let value):
            switch field {
            case .id: next.agentIDDraft = value
            case .executablePath: next.agentExecutablePathDraft = value
            case .arguments: next.agentArgumentsDraft = value
            case .projectDirectory: next.agentProjectDirectoryDraft = value
            case .timeoutSeconds: next.agentTimeoutDraft = value
            case .clause: next.agentClauseDraft = value
            case .environmentKey(let index):
                guard next.agentEnvironmentDrafts.indices.contains(index) else { return state }
                next.agentEnvironmentDrafts[index].key = value
            case .environmentValue(let index):
                guard next.agentEnvironmentDrafts.indices.contains(index) else { return state }
                next.agentEnvironmentDrafts[index].value = value
            }

        case .agentEnvironmentPairAdded:
            next.agentEnvironmentDrafts.append(ActionsAgentEnvironmentPairDraft())

        case .agentEnvironmentPairRemoved(let index):
            guard next.agentEnvironmentDrafts.indices.contains(index) else { return state }
            next.agentEnvironmentDrafts.remove(at: index)

        case .agentSaveRequested:
            // The whole refusal battery runs here, before anything reaches the file: the
            // definition's own init rules, the duplicate-id refusal (the registry's
            // first-wins would silently skip a duplicate), and the `<task>` placeholder
            // warning — the row the user saves must be a row that means something. A refusal
            // is loud (saveError) and keeps the editor open with the draft intact.
            let definition: ActionsAgentDefinition
            switch Self.definition(from: next) {
            case .refused(let reason):
                next.saveError = ActionsTabCopy.agentInvalidRow(reason)
                return next
            case .valid(let row):
                definition = row
            }
            let editingID = next.editingAgentID
            if next.agentDefinitions.contains(where: {
                $0.id == definition.id && $0.id != editingID
            }) {
                next.saveError = ActionsTabCopy.agentDuplicateID(definition.id)
                return next
            }
            if definition.arguments.contains(AgentAuthoringConstants.taskPlaceholder) {
                next.saveError = ActionsTabCopy.agentPlaceholderWarning
                return next
            }
            if let editingID, let index = next.agentDefinitions.firstIndex(where: {
                $0.id == editingID
            }) {
                // Edit: mutate in place — never a delete-plus-add. A renamed id carries its
                // enablement with it: the old key would otherwise dangle, and a row the user
                // enabled would silently stop being enabled.
                let oldID = next.agentDefinitions[index].id
                next.agentDefinitions[index] = definition
                if oldID != definition.id {
                    let key = ActionsToolKey(
                        providerID: AgentAuthoringConstants.agentProviderID, toolID: oldID)
                    if next.enablement.contains(key) {
                        next.enablement.remove(key)
                        next.enablement.insert(
                            ActionsToolKey(
                                providerID: AgentAuthoringConstants.agentProviderID,
                                toolID: definition.id))
                    }
                }
            } else {
                next.agentDefinitions.append(definition)
            }
            next.editingAgentID = nil
            next.isAgentEditorOpen = false
            next.saveError = nil
            next.lastAgentProjectDirectory = definition.projectDirectory ?? ""
            // The drafts are held through the save: success clears them (`.saveSucceeded`),
            // failure leaves them for the user — the row the editor committed stays the row
            // the user wrote.

        case .agentEditStarted(let id):
            guard let definition = next.agentDefinitions.first(where: { $0.id == id })
            else { return state }
            next.isAgentEditorOpen = true
            next.editingAgentID = id
            next.agentIDDraft = definition.id
            next.agentExecutablePathDraft = definition.executablePath
            next.agentArgumentsDraft = definition.arguments.joined(separator: " ")
            next.agentProjectDirectoryDraft = definition.projectDirectory ?? ""
            next.agentTimeoutDraft = "\(definition.timeoutSeconds)"
            next.agentEnvironmentDrafts = (definition.environment ?? [:]).map {
                ActionsAgentEnvironmentPairDraft(key: $0.key, value: $0.value)
            }
            next.agentClauseDraft = definition.clause ?? ""

        case .agentRemoved(let id):
            guard next.agentDefinitions.contains(where: { $0.id == id }) else { return state }
            next.agentDefinitions.removeAll { $0.id == id }
            // The enablement row goes with it — a removed agent's key would otherwise be
            // re-saved by the very next save, and the store's stale-row tolerance would keep
            // it forever (the server-removal precedent).
            next.enablement = next.enablement.filter {
                !($0.providerID == AgentAuthoringConstants.agentProviderID && $0.toolID == id)
            }
            if next.editingAgentID == id {
                next.editingAgentID = nil
                next.isAgentEditorOpen = false
            }
            next.saveError = nil

        case .phrasesConfigLoaded(let file):
            // The file is the section's row source and its snapshot: rows, version and the
            // switch all ride the draft, and the snapshot is what a later save compares the
            // committed file against. A load never writes.
            next.phraseRows = file.phrases
            next.phraseSnapshot = file
            next.phraseVersion = file.version
            next.keywordFallbackDraft = file.keywordFallback
            next.isPhrasesLoaded = true
            next.saveError = nil

        case .phraseEditorOpened:
            // The blank add editor — the drafts re-minted on every open, so a refused earlier
            // save can never leak its values into a fresh row.
            next.isPhraseEditorOpen = true
            next.editingPhraseID = nil
            next.phrasePhraseDraft = ""
            next.phraseProviderIDDraft = ""
            next.phraseToolIDDraft = ""
            next.saveError = nil

        case .phraseDraftFieldEdited(let field, let value):
            switch field {
            case .phrase: next.phrasePhraseDraft = value
            case .providerID: next.phraseProviderIDDraft = value
            case .toolID: next.phraseToolIDDraft = value
            }

        case .phraseSaveRequested:
            // The refusal battery runs here, before anything reaches the file — the store's own
            // rules, mirrored so the editor and the file agree. A refusal is loud (saveError)
            // and keeps the editor open with the draft intact.
            switch Self.phraseRow(from: next) {
            case .refused(let reason):
                next.saveError = ActionsTabCopy.phraseInvalidRow(reason)
                return next
            case .valid(let row):
                if let editing = next.editingPhraseID,
                    let index = next.phraseRows.firstIndex(where: { $0.phrase == editing })
                {
                    // Edit: replace in place — never a delete-plus-add, so the row keeps its
                    // identity across a rename.
                    next.phraseRows[index] = row
                } else {
                    next.phraseRows.append(row)
                }
            }
            next.isPhraseEditorOpen = false
            next.editingPhraseID = nil
            next.saveError = nil
            // The drafts are held through the save: success clears them (`.phrasesSaved`),
            // failure leaves them for the user — the row the editor committed stays the row
            // the user wrote.

        case .phraseEditStarted(let phrase):
            guard let row = next.phraseRows.first(where: { $0.phrase == phrase }) else {
                return state
            }
            next.isPhraseEditorOpen = true
            next.editingPhraseID = phrase
            next.phrasePhraseDraft = row.phrase
            next.phraseProviderIDDraft = row.providerID
            next.phraseToolIDDraft = row.toolID
            next.saveError = nil

        case .phraseEditCancelled:
            next.isPhraseEditorOpen = false
            next.editingPhraseID = nil
            next.phrasePhraseDraft = ""
            next.phraseProviderIDDraft = ""
            next.phraseToolIDDraft = ""

        case .phraseRemoved(let phrase):
            guard next.phraseRows.contains(where: { $0.phrase == phrase }) else { return state }
            next.phraseRows.removeAll { $0.phrase == phrase }
            if next.editingPhraseID == phrase {
                next.editingPhraseID = nil
                next.isPhraseEditorOpen = false
            }
            next.saveError = nil

        case .keywordFallbackToggled(let on):
            next.keywordFallbackDraft = on

        case .phrasesSaved(let file):
            // The write reached the file: the snapshot advances to the saved table (so the next
            // save's read-before-write guard compares against the truth), and the drafts clear.
            next.phraseRows = file.phrases
            next.phraseSnapshot = file
            next.phraseVersion = file.version
            next.keywordFallbackDraft = file.keywordFallback
            next.saveError = nil
            next.phrasePhraseDraft = ""
            next.phraseProviderIDDraft = ""
            next.phraseToolIDDraft = ""
            next.editingPhraseID = nil
            next.isPhraseEditorOpen = false

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
            // row nobody discovered — or a command the registry never declared — mints nothing
            // and enables nothing. The shell rows and the agent rows join the search: their
            // rows flip through the same enablement set, the same draft, the same save.
            if let index = next.toolRows.firstIndex(where: {
                $0.providerID == providerID && $0.toolID == toolID
            }) {
                next.toolRows[index].isEnabled = enabled
            } else if let index = next.shellRows.firstIndex(where: {
                $0.providerID == providerID && $0.toolID == toolID
            }) {
                next.shellRows[index].isEnabled = enabled
            } else if let index = next.auditRows.firstIndex(where: {
                $0.providerID == providerID && $0.toolID == toolID
            }) {
                next.auditRows[index].isEnabled = enabled
            } else if let index = next.agentRows.firstIndex(where: {
                $0.providerID == providerID && $0.toolID == toolID
            }) {
                next.agentRows[index].isEnabled = enabled
            } else {
                return state
            }
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
            // The shell rows and the agent rows join the search: a shell command or an agent
            // is armed through the same gate the server tools are.
            guard next.arm == .idle,
                let row = (next.toolRows + next.shellRows + next.agentRows).first(where: {
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
            // The agent drafts clear only on a save that reached the file — a failed save
            // leaves them in place, the "draft kept" rule.
            next.agentIDDraft = ""
            next.agentExecutablePathDraft = ""
            next.agentArgumentsDraft = ""
            next.agentProjectDirectoryDraft = ""
            next.agentTimeoutDraft = ""
            next.agentEnvironmentDrafts = []
            next.agentClauseDraft = ""

        case .saveFailed(let message):
            next.saveError = message
        }
        return next
    }

    // MARK: - The row the drafts name

    /// Builds the definition the drafts name, or the loud reason the row must be refused —
    /// the definition's own init rules, spelled under ``AgentAuthoringConstants`` because the
    /// module boundary forbids naming the registry's (the agreement is pinned by the surface
    /// suite). The arguments draft splits on whitespace — the row saved is exactly the words
    /// typed — and an empty timeout draft is the definition's *absent*: the 30-second
    /// default. Environment pairs with an empty key are not entries.
    private static func definition(
        from state: ActionsTabState
    ) -> DraftValidation {
        let id = state.agentIDDraft
        guard !id.isEmpty else { return .refused(reason: ActionsTabCopy.agentEmptyIDReason) }
        guard id.count <= AgentAuthoringConstants.maximumIDLength else {
            return .refused(reason: ActionsTabCopy.agentOverlongIDReason)
        }
        let executablePath = state.agentExecutablePathDraft
        guard isAbsolute(executablePath) else {
            return .refused(reason: ActionsTabCopy.agentExecutablePathReason)
        }
        let arguments = state.agentArgumentsDraft.split(whereSeparator: \.isWhitespace).map(String.init)
        guard arguments.count <= AgentAuthoringConstants.maximumArgumentCount else {
            return .refused(reason: ActionsTabCopy.agentArgumentCountReason)
        }
        let projectDirectory = state.agentProjectDirectoryDraft
        if !projectDirectory.allSatisfy(\.isWhitespace) {
            guard isAbsolute(projectDirectory) else {
                return .refused(reason: ActionsTabCopy.agentProjectDirectoryReason)
            }
        }
        let timeoutSeconds: Int
        if state.agentTimeoutDraft.isEmpty {
            timeoutSeconds = AgentAuthoringConstants.defaultTimeoutSeconds
        } else if let parsed = Int(state.agentTimeoutDraft),
            (1...AgentAuthoringConstants.maximumTimeoutSeconds).contains(parsed)
        {
            timeoutSeconds = parsed
        } else {
            return .refused(reason: ActionsTabCopy.agentTimeoutReason)
        }
        var environment: [String: String] = [:]
        for pair in state.agentEnvironmentDrafts {
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            guard
                key.count <= AgentAuthoringConstants.maximumEnvironmentValueLength
                    && pair.value.count <= AgentAuthoringConstants.maximumEnvironmentValueLength
            else {
                return .refused(reason: ActionsTabCopy.agentEnvironmentLengthReason)
            }
            environment[key] = pair.value
        }
        guard environment.count <= AgentAuthoringConstants.maximumEnvironmentEntries else {
            return .refused(reason: ActionsTabCopy.agentEnvironmentCountReason)
        }
        return .valid(
            ActionsAgentDefinition(
                id: id, executablePath: executablePath, arguments: arguments,
                projectDirectory: projectDirectory, timeoutSeconds: timeoutSeconds,
                environment: environment.isEmpty ? nil : environment,
                clause: state.agentClauseDraft.isEmpty ? nil : state.agentClauseDraft))
    }

    /// Builds the phrase row the drafts name, or the loud reason the row must be refused — the
    /// store's own save rules, mirrored here so the editor refuses before the file ever sees the
    /// row: a `dev.vocca.shell` target, an empty phrase, an empty target, a phrase that
    /// normalizes to one already present, and the length caps. The duplicate check excludes the
    /// row being edited (an in-place rename is never a duplicate of itself).
    private static func phraseRow(from state: ActionsTabState) -> PhraseDraftValidation {
        let providerID = state.phraseProviderIDDraft
        let toolID = state.phraseToolIDDraft
        guard providerID != PhraseAuthoringConstants.shellProviderID else {
            return .refused(reason: ActionsTabCopy.phraseShellTargetReason)
        }
        let phrase = state.phrasePhraseDraft
        let key = PhraseAuthoringConstants.normalized(phrase)
        guard !key.isEmpty else {
            return .refused(reason: ActionsTabCopy.phraseEmptyPhraseReason)
        }
        guard !providerID.isEmpty, !toolID.isEmpty else {
            return .refused(reason: ActionsTabCopy.phraseEmptyTargetReason)
        }
        let isDuplicate = state.phraseRows.contains {
            PhraseAuthoringConstants.normalized($0.phrase) == key && $0.phrase != state.editingPhraseID
        }
        guard !isDuplicate else {
            return .refused(reason: ActionsTabCopy.phraseDuplicateReason)
        }
        guard phrase.count <= PhraseAuthoringConstants.maximumPhraseLength else {
            return .refused(reason: ActionsTabCopy.phraseTooLongReason)
        }
        guard providerID.count <= PhraseAuthoringConstants.maximumIDLength,
            toolID.count <= PhraseAuthoringConstants.maximumIDLength
        else {
            return .refused(reason: ActionsTabCopy.phraseIDTooLongReason)
        }
        return .valid(
            ActionsPhraseRow(phrase: phrase, providerID: providerID, toolID: toolID))
    }

    /// The phrase drafts' validation answer — the ``DraftValidation`` shape for the row.
    private enum PhraseDraftValidation {
        case valid(ActionsPhraseRow)
        case refused(reason: String)
    }

    /// The drafts' validation answer: the row they name, or the loud reason they must be
    /// refused. `String` is deliberately not the failure half of a `Result` — the reason is
    /// copy, not an error to throw.
    private enum DraftValidation {
        case valid(ActionsAgentDefinition)
        case refused(reason: String)
    }
    /// Whether `path` is a usable absolute path under the fixed-argv contract — it must begin
    /// with `/`, and it must **not** begin with `~` (nothing in this product expands `~`, so a
    /// `~/bin/agent` would silently resolve to a literal `~` directory at spawn time — the
    /// exact silent mangling the row's contract exists to refuse).
    private static func isAbsolute(_ path: String) -> Bool {
        (path as NSString).isAbsolutePath && !path.hasPrefix("~")
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