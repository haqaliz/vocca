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

/// Whether a chord may be bound — the pure decision every surface in `hotkey-rebinding` asks, and
/// none of them re-derives (`binding-vocabulary/spec.md` M6).
///
/// ## The two wrong answers do not cost the same
///
/// A false ``HotkeyBindingValidity/refused`` is an annoyance: the user picks a different chord. A
/// false ``HotkeyBindingValidity/accepted`` on a text-entry key makes that key untypeable **on the
/// whole machine** — the tap is active and swallows what is bound (`ARCHITECTURE.md` §13) — and
/// the way out is a Settings window the user now needs that keyboard to reach. So the default
/// answer for an unmodified key is *refusal*, and acceptance is granted only from a named table.
public enum HotkeyBindingRules {

    /// The validity of a candidate binding.
    ///
    /// ## The order of the checks is part of the answer
    ///
    /// 1. ``ModifierSet/locking`` is masked first, so a chord recorded with Caps Lock on is the
    ///    same chord as one recorded without.
    /// 2. **Modifier-only**, before anything else looks at the key: a lone ⌘ arrives as
    ///    `kVK_Command`, and nothing further down would recognise it.
    /// 3. **Reserved**, before the unmodified test — so `⌘Escape` is refused as Vocca's own key
    ///    rather than accepted as a modified chord, and bare Escape reads `reservedByVocca` rather
    ///    than the false sentence "Escape types text".
    /// 4. Anything still holding a modifier is **accepted**: a modified chord cannot brick a key,
    ///    because the bare key still types.
    /// 5. What is left is bare, and is accepted **only** from ``safeUnmodifiedKeyCodes``. Every
    ///    other bare key — listed, unlisted or unknown — is refused.
    ///
    /// - Parameters:
    ///   - keyCode: the virtual key code the recorder observed.
    ///   - modifiers: the modifiers held with it. ``ModifierSet/locking`` is masked out first, so
    ///     a candidate recorded with Caps Lock on is the same candidate as one recorded without.
    public static func validate(keyCode: UInt16, modifiers: ModifierSet) -> HotkeyBindingValidity {
        let bindable = modifiers.subtracting(.locking)

        if HotkeyBindingTables.modifierKeyCodes.contains(keyCode) {
            return .refused(.modifierOnly)
        }

        if HotkeyBindingTables.voccaReservedKeyCodes.contains(keyCode) {
            return .refused(.reservedByVocca)
        }

        guard bindable.isEmpty else { return .accepted }

        return HotkeyBindingTables.safeUnmodifiedKeyCodes.contains(keyCode)
            ? .accepted
            : .refused(.unmodifiedTextEntryKey)
    }

    /// The validity of a candidate binding, **against what the system has already claimed**.
    ///
    /// The recorder's whole question in one place, rather than two calls sequenced in a
    /// composition root — because the order between them is a decision, and a decision in a
    /// composition root is a decision no test reaches.
    ///
    /// **A refusal outranks a collision.** A bare text-entry key is refused whether or not macOS
    /// also claims it: the refusal is the stronger answer, and a recorder that offered "macOS uses
    /// this, take it anyway" over a key that would stop typing on the whole machine would be
    /// offering exactly what the rules exist to prevent.
    ///
    /// - Parameters:
    ///   - chord: the candidate.
    ///   - occupied: what ``SystemShortcutReader`` reported. Empty means *nothing known*, which is
    ///     indistinguishable from nothing being claimed — deliberately, because the two lead to the
    ///     same answer, and because the reader can see only Apple's own remappable shortcuts and
    ///     only the ones the user has changed.
    public static func validate(
        _ chord: HotkeyChord, against occupied: [SystemShortcut]
    ) -> HotkeyBindingValidity {
        let validity = validate(keyCode: chord.keyCode, modifiers: chord.modifiers)
        guard case .accepted = validity else { return validity }

        guard let warning = SystemShortcutRules.warning(for: chord, against: occupied) else {
            return .accepted
        }
        return .warned(warning)
    }
}
