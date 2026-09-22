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

/// One seeded phrase-to-tool row of ``KeywordIntentResolver``'s synonym table (R2, R8).
///
/// The table is **code-level this slice**: a Core constant, Foundation-free, test-pinned
/// (`IntentSeamBoundaryTests` asserts the shipped rows verbatim, so a retune is a reviewed
/// edit). The user-editable tuning path is S1's phrase table; day-one retuning of a wrong seed
/// is a reviewed code edit until S1 lands, and the unit record says so.
///
/// `arguments`, when present, is JSON text the resolver carries into the invocation it builds —
/// the same "text Core admits it cannot validate" posture as ``ActionInvocation``. A row may
/// substitute the *whole cleaned utterance* into its JSON text by writing the placeholder
/// ``KeywordIntentResolver/utterancePlaceholder`` (`{{utterance}}`) inside it; `nil` is the
/// honest answer for a no-arg tool (the audit tools take none). An invocation whose arguments
/// would exceed ``ActionInvocation/maximumArgumentsUTF8Bytes`` is refused, never truncated.
public struct KeywordSynonym: Sendable, Equatable {

    /// The spoken phrase that matches this row — e.g. `"clear the audit log"`.
    public let phrase: String

    /// The provider the matched tool belongs to.
    public let providerID: String

    /// The tool within that provider.
    public let toolID: String

    /// The JSON text the resolution carries, or `nil` for a no-arg tool. May contain
    /// ``KeywordIntentResolver/utterancePlaceholder``.
    public let arguments: String?

    /// - Parameters:
    ///   - phrase: The spoken phrase that matches this row.
    ///   - providerID: The provider the matched tool belongs to.
    ///   - toolID: The tool within that provider.
    ///   - arguments: JSON text the resolution carries, or `nil` for a no-arg tool.
    public init(phrase: String, providerID: String, toolID: String, arguments: String? = nil) {
        self.phrase = phrase
        self.providerID = providerID
        self.toolID = toolID
        self.arguments = arguments
    }
}

/// The deterministic, token-scored ``IntentResolver`` (`intent-layer` PRD R2; `intent-seam` spec
/// acceptance 1-4) — the first real classifier over the enabled-tool catalog.
///
/// ## How an utterance is matched
///
/// The cleaned utterance is lowercased and split into tokens; stop words are dropped. Each tool
/// in the provided catalog is scored as **matched tokens ÷ candidate tokens**, where a tool's
/// candidates are the tokens of its `displayName`, its `toolID`, and every seeded synonym phrase
/// targeting it. A top score at or above ``notConfidentThreshold`` is a confident match →
/// ``IntentResolution/toolCall(_:)``; a non-zero top score below it is not confident →
/// ``IntentResolution/ask(question:)`` naming the resolver's own top candidates (≤ 3, in
/// deterministic score-then-lexical order); a zero top score is ``IntentResolution/none``. Empty
/// and whitespace-only utterances are ``IntentResolution/none`` before any scoring.
///
/// ## The safety posture
///
/// The resolver **never invents a tool the catalog does not name** (acceptance 4): a seed row's
/// target is inert unless the caller's catalog supplies it, and the invocation it builds always
/// names a catalog tool. Its *wrong-but-confident* failures are bounded by the gate, not by the
/// classifier (R8). And the whole thing is Foundation-free — the empty import allow-list
/// (`CoreBoundaryTests.swift:116`) holds.
///
/// The seeds and the threshold are the founder's invention until SMOKE 148-150 runs (R8): the
/// PRD claims no resolution rate, and retuning is a reviewed edit to ``shippedSynonyms``.
public struct KeywordIntentResolver: IntentResolver {

    /// The not-confident threshold: a top score below this resolves to
    /// ``IntentResolution/ask(question:)`` rather than a tool call. Seeded and documented; real
    /// resolution accuracy is env-gated, never CI-measurable (the ASR-WER precedent).
    public static let notConfidentThreshold = 0.75

    /// The placeholder a row's ``KeywordSynonym/arguments`` may use to carry the whole cleaned
    /// utterance into its JSON text.
    public static let utterancePlaceholder = "{{utterance}}"

    /// The shipped synonym table (R8): the two audit rows the persona runs on, plus an
    /// args-carrying MCP-style row so the arguments path and its bound are real. **Pinned
    /// verbatim** by `IntentSeamBoundaryTests` — a retune is a reviewed edit.
    public static let shippedSynonyms: [KeywordSynonym] = [
        KeywordSynonym(
            phrase: "clear the audit log", providerID: "dev.vocca.audit", toolID: "audit.clear"),
        KeywordSynonym(
            phrase: "count the audit log", providerID: "dev.vocca.audit", toolID: "audit.count"),
        KeywordSynonym(
            phrase: "post a message", providerID: "dev.vocca.mcp.chat", toolID: "post_message",
            arguments: #"{"text": "{{utterance}}"}"#),
    ]

    /// The stop words dropped from both sides of a match. Deliberately short and ordinary — "the
    /// audit log" is meant to match "count the audit log", so the words that only glue speech are
    /// the ones removed, never the ones that name tools.
    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "at", "but", "by", "can", "did", "do", "does", "for", "from",
        "i", "in", "is", "it", "me", "my", "of", "on", "or", "please", "so", "the", "then",
        "this", "that", "to", "we", "with", "you",
    ]

    private let synonyms: [KeywordSynonym]
    private let threshold: Double

    /// - Parameters:
    ///   - synonyms: The synonym table to match against. Defaults to ``shippedSynonyms``.
    ///   - threshold: The not-confident threshold. Defaults to ``notConfidentThreshold``. Both
    ///     parameters are injectable so a test can plant a wrong row or a boundary threshold —
    ///     the shipped resolver uses the seeded defaults.
    public init(
        synonyms: [KeywordSynonym] = KeywordIntentResolver.shippedSynonyms,
        threshold: Double = KeywordIntentResolver.notConfidentThreshold
    ) {
        self.synonyms = synonyms
        self.threshold = threshold
    }

    /// Token-scored resolution per the type documentation.
    public func resolve(
        _ utterance: String, against catalog: [ToolReference]
    ) -> IntentResolution {
        guard utterance.contains(where: { !$0.isWhitespace }) else { return .none }
        let utteranceTokens = Set(Self.tokens(in: utterance)).subtracting(Self.stopWords)
        guard !utteranceTokens.isEmpty else { return .none }

        var ranked: [(tool: ToolReference, score: Double)] = []
        for tool in catalog where !tool.providerID.isEmpty && !tool.toolID.isEmpty {
            let candidates = candidateTokens(for: tool)
            guard !candidates.isEmpty else { continue }
            let matched = utteranceTokens.intersection(candidates).count
            let score = Double(matched) / Double(candidates.count)
            ranked.append((tool: tool, score: score))
        }

        ranked.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.tool.providerID != b.tool.providerID {
                return a.tool.providerID < b.tool.providerID
            }
            return a.tool.toolID < b.tool.toolID
        }

        guard let top = ranked.first else { return .none }

        if top.score >= threshold {
            let arguments = self.arguments(for: top.tool, utterance: utterance)
            if let invocation = ActionInvocation(
                providerID: top.tool.providerID, toolID: top.tool.toolID, arguments: arguments
            ) {
                return .toolCall(invocation)
            }
            // Refused — the arguments would exceed the 4 KB bound, or an identifier was empty.
            // Never truncated: truncated arguments are a different action (`ActionInvocation`).
            return .none
        }

        let candidates = ranked.filter { $0.score > 0 }
            .prefix(3)
            .map { Self.name(of: $0.tool) }
        guard !candidates.isEmpty else { return .none }
        return .ask(question: Self.question(naming: candidates))
    }

    // MARK: - Matching

    /// The candidate tokens of a catalog tool: its display name, its id, and every seeded phrase
    /// targeting it, stop words removed. A wrong synonym planted on a tool *dilutes* it — its
    /// candidate set grows, so a wrong phrase can no longer out-score the tool whose own identity
    /// tokens are fully matched.
    private func candidateTokens(for tool: ToolReference) -> Set<String> {
        var tokens: Set<String> = []
        tokens.formUnion(Self.tokens(in: tool.displayName))
        tokens.formUnion(Self.tokens(in: tool.toolID))
        for row in synonyms where row.providerID == tool.providerID && row.toolID == tool.toolID {
            tokens.formUnion(Self.tokens(in: row.phrase))
        }
        tokens.subtract(Self.stopWords)
        return tokens
    }

    /// The arguments a matched tool carries: the first seeded row targeting it, its JSON text
    /// built over the utterance — or `nil` for a no-arg tool. `first(where:)` is deterministic:
    /// the table is ordered, and a second row for one tool would be a reviewed edit.
    private func arguments(for tool: ToolReference, utterance: String) -> String? {
        guard let row = synonyms.first(where: {
            $0.providerID == tool.providerID && $0.toolID == tool.toolID
        }) else { return nil }
        guard let template = row.arguments else { return nil }
        return Self.builtArguments(from: template, utterance: utterance)
    }

    private static func builtArguments(from template: String, utterance: String) -> String {
        guard template.contains(Self.utterancePlaceholder) else { return template }
        return Self.substituting(
            Self.utterancePlaceholder, with: Self.jsonEscaped(Self.whitespaceStripped(utterance)),
            in: template)
    }

    // MARK: - The ask path

    private static func name(of tool: ToolReference) -> String {
        tool.displayName.isEmpty ? "\(tool.providerID)/\(tool.toolID)" : tool.displayName
    }

    /// The deterministic question over the resolver's own top candidates (S2's exact copy is a
    /// later review; this is the bounded, deterministic shape the seam promises).
    private static func question(naming candidates: [String]) -> String {
        switch candidates.count {
        case 0:
            return "I didn't catch that — try again?"
        case 1:
            return "Did you mean '\(candidates[0])'?"
        case 2:
            return "Did you mean '\(candidates[0])' or '\(candidates[1])'?"
        default:
            return "Did you mean '\(candidates[0])', '\(candidates[1])' or '\(candidates[2])'?"
        }
    }

    // MARK: - Foundation-free text

    /// Lowercases and splits a string into word tokens on anything that is not a letter or digit,
    /// splitting camelCase boundaries too (`postMessage` → `post`, `message`).
    private static func tokens(in text: String) -> [String] {
        var words: [String] = []
        var current: [Character] = []
        var previous: Character?
        for ch in text {
            if ch.isLetter || ch.isNumber {
                if let prev = previous, prev.isLetter, prev.isLowercase, ch.isLetter,
                    ch.isUppercase, !current.isEmpty
                {
                    words.append(String(current))
                    current = []
                }
                current.append(ch)
            } else {
                if !current.isEmpty {
                    words.append(String(current))
                    current = []
                }
            }
            previous = ch
        }
        if !current.isEmpty { words.append(String(current)) }
        return words.map { $0.lowercased() }
    }

    private static func whitespaceStripped(_ text: String) -> String {
        var chars = Array(text)
        while let first = chars.first, first.isWhitespace { chars.removeFirst() }
        while let last = chars.last, last.isWhitespace { chars.removeLast() }
        return String(chars)
    }

    /// Escapes a string for embedding inside a JSON string literal — `VoccaCore` has no
    /// Foundation `JSONSerialization` to lean on, and the resolver's claim is only ever "text the
    /// provider will parse" (`ActionInvocation`'s admitted limit), never "validated JSON".
    private static func jsonEscaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x0C: result += "\\f"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0x00..<0x20:
                result += "\\u{" + Self.hexString(scalar.value) + "}"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func hexString(_ value: UInt32) -> String {
        let digits = Array("0123456789abcdef")
        var result = ""
        var remaining = value
        repeat {
            result.insert(digits[Int(remaining % 16)], at: result.startIndex)
            remaining /= 16
        } while remaining > 0
        return result
    }

    /// A Foundation-free replace-all of one substring with another.
    private static func substituting(
        _ needle: String, with replacement: String, in template: String
    ) -> String {
        let pattern = Array(needle)
        let source = Array(template)
        var result = ""
        var index = 0
        while index < source.count {
            if index + pattern.count <= source.count,
                Array(source[index..<(index + pattern.count)]) == pattern
            {
                result += replacement
                index += pattern.count
            } else {
                result.append(source[index])
                index += 1
            }
        }
        return result
    }
}