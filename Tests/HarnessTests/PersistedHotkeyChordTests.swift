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

/// The persisted hotkey chord — the `binding-store` aspect's Core half (`plan_20260830.md`
/// phase 1): the shipped default, and the tolerant decode that reads a stored pair of strings
/// back into a chord.
///
/// The three-answer contract is `PersistedSettings`' existing one and is not restated here:
/// **absent → the shipped chord, silently**; **malformed → the shipped chord plus exactly one
/// report**; **known → the stored chord, silently**. What this file adds is the reason the
/// aspect needed a table of its own — a chord is *two* stored strings, so there is a fourth
/// input shape the other settings do not have (half of a pair), and the decoded value is
/// validated rather than trusted, because a hand-edited plist must not reach a binding the
/// recorder would have refused.
final class PersistedHotkeyChordTests: XCTestCase {

    // MARK: - Absent

    /// An install that has never rebound reads the shipped chord — ⌥Space — and **nothing is
    /// logged**. Both keys absent is the normal path, not an error.
    func testBothKeysAbsentIsTheShippedChordAndReportsNothing() {
        var reports: [String] = []
        let chord = PersistedSettings.decodeHotkeyChord(
            keyCodeRaw: nil, modifiersRaw: nil, onInvalidValue: { reports.append($0) })

        XCTAssertEqual(chord.keyCode, PersistedSettings.defaultHotkeyKeyCode)
        XCTAssertEqual(chord.modifiers, PersistedSettings.defaultHotkeyModifiers)
        XCTAssertEqual(reports, [], "a fresh install has bound nothing — that is not an error")
    }

    // MARK: - Known

    /// A stored chord the rules accept decodes to itself, and reports nothing.
    ///
    /// Deliberately **not** ⌥Space: a row whose expected answer is the shipped default passes
    /// against a decode that ignores its inputs entirely, which is the one thing this test has
    /// to rule out. ⌃⌘F13 is a chord nothing would fall back to.
    func testAValidStoredChordDecodesToItselfSilently() {
        var reports: [String] = []
        let chord = PersistedSettings.decodeHotkeyChord(
            keyCodeRaw: "105", modifiersRaw: "9", onInvalidValue: { reports.append($0) })

        XCTAssertEqual(chord.keyCode, 0x69, "kVK_F13")
        XCTAssertEqual(chord.modifiers, [.control, .command])
        XCTAssertEqual(reports, [], "a readable chord is not an error")
    }

    // MARK: - Half a pair

    /// A key code with no modifiers key beside it is **malformed, not absent** — the shipped
    /// chord plus exactly one report.
    ///
    /// This is the case the two-key shape was chosen to make visible (`plan_20260830.md` §1.2).
    /// Reading it as absent would be tolerable; reading the present half and defaulting the
    /// other would not — that synthesises a chord nobody chose, and an unmodified key code that
    /// arrived with its modifiers missing is exactly the shape that binds a bare letter and
    /// makes it untypeable system-wide.
    func testAKeyCodeWithNoModifiersIsMalformedAndReportedOnce() {
        var reports: [String] = []
        let chord = PersistedSettings.decodeHotkeyChord(
            keyCodeRaw: "105", modifiersRaw: nil, onInvalidValue: { reports.append($0) })

        XCTAssertEqual(chord, PersistedSettings.defaultHotkeyChord)
        XCTAssertEqual(reports.count, 1, "exactly one report per unreadable binding; got \(reports)")
    }

    /// The mirror: modifiers with no key code beside them. Driven separately rather than
    /// folded into the row above because the two halves are written by different code paths and
    /// a guard that checks one direction only is the natural way to get this wrong.
    func testModifiersWithNoKeyCodeAreMalformedAndReportedOnce() {
        var reports: [String] = []
        let chord = PersistedSettings.decodeHotkeyChord(
            keyCodeRaw: nil, modifiersRaw: "9", onInvalidValue: { reports.append($0) })

        XCTAssertEqual(chord, PersistedSettings.defaultHotkeyChord)
        XCTAssertEqual(reports.count, 1, "exactly one report per unreadable binding; got \(reports)")
    }

    // MARK: - Unreadable numbers

    /// A key code that is not a number at all — someone hand-editing the plist wrote the key's
    /// name. The shipped chord plus one report, and the report **names the value it rejected**,
    /// since a report that does not name it cannot be acted on.
    func testANonNumericKeyCodeIsMalformedAndReportedOnce() {
        var reports: [String] = []
        let chord = PersistedSettings.decodeHotkeyChord(
            keyCodeRaw: "space", modifiersRaw: "2", onInvalidValue: { reports.append($0) })

        XCTAssertEqual(chord, PersistedSettings.defaultHotkeyChord)
        XCTAssertEqual(reports.count, 1, "exactly one report per unreadable binding; got \(reports)")
        XCTAssertTrue(
            reports.first?.contains("space") == true,
            "the report must name the value it rejected; got \(reports)")
    }

    /// A key code numerically outside `UInt16` — the shipped chord plus one report, **never a
    /// truncated or clamped number**.
    ///
    /// A pin rather than a new branch: `UInt16.init?(_: String)` already refuses it, so this row
    /// guards the *way* the parse is written. The mutation it exists to catch is the plausible
    /// repair — swapping in `UInt16(clamping:)` or `UInt16(truncatingIfNeeded:)` so that "the
    /// number always parses" — which silently binds key 65535, a key no keyboard has and no user
    /// can press.
    func testAnOutOfRangeKeyCodeIsMalformedAndNeverTruncated() {
        var reports: [String] = []
        let chord = PersistedSettings.decodeHotkeyChord(
            keyCodeRaw: "70000", modifiersRaw: "2", onInvalidValue: { reports.append($0) })

        XCTAssertEqual(chord, PersistedSettings.defaultHotkeyChord)
        XCTAssertEqual(reports.count, 1, "exactly one report per unreadable binding; got \(reports)")
    }

    /// A modifiers word carrying a bit `ModifierSet` does not define — the shipped chord plus one
    /// report.
    ///
    /// `UInt16` parses `64` happily, so nothing before this checks it: an unknown bit would reach
    /// a live `ModifierSet` and be compared for equality against every real key press, which no
    /// press can ever satisfy. The result is a hotkey that is stored, displayed and completely
    /// dead — the failure mode a user cannot diagnose, because Settings would show them the
    /// binding they chose.
    func testModifierBitsOutsideTheDefinedSetAreMalformedAndReportedOnce() {
        var reports: [String] = []
        let chord = PersistedSettings.decodeHotkeyChord(
            keyCodeRaw: "105", modifiersRaw: "64", onInvalidValue: { reports.append($0) })

        XCTAssertEqual(chord, PersistedSettings.defaultHotkeyChord)
        XCTAssertEqual(reports.count, 1, "exactly one report per unreadable binding; got \(reports)")
    }

    /// The companion pin: ``PersistedSettings/knownModifierBits`` really is every bit
    /// ``ModifierSet`` defines, named one at a time.
    ///
    /// `ModifierSet` is an `OptionSet` and has no `allCases` to derive this from, so the union is
    /// written out — and a modifier added to `ModifierSet` without being added there would be
    /// rejected by the decode as an unknown bit, silently resetting the binding of every user who
    /// had chosen it. This row is what fails instead.
    func testTheKnownModifierBitsAreEveryBitModifierSetDefines() {
        XCTAssertEqual(
            PersistedSettings.knownModifierBits,
            [.control, .option, .shift, .command, .function, .capsLock])
        XCTAssertEqual(
            PersistedSettings.knownModifierBits.rawValue, 0b11_1111,
            "six defined bits, contiguous from bit 0")
    }

    // MARK: - Validated, not trusted

    /// A stored chord the binding rules **refuse** is malformed — the shipped chord plus one
    /// report — even though both strings parsed perfectly.
    ///
    /// Bare `e` (`kVK_ANSI_E`, `0x0E`, no modifiers) is the worked example: the tap swallows what
    /// is bound (`ARCHITECTURE.md` §13), so a binding the recorder would have refused makes `e`
    /// untypeable on the whole machine, with the recovery path behind a Settings window the user
    /// now needs that keyboard to reach. A plist is hand-editable and a downgrade can narrow the
    /// safe table, so "the recorder would never have written this" is not a guarantee the read
    /// side may rely on.
    func testAStoredChordTheRulesRefuseIsMalformedAndReportedOnce() {
        var reports: [String] = []
        let chord = PersistedSettings.decodeHotkeyChord(
            keyCodeRaw: "14", modifiersRaw: "0", onInvalidValue: { reports.append($0) })

        XCTAssertEqual(
            HotkeyBindingRules.validate(keyCode: 0x0E, modifiers: []),
            .refused(.unmodifiedTextEntryKey),
            "the premise: bare e is a chord the rules refuse")
        XCTAssertEqual(chord, PersistedSettings.defaultHotkeyChord)
        XCTAssertEqual(reports.count, 1, "exactly one report per unreadable binding; got \(reports)")
    }

    /// A chord that **warns** is adopted, silently. Warnings are not refusals.
    ///
    /// ## Why this row is driven over the decision and not over the decode
    ///
    /// `HotkeyBindingRules.validate` produces no ``HotkeyBindingValidity/warned`` today —
    /// `binding-vocabulary` shipped the case and no producer, because reading Apple's shortcut
    /// table is `shortcut-conflicts`' aspect and most of that question is undecidable
    /// (`prd.md` §5.3). So there is no pair of strings that reaches the warned arm through
    /// `decodeHotkeyChord`, and a row that pretended otherwise would be asserting against a stub.
    /// The decision itself is reachable, so the decision is what is driven — and the decode calls
    /// exactly this function, so when `shortcut-conflicts` gives the rules something to warn
    /// about, the answer here is already the one it gets.
    ///
    /// The direction matters more than the mechanism: startup must never become a gate on
    /// `shortcut-conflicts`. A user whose ⌥Space collides with something Apple ships keeps their
    /// binding and is told about it in Settings; they do not launch Vocca one morning and find it
    /// silently back on the shipped chord.
    func testAWarnedChordIsAdoptedAndARefusedOneIsNot() {
        XCTAssertTrue(PersistedSettings.isAdoptable(.accepted))
        XCTAssertTrue(
            PersistedSettings.isAdoptable(.warned(.usedBySystemShortcut(name: "Spotlight"))),
            "a warning is not a refusal — a stored binding survives a conflict it can be told about")
        XCTAssertTrue(
            PersistedSettings.isAdoptable(.warned(.usedBySystemShortcut(name: nil))),
            "including the common shape, where the conflict is known and its owner is not")

        for refusal in HotkeyBindingRefusal.allCases {
            XCTAssertFalse(
                PersistedSettings.isAdoptable(.refused(refusal)),
                "\(refusal) must not be adoptable from storage")
        }
    }

    /// A stored **single key** with no modifiers at all is adopted, silently — bare F13.
    ///
    /// `PRODUCT_SPEC.md:257` calls single-key bindings an accessibility requirement rather than a
    /// preference: they exist for users who cannot hold a chord. The row above added a refusal
    /// path to this decode, and the obvious way to write that refusal too broadly is to treat an
    /// empty modifier set as suspect — which would reset exactly the bindings that were chosen
    /// because a chord could not be held, on every launch, loudly, and with no way to set them
    /// again.
    func testASafeSingleKeyIsAdoptedSilently() {
        var reports: [String] = []
        let chord = PersistedSettings.decodeHotkeyChord(
            keyCodeRaw: "105", modifiersRaw: "0", onInvalidValue: { reports.append($0) })

        XCTAssertEqual(chord, HotkeyChord(keyCode: 0x69, modifiers: []), "bare F13")
        XCTAssertEqual(reports, [], "a binding the rules accept is not an error")
    }

    // MARK: - Caps Lock

    /// A stored chord carrying ``ModifierSet/capsLock`` is adopted **with the bit masked**, and
    /// silently.
    ///
    /// `ModifierSet.locking` is masked on both sides of every hotkey comparison, so a binding that
    /// kept the bit could never match a real key press: it would be a hotkey that is stored,
    /// rendered correctly in Settings, and completely dead. The write side masks too, so this can
    /// only arrive from a hand-edit or an older build — which is exactly why the read side cannot
    /// assume it away. Silent rather than reported: nothing was lost, the chord the user meant is
    /// the chord they get.
    func testAStoredChordCarryingCapsLockIsAdoptedWithTheBitMasked() {
        var reports: [String] = []
        let chord = PersistedSettings.decodeHotkeyChord(
            keyCodeRaw: "105", modifiersRaw: "34", onInvalidValue: { reports.append($0) })

        XCTAssertEqual(ModifierSet(rawValue: 34), [.option, .capsLock], "the premise")
        XCTAssertEqual(chord.modifiers, [.option], "Caps Lock is not part of a binding")
        XCTAssertEqual(chord.keyCode, 0x69)
        XCTAssertEqual(reports, [], "nothing was lost — the chord the user meant is the chord stored")
    }
}
