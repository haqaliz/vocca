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

import VoccaBootstrap
import VoccaCore
import XCTest

/// The persisted-settings vocabulary — the `settings-store` aspect's Core half
/// (`plan_20260828.md` phase 1): the stable on-disk spellings of the two values Settings can
/// change, and the pure tolerant decode that reads them back.
///
/// **Why the identifiers are pinned as literals rather than asked of the enum.** A test that
/// writes `XCTAssertEqual(tier.persistedIdentifier, tier.persistedIdentifier)` — or that derives
/// the expectation from `String(describing:)` — passes through any rename, which is precisely the
/// event R5 exists to catch: a Swift case rename that silently resets a user's choice on their
/// next launch. The literals below are the file format. Changing one is changing the format, and
/// this file is where that has to be argued for.
final class PersistedSettingsTests: XCTestCase {

    // MARK: - The engine tier's on-disk spelling

    /// Every `EngineTier` spells itself the same way forever, pinned byte-for-byte.
    ///
    /// The switch is exhaustive over `allCases`, so a tier added without an identifier fails
    /// here as an unmatched case rather than shipping a value the store cannot write.
    func testEveryEngineTierHasItsPinnedPersistedIdentifier() {
        for tier in EngineTier.allCases {
            switch tier {
            case .parakeetV3:
                XCTAssertEqual(tier.persistedIdentifier, "parakeet-v3")
            case .whisperTurbo:
                XCTAssertEqual(tier.persistedIdentifier, "whisper-turbo")
            case .whisperTurboQ5:
                XCTAssertEqual(tier.persistedIdentifier, "whisper-turbo-q5_0")
            }
        }
    }
    // MARK: - The activation mode's on-disk spelling

    /// Every activation mode spells itself the same way forever, pinned byte-for-byte.
    ///
    /// The mode persisted is `HotkeyConfiguration.Activation` — the type the session machine
    /// itself branches on (`SessionRules.decide`, `SessionWatchdog.wake`) — not the root's
    /// two-case `DictationMode`, which lives in `VoccaBootstrap` and is therefore unreachable
    /// from both Core and the adapter module. Persisting the type the machine reads means the
    /// stored value is the decision, not a translation of one.
    func testEveryActivationModeHasItsPinnedPersistedIdentifier() {
        for activation in HotkeyConfiguration.Activation.allCases {
            switch activation {
            case .holdToTalk:
                XCTAssertEqual(activation.persistedIdentifier, "hold-to-talk")
            case .toggle:
                XCTAssertEqual(activation.persistedIdentifier, "toggle")
            }
        }
    }
    // MARK: - Uniqueness

    /// No two tiers share an on-disk spelling.
    ///
    /// The aspect-1 lesson applied before the defect rather than after: two tiers that spell
    /// themselves alike are two choices the store cannot tell apart, so a user who picked the
    /// Whisper q5_0 tier is silently handed the full-precision one on their next launch. Driven
    /// over `allCases`, so a new tier that reuses an existing spelling fails here.
    func testTierPersistedIdentifiersArePairwiseDistinct() {
        let identifiers = EngineTier.allCases.map(\.persistedIdentifier)
        XCTAssertEqual(
            Set(identifiers).count, identifiers.count,
            """
            two tiers share a persisted identifier (\(identifiers.sorted().joined(separator: ", "))). \
            A shared spelling is a choice the store cannot read back: the decode would resolve \
            both to whichever case it matches first, silently substituting one artifact for another.
            """)
    }
    /// No two activation modes share an on-disk spelling — the same guard, for the other
    /// persisted type. Driven over `allCases`, so the P3 third mode cannot join by reusing a
    /// spelling and quietly becoming one of the existing two on the next launch.
    func testActivationPersistedIdentifiersArePairwiseDistinct() {
        let identifiers = HotkeyConfiguration.Activation.allCases.map(\.persistedIdentifier)
        XCTAssertEqual(
            Set(identifiers).count, identifiers.count,
            """
            two activation modes share a persisted identifier \
            (\(identifiers.sorted().joined(separator: ", "))). Hold-to-talk is an accessibility \
            requirement, not a preference: a spelling collision is a user who cannot hold a key \
            being given a mode they cannot use.
            """)
    }
    // MARK: - Round trip

    /// Every tier survives a write and a read: `decode(persistedIdentifier(x)) == x`.
    ///
    /// Driven over `allCases` rather than a hand-written list, so a tier added without a decode
    /// arm fails here rather than becoming a setting the user can choose and the store silently
    /// forgets. The decode reports nothing on this path — a valid value is not an error.
    func testEveryTierRoundTripsThroughItsPersistedIdentifier() {
        for tier in EngineTier.allCases {
            var reports: [String] = []
            let decoded = PersistedSettings.decodeEngineSelection(
                tier.persistedIdentifier, onInvalidValue: { reports.append($0) })
            XCTAssertEqual(decoded, EngineSelection(tier: tier))
            XCTAssertEqual(
                reports, [],
                "a valid identifier must decode silently; \(tier) reported \(reports)")
        }
    }
    /// Every activation mode survives a write and a read, driven over `allCases` for the same
    /// reason: a mode added without a decode arm is a mode the user can choose and lose.
    func testEveryActivationModeRoundTripsThroughItsPersistedIdentifier() {
        for activation in HotkeyConfiguration.Activation.allCases {
            var reports: [String] = []
            let decoded = PersistedSettings.decodeActivation(
                activation.persistedIdentifier, onInvalidValue: { reports.append($0) })
            XCTAssertEqual(decoded, activation)
            XCTAssertEqual(
                reports, [],
                "a valid identifier must decode silently; \(activation) reported \(reports)")
        }
    }
    // MARK: - The tolerant decode's three answers

    /// An absent engine selection is the shipped default, and **reports nothing**.
    ///
    /// A fresh install has chosen nothing; that is the normal path, not an error. Reporting it
    /// would put a line in the log on every launch of a machine where nothing is wrong, which is
    /// how a reader learns to ignore the category the next test depends on.
    func testAnAbsentEngineSelectionIsTheShippedDefaultAndReportsNothing() {
        var reports: [String] = []
        let decoded = PersistedSettings.decodeEngineSelection(
            nil, onInvalidValue: { reports.append($0) })
        XCTAssertEqual(decoded, EngineSelection.defaultSelection)
        XCTAssertEqual(decoded.tier, .parakeetV3)
        XCTAssertEqual(reports, [], "an absent value is the normal path and must be silent")
    }

    /// An unknown engine selection is the shipped default **and exactly one loud report naming
    /// the value that was rejected**.
    ///
    /// The loud half is what is asserted here, not the fallback: a present-but-unreadable value
    /// means a downgrade, a hand-edit or a rename has cost the user a choice they made, and a
    /// silent reset is the exact failure this rule exists for — the user watches their setting
    /// revert with nothing anywhere saying why. The report must carry the offending string, since
    /// a report that does not name it cannot be acted on.
    func testAnUnknownEngineSelectionIsTheShippedDefaultAndIsReportedLoudly() {
        var reports: [String] = []
        let decoded = PersistedSettings.decodeEngineSelection(
            "parakeet-v4-from-the-future", onInvalidValue: { reports.append($0) })
        XCTAssertEqual(decoded, EngineSelection.defaultSelection)
        XCTAssertEqual(reports.count, 1, "exactly one report per unreadable value")
        XCTAssertTrue(
            reports.first?.contains("parakeet-v4-from-the-future") == true,
            "the report must name the value it rejected; got \(reports)")
    }

    /// An absent activation mode is the shipped default, and reports nothing — the same normal
    /// path, for the other setting.
    func testAnAbsentActivationModeIsTheShippedDefaultAndReportsNothing() {
        var reports: [String] = []
        let decoded = PersistedSettings.decodeActivation(
            nil, onInvalidValue: { reports.append($0) })
        XCTAssertEqual(decoded, PersistedSettings.defaultActivation)
        XCTAssertEqual(reports, [], "an absent value is the normal path and must be silent")
    }

    /// An unknown activation mode is the shipped default **and one loud report naming it**.
    ///
    /// This setting is the one where a silent reset is worst: hold-to-talk is an accessibility
    /// requirement, so a user who cannot hold a key and finds themselves back in toggle needs the
    /// log to say that their stored value was unreadable rather than that nothing happened.
    func testAnUnknownActivationModeIsTheShippedDefaultAndIsReportedLoudly() {
        var reports: [String] = []
        let decoded = PersistedSettings.decodeActivation(
            "voice-activated", onInvalidValue: { reports.append($0) })
        XCTAssertEqual(decoded, PersistedSettings.defaultActivation)
        XCTAssertEqual(reports.count, 1, "exactly one report per unreadable value")
        XCTAssertTrue(
            reports.first?.contains("voice-activated") == true,
            "the report must name the value it rejected; got \(reports)")
    }
    // MARK: - The duplicated default, pinned against its twin

    /// ``PersistedSettings/defaultActivation`` and `DictationLoopRoot.defaultMode` state the same
    /// fact, and this test is the only thing keeping them from stating it differently.
    ///
    /// The duplication is deliberate and temporary. The root's constant lives in `VoccaBootstrap`,
    /// which `VoccaCore` may not import (the graph points inward) and which the store's adapter
    /// module cannot see either — so the store cannot read the root's answer, and the root does
    /// not yet read the store's. Until the wiring aspect makes the root derive its constant from
    /// this one, a change to either alone means a user's fresh install starts in one mode and
    /// their first saved setting reads back as another. That is a test target's job precisely
    /// because it is the one place that may import both modules; nothing in `Sources/` does, and
    /// this aspect deliberately wires nothing into the root.
    ///
    /// The mapping switch is exhaustive with no `default:`, so a third mode has to say which
    /// `Activation` it corresponds to rather than silently satisfying the pin.
    @MainActor
    func testTheShippedActivationDefaultAgreesWithTheRootsDictationModeDefault() {
        let rootDefault: HotkeyConfiguration.Activation
        switch DictationLoopRoot.defaultMode {
        case .holdToTalk: rootDefault = .holdToTalk
        case .toggle: rootDefault = .toggle
        }
        XCTAssertEqual(
            PersistedSettings.defaultActivation, rootDefault,
            """
            the persisted-settings default (\(PersistedSettings.defaultActivation)) and the root's \
            DictationLoopRoot.defaultMode (\(DictationLoopRoot.defaultMode)) disagree. They are one \
            fact in two modules until the wiring aspect deletes the duplication; a machine with no \
            saved setting would start in one mode while the store reports the other.
            """)
    }
}
