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

/// One known coding-agent CLI — the code-level seed the Coding agents editor pre-fills from
/// (`agent-catalog` spec, PRD R1).
///
/// A preset names the agent's stable id, its human-readable display name, the candidate binary
/// names detection resolves against, and a **non-interactive argv template** with the
/// ``KnownAgentPresets/taskPlaceholder`` placeholder string (e.g. claude: `["-p", "<task>"]`;
/// codex: `["exec", "<task>"]`).
///
/// ## A seed, never a claim
///
/// The template is a **seed**: Vocca never claims the CLI behaves as the template says — a real
/// run's failure is a loud returned value, and the surface copy says "detected = the binary
/// exists at that path", never "ready". The `<task>` placeholder is a literal string the editor
/// pre-fills and the user may edit; **this slice never substitutes it** (N1 stays deferred), so
/// a template can never be executed as a substitution.
///
/// The whole catalog is **pinned verbatim** by `KnownAgentPresetsTests` — the
/// ``KeywordIntentResolver/shippedSynonyms`` precedent, moved from the intent layer to the
/// coding-agents surface. A retune is a reviewed edit; the pin is the record of the decision.
public struct KnownAgentPreset: Sendable, Equatable {
    /// The stable identifier of the preset — the id the surface names rows by.
    public let id: String

    /// The human-readable name the Coding agents section shows for this preset.
    public let displayName: String

    /// The candidate binary names detection resolves against — e.g. `["claude"]`, or
    /// `["claude-code", "claude"]` where the CLI ships under an alternate name.
    public let candidateNames: [String]

    /// The non-interactive argv template the editor pre-fills — exactly one
    /// ``KnownAgentPresets/taskPlaceholder`` occurrence, never substituted by this slice.
    public let arguments: [String]

    /// - Parameters:
    ///   - id: The stable identifier of the preset.
    ///   - displayName: The human-readable name the Coding agents section shows.
    ///   - candidateNames: The candidate binary names detection resolves against.
    ///   - arguments: The non-interactive argv template, with the `<task>` placeholder.
    public init(
        id: String, displayName: String, candidateNames: [String], arguments: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.candidateNames = candidateNames
        self.arguments = arguments
    }
}

/// The closed known-agents catalog (`agent-catalog` spec acceptance 1-4, PRD R1) — the
/// code-level seed of **exactly eight** coding-agent CLIs.
///
/// ## What this is and what it is not
///
/// The catalog is **pure data**: no file system, no transport, no runtime behaviour, no import
/// beyond nothing (Sendable needs no Foundation). It feeds the detection aspect (candidate
/// names) and the authoring aspect (id, display name, argv template pre-fill). Nothing here
/// spawns, connects or creates — the default configuration's `spawnsSubprocess=false` is
/// untouched by the catalog's existence, and the transport lint stays green because this file
/// has nothing for it to find.
///
/// ## The pin is the record
///
/// The eight presets and their templates are **pinned verbatim** by `KnownAgentPresetsTests` —
/// a retune of a wrong seed (a flag a CLI changed, a display name that reads wrong, a candidate
/// name that never matches) is a reviewed edit to this file, exactly as the intent synonym
/// table's retune is a reviewed edit to ``KeywordIntentResolver/shippedSynonyms``.
///
/// The `q` preset is Amazon Q's CLI; `crush` is the eighth, reviewed in during planning. Every
/// template carries exactly one ``taskPlaceholder`` occurrence.
public enum KnownAgentPresets {
    /// The literal placeholder a preset's argv template carries the task in. A **string the
    /// editor pre-fills and the user may edit** — never substituted by this slice (N1 stays
    /// deferred), and pinned so the authoring aspect pre-fills the same spelling the pins watch.
    public static let taskPlaceholder = "<task>"

    /// The closed set of known presets, in the shipped order — exactly eight, pinned verbatim
    /// by `KnownAgentPresetsTests`. A ninth preset is a reviewed widening, not a silent
    /// addition.
    public static let all: [KnownAgentPreset] = [
        KnownAgentPreset(
            id: "claude", displayName: "Claude", candidateNames: ["claude"],
            arguments: ["-p", "<task>"]),
        KnownAgentPreset(
            id: "codex", displayName: "Codex", candidateNames: ["codex"],
            arguments: ["exec", "<task>"]),
        KnownAgentPreset(
            id: "gemini", displayName: "Gemini", candidateNames: ["gemini"],
            arguments: ["-p", "<task>"]),
        KnownAgentPreset(
            id: "opencode", displayName: "OpenCode", candidateNames: ["opencode"],
            arguments: ["run", "<task>"]),
        KnownAgentPreset(
            id: "aider", displayName: "Aider", candidateNames: ["aider"],
            arguments: ["--message", "<task>"]),
        KnownAgentPreset(
            id: "cursor", displayName: "Cursor", candidateNames: ["cursor"],
            arguments: ["run", "<task>"]),
        KnownAgentPreset(
            id: "q", displayName: "Amazon Q", candidateNames: ["q"],
            arguments: ["-p", "<task>"]),
        KnownAgentPreset(
            id: "crush", displayName: "Crush", candidateNames: ["crush"],
            arguments: ["run", "<task>"]),
    ]
}