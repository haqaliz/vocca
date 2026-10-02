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

/// **The Actions tab's view model — plain structures, and nothing from `VoccaActions`.**
///
/// `VoccaUI` may import only `VoccaCore` (`ModuleBoundaryTests`), and the action layer's own
/// types (`MCPServerConfiguration`, `MCPToolDescriptor`, `ActionInvocation`, `ActionSummary`)
/// must stay out of a settings table for a second reason as well: the family lints
/// (`ActionSeamBoundaryTests`) confine the action vocabulary to the files that decide with it,
/// and a page that renders tool rows decides nothing. So everything that crosses the tab's
/// seams is spelled here, in identifiers and strings, and the wiring maps `VoccaActions` types
/// into these shapes — one direction, at the composition root.

/// One configured server, as the tab lists it: the stable identity, the name a person reads,
/// and the executable path the wiring launches.
public struct ActionsServerRow: Sendable, Equatable, Identifiable {
    /// The stable identifier — minted once at add time, kept across edits and relaunches
    /// (the `MCPServerConfiguration.id` contract: a regenerated id would read to every later
    /// reader like a deleted server and a new one).
    public let id: String
    /// What to call it on screen.
    public var name: String
    /// The executable to launch — absolute, the stdio transport's contract.
    public var path: String

    public init(id: String, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

/// Two identifiers that name one tool — the tab's spelling of an invocation with no arguments.
/// Enablement is membership by the whole pair, never by tool name alone (two providers may
/// serve the same tool name; enabling one must not enable the other).
public struct ActionsToolKey: Sendable, Equatable, Hashable {
    public let providerID: String
    public let toolID: String

    public init(providerID: String, toolID: String) {
        self.providerID = providerID
        self.toolID = toolID
    }
}

/// How far a tool's action reaches — the claimed radius, rendered on the toggle row. A plain
/// vocabulary rather than the core's `BlastRadius` for the family-lint reason above: the tab
/// reports the claim; it never classifies with it.
public enum ActionsTabRadius: String, Sendable, Equatable, CaseIterable {
    /// Observes and reports; changes nothing and sends nothing anywhere.
    case readOnly
    /// Changes or removes something on this machine.
    case destructive
    /// Leaves the machine — a message sent, a request made, a file shared.
    case outwardFacing
}

/// One discovered tool, as the tab renders it: who owns it, what it is called, what the server
/// said about it, and whether the user enabled it — **off by default** (M7), and the reducer
/// re-derives the flag from the persisted enablement rather than trusting what arrives.
public struct ActionsToolRow: Sendable, Equatable, Identifiable {
    /// The provider that owns the tool — for a server's tools, the wiring keys it to the server.
    public let providerID: String
    /// The tool within that provider.
    public let toolID: String
    /// The server's own one-line account of what the tool does.
    public let summary: String
    /// The claimed radius — the server's word, never verified here.
    public let radius: ActionsTabRadius
    /// Whether the user enabled the tool. The reducer's `discoverySucceeded` folds this from
    /// the persisted enablement set; a row that arrives enabled is still off unless the set
    /// says otherwise.
    public var isEnabled: Bool

    public var id: String { "\(providerID)/\(toolID)" }

    public init(
        providerID: String, toolID: String, summary: String, radius: ActionsTabRadius,
        isEnabled: Bool = false
    ) {
        self.providerID = providerID
        self.toolID = toolID
        self.summary = summary
        self.radius = radius
        self.isEnabled = isEnabled
    }
}

/// The config as the tab edits it — servers and the persisted enablement, one draft, so what
/// the table shows and what `action-config.json` holds cannot drift apart.
public struct ActionsConfigDraft: Sendable, Equatable {
    /// The configured servers.
    public var servers: [ActionsServerRow]
    /// The persisted enablement — absent is off, `ActionEnablement`'s own semantics (PRD M7).
    public var enablement: Set<ActionsToolKey>

    /// Nothing configured — the file's empty spelling, and the honest first-launch answer.
    public static let empty = ActionsConfigDraft(servers: [], enablement: [])

    public init(servers: [ActionsServerRow], enablement: Set<ActionsToolKey>) {
        self.servers = servers
        self.enablement = enablement
    }
}

/// What an explicit discovery attempt came back with — the tab's own spelling of success and
/// failure. The failure carries the bounded key the wiring reported; the tab shows it and lets
/// the user retry.
public enum ActionsDiscoveryResult: Sendable, Equatable {
    /// The server answered with its tool list.
    case succeeded([ActionsToolRow])
    /// Discovery failed — the child could not be spawned or answered — with the wiring's reason.
    case failed(String)
}

// MARK: - The agent authoring surface (agent-presets)

/// One configured coding agent, as the tab lists and edits it — the tab's own plain spelling
/// of a `coding-agents.json` row.
///
/// `VoccaUI` may not name the action layer's types (the module boundary), so everything the
/// authoring surface crosses its seams with is spelled here, and the wiring maps the two
/// spellings at the composition root — the ``ActionsConfigDraft`` precedent, one direction.
public struct ActionsAgentDefinition: Sendable, Equatable, Identifiable {
    /// The stable identifier of the agent — the id enablement rows name it by, and the id
    /// the duplicate check refuses.
    public var id: String
    /// The executable to launch — absolute, the fixed-argv contract.
    public var executablePath: String
    /// The fixed argv the executable is told — the space-separated draft's folded value.
    public var arguments: [String]
    /// The absolute directory the agent works in — or `nil` for the nil-directory row: the
    /// editor's empty Project directory field (the caption's contract — "leave empty to
    /// detect the focused app's project"), resolved once at arm time. A blank value is the
    /// nil spelling; a filled-in value must be absolute and must not start with `~` (the
    /// definition's own rule, spelled on the surface).
    public var projectDirectory: String?
    /// How long the agent may run, in seconds — `1...600`, empty meaning the 30-second
    /// default, exactly as the definition's own init rules say.
    public var timeoutSeconds: Int
    /// Explicit environment entries for the agent's process — capped, never truncated.
    public var environment: [String: String]?
    /// An optional plain-text sentence the author adds to the confirmation surface.
    public var clause: String?

    public init(
        id: String, executablePath: String, arguments: [String] = [],
        projectDirectory: String? = nil, timeoutSeconds: Int = 30,
        environment: [String: String]? = nil, clause: String? = nil
    ) {
        self.id = id
        self.executablePath = executablePath
        self.arguments = arguments
        self.projectDirectory = projectDirectory.flatMap {
            $0.allSatisfy(\.isWhitespace) ? nil : $0
        }
        self.timeoutSeconds = timeoutSeconds
        self.environment = environment
        self.clause = clause
    }
}

/// The registry as the tab saves it — the ``ActionsConfigDraft`` shape for
/// `coding-agents.json`: version + rows, one draft, so what the table shows and what the
/// file holds cannot drift.
public struct ActionsAgentFile: Sendable, Equatable {
    /// The file format's version — this build reads and writes `1`.
    public let version: Int
    /// The configured agents, in the table's order.
    public let agents: [ActionsAgentDefinition]

    /// No agents — the file's empty spelling.
    public static let empty = ActionsAgentFile(version: 1, agents: [])

    public init(version: Int = 1, agents: [ActionsAgentDefinition]) {
        self.version = version
        self.agents = agents
    }
}

/// One known coding-agent preset, as the chooser renders it — the tab's plain spelling of
/// the catalog's row: the stable id, the display name, the candidate names detection
/// resolves, and the non-interactive argv template the editor pre-fills.
public struct ActionsAgentPreset: Sendable, Equatable, Identifiable {
    /// The stable identifier of the preset.
    public let id: String
    /// The human-readable name the chooser shows.
    public let displayName: String
    /// The candidate binary names detection resolves against.
    public let candidateNames: [String]
    /// The argv template the editor pre-fills — with the placeholder, never substituted.
    public let arguments: [String]

    public init(id: String, displayName: String, candidateNames: [String], arguments: [String]) {
        self.id = id
        self.displayName = displayName
        self.candidateNames = candidateNames
        self.arguments = arguments
    }
}

/// One preset's detection fact, as the chooser renders it — the tab's plain spelling of the
/// resolver's answer. **The honest fact**: detection is the binary exists at a resolved
/// path — never a version, never "ready to run", and this vocabulary has no words for more.
public enum ActionsAgentDetection: Sendable, Equatable {
    /// The binary exists at `path`.
    case detected(path: String)
    /// The binary exists nowhere the resolver was allowed to look.
    case notDetected
}

/// One detection pass — every preset id, mapped to its fact.
public typealias ActionsAgentDetectionResult = [String: ActionsAgentDetection]

/// One environment entry as the editor edits it — a key/value pair with a UI-side identity,
/// because a dictionary cannot hold a half-typed entry and the list's order is the entry's
/// own place.
public struct ActionsAgentEnvironmentPairDraft: Sendable, Equatable, Identifiable {
    /// The pair's UI-side identity — minted once per entry, for the editor's list.
    public let id: UUID
    /// The entry's key — a pair with an empty key is not an entry.
    public var key: String
    /// The entry's value — may be empty.
    public var value: String

    public init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

/// The agent editor's fields — the closed set the draft-edit action names. The environment
/// pairs are edited by their position in the draft list.
public enum AgentDraftField: Sendable, Equatable {
    case id
    case executablePath
    case arguments
    case projectDirectory
    case timeoutSeconds
    case clause
    case environmentKey(Int)
    case environmentValue(Int)
}

/// **The authoring surface's own copy of the row contract** — the caps, the timeout default
/// and the placeholder `VoccaUI` must validate and pre-fill with, spelled here because the
/// module boundary forbids naming the registry's and the catalog's constants.
///
/// A second spelling is honest only while it is proven to agree with the one source of
/// truth: `AgentAuthoringSurfaceTests` pins every value here against its action-layer
/// counterpart, so a retune on either side fails loudly — the store/resolver agreement
/// precedent.
public enum AgentAuthoringConstants {
    /// ``CodingAgentRegistry/maximumIDLength``.
    public static let maximumIDLength = 128
    /// ``CodingAgentRegistry/maximumArgumentCount``.
    public static let maximumArgumentCount = 64
    /// ``CodingAgentRegistry/maximumEnvironmentEntries``.
    public static let maximumEnvironmentEntries = 16
    /// ``CodingAgentRegistry/maximumEnvironmentValueLength``.
    public static let maximumEnvironmentValueLength = 256
    /// ``CodingAgentRegistry/maximumTimeoutSeconds``.
    public static let maximumTimeoutSeconds = 600
    /// ``CodingAgentRegistry/defaultTimeoutSeconds``.
    public static let defaultTimeoutSeconds = 30
    /// ``KnownAgentPresets/taskPlaceholder`` — the literal the editor pre-fills and a save
    /// with it still in the argv refuses loudly.
    public static let taskPlaceholder = "<task>"
    /// ``CodingAgentProvider/providerID`` — the enablement keys the agent rows cascade on
    /// edit-rename and remove.
    public static let agentProviderID = "vocca.agent"
}