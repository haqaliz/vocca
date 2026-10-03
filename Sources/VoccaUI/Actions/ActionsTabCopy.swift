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

/// The Actions tab's strings, kept out of the views so they can be read without a window
/// server — the ``AppsTabCopy``/``BadgeCopy`` shape.
public enum ActionsTabCopy {

    /// The servers section's title.
    public static let serversSectionTitle = "Servers"

    /// The tools section's title — the section whose button spawns the child, and where the
    /// D2 copy must therefore live (the moment of spawn).
    public static let toolsSectionTitle = "Server tools"

    /// The shell section's title (`shell-provider` wiring) — the section that lists the
    /// registry's configured commands, armable like any other tool row.
    public static let shellSectionTitle = "Shell commands"

    /// The agents section's title (`coding-agent-handoff` wiring) — the section that lists
    /// the registry's configured agents, armable like any other tool row.
    public static let agentsSectionTitle = "Coding agents"

    /// The agents section's empty state — honest about why it is empty: nothing is configured
    /// out of the box, and an absent `coding-agents.json` is the empty registry. It points at
    /// the in-app affordance, which is where a row is authored since `agent-authoring`.
    public static let emptyAgents =
        "No coding agents configured. Add one to arm it here."

    // MARK: - The agent authoring surface (agent-presets)

    /// The agents section's add affordance — the header of the preset chooser.
    public static let agentAddButton = "Add coding agent"

    /// The preset chooser's title — the rows below it are the known agents.
    public static let agentChooserTitle = "Preset"

    /// The chooser's blank row — a pick that starts the editor empty.
    public static let agentBlankOption = "Blank"

    /// The editor's executable path field.
    public static let agentExecutablePathLabel = "Executable path"

    /// The editor's arguments field — the fixed argv, space-separated.
    public static let agentArgumentsLabel = "Arguments"

    /// The editor's project directory field.
    public static let agentProjectDirectoryLabel = "Project directory"

    /// The editor's project directory field's caption (`agent-wiring-cwd` R4) — what an
    /// empty field means: the arm-time resolution detects the focused app's working
    /// directory (the metadata lane's read), and the confirmation sentence shows it.
    public static let agentProjectDirectoryCaption =
        "leave empty to detect the focused app's project"

    /// The editor's timeout field.
    public static let agentTimeoutLabel = "Timeout (seconds)"

    /// The editor's environment section title.
    public static let agentEnvironmentLabel = "Environment"

    /// The editor's clause field.
    public static let agentClauseLabel = "Clause"

    /// The editor's add-an-environment-entry control.
    public static let agentAddEnvironmentEntry = "Add environment entry"

    /// One preset's detection fact, when the binary exists at a path — **the honest copy**:
    /// "detected" means the binary exists at that path, never that it runs or its version
    /// (`agent-detection` R-A).
    public static func agentDetected(_ path: String) -> String {
        "Detected — \(path)"
    }

    /// One preset's detection fact, when the binary exists nowhere the resolver may look.
    public static let agentNotDetected = "not detected"

    /// **The concrete default task the preset pre-fill renders the `<task>` placeholder
    /// as** — the editor-side render (the N1 flip): a preset pick pre-fills the arguments
    /// draft with a row that means something, so a pick-then-save commits immediately and
    /// the user edits the task per row. The catalog's pinned templates are untouched — the
    /// substitution happens in the draft, never in the catalog.
    public static let agentDefaultTask = "Summarize the current project"

    /// **The `<task>` placeholder warning** (PRD critique gap 1): a save whose argv still
    /// carries the placeholder is refused with the loud explanation — the row the user saves
    /// must be a row that means something (the honest-sentence principle; the refusal is at
    /// Save, never at confirm).
    public static let agentPlaceholderWarning =
        "Save refused: the arguments still contain \(AgentAuthoringConstants.taskPlaceholder). "
        + "A row that means something cannot save a placeholder — replace "
        + "\(AgentAuthoringConstants.taskPlaceholder) with a concrete task, or remove it from "
        + "the arguments."

    /// **The placeholder row's arm refusal** (`utterance-threading`, PRD R4): arming a row
    /// whose argv still carries the `<task>` placeholder is refused loudly — the tab has no
    /// utterance to fill it with, so a placeholder row cannot run from here; its task is
    /// filled by the spoken words in conversation (the voice leg is the only path that fills
    /// one). The editor's `<task>`-Save refusal above is unchanged — this is the arm path's
    /// own line.
    public static let agentPlaceholderArmRefusal =
        "Arm refused: the arguments still contain \(AgentAuthoringConstants.taskPlaceholder). "
        + "A placeholder row cannot run from the tab — its task is filled by your spoken "
        + "words in conversation. Replace \(AgentAuthoringConstants.taskPlaceholder) with a "
        + "concrete task in the arguments, or remove it."

    /// A save refused because its id matches an existing row — the registry's first-wins
    /// would silently skip the duplicate, so the editor refuses it loudly, naming the id.
    public static func agentDuplicateID(_ id: String) -> String {
        "Save refused: an agent named \"\(id)\" already exists. Every agent id is unique."
    }

    /// A save refused because the draft violates the row's own contract, with the reason.
    public static func agentInvalidRow(_ reason: String) -> String {
        "Save refused: \(reason)"
    }

    /// The reasons the editor refuses with — the definition's own init rules, in words.
    public static let agentEmptyIDReason = "the id cannot be empty"
    public static let agentOverlongIDReason =
        "the id is longer than \(AgentAuthoringConstants.maximumIDLength) characters"
    public static let agentExecutablePathReason =
        "the executable path must be absolute and must not start with ~"
    public static let agentProjectDirectoryReason =
        "the project directory, when filled in, must be absolute and must not start with ~"
    public static let agentTimeoutReason =
        "the timeout must be a number between 1 and \(AgentAuthoringConstants.maximumTimeoutSeconds) seconds"
    public static let agentArgumentCountReason =
        "more than \(AgentAuthoringConstants.maximumArgumentCount) arguments"
    public static let agentEnvironmentCountReason =
        "more than \(AgentAuthoringConstants.maximumEnvironmentEntries) environment entries"
    public static let agentEnvironmentLengthReason =
        "an environment key or value is longer than \(AgentAuthoringConstants.maximumEnvironmentValueLength) characters"

    /// The shell section's empty state — honest about why it is empty: nothing is configured
    /// out of the box, and an absent `shell-commands.json` is the empty registry.
    public static let emptyShellCommands =
        "No shell commands configured. Add them to shell-commands.json to arm them here."

    /// **The shell leg's D2 copy, exact-in-spirit** (the server-author copy above): configuring
    /// a shell command runs that command on the user's machine — and Vocca's check watches its
    /// own process and cannot see inside a program Vocca starts on its behalf. Placed in the
    /// shell section, the moment of arm.
    public static let shellD2TrustCopy =
        "Configuring a shell command runs that command on your machine; Vocca cannot see "
        + "inside a program it starts on your behalf."

    /// **The agent leg's D2 copy, exact-in-spirit** (the shell copy above): configuring a
    /// coding agent runs it on the user's machine with the user's configured project — and
    /// Vocca's check watches its own process and cannot see inside a program Vocca starts on
    /// its behalf, so an enabled agent's egress is never provable. Placed in the agents
    /// section, the moment of arm.
    public static let agentD2TrustCopy =
        "Configuring a coding agent runs it on your machine with your configured project; "
        + "Vocca cannot see inside a program it starts on your behalf — an enabled agent's "
        + "egress is never provable."

    /// **The baseline's D2 line** (`wiring-baseline`, the hard question): the composition
    /// hands every agent child the user's home directory — the wired HOME baseline — so
    /// configuring an agent is trust extended to its author over the whole home folder.
    /// Exact-in-spirit with the D2 copies above; placed in the agents section beside them,
    /// the moment of trust.
    public static let agentBaselineD2Copy =
        "the baseline hands the agent your home directory; configure only agents you trust"

    /// The empty state — honest about why it is empty.
    public static let emptyServers =
        "No servers configured yet. Add one to connect its tools."

    /// The add form's name field.
    public static let nameFieldLabel = "Name"

    /// The add form's path field.
    public static let pathFieldLabel = "Path"

    /// The add form's commit button.
    public static let addServerButton = "Add server"

    /// The row's edit button.
    public static let editServerButton = "Edit"

    /// The row's remove button.
    public static let removeServerButton = "Remove"

    /// The editor's commit button.
    public static let saveServerButton = "Save"

    /// The editor's way out, which leaves the server exactly as it was.
    public static let cancelButton = "Cancel"

    /// The discover button — the explicit, user-initiated spawn (`action-surface-wiring` D2).
    public static let discoverButton = "Discover tools"

    /// What the control says while the child is answering.
    public static let discoveringLabel = "Discovering…"

    /// The failed discovery's way forward.
    public static let tryAgainButton = "Try again"

    /// The empty tool list, after a discovery that answered.
    public static let noToolsFound = "This server offers no tools."

    /// **The default-off detail (M7)** — the row copy under the toggles: tools are off until
    /// the user enables them, and a disabled tool cannot be invoked.
    public static let defaultOffDetail =
        "Tools are off by default. Enable a tool before it can be invoked."

    /// The row's invoke button — shown only for enabled tools.
    public static let invokeButton = "Invoke"

    /// The row's preview button — the dry-run, shown only for enabled tools.
    public static let previewButton = "Preview"

    /// What the tools section says while an arm is awaiting the confirmation card.
    public static let awaitingConfirmation = "Waiting for your confirmation…"

    /// **The D2 copy, exact-in-spirit** (`actions-tab/spec.md`): configuring a server is trust
    /// extended to its author, not a guarantee we can make. Vocca's check watches its own
    /// process and cannot see inside a program Vocca starts on your behalf — the narrowed
    /// promise, in words, placed in the discover section so a user meets it at the moment of
    /// spawn.
    public static let d2TrustCopy =
        "Configuring a server is trust extended to its author, not a guarantee we can make."

    /// A failed discovery, with the bounded key the wiring reported.
    public static func discoveryFailed(_ key: String) -> String {
        "Couldn't discover tools: \(key)"
    }

    /// The preview row — the provider's own sentence.
    public static func previewSentence(_ sentence: String) -> String {
        "Preview: \(sentence)"
    }

    /// The claimed radius, in words a person can weigh. The row reports the claim; it never
    /// verifies it — the escalate-only policy is the gate's.
    public static func radiusLabel(_ radius: ActionsTabRadius) -> String {
        switch radius {
        case .readOnly: return "Read only"
        case .destructive: return "Destructive"
        case .outwardFacing: return "Outward facing"
        }
    }

    /// A failed write, surfaced — the `AppsSettingsPage` rule: a store that silently fails to
    /// save is one the user sets up again next launch.
    public static func saveError(_ message: String) -> String {
        "Couldn't save: \(message)"
    }
}