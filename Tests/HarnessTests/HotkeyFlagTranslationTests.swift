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

import Carbon.HIToolbox
import CoreGraphics
import VoccaCore
import VoccaHotkey
import XCTest

/// One row of the modifier truth table: the SDK's own flag constant, and the ``ModifierSet`` member
/// it must become.
private struct ModifierRow {
    /// The name as it appears in `CGEventTypes.h`, so a failure names the constant rather than a
    /// bit pattern nobody can read.
    let name: String
    let flag: CGEventFlags
    let modifier: ModifierSet
}

/// One key code, with the identifier it has in `Carbon/HIToolbox/Events.h`.
private struct NamedKeyCode {
    let name: String
    let code: UInt16

    init(_ name: String, _ code: Int) {
        self.name = name
        self.code = UInt16(code)
    }
}

/// The translation from a macOS event-flag word plus a key code into Vocca's own ``ModifierSet``.
///
/// ## Why the expected values come from the SDK, never from this file
///
/// Every flag bit below is read from `CGEventFlags`, and every key code from `kVK_*`. Neither is
/// written out here. That is deliberate and it is the point of the suite: the *implementation*
/// hand-writes both, because `VoccaHotkey`'s translation must not bridge the two bit worlds with a
/// cast (`ModifierSet.swift:23-26`), and hand-written constants are exactly where a silent typo
/// lives. A wrong bit or a wrong key code is not a compile error and not a crash — it is a hotkey
/// that never fires, discovered by a user. Driving the public function with the SDK's own values
/// makes any divergence a test failure instead.
///
/// ## What the `fn` rule is for
///
/// macOS sets the `fn` bit on F1–F20, the arrows, Home/End/PgUp/PgDn, forward-Delete and Help with
/// no user involvement at all, so the bit means *either* "the user is holding `fn`" *or* "this key
/// code carries it implicitly". Only this layer sees the key code, so only this layer can tell them
/// apart — `ModifierSet.swift:65-88` records the founder's decision and the two failures it
/// prevents, both of which land on single-key bindings that `PRODUCT_SPEC.md:257` calls an
/// accessibility requirement rather than a preference.
final class HotkeyFlagTranslationTests: XCTestCase {

    // MARK: - Fixtures

    /// A key code that is emphatically *not* in the implicit-`fn` set, used wherever a test needs
    /// an ordinary key. `kVK_ANSI_A`, verified in `Events.h` as `0x00`.
    private static let ordinaryKeyCode = UInt16(kVK_ANSI_A)

    /// Every flag Vocca has a ``ModifierSet`` member for.
    private static let translatedModifiers: [ModifierRow] = [
        ModifierRow(name: "kCGEventFlagMaskControl", flag: .maskControl, modifier: .control),
        ModifierRow(name: "kCGEventFlagMaskAlternate", flag: .maskAlternate, modifier: .option),
        ModifierRow(name: "kCGEventFlagMaskShift", flag: .maskShift, modifier: .shift),
        ModifierRow(name: "kCGEventFlagMaskCommand", flag: .maskCommand, modifier: .command),
        ModifierRow(name: "kCGEventFlagMaskSecondaryFn", flag: .maskSecondaryFn, modifier: .function),
        ModifierRow(name: "kCGEventFlagMaskAlphaShift", flag: .maskAlphaShift, modifier: .capsLock),
    ]

    /// Flags macOS sets in the same word that Vocca has no member for. Each must be *dropped*, not
    /// folded into a member that happens to be nearby.
    ///
    /// `maskNumericPad` is the one that would bite. It is set on every arrow key — the same keys
    /// that carry `fn` implicitly — so a translation that mapped an unrecognised bit onto some
    /// member would make every arrow-key binding carry a modifier the user never pressed, and stop
    /// rule (c) would end the session on the first ordinary keystroke. Exactly the `fn` bug, by a
    /// second route.
    private static let untranslatedFlags: [ModifierRow] = [
        ModifierRow(name: "kCGEventFlagMaskHelp", flag: .maskHelp, modifier: []),
        ModifierRow(name: "kCGEventFlagMaskNumericPad", flag: .maskNumericPad, modifier: []),
        ModifierRow(name: "kCGEventFlagMaskNonCoalesced", flag: .maskNonCoalesced, modifier: []),
    ]

    /// Every key code macOS sets the `fn` bit on by itself.
    ///
    /// Named individually and sourced individually from `Carbon/HIToolbox/Events.h` in the current
    /// SDK. The F-keys are **not contiguous** and are not in numeric order there — `kVK_F17` is
    /// `0x40` while `kVK_F16` is `0x6A` — which is precisely why none of these may be written from
    /// memory or extrapolated from a neighbour.
    private static let implicitFunctionKeys: [NamedKeyCode] = [
        NamedKeyCode("kVK_F1", kVK_F1),
        NamedKeyCode("kVK_F2", kVK_F2),
        NamedKeyCode("kVK_F3", kVK_F3),
        NamedKeyCode("kVK_F4", kVK_F4),
        NamedKeyCode("kVK_F5", kVK_F5),
        NamedKeyCode("kVK_F6", kVK_F6),
        NamedKeyCode("kVK_F7", kVK_F7),
        NamedKeyCode("kVK_F8", kVK_F8),
        NamedKeyCode("kVK_F9", kVK_F9),
        NamedKeyCode("kVK_F10", kVK_F10),
        NamedKeyCode("kVK_F11", kVK_F11),
        NamedKeyCode("kVK_F12", kVK_F12),
        NamedKeyCode("kVK_F13", kVK_F13),
        NamedKeyCode("kVK_F14", kVK_F14),
        NamedKeyCode("kVK_F15", kVK_F15),
        NamedKeyCode("kVK_F16", kVK_F16),
        NamedKeyCode("kVK_F17", kVK_F17),
        NamedKeyCode("kVK_F18", kVK_F18),
        NamedKeyCode("kVK_F19", kVK_F19),
        NamedKeyCode("kVK_F20", kVK_F20),
        NamedKeyCode("kVK_LeftArrow", kVK_LeftArrow),
        NamedKeyCode("kVK_RightArrow", kVK_RightArrow),
        NamedKeyCode("kVK_UpArrow", kVK_UpArrow),
        NamedKeyCode("kVK_DownArrow", kVK_DownArrow),
        NamedKeyCode("kVK_Home", kVK_Home),
        NamedKeyCode("kVK_End", kVK_End),
        NamedKeyCode("kVK_PageUp", kVK_PageUp),
        NamedKeyCode("kVK_PageDown", kVK_PageDown),
        NamedKeyCode("kVK_ForwardDelete", kVK_ForwardDelete),
        NamedKeyCode("kVK_Help", kVK_Help),
    ]

    /// Key codes that must **not** be treated as carrying `fn`, each a near-miss for one that does.
    private static let ordinaryKeys: [NamedKeyCode] = [
        NamedKeyCode("kVK_ANSI_A", kVK_ANSI_A),
        NamedKeyCode("kVK_Space", kVK_Space),
        // The backspace key. One glyph away from kVK_ForwardDelete (0x75) and a completely
        // different key code (0x33); confusing the two is the obvious mistake here.
        NamedKeyCode("kVK_Delete", kVK_Delete),
        NamedKeyCode("kVK_Return", kVK_Return),
        NamedKeyCode("kVK_Escape", kVK_Escape),
        NamedKeyCode("kVK_Tab", kVK_Tab),
        // The `fn` key itself. It is *not* in the implicit set, and must not be: pressing `fn`
        // alone is the flagsChanged event that arms every genuine fn-held binding, and it arrives
        // carrying kVK_Function with the fn bit set. Strip it here and no fn binding can ever
        // start.
        NamedKeyCode("kVK_Function", kVK_Function),
    ]

    // MARK: - Every modifier translates exactly (H1)

    /// Each flag alone becomes its member alone. Both halves are asserted: the member is present
    /// *and* nothing else is, so a translation that returned everything would fail rather than pass
    /// six times over.
    func testEveryModifierBitTranslatesToItsOwnMemberAndNothingElse() {
        XCTAssertFalse(Self.translatedModifiers.isEmpty, "The modifier table is empty.")

        for row in Self.translatedModifiers {
            let translated = HotkeyFlagTranslation.modifiers(
                rawFlags: row.flag.rawValue, keyCode: Self.ordinaryKeyCode)
            XCTAssertEqual(
                translated, row.modifier,
                "\(row.name) must translate to exactly \(row.modifier), got \(translated)")
        }
    }

    /// The whole word at once. A per-bit loop cannot catch a translation that handles each bit in
    /// isolation but overwrites rather than accumulates.
    func testAllModifiersHeldTogetherTranslateTogether() {
        let everything = Self.translatedModifiers.reduce(into: CGEventFlags()) {
            $0.insert($1.flag)
        }
        let expected = Self.translatedModifiers.reduce(into: ModifierSet()) {
            $0.insert($1.modifier)
        }

        XCTAssertEqual(
            HotkeyFlagTranslation.modifiers(
                rawFlags: everything.rawValue, keyCode: Self.ordinaryKeyCode),
            expected,
            "Every modifier held at once must translate to every member at once.")
    }

    /// No flags means no modifiers — the bare-key case, and the one a single-key binding lives on.
    func testAnEmptyFlagWordTranslatesToNoModifiers() {
        XCTAssertEqual(
            HotkeyFlagTranslation.modifiers(rawFlags: 0, keyCode: Self.ordinaryKeyCode), [],
            "A flag word with nothing set must produce no modifiers.")
    }

    /// The whole 64-bit space, one bit at a time: exactly six bits may produce anything, and each
    /// must produce its own member.
    ///
    /// This exists because of a mutation that survived the tests above. Changing `controlBit` from
    /// `0x0004_0000` to `0x0004_0001` — a plausible transcription slip — left all twelve of them
    /// green, because `rawFlags & bit != 0` still matched whenever the real control bit was set and
    /// nothing in the suite ever set bit 0. A constant that is a *superset* of the right bit is
    /// invisible to a table driven only by known-good flag words. Sweeping every bit position is
    /// what makes the constants pinned rather than merely plausible.
    func testExactlySixBitPositionsInTheWholeWordProduceAModifier() {
        let expectedByBit: [UInt64: ModifierSet] = Self.translatedModifiers.reduce(into: [:]) {
            $0[$1.flag.rawValue] = $1.modifier
        }
        XCTAssertEqual(expectedByBit.count, 6, "Each modifier must be a distinct single bit.")

        for position in 0..<64 {
            let word: UInt64 = 1 << position
            let translated = HotkeyFlagTranslation.modifiers(
                rawFlags: word, keyCode: Self.ordinaryKeyCode)
            XCTAssertEqual(
                translated, expectedByBit[word] ?? [],
                """
                Bit \(position) (0x\(String(word, radix: 16, uppercase: true))) alone must produce \
                \(expectedByBit[word].map(String.init(describing:)) ?? "nothing"), got \
                \(translated). A constant covering a bit macOS does not use here is a constant that \
                will match something it should not.
                """)
        }
    }

    // MARK: - Bits Vocca has no member for are dropped, not misread

    func testUnrecognisedFlagBitsAreDropped() {
        XCTAssertFalse(Self.untranslatedFlags.isEmpty, "The untranslated-flag table is empty.")

        for row in Self.untranslatedFlags {
            let translated = HotkeyFlagTranslation.modifiers(
                rawFlags: row.flag.rawValue, keyCode: Self.ordinaryKeyCode)
            XCTAssertEqual(
                translated, [],
                """
                \(row.name) has no ModifierSet member and must be dropped, not mapped onto one. \
                Got \(translated).
                """)
        }
    }

    /// An unrecognised bit set *alongside* recognised ones must not disturb them. This is the shape
    /// a real arrow-key event has: `maskNumericPad` and `maskSecondaryFn` together.
    func testAnUnrecognisedBitDoesNotDisturbTheRecognisedOnes() {
        let flags: CGEventFlags = [.maskControl, .maskShift, .maskNumericPad, .maskNonCoalesced]
        XCTAssertEqual(
            HotkeyFlagTranslation.modifiers(
                rawFlags: flags.rawValue, keyCode: Self.ordinaryKeyCode),
            [.control, .shift],
            "Unrecognised bits must be ignored without taking the recognised ones with them.")
    }

    /// Bits nothing in macOS defines today. A future OS setting one must not silently become a
    /// modifier Vocca thinks the user is holding.
    func testUndefinedHighBitsAreDropped() {
        XCTAssertEqual(
            HotkeyFlagTranslation.modifiers(
                rawFlags: 0xFFFF_FFFF_FFFF_FFFF, keyCode: Self.ordinaryKeyCode),
            Self.translatedModifiers.reduce(into: ModifierSet()) { $0.insert($1.modifier) },
            """
            With every bit in the word set, exactly the six recognised modifiers must appear and \
            nothing else — the translation must read the bits it knows, not everything it is given.
            """)
    }

    // MARK: - The `fn` rule (H1, H2)

    /// Guards the fixture itself, before anything is measured against it.
    ///
    /// **Counting the array is not enough, and that is not a hypothetical.** Review sabotaged this
    /// suite by replacing the `kVK_F20` row with a second `kVK_F16` row and deleting `0x5A` from the
    /// implementation: the array stayed at 30, the *set* fell to 29, the implementation was missing
    /// a key, and all 13 tests passed. `F20` bindings were silently dead.
    ///
    /// That is the same class as the `controlBit` superset mutation this phase set out to close — a
    /// cardinality guard over a container that can hold a duplicate — and it was closed for the flag
    /// constants and missed for the key codes. So all three cardinalities are asserted:
    ///
    /// - the **array**, so no row is deleted outright;
    /// - the **set of codes**, so no row is duplicated to disguise a deletion;
    /// - the **set of names**, because a row's `name` appears only in failure messages and is not
    ///   pinned to its code. `NamedKeyCode("kVK_F20", kVK_F19)` would otherwise make a failure
    ///   message lie about which key is broken, which is worse than no message.
    private func assertTheImplicitKeyTableIsWellFormed(
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = 30
        let rationale =
            "F1–F20 (20) + four arrows + Home/End/PageUp/PageDown (4) + forward-Delete + Help = 30."

        XCTAssertEqual(
            Self.implicitFunctionKeys.count, expected,
            "\(rationale) A short list is a key code whose binding never fires, with this test "
                + "still green.",
            file: file, line: line)

        XCTAssertEqual(
            Set(Self.implicitFunctionKeys.map(\.code)).count, expected,
            "\(rationale) Two rows naming the same key code make the array 30 while the set is 29 "
                + "— the missing key's binding is then silently dead with every test still green. "
                + "Measured: that exact sabotage passed 13/13 before this assertion existed.",
            file: file, line: line)

        XCTAssertEqual(
            Set(Self.implicitFunctionKeys.map(\.name)).count, expected,
            "\(rationale) Two rows carrying the same name mean a failure message names the wrong "
                + "key. The name is only ever read by someone debugging, so a lying one costs more "
                + "than a missing one.",
            file: file, line: line)
    }

    /// The founder's rule, one assertion per key code, each identifiable by its `kVK_` name in the
    /// failure message.
    ///
    /// The table is required to hold exactly 30 *distinct* key codes — see
    /// ``assertTheImplicitKeyTableIsWellFormed(file:line:)``, which exists because counting the
    /// array alone did not catch a deletion disguised by a duplicate.
    func testFunctionIsStrippedForEveryKeyCodeThatCarriesItImplicitly() {
        assertTheImplicitKeyTableIsWellFormed()

        for key in Self.implicitFunctionKeys {
            let translated = HotkeyFlagTranslation.modifiers(
                rawFlags: CGEventFlags.maskSecondaryFn.rawValue, keyCode: key.code)
            XCTAssertEqual(
                translated, [],
                """
                \(key.name) (0x\(String(key.code, radix: 16, uppercase: true))) carries the fn bit \
                with no user involvement, so it must be stripped. Got \(translated). Left in, a \
                binding on this key either never fires (configured []) or ends on the user's first \
                typed character (configured [.function]).
                """)
        }
    }

    /// The published set, compared for equality rather than containment.
    ///
    /// Containment would accept an over-broad set, and an over-broad set is the *other* failure: a
    /// key code wrongly listed here can never be bound with a genuine `fn`, because the bit is
    /// removed before anything compares it.
    func testThePublishedImplicitFunctionKeySetIsExactlyTheDocumentedThirty() {
        // Stands alone rather than relying on the other test having run: the comparison below is
        // against a set derived from the fixture, so a duplicated row shrinks *both* sides at once
        // and the equality holds while a key is missing.
        assertTheImplicitKeyTableIsWellFormed()

        XCTAssertEqual(
            HotkeyFlagTranslation.keyCodesCarryingFunctionImplicitly,
            Set(Self.implicitFunctionKeys.map(\.code)),
            """
            The set the implementation publishes must match the SDK-sourced list exactly. Extra \
            entries make a genuine fn binding on that key impossible; missing entries make an \
            unmodified binding on it impossible.
            """)
    }

    /// Stripping `fn` must not strip anything else. `⇧F13` is a real binding.
    func testStrippingFunctionLeavesTheOtherModifiersAlone() {
        let flags: CGEventFlags = [.maskSecondaryFn, .maskShift, .maskControl]
        for key in Self.implicitFunctionKeys {
            let translated = HotkeyFlagTranslation.modifiers(
                rawFlags: flags.rawValue, keyCode: key.code)
            XCTAssertEqual(
                translated, [.shift, .control],
                "\(key.name): only fn is implicit here — shift and control were genuinely held.")
        }
    }

    // MARK: - The inverse: a genuinely held `fn` survives (H1)

    /// The failure the founder's decision was written to avoid causing. `fn` is bindable, so on a
    /// key code that does not carry it implicitly the bit must reach the session rules intact.
    func testFunctionSurvivesOnKeyCodesThatDoNotCarryItImplicitly() {
        XCTAssertFalse(Self.ordinaryKeys.isEmpty, "The ordinary-key table is empty.")

        for key in Self.ordinaryKeys {
            XCTAssertFalse(
                HotkeyFlagTranslation.keyCodesCarryingFunctionImplicitly.contains(key.code),
                "\(key.name) must not be in the implicit-fn set — this test would be vacuous.")

            let translated = HotkeyFlagTranslation.modifiers(
                rawFlags: CGEventFlags.maskSecondaryFn.rawValue, keyCode: key.code)
            XCTAssertEqual(
                translated, [.function],
                """
                \(key.name) (0x\(String(key.code, radix: 16, uppercase: true))) does not carry fn \
                implicitly, so the bit means the user is holding the key and must survive. Got \
                \(translated). Stripped, every fn-prefixed binding becomes its unprefixed form.
                """)
        }
    }

    /// A genuine `fn` chord, whole.
    func testAGenuineFunctionChordSurvivesIntact() {
        let flags: CGEventFlags = [.maskSecondaryFn, .maskCommand]
        XCTAssertEqual(
            HotkeyFlagTranslation.modifiers(rawFlags: flags.rawValue, keyCode: UInt16(kVK_Space)),
            [.function, .command],
            "fn+command+space is a bindable chord and must translate whole.")
    }

    // MARK: - The flags-state form, which has no key code

    /// **`CGEventSourceFlagsState` has no key code, so the `fn` rule cannot be applied — and the
    /// key-code form must be exactly this plus that rule.**
    ///
    /// Written as an equality against the ordinary form on a key code that carries no implicit `fn`,
    /// rather than as a table of its own, because the failure worth catching is the two drifting: a
    /// flags-only translation with its own copy of the bit table would go stale the day a modifier is
    /// added, and nothing would say so.
    func testTheFlagsOnlyFormIsTheKeyCodeFormMinusTheFunctionRule() {
        for flags: CGEventFlags in [
            [], [.maskControl], [.maskAlternate], [.maskShift], [.maskCommand],
            [.maskSecondaryFn], [.maskAlphaShift],
            [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn,
                .maskAlphaShift],
        ] {
            XCTAssertEqual(
                HotkeyFlagTranslation.modifiers(rawFlags: flags.rawValue),
                HotkeyFlagTranslation.modifiers(
                    rawFlags: flags.rawValue, keyCode: UInt16(kVK_Space)),
                """
                The flags-state translation disagrees with the event translation for \(flags) on a \
                key that carries no implicit fn. There is one bit table and both forms must read it.
                """)
        }
    }

    /// The one place they differ, and the argument that makes it safe.
    ///
    /// On a key that carries `fn` implicitly the event form strips the bit and the flags-state form
    /// cannot, because it has no key code to know it should. That surviving bit reaches
    /// `PhysicalKeyStateReader.physicalModifiers`, whose only consumer asks whether it **contains**
    /// the configured chord — and an extra bit never removes one, so no containment answer changes.
    ///
    /// The second assertion is the boundary of that argument: under *equality* the two differ, which
    /// is exactly why a caller must not compare this value that way. Starting a session is an
    /// equality comparison, which is why the poll and the start rule read different things.
    func testTheFlagsOnlyFormKeepsAnImplicitFunctionBitAndWhyThatIsSafe() {
        let flags: CGEventFlags = [.maskSecondaryFn, .maskAlternate]

        XCTAssertEqual(
            HotkeyFlagTranslation.modifiers(rawFlags: flags.rawValue),
            [.function, .option],
            "the flags-state read has no key code, so an implicitly-set fn survives")
        XCTAssertEqual(
            HotkeyFlagTranslation.modifiers(rawFlags: flags.rawValue, keyCode: UInt16(kVK_F13)),
            [.option],
            "...while the event form, which has one, strips it")

        XCTAssertTrue(
            HotkeyFlagTranslation.modifiers(rawFlags: flags.rawValue)
                .isSuperset(of: [.option]),
            """
            The safety argument, as an assertion: containment is unaffected by the extra bit. If a \
            caller ever compares `physicalModifiers` for equality this stops being true, and a \
            bare-arrow binding becomes one that can never be held.
            """)
        XCTAssertNotEqual(
            HotkeyFlagTranslation.modifiers(rawFlags: flags.rawValue), [.option],
            "and under equality they differ, which is the boundary of that argument.")
    }

    /// The two directions in one place: the *same* flag word, on two key codes, must differ. If it
    /// ever stops differing, either the strip has been removed or it has been made unconditional,
    /// and each of those breaks a different half of `PRODUCT_SPEC.md:257`.
    func testTheSameFlagWordTranslatesDifferentlyByKeyCode() {
        let flags = CGEventFlags.maskSecondaryFn.rawValue
        XCTAssertNotEqual(
            HotkeyFlagTranslation.modifiers(rawFlags: flags, keyCode: UInt16(kVK_F13)),
            HotkeyFlagTranslation.modifiers(rawFlags: flags, keyCode: UInt16(kVK_Space)),
            """
            The key code is the only thing that can distinguish a hardware-set fn bit from a held \
            one. If these two agree, the translation is ignoring it.
            """)
    }
}
