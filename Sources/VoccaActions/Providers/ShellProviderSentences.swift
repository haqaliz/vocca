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

/// The argv-derived sentence machinery of ``ShellProvider`` (`shell-provider` PRD R3) —
/// the resolution and rendering shared by `describe` and `invoke`, kept out of the
/// conformance so that the file that owes its Family-A rows owes only those rows.
///
/// ## The sentence is derived from the argv, never authored prose
///
/// The founder decision, stated where the machinery lives: a confirmation shows the command
/// name, the argv with supplied parameter values substituted in place, the `key = value`
/// value renderings (keys sorted, values sanitised — the `MCPProvider` discipline), and the
/// author's optional clause appended **last**, sanitised. A planted argv appears verbatim in
/// the sentence, and a misleading clause cannot hide it: the card confirms what actually
/// runs, not what the author wrote about it.
///
/// ## Everything that reaches a dialog line is sanitised
///
/// The command id, every argv element, every supplied value and the clause are all
/// untrusted text rendered into a safety dialog. A newline inside any of them would let it
/// forge a new line of the dialog it appears in — the cheapest way to make a confirmation
/// say something nobody wrote. The rule is exactly ``MCPProvider``'s: control characters
/// below `0x20` and `0x7F` become spaces.
///
/// ## The resolution the invoke path shares
///
/// The invocation's argument text is JSON the provider must validate against the command's
/// declared parameter slots: every declared parameter must be supplied, every supplied key
/// must be declared, and every value must be a JSON string — the argv is a string array,
/// and a value with no honest string spelling is a value the command could not honestly run
/// with. Anything else is ``ShellParameterResolution/unreadable``, and the caller renders a
/// refusal that keeps the command's own radius — never a de-escalation, which is a
/// de-escalation however it is arrived at.
public enum ShellProviderSentences {

    /// How an invocation's argument text reads against a command's declared parameters.
    enum ShellParameterResolution {
        /// The text is not a JSON object, a declared parameter is missing or not a string,
        /// or a key names no declared parameter. The command cannot honestly run.
        case unreadable

        /// Every declared parameter has a string value, keyed by display name.
        case resolved([String: String])
    }

    // MARK: - Sentences

    /// The concrete sentence for a resolved invocation: the command name, the argv with the
    /// supplied values rendered in place of their slot markers, the `key = value` renderings
    /// (sorted, sanitised) and the author's clause appended last — the clause can describe,
    /// never hide.
    ///
    /// The argv renders **raw**, with the slot markers still in it, and the marker positions
    /// render the supplied values quoted — so the sentence states what would actually run
    /// without pretending the quoting is part of the argv.
    static func sentence(
        id: String,
        argv: [String],
        parameters: [ShellCommandParameter],
        values: [String: String],
        clause: String?
    ) -> String {
        let markers = parameters.enumerated().map { index, _ in "$\(index + 1)" }
        let renderedArgv = argv.map { element in
            guard let index = markers.firstIndex(of: element) else { return sanitised(element) }
            return renderedValue(values[parameters[index].name] ?? element)
        }.joined(separator: " ")
        let pairs = values.keys.sorted()
            .map { key in "\(sanitised(key)) = \(renderedValue(values[key] ?? ""))" }
            .joined(separator: ", ")
        var sentence = "Run the shell command '\(sanitised(id))': " + renderedArgv
        if !pairs.isEmpty {
            sentence += "; " + pairs
        }
        sentence += "."
        if let clause, !clause.isEmpty {
            sentence += " " + sanitised(clause)
        }
        return sentence
    }

    /// The refusal sentence for an invocation whose parameters could not be resolved.
    ///
    /// The argv still renders — a person asked to approve a refusal of a destructive command
    /// should still see what would have run — and the sentence says the call will be refused.
    /// The clause does not appear: the call will not happen, so there is nothing for the
    /// author's description to describe.
    static func refusalSentence(id: String, argv: [String]) -> String {
        let argvRendering = argv.isEmpty
            ? ""
            : ": " + argv.map { sanitised($0) }.joined(separator: " ")
        return "Run the shell command '\(sanitised(id))'\(argvRendering). "
            + "Vocca could not resolve the parameters for this command. The call will be refused."
    }

    /// The refusal sentence for a command the registry never declared. Nothing will happen.
    static func unknownCommandSentence(toolID: String) -> String {
        "Vocca's shell provider does not serve the command '\(sanitised(toolID))'. "
            + "Nothing will happen."
    }

    // MARK: - Reading the invocation

    /// The invocation's argument text as a validated map of parameter display name to
    /// supplied value, or ``ShellParameterResolution/unreadable``.
    ///
    /// `nil` argument text is an empty object — a call with no arguments. Text that is not
    /// JSON, or is JSON but not an object, is unreadable here and a named failure above.
    ///
    /// Validation is the whole point: `describe` must not render a value that `invoke` would
    /// drop, and `invoke` must not run an argv whose sentence showed something else.
    static func resolve(arguments text: String?, parameters: [ShellCommandParameter])
        -> ShellParameterResolution
    {
        let members: [String: JSONValue]
        if let text {
            guard case .object(let parsed)? = JSONValue.decode(Data(text.utf8)) else {
                return .unreadable
            }
            members = parsed
        } else {
            members = [:]
        }

        let declared = parameters.map(\.name)
        for name in declared {
            guard case .string = members[name] else { return .unreadable }
        }
        for (name, value) in members {
            guard declared.contains(name), case .string = value else { return .unreadable }
        }

        var values: [String: String] = [:]
        for name in declared {
            if case .string(let value)? = members[name] {
                values[name] = value
            }
        }
        return .resolved(values)
    }

    /// The argv that would actually run: the configured argv with each declared slot marker
    /// (`$1`, `$2`, …) replaced by its supplied value.
    ///
    /// `nil` when the command cannot honestly run: an empty argv (a shape only a direct
    /// constructor can produce — the registry refuses it), or a declared parameter whose
    /// marker never appears in the argv — a supplied value for it could never reach the
    /// child, so a sentence that rendered one would lie about what runs.
    static func substitutedArgv(_ command: ShellCommandDefinition, values: [String: String])
        -> [String]?
    {
        guard !command.command.isEmpty else { return nil }
        let markers = command.parameters.enumerated().map { index, _ in "$\(index + 1)" }
        for marker in markers where !command.command.contains(marker) { return nil }
        return command.command.map { element in
            guard let index = markers.firstIndex(of: element) else { return element }
            return values[command.parameters[index].name] ?? element
        }
    }

    // MARK: - Rendering

    /// One supplied value as a person should read it: quoted, sanitised.
    ///
    /// Every argv slot is a string, so every value renders the same way — the 
    /// ``MCPProvider`` string rendering, whole.
    static func renderedValue(_ value: String) -> String {
        "\"\(sanitised(value))\""
    }

    /// `text` with control characters replaced by spaces.
    ///
    /// The ``MCPProvider`` rule, copied exactly: everything rendered into the sentence comes
    /// from outside Vocca — the command id, the argv, the values, the clause — and a newline
    /// inside any of them would let it forge a new line of the dialog it appears in.
    static func sanitised(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.unicodeScalars.map { scalar in
                    scalar.value < 0x20 || scalar.value == 0x7F ? " " : scalar
                }))
    }
}