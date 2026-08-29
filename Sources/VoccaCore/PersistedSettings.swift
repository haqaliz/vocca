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

extension EngineTier {
    /// The stable on-disk spelling of this tier — the string a persisted setting holds, and the
    /// string a later launch decodes back into a selection.
    ///
    /// **Deliberately not ``EngineTier/storageID``.** A settings key and a model directory name
    /// answer different questions and change for different reasons: a directory name is a fact
    /// about an artifact on disk and may be renamed the day the artifact is repackaged, while a
    /// settings value is a fact this app must keep decoding forever. Aspect 1 of this unit
    /// existed because one string carried two meanings — the engine id was both the attribution
    /// key and the storage directory, and two Whisper tiers therefore shared one verified marker.
    /// A third meaning on `storageID` would repeat that defect exactly, so the values below are
    /// also spelled differently from the directory names, to make an accidental swap visible.
    ///
    /// Total, with no `default:`: a tier added here must state its on-disk spelling or the file
    /// stops compiling.
    public var persistedIdentifier: String {
        switch self {
        case .parakeetV3: return "parakeet-v3"
        case .whisperTurbo: return "whisper-turbo"
        case .whisperTurboQ5: return "whisper-turbo-q5_0"
        }
    }
}

extension HotkeyConfiguration.Activation {
    /// The stable on-disk spelling of this activation mode.
    ///
    /// ``HotkeyConfiguration/Activation`` is the mode that gets persisted, rather than the
    /// root's `DictationMode`: it is the type ``decide(_:state:config:)`` and
    /// ``SessionWatchdog/wake()`` branch on, it lives in this module, and `DictationMode` — a
    /// two-case near-duplicate declared in `VoccaBootstrap` — is unreachable from both Core and
    /// the adapter that owns the store. Persisting the machine's own vocabulary means the stored
    /// value is the decision rather than a translation of one; the root translates at its edge,
    /// exactly as the Settings page already translates a `Bool` there.
    ///
    /// Total, with no `default:`: the third mode the enum's own documentation anticipates
    /// (voice-activated, at P3) must state its on-disk spelling or the file stops compiling.
    public var persistedIdentifier: String {
        switch self {
        case .holdToTalk: return "hold-to-talk"
        case .toggle: return "toggle"
        }
    }
}

/// The pure half of the settings store: the shipped defaults, and the tolerant decode that turns
/// a persisted string back into a value.
///
/// **Pure and Foundation-free, because this module is.** Nothing here reads a store, a file or a
/// clock; the adapter (`VoccaUI/Settings/UserDefaultsSettingsStore.swift`, the one file permitted
/// to name `UserDefaults`) hands these functions a string it read and receives a value back. Every
/// decision about what a bad string means therefore runs headlessly in CI, which is the whole
/// reason for the split.
///
/// ## The tolerant-decode contract
///
/// Three inputs, three answers, and the difference between the last two is the point:
///
/// - **Absent** (`nil`) — the shipped default, reported to nobody. A fresh install has chosen
///   nothing; that is the normal path, not an error, and logging it would train a reader to
///   ignore this category.
/// - **Unknown or malformed** — the shipped default **and exactly one report**. A value that is
///   present but unreadable means a downgrade, a hand-edit or a rename has cost the user a choice
///   they made. Falling back silently is the failure this rule exists to prevent: the user sees
///   their setting revert and has nothing anywhere that says why.
/// - **Known** — the value, reported to nobody.
///
/// A pure function cannot log, so the loud half arrives through `onInvalidValue`, exactly as
/// `FileSystemDictionaryStore.decode(_:onInvalidElement:)` does. The caller supplies the logger;
/// the test supplies an array, which is how the loudness is asserted rather than hoped.
///
/// Nothing here throws. Every failure degrades to a shipped default, which is a working
/// configuration — a settings read must never be able to make Vocca unusable.
public enum PersistedSettings {

    /// Decode a persisted engine selection, tolerantly.
    ///
    /// The tier is the single stored fact and the engine is derived from it
    /// (``EngineSelection``), so one string is the whole of the selection and an engine/tier
    /// pairing that disagrees is not representable.
    public static func decodeEngineSelection(
        _ raw: String?,
        onInvalidValue: (String) -> Void
    ) -> EngineSelection {
        guard let raw else { return EngineSelection.defaultSelection }
        guard let tier = EngineTier.allCases.first(where: { $0.persistedIdentifier == raw })
        else {
            onInvalidValue(
                "settings: unknown engine selection \"\(raw)\"; falling back to "
                    + "\(EngineSelection.defaultSelection.tier.persistedIdentifier)")
            return EngineSelection.defaultSelection
        }
        return EngineSelection(tier: tier)
    }
    /// The shipped activation mode a fresh install starts in: toggle.
    ///
    /// **The one place this fact is written.** It was briefly duplicated by
    /// `DictationLoopRoot.defaultMode`, in a module this one may not import, with a test in the one
    /// target that can see both holding them together — an arrangement that existed only because
    /// the settings-store aspect could not reach the composition root. The root reads this store
    /// now and derives its constant from this one through an exhaustive mapping, so the duplication
    /// and the test that guarded it are both gone.
    ///
    /// Toggle became the default on 2026-08-25, after the first real dictation: holding a key for
    /// a whole utterance is what produces the accidentally-short presses that failed. Hold-to-talk
    /// is still shipped and is an accessibility requirement, which is why the choice is persisted
    /// at all.
    public static let defaultActivation: HotkeyConfiguration.Activation = .toggle

    /// The stable on-disk spelling of a given cloud-cleanup acknowledgement.
    ///
    /// A string rather than a `Bool`, so it takes the same three-answer path as every other
    /// setting: `object(forKey:)` cannot tell a stored `false` from a stored array from nothing at
    /// all once it has been narrowed to `Bool`, and the difference between "not acknowledged" and
    /// "unreadable" is the one this contract exists to keep.
    public static func encodeCloudAcknowledgement(_ acknowledged: Bool) -> String {
        acknowledged ? acknowledgedValue : notAcknowledgedValue
    }

    /// The spelling of an acknowledgement that was given.
    public static let acknowledgedValue = "acknowledged"

    /// The spelling of one that was not — written when a user withdraws it, so the absent value
    /// keeps meaning "never asked".
    public static let notAcknowledgedValue = "not-acknowledged"

    /// **Whether the user has read and accepted the cloud-cleanup dialog** — the same three-answer
    /// contract, with the safe direction chosen deliberately.
    ///
    /// Absent is `false`, silently: a fresh install has agreed to nothing, which is the normal
    /// path. **Unreadable is also `false`, loudly** — and that direction is the point. Degrading a
    /// corrupted preferences entry to `true` would spend an agreement the user never gave and send
    /// their text off the machine without the dialog `PRODUCT_SPEC.md:273` requires; degrading to
    /// `false` costs them one dialog they have seen before. Those are not comparable failures.
    public static func decodeCloudAcknowledgement(
        _ raw: String?,
        onInvalidValue: (String) -> Void
    ) -> Bool {
        guard let raw else { return false }
        switch raw {
        case acknowledgedValue: return true
        case notAcknowledgedValue: return false
        default:
            onInvalidValue(
                "settings: unreadable cloud-cleanup acknowledgement \"\(raw)\"; treating it as "
                    + "not acknowledged, so the confirmation is shown again")
            return false
        }
    }

    /// Decode a persisted activation mode, tolerantly — the same three-answer contract as
    /// ``decodeEngineSelection(_:onInvalidValue:)``.
    public static func decodeActivation(
        _ raw: String?,
        onInvalidValue: (String) -> Void
    ) -> HotkeyConfiguration.Activation {
        guard let raw else { return defaultActivation }
        guard
            let activation = HotkeyConfiguration.Activation.allCases.first(where: {
                $0.persistedIdentifier == raw
            })
        else {
            onInvalidValue(
                "settings: unknown activation mode \"\(raw)\"; falling back to "
                    + "\(defaultActivation.persistedIdentifier)")
            return defaultActivation
        }
        return activation
    }
}
