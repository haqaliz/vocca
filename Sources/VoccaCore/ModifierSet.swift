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

    /// Modifiers that are **not part of a binding** and are masked out before any hotkey
    /// comparison, on both sides.
    ///
    /// Caps Lock alone, and the reason is the one already given above: it is a *lock*, not a key
    /// someone holds down to mean something. A user with Caps Lock on must still be able to press
    /// their hotkey, and nobody binds to it, so it can be neither required nor disqualifying.
    ///
    /// Masked from the *configuration* as well as from the event. A configuration naming Caps Lock
    /// is then simply ignored rather than becoming a hotkey that only works with Caps Lock on —
    /// which is the failure a one-sided mask would produce.
    ///
    /// Everything else is bindable and is compared exactly. `function` is deliberately **not** here:
    /// `fn` is a key a user holds, and ``ModifierSet/function`` documents it as a usable hotkey
    /// modifier on Apple keyboards. Treating it as a lock would silently make `fn`-prefixed bindings
    /// interchangeable with their unprefixed forms.
    ///
    /// ## `fn` carries two different meanings, and only the adapter can tell them apart
    ///
    /// macOS sets the `fn` bit on F1–F20, the arrow keys, Home/End/PgUp/PgDn, forward-Delete and
    /// Help **with no user involvement at all**. So the bit means either *"the user is holding
    /// `fn`"* or *"this key code carries it implicitly"*, and this type cannot distinguish them —
    /// it never sees a key code.
    ///
    /// Left unhandled, that breaks exactly the bindings `PRODUCT_SPEC.md:257` calls an
    /// accessibility requirement rather than a preference — single keys, *"for users who can't
    /// hold chords"*. Both shapes fail, in opposite directions:
    ///
    /// | Binding | What happens |
    /// |---|---|
    /// | bare `F13`, configured `[]` | the event carries `[.function]`, so the chords are unequal and **the hotkey never fires** |
    /// | `F13` configured `[.function]` | it starts, then hold-to-talk stop rule (c) fires on the first ordinary keystroke (`[] ⊉ [.function]`) and **the session ends on the user's first typed character** |
    ///
    /// **Decision (founder, at the end of `session-lifecycle`): `fn` stays bindable here, and
    /// `VoccaHotkey` must strip it for key codes that carry it implicitly.** The adapter is the only
    /// layer that knows the key code, so it is the only layer that can tell a held `fn` from a
    /// hardware-set one. Adding `fn` to ``locking`` would fix the accessibility case and silently
    /// break genuine `fn`-held bindings — the right symptom cured at the wrong layer.
    ///
    /// A `VoccaHotkey` that does not strip it inherits both failures above, and the tests in
    /// `SessionDecisionTests` pin the current behaviour as correct, so nothing here will catch it.
    public static let locking: ModifierSet = [.capsLock]
}
