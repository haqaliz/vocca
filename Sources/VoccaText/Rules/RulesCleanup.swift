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

import VoccaCore

/// The deterministic rules engine (`ARCHITECTURE.md:511`): a pure function over
/// `(String, [ReplacementRule]) -> String` — filler removal, sentence segmentation and terminal
/// punctuation, capitalization, spoken-punctuation commands, number/unit normalization, then user
/// dictionary rules in declared order. Pure means table-driven tests (`RulesCleanupTests`).
///
/// The engine is deliberately **not** a `CleanupProvider` conformance: it is the pure function the
/// conformer (`ShippingCleanup`, pipeline-wiring's M6) composes the seam's context down to. It
/// reads `String`/`[ReplacementRule]` only — no IO, no clock, no network, no randomness; every
/// stage returns a new `String` and never mutates its input. Output is byte-identical across
/// machines and process invocations: explicit tables only, no `Locale`, no `NumberFormatter`, no
/// `String(format:)` (`spec.md` `## Isolation`).
///
/// The adapter shape follows `VoccaAudio`'s precedent (the seam-owned-vocabulary enum), and the
/// module-move precedent the boundary suite documents (`ModuleBoundaryTests`): VoccaText imports
/// `VoccaCore` and nothing else — beyond it, stdlib only.
public enum RulesCleanup {
    /// The composed pipeline, signature per `ARCHITECTURE.md:511`.
    ///
    /// The six stages run in the fixed order declared below. The order deliberately reorders
    /// `ARCHITECTURE.md`'s listing: the spoken-command stage must produce its symbols *before*
    /// segmentation so the boundary exists (`spec.md` `## In scope` 2); the observable order of
    /// effects matches `ARCHITECTURE.md:511`. The dictionary arrives in declared order
    /// (`ReplacementRule` — order is the contract) and runs after the built-ins.
    public static func clean(_ input: String, dictionary: [ReplacementRule]) -> String {
        var text = removeFillers(input)
        text = resolveSpokenCommands(text)
        text = segmentAndTerminate(text)
        text = capitalizeSentences(text)
        text = normalizeNumbers(text)
        text = applyDictionary(text, rules: dictionary)
        return text
    }

    /// Stage 1 — filler removal, frequency-tuned rather than blanket (`spec.md` B1).
    ///
    /// Static fillers (`um`, `uh`, `er`, `hmm`, the two-word unit `you know`) are removed
    /// wherever they appear; **`like`** is removed iff utterance-initial (or preceded by a
    /// boundary symbol, or a position vacated by an earlier removal this pass) **and** followed
    /// by a pronoun — the discourse marker, not the verb (`I like pizza`) or the preposition
    /// (`it looks like rain`); **`so`** (provisional, pinned only by B8 row 1) is removed iff
    /// sentence-initial and followed by a filler or a pronoun — `so that we can`, `I think so`
    /// and `and so on` survive because none is sentence-initial plus pronoun/filler.
    ///
    /// The cannot-corrupt rule (I5): a removal takes the filler span plus exactly one adjacent
    /// whitespace run — the preceding one if present, else the following — never both, never two
    /// spaces (`("pizza um and" → "pizza and")`, `("um kawa" → "kawa")`, pinned by the B6
    /// `noCorruptionRows`). Whitespace-only input is identity (B11 row 2 — never trimmed), and
    /// nothing is rewritten inside a protected token (a token containing `/ . - _ @` is one unit).
    public static func removeFillers(_ input: String) -> String {
        let (entries, trailing) = Self.tokenize(input)
        guard !entries.isEmpty else { return input }

        let pronouns: Set<String> = ["i", "you", "he", "she", "we", "they", "it"]
        let staticFillers: Set<String> = ["um", "uh", "er", "hmm"]
        let fillerFlankWords: Set<String> = ["um", "uh", "er", "hmm", "you", "like"]

        var output: [Substring] = []
        var consumeNextLeading = false
        var removedAny = false
        var index = 0

        /// `true` when the edited text so far is empty or ends with a sentence boundary —
        /// the "preceded by utterance start, a boundary symbol, or a position vacated by an
        /// earlier removal" flank (earlier removals mean `output` reflects the edited text).
        func isSentenceInitial() -> Bool {
            guard let last = output.last, let lastCharacter = last.last else { return true }
            return lastCharacter == "." || lastCharacter == "?" || lastCharacter == "!"
                || lastCharacter == "\n"
        }

        while index < entries.count {
            let word = entries[index].word
            let lower = word.lowercased()
            let nextLower =
                index + 1 < entries.count ? entries[index + 1].word.lowercased() : ""

            var spanLength = 0
            if !Self.isProtectedToken(word) {
                if staticFillers.contains(lower) {
                    spanLength = 1
                } else if lower == "you", nextLower == "know" {
                    spanLength = 2
                } else if lower == "like", isSentenceInitial(), pronouns.contains(nextLower) {
                    spanLength = 1
                } else if lower == "so", isSentenceInitial(),
                    fillerFlankWords.contains(nextLower) || pronouns.contains(nextLower)
                {
                    spanLength = 1
                }
            }

            if spanLength > 0 {
                removedAny = true
                let effectiveLeading =
                    consumeNextLeading ? Substring() : entries[index].leading
                // A removal takes the span plus exactly one adjacent whitespace run: the
                // preceding one (mid-utterance), else the following one (start-context —
                // consumed here by flagging the next entry's leading as already gone).
                consumeNextLeading = effectiveLeading.isEmpty
                index += spanLength
            } else {
                if !consumeNextLeading, !entries[index].leading.isEmpty {
                    output.append(entries[index].leading)
                }
                consumeNextLeading = false
                output.append(word)
                index += 1
            }
        }

        guard removedAny else { return input }
        if !consumeNextLeading, !trailing.isEmpty {
            output.append(trailing)
        }
        return output.joined()
    }

    /// Stage 2 — spoken-punctuation commands resolved to their symbols, including N2 literal
    /// tokens (`spec.md` B4, B9): `period` → `.`, `question mark` → `?`, `exclamation point` →
    /// `!`, `comma` → `,`, `new line`/`newline` → `\n`. A literal `.`/`?` already-symbolic token
    /// is kept (attached — `done.` — or standalone — `we are done . then we rest`). Word and
    /// symbol both present (`period.`): the symbol wins, the word is dropped (provisional, B9
    /// row 5).
    ///
    /// Symbols left-attach: the command's own leading whitespace is consumed, and `\n` also
    /// consumes the following whitespace run (`First line\nSecond line.`), so a boundary lands
    /// exactly where the spoken command was. Exactly one adjacent space, never two. The
    /// provisional false-positive guard (Open question 5): a command word does not fire when the
    /// preceding word is a determiner (`the`/`a`/`an` — `the period of the sine wave` survives);
    /// and a command never fires inside a protected token (`/ . - _ @`), while a symbol may
    /// attach *after* one (`aliz@vocca.dev.` — B6 row 1).
    public static func resolveSpokenCommands(_ input: String) -> String {
        let (entries, trailing) = Self.tokenize(input)
        guard !entries.isEmpty else { return input }

        let determiners: Set<String> = ["the", "a", "an"]

        var output: [String] = []
        var consumeNextLeading = false
        var changedAny = false
        var index = 0

        /// The word the edited text so far ends with ("" at utterance start) — the determiner
        /// guard's subject: earlier replacements are visible, so the check reads the edited text.
        func previousWord() -> String {
            guard let last = output.last else { return "" }
            return last
        }

        while index < entries.count {
            let word = entries[index].word
            let lower = word.lowercased()
            let effectiveLeading = consumeNextLeading ? Substring() : entries[index].leading
            consumeNextLeading = false

            let precededByDeterminer = determiners.contains(previousWord().lowercased())

            var resolved: (symbol: String, span: Int, consumeFollowing: Bool)?
            if lower == "." || lower == "?" {
                // N2 standalone literal token: kept, left-attached to the previous word.
                resolved = (String(word), 1, false)
            } else if word.count > 1, word.last == ".",
                let symbol = Self.singleWordCommandSymbol(String(word.dropLast().lowercased())),
                !precededByDeterminer
            {
                // N2 word + symbol (`period.`): the symbol wins, the word is dropped.
                resolved = (symbol, 1, false)
            } else if !Self.isProtectedToken(word) {
                if lower == "question", index + 1 < entries.count,
                    entries[index + 1].word.lowercased() == "mark", !precededByDeterminer
                {
                    resolved = ("?", 2, false)
                } else if lower == "exclamation", index + 1 < entries.count,
                    entries[index + 1].word.lowercased() == "point", !precededByDeterminer
                {
                    resolved = ("!", 2, false)
                } else if lower == "new", index + 1 < entries.count,
                    entries[index + 1].word.lowercased() == "line", !precededByDeterminer
                {
                    resolved = ("\n", 2, true)
                } else if let symbol = Self.singleWordCommandSymbol(lower), !precededByDeterminer {
                    resolved = (symbol, 1, symbol == "\n")
                }
            }

            if let resolved {
                changedAny = true
                output.append(resolved.symbol)
                consumeNextLeading = resolved.consumeFollowing
                index += resolved.span
            } else {
                if !effectiveLeading.isEmpty {
                    output.append(String(effectiveLeading))
                }
                output.append(String(word))
                index += 1
            }
        }

        guard changedAny else { return input }
        if !consumeNextLeading, !trailing.isEmpty {
            output.append(String(trailing))
        }
        return output.joined()
    }

    /// The single-word spoken-punctuation commands (multi-word phrases are matched by the scan
    /// itself). Returns the command's symbol or `nil` when the word is not a command.
    private static func singleWordCommandSymbol(_ lower: String) -> String? {
        switch lower {
        case "period": return "."
        case "comma": return ","
        case "newline": return "\n"
        default: return nil
        }
    }

    /// Stage 3 — sentence segmentation and terminal punctuation (`spec.md` B2).
    public static func segmentAndTerminate(_ input: String) -> String {
        input
    }

    /// Stage 4 — sentence-initial capitalization (`spec.md` B3).
    public static func capitalizeSentences(_ input: String) -> String {
        input
    }

    /// Stage 5 — bounded number/unit normalization (`spec.md` B5).
    public static func normalizeNumbers(_ input: String) -> String {
        input
    }

    /// Stage 6 — user dictionary rules in declared order (`spec.md` B7, B8).
    public static func applyDictionary(_ input: String, rules: [ReplacementRule]) -> String {
        input
    }

    /// Splits the input into whitespace-delimited word entries, each carrying the whitespace run
    /// that precedes it, plus the trailing whitespace run (empty when the input ends on a word).
    /// Deterministic: word and whitespace boundaries only — no locale, no trimming.
    private static func tokenize(_ input: String) -> (entries: [(leading: Substring, word: Substring)], trailing: Substring) {
        var entries: [(leading: Substring, word: Substring)] = []
        var index = input.startIndex
        var trailingStart = input.startIndex
        while index < input.endIndex {
            let leadingStart = index
            while index < input.endIndex, input[index].isWhitespace {
                index = input.index(after: index)
            }
            let leadingEnd = index
            let wordStart = index
            while index < input.endIndex, !input[index].isWhitespace {
                index = input.index(after: index)
            }
            if wordStart != index {
                entries.append((input[leadingStart..<leadingEnd], input[wordStart..<index]))
                trailingStart = index
            }
        }
        return (entries, input[trailingStart..<input.endIndex])
    }

    /// The M2 cannot-corrupt guarantee, one mechanism: a token containing any of `/ . - _ @`
    /// (URLs, paths, code identifiers, email addresses) is one unit — no stage rewrites inside
    /// it, its internal `.` is never a sentence boundary, and only the Open-question-8
    /// first-character rules apply at sentence start.
    private static func isProtectedToken(_ token: Substring) -> Bool {
        token.contains("/") || token.contains(".")
            || token.contains("-") || token.contains("_") || token.contains("@")
    }
}
