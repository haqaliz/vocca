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

/// Why a candidate chord may not be bound.
///
/// A **closed** set, and closed for a reason: the answer a user is given when their chord is
/// refused has to name something, and an open-ended `refused(String)` would let every surface
/// invent its own wording for the same refusal. `CaseIterable` is the mechanism behind
/// `binding-vocabulary/spec.md`'s first acceptance criterion — the exhaustiveness test iterates
/// ``allCases`` and demands a candidate that produces each — so a fourth reason cannot be added
/// without a test that shows it happening.
public enum HotkeyBindingRefusal: Sendable, Equatable, CaseIterable {

    /// Modifiers with no ordinary key. ``HotkeyConfiguration`` pairs a `keyCode` with a
    /// ``ModifierSet``; modifiers alone have no representation in it, so there is nothing to store.
    case modifierOnly

    /// Escape — Vocca's own cancel key (`SessionKeyPolicy.escapeKeyCode`) and the recorder's abort
    /// gesture. Binding it would leave a user no way to abandon a dictation, or a recording.
    case reservedByVocca

    /// An unmodified letter, digit, punctuation mark, Space, Return, Tab or Delete. The tap is
    /// active and swallows what is bound (`ARCHITECTURE.md` §13), so binding one of these makes
    /// that key untypeable **system-wide** — in a tool whose entire job is putting text into
    /// fields, with the recovery path behind a Settings window that needs the keyboard.
    case unmodifiedTextEntryKey
}

/// A binding that is legal but worth saying something about.
///
/// Separate from ``HotkeyBindingRefusal`` because the two lead to different controls: a refusal
/// disables the Save button, a warning does not. `binding-vocabulary` ships this case and produces
/// none — reading Apple's own shortcut table is `shortcut-conflicts`, and most of that question is
/// undecidable (`prd.md` §5.3). The case exists now so that aspect has somewhere to put its answer
/// rather than growing a second vocabulary beside this one.
public enum HotkeyBindingWarning: Sendable, Equatable {

    /// The chord is already spoken for by a system shortcut. `name` is what to call it — `nil`
    /// when the conflict is known but its owner is not, which is the common case: the system's
    /// shortcut table is readable, its labels much less so.
    case usedBySystemShortcut(name: String?)
}

/// Whether a candidate chord may be bound — the closed answer every surface in `hotkey-rebinding`
/// asks for and none of them re-derives.
///
/// Three-way rather than a `Bool`, because "legal, and Spotlight already uses it" is neither a
/// refusal nor silence: a recorder that renders ``warned`` the same as ``accepted`` has dropped
/// the only thing the warning existed to carry.
public enum HotkeyBindingValidity: Sendable, Equatable {

    /// Bind it.
    case accepted

    /// Bind it, and tell the user this first.
    case warned(HotkeyBindingWarning)

    /// Do not bind it, for this named reason.
    case refused(HotkeyBindingRefusal)
}
