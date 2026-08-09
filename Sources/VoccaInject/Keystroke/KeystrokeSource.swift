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

import CoreGraphics

/// **The keystroke adapter — the one file in `VoccaInject` permitted to speak CoreGraphics.**
///
/// The keystroke rung of the injection ladder (`ARCHITECTURE.md:402`) must name `CGEvent` and
/// `CGKeyCode` to synthesise keystrokes, and the H7 seam lint is a per-seam table: the tap seam
/// keeps its one file (`VoccaHotkey/CGEventTapSource.swift`) and the keystroke seam gains this
/// one — `InjectionSeamBoundaryTests` names both, and nothing else in `Sources/` may name the
/// family. No other file in `VoccaInject` names a CoreGraphics identifier: the clipboard rung's
/// ⌘V goes through ``KeystrokeSynthesizing/pressPaste()``, exactly as the tap adapter's decisions
/// all sit above the seam.
///
/// Like the tap adapter, this file is **executed by nothing in CI**. Posting events into the login
/// session needs a real user session and an Accessibility grant — the same TCC wall `tapCreate`
/// hits, which a hosted runner cannot be given — so every line below is translation with no
/// decisions in it, and the decisions that *would* live here are made above the seam instead:
///
/// | The question | Where it is answered |
/// |---|---|
/// | How large is each chunk? | The keystroke rung strategy (``typeText(_:chunkSize:)`` receives the size) |
/// | How long between chunks? | The keystroke rung strategy (pacing is not this file's business) |
/// | Should a field that refused the text be retried? | The ladder's decision, via ``RungAttempt`` |
/// | What does a timeout mean? | The decision function, never an adapter (`ARCHITECTURE.md:400`) |
///
/// If this file grows an `if` that decides something, the `if` is in the wrong half. It translates
/// text into key events and forwards them; everything else arrives as parameters.
///
/// ## Isolation
///
/// The type holds no state, so it has no isolation requirements of its own: it is callable from
/// whatever context the rung runs in. It is not annotated `@MainActor` — nothing here touches a
/// run loop, and the rung's context (like the ladder's) decides where the calls land. The seam
/// gains `Sendable` in the phase that first crosses an actor boundary with it, and not before.
final class KeystrokeSource: KeystrokeSynthesizing {

    init() {}

    // MARK: - KeystrokeSynthesizing

    func typeText(_ text: String, chunkSize: Int) {
        // The chunk size is policy, decided above the seam and passed in; this loop is the
        // translation of that policy into per-chunk event bursts. A caller that passes a
        // non-positive size gets single-character chunks, which is a guard against a hang rather
        // than a pacing decision — a zero step would never advance this loop.
        let characters = Array(text)
        let step = max(chunkSize, 1)
        var index = 0
        while index < characters.count {
            let end = min(index + step, characters.count)
            for character in characters[index..<end] {
                type(character)
            }
            index = end
        }
    }

    func pressPaste() {
        // ⌘V, the one gesture the clipboard rung needs from this seam: the rung saves the
        // pasteboard, writes, asks for a paste and restores — and never names a `CGEvent` itself.
        post(keyCode: Self.pasteKeyCode, with: .maskCommand)
    }

    // MARK: - One character, as key events

    /// One character as a key-down/key-up pair, or as many pairs as its grapheme cluster needs.
    private func type(_ character: Character) {
        // A character the user types with Shift held — the uppercase letters and the symbols above
        // the digit row — is produced by its base key with `.maskShift` set on the events.
        if let base = Self.baseCharacterByShiftedCharacter[character],
            let keyCode = Self.keyCodeByBaseCharacter[base]
        {
            post(keyCode: keyCode, with: .maskShift)
            return
        }
        if let keyCode = Self.keyCodeByBaseCharacter[character] {
            post(keyCode: keyCode, with: [])
            return
        }
        // Everything the US layout cannot express — accented letters, symbols, emoji — goes out as
        // a Unicode string attached to the event pair. A cluster of several scalars is typed one
        // scalar per pair; the input side composes them.
        for scalar in character.unicodeScalars {
            postUnicodeScalar(scalar)
        }
    }

    /// A key-down/key-up pair for `keyCode`, both carrying `flags`, posted to the session tap.
    private func post(keyCode: CGKeyCode, with flags: CGEventFlags) {
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// One Unicode scalar as an event pair carrying it, for characters no key produces.
    private func postUnicodeScalar(_ scalar: Unicode.Scalar) {
        let code = UInt16(truncatingIfNeeded: scalar.value)
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return }
        var unicode = code
        down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicode)
        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicode)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - The two tables this file is allowed

    /// The virtual key code of each unshifted printable ASCII key, keyed by the character it
    /// produces. Transcribed by hand from Carbon's `kVK_*` constants, deliberately not imported —
    /// the ``HotkeyFlagTranslation`` precedent: the two files that may speak CoreGraphics keep
    /// their own spelling of the constants so neither needs the headers, and the values are
    /// stable ABI (`CarbonEvents.h`, every release since the first).
    private static let keyCodeByBaseCharacter: [Character: CGKeyCode] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03, "g": 0x05,
        "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D,
        "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11, "u": 0x20,
        "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10, "z": 0x06,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A,
        "8": 0x1C, "9": 0x19, "0": 0x1D,
        "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E, "\\": 0x2A, ";": 0x29, "'": 0x27,
        ",": 0x2B, ".": 0x2F, "/": 0x2C, "`": 0x32,
        " ": 0x31, "\t": 0x30, "\n": 0x24, "\r": 0x24,
    ]

    /// The unshifted character behind each shifted printable — what Shift plus the base key
    /// produces. `"A"` → `"a"`, `"!"` → `"1"`, `"{"` → `"["`, and so on down the US layout.
    private static let baseCharacterByShiftedCharacter: [Character: Character] = [
        "A": "a", "B": "b", "C": "c", "D": "d", "E": "e", "F": "f", "G": "g",
        "H": "h", "I": "i", "J": "j", "K": "k", "L": "l", "M": "m", "N": "n",
        "O": "o", "P": "p", "Q": "q", "R": "r", "S": "s", "T": "t", "U": "u",
        "V": "v", "W": "w", "X": "x", "Y": "y", "Z": "z",
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
        "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'",
        "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// The virtual key code of V, whose pair with Command is the paste gesture.
    private static let pasteKeyCode: CGKeyCode = 0x09
}

/// **The seam the clipboard rung and the keystroke rung inject.** `pressPaste()` is the ⌘V the
/// clipboard rung needs (it names no `CGEvent`, which is the point of the per-seam table);
/// `typeText(_:chunkSize:)` is the keystroke rung's whole delivery surface, with the chunk size —
/// the one policy knob the file is not allowed to own — arriving as a parameter.
///
/// Nothing here is `Sendable` yet: the seam is not crossing an actor boundary in this phase, and
/// the file that first crosses one decides (the ``InjectionRungStrategy`` precedent — the ladder's
/// seam carries `Sendable` because the decision awaits rungs across suspension points).
protocol KeystrokeSynthesizing {
    /// Type `text`, in bursts of at most `chunkSize` characters, with no pacing between bursts.
    ///
    /// The size is the caller's policy — the rung strategy decides how large a burst is safe for
    /// the focused field and how long to wait between them, and this file only slices.
    func typeText(_ text: String, chunkSize: Int)

    /// Synthesise ⌘V: the paste the clipboard rung issues between its write and its restore.
    func pressPaste()
}
