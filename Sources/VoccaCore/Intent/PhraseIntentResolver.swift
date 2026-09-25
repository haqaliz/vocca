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

/// One user-authored phrase-to-tool row of ``PhraseIntentResolver``'s table
/// (`phrase-intent-resolver` PRD R1).
///
/// Three identifiers and nothing else: **no arguments** — a row names a no-arg tool, the same
/// shape-only posture as `action-config.json` — and no enablement, which is the caller's
/// catalog, never the table. Rows come from the user's `intent-phrases.json` through the
/// store in `VoccaActions`; Core only ever sees the decoded values.
public struct PhraseIntentRow: Sendable, Equatable {

    /// The spoken phrase that matches this row, compared after
    /// ``PhraseIntentResolver/normalized(_:)``.
    public let phrase: String

    /// The provider the matched tool belongs to.
    public let providerID: String

    /// The tool within that provider.
    public let toolID: String

    /// - Parameters:
    ///   - phrase: The spoken phrase that matches this row.
    ///   - providerID: The provider the matched tool belongs to.
    ///   - toolID: The tool within that provider.
    public init(phrase: String, providerID: String, toolID: String) {
        self.phrase = phrase
        self.providerID = providerID
        self.toolID = toolID
    }
}

/// The exact-phrase ``IntentResolver`` (`phrase-intent-resolver` PRD R2; `phrase-resolver` spec
/// acceptance 1-9) — the seam's second real classifier, and the user's tuning path: a phrase
/// the user wrote resolves to the tool the user named, and nothing else does.
///
/// ## How an utterance is matched
///
/// The utterance and every row's phrase pass through ``normalized(_:)`` — lowercased, every run
/// of characters that are neither letters nor digits collapsed to one space, trimmed. The
/// **first** row in table order whose normalized phrase equals the normalized utterance *and*
/// whose tool is in the caller's catalog resolves to ``IntentResolution/toolCall(_:)`` with no
/// arguments. Anything else is ``IntentResolution/none``.
///
/// ## Never asks
///
/// There is no confidence gradient in an equality, so this resolver never returns
/// ``IntentResolution/ask(question:)``. Its brittleness — "clear audit log" is not "clear the
/// audit log" — fails to *nothing* (the reply generator's echo), never to a wrong tool.
///
/// ## The safety posture
///
/// The same as the seam's: the catalog is the enablement and is never read here, so a row
/// whose tool is not enabled is inert and the resolver never invents a tool. A resolved call is
/// a `.toolCall` like any other — it reaches the gate withheld, and an outward-facing tool
/// always confirms (`EscapeValveTests`). Foundation-free, so the empty import allow-list
/// (`CoreBoundaryTests.swift:116`) holds.
public struct PhraseIntentResolver: IntentResolver {

    /// The table, in the order it was supplied — read-only, so a caller can count what a
    /// composed resolver was actually built over (the probe's `intentShellRows`).
    public let rows: [PhraseIntentRow]

    /// The rows' normalized phrases, index-aligned with ``rows`` — computed once, at
    /// construction.
    private let normalizedPhrases: [String]

    /// - Parameter rows: The phrase table, in priority order: the first matching row wins.
    public init(rows: [PhraseIntentRow]) {
        self.rows = rows
        self.normalizedPhrases = rows.map { Self.normalized($0.phrase) }
    }

    /// Exact normalized resolution per the type documentation.
    public func resolve(
        _ utterance: String, against catalog: [ToolReference]
    ) -> IntentResolution {
        let key = Self.normalized(utterance)
        guard !key.isEmpty else { return .none }

        for (index, row) in rows.enumerated() where normalizedPhrases[index] == key {
            guard
                catalog.contains(where: {
                    $0.providerID == row.providerID && $0.toolID == row.toolID
                })
            else { continue }
            guard
                let invocation = ActionInvocation(
                    providerID: row.providerID, toolID: row.toolID, arguments: nil)
            else { continue }
            return .toolCall(invocation)
        }
        return .none
    }

    /// The one normalization a phrase and an utterance are compared under — public so the
    /// phrase store's empty and duplicate checks use exactly this, and the store and the
    /// resolver cannot disagree about what a phrase is.
    ///
    /// Lowercases letters, keeps letters and digits, and collapses every other run of
    /// characters to a single space; no leading or trailing space. `"A--b  C!"` → `"a b c"`,
    /// `"!!!"` → `""`.
    public static func normalized(_ text: String) -> String {
        var result = ""
        var pendingSeparator = false
        for ch in text {
            if ch.isLetter || ch.isNumber {
                if pendingSeparator && !result.isEmpty { result.append(" ") }
                pendingSeparator = false
                result += ch.lowercased()
            } else {
                pendingSeparator = true
            }
        }
        return result
    }
}
