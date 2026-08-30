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
import OSLog
import VoccaCore

/// **The settings seam — the one file in `Sources/` permitted to name `UserDefaults` for the
/// settings family** (the settings entry in `InjectionSeamBoundaryTests`' UserDefaults table,
/// beside the completion flag's `CompletionFlagStore`). One file per seam, and nothing else ever
/// joins this entry: a second naming file would be a persisted-settings decision that escaped the
/// headless suite forever.
///
/// The user outcome is one sentence — *a setting, once chosen, stays chosen*. Before this store,
/// the activation mode was read from a constant and written nowhere, so a user who switched it in
/// Settings was back in the shipped mode at the next launch.
///
/// ## What this file is allowed to decide: nothing
///
/// Every decision about what a stored string *means* — the on-disk spellings, what an absent value
/// is, what an unreadable one is and how loudly it is reported — lives in `PersistedSettings`
/// (VoccaCore), where it is pure and CI runs all of it. What is left here is raw `UserDefaults`
/// translation: which key, and reading the raw object out. The one judgement this file does make
/// is the wrong-type case, and it makes it by *routing* rather than deciding: a value that is
/// present but is not a string is handed to the same decode path as an unknown string, so it takes
/// the same loud fallback rather than being quietly mistaken for "nothing stored".
///
/// ## Read contract
///
/// Synchronous, never throwing — the `CompletionFlagStore` rationale applies unchanged: the launch
/// path needs an answer with no `await` in it (window-server rule: `main()` shows, `configure`
/// never constructs a window). Every failure degrades to a shipped default, which is a working
/// configuration; a settings read must never be able to make Vocca unusable.
///
/// **A failed read never writes.** A value the store could not decode is left exactly as it was
/// found — the `FileSystemDictionaryStore` rule. Rewriting it would destroy the evidence, and
/// would turn a value a future version could have understood into one it cannot.
///
/// ## Write contract
///
/// Best-effort and never throwing, for the same reason the completion flag's write is: a failed
/// write fails in the safe direction — the setting reverts to the shipped default at the next
/// launch, which is a working configuration and a visible one.
public struct UserDefaultsSettingsStore: SettingsStore {
    /// The frozen key the engine selection lives under.
    ///
    /// Pinned by test as a literal. The key is the file format: change it and every existing
    /// user's choice becomes an absent value on their next launch, silently and with no error
    /// anywhere — the same class of loss `EngineTier.persistedIdentifier` exists to prevent, one
    /// level up.
    public static let engineSelectionKey = "settings.engineSelection"

    /// The frozen key the activation mode lives under. Pinned by test as a literal, for the same
    /// reason.
    public static let activationModeKey = "settings.activationMode"

    /// The frozen key the cloud-cleanup acknowledgement lives under. Pinned by test as a literal,
    /// for the same reason as the two above — and with one more: a renamed key here re-shows a
    /// dialog every existing cloud user already read.
    public static let cloudCleanupAcknowledgementKey = "settings.cloudCleanupAcknowledged"

    /// The frozen keys the hotkey chord lives under. Pinned by test as literals, for the same
    /// reason as the three above.
    ///
    /// **Two keys, not one.** A single encoded chord has no shape that says "half of me is
    /// missing", so a partial write would decode to a chord nobody chose; a missing key beside a
    /// present one is visible, and `PersistedSettings` reads it as malformed rather than absent.
    public static let hotkeyKeyCodeKey = "settings.hotkey.keyCode"

    /// The modifiers half of the pair.
    public static let hotkeyModifiersKey = "settings.hotkey.modifiers"

    private let defaults: UserDefaults
    private let log: @Sendable (String) -> Void

    /// A store over `defaults` — `.standard` in the app, a scoped suite in tests (never
    /// `UserDefaults.standard` from the test suite, so the developer's real settings are
    /// untouchable).
    ///
    /// `log` is the loud half of the tolerant-decode contract: every value that was present and
    /// unreadable goes through it, injectable so the loudness is asserted rather than hoped. The
    /// normal path — nothing stored yet — goes through it never.
    public init(
        defaults: UserDefaults = .standard,
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "settings").error("\($0)")
        }
    ) {
        self.defaults = defaults
        self.log = log
    }

    /// The chosen engine and tier, or the shipped default (Parakeet v3).
    public func engineSelection() -> EngineSelection {
        PersistedSettings.decodeEngineSelection(rawValue(forKey: Self.engineSelectionKey), onInvalidValue: log)
    }

    /// Persist the chosen engine and tier. Best-effort, never throws.
    public func setEngineSelection(_ selection: EngineSelection) {
        defaults.set(selection.tier.persistedIdentifier, forKey: Self.engineSelectionKey)
    }

    /// The chosen activation mode, or the shipped default (toggle).
    public func activationMode() -> HotkeyConfiguration.Activation {
        PersistedSettings.decodeActivation(rawValue(forKey: Self.activationModeKey), onInvalidValue: log)
    }

    /// Persist the chosen activation mode. Best-effort, never throws.
    public func setActivationMode(_ activation: HotkeyConfiguration.Activation) {
        defaults.set(activation.persistedIdentifier, forKey: Self.activationModeKey)
    }

    /// The bound hotkey chord, or the shipped default (⌥Space).
    ///
    /// Both halves go through ``rawValue(forKey:)``, so a stored non-string takes the loud path
    /// rather than reading as nothing stored — and, because the pair is read together, a
    /// corrupted half is seen as half a pair rather than silently paired with the default's
    /// other half.
    public func hotkeyChord() -> HotkeyChord {
        PersistedSettings.decodeHotkeyChord(
            keyCodeRaw: rawValue(forKey: Self.hotkeyKeyCodeKey),
            modifiersRaw: rawValue(forKey: Self.hotkeyModifiersKey),
            onInvalidValue: log)
    }

    /// Persist the bound chord — both halves. Best-effort, never throws.
    public func setHotkeyChord(_ chord: HotkeyChord) {
        let encoded = PersistedSettings.encodeHotkeyChord(chord)
        defaults.set(encoded.keyCode, forKey: Self.hotkeyKeyCodeKey)
        defaults.set(encoded.modifiers, forKey: Self.hotkeyModifiersKey)
    }

    /// Whether the cloud-cleanup confirmation has been read and accepted. `false` for a fresh
    /// install and `false` for anything unreadable — see
    /// `PersistedSettings.decodeCloudAcknowledgement(_:onInvalidValue:)` for why that direction.
    public func hasAcknowledgedCloudCleanup() -> Bool {
        PersistedSettings.decodeCloudAcknowledgement(
            rawValue(forKey: Self.cloudCleanupAcknowledgementKey), onInvalidValue: log)
    }

    /// Record or withdraw the acknowledgement. Best-effort, never throws.
    public func setAcknowledgedCloudCleanup(_ acknowledged: Bool) {
        defaults.set(
            PersistedSettings.encodeCloudAcknowledgement(acknowledged),
            forKey: Self.cloudCleanupAcknowledgementKey)
    }

    // MARK: - The one piece of translation this file owns

    /// The stored string under `key`, or `nil` for a key with nothing under it.
    ///
    /// Deliberately `object(forKey:)` rather than `string(forKey:)`. `string(forKey:)` answers
    /// `nil` for a stored value of the wrong type — an array, a dictionary — which is the same
    /// answer it gives for a key that was never written, so a corrupted preferences file would
    /// take the *silent* absent-value path instead of the loud one. Routing a present non-string
    /// through a sentinel keeps the two cases apart at the only point where they can still be
    /// told apart.
    private func rawValue(forKey key: String) -> String? {
        guard let object = defaults.object(forKey: key) else { return nil }
        guard let string = object as? String else { return Self.presentButNotAString }
        return string
    }

    /// The sentinel a present non-string value is decoded as. Any string no
    /// `persistedIdentifier` can equal would do; this one says what happened when it reaches a
    /// log line. It is never written to the defaults — nothing here writes on a read.
    private static let presentButNotAString = "<a stored value that is not a string>"
}

/// The shipped settings store, behind the Core-owned seam — the composition factory, in the one
/// file permitted to name the type it returns.
///
/// The `ShippingLadder`/`ShippingCleanup` shape, and it exists for a lint's sake as much as for
/// tidiness: `InjectionSeamBoundaryTests` forbids any file outside this seam's table from naming an
/// identifier beginning `UserDefaults` — the type's own name included. Without this factory the
/// composition root could not so much as mention the store, which is exactly the pressure the rule
/// is meant to apply: the root reads a seam, not an adapter.
public enum ShippingSettings {
    /// The store over the app's standard defaults domain.
    public static func store() -> any SettingsStore {
        UserDefaultsSettingsStore()
    }
}
