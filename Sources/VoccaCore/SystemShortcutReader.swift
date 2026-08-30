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

/// One chord the system has already claimed, and what to call it.
public struct SystemShortcut: Sendable, Equatable {

    /// The chord the shortcut occupies.
    public let chord: HotkeyChord

    /// What to call it, or `nil` when the collision is known and its owner is not.
    ///
    /// `nil` is the **common** case, not the exceptional one. `com.apple.symbolichotkeys` is keyed
    /// by an opaque integer and carries no labels at all; the only identifiers Vocca can name are
    /// the ones it could verify against a table Apple itself ships
    /// (``SystemShortcutNames``). Everything else is reported by chord alone — an unnamed
    /// collision is still a collision, and dropping it would hide a real one.
    public let name: String?

    public init(chord: HotkeyChord, name: String?) {
        self.chord = chord
        self.name = name
    }
}

/// **What the system has already claimed** — the seam `shortcut-conflicts` asks, and the honest
/// limits of the question.
///
/// ## What this can and cannot see, stated before anything uses it
///
/// The only enumerable source is `com.apple.symbolichotkeys`, which covers **Apple's own
/// remappable shortcuts and nothing else** — Mission Control, Spaces switching, screenshots,
/// input-source switching. There is **no API to enumerate a hotkey another process registered**,
/// whether through Carbon's `RegisterEventHotKey` or through its own `CGEventTap`. That is closed
/// by design, not an omission this aspect can work around.
///
/// **So Raycast, Alfred and every other launcher are structurally invisible here** — including
/// when they hold the very chord the user is trying to bind. Nothing built on this seam may be
/// phrased, in code or in copy, as though the check were complete.
///
/// ## Every failure is silence
///
/// Synchronous, non-throwing, and returning a possibly-empty array on purpose. An absent file, an
/// unreadable one, a format Apple changed under us — all answer "nothing known". A detection
/// failure must never block or refuse a rebind, so there is no shape in this signature for one to
/// travel through.
public protocol SystemShortcutReader: Sendable {

    /// The chords the system is known to have claimed. Empty when nothing is known, which is
    /// indistinguishable from nothing being claimed — deliberately, because the two lead to the
    /// same answer.
    func occupiedChords() -> [SystemShortcut]
}

/// The pure decision above the seam: does a candidate chord collide with something already
/// claimed, and what is it called.
public enum SystemShortcutRules {

    /// The warning a candidate earns, or `nil`.
    ///
    /// **Warn, never refuse.** This function's return type is the whole of that guarantee: there
    /// is no case in ``HotkeyBindingWarning`` and no third branch here that could turn into a
    /// refusal, and ``PersistedSettings/isAdoptable(_:)`` accepts ``HotkeyBindingValidity/warned``
    /// on the other side. The user's machine is the authority on their own shortcuts — theirs may
    /// be remapped or switched off — so a collision is something to say, not something to enforce.
    public static func warning(
        for candidate: HotkeyChord,
        against occupied: [SystemShortcut]
    ) -> HotkeyBindingWarning? {
        let matches = occupied.filter { $0.chord == candidate }
        guard !matches.isEmpty else { return nil }

        // A named match wins over an unnamed one. Two entries can carry the same chord — the
        // user has remapped one onto another, or a fixture holds both shapes — and reporting the
        // unnamed one first would throw away the only useful half of the answer for no reason.
        let named = matches.first { $0.name != nil }
        return .usedBySystemShortcut(name: (named ?? matches[0]).name)
    }
}
