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

import VoccaActions
import XCTest

/// The known-agents catalog's pin suite (`agent-catalog` spec acceptance 1-4) — the
/// `KeywordSynonym` seed precedent, moved from the intent layer to the coding-agents surface.
///
/// ## Why a pin, not a read
///
/// The eight presets are **code-level seeds** (PRD R1, founder decision Q1): candidate binary
/// names and non-interactive argv templates that the Coding agents editor pre-fills. Vocca never
/// claims the CLI behaves as the template says — a template is a seed, and the copy says so. The
/// suite's job is to make a retune a **reviewed edit**: the count, the ids, the display names and
/// every argv template are pinned verbatim, exactly as ``KeywordIntentResolver/shippedSynonyms``
/// is pinned by `IntentSeamBoundaryTests`, so a wrong template cannot land silently.
///
/// ## The placeholder contract
///
/// `<task>` is a literal string the editor pre-fills and the user may edit; this slice never
/// substitutes it (N1 stays deferred). Every shipped template carries **exactly one** occurrence,
/// and ``KnownAgentPresets/taskPlaceholder`` is pinned so the authoring aspect pre-fills the same
/// spelling the pins watch.
///
/// ## The pure-data half
///
/// The catalog is pure data: it names no transport family (the
/// ``ActionTransportProhibitionTests`` detector, run against the shipped file itself — the lint
/// stays green) and no `FileManager` spelling, and it imports nothing — not even Foundation
/// (`Sendable` needs none of it).
final class KnownAgentPresetsTests: XCTestCase {

    // MARK: - Acceptance 1 — exactly eight presets, ids and display names pinned

    /// The closed set: exactly eight presets, in the shipped order, with ids and display names
    /// pinned verbatim. An added, removed or renamed preset is a reviewed edit — the count pin
    /// and the row pin together are what make it one.
    func testTheCatalogHoldsExactlyEightPresetsWithPinnedIDsAndDisplayNames() {
        let expected: [KnownAgentPreset] = [
            KnownAgentPreset(
                id: "claude", displayName: "Claude", candidateNames: ["claude"],
                arguments: ["-p", "<task>"]),
            KnownAgentPreset(
                id: "codex", displayName: "Codex", candidateNames: ["codex"],
                arguments: ["exec", "<task>"]),
            KnownAgentPreset(
                id: "gemini", displayName: "Gemini", candidateNames: ["gemini"],
                arguments: ["-p", "<task>"]),
            KnownAgentPreset(
                id: "opencode", displayName: "OpenCode", candidateNames: ["opencode"],
                arguments: ["run", "<task>"]),
            KnownAgentPreset(
                id: "aider", displayName: "Aider", candidateNames: ["aider"],
                arguments: ["--message", "<task>"]),
            KnownAgentPreset(
                id: "cursor", displayName: "Cursor", candidateNames: ["cursor"],
                arguments: ["run", "<task>"]),
            KnownAgentPreset(
                id: "q", displayName: "Amazon Q", candidateNames: ["q"],
                arguments: ["-p", "<task>"]),
            KnownAgentPreset(
                id: "crush", displayName: "Crush", candidateNames: ["crush"],
                arguments: ["run", "<task>"]),
        ]

        XCTAssertEqual(
            KnownAgentPresets.all, expected,
            "the known-agents catalog must match its pin — retuning a preset is a reviewed edit, "
                + "and the pin is what makes it one")
        XCTAssertEqual(
            KnownAgentPresets.all.count, 8,
            "a ninth preset is a reviewed widening, not a silent addition")
    }

    /// The ids are the enablement surface's vocabulary — a duplicate would make two rows
    /// indistinguishable.
    func testEveryPresetIDIsUnique() {
        let ids = KnownAgentPresets.all.map(\.id)
        XCTAssertEqual(
            Set(ids).count, ids.count,
            "preset ids must be unique — a duplicate id makes two presets indistinguishable on "
                + "the surface")
    }

    // MARK: - Acceptance 2 — argv templates pinned verbatim

    /// Each preset's argv template, pinned element by element — a changed flag, a reordered
    /// argument or a substituted placeholder fails here, not on a user's machine.
    func testEveryArgvTemplateIsPinnedVerbatim() {
        let expected: [String: [String]] = [
            "claude": ["-p", "<task>"],
            "codex": ["exec", "<task>"],
            "gemini": ["-p", "<task>"],
            "opencode": ["run", "<task>"],
            "aider": ["--message", "<task>"],
            "cursor": ["run", "<task>"],
            "q": ["-p", "<task>"],
            "crush": ["run", "<task>"],
        ]

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: KnownAgentPresets.all.map { ($0.id, $0.arguments) }),
            expected,
            "every argv template must match its pin verbatim — the templates are seeds, and the "
                + "pin is the record of the decision")
    }

    /// The negative control: a **wrong** template is caught by the same comparison the pin uses.
    ///
    /// A pin that has only ever seen the shipped values is a pin nobody has watched fail — each
    /// of the mutations below (a changed flag, a changed placeholder spelling, a dropped
    /// argument) must disagree with the shipped argv, which is what "a changed template fails
    /// loudly" means rather than hopes.
    func testAPlantedWrongTemplateFailsThePin() {
        let shipped = Dictionary(
            uniqueKeysWithValues: KnownAgentPresets.all.map { ($0.id, $0.arguments) })

        let planted: [String: [String]] = [
            "claude": ["--print", "<task>"],
            "codex": ["exec", "{{task}}"],
            "gemini": ["-p"],
            "opencode": ["run", "<task>", "--verbose"],
            "aider": ["-m", "<task>"],
            "cursor": ["<task>", "run"],
            "q": ["--prompt", "<task>"],
            "crush": ["exec", "<task>"],
        ]

        XCTAssertFalse(
            shipped == planted,
            "the pin must be able to fail — a planted wrong template must not equal the shipped "
                + "catalog, or the verbatim pin watches nothing")
        for (id, wrong) in planted {
            XCTAssertNotEqual(
                shipped[id], wrong,
                "the planted template for \(id) must disagree with the shipped one — otherwise "
                    + "the pin cannot catch a change to it")
        }
    }

    // MARK: - Acceptance 3 — candidate names

    /// Every preset carries at least one candidate binary name, and every name is non-empty and
    /// within the 64-character bound — the bound the detection aspect reads them under.
    func testEveryPresetCarriesAtLeastOneCandidateNameWithinBounds() {
        XCTAssertFalse(KnownAgentPresets.all.isEmpty)
        for preset in KnownAgentPresets.all {
            XCTAssertFalse(
                preset.candidateNames.isEmpty,
                "\(preset.id) must carry at least one candidate binary name — a preset with no "
                    + "candidate names is a row detection can never resolve")
            for name in preset.candidateNames {
                XCTAssertFalse(
                    name.isEmpty,
                    "\(preset.id) carries an empty candidate name — an empty name can never match "
                        + "a binary")
                XCTAssertLessThanOrEqual(
                    name.count, 64,
                    "\(preset.id)'s candidate name '\(name)' exceeds 64 characters — the bound "
                        + "the detection aspect reads under")
            }
        }
    }

    // MARK: - The placeholder contract

    /// Every template is non-empty and carries **exactly one** `<task>` occurrence — the shape
    /// the editor pre-fills from, and the shape the pin watches (a template that lost its
    /// placeholder would silently pre-fill a form that can never carry the task).
    func testEveryTemplateIsNonEmptyAndCarriesExactlyOneTaskPlaceholder() {
        XCTAssertEqual(
            KnownAgentPresets.taskPlaceholder, "<task>",
            "the placeholder is part of the seeded contract — the shipped templates spell it")
        for preset in KnownAgentPresets.all {
            XCTAssertFalse(
                preset.arguments.isEmpty,
                "\(preset.id)'s argv template must not be empty — an empty template pre-fills a "
                    + "form that runs the binary with no arguments")
            let occurrences = preset.arguments.filter { $0 == KnownAgentPresets.taskPlaceholder }
                .count
            XCTAssertEqual(
                occurrences, 1,
                "\(preset.id)'s argv template must carry exactly one \(KnownAgentPresets.taskPlaceholder) "
                    + "occurrence, got \(occurrences) — a template with zero placeholders cannot "
                    + "carry the task, and one with several would substitute ambiguously")
        }
    }

    // MARK: - Acceptance 4 — pure data

    /// The catalog file is pure data: it names no forbidden transport or subprocess family, no
    /// `FileManager` spelling, and imports nothing — the `ActionTransportProhibitionTests` scan
    /// of the whole module stays green because this file has nothing for it to find.
    func testTheCatalogFileIsPureData() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let file = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoccaActions")
            .appendingPathComponent("Config")
            .appendingPathComponent("KnownAgentPresets.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        XCTAssertEqual(
            ActionTransportProhibitionTests.transportIdentifiers(inSource: source), [],
            "the catalog must name no transport or subprocess family — the transport lint stays "
                + "green because a pure-data seed has nothing for it to find")
        XCTAssertFalse(
            source.contains("FileManager"),
            "the catalog must not name FileManager — detection rides the injected file-system "
                + "seam, and the catalog itself is pure data")
        XCTAssertFalse(
            source.contains("import "),
            "the catalog must import nothing — not even Foundation; Sendable needs none of it, "
                + "and an import is the first step away from pure data")
    }
}