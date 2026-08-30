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

/// A key and the modifiers held with it — **a binding without an activation mode**.
///
/// ``HotkeyConfiguration`` is this plus an ``HotkeyConfiguration/Activation``, and the split is
/// deliberate: the activation mode is already persisted on its own
/// (``PersistedSettings/defaultActivation``, `settings.activationMode`), and storing it a second
/// time inside a stored configuration would create two sources of truth for one fact — two places
/// a relaunch could read a different answer from. The composition root pairs one stored chord with
/// each activation to build the two configurations the two machines run on.
public struct HotkeyChord: Sendable, Hashable {

    /// The virtual key code. Compared for equality and nothing else — key codes are not
    /// comparable across layouts, and nothing here tries.
    public let keyCode: UInt16

    /// The modifiers held with it, **with ``ModifierSet/locking`` already masked out**.
    public let modifiers: ModifierSet

    /// A chord, with Caps Lock masked out on the way in.
    ///
    /// The mask lives here rather than at each end because ``ModifierSet/locking`` is already
    /// masked on both sides of every hotkey comparison: a chord that carried the bit could never
    /// match a real key press, so storing one would be storing a binding that can never fire.
    /// Masking in the initializer means neither the write path nor the read path can forget —
    /// including the third path some later aspect adds.
    public init(keyCode: UInt16, modifiers: ModifierSet) {
        self.keyCode = keyCode
        self.modifiers = modifiers.subtracting(.locking)
    }
}
