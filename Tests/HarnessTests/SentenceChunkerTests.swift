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

/// The sentence chunker's acceptance table (`speech-seam/spec.md` R2, acceptance 3): what a
/// synthesizer is asked to render when a caller feeds it a whole reply, so speech can begin
/// before the reply is complete.
///
/// The shipped boundary rule, pinned row by row below:
///
/// - a chunk boundary is `.` `!` `?` or `…` immediately followed by whitespace-or-end-of-input,
///   and the punctuation stays on the chunk;
/// - a run with no such boundary stays whole — the chunker never splits mid-word;
/// - surrounding whitespace is trimmed and empty chunks are dropped (whitespace-only input
///   yields nothing, as does empty input);
/// - **the `space-after` abbreviation rule** (`spec.md` acceptance 3, pinned): a `.` is *not* a
///   boundary even when followed by whitespace if the letter-token immediately before it is
///   non-empty and vowel-free — `Mr.` `Dr.` `St.` `vs.` are abbreviations, while `went.` and
///   even two-letter `No.` are real sentence ends. Intentionally shallow; a smarter segmenter
///   is a later unit's choice (`spec.md` open questions).
final class SentenceChunkerTests: XCTestCase {

    /// Multi-sentence text splits at every boundary, punctuation kept on the chunk.
    func testMultiSentenceTextSplitsWithPunctuationKept() {
        XCTAssertEqual(
            SentenceChunker.sentenceChunks(of: "The cat sat. The dog ran!"),
            ["The cat sat.", "The dog ran!"])
        XCTAssertEqual(
            SentenceChunker.sentenceChunks(of: "Really? Wait…"),
            ["Really?", "Wait…"])
    }

    /// A run with no sentence boundary stays whole — and never splits mid-word.
    func testNoBoundaryRunStaysWhole() {
        XCTAssertEqual(
            SentenceChunker.sentenceChunks(of: "The quick brown fox jumps"),
            ["The quick brown fox jumps"])
    }

    /// Punctuation not followed by whitespace-or-end is not a boundary: the chunker splits on
    /// sentence ends, never inside a word.
    func testPunctuationNotFollowedByWhitespaceIsNotABoundary() {
        XCTAssertEqual(
            SentenceChunker.sentenceChunks(of: "Hello.world"),
            ["Hello.world"])
    }

    /// Whitespace-only input yields nothing — not an error, and not a chunk of blanks.
    func testWhitespaceOnlyYieldsNothing() {
        XCTAssertEqual(SentenceChunker.sentenceChunks(of: "   \n\t "), [])
    }

    /// Empty input yields nothing.
    func testEmptyYieldsNothing() {
        XCTAssertEqual(SentenceChunker.sentenceChunks(of: ""), [])
    }

    /// Surrounding whitespace is trimmed off every chunk, including runs between sentences.
    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(
            SentenceChunker.sentenceChunks(of: "  Hello.   World.  "),
            ["Hello.", "World."])
    }

    /// The pinned abbreviation case: `Mr. Smith went.` is ONE chunk — the period after `Mr` is
    /// not a boundary even though it is followed by whitespace (`spec.md` acceptance 3).
    func testMrAbbreviationStaysOneChunk() {
        XCTAssertEqual(
            SentenceChunker.sentenceChunks(of: "Mr. Smith went."),
            ["Mr. Smith went."])
    }

    /// The pinned split case: a real boundary after the abbreviation splits the text — the
    /// period after `went` is followed by whitespace and is not an abbreviation.
    func testMrAbbreviationThenRealBoundarySplits() {
        XCTAssertEqual(
            SentenceChunker.sentenceChunks(of: "Mr. Smith went. He left."),
            ["Mr. Smith went.", "He left."])
    }

    /// The abbreviation rule does not swallow short real sentences: `No.` has a vowel, so it
    /// ends a sentence like any word — the shallow rule is about consonant-only tokens.
    func testVoweledShortTokenStillSplits() {
        XCTAssertEqual(
            SentenceChunker.sentenceChunks(of: "No. That's wrong."),
            ["No.", "That's wrong."])
        XCTAssertEqual(
            SentenceChunker.sentenceChunks(of: "I went. He left."),
            ["I went.", "He left."])
    }

    /// A period after a non-letter ends a sentence: `5.` is a real boundary, not an
    /// abbreviation.
    func testDigitEndedSentenceSplits() {
        XCTAssertEqual(
            SentenceChunker.sentenceChunks(of: "He said 5. Then he left."),
            ["He said 5.", "Then he left."])
    }

    /// A run of trailing punctuation stays on the chunk: `Wow!?` is one chunk end, not two.
    func testMultipleTrailingPunctuationStaysOnTheChunk() {
        XCTAssertEqual(
            SentenceChunker.sentenceChunks(of: "Wow!? That's great."),
            ["Wow!?", "That's great."])
    }
}