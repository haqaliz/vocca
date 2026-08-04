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

/// The keyboard modifiers held at the moment an event was observed.
///
/// Vocca's own type, not `CGEventFlags`. `CGEventFlags` lives in CoreGraphics, and CoreGraphics in
/// this module would put every start and stop rule below the system-API seam — where a CI runner
/// cannot reach it, because `CGEvent.tapCreate` returns `nil` without an Accessibility grant and
/// there is no programmatic route to TCC. `CoreBoundaryTests` asserts that seam rather than
/// trusting it.
///
/// **The raw bit positions are deliberately not `CGEventFlags`'.** They are this package's own,
/// starting at bit 0, so that no one can be tempted to bridge the two with a bit-cast or a
/// `rawValue` round-trip. The translation belongs in `VoccaHotkey`, written out case by case, at
/// the one point in the program where a `CGEvent` legitimately exists.
///
/// Modifier state is always *derived* from the flags carried by the event in hand — never
/// accumulated across `flagsChanged` events. That prohibition is a requirement, not a style note:
/// Handy's v0.2.0 switched from deriving to accumulating and desynchronised permanently after a
/// single missed event, leaving the microphone open ([Handy #840](https://github.com/cjpais/Handy/issues/840)).
public struct ModifierSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let control = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let shift = ModifierSet(rawValue: 1 << 2)
    public static let command = ModifierSet(rawValue: 1 << 3)
    /// The `fn` key. Carried because it is a usable hotkey modifier on Apple keyboards.
    public static let function = ModifierSet(rawValue: 1 << 4)
    /// Included because macOS reports it in the same flag word, and a hotkey must keep working
    /// while it happens to be on — not because anyone should bind to it.
    public static let capsLock = ModifierSet(rawValue: 1 << 5)
}
