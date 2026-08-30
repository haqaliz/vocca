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

import XCTest

@testable import VoccaCore

/// `shortcut-conflicts` criteria 2 and 4: the pure decode of `com.apple.symbolichotkeys`, driven
/// over fixtures.
///
/// ## Where the fixtures come from
///
/// The shapes below are not invented. They are the entries Apple's own
/// `KeyboardSettings.appex/Contents/Resources/DefaultSpacesShortcuts.xml` declares and the entries
/// this machine's live `com.apple.symbolichotkeys` holds, read on 2026-08-30 — identifier 118 is
/// `[49, 18, 262144]` in both. Everything malformed below is a deliberate mutation of one of them.
///
/// ## Every failure mode is silence
///
/// The format is undocumented, so every field is treated as hostile. Absent, truncated, wrongly
/// typed, out of range, disabled — all yield **no entry**, never a throw and never a refusal. The
/// worst outcome of a decode failure is that Vocca fails to mention a collision the user will
/// notice within seconds anyway; the worst outcome of the alternative is a rebind that cannot be
/// completed.
final class SymbolicHotkeyDecodingTests: XCTestCase {

    /// Identifier 118 exactly as Apple's `DefaultSpacesShortcuts.xml` declares it, and exactly as
    /// this machine's live plist holds it: ⌃1, *Switch to Desktop 1*.
    private static let switchToDesktopOne = SymbolicHotkeyDecoding.RawEntry(
        identifier: 118, isEnabled: true, parameters: [49, 18, 262_144])

    // MARK: - Criterion 1's decode half: a well-formed enabled entry

    /// A well-formed enabled entry yields its key code and its modifier word.
    ///
    /// `parameters[1]` is the key code and `parameters[2]` the modifier mask. **`parameters[0]` is
    /// deliberately never read**: it is the character code, which is layout-dependent — 49 here is
    /// the character `1`, which is only what that key produces on a US layout.
    func testAWellFormedEnabledEntryDecodesItsKeyCodeAndModifierWord() {
        XCTAssertEqual(
            SymbolicHotkeyDecoding.decode(Self.switchToDesktopOne),
            SymbolicHotkeyDecoding.DecodedEntry(
                identifier: 118, keyCode: 18, rawModifierFlags: 262_144),
            """
            Identifier 118 is [49, 18, 262144] in Apple's own default table and in this machine's \
            live plist: key code 18, modifier word 262144. Reading parameters[0] instead would \
            give 49 — Space — which is a different key entirely.
            """)
    }

    // MARK: - Criterion 2: the `enabled` flag is honoured

    /// A **disabled** entry yields nothing, even though every other field is well formed.
    ///
    /// The user turned that shortcut off. Warning about it would tell them a chord is taken by
    /// something that will never fire — and on a machine where a user has deliberately cleared
    /// Apple's shortcuts to make room for their own, it would warn about most of what they picked.
    func testADisabledEntryDecodesToNothing() {
        let disabled = SymbolicHotkeyDecoding.RawEntry(
            identifier: 118, isEnabled: false, parameters: [49, 18, 262_144])

        XCTAssertNil(
            SymbolicHotkeyDecoding.decode(disabled),
            """
            A disabled shortcut does not occupy its chord. Warning about one would tell the user \
            a key is taken by something they have already switched off.
            """)
    }

    /// An entry whose `enabled` flag is **absent, or present but not a boolean**, yields nothing.
    ///
    /// Silence rather than an assumption in either direction. The format is undocumented, so a
    /// missing flag is a shape we do not understand, and the rule for those is the rule for every
    /// other one here.
    func testAnEntryWithNoReadableEnabledFlagDecodesToNothing() {
        XCTAssertNil(
            SymbolicHotkeyDecoding.decode(
                SymbolicHotkeyDecoding.RawEntry(
                    identifier: 118, isEnabled: nil, parameters: [49, 18, 262_144])),
            """
            An absent or non-boolean `enabled` flag is a shape this decode does not understand, \
            and an unrecognised shape is silence — never a guess in either direction.
            """)
    }

    // MARK: - Criterion 4: every malformed shape is silence

    /// **The malformed table.** Each row is a deliberate mutation of identifier 118, and every one
    /// of them decodes to nothing.
    ///
    /// Driven as a table rather than as one test per row because the claim is about the *set*: it
    /// is not that these particular shapes are handled, it is that no shape but the well-formed
    /// one produces an entry. A row added here as macOS changes costs one line.
    func testEveryMalformedShapeDecodesToNothing() {
        let malformed: [(String, SymbolicHotkeyDecoding.RawEntry)] = [
            (
                "no parameters at all — the key is absent, or is not an array",
                .init(identifier: 118, isEnabled: true, parameters: nil)
            ),
            (
                "an empty parameters array",
                .init(identifier: 118, isEnabled: true, parameters: [])
            ),
            (
                "a parameters array truncated to two elements — the modifier mask is missing",
                .init(identifier: 118, isEnabled: true, parameters: [49, 18])
            ),
            (
                "a non-integer key code at position 1",
                .init(identifier: 118, isEnabled: true, parameters: [49, nil, 262_144])
            ),
            (
                "a non-integer modifier mask at position 2",
                .init(identifier: 118, isEnabled: true, parameters: [49, 18, nil])
            ),
            (
                "a negative key code, which no virtual key code is",
                .init(identifier: 118, isEnabled: true, parameters: [49, -1, 262_144])
            ),
            (
                "a key code past the end of UInt16",
                .init(identifier: 118, isEnabled: true, parameters: [49, 70_000, 262_144])
            ),
            (
                "a negative modifier word",
                .init(identifier: 118, isEnabled: true, parameters: [49, 18, -262_144])
            ),
        ]

        for (shape, entry) in malformed {
            XCTAssertNil(
                SymbolicHotkeyDecoding.decode(entry),
                """
                \(shape) must decode to nothing. The format is undocumented and Apple may change \
                it in any release; a decode that guessed at a shape it did not recognise would \
                warn about a chord the user is free to bind, and the user cannot tell a wrong \
                warning from a right one.
                """)
        }
    }

    /// **A non-integer at position 0 still decodes**, because position 0 is never read.
    ///
    /// The complement of the table above, and the one row that proves the tolerance is aimed
    /// rather than blanket: a decode that gave up on any malformed element would drop a
    /// perfectly good shortcut over a field it does not use.
    func testAMalformedCharacterCodeDoesNotStopTheDecode() {
        XCTAssertEqual(
            SymbolicHotkeyDecoding.decode(
                SymbolicHotkeyDecoding.RawEntry(
                    identifier: 118, isEnabled: true, parameters: [nil, 18, 262_144])),
            SymbolicHotkeyDecoding.DecodedEntry(
                identifier: 118, keyCode: 18, rawModifierFlags: 262_144),
            """
            parameters[0] is the layout-dependent character code and is never read, so a \
            malformed one must not cost us the key code beside it.
            """)
    }

    /// The **0xFFFF sentinel** — an entry with no key — decodes to nothing.
    ///
    /// Not a hypothetical: this machine's live plist holds four of them (identifiers 163, 164,
    /// 175 and 222 all read `[65535, 65535, 0]`), and every unbound Spaces row reads 65535 in
    /// position 0 too. macOS writes 65535 where there is no key, and an entry with no key claims
    /// no chord. Letting it through would put a shortcut in the table whose "chord" is key 65535
    /// with no modifiers — harmless only by luck, because no real key code is 65535.
    func testTheNoKeySentinelDecodesToNothing() {
        XCTAssertNil(
            SymbolicHotkeyDecoding.decode(
                SymbolicHotkeyDecoding.RawEntry(
                    identifier: 163, isEnabled: true, parameters: [65535, 65535, 0])),
            """
            65535 is macOS's "no key" sentinel — four entries on the authoring machine read \
            exactly this — and an entry with no key occupies no chord.
            """)
    }

    /// The array form drops what it cannot decode and keeps what it can, in order.
    ///
    /// One bad entry must not cost the good ones beside it: the plist is read whole, and a single
    /// shape macOS changed would otherwise silence the entire check rather than one row of it.
    func testTheArrayFormKeepsWhatItCanAndDropsTheRest() {
        let entries: [SymbolicHotkeyDecoding.RawEntry] = [
            Self.switchToDesktopOne,
            .init(identifier: 15, isEnabled: false, parameters: nil),
            .init(identifier: 119, isEnabled: true, parameters: [65535, 19, 262_144]),
            .init(identifier: 999, isEnabled: true, parameters: [1]),
        ]

        XCTAssertEqual(
            SymbolicHotkeyDecoding.decode(entries),
            [
                .init(identifier: 118, keyCode: 18, rawModifierFlags: 262_144),
                .init(identifier: 119, keyCode: 19, rawModifierFlags: 262_144),
            ],
            """
            A disabled entry and a truncated one are dropped; the two well-formed ones survive in \
            order. One shape macOS changed must cost one row, never the whole check.
            """)
    }
}
