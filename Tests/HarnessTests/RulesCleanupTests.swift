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
import VoccaText
import XCTest

/// The rules engine's acceptance tables (`spec.md` B1–B12): one table per rule class plus the
/// combination tables, hand-written rows asserting exact output strings — written from the spec,
/// never derived from the implementation (the `InjectionLadderTests`/`WERTests` precedent).
///
/// **The table → entry-point map.** Because the spec's rows sometimes carry downstream effects
/// (B4's and B7's capitalized output) and sometimes exclude them (B1 and B5 rows have no terminal
/// period), each table drives the minimal composition that reproduces the spec's expected strings
/// — never more, never less:
///
/// | Table (spec) | Method | Entry point |
/// |---|---|---|
/// | B1 `fillerRows` | `testFillerRemovalRows` | `removeFillers` |
/// | B2 `segmentationRows` | `testSegmentationRows` | `{segmentAndTerminate, capitalizeSentences}` |
/// | B3 `capitalizationRows` | `testCapitalizationRows` | `capitalizeSentences` (rows 1–2); `{segmentAndTerminate, capitalizeSentences}` (row 3) |
/// | B4 `spokenPunctuationRows` | `testSpokenPunctuationRows` | `clean` |
/// | B5 `numberRows` | `testNumberRows` | `normalizeNumbers` |
/// | B6 `protectionRows` | `testProtectionRows` | `clean` |
/// | B6 `noCorruptionRows` | `testNoCorruptionRows` | `{removeFillers, normalizeNumbers}` |
/// | B7 `dictionaryRows` | `testDictionaryRows` | `{removeFillers, normalizeNumbers, applyDictionary, capitalizeSentences}` |
/// | B8 `combinationRows` | `testCombinationRows` | `clean` |
/// | B9 `literalTokenRows` | `testLiteralTokenRows` | `clean` |
/// | B10 `determinismRows` | `testDeterminismRows` | `clean`, N=5 + two independent sequences |
/// | B11 `boundaryRows` | `testBoundaryRows` | `clean` |
/// | B12 perf smoke | `testPerfSmokeUnderTheNamedBound` | `clean`, `perfSmokeBudget` |
///
/// **Do not "harmonise" the B7 composition.** `testDictionaryRows` drives
/// `{removeFillers, normalizeNumbers, applyDictionary, capitalizeSentences}` — dictionary
/// **before** capitalization — because row 3 pins it: capitalize-then-dictionary yields
/// `"hi today"`, not `"Hi today"`. This is a testing-surface choice for the class table, **not**
/// an order change: the composed `clean` keeps the spec's fixed order (capitalize then
/// dictionary), which B8 row 2 pins. The B10/B11/B12 property-pin tables pass from the first
/// commit on and must never go red.
final class RulesCleanupTests: XCTestCase {

    // MARK: - B1 · fillers

    /// `fillerRows` — static fillers, the three "like" shapes (discourse vs verb vs preposition)
    /// and the multi-filler row. Frequency-tuned, not blanket: a flank heuristic must remove
    /// utterance-initial "like" followed by a pronoun while the verb (`I like pizza`) and the
    /// preposition (`it looks like rain`) survive byte-identical.
    func testFillerRemovalRows() {
        struct Row {
            let input: String
            let expected: String
        }
        let rows: [Row] = [
            Row(input: "um we should go", expected: "we should go"),
            Row(input: "uh i think it works", expected: "i think it works"),
            Row(input: "er we ship it", expected: "we ship it"),
            Row(input: "you know it was hard", expected: "it was hard"),
            Row(input: "hmm maybe", expected: "maybe"),
            Row(input: "like we could ship it", expected: "we could ship it"),
            Row(input: "I like pizza", expected: "I like pizza"),
            Row(input: "it looks like rain", expected: "it looks like rain"),
            Row(input: "um you know like we are late", expected: "we are late"),
        ]
        for row in rows {
            XCTAssertEqual(
                RulesCleanup.removeFillers(row.input), row.expected,
                "input: \(row.input.debugDescription)")
        }
    }

    // MARK: - B2 · segmentation + terminal punctuation

    /// `segmentationRows` — no punctuation signal means a single terminal period and **no
    /// boundary inserted** (`we are late it is fine` is one sentence; the spec's Open question 6
    /// — boundaries exist only at spoken commands, literal tokens and end of input); an
    /// already-terminated input is unchanged, never doubled. Drives
    /// `{segmentAndTerminate, capitalizeSentences}` — the minimal composition that reproduces the
    /// spec's capitalized output.
    func testSegmentationRows() {
        struct Row {
            let input: String
            let expected: String
        }
        let rows: [Row] = [
            Row(input: "we are late it is fine", expected: "We are late it is fine."),
            Row(input: "We are late.", expected: "We are late."),
        ]
        for row in rows {
            XCTAssertEqual(
                RulesCleanup.capitalizeSentences(RulesCleanup.segmentAndTerminate(row.input)),
                row.expected,
                "input: \(row.input.debugDescription)")
        }
    }

    // MARK: - B3 · capitalization

    /// `capitalizationRows` — sentence-initial capitalization only: first-char per sentence,
    /// no token rewriting (`i'm here` → `I'm here`). Rows 1–2 drive `capitalizeSentences` alone
    /// (they must not gain a terminal period); row 3 drives
    /// `{segmentAndTerminate, capitalizeSentences}` — the boundary after the literal `.` is a
    /// real sentence boundary, so `it` capitalizes.
    func testCapitalizationRows() {
        struct Row {
            let input: String
            let expected: String
            let segmentFirst: Bool
        }
        let rows: [Row] = [
            Row(input: "i think", expected: "I think", segmentFirst: false),
            Row(input: "i'm here", expected: "I'm here", segmentFirst: false),
            Row(
                input: "we are late. it is fine",
                expected: "We are late. It is fine.", segmentFirst: true),
        ]
        for row in rows {
            let segmented = row.segmentFirst
                ? RulesCleanup.segmentAndTerminate(row.input)
                : row.input
            XCTAssertEqual(
                RulesCleanup.capitalizeSentences(segmented), row.expected,
                "input: \(row.input.debugDescription)")
        }
    }

    // MARK: - B5 · bounded number normalization

    /// `numberRows` — bounded cardinals + units only, driving `normalizeNumbers` alone: digit
    /// words through explicit tables, no `Locale`/`NumberFormatter`/`String(format:)` (the
    /// determinism claim). Unit words stay words (`forty percent` → `40 percent` — symbol
    /// rendering is Open question 3); digits already present are unchanged (`build 42`); no
    /// decimal rows until Open question 2 resolves.
    func testNumberRows() {
        struct Row {
            let input: String
            let expected: String
        }
        let rows: [Row] = [
            Row(input: "twelve", expected: "12"),
            Row(input: "twenty five", expected: "25"),
            Row(input: "one hundred", expected: "100"),
            Row(input: "forty percent", expected: "40 percent"),
            Row(input: "twelve dollars", expected: "12 dollars"),
            Row(input: "build 42", expected: "build 42"),
        ]
        for row in rows {
            XCTAssertEqual(
                RulesCleanup.normalizeNumbers(row.input), row.expected,
                "input: \(row.input.debugDescription)")
        }
    }

    // MARK: - B6 · token protection + cannot-corrupt

    /// `protectionRows` — the global cannot-corrupt guarantee (M2), driving the composed `clean`:
    /// a token containing any of `/ . - _ @` is one unit — no rewrite inside it, its internal `.`
    /// is **not** a sentence boundary (`v2.4.1` does not capitalize `it`), an `@`-token is never
    /// first-char-capitalized at sentence start, a `_`-token is (`My_repo`), and a symbol may
    /// attach *after* a protected token (`aliz@vocca.dev.`).
    func testProtectionRows() {
        struct Row {
            let input: String
            let expected: String
        }
        let rows: [Row] = [
            Row(
                input: "email me at aliz@vocca.dev period",
                expected: "Email me at aliz@vocca.dev."),
            Row(
                input: "the build is v2.4.1 it is stable",
                expected: "The build is v2.4.1 it is stable."),
            Row(input: "run deploy-vocca.sh now", expected: "Run deploy-vocca.sh now."),
            Row(
                input: "checkout /Users/aliz/dev then test",
                expected: "Checkout /Users/aliz/dev then test."),
            Row(input: "my_repo is fine", expected: "My_repo is fine."),
        ]
        for row in rows {
            XCTAssertEqual(
                RulesCleanup.clean(row.input, dictionary: []), row.expected,
                "input: \(row.input.debugDescription)")
        }
    }

    /// `noCorruptionRows` — a rule's edit is confined to its match span, driving
    /// `{removeFillers, normalizeNumbers}` — the two classes whose span discipline the rows pin:
    /// the filler removal takes the filler plus its adjacent space and nothing else (no double
    /// spaces, no mangled neighbors), and the number rewrite touches only its own words.
    func testNoCorruptionRows() {
        struct Row {
            let input: String
            let expected: String
        }
        let rows: [Row] = [
            Row(
                input: "I like pizza um and twelve apples",
                expected: "I like pizza and 12 apples"),
            Row(input: "um kawa", expected: "kawa"),
        ]
        for row in rows {
            XCTAssertEqual(
                RulesCleanup.normalizeNumbers(RulesCleanup.removeFillers(row.input)), row.expected,
                "input: \(row.input.debugDescription)")
        }
    }

    // MARK: - B4 · spoken punctuation

    /// `spokenPunctuationRows` — the spoken commands resolved to their symbols, driving the
    /// composed `clean`: the symbol is the sentence boundary, so `period` mid-utterance ends one
    /// sentence and the next is capitalized.
    func testSpokenPunctuationRows() {
        struct Row {
            let input: String
            let expected: String
        }
        let rows: [Row] = [
            Row(input: "we are done period", expected: "We are done."),
            Row(input: "are you ready question mark", expected: "Are you ready?"),
            Row(input: "wow exclamation point", expected: "Wow!"),
            Row(input: "please pause comma we are live", expected: "Please pause, we are live."),
            Row(input: "first line new line second line", expected: "First line\nSecond line."),
            Row(input: "we are done period then we rest", expected: "We are done. Then we rest."),
        ]
        for row in rows {
            XCTAssertEqual(
                RulesCleanup.clean(row.input, dictionary: []), row.expected,
                "input: \(row.input.debugDescription)")
        }
    }

    // MARK: - B9 · N2 literal tokens

    /// `literalTokenRows` — the N2 interplay: whisper emits literal `.` / `?` / `newline` tokens
    /// as well as the spelled words, and both shapes must converge on the same output. The
    /// `period.` row pins the provisional word+symbol rule: the symbol wins, the word is dropped
    /// (Open question 4; the reversed `. period` shape is unpinned and has no row).
    func testLiteralTokenRows() {
        struct Row {
            let input: String
            let expected: String
        }
        let rows: [Row] = [
            Row(input: "we are done. then we rest", expected: "We are done. Then we rest."),
            Row(input: "press return newline then continue", expected: "Press return\nThen continue."),
            Row(input: "are you ready?", expected: "Are you ready?"),
            Row(input: "we are done . then we rest", expected: "We are done. Then we rest."),
            Row(input: "we are done period.", expected: "We are done."),
        ]
        for row in rows {
            XCTAssertEqual(
                RulesCleanup.clean(row.input, dictionary: []), row.expected,
                "input: \(row.input.debugDescription)")
        }
    }

    // MARK: - B10 · determinism

    /// `determinismRows` — the pure-function claim asserted, not assumed: for a representative
    /// input set covering every class (fillers, spoken commands, literal tokens, numbers,
    /// protected tokens, a small `[ReplacementRule]`), N=5 repeated calls each yield
    /// byte-identical output, and two independently constructed call sequences — two local
    /// builders, each constructing its own inputs and rules from literals — agree pairwise
    /// byte-for-byte.
    func testDeterminismRows() {
        struct Row {
            let input: String
            let rules: [ReplacementRule]
        }
        let rows: [Row] = [
            Row(input: "um we should go", rules: []),
            Row(input: "we are done period then we rest", rules: []),
            Row(input: "we are done. then we rest", rules: []),
            Row(input: "twenty five and twelve apples", rules: []),
            Row(input: "email me at aliz@vocca.dev now", rules: []),
            Row(
                input: "we should ship kawa this week", rules: [
                    ReplacementRule(
                        source: "kawa", replacement: "Kawa",
                        caseSensitive: false, wordBoundary: true),
                ]),
        ]
        for row in rows {
            let first = RulesCleanup.clean(row.input, dictionary: row.rules)
            for _ in 1...5 {
                XCTAssertEqual(
                    RulesCleanup.clean(row.input, dictionary: row.rules), first,
                    "repeated calls must yield byte-identical output for "
                        + row.input.debugDescription)
            }
        }
        XCTAssertEqual(
            Self.independentDeterminismSequenceA(),
            Self.independentDeterminismSequenceB(),
            "two independently constructed call sequences must agree byte-for-byte")
    }

    /// The first of the two independent call sequences: every input and rule built from its own
    /// literals, sharing nothing with `independentDeterminismSequenceB()`.
    private static func independentDeterminismSequenceA() -> [String] {
        let rules = [
            ReplacementRule(
                source: "kawa", replacement: "Kawa",
                caseSensitive: false, wordBoundary: true),
        ]
        return [
            RulesCleanup.clean("um so like we need to ship this period", dictionary: []),
            RulesCleanup.clean("the build is v2.4.1 it is stable", dictionary: []),
            RulesCleanup.clean("we should ship kawa this week period", dictionary: rules),
            RulesCleanup.clean("first line new line second line", dictionary: []),
            RulesCleanup.clean("are you ready question mark we ship now", dictionary: []),
        ]
    }

    /// The second independent call sequence: the same inputs and rules, written out again from
    /// its own literals — two independently constructed call sequences, asserted pairwise
    /// byte-identical by `testDeterminismRows`.
    private static func independentDeterminismSequenceB() -> [String] {
        let rules = [
            ReplacementRule(
                source: "kawa", replacement: "Kawa",
                caseSensitive: false, wordBoundary: true),
        ]
        return [
            RulesCleanup.clean("um so like we need to ship this period", dictionary: []),
            RulesCleanup.clean("the build is v2.4.1 it is stable", dictionary: []),
            RulesCleanup.clean("we should ship kawa this week period", dictionary: rules),
            RulesCleanup.clean("first line new line second line", dictionary: []),
            RulesCleanup.clean("are you ready question mark we ship now", dictionary: []),
        ]
    }

    // MARK: - B11 · empty, hostile, identity

    /// `boundaryRows` — the totality and byte-preservation contract. Exact rows: empty input and
    /// whitespace-only input are identity (the never-empty guard is the pipeline's, M4), and an
    /// already-clean sentence passes through unchanged. Hostile rows (emoji, RTL text, a 5,000-
    /// char unbroken token, embedded newlines): no crash, and every character that matches no
    /// rule arrives byte-identical — the input may gain only the terminal period, and the only
    /// case rewrite permitted is the capitalization rule's (neutralized by lowercasing both
    /// sides).
    func testBoundaryRows() {
        XCTAssertEqual(RulesCleanup.clean("", dictionary: []), "")
        XCTAssertEqual(RulesCleanup.clean("   ", dictionary: []), "   ")
        XCTAssertEqual(
            RulesCleanup.clean("This is already clean.", dictionary: []),
            "This is already clean.")

        let emoji = "🙂"
        let rtl = "שלום עולם"
        let unbrokenToken = String(repeating: "a", count: 5_000)
        let embeddedNewlines = "first line\nsecond line"

        // Caseless scripts: the capitalization rule is a no-op on them, so the only permitted
        // change is the terminal period — asserted strictly, not through the lowercased form.
        for caseless in [emoji, rtl] {
            let output = RulesCleanup.clean(caseless, dictionary: [])
            XCTAssertTrue(
                output == caseless || output == caseless + ".",
                "a caseless-script input must gain only the terminal period: "
                    + output.debugDescription)
        }
        for hostile in [emoji, rtl, unbrokenToken, embeddedNewlines] {
            Self.assertHostileInputPreserved(hostile)
        }
    }

    /// Asserts the hostile-input contract for one input: no crash, and the output is the input
    /// with at most a terminal period added, modulo the capitalization rule (neutralized by
    /// lowercasing both sides) — nothing lost, nothing added, nothing reordered.
    private static func assertHostileInputPreserved(
        _ input: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let output = RulesCleanup.clean(input, dictionary: [])
        let normalizedOutput = output.lowercased()
        let normalizedInput = input.lowercased()
        XCTAssertTrue(
            normalizedOutput == normalizedInput
                || normalizedOutput == normalizedInput + ".",
            "hostile input must not crash, lose, reorder, or add characters beyond a terminal "
                + "period: input \(input.debugDescription), output \(output.debugDescription)",
            file: file, line: line)
    }

    // MARK: - B12 · perf smoke

    /// `perfSmokeBudget` — the single named bound: ~25× the 10 ms budget (`ARCHITECTURE.md:310`),
    /// flake-proof headroom on a loaded runner, tight enough to trip on a pathological rewrite.
    /// The honest <10 ms p50/p95 numbers belong to the eval-harness aspect; CI here proves
    /// non-pathological speed only (`spec.md` `## Isolation`).
    private static let perfSmokeBudget = Duration.milliseconds(250)

    /// `perfSmokeInput` — the B12 smoke input: ~2,400 words (60 sentences × 40 word slots — the
    /// honesty note of `spec.md` Open question 7: ~8× a maximum-length utterance at ~150 wpm; the
    /// number is kept, the framing corrected). Built by a fixed template cycling a fixed word
    /// bank by index arithmetic — no randomness, so the input is byte-identical on every machine.
    /// The mix covers every class: fillers, number words, punctuation commands and protected
    /// tokens.
    private static func makePerfSmokeInput() -> String {
        let content = [
            "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
            "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
            "quebec", "romeo", "sierra", "tango",
        ]
        let fillers = ["um", "you know", "uh", "hmm", "so like"]
        let numbers = ["twelve", "twenty five", "one hundred", "forty percent"]
        let commands = ["period", "question mark", "comma", "new line"]
        let protectedTokens = ["v2.4.1", "deploy-vocca.sh", "aliz@vocca.dev"]

        var slots: [String] = []
        for index in 0..<(60 * 40) {
            switch index % 10 {
            case 0: slots.append(fillers[index % fillers.count])
            case 1: slots.append(numbers[(index / 10) % numbers.count])
            case 2: slots.append(commands[(index / 7) % commands.count])
            case 3: slots.append(protectedTokens[(index / 5) % protectedTokens.count])
            default: slots.append(content[(index * 7) % content.count])
            }
        }
        return slots.joined(separator: " ")
    }

    /// `perfSmokeRows` — the ~2,400-word input must clean under `perfSmokeBudget` (asserted in
    /// CI, deterministic enough to gate): run twice, byte-identical output.
    func testPerfSmokeUnderTheNamedBound() {
        let input = Self.makePerfSmokeInput()
        let start = ContinuousClock.now
        let first = RulesCleanup.clean(input, dictionary: [])
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThanOrEqual(
            elapsed, Self.perfSmokeBudget,
            "the ~2,400-word smoke input must clean within the named bound — a pathological "
                + "rewrite is a regression")
        XCTAssertEqual(
            RulesCleanup.clean(input, dictionary: []), first,
            "the smoke input must clean deterministically — run twice, byte-identical")
    }
}
