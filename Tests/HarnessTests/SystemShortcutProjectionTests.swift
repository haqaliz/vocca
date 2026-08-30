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
import XCTest

@testable import VoccaHotkey

/// `shortcut-conflicts` criterion 6: **the modifier word maps to ``ModifierSet`` correctly.**
///
/// ## The plan was wrong about which word this is, and the correction is the point
///
/// `plan_20260830.md` §2 says the mask is *"Carbon's, neither `CGEventFlags`' nor ours"* and asks
/// for it to be verified against `Carbon/HIToolbox/Events.h`. It was, and it is not Carbon's:
/// Carbon's `cmdKey` is `1 << 8` (`cmdKeyBit = 8`, read from the SDK header on 2026-08-30), which
/// is `0x100`. The plan's own numbers — 0x20000, 0x40000, 0x80000, 0x100000 — are
/// `NSEventModifierFlag`/`kCGEventFlagMask` values, `1 << 17` through `1 << 20`, and the live
/// plist agrees: identifier 118's mask is 262144, which is `1 << 18`, and ⌃1 is what macOS shows
/// for it. So the plan's **values** are right and its **attribution** is wrong.
///
/// That correction is what makes this file short. Because the word is `CGEventFlags`', the
/// translation Vocca needs is the one it already has — ``HotkeyFlagTranslation``, pinned against
/// the SDK's own constants by `HotkeyFlagTranslationTests` — and a second transcription of the
/// same bits would be a copy that can drift. A drifted copy shows up as a hotkey warning that
/// never appears, which nobody reports.
///
/// Every mask below is one this machine's live `com.apple.symbolichotkeys` actually holds, read on
/// 2026-08-30, except the single-modifier rows that no shipped shortcut happens to use.
final class SystemShortcutProjectionTests: XCTestCase {

    // MARK: - Criterion 6: the mask table

    /// Each of the four bindable modifiers, singly and in the combinations macOS ships.
    func testTheModifierWordMapsToTheModifiersMacOSMeans() {
        let table: [(mask: UInt64, expected: ModifierSet, note: String)] = [
            (0x0002_0000, [.shift], "1 << 17 — shift"),
            (0x0004_0000, [.control], "1 << 18 — control; live identifier 118 reads 262144"),
            (0x0008_0000, [.option], "1 << 19 — option"),
            (0x0010_0000, [.command], "1 << 20 — command; live identifier 260 reads 1048576"),
            (
                0x000C_0000, [.control, .option],
                "786432 — live identifier 61, ⌃⌥Space, select next input source"
            ),
            (
                0x0006_0000, [.shift, .control],
                "393216 — the shift-and-control pair, as identifier 34 carries it minus its fn"
            ),
            (
                0x001E_0000, [.shift, .control, .option, .command],
                "all four at once — nothing ships this, and the translation must still be exact"
            ),
            (0, [], "0 — a shortcut with no modifiers at all"),
        ]

        for row in table {
            let projected = SystemShortcutProjection.shortcuts(from: [
                .init(identifier: 118, keyCode: 18, rawModifierFlags: row.mask)
            ])

            XCTAssertEqual(
                projected.map(\.chord.modifiers), [row.expected],
                """
                mask \(row.mask) must be \(row.expected): \(row.note). This word is \
                CGEventFlags', not Carbon's — Carbon's cmdKey is 0x100, not 0x100000 — and a \
                wrong constant here is not a compile error, it is a collision Vocca never \
                mentions.
                """)
        }
    }

    /// **The `fn` rule reaches the shortcut table too**, and it has to: the shortcuts most likely
    /// to collide with a user's chord are the arrow-key ones.
    ///
    /// macOS sets the `fn` bit on arrow keys and F-keys with no user involvement, so this
    /// machine's identifier 32 — Mission Control's ⌃↑ — reads mask 8650752, which is
    /// `fn | control`. A recorder produces `[.control]` for that same press, because
    /// ``HotkeyFlagTranslation`` strips the implicit bit. Left unstripped here, the two chords
    /// would never be equal and **every arrow-key system shortcut would be invisible to the
    /// collision check** — silently, and for exactly the shortcuts that matter most.
    func testAnImplicitFunctionBitIsStrippedJustAsItIsForALiveKeyPress() {
        let missionControl = SystemShortcutProjection.shortcuts(from: [
            .init(identifier: 32, keyCode: 0x7E, rawModifierFlags: 0x0084_0000)
        ])

        XCTAssertEqual(
            missionControl.map(\.chord.modifiers), [[.control]],
            """
            Identifier 32 reads [65535, 126, 8650752] on this machine: the Up arrow with \
            fn | control. The fn bit is the hardware's, not the user's, so the chord is ⌃↑ — \
            which is what a recorder produces for the same press.
            """)

        let heldFunction = SystemShortcutProjection.shortcuts(from: [
            .init(identifier: 999, keyCode: 49, rawModifierFlags: 0x0080_0000)
        ])

        XCTAssertEqual(
            heldFunction.map(\.chord.modifiers), [[.function]],
            """
            ...but on a key that does not carry fn implicitly, the bit means the user is holding \
            it, and it survives. Stripping unconditionally would make every genuine fn binding \
            interchangeable with its bare form — the right symptom cured at the wrong layer.
            """)
    }

    /// The projection carries the key code through untouched, and preserves order.
    func testTheProjectionCarriesEachKeyCodeThroughInOrder() {
        let projected = SystemShortcutProjection.shortcuts(from: [
            .init(identifier: 118, keyCode: 18, rawModifierFlags: 0x0004_0000),
            .init(identifier: 119, keyCode: 19, rawModifierFlags: 0x0004_0000),
        ])

        XCTAssertEqual(projected.map(\.chord.keyCode), [18, 19])
    }

    // MARK: - The name reaches the shortcut, or does not

    /// A projected shortcut carries the name for identifiers that have one, and `nil` for the rest.
    ///
    /// Both halves in one test because they are one claim: the projection asks
    /// ``SystemShortcutNames``, and asks it about the identifier it was handed rather than about
    /// anything it invents. A projection that named everything `nil` would pass a positive-only
    /// test while making the whole names table dead code.
    func testTheProjectionNamesWhatItCanAndLeavesTheRestUnnamed() {
        let projected = SystemShortcutProjection.shortcuts(from: [
            .init(identifier: 118, keyCode: 18, rawModifierFlags: 0x0004_0000),
            .init(identifier: 133, keyCode: 22, rawModifierFlags: 0x000C_0000),
            .init(identifier: 32, keyCode: 0x7E, rawModifierFlags: 0x0084_0000),
        ])

        XCTAssertEqual(
            projected.map(\.name),
            ["Switch to Desktop 1", "Switch to Desktop 16", nil],
            """
            118 and 133 are the two ends of the range verified against Apple's own tables; 32 is \
            ⌃↑ on this machine and no shipped table names it, so it is reported unnamed rather \
            than guessed at or dropped.
            """)
    }
}
