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

    // MARK: - Keep in tray

    /// The stable on-disk spelling of a given keep-in-tray choice.
    ///
    /// A string rather than a `Bool`, for the cloud acknowledgement's reason: `object(forKey:)`
    /// cannot tell a stored `false` from a stored array from nothing at all once narrowed to
    /// `Bool`, and the difference between "quit normally" and "unreadable" is the one this
    /// contract exists to keep.
    public static func encodeKeepInTray(_ keepInTray: Bool) -> String {
        keepInTray ? keepInTrayValue : notKeepInTrayValue
    }

    /// The spelling of a choice to keep running in the menu bar.
    public static let keepInTrayValue = "enabled"

    /// The spelling of a choice to quit normally — written when a user withdraws it, so the
    /// absent value keeps meaning "never asked".
    public static let notKeepInTrayValue = "disabled"

    /// **Whether a quit initiated outside the tray menu keeps Vocca running in the menu bar** —
    /// the same three-answer contract, with the safe direction chosen deliberately.
    ///
    /// Absent is `false`, silently: a fresh install has chosen nothing and quits when told to,
    /// which is the normal path. **Unreadable is also `false`, loudly** — that direction is the
    /// point. Degrading a corrupted preferences entry to `true` would make the app refuse to quit
    /// on a choice the user never made, holding the process hostage to a value nobody wrote;
    /// degrading to `false` costs only a setting they can re-enable in one click.
    public static func decodeKeepInTray(
        _ raw: String?,
        onInvalidValue: (String) -> Void
    ) -> Bool {
        guard let raw else { return false }
        switch raw {
        case keepInTrayValue: return true
        case notKeepInTrayValue: return false
        default:
            onInvalidValue(
                "settings: unreadable keep-in-tray choice \"\(raw)\"; treating it as disabled, "
                    + "so quitting quits")
            return false
        }
    }

    // MARK: - The hotkey chord

    /// The key code a fresh install's hotkey is bound to: Space, as in ⌥Space
    /// (`PRODUCT_SPEC.md:127`).
    ///
    /// The same number as `AppBootstrap.shippedHotkeyKeyCode`, which is the composition root's
    /// name for it — held together by test rather than by comment, because the two live in
    /// modules that cannot import each other.
    public static let defaultHotkeyKeyCode: UInt16 = 49

    /// The modifiers a fresh install's hotkey is bound with: Option alone.
    public static let defaultHotkeyModifiers: ModifierSet = [.option]

    /// Every bit ``ModifierSet`` defines — what a stored modifiers word is checked against.
    ///
    /// Written out one modifier at a time because `ModifierSet` is an `OptionSet` and has no
    /// `allCases` to derive this from. A stored word carrying any other bit is malformed: an
    /// unknown bit is compared for equality against every real key press and can never match, so
    /// accepting one would store a hotkey that is displayed correctly in Settings and is
    /// completely dead — which is worse than falling back, because the user can see nothing wrong.
    ///
    /// A modifier added to `ModifierSet` must be added here too, or every user who had bound it
    /// silently loses their binding. `PersistedHotkeyChordTests` is what fails first.
    public static let knownModifierBits: ModifierSet = [
        .control, .option, .shift, .command, .function, .capsLock,
    ]

    /// How the shipped chord is written in a report, so a user reading the log sees the binding
    /// they have been given rather than two numbers.
    private static var shippedChordDescription: String {
        HotkeyChordFormatter.describe(
            keyCode: defaultHotkeyKeyCode, modifiers: defaultHotkeyModifiers)
    }

    /// The chord a fresh install runs, and the chord every failure below degrades to.
    public static var defaultHotkeyChord: HotkeyChord {
        HotkeyChord(keyCode: defaultHotkeyKeyCode, modifiers: defaultHotkeyModifiers)
    }

    /// The two strings a chord is stored as — decimal, matching the store's habit of persisting
    /// strings only.
    ///
    /// **Two values rather than one encoded chord**, so that a half-written pair degrades to the
    /// shipped default rather than to a chord nobody chose: a single string with a missing half
    /// has no shape that says so.
    public static func encodeHotkeyChord(_ chord: HotkeyChord) -> (keyCode: String, modifiers: String) {
        (String(chord.keyCode), String(chord.modifiers.rawValue))
    }

    /// Decode a persisted chord, tolerantly — the same three-answer contract as the settings
    /// above, over a *pair* of stored strings.
    public static func decodeHotkeyChord(
        keyCodeRaw: String?,
        modifiersRaw: String?,
        onInvalidValue: (String) -> Void
    ) -> HotkeyChord {
        if (keyCodeRaw == nil) != (modifiersRaw == nil) {
            let present = keyCodeRaw == nil ? "modifiers" : "keyCode"
            let missing = keyCodeRaw == nil ? "keyCode" : "modifiers"
            onInvalidValue(
                "settings: half a stored hotkey binding (\(present) present, \(missing) "
                    + "missing); falling back to \(shippedChordDescription)")
            return defaultHotkeyChord
        }
        guard let keyCodeRaw, let modifiersRaw else { return defaultHotkeyChord }
        guard let keyCode = UInt16(keyCodeRaw) else {
            onInvalidValue(
                "settings: unreadable hotkey key code \"\(keyCodeRaw)\"; falling back to "
                    + shippedChordDescription)
            return defaultHotkeyChord
        }
        guard let modifierBits = UInt16(modifiersRaw) else {
            onInvalidValue(
                "settings: unreadable hotkey modifiers \"\(modifiersRaw)\"; falling back to "
                    + shippedChordDescription)
            return defaultHotkeyChord
        }
        let modifiers = ModifierSet(rawValue: modifierBits)
        guard modifiers.subtracting(knownModifierBits).isEmpty else {
            onInvalidValue(
                "settings: hotkey modifiers \"\(modifiersRaw)\" carry a bit this version does "
                    + "not define; falling back to \(shippedChordDescription)")
            return defaultHotkeyChord
        }
        let validity = HotkeyBindingRules.validate(keyCode: keyCode, modifiers: modifiers)
        guard isAdoptable(validity) else {
            onInvalidValue(
                "settings: stored hotkey "
                    + "\(HotkeyChordFormatter.describe(keyCode: keyCode, modifiers: modifiers)) "
                    + "is not bindable (\(validity)); falling back to \(shippedChordDescription)")
            return defaultHotkeyChord
        }
        return HotkeyChord(keyCode: keyCode, modifiers: modifiers)
    }

    /// Whether a stored chord of this validity may be adopted at launch.
    ///
    /// Exhaustive with no `default:`, so a fourth ``HotkeyBindingValidity`` case has to state its
    /// answer here rather than inheriting one.
    ///
    /// **A warning is adopted.** Warnings and refusals lead to different controls in a recorder —
    /// one disables Save, the other does not — and they must lead to different answers here for
    /// the same reason. `shortcut-conflicts` will one day give the rules something to warn about;
    /// the day it does, no user may find their binding silently reset to ⌥Space because Vocca
    /// learned that Spotlight also uses it. Startup is not the place to re-litigate a choice the
    /// user already made and can still see.
    public static func isAdoptable(_ validity: HotkeyBindingValidity) -> Bool {
        switch validity {
        case .accepted, .warned: return true
        case .refused: return false
        }
    }
}
