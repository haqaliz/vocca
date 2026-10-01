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

/// The argv-derived sentence machinery of ``CodingAgentProvider`` (`agent-provider` spec, PRD
/// R2) — the rendering shared by `describe` and `invoke`, kept out of the conformance so that
/// the file that owes its Family-A rows owes only those rows.
///
/// ## The sentence is derived from the argv, never authored prose
///
/// The founder decision the shell slice pinned, carried over whole: a confirmation shows the
/// agent's id, the fixed argv verbatim and the project directory, with the author's optional
/// clause appended **last**, sanitised. A planted argv appears verbatim in the sentence, and a
/// misleading clause cannot hide it: the card confirms what actually runs, not what the author
/// wrote about it.
///
/// ## Everything that reaches a dialog line is sanitised
///
/// The agent id, every argv element, the project directory and the clause are all untrusted
/// text rendered into a safety dialog. A newline inside any of them would let it forge a new
/// line of the dialog it appears in — the cheapest way to make a confirmation say something
/// nobody wrote. The rule is exactly ``MCPProvider``'s: control characters below `0x20` and
/// `0x7F` become spaces.
///
/// ## The refusal keeps the radius's facts
///
/// The unexpected-arguments refusal still renders what would have run — a person asked to
/// approve a refusal should still see the argv — and says the call will be refused. The
/// unknown-agent sentence says nothing will happen, which is the truth of a row the registry
/// never declared.
public enum CodingAgentSentences {

    // MARK: - Sentences

    /// The concrete sentence for a resolved invocation: the agent id, the fixed argv verbatim,
    /// the project directory, and the author's clause appended last — the clause can describe,
    /// never hide.
    ///
    /// An empty argv renders as the executable alone — a binary that needs no arguments is a
    /// valid agent — so the sentence never carries a dangling space.
    static func sentence(
        id: String,
        executablePath: String,
        arguments: [String],
        projectDirectory: String,
        clause: String?
    ) -> String {
        let argvRendering = arguments.isEmpty
            ? sanitised(executablePath)
            : sanitised(executablePath) + " " + arguments.map { sanitised($0) }.joined(separator: " ")
        var sentence =
            "Run the coding agent '\(sanitised(id))': \(argvRendering) in "
            + sanitised(projectDirectory)
        sentence += "."
        if let clause, !clause.isEmpty {
            sentence += " " + sanitised(clause)
        }
        return sentence
    }

    /// The refusal sentence for an invocation that carried arguments an agent row cannot
    /// accept — the gap-1 pin: an agent row declares no parameters, so any supplied arguments
    /// are refused.
    ///
    /// The argv still renders — a person asked to approve a refusal should still see what
    /// would have run — and the sentence says the call will be refused. The clause does not
    /// appear: the call will not happen, so there is nothing for the author's description to
    /// describe.
    static func unexpectedArgumentsSentence(
        id: String,
        executablePath: String,
        arguments: [String],
        projectDirectory: String
    ) -> String {
        let argvRendering = arguments.isEmpty
            ? sanitised(executablePath)
            : sanitised(executablePath) + " " + arguments.map { sanitised($0) }.joined(separator: " ")
        return
            "Run the coding agent '\(sanitised(id))': \(argvRendering) in "
            + sanitised(projectDirectory)
            + ". An agent row declares no parameters, so Vocca could not read the arguments "
            + "supplied for this agent. The call will be refused."
    }

    /// The refusal sentence for an agent the registry never declared. Nothing will happen.
    static func unknownAgentSentence(toolID: String) -> String {
        "Vocca's coding-agent provider does not serve the agent '\(sanitised(toolID))'. "
            + "Nothing will happen."
    }

    // MARK: - Rendering

    /// `text` with control characters replaced by spaces.
    ///
    /// The ``MCPProvider`` rule, copied exactly: everything rendered into the sentence comes
    /// from outside Vocca — the agent id, the argv, the project directory, the clause — and a
    /// newline inside any of them would let it forge a new line of the dialog it appears in.
    static func sanitised(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.unicodeScalars.map { scalar in
                    scalar.value < 0x20 || scalar.value == 0x7F ? " " : scalar
                }))
    }
}