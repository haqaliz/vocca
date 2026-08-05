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

    /// How pressing the hotkey relates to the session: **two configurations of one state machine.**
    ///
    /// `spec.md:74-86` is emphatic that these are not two machines, and the code follows: the start
    /// rule is identical in both, ``decide(_:state:config:)`` branches once at its top, and the
    /// state machine, the custody funnel and the key claim below are all mode-blind.
    ///
    /// **The two modes do not have the same safety properties, and pretending otherwise is the
    /// danger this enum introduces.** In hold-to-talk a session cannot outlive the user's finger:
    /// the continuation condition is *"the key is held"*, which is a state of the world, so
    /// `CGEventSourceKeyState` can read it out of band and stop rule (f) closes a missed key-up
    /// within one poll interval. In toggle the continuation condition is *"the user has not pressed
    /// again"*, which is not a state of the world at all — it is the absence of a future event, and
    /// no poll can read that. Rule (f) therefore does not exist in toggle mode (see
    /// ``SessionWatchdog/wake()``), and what is left bounding a toggle session is the ceiling, the
    /// tap-disabled stop, the system triggers and the user.
    ///
    /// Every switch over this enum in the module is exhaustive with no `default:`, so a third mode
    /// — voice-activated, at P3 — has to state its own answer to that everywhere it matters rather
    /// than inheriting one of these two.
    public enum Activation: Sendable, Hashable, CaseIterable {
        /// The session lasts as long as the key is held. The user's finger is the endpointer.
        case holdToTalk

        /// One press starts the session and the next press ends it.
        ///
        /// `PRODUCT_SPEC.md:257`: *"Hold-to-talk always has a toggle alternative for users who
        /// can't hold a key — this is a real accessibility need, not a preference."* It is not a
        /// convenience mode and must never be degraded to buy safety back; the honest response to
        /// the asymmetry above is to bound it and say so, not to make it worse than hold-to-talk to
        /// use.
        ///
        /// Stop rules (a) key-up, (b)/(c) modifier released and (f) the physical-key poll are all
        /// replaced by a single one: **the next matching key-down**, reported as
        /// ``RetainedEndReason/toggledOff``. Rules (d) tap-disabled and (e) ceiling still apply
        /// unchanged, as do the system triggers and cancellation.
        case toggle
    }

    /// The virtual key code the user bound. Compared for equality and nothing else — key codes are
    /// not comparable across layouts, and nothing here tries.
    public let keyCode: UInt16

    /// The modifiers that must be held.
    ///
    /// Compared two different ways, because starting and stopping ask different questions — see
    /// ``decide(_:state:config:)``, "Why starting is exact and stopping is not". Starting requires
    /// **equality**, so `⌥⇧Space` is not `⌥Space` and two bindings cannot both match one press. In
    /// hold-to-talk, stopping requires only **containment**, so reaching for Shift mid-sentence does
    /// not end a session. In toggle there is no containment question at all: stopping is a *press*,
    /// so it asks the starting question and is compared for equality too.
    /// ``ModifierSet/locking`` is masked out of every one of those comparisons first, which is what
    /// keeps a hotkey working while Caps Lock happens to be on.
    ///
    /// May be empty — a bare F13 is a legitimate binding. The stop rules are then vacuously
    /// satisfied, which is correct: there is no modifier to release. Starting still requires
    /// equality, so a bare binding is *not* triggered by the same key with a modifier held.
    public let modifiers: ModifierSet

    public let activation: Activation

    /// No default for `activation`. There are two values now, and the compiler asks every call
    /// site which one it meant — rather than picking hold-to-talk for a user who configured toggle,
    /// which for a user who cannot hold a key is not a fallback but a hotkey that does nothing.
    public init(keyCode: UInt16, modifiers: ModifierSet, activation: Activation) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.activation = activation
    }
}
