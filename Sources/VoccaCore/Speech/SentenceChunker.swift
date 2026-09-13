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

/// Splits text into sentence chunks — the shape `SpeechSynthesizer` adapters render one
/// utterance per chunk from, so speech can begin before the full reply is synthesized
/// (`speech-seam/spec.md` R2, G4).
///
/// ## The boundary rule
///
/// - A chunk boundary is `.` `!` `?` or `…` immediately followed by whitespace-or-end-of-input,
///   and the punctuation stays on the chunk.
/// - Surrounding whitespace is trimmed off every chunk; empty chunks are dropped, so
///   whitespace-only input yields `[]` and empty input yields `[]`.
/// - A run with no boundary stays whole — the chunker never splits mid-word.
/// - **The `space-after` abbreviation rule** (shallow by design, pinned as shipped): a `.`
///   followed by whitespace is *not* a boundary when the letter-token immediately before it is
///   non-empty and vowel-free — `Mr.` `Dr.` `St.` `vs.` are abbreviations; `went.` and even
///   two-letter `No.` are real sentence ends. A period after a non-letter (`5.`) is a real
///   boundary. A smarter segmenter is a later unit's choice.
public enum SentenceChunker {

    /// The sentence-ending punctuation the chunker splits on.
    public static let boundaryCharacters: Set<Character> = [".", "!", "?", "…"]

    /// The vowel letters of the abbreviation rule, both cases.
    private static let vowelLetters: Set<Character> = ["a", "e", "i", "o", "u", "A", "E", "I", "O", "U"]

    /// Splits `text` into sentence chunks per the boundary rule above.
    public static func sentenceChunks(of text: String) -> [String] {
        let characters = Array(text)
        var chunks: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            current.append(character)
            if isBoundary(character, at: index, in: characters) {
                let chunk = trimmed(current)
                if !chunk.isEmpty {
                    chunks.append(chunk)
                }
                current = ""
            }
        }
        let tail = trimmed(current)
        if !tail.isEmpty {
            chunks.append(tail)
        }
        return chunks
    }

    /// Whether `character` at `index` ends a sentence: sentence punctuation followed by
    /// whitespace-or-end-of-input, subject to the abbreviation rule.
    private static func isBoundary(
        _ character: Character, at index: Int, in characters: [Character]
    ) -> Bool {
        guard boundaryCharacters.contains(character) else { return false }
        let nextIndex = index + 1
        guard nextIndex == characters.count || characters[nextIndex].isWhitespace else {
            return false
        }
        if character == "." && isAbbreviationPeriod(at: index, in: characters) {
            return false
        }
        return true
    }

    /// The abbreviation rule: whether the period at `index` follows a non-empty, vowel-free
    /// letter token — `Mr.` `Dr.` `St.` `vs.` — and therefore does not end a sentence.
    private static func isAbbreviationPeriod(at index: Int, in characters: [Character]) -> Bool {
        var cursor = index
        var hasVowel = false
        while cursor > 0, characters[cursor - 1].isLetter {
            if vowelLetters.contains(characters[cursor - 1]) {
                hasVowel = true
                break
            }
            cursor -= 1
        }
        guard cursor < index else { return false }
        return !hasVowel
    }

    /// The surrounding-whitespace trim, with no Foundation: Core imports nothing.
    private static func trimmed(_ string: String) -> String {
        var start = string.startIndex
        var end = string.endIndex
        while start < end, string[start].isWhitespace {
            start = string.index(after: start)
        }
        while end > start, string[string.index(before: end)].isWhitespace {
            end = string.index(before: end)
        }
        return String(string[start..<end])
    }
}