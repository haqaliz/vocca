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
/// agent's id, the fixed argv verbatim and the resolved project directory, with the author's
/// optional clause appended **last**, sanitised. A planted argv appears verbatim in the
/// sentence, and a misleading clause cannot hide it: the card confirms what actually runs, not
/// what the author wrote about it. When the resolution — `invocation.resolvedDirectory ??
/// agent.projectDirectory` — is nil, no `in` clause renders at all (S1): the child runs in
/// Vocca's cwd and the sentence says so by saying nothing about a directory.
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
///
/// ## The spoken task substitutes into the argv before either half renders
///
/// `task-carrier` (the `spoken-task-seeding` unit): an invocation may carry ``taskText`` —
/// the spoken words that fill the row's `<task>` placeholder. The substitution is **one
/// render shared by describe and invoke**: both halves resolve the substituted argv from
/// ``substitutedArguments(arguments:taskText:)``, so the argv that runs is the argv the
/// sentence showed, with the spoken words in place. The rule is deterministic — every
/// literal placeholder occurrence in every argv element — and Foundation-free: the split and
/// join are the standard library's own. The three refusals the rule leaves over are spoken
/// here too, each rendering the row's argv (what would have run, honestly) and saying the
/// call will be refused.
public enum CodingAgentSentences {

    // MARK: - Sentences

    /// The concrete sentence for a resolved invocation: the agent id, the fixed argv verbatim,
    /// the resolved project directory, and the author's clause appended last — the clause can
    /// describe, never hide.
    ///
    /// **The directory is optional (`invocation-carrier`, PRD R2/S1):** when the resolution —
    /// `invocation.resolvedDirectory ?? agent.projectDirectory` — is nil, the sentence renders
    /// **without** the `in <dir>` clause: the child will run in Vocca's own cwd, and the card
    /// says so by saying nothing about a directory, never a dishonest `in .`. The with-directory
    /// render is byte-identical to the pre-carrier shape.
    ///
    /// An empty argv renders as the executable alone — a binary that needs no arguments is a
    /// valid agent — so the sentence never carries a dangling space.
    static func sentence(
        id: String,
        executablePath: String,
        arguments: [String],
        projectDirectory: String?,
        clause: String?
    ) -> String {
        let argvRendering = arguments.isEmpty
            ? sanitised(executablePath)
            : sanitised(executablePath) + " " + arguments.map { sanitised($0) }.joined(separator: " ")
        var sentence = "Run the coding agent '\(sanitised(id))': \(argvRendering)"
        if let projectDirectory {
            sentence += " in " + sanitised(projectDirectory)
        }
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
    /// describe. The row's directory is optional like the argv's sibling is: a nil-directory
    /// row has no `in` clause to render (S1 — there is no directory to show).
    static func unexpectedArgumentsSentence(
        id: String,
        executablePath: String,
        arguments: [String],
        projectDirectory: String?
    ) -> String {
        let argvRendering = arguments.isEmpty
            ? sanitised(executablePath)
            : sanitised(executablePath) + " " + arguments.map { sanitised($0) }.joined(separator: " ")
        var sentence = "Run the coding agent '\(sanitised(id))': \(argvRendering)"
        if let projectDirectory {
            sentence += " in " + sanitised(projectDirectory)
        }
        sentence +=
            ". An agent row declares no parameters, so Vocca could not read the arguments "
            + "supplied for this agent. The call will be refused."
        return sentence
    }

    /// The refusal sentence for an agent the registry never declared. Nothing will happen.
    static func unknownAgentSentence(toolID: String) -> String {
        "Vocca's coding-agent provider does not serve the agent '\(sanitised(toolID))'. "
            + "Nothing will happen."
    }

    /// The refusal sentence for a spoken task with no placeholder in the row's argv — the
    /// task has nowhere to go.
    ///
    /// The argv still renders — what the row defines, which is the honest account of a call
    /// that cannot run — and the sentence says the call will be refused. The task text itself
    /// is never rendered: nothing runs, so nothing substitutes, and the dialog stays bounded.
    static func taskHasNowhereToGoSentence(
        id: String,
        executablePath: String,
        arguments: [String],
        projectDirectory: String?
    ) -> String {
        let argvRendering = arguments.isEmpty
            ? sanitised(executablePath)
            : sanitised(executablePath) + " " + arguments.map { sanitised($0) }.joined(separator: " ")
        var sentence = "Run the coding agent '\(sanitised(id))': \(argvRendering)"
        if let projectDirectory {
            sentence += " in " + sanitised(projectDirectory)
        }
        sentence +=
            ". The spoken task has nowhere to go: this agent's command carries no "
            + KnownAgentPresets.taskPlaceholder
            + " placeholder to fill. The call will be refused."
        return sentence
    }

    /// The refusal sentence for a placeholder in the row's argv with no spoken task supplied —
    /// reachable only by a hand-built invocation, since the surface refuses earlier.
    ///
    /// The argv still renders verbatim — the unsubstituted placeholder is visible, which is
    /// the honest account of a call that cannot run — and the sentence says the call will be
    /// refused.
    static func taskTextMissingSentence(
        id: String,
        executablePath: String,
        arguments: [String],
        projectDirectory: String?
    ) -> String {
        let argvRendering = arguments.isEmpty
            ? sanitised(executablePath)
            : sanitised(executablePath) + " " + arguments.map { sanitised($0) }.joined(separator: " ")
        var sentence = "Run the coding agent '\(sanitised(id))': \(argvRendering)"
        if let projectDirectory {
            sentence += " in " + sanitised(projectDirectory)
        }
        sentence +=
            ". This agent's command carries a " + KnownAgentPresets.taskPlaceholder
            + " placeholder, but no task text was supplied to fill it. The call will be refused."
        return sentence
    }

    /// The refusal sentence for a spoken task over the 4096-UTF-8-byte bound — refused, never
    /// truncated (the ``arguments`` precedent: a truncated task is a different task,
    /// silently).
    ///
    /// The argv still renders, and the oversized text itself is never rendered — the dialog
    /// stays bounded.
    static func taskTextTooLargeSentence(
        id: String,
        executablePath: String,
        arguments: [String],
        projectDirectory: String?
    ) -> String {
        let argvRendering = arguments.isEmpty
            ? sanitised(executablePath)
            : sanitised(executablePath) + " " + arguments.map { sanitised($0) }.joined(separator: " ")
        var sentence = "Run the coding agent '\(sanitised(id))': \(argvRendering)"
        if let projectDirectory {
            sentence += " in " + sanitised(projectDirectory)
        }
        sentence += ". The spoken task is too large for Vocca to carry. The call will be refused."
        return sentence
    }

    // MARK: - The task substitution

    /// Whether the row's argv contains at least one literal
    /// ``KnownAgentPresets/taskPlaceholder`` occurrence — the check that decides between
    /// substitution and the two placeholder-shaped refusals.
    ///
    /// Public because the wirings decide on it too (`utterance-threading`): the intent leg
    /// enriches exactly a row whose argv carries the placeholder, and the surface arm
    /// refuses exactly one — one rule, judged in one place.
    public static func argumentsContainPlaceholder(_ arguments: [String]) -> Bool {
        arguments.contains { $0.contains(KnownAgentPresets.taskPlaceholder) }
    }

    /// The pure substitution rule: **every** literal ``KnownAgentPresets/taskPlaceholder``
    /// occurrence in the row's argv replaced with the task text — the deterministic rule
    /// pinned by the two-placeholder acceptance.
    ///
    /// Foundation-free by construction (this file imports nothing): the split and join are
    /// the standard library's own, and `omittingEmptySubsequences: false` is the load-bearing
    /// half — a split that dropped empty subsequences would collapse an adjacent pair
    /// (`<task><task>`) into one substitution, silently changing the argv.
    static func substitutedArguments(arguments: [String], taskText: String) -> [String] {
        arguments.map { element in
            element
                .split(
                    separator: KnownAgentPresets.taskPlaceholder,
                    omittingEmptySubsequences: false)
                .joined(separator: taskText)
        }
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