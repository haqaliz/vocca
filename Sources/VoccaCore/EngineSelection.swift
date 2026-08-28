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

/// The model tier of a seeded ASR engine.
///
/// **Engine-scoped by construction**: every case names the one engine it belongs to
/// (``parakeetV3`` for Parakeet; the two quantisation tiers for Whisper), so an (engine, tier)
/// pairing drawn from different engines is not a value that exists — it cannot even be passed to a
/// caller. The picker's reducer therefore cannot hand the session an engine and a tier that belong
/// to different engines; the invalid combination is unrepresentable rather than checked.
public enum EngineTier: Sendable, Hashable, CaseIterable {
    /// Parakeet v3 — the only tier Parakeet ships. There is nothing to choose.
    case parakeetV3
    /// Whisper turbo at full precision.
    case whisperTurbo
    /// Whisper turbo at q5_0 quantisation.
    case whisperTurboQ5

    /// The engine this tier belongs to. Total, with no `default:`: a tier added here must say
    /// which engine it belongs to or the file stops compiling.
    public var engine: EngineCandidate {
        switch self {
        case .parakeetV3: return .parakeetV3
        case .whisperTurbo, .whisperTurboQ5: return .whisperTurbo
        }
    }

    /// The key the model store names this tier's directory by: `<root>/<storageID>/<version>/`.
    ///
    /// **Storage is keyed by tier, not by engine**, and that is the whole of this property's
    /// reason to exist. Two tiers of one engine are two different artifacts — whisper turbo is
    /// 1.6 GB and its q5_0 quantisation is 574 MB, under different file names — so keying their
    /// directories by ``EngineCandidate/id``, which both share, gave them one directory and one
    /// verified marker: the second tier's download short-circuits on the first tier's marker and
    /// the engine loads bytes nobody chose. ``EngineCandidate/id`` remains the *attribution* key
    /// a transcript is signed with, which is correct to share; the directory is not.
    ///
    /// Total, with no `default:`, exactly as ``engine`` is: a tier added here must say where its
    /// bytes live or the file stops compiling. Every shipped manifest's `engineID` is pinned to
    /// this value (`ModelStoreTierKeyingTests`), so the two names for one directory cannot drift.
    public var storageID: String {
        switch self {
        case .parakeetV3: return "parakeet-tdt-0.6b-v3"
        case .whisperTurbo: return "whisper-large-v3-turbo"
        case .whisperTurboQ5: return "whisper-large-v3-turbo-q5_0"
        }
    }
}

/// The closed set of ASR engines the picker can select — the seeded two, no more.
///
/// ``id`` is the stable machine key **attribution** uses and persisted settings decode back
/// (C14); ``identity`` is the full ``EngineIdentity`` the transcript attribution carries, so the
/// selection's engine is exactly the engine that signs transcripts.
///
/// ``id`` is **not** the model store's directory key, though it read as one until 2026-08-28.
/// Both Whisper tiers share this engine, so keying storage by it gave two different artifacts one
/// directory and one verified marker. Storage is keyed by tier — see ``EngineTier/storageID``.
/// Sharing ``id`` across an engine's tiers is correct for signing a transcript and wrong for
/// naming a directory, and the two answers are now two properties.
/// Both seeded engines are local, so ``EngineIdentity.isLocal`` is `true` and no egress badge
/// applies.
public enum EngineCandidate: Sendable, Hashable, CaseIterable {
    case parakeetV3
    case whisperTurbo

    /// The stable machine key: `"parakeet-tdt-0.6b-v3"`, `"whisper-large-v3-turbo"`.
    public var id: String {
        switch self {
        case .parakeetV3: return "parakeet-tdt-0.6b-v3"
        case .whisperTurbo: return "whisper-large-v3-turbo"
        }
    }

    /// The human-readable name, for the settings rows.
    public var displayName: String {
        switch self {
        case .parakeetV3: return "Parakeet v3"
        case .whisperTurbo: return "Whisper turbo"
        }
    }

    /// The full Core identity — the same id and name the transcripts attribute to.
    public var identity: EngineIdentity {
        EngineIdentity(id: id, displayName: displayName, isLocal: true)
    }

    /// The tier a fresh selection of this engine starts at — Parakeet's only tier, or Whisper
    /// turbo full. The user's finger has not touched the tier menu yet.
    public var defaultTier: EngineTier {
        switch self {
        case .parakeetV3: return .parakeetV3
        case .whisperTurbo: return .whisperTurbo
        }
    }
}

/// A chosen engine and model tier — the picker's answer.
///
/// The tier is the single stored fact and implies the engine (``EngineTier.engine``), so an
/// invalid pairing is not a value that exists and ``EngineSelection/tier`` is the only slot that
/// can vary. Changing *engine* is the one mutation that moves it: ``selecting(engine:)`` lands on
/// the new engine's default tier, never carrying a foreign tier across.
public struct EngineSelection: Sendable, Hashable {
    /// The chosen tier; the engine is derived from it.
    public let tier: EngineTier

    /// The engine this selection names.
    public var engine: EngineCandidate { tier.engine }

    /// The shipped default: Parakeet v3 (`PRODUCT_SPEC.md:189`).
    public static let defaultSelection = EngineSelection(tier: .parakeetV3)

    /// Total over the closed set ``EngineTier.allCases``: every tier is a valid selection of the
    /// engine it belongs to, so every constructible value is a valid one.
    public init(tier: EngineTier) {
        self.tier = tier
    }

    /// A selection of the given engine, at that engine's default tier — the "user picked an
    /// engine" rule. Tier reset is inherent, not remembered: there is no tier to inherit, because
    /// a foreign tier cannot exist on this value.
    public func selecting(engine: EngineCandidate) -> EngineSelection {
        EngineSelection(tier: engine.defaultTier)
    }
}

/// The tiers the given engine can be used with — its own, and no other engine's.
public func validTiers(for engine: EngineCandidate) -> [EngineTier] {
    switch engine {
    case .parakeetV3: return [.parakeetV3]
    case .whisperTurbo: return [.whisperTurbo, .whisperTurboQ5]
    }
}
