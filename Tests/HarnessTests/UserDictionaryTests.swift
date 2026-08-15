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
import Synchronization
import VoccaCore
import VoccaText
import XCTest

/// The user dictionary's semantics as data — the `user-dictionary` aspect's B1–B4, written
/// before the store exists (`spec.md` Acceptance criteria, `plan_20260815.md` Phase 1). Failing
/// to compile is the red state: no `FileSystemDictionaryStore` is in scope yet.
///
/// **The applier here is a test fixture, not shipped code.** Rule application is `rules-engine`'s
/// M2 (`spec.md:50-51`), which owns the shipped `RulesCleanup`; this file's one job is to pin
/// the reference semantics M2 must satisfy: declared order is application order, each rule
/// re-scans the whole current text — including every earlier rule's output, which is what
/// chained application means — and the two flags mean what the seam says they mean.
///
/// Two discipline decisions from the spec's open questions, closed in the plan (`§1.1`): case
/// folding is plain `String.lowercased()` — locale-independent, never `localizedStandard*` —
/// and the word-boundary set is the explicit literal `" \t\n\r.,;:!?()[]{}\"'"` plus
/// start-of-text and end-of-text, table-tested, never `CharacterSet` heuristics that drift.
final class UserDictionaryTests: XCTestCase {

    // MARK: - The fixture applier (B1–B3)

    /// Applies the rules in declared order, each re-scanning the whole current text — the
    /// reference semantics the shipped rules engine (M2) must satisfy. Never reorders, never
    /// deduplicates.
    private static func apply(_ rules: [ReplacementRule], to text: String) -> String {
        var result = text
        for rule in rules {
            result = applying(rule, to: result)
        }
        return result
    }

    /// One rule over one text: every non-overlapping match replaced, scanning left to right,
    /// never re-scanning a replaced region with the same rule.
    private static func applying(_ rule: ReplacementRule, to text: String) -> String {
        guard !rule.source.isEmpty else { return text }
        var result = text
        var scan = result.startIndex
        while scan < result.endIndex {
            guard
                let match = match(
                    of: rule.source, in: result, from: scan, caseSensitive: rule.caseSensitive)
            else {
                break
            }
            if rule.wordBoundary && !isOnWordBoundary(match, in: result) {
                scan = result.index(after: match.lowerBound)
                continue
            }
            result.replaceSubrange(match, with: rule.replacement)
            scan = result.index(
                match.lowerBound, offsetBy: rule.replacement.count, limitedBy: result.endIndex)
                ?? result.endIndex
        }
        return result
    }

    /// The next occurrence of `source` at or after `start`, or `nil`.
    ///
    /// A case-insensitive search folds the slice with plain `lowercased()` — the same fold the
    /// case-sensitivity decision is defined by (`plan_20260815.md` §1.1), on the same machine
    /// and every other.
    private static func match(
        of source: String, in text: String, from start: String.Index, caseSensitive: Bool
    ) -> Range<String.Index>? {
        var cursor = start
        while cursor < text.endIndex {
            let end = text.index(cursor, offsetBy: source.count, limitedBy: text.endIndex)
                ?? text.endIndex
            let slice = text[cursor..<end]
            if caseSensitive ? slice == source : slice.lowercased() == source.lowercased() {
                return cursor..<end
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    /// The explicit word-boundary set: whitespace, punctuation, and the two quoted forms.
    ///
    /// Deliberately a literal — the spec's open question (`spec.md:151`), closed as an explicit,
    /// small set, never `CharacterSet` heuristics that drift between OS releases.
    private static let boundaryCharacters = Set(" \t\n\r.,;:!?()[]{}\"'")

    /// `true` when the match sits on a word boundary: the characters on both edges are outside
    /// the word (`boundaryCharacters`), or the match starts or ends the text.
    private static func isOnWordBoundary(_ range: Range<String.Index>, in text: String) -> Bool {
        let left = range.lowerBound == text.startIndex
            || boundaryCharacters.contains(text[text.index(before: range.lowerBound)])
        let right = range.upperBound == text.endIndex
            || boundaryCharacters.contains(text[range.upperBound])
        return left && right
    }

    // MARK: - B1 · declared order is application order

    /// The spec's pair, both directions: `[("mcp" → "MCP"), ("mcp server" → "MCP server")]` and
    /// the reverse, over the input "mcp server" — each run must equal the human-applied chain
    /// for that declared order, and the same order must be deterministic.
    func testDeclaredOrderIsApplicationOrder() {
        let mcp = ReplacementRule(
            source: "mcp", replacement: "MCP", caseSensitive: false, wordBoundary: true)
        let server = ReplacementRule(
            source: "mcp server", replacement: "MCP server", caseSensitive: false,
            wordBoundary: true)

        XCTAssertEqual(Self.apply([mcp, server], to: "mcp server"), "MCP server")
        XCTAssertEqual(Self.apply([server, mcp], to: "mcp server"), "MCP server")
        XCTAssertEqual(
            Self.apply([mcp, server], to: "mcp server"),
            Self.apply([mcp, server], to: "mcp server"),
            "the same declared order must be deterministic — order is never a sorting or dedup artifact")
    }

    /// **The load-bearing half of B1**: the later rule's source is the earlier rule's output.
    ///
    /// Forward `[("gonna" → "going to"), ("going to" → "go to")]` on "gonna" yields "go to";
    /// the reverse yields "going to" — the two orders differ visibly, so order is carried by the
    /// data, not assumed away.
    func testALaterRuleReReplacesAnEarlierRulesOutputRegion() {
        let gonna = ReplacementRule(
            source: "gonna", replacement: "going to", caseSensitive: true, wordBoundary: true)
        let goingTo = ReplacementRule(
            source: "going to", replacement: "go to", caseSensitive: true, wordBoundary: true)

        XCTAssertEqual(Self.apply([gonna, goingTo], to: "gonna"), "go to")
        XCTAssertEqual(Self.apply([goingTo, gonna], to: "gonna"), "going to")
    }

    // MARK: - B2 · caseSensitive

    /// `caseSensitive: false` matches "kawa", "Kawa" and "KAWA"; `caseSensitive: true` matches
    /// only the exact casing the rule declares.
    func testCaseSensitiveOffMatchesAnyCasingAndOnMatchesExact() {
        let rule = ReplacementRule(
            source: "kawa", replacement: "Kawa", caseSensitive: false, wordBoundary: true)
        XCTAssertEqual(Self.apply([rule], to: "kawa"), "Kawa")
        XCTAssertEqual(Self.apply([rule], to: "Kawa"), "Kawa")
        XCTAssertEqual(Self.apply([rule], to: "KAWA"), "Kawa")

        let exact = ReplacementRule(
            source: "kawa", replacement: "Kawa", caseSensitive: true, wordBoundary: true)
        XCTAssertEqual(Self.apply([exact], to: "kawa"), "Kawa")
        XCTAssertEqual(Self.apply([exact], to: "Kawa"), "Kawa")
        XCTAssertEqual(Self.apply([exact], to: "KAWA"), "KAWA")
    }

    /// Case folding is plain `lowercased()`, which folds accented forms too — and deliberately
    /// not locale-dependent: the same fold on every machine, whatever the user's region.
    func testCaseFoldingIsUnicodeAware() {
        let rule = ReplacementRule(
            source: "café", replacement: "CAFÉ", caseSensitive: false, wordBoundary: true)
        XCTAssertEqual(Self.apply([rule], to: "CAFÉ"), "CAFÉ")
        XCTAssertEqual(Self.apply([rule], to: "Café"), "CAFÉ")
    }

    // MARK: - B3 · wordBoundary

    /// `wordBoundary: true` keeps "cat" out of "catalog" but matches "cat" bounded by
    /// whitespace or punctuation — "cat." and "the cat," — and start-of-text "cat";
    /// `wordBoundary: false` matches inside words.
    func testWordBoundaryOnPreventsMatchesInsideWordsAndOffAllowsThem() {
        let bounded = ReplacementRule(
            source: "cat", replacement: "dog", caseSensitive: true, wordBoundary: true)
        XCTAssertEqual(Self.apply([bounded], to: "catalog"), "catalog")
        XCTAssertEqual(Self.apply([bounded], to: "cat."), "dog.")
        XCTAssertEqual(Self.apply([bounded], to: "the cat,"), "the dog,")
        XCTAssertEqual(Self.apply([bounded], to: "cat"), "dog")

        let inside = ReplacementRule(
            source: "cat", replacement: "dog", caseSensitive: true, wordBoundary: false)
        XCTAssertEqual(Self.apply([inside], to: "catalog"), "dogalog")
    }

    // MARK: - B4 · JSON round-trip

    /// The type-level round-trip: an ordered array of three rules with mixed flags is exactly
    /// identical through `JSONEncoder`/`JSONDecoder` — order, `caseSensitive` and `wordBoundary`
    /// included (Foundation is legal in the test target; the mirror of the seam's own B5 test).
    func testJsonRoundTripPreservesOrderAndBothFlags() throws {
        let rules = [
            ReplacementRule(
                source: "mcp", replacement: "MCP", caseSensitive: false, wordBoundary: true),
            ReplacementRule(
                source: "gonna", replacement: "going to", caseSensitive: true, wordBoundary: false),
            ReplacementRule(
                source: "café", replacement: "CAFÉ", caseSensitive: false, wordBoundary: false),
        ]

        let data = try JSONEncoder().encode(rules)
        let decoded = try JSONDecoder().decode([ReplacementRule].self, from: data)

        XCTAssertEqual(
            decoded, rules,
            "order, caseSensitive and wordBoundary must round-trip exactly")
    }

    /// The store's own code path: the exact encode/decode pair `save`/`load` use, driven
    /// directly — the identical array back, no logs emitted.
    func testJsonRoundTripThroughTheStoresEncoderAndDecoder() throws {
        let rules = [
            ReplacementRule(
                source: "mcp", replacement: "MCP", caseSensitive: false, wordBoundary: true),
            ReplacementRule(
                source: "gonna", replacement: "going to", caseSensitive: true, wordBoundary: false),
            ReplacementRule(
                source: "café", replacement: "CAFÉ", caseSensitive: false, wordBoundary: false),
        ]

        let data = try FileSystemDictionaryStore.encode(rules)
        let logs = LogCollector()
        let decoded = FileSystemDictionaryStore.decode(data) { logs.append($0) }

        XCTAssertEqual(decoded, rules)
        XCTAssertTrue(logs.entries.isEmpty, "a clean round-trip must not log")
    }

    /// Forward compatibility (`spec.md:141-144`): an unknown key on a rule is stock
    /// `JSONDecoder` behavior — ignored, with all four known fields intact, and no log. The file
    /// is user-owned; reading it must not depend on the writer having been this store.
    func testUnknownFieldsAreToleratedOnLoad() {
        let json = """
            [{"source": "mcp", "replacement": "MCP", "caseSensitive": false, "wordBoundary": true, "notes": "a field this store does not know"}]
            """
        let logs = LogCollector()
        let decoded = FileSystemDictionaryStore.decode(Data(json.utf8)) { logs.append($0) }

        XCTAssertEqual(
            decoded,
            [ReplacementRule(
                source: "mcp", replacement: "MCP", caseSensitive: false, wordBoundary: true)])
        XCTAssertTrue(logs.entries.isEmpty, "an unknown key is not a corrupt entry")
    }
}
