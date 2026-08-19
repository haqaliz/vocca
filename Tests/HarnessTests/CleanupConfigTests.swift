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
import VoccaText
import XCTest

/// The cleanup config's decode contract (spec B1–B2): the hand-edited `cleanup-config.json`
/// shape (`prd.md` M7) — `provider: rules|ollama|byok`, an Ollama block of endpoint/model, a
/// BYOK block of endpoint/optional-model — read tolerantly, never throwing, with every invalid
/// block degrading to the rules provider plus one loud log.
///
/// Tolerant decode is the `FileSystemDictionaryStore.decode` precedent (`DictionaryStoreTests`):
/// untyped `JSONSerialization` reads, unknown keys ignored by construction, and exactly one
/// injected-log call per invalid block — so the zero-network default (absent file, absent
/// provider) is silent and every hand-edit mistake is loud, never silently different from the
/// file (`spec.md:51-55`).
final class CleanupConfigTests: XCTestCase {

    // MARK: - B1: kind round-trip

    /// **B1 — the three kinds round-trip through JSON and their raw values are pinned.** The
    /// file is hand-edited, so the raw strings are the contract: `rules`, `ollama`, `byok`.
    func testTheProviderKindsRoundTripThroughJsonWithPinnedRawValues() throws {
        for kind in [CleanupProviderKind.rules, .ollama, .byok] {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(CleanupProviderKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
        XCTAssertEqual(CleanupProviderKind.rules.rawValue, "rules")
        XCTAssertEqual(CleanupProviderKind.ollama.rawValue, "ollama")
        XCTAssertEqual(CleanupProviderKind.byok.rawValue, "byok")
    }

    /// **B1 — an unknown kind string skips with one loud log.** A hand-edited provider name the
    /// product does not know is a mistake to be told about, not silently reset
    /// (`spec.md:51-55`).
    func testAnUnknownKindStringDegradesToRulesWithALoudLog() {
        let logs = LogCollector()
        let config = CleanupConfig.tolerantDecode(
            Data(#"{"provider":"claude"}"#.utf8), log: { logs.append($0) })

        XCTAssertEqual(config.provider, .rules)
        XCTAssertEqual(
            logs.entries.count, 1,
            "an unknown kind must emit exactly one loud log")
    }

    // MARK: - B2: the decode table

    /// **B2 — a valid full config decodes to its fields, unknown keys tolerated, no log.** The
    /// `extraKey` rides along ignored — a future settings surface may add keys before this
    /// aspect's consumer knows them.
    func testAValidFullConfigDecodesWithUnknownKeysTolerated() {
        let json = """
            {
              "provider": "ollama",
              "ollama": {"endpoint": "http://localhost:11434", "model": "llama3.1"},
              "byok": {"endpoint": "https://api.example.com/v1/chat/completions", "model": "gpt-4o-mini"},
              "extraKey": true
            }
            """
        let logs = LogCollector()
        let config = CleanupConfig.tolerantDecode(Data(json.utf8), log: { logs.append($0) })

        XCTAssertEqual(config.provider, .ollama)
        XCTAssertEqual(config.ollama?.endpoint, "http://localhost:11434")
        XCTAssertEqual(config.ollama?.model, "llama3.1")
        XCTAssertEqual(config.byok?.endpoint, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(config.byok?.model, "gpt-4o-mini")
        XCTAssertTrue(
            logs.entries.isEmpty,
            "a valid config must decode silently")
    }

    /// **B2 — a `rules` config with only unknown keys decodes silently.** The rules provider
    /// needs no block; anything extra is ignored.
    func testARulesConfigWithUnknownKeysDecodesSilently() {
        let json = #"{"provider":"rules","mystery":{"a":1}}"#
        let logs = LogCollector()
        let config = CleanupConfig.tolerantDecode(Data(json.utf8), log: { logs.append($0) })

        XCTAssertEqual(config.provider, .rules)
        XCTAssertTrue(logs.entries.isEmpty)
    }

    /// **B2 — `ollama` without a `model` is invalid and loud.** No model, no call — the block
    /// degrades to rules with one loud log (`spec.md:40-41`).
    func testAnOllamaBlockWithoutAModelIsInvalidAndLoud() {
        let json = #"{"provider":"ollama","ollama":{"endpoint":"http://localhost:11434"}}"#
        let logs = LogCollector()
        let config = CleanupConfig.tolerantDecode(Data(json.utf8), log: { logs.append($0) })

        XCTAssertEqual(config.provider, .rules)
        XCTAssertNil(config.ollama)
        XCTAssertEqual(logs.entries.count, 1)
    }

    /// **B2 — `byok` without an `endpoint` is invalid and loud.** A BYOK block names where the
    /// text goes; without it the block degrades to rules with one loud log.
    func testAByokBlockWithoutAnEndpointIsInvalidAndLoud() {
        let json = #"{"provider":"byok","byok":{"model":"gpt-4o-mini"}}"#
        let logs = LogCollector()
        let config = CleanupConfig.tolerantDecode(Data(json.utf8), log: { logs.append($0) })

        XCTAssertEqual(config.provider, .rules)
        XCTAssertNil(config.byok)
        XCTAssertEqual(logs.entries.count, 1)
    }

    /// **B2 — a wrong-typed field is invalid and loud.** `model` as a number is not a model; the
    /// whole block degrades to rules.
    func testAWrongTypedFieldIsInvalidAndLoud() {
        let json = #"{"provider":"ollama","ollama":{"endpoint":"http://localhost:11434","model":42}}"#
        let logs = LogCollector()
        let config = CleanupConfig.tolerantDecode(Data(json.utf8), log: { logs.append($0) })

        XCTAssertEqual(config.provider, .rules)
        XCTAssertEqual(logs.entries.count, 1)
    }

    /// **B2 — an endpoint that is not a URL is invalid and loud.** A hand-edited endpoint that
    /// cannot be dialed is a mistake to be told about; the block degrades to rules.
    func testANonUrlEndpointIsInvalidAndLoud() {
        let json = #"{"provider":"byok","byok":{"endpoint":"not a url","model":"gpt-4o-mini"}}"#
        let logs = LogCollector()
        let config = CleanupConfig.tolerantDecode(Data(json.utf8), log: { logs.append($0) })

        XCTAssertEqual(config.provider, .rules)
        XCTAssertEqual(logs.entries.count, 1)
    }

    /// **B2 — decode never throws.** A non-object top level, a JSON array, a string, garbage —
    /// each degrades to the rules default (loud for garbage, silent for a valid-but-wrong
    /// shape is the store's contract; here every path returns the default).
    func testTolerantDecodeNeverThrows() {
        let inputs = [Data("not json".utf8), Data(#"[]"#.utf8), Data(#""str""#.utf8)]
        for input in inputs {
            let logs = LogCollector()
            let config = CleanupConfig.tolerantDecode(input, log: { logs.append($0) })
            XCTAssertEqual(config.provider, .rules)
        }
    }
}
