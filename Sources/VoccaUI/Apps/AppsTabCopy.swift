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

/// **How Vocca types into an application, in words a person can act on.**
///
/// The Apps tab's health column (`PRODUCT_SPEC.md:275`). Three states, because the ladder has
/// three rungs a strategy can lead with — and deliberately *not* the rung names: `accessibility`
/// and `clipboardPaste` are the mechanism, and a user reading a settings table wants to know
/// whether their text arrives by being typed, by being pasted, or only by hand.
public enum AppsTabHealth: String, Sendable, Equatable, CaseIterable {
    /// The accessibility rung leads: Vocca inserts into the field directly, and reads it back.
    case typingDirectly
    /// The clipboard rung leads — the workhorse, and what most applications get.
    case pasting
    /// Keystroke synthesis leads, which is the last thing before the failsafe.
    case manualOnly

    /// The health a rung leads to. `.widgetFailsafe` never appears in a strategy (PRD R2) and so
    /// can never be a first rung — it maps here anyway, so the table is total rather than
    /// crashing on a state the type system still permits.
    public init(firstRung: InjectionRung) {
        switch firstRung {
        case .accessibility: self = .typingDirectly
        case .clipboardPaste: self = .pasting
        case .keystrokeSynthesis, .widgetFailsafe: self = .manualOnly
        }
    }
}

/// **What a user can pin an application to** — the override's three choices (PRD R7/S2).
///
/// Each is a whole rung order, not a single rung, because an override replaces the projection
/// outright: what the user picks is what the ladder attempts, in that order, forever. Two
/// invariants are built into the lists rather than checked afterwards: `.widgetFailsafe` never
/// appears in a strategy, and `.clipboardPaste` is always present — the workhorse
/// (`ROADMAP.md:47`), so a pin can never leave an application with nothing that works.
public enum AppsTabMethod: String, Sendable, Equatable, CaseIterable {
    /// Accessibility first, with the usual fallbacks beneath it.
    case typeDirectly
    /// Clipboard first — the default for everything the allowlist does not bless.
    case paste
    /// Keystroke synthesis first, clipboard beneath it. Not "never touch the clipboard": that
    /// would contradict the never-empty invariant, and the fallback is what keeps a pin from
    /// being a way to break dictation into one application permanently.
    case manual

    /// The rung order this pin means.
    public var rungs: [InjectionRung] {
        switch self {
        case .typeDirectly: return [.accessibility, .clipboardPaste, .keystrokeSynthesis]
        case .paste: return [.clipboardPaste, .keystrokeSynthesis]
        case .manual: return [.keystrokeSynthesis, .clipboardPaste]
        }
    }

    /// The health this pin produces — its first rung's, by construction, so the column a user
    /// reads after pinning is the one they chose.
    public var health: AppsTabHealth {
        AppsTabHealth(firstRung: rungs[0])
    }

    /// The pin an existing override represents, or `nil` if the stored order is not one of the
    /// three the tab offers — a hand-edited `strategies.json` can hold any order at all, and the
    /// picker must not silently re-write it to the nearest thing it knows.
    public init?(rungs: [InjectionRung]) {
        guard let match = AppsTabMethod.allCases.first(where: { $0.rungs == rungs }) else {
            return nil
        }
        self = match
    }
}

/// The Apps tab's strings, kept out of the views so they can be read without a window server —
/// the ``SettingsCopy``/``BadgeCopy`` shape.
public enum AppsTabCopy {

    /// The health column's word for a state. `PRODUCT_SPEC.md:275`, byte for byte.
    public static func healthLabel(_ health: AppsTabHealth) -> String {
        switch health {
        case .typingDirectly: return "typing directly"
        case .pasting: return "pasting"
        case .manualOnly: return "manual only"
        }
    }

    /// The override picker's word for a choice — the health vocabulary, deliberately reused. A
    /// second set of words for the same three ideas would make the user translate between the
    /// column they read and the control they use.
    public static func methodLabel(_ method: AppsTabMethod) -> String {
        healthLabel(method.health)
    }

    /// The reset button. The spec writes the phrase in prose, lower case; a button label carries
    /// a leading capital, which is the only difference.
    public static let resetButton = "Reset what Vocca learned"

    /// What reset does, and — the part a user actually needs — what it leaves alone.
    public static let resetExplanation =
        "Clears what Vocca worked out by itself. Anything you pinned stays pinned."

    /// An overridden row, in words rather than only in styling.
    public static let overriddenBadge = "Pinned by you"

    /// A row Vocca worked out on its own.
    public static let learnedBadge = "Learned"

    /// The empty state — honest about why it is empty rather than reading like a fault.
    public static let empty =
        "Vocca hasn't learned anything about your apps yet. It learns the first time it "
        + "types into one."

    /// A failed write, surfaced. The `DictionarySettingsPage` rule: a store that silently fails
    /// to save is one the user sets up again next launch.
    public static func saveError(_ message: String) -> String {
        "Couldn't save: \(message)"
    }

    /// The table's column headings.
    public static let appColumn = "App"
    /// The health column's heading.
    public static let healthColumn = "How Vocca types"
    /// The learned/pinned column's heading.
    public static let stateColumn = "Where that came from"
}
