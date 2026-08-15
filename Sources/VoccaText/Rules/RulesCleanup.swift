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

        // The protection class, computed once per call: a token containing any of `/ . - _ @` is
        // one unit, and this stage (like every stage) consults the same flags rather than its
        // own notion of the rule.
        let protected = Self.protectedFlags(for: entries)

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
            if !protected[index] {
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

        // The protection class, computed once per call (see `removeFillers`).
        let protected = Self.protectedFlags(for: entries)

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
            } else if !protected[index] {
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
    ///
    /// A terminal `.` is appended iff the trimmed end lacks `.`/`?`/`!` (never doubled — the
    /// B2 row 2); empty and whitespace-only input are identity (B11 rows 1–2). **No boundary is
    /// ever inserted without a signal** (Open question 6 — `we are late it is fine` is one
    /// sentence): boundaries exist only at spoken commands, literal tokens and end of input.
    public static func segmentAndTerminate(_ input: String) -> String {
        guard let last = Self.lastNonWhitespaceCharacter(of: input) else { return input }
        if last == "." || last == "?" || last == "!" {
            return input
        }
        return input + "."
    }

    /// Stage 4 — sentence-initial capitalization (`spec.md` B3).
    ///
    /// Uppercases the first letter of each sentence only — first-char, never a token rewrite
    /// (`i'm here` → `I'm here`); a caseless script's first letter is a no-op (B11's hostile
    /// rows); commas are not boundaries (`please pause, we are live` keeps `we` lowercase).
    ///
    /// Boundaries are `.`/`?`/`!` in **terminal position** — the last character of their token —
    /// and every `\n`; a `.` inside a token (`v2.4.1`) is not a boundary (B6 row 2 — `it` stays
    /// lowercase). The Open-question-8 split: a protected token at sentence start **is**
    /// first-char-capitalized except `@`-tokens, whose local part must not be rewritten
    /// (`aliz@vocca.dev` stays lowercase at sentence start; `My_repo` capitalizes — B6 row 5).
    public static func capitalizeSentences(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var output = ""
        var atSentenceStart = true
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            let nextIndex = input.index(after: index)
            if character == "\n"
                || ((character == "." || character == "?" || character == "!")
                    && Self.isTerminalInToken(character, at: index, in: input))
            {
                atSentenceStart = true
                output.append(character)
            } else if atSentenceStart, character.isLetter,
                !Self.tokenContains("@", in: input, from: index)
            {
                output.append(String(character).uppercased())
                atSentenceStart = false
            } else {
                output.append(character)
            }
            index = nextIndex
        }
        return output
    }

    /// Stage 5 — bounded number/unit normalization (`spec.md` B5).
    ///
    /// Bounded cardinals only, no decimals (`point` is out of the table — Open question 2):
    /// digit words `one`…`twenty`, tens `thirty`…`ninety`, `hundred`; compositions
    /// `[tens][ones]` sum (`twenty five` → `25`) and `[ones][hundred]` multiply
    /// (`one hundred` → `100`). Case-blind scan against explicit tables — no
    /// `Locale`/`NumberFormatter`/`String(format:)`, so the output is byte-identical across
    /// machines (the determinism claim). Units stay words (`forty percent` → `40 percent`,
    /// `twelve dollars` → `12 dollars` — symbol rendering is Open question 3), digits already
    /// present are unchanged (`build 42`), and nothing is rewritten inside a protected token.
    public static func normalizeNumbers(_ input: String) -> String {
        let (entries, trailing) = Self.tokenize(input)
        guard !entries.isEmpty else { return input }

        var output: [String] = []
        var changedAny = false
        var index = 0

        // The protection class, computed once per call (see `removeFillers`).
        let protected = Self.protectedFlags(for: entries)

        while index < entries.count {
            if let phrase = Self.numberPhrase(at: index, in: entries, protected: protected) {
                changedAny = true
                if !entries[index].leading.isEmpty {
                    output.append(String(entries[index].leading))
                }
                output.append(String(phrase.value))
                index += phrase.count
            } else {
                if !entries[index].leading.isEmpty {
                    output.append(String(entries[index].leading))
                }
                output.append(String(entries[index].word))
                index += 1
            }
        }

        guard changedAny else { return input }
        if !trailing.isEmpty {
            output.append(String(trailing))
        }
        return output.joined()
    }

    /// Stage 6 — user dictionary rules in declared order (`spec.md` B7, B8).
    ///
    /// **Order is the contract** (`ReplacementRule.swift:17-22`): a left-to-right scan; at each
    /// position the rules are tried in declared order; the **first match wins and consumes its
    /// span** — the scan resumes after the replacement, and replacement text is never re-scanned.
    /// `[("hello world", "hi"), ("world", "earth")]` on `"hello world today"` → `"hi today"`:
    /// the first rule consumes the phrase before the second sees it. No sorting, no dedup.
    ///
    /// The flags are read, not defined — their full semantics ship with `user-dictionary`
    /// (spec B2/B3): `caseSensitive: false` folds case on both sides; `wordBoundary: true` binds
    /// the match to word boundaries (`cat.` and `the cat` match, `catalog` does not — a word
    /// character is a letter or a digit). Built-ins run before the dictionary (`um twelve kawa`
    /// → `12 Kawa` — B7 row 2).
    public static func applyDictionary(_ input: String, rules: [ReplacementRule]) -> String {
        guard !rules.isEmpty else { return input }

        var output = ""
        var index = input.startIndex
        while index < input.endIndex {
            var matched = false
            for rule in rules {
                guard !rule.source.isEmpty else { continue }
                if let end = Self.dictionaryMatch(rule, in: input, from: index) {
                    output.append(rule.replacement)
                    index = end
                    matched = true
                    break
                }
            }
            if !matched {
                output.append(input[index])
                index = input.index(after: index)
            }
        }
        return output
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

    /// The protection class computed **once per call**: the per-entry flags every word-scanning
    /// stage consults, so the guarantee is one mechanism rather than each stage's own notion of
    /// the rule. `capitalizeSentences` consults the same predicate through its terminal-position
    /// boundary rule and `@`-token guard — a protected token's internal `.` is never terminal.
    private static func protectedFlags(
        for entries: [(leading: Substring, word: Substring)]
    ) -> [Bool] {
        entries.map { Self.isProtectedToken($0.word) }
    }

    /// The last non-whitespace character of the input, or `nil` when the input is empty or
    /// whitespace-only — the trimmed end `segmentAndTerminate` judges the terminal punctuation
    /// on. The appended period lands at the raw end, so the input's characters are never moved.
    private static func lastNonWhitespaceCharacter(of input: String) -> Character? {
        var index = input.endIndex
        while index > input.startIndex {
            index = input.index(before: index)
            if !input[index].isWhitespace {
                return input[index]
            }
        }
        return nil
    }

    /// Whether the character at `index` is the last character of its whitespace-delimited token
    /// — the terminal-position boundary rule: `done.` ends a sentence, the `.` inside `v2.4.1`
    /// does not.
    private static func isTerminalInToken(
        _ character: Character, at index: String.Index, in input: String
    ) -> Bool {
        let next = input.index(after: index)
        guard next < input.endIndex else { return true }
        return input[next].isWhitespace
    }

    /// Whether the whitespace-delimited token beginning at `start` contains `character` — the
    /// `@`-token guard capitalization consults before rewriting a sentence-initial letter.
    private static func tokenContains(
        _ character: Character, in input: String, from start: String.Index
    ) -> Bool {
        var index = start
        while index < input.endIndex {
            let current = input[index]
            if current.isWhitespace { return false }
            if current == character { return true }
            index = input.index(after: index)
        }
        return false
    }

    /// The bounded cardinal words `one`…`twenty`, including the teens — the B5 explicit table
    /// (`spec.md` B5, Open question 2: no `point`, no thousands).
    private static let onesTable: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20,
    ]

    /// The tens words — `twenty` plus `thirty`…`ninety` — the `[tens][ones]` composition's
    /// first leg (`twenty five` → `25`; a bare `twenty` still resolves through the ones table).
    private static let tensTable: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// The multiplier word — `[ones][hundred]` multiplies (`one hundred` → `100`).
    private static let hundredWords: Set<String> = ["hundred"]

    /// Whether the character is a word character for `wordBoundary` purposes — a letter or a
    /// digit; anything else (whitespace, punctuation, start/end of text) is a boundary.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Attempts to match `rule.source` at `start`, honouring the rule's `caseSensitive` and
    /// `wordBoundary` flags. Returns the index just past the match, or `nil`. A single
    /// character-by-character comparison — no regex, no Foundation — deterministic across
    /// machines.
    private static func dictionaryMatch(
        _ rule: ReplacementRule, in input: String, from start: String.Index
    ) -> String.Index? {
        var sourceIndex = rule.source.startIndex
        var inputIndex = start
        while sourceIndex < rule.source.endIndex {
            guard inputIndex < input.endIndex else { return nil }
            let sourceCharacter = rule.source[sourceIndex]
            let inputCharacter = input[inputIndex]
            let equal =
                rule.caseSensitive
                ? sourceCharacter == inputCharacter
                : sourceCharacter.lowercased() == inputCharacter.lowercased()
            guard equal else { return nil }
            sourceIndex = rule.source.index(after: sourceIndex)
            inputIndex = input.index(after: inputIndex)
        }
        if rule.wordBoundary {
            if start != input.startIndex, Self.isWordCharacter(input[input.index(before: start)]) {
                return nil
            }
            if inputIndex < input.endIndex, Self.isWordCharacter(input[inputIndex]) {
                return nil
            }
        }
        return inputIndex
    }

    /// Parses the longest bounded number phrase beginning at `index`: `[tens][ones]` sums,
    /// `[ones][hundred]` multiplies, both may combine (`one hundred twenty five` → `125`).
    /// Returns the value and the number of tokens it consumed, or `nil` when the token at
    /// `index` is not a number word. Never parses inside a protected token — the flags are the
    /// once-per-call protection class.
    private static func numberPhrase(
        at index: Int,
        in entries: [(leading: Substring, word: Substring)],
        protected: [Bool]
    ) -> (value: Int, count: Int)? {
        guard index < entries.count, !protected[index] else {
            return nil
        }
        let lower = { (offset: Int) -> String in
            String(entries[index + offset].word.lowercased())
        }

        var value = 0
        var count = 0

        // [ones][hundred]
        if let ones = Self.onesTable[lower(0)], index + 1 < entries.count,
            !protected[index + 1],
            Self.hundredWords.contains(lower(1))
        {
            value += ones * 100
            count = 2
        }
        // [tens][ones]?
        if index + count < entries.count, !protected[index + count],
            let tens = Self.tensTable[lower(count)]
        {
            value += tens
            count += 1
            if index + count < entries.count, !protected[index + count],
                let ones = Self.onesTable[lower(count)]
            {
                value += ones
                count += 1
            }
        } else if count == 0 {
            // A bare [ones] or [tens] word.
            if let ones = Self.onesTable[lower(0)] {
                value = ones
                count = 1
            } else if let tens = Self.tensTable[lower(0)] {
                value = tens
                count = 1
            }
        }

        guard count > 0 else { return nil }
        return (value, count)
    }
}
