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
    /// The server listed these tools.
    case succeeded([ActionsToolRow])
    /// Discovery failed — the child could not be spawned or answered — with the wiring's reason.
    case failed(String)
}