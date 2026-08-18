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

/// The shipping cleanup factory's contract (spec B10): the rules provider the composition root
/// wires as the default cleanup stage.
///
/// Three promises are pinned here, over the seam's own vocabulary:
///
/// - **`requiresNetwork` is `false`** — the egress hook the zero-network invariant keys on: the
///   default configuration stays offline with cleanup wired, because the shipped provider
///   declares offline.
/// - **The identity is non-optional and stable** — the I1 attribution discipline applied to
///   cleanup: every cleaned string carries `"rules-cleanup"`, the machine key the
///   ``ProviderIdentity`` documentation names.
/// - **The probe's canonical input survives the rules path** — `"1 2 3"` keeps its digits
///   through the empty-dictionary rules path, earning only the terminal punctuation the shipped
///   segmentation stage appends to every unpunctuated utterance (so `injected=1-2-3.` in the
///   zero-network probe's report): the zero-network probe drives the *real* rules provider, and
///   its `transcript=1-2-3` field stays true through the cleanup stage (`ProbeEngine.swift:43,108`).
final class ShippingCleanupTests: XCTestCase {

    /// **B10a — the shipped provider is offline by declaration.** `requiresNetwork == false` is
    /// the hook `ZeroNetworkTests` keys on; the default configuration makes zero network calls
    /// with the rules provider wired, because this declaration is what the invariant trusts.
    func testShippingCleanupRequiresNetworkIsFalse() {
        let provider = ShippingCleanup.make(
            store: FileSystemDictionaryStore(directory: Self.tempDirectory()))

        XCTAssertFalse(
            provider.requiresNetwork,
            "the rules provider is offline by construction — and declares it, so the "
                + "zero-network invariant is keyed on the declaration, not a convention")
    }

    /// **B10b — the rules provider declares its 10 ms budget.** The shipped provider states its
    /// budget explicitly (the declared-not-defaulted B10 contract), so the pipeline races the
    /// rules number itself rather than inheriting it — a future conformer that declares more
    /// changes only its own line, never the rules path.
    func testTheRulesProviderDeclaresItsTenMillisecondBudget() {
        let provider = ShippingCleanup.make(
            store: FileSystemDictionaryStore(directory: Self.tempDirectory()))

        XCTAssertEqual(
            provider.budget, .milliseconds(10),
            "the rules provider declares its 10 ms budget — declared, not defaulted (B10)")
    }

    /// **B10b — the identity is non-optional and stable.** The machine key is the name the
    /// ``ProviderIdentity`` documentation reserves for the rules engine; the display name is
    /// human-readable; and the identity's `Hashable` equality survives driving a clean call —
    /// attribution is the same value before and after the work it names.
    func testShippingCleanupIdentityIsNonOptionalAndStable() async {
        let provider = ShippingCleanup.make(
            store: FileSystemDictionaryStore(directory: Self.tempDirectory()))

        XCTAssertEqual(
            provider.identity.id, "rules-cleanup",
            "the machine key is the name ProviderIdentity.swift:31 reserves for the rules engine")
        XCTAssertFalse(
            provider.identity.displayName.isEmpty,
            "the display name is for humans — empty means nothing to log or show")

        let before = provider.identity
        _ = try? await provider.clean(
            Self.probeTranscript, context: Self.context())
        XCTAssertEqual(
            provider.identity, before,
            "the identity is a stable value — equality survives the drive")
        XCTAssertEqual(
            provider.identity, ProviderIdentity(id: "rules-cleanup", displayName: before.displayName),
            "Hashable equality holds against a hand-built identity with the same key")
    }

    /// **B10c — the probe's canonical input survives the rules path.** Over a store whose
    /// directory does not exist (an empty rule set, per the dictionary store's contract), the
    /// probe's canonical `"1 2 3"` comes back as `"1 2 3."` — the digits unrewritten, with only
    /// the terminal punctuation the rules engine's pinned segmentation stage appends to any
    /// unpunctuated utterance (its combination tables: `"um so like we need to ship this period"`
    /// → `"We need to ship this."`). The cycle report's `transcript=1-2-3` (the engine's side)
    /// stays untouched; `injected=` carries the cleaned text.
    func testShippingCleanupLeavesTheProbeCanonicalInputUnchanged() async {
        let provider = ShippingCleanup.make(
            store: FileSystemDictionaryStore(directory: Self.tempDirectory()))

        let cleaned = try? await provider.clean(Self.probeTranscript, context: Self.context())

        XCTAssertEqual(
            cleaned, "1 2 3.",
            "the empty-dictionary rules path must not rewrite the probe's digits — the only "
                + "change is the terminal punctuation every unpunctuated utterance earns")
    }

    // MARK: - Fixtures

    /// A directory that does not exist — an empty dictionary, never an error.
    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-cleanup-shipping-\(UUID().uuidString)")
    }

    /// The probe's canonical transcript (`ProbeEngine.swift:43,108`), as a real ``Transcript``.
    private static let probeTranscript = Transcript(
        text: "1 2 3",
        segments: [],
        engine: EngineIdentity(
            id: "probe-stub-engine", displayName: "Probe stub engine", isLocal: true),
        isFinal: true,
        audioDuration: 1.0)

    /// The dictation-mode context the pipeline hands a provider: the focused app as it was at
    /// key-down, the dictation mode, no rules in the advisory channel, and the caller-enforced
    /// budget as information only.
    private static func context() -> CleanupContext {
        CleanupContext(
            target: TargetContext(
                bundleID: "com.example.Notes", windowTitle: "Notes - The Draft",
                isSecureInput: false),
            mode: .dictation,
            dictionary: [],
            budget: .milliseconds(10))
    }
}
