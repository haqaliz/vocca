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
import VoccaCore

/// **The system shortcut table's read seam — the one file in `Sources/` permitted to name
/// `UserDefaults` for the `systemShortcuts` seam** (the UserDefaults family's third entry in
/// `InjectionSeamBoundaryTests`' seam table).
///
/// ## What this can see, and what it cannot
///
/// `com.apple.symbolichotkeys` is Apple's own preferences domain for Apple's own remappable
/// shortcuts — Mission Control, Spaces switching, screenshots, input-source switching. It is
/// undocumented and readable with no entitlement.
///
/// It is also **all there is**. There is no API to enumerate a hotkey another process registered,
/// through Carbon's `RegisterEventHotKey` or through its own `CGEventTap`; that is closed by
/// design. **Raycast, Alfred and every other launcher are therefore invisible to this reader**,
/// including when they are holding the chord the user is trying to bind. Nothing built on it may
/// be written, in code or in copy, as though the check were complete.
///
/// A second limit, found by reading the live file rather than by reasoning about it: macOS writes
/// an entry here **only for a shortcut whose setting differs from the shipped default**. On the
/// authoring machine (2026-08-30) the domain holds 37 entries and none of them is Spotlight, whose
/// ⌘Space is untouched. So a shortcut the user has never changed is not merely unnamed — it is
/// absent. That, too, degrades to silence.
///
/// ## Executed by nothing in CI
///
/// This reads the runner's own preferences, and asserting anything about those is asserting a fact
/// about the machine — the `SystemSecureInputState` case exactly. So this file holds no decisions:
/// what a malformed entry means is `VoccaCore/SymbolicHotkeyDecoding.swift`, over integers, and
/// what a modifier word means is `SystemShortcutProjection`, over the translation the event tap
/// already uses. Both run headless. What is left here is casting.
public struct SystemShortcutDefaultsReader: SystemShortcutReader {

    /// Apple's preferences domain for its own remappable shortcuts.
    public static let suiteName = "com.apple.symbolichotkeys"

    /// The key the table lives under inside that domain.
    public static let tableKey = "AppleSymbolicHotKeys"

    private let suiteName: String

    /// A reader over `suiteName` — Apple's domain in the app, an arbitrary scratch domain if some
    /// later caller needs one. Never `.standard`: the table is not in Vocca's own domain.
    public init(suiteName: String = SystemShortcutDefaultsReader.suiteName) {
        self.suiteName = suiteName
    }

    /// The chords the system is known to have claimed — empty whenever anything at all goes
    /// wrong, which is every failure mode this aspect has.
    public func occupiedChords() -> [SystemShortcut] {
        // The domain is opened per read rather than held, and the reason is `Sendable`: this
        // type crosses isolation boundaries and `UserDefaults` is not `Sendable`, so storing one
        // would need a suppression to say something the compiler is right to doubt. Opening it
        // here needs no claim at all, and the read happens while a chord is being recorded — once
        // per rebind, never on the dictation path.
        guard let defaults = UserDefaults(suiteName: suiteName),
            let table = defaults.dictionary(forKey: Self.tableKey)
        else { return [] }

        let raw: [SymbolicHotkeyDecoding.RawEntry] = table.compactMap { key, value in
            guard let identifier = Int(key) else { return nil }
            let entry = value as? [String: Any]
            let parameters = (entry?["value"] as? [String: Any])?["parameters"] as? [Any]
            return SymbolicHotkeyDecoding.RawEntry(
                identifier: identifier,
                // Read through `NSNumber` rather than `as? Bool`, because that is one cast for
                // both spellings a property list can carry a flag in — `<true/>` and
                // `<integer>1</integer>` are both `NSNumber` here — rather than a branch choosing
                // between them. Anything that is not a number at all stays `nil`, and Core reads
                // `nil` as silence.
                isEnabled: (entry?["enabled"] as? NSNumber)?.boolValue,
                // Mapped element by element, so a non-integer arrives as a `nil` **in place** and
                // the arity survives. Collapsing the whole array on one bad element would take
                // the position information away from the only layer that decides what to do
                // with it.
                parameters: parameters?.map { ($0 as? NSNumber)?.intValue })
        }

        return SystemShortcutProjection.shortcuts(from: SymbolicHotkeyDecoding.decode(raw))
    }
}
