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

import Foundation

/// Word error rate, computed over normalized word sequences — the measurement the C2
/// acceptance (and the P0 gate's calibration) is judged on.
///
/// This is the pure decision the fixture suite is built on, so it lives where tests can reach
/// it directly (the repo's pattern): every rule below is pinned by ``WERTests`` before any
/// engine runs against it.
///
/// ## Normalization
///
/// Both strings are lowercased and split on every character that is not a letter or an
/// apostrophe (`don't` survives as one token; `state-of-the-art` splits; punctuation vanishes).
/// The split is on characters because it must not depend on locale.
///
/// ## The score
///
/// The word-level Levenshtein distance (substitutions, insertions and deletions each cost 1)
/// divided by the reference word count. An empty reference is the degenerate case: 0 when the
/// hypothesis is also empty, else 1 — never a division by zero, never a negative score.
public enum WER {

    public static func compute(reference: String, hypothesis: String) -> Double {
        let referenceWords = normalize(reference)
        let hypothesisWords = normalize(hypothesis)
        guard !referenceWords.isEmpty else {
            return hypothesisWords.isEmpty ? 0 : 1
        }
        let distance = levenshtein(referenceWords, hypothesisWords)
        return Double(distance) / Double(referenceWords.count)
    }

    /// Lowercased, split on non-letter/non-apostrophe characters, empty tokens dropped.
    private static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && $0 != "'" }
            .map(String.init)
    }

    /// Classic DP over word arrays; substitutions, insertions and deletions each cost 1.
    private static func levenshtein(_ a: [String], _ b: [String]) -> Int {
        let rows = a.count + 1
        let columns = b.count + 1
        var matrix = [[Int]](repeating: [Int](repeating: 0, count: columns), count: rows)
        for i in 1..<rows { matrix[i][0] = i }
        for j in 1..<columns { matrix[0][j] = j }
        for i in 1..<rows {
            for j in 1..<columns {
                let substitutionCost = a[i - 1] == b[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,
                    matrix[i][j - 1] + 1,
                    matrix[i - 1][j - 1] + substitutionCost)
            }
        }
        return matrix[rows - 1][columns - 1]
    }
}
