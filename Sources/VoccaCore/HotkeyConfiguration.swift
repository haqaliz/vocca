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

/// The hotkey the user configured, as the rules need to know it.
///
/// A parameter of ``decide(_:state:config:)`` rather than a global, because a global is state, and
/// a function that reads state is not the pure function this aspect's tests depend on. It costs one
/// argument at the call site and buys a test that can drive two configurations in the same run.
public struct HotkeyConfiguration: Sendable, Hashable {

    /// How holding the hotkey relates to the session: **hold-to-talk today, and only that.**
    ///
    /// A one-case enum on purpose. `spec.md` describes hold-to-talk and toggle as two
    /// configurations of one state machine, and the shape has to be able to say so — but toggle is
    /// a later unit of work, and a value that cannot yet be honoured must not be constructible.
    /// The alternative shapes were both worse:
    ///
    /// - **A `Bool isToggle` (or a two-case enum) with no implementation.** Then `.toggle` is
    ///   constructible today and silently behaves as hold-to-talk. That is the exact failure this
    ///   repository has already paid for twice: a public case whose branch someone else's logic
    ///   quietly inherits.
    /// - **No field at all**, added when toggle arrives. Then the compiler has nothing to point at,
    ///   and the mode has to be threaded through every call site in the commit that is meant to be
    ///   about the mode's *behaviour*.
    ///
    /// ``decide(_:state:config:)`` switches over this without a `default:`, so adding `.toggle` is
    /// a compile error there, at the one place that has to state what it means.
    public enum Activation: Sendable, Hashable, CaseIterable {
        /// The session lasts as long as the key is held. The user's finger is the endpointer.
        case holdToTalk
    }

    /// The virtual key code the user bound. Compared for equality and nothing else — key codes are
    /// not comparable across layouts, and nothing here tries.
    public let keyCode: UInt16

    /// The modifiers that must be held. Tested with `⊇`, never `==`: caps lock being on, or a
    /// finger still resting on Shift, must not stop the hotkey working.
    ///
    /// May be empty — a bare F13 is a legitimate binding. Every modifier rule is then vacuously
    /// satisfied, which is correct: there is no modifier to release.
    public let modifiers: ModifierSet

    public let activation: Activation

    /// No default for `activation`. There is one value, so spelling it costs nothing today, and
    /// when there are two the compiler will ask every call site which one it meant — rather than
    /// picking hold-to-talk for a user who configured toggle.
    public init(keyCode: UInt16, modifiers: ModifierSet, activation: Activation) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.activation = activation
    }
}
