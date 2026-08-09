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
import XCTest

/// `EngineSelection`'s decision table (`engine-picker` Phase 1): the seeded candidates, their
/// engine-scoped tiers, the default, and the mutation rules — pinned headlessly, the
/// `SessionDecisionTests` table style.
///
/// The load-bearing property is that **no invalid (engine, tier) pairing is representable**: the
/// tier carries its engine (`EngineTier.engine`), so the picker's reducer cannot hand the session
/// an engine and a tier from different engines — the value does not exist to be constructed. The
/// closed-set walk below asserts the space `EngineTier.allCases` is exactly the valid space, and
/// that the engine mirror (`EngineCandidate.allCases`) has not gone stale in either direction.
final class EngineSelectionTests: XCTestCase {

    // MARK: - The default

    /// `PRODUCT_SPEC.md:189` names Parakeet v3 as the shipped default: it is what a fresh install
    /// selects, and what a session starts with before the user has ever opened settings.
    func testDefaultSelectionIsParakeetV3() {
        XCTAssertEqual(
            EngineSelection.defaultSelection,
            EngineSelection(tier: .parakeetV3),
            "The default selection must be Parakeet v3 at its own tier.")
        XCTAssertEqual(
            EngineSelection.defaultSelection.engine, .parakeetV3,
            "The default selection must name the Parakeet engine.")
    }

    // MARK: - The tier table

    /// Each engine's tier set is exactly its own: Parakeet ships one tier (nothing to choose),
    /// Whisper ships the two quantisation tiers. The table is written out in full so an engine
    /// gaining a tier, or a tier being attached to the wrong engine, has a row to fail in.
    func testEachEnginesTierSetIsExactlyItsOwn() {
        let table: [(engine: EngineCandidate, expectedTiers: [EngineTier])] = [
            (.parakeetV3, [.parakeetV3]),
            (.whisperTurbo, [.whisperTurbo, .whisperTurboQ5]),
        ]
        for row in table {
            XCTAssertEqual(
                validTiers(for: row.engine), row.expectedTiers,
                "\(row.engine) must offer exactly its own tiers, in order.")
        }

        // The reverse direction, over the closed set: every tier there is belongs to the engine it
        // claims to belong to — an independent mirror, so a tier added to `EngineTier` but
        // forgotten in the table above fails here instead of passing silently.
        for tier in EngineTier.allCases {
            XCTAssertTrue(
                validTiers(for: tier.engine).contains(tier),
                "\(tier) names engine \(tier.engine), which must offer \(tier) back.")
        }

        // Two engines with a shared tier would be a representable collision — the exact defect the
        // engine-scoped tier design exists to rule out. The counts differing is the structural pin.
        XCTAssertNotEqual(
            validTiers(for: .parakeetV3), validTiers(for: .whisperTurbo),
            "A tier set shared across engines would make the tier ambiguous about its engine.")
        XCTAssertEqual(validTiers(for: .parakeetV3).count, 1)
        XCTAssertEqual(validTiers(for: .whisperTurbo).count, 2)
    }

    // MARK: - Mutation rules

    /// Changing engine resets the tier to that engine's default. The picker may be sitting on
    /// Whisper q5_0 when the user switches to Parakeet; the selection must land on Parakeet's
    /// default, never carry a foreign tier across.
    func testSelectingAnEngineResetsTheTierToThatEnginesDefault() {
        let whisperAtQ5 = EngineSelection(tier: .whisperTurboQ5)

        let toParakeet = whisperAtQ5.selecting(engine: .parakeetV3)
        XCTAssertEqual(
            toParakeet, EngineSelection(tier: .parakeetV3),
            "Switching to Parakeet from a Whisper q5_0 selection must land on Parakeet's default.")

        let toWhisper = whisperAtQ5.selecting(engine: .whisperTurbo)
        XCTAssertEqual(
            toWhisper, EngineSelection(tier: .whisperTurbo),
            """
            Selecting Whisper must land on its default tier, turbo full — never inherit q5_0, and \
            never forget that Whisper's default is the full-precision tier.
            """)

        // Idempotent on the tier: selecting the engine you are already on is a no-op for the tier.
        XCTAssertEqual(
            toParakeet.selecting(engine: .parakeetV3), toParakeet,
            "Re-selecting the current engine must not move the tier.")
    }

    // MARK: - The space walk

    /// The closed-set walk: every tier in `EngineTier.allCases` is a valid selection for its own
    /// engine, and there are no other (engine, tier) values than those the walk visits — the walk
    /// and the tier table cover the same three values, so the space is exhaustively valid and the
    /// two enumerations cannot drift apart.
    func testTheEngineTierSpaceWalkIsExhaustivelyValid() {
        let walked = EngineTier.allCases.map { EngineSelection(tier: $0) }

        XCTAssertEqual(
            walked.map(\.engine),
            [.parakeetV3, .whisperTurbo, .whisperTurbo],
            "Each tier must resolve to exactly its own engine across the whole space.")

        XCTAssertEqual(
            Set(walked).count, EngineTier.allCases.count,
            "Every tier must produce a distinct selection — no two tiers may collapse onto one.")

        XCTAssertEqual(
            EngineTier.allCases.count,
            validTiers(for: .parakeetV3).count + validTiers(for: .whisperTurbo).count,
            """
            The whole tier space must be the two engines' tier sets put together. If a tier exists \
            that no engine offers, or an engine offers a tier that is not in the space, the walk \
            and the table disagree.
            """)

        for selection in walked {
            XCTAssertTrue(
                validTiers(for: selection.engine).contains(selection.tier),
                "\(selection.tier) must be a valid tier of \(selection.engine) — it resolved to it.")
        }
    }

    // MARK: - The candidate table

    /// The stable machine ids are the seeded contract (`EngineIdentity.swift:28` documents the
    /// same two strings): the model store keys its directories by them, so a typo here would
    /// silently point the picker at a model that does not exist. Both engines are local — no
    /// egress badge (`ARCHITECTURE.md:152-156`).
    func testCandidateIdentityMatchesTheSeededIds() {
        let table: [(engine: EngineCandidate, id: String, displayName: String)] = [
            (.parakeetV3, "parakeet-tdt-0.6b-v3", "Parakeet v3"),
            (.whisperTurbo, "whisper-large-v3-turbo", "Whisper turbo"),
        ]
        for row in table {
            XCTAssertEqual(row.engine.id, row.id, "\(row.engine)'s id must be the seeded one.")
            XCTAssertEqual(
                row.engine.displayName, row.displayName,
                "\(row.engine)'s display name must be the seeded one.")
            XCTAssertTrue(
                row.engine.identity.isLocal,
                "\(row.engine) is a local engine and must never claim otherwise.")
            XCTAssertEqual(row.engine.identity.id, row.id)
            XCTAssertEqual(row.engine.identity.displayName, row.displayName)
        }

        // Distinct engines must be distinct identities, or a lookup keyed on the identity could
        // hand the picker's answer to the wrong engine.
        XCTAssertNotEqual(EngineCandidate.parakeetV3.identity, EngineCandidate.whisperTurbo.identity)
        XCTAssertEqual(Set([EngineCandidate.parakeetV3.identity, EngineCandidate.whisperTurbo.identity]).count, 2)
    }

    // MARK: - Equality

    /// Equality tracks the tier exactly: the tier determines the engine, so two selections equal
    /// iff their tiers do — and different tiers of the same engine are different selections.
    func testSelectionEqualityTracksTheTierExactly() {
        XCTAssertEqual(EngineSelection(tier: .whisperTurbo), EngineSelection(tier: .whisperTurbo))
        XCTAssertNotEqual(
            EngineSelection(tier: .whisperTurbo), EngineSelection(tier: .whisperTurboQ5),
            "Turbo full and q5_0 are different tiers of the same engine and must not compare equal.")
        XCTAssertNotEqual(
            EngineSelection(tier: .parakeetV3), EngineSelection(tier: .whisperTurbo),
            "Different engines must not compare equal.")
        XCTAssertEqual(
            Set([EngineSelection(tier: .parakeetV3), EngineSelection(tier: .parakeetV3)]).count, 1,
            "Hashable: the same selection must deduplicate.")
    }

    // MARK: - Sendable

    /// Compile-time, not runtime: `requireSendable` constrains its parameter to `Sendable`, so a
    /// conformance that disappears fails to build this file rather than failing an assertion. The
    /// selection crosses the picker's boundary into the session machine, which is a different
    /// isolation domain.
    func testTheSelectionVocabularyIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        _ = requireSendable(EngineTier.allCases)
        _ = requireSendable(EngineCandidate.allCases)
        _ = requireSendable(EngineSelection.defaultSelection)
        _ = requireSendable(validTiers(for: .whisperTurbo))
    }
}
