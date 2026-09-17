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
import VoccaCore
import VoccaText
import XCTest

/// **R8 — the persisted per-mode selection shape**: `cleanup-config.json` grows one key,
/// `converseProvider`, carrying the same three raw strings as `provider` — which keeps its
/// spelling and its meaning, now explicitly the **dictate** half's selection (D1).
///
/// The file is the per-mode surface by design ("one file" doctrine): the choice is not a
/// `UserDefaults` key, and an old file (no `converseProvider`) decodes to converse `.rules`
/// **silently** — the converse default is the zero-network rung, and the dictate half is
/// byte-identical to today.
///
/// The one deliberate semantic change to the degrade policy: an invalid **selected converse**
/// block degrades **only** the converse selection to rules (loudly) while the dictate selection
/// stands — today's "invalid selected block ⇒ whole config to rules" still applies to the
/// dictate half, pinned unchanged (`CleanupConfigTests`).
final class CleanupConfigPerModeTests: XCTestCase {

    // MARK: - The shape

    /// **The draft carries a converse selection defaulting to rules.** The default is the
    /// zero-network rung — the G7 posture for anything a converse session says — and the two
    /// halves are independent fields: constructing one never touches the other.
    func testTheDraftCarriesAConverseSelectionDefaultingToRules() {
        XCTAssertEqual(
            CleanupConfigDraft(provider: .rules).converseProvider, .rules,
            "a draft that says nothing about conversations defaults to the zero-network rung")
        let draft = CleanupConfigDraft(provider: .ollama, converseProvider: .byok)
        XCTAssertEqual(draft.provider, .ollama, "the dictate half is untouched by the converse half")
        XCTAssertEqual(draft.converseProvider, .byok)
    }

    /// **The config itself carries the converse selection, defaulting to rules.**
    func testTheConfigCarriesAConverseSelectionDefaultingToRules() {
        XCTAssertEqual(CleanupConfig.defaultConfig.converseProvider, .rules)
    }

    /// **`encoded()` writes the `converseProvider` key** — the key's spelling is the file
    /// format, pinned as a literal, and the value is one of the three raw strings
    /// (`CleanupProviderKind.swift:33-39`).
    func testEncodedWritesTheConverseProviderKey() throws {
        let config = CleanupConfig(
            provider: .rules, converseProvider: .ollama, ollama: nil, byok: nil)

        let data = try config.encoded()
        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            document["converseProvider"] as? String, "ollama",
            "the key spelling and the raw value are the file's contract")
        XCTAssertTrue(
            String(decoding: data, as: UTF8.self).contains("\"converseProvider\""),
            "the literal key must appear in the written document")
    }

    // MARK: - The decode table (D1)

    /// **An old file (no `converseProvider`) decodes to converse `.rules` silently.**
    ///
    /// No migration: the dictate half is byte-identical to today, and the converse default is
    /// the zero-network rung — exactly what an absent key means.
    func testAnAbsentConverseProviderDecodesToRulesSilently() {
        let logs = LogCollector()
        let config = CleanupConfig.tolerantDecode(
            Data(#"{"provider":"rules"}"#.utf8), log: { logs.append($0) })

        XCTAssertEqual(config.provider, .rules)
        XCTAssertEqual(
            config.converseProvider, .rules,
            "an absent converse selection is the rules default")
        XCTAssertTrue(
            logs.entries.isEmpty,
            "the today-shape file must decode silently — an old file is not a mistake")
    }

    /// **An unknown `converseProvider` string decodes to converse `.rules` loudly**, and the
    /// dictate selection stands.
    func testAnUnknownConverseProviderDecodesToRulesLoudly() {
        let logs = LogCollector()
        let config = CleanupConfig.tolerantDecode(
            Data(#"{"provider":"ollama","ollama":{"endpoint":"http://localhost:11434","model":"llama3.1"},"converseProvider":"spaceship"}"#.utf8),
            log: { logs.append($0) })

        XCTAssertEqual(config.provider, .ollama, "the dictate selection stands")
        XCTAssertEqual(config.converseProvider, .rules)
        XCTAssertEqual(
            logs.entries.count, 1,
            "an unknown converse kind must emit exactly one loud log")
        XCTAssertTrue(
            logs.entries[0].contains("spaceship"),
            "the log names the string that was not understood")
    }

    /// **An invalid selected converse block degrades only the converse selection** — a
    /// `converseProvider: byok` with no dialable byok block lands on converse `.rules`, loudly,
    /// while the dictate `ollama` selection stands. Two independent selections cannot share one
    /// "invalid kills both" rule (D1).
    func testAnInvalidConverseBlockDecodesToRulesLoudlyWhileDictationStands() {
        let logs = LogCollector()
        let config = CleanupConfig.tolerantDecode(
            Data(#"{"provider":"ollama","ollama":{"endpoint":"http://localhost:11434","model":"llama3.1"},"converseProvider":"byok"}"#.utf8),
            log: { logs.append($0) })

        XCTAssertEqual(config.provider, .ollama, "the dictate half stands")
        XCTAssertEqual(config.converseProvider, .rules, "only the converse half degrades")
        XCTAssertEqual(logs.entries.count, 1, "one loud log for the one degraded selection")
    }

    /// **An invalid selected dictate block still degrades the whole config** — today's pinned
    /// rule, with both keys present. The pipeline's provider must stay rules; the safest
    /// converse answer is the same.
    func testAnInvalidDictationBlockStillDegradesTheWholeConfig() {
        let logs = LogCollector()
        let config = CleanupConfig.tolerantDecode(
            Data(#"{"provider":"ollama","converseProvider":"byok","ollama":{"endpoint":"http://localhost:11434"}}"#.utf8),
            log: { logs.append($0) })

        XCTAssertEqual(config.provider, .rules, "the dictate degrade rule is unchanged")
        XCTAssertEqual(config.converseProvider, .rules)
    }

    // MARK: - Round trips

    /// **A draft carrying distinct selections round-trips through the config.**
    func testTheDraftRoundTripsBothSelectionsThroughTheConfig() {
        let draft = CleanupConfigDraft(
            provider: .ollama, converseProvider: .byok,
            ollamaEndpoint: "http://localhost:11434", ollamaModel: "llama3.1",
            byokEndpoint: "https://api.example.com/v1", byokModel: "gpt-4o-mini")

        XCTAssertEqual(CleanupConfig(draft: draft).draft, draft)
    }

    /// **A blank converse block is not written at all** — a converse `ollama` selection with no
    /// model leaves no block on disk, and the file decodes back to the rules default (the
    /// blank-block rule, extended to the converse half).
    func testTheRoundTripPreservesABlankConverseBlock() throws {
        let draft = CleanupConfigDraft(
            provider: .rules, converseProvider: .ollama,
            ollamaEndpoint: "http://localhost:11434", ollamaModel: "")

        let config = CleanupConfig(draft: draft)
        XCTAssertNil(config.ollama, "a half-filled block is no block")

        let logs = LogCollector()
        let decoded = CleanupConfig.tolerantDecode(
            try config.encoded(), log: { logs.append($0) })
        XCTAssertEqual(
            decoded.converseProvider, .rules,
            "a converse selection whose block was never written decodes as rules")
    }
}