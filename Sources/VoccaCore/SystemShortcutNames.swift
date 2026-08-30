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

/// The shortcut identifiers Vocca can put a name to.
///
/// ## The table is small on purpose, and the reason is evidentiary
///
/// `com.apple.symbolichotkeys` carries no labels — only opaque integer keys — so every name has to
/// come from somewhere else. Two Apple-shipped tables exist on a real machine and both were read
/// on 2026-08-30:
///
/// - `KeyboardSettings.appex/Contents/Resources/DefaultSpacesShortcuts.xml` maps identifier to
///   shortcut. It declares identifier 118 as key 18, modifier 262144 — which is exactly what the
///   live plist holds, so the two agree independently.
/// - `.../DefaultShortcutsTable.loctable` maps that shortcut's internal name to the English label
///   macOS shows: `Switch to Space 1` → "Switch to Desktop 1".
///
/// Every row below was checked through both. **Nothing else on the machine names an identifier**:
/// no other shipped table covers a non-Spaces identifier, and the settings extension's binary
/// embeds no property list at all.
///
/// ## Spotlight is not here, and that is the honest answer rather than an omission
///
/// `spec.md` names 32/33 as Spotlight and `plan_20260830.md` names 64/65, each flagging the other
/// as unverified. Both are wrong or unverifiable here. Identifier 32 reads `[65535, 126, 8650752]`
/// on this machine — the Up arrow with `fn | control`, which is ⌃↑ and not ⌘Space. Identifiers 64
/// and 65 are **absent from the live file entirely**, and **why is not understood**.
///
/// The obvious explanation — that macOS records an entry only where a setting differs from the
/// shipped default — was written here as fact and is **false**: identifier 118 is present on the
/// same machine holding `⌃1`, the stock default for *Switch to Desktop 1*, untouched. Untouched
/// shortcuts plainly do get entries. The retraction is kept rather than deleted because the
/// deleted version of this comment is what a later reader would otherwise reconstruct from the
/// same evidence.
///
/// So the shortcut this aspect was most wanted for is one it can neither name nor, on at least one
/// real machine, see — with the cause unknown, which means coverage may be better or worse than
/// this file can say. That is worth stating plainly wherever this feature is described. What saves it
/// from being useless is that an **unnamed collision still warns**
/// (``SystemShortcutRules/warning(for:against:)``): a chord Vocca cannot label is still reported
/// as taken.
///
/// A name added here must come from a table Apple ships, read on a machine. Never from memory,
/// never from a plan — a guessed name is worse than no name, because the user cannot tell one
/// from the other.
public enum SystemShortcutNames {

    /// Identifier to English label, for the identifiers verified against Apple's own tables.
    ///
    /// The full sixteen rather than a range computed from one, because the two halves come from
    /// different shortcuts — 118–127 are ⌃1…⌃0, 128–133 are ⌃⌥1…⌃⌥6 — and an arithmetic shortcut
    /// would name a user's chord as the wrong desktop the day Apple renumbers one.
    private static let verifiedNames: [Int: String] = [
        118: "Switch to Desktop 1",
        119: "Switch to Desktop 2",
        120: "Switch to Desktop 3",
        121: "Switch to Desktop 4",
        122: "Switch to Desktop 5",
        123: "Switch to Desktop 6",
        124: "Switch to Desktop 7",
        125: "Switch to Desktop 8",
        126: "Switch to Desktop 9",
        127: "Switch to Desktop 10",
        128: "Switch to Desktop 11",
        129: "Switch to Desktop 12",
        130: "Switch to Desktop 13",
        131: "Switch to Desktop 14",
        132: "Switch to Desktop 15",
        133: "Switch to Desktop 16",
    ]

    /// What to call the shortcut with this identifier, or `nil` when it cannot be named.
    ///
    /// `nil` is the common answer and is not a failure — see the type's documentation. The caller
    /// reports the collision either way.
    public static func name(forIdentifier identifier: Int) -> String? {
        verifiedNames[identifier]
    }
}
