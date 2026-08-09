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

/// The WER scorer's decision table: every edit class, the normalization rules, and the
/// empty-reference rule — the measurement the P0 gate is judged on, pinned before any engine
/// runs against it.
final class WERTests: XCTestCase {

    /// A perfect transcription scores exactly zero.
    func testAnExactMatchScoresZero() {
        XCTAssertEqual(WER.compute(reference: "the quick brown fox", hypothesis: "the quick brown fox"), 0)
        XCTAssertEqual(WER.compute(reference: "test", hypothesis: "test"), 0)
    }

    /// One substituted word in a four-word reference is 0.25 — the classic case.
    func testOneSubstitutionScoresOneOverReferenceLength() {
        XCTAssertEqual(
            WER.compute(reference: "the quick brown fox", hypothesis: "the slow brown fox"),
            0.25)
    }

    /// A deleted word scores one over the reference length; an inserted word scores the same.
    func testDeletionsAndInsertionsScoreOneEach() {
        XCTAssertEqual(
            WER.compute(reference: "the quick brown fox", hypothesis: "the brown fox"),
            0.25, "a deletion costs one edit")
        XCTAssertEqual(
            WER.compute(reference: "the quick brown fox", hypothesis: "the quick brown lazy fox"),
            0.25, "an insertion costs one edit")
    }

    /// Case and punctuation do not count: the golden is written naturally and the transcript
    /// arrives however the engine renders it.
    func testCaseAndPunctuationAreNormalizedAway() {
        let reference = "The quick brown fox. Today is a good day!"
        let hypothesis = "the quick, brown fox today is a good day"
        XCTAssertEqual(WER.compute(reference: reference, hypothesis: hypothesis), 0)
    }

    /// An empty reference is the degenerate case: WER 0 iff the hypothesis is also empty,
    /// else 1 — never a division by zero, never a negative.
    func testTheEmptyReferenceRule() {
        XCTAssertEqual(WER.compute(reference: "", hypothesis: ""), 0)
        XCTAssertEqual(WER.compute(reference: "", hypothesis: "anything"), 1)
    }

    /// A word dropped from every third position in the golden — the imperfect stub's shape —
    /// yields exactly the scorer's own arithmetic, which is what the harness test asserts
    /// end-to-end.
    func testTheImperfectStubShapeScoresExactly() {
        let reference = "one two three four five six seven eight nine ten"
        let hypothesis = "one three four six seven nine ten"  // dropped 2, 5, 8
        XCTAssertEqual(WER.compute(reference: reference, hypothesis: hypothesis), 0.3)
    }

    /// Apostrophes keep a contraction one token (a dropped apostrophe is a substitution, not a
    /// split); hyphens split.
    func testApostrophesStickAndHyphensSplit() {
        XCTAssertEqual(WER.compute(reference: "don't stop", hypothesis: "don't stop"), 0)
        XCTAssertEqual(
            WER.compute(reference: "don't stop", hypothesis: "dont stop"),
            0.5, "a dropped apostrophe is a word substitution — 'don't' and 'dont' differ")
        XCTAssertEqual(WER.compute(reference: "state of the art", hypothesis: "state of the-art"), 0)
    }
}
