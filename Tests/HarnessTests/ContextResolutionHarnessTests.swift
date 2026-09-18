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
import VoccaContext
import VoccaCore
import XCTest

/// The `accessibility-context` aspect's ≥95% resolution harness (S1, `prd.md:127-130`): the
/// scripted corpus runs the **real** ``AccessibilityContext`` adapter over a stub AX read seeded
/// from each row, and ``ContextResolutionScorer`` measures bundle ID + selected text resolution
/// against the matrix's rows — the C8 matrix's rows, so the CI harness and the founder's real
/// run measure the same shape.
///
/// The scorer does not exist yet — every reference below is the compile pin this suite exists
/// to make RED, the `TurnCommitmentHarnessTests` precedent.
///
/// What is pinned here:
///
/// - the passing corpus (22 all-correct rows, `Tests/HarnessTests/Fixtures/ContextResolution/`)
///   scores **1.0000** and passes the ≥0.95 bar;
/// - the planted corpus (2 misresolutions in 22) scores ≈ **0.909** and **fails loudly** — a
///   gate that cannot fail proves nothing, and the harness asserts the failure;
/// - the boundary is honest: 1 miss in 22 = 21/22 ≈ 0.9545 **passes** at the bar by design;
/// - an empty corpus **throws** — a harness that cannot measure must never read green
///   (the `TurnCommitmentScorerError.emptyCorpus` precedent);
/// - the corpus is non-empty, every row carries a non-empty bundle ID, and the scorer's
///   denominator counts what it says it counts.
enum ContextResolutionHarnessError: Error, CustomStringConvertible {
    case unreadableCorpus(reason: String)
    case malformedFixture(index: Int, reason: String)

    var description: String {
        switch self {
        case .unreadableCorpus(let reason):
            return "the resolution corpus could not be read: \(reason)"
        case .malformedFixture(let index, let reason):
            return "corpus row \(index) is malformed: \(reason)"
        }
    }
}

/// One corpus row, seeded from `Scripts/injection-matrix.sh` `ROWS`: what the stub AX read
/// answers (app, bundle ID, window title, selection) and the expected resolution (bundle ID +
/// selection — the window title is carried, never scored, D5).
struct ContextResolutionRow {
    let app: String
    let bundleID: String
    let windowTitle: String
    let selection: String
    let expectedBundleID: String
    let expectedSelectedText: String
}

/// The harness's drive: every row runs the real adapter over a stub seeded from the row, and the
/// scorer classifies the adapter's snapshot against the row's expected resolution.
enum ContextResolutionHarness {

    /// A stub AX read seeded from one row — the CI shape of the raw read, no AX call.
    private final class StubContextAXRead: ContextAXReading, @unchecked Sendable {
        private let answer: RawContextRead?

        init(answer: RawContextRead? = nil) {
            self.answer = answer
        }

        func readContext() -> RawContextRead? {
            answer
        }
    }

    /// Secure Input inactive for every corpus row — the harness measures resolution, not the
    /// refusal.
    private static let secureInputRead: any ContextSecureInputReading = StubSecureInputRead()

    private final class StubSecureInputRead: ContextSecureInputReading, @unchecked Sendable {
        func isSecureInputActive() -> Bool {
            false
        }
    }

    /// Loads a corpus file, failing loudly on an unreadable file or an empty array — a corpus
    /// that cannot load must not read green.
    static func loadRows(corpusURL: URL) throws -> [ContextResolutionRow] {
        let data: Data
        do {
            data = try Data(contentsOf: corpusURL)
        } catch {
            throw ContextResolutionHarnessError.unreadableCorpus(reason: "\(error)")
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ContextResolutionHarnessError.unreadableCorpus(reason: "\(error)")
        }
        guard let rows = json as? [[String: Any]], !rows.isEmpty else {
            throw ContextResolutionHarnessError.unreadableCorpus(
                reason: "expected a non-empty JSON array of rows")
        }
        return try rows.enumerated().map { index, raw in
            func string(_ key: String) throws -> String {
                guard let value = raw[key] as? String, !value.isEmpty else {
                    throw ContextResolutionHarnessError.malformedFixture(
                        index: index, reason: "missing or empty \(key)")
                }
                return value
            }
            return ContextResolutionRow(
                app: try string("app"),
                bundleID: try string("bundleID"),
                windowTitle: try string("windowTitle"),
                selection: try string("selection"),
                expectedBundleID: try string("expectedBundleID"),
                expectedSelectedText: try string("expectedSelectedText"))
        }
    }

    /// One row's resolution through the real adapter, classified by the scorer.
    static func classify(_ row: ContextResolutionRow) -> ContextResolutionClass {
        let context = AccessibilityContext(
            axRead: StubContextAXRead(
                answer: RawContextRead(
                    bundleID: row.bundleID, windowTitle: row.windowTitle,
                    selectedText: row.selection)),
            secureInputRead: secureInputRead)
        let snapshot = context.resolveCurrent()
        return ContextResolutionScorer.classify(
            bundleID: snapshot.bundleID,
            selectedText: snapshot.selectedText,
            expectedBundleID: row.expectedBundleID,
            expectedSelectedText: row.expectedSelectedText)
    }
}

final class ContextResolutionHarnessTests: XCTestCase {

    /// The fixture directory, located the way every suite in `HarnessTests` locates it.
    private var fixtureDirectory: URL {
        get throws {
            try PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Tests/HarnessTests/Fixtures/ContextResolution")
        }
    }

    /// The passing corpus — 22 all-correct rows seeded from the matrix — scores 1.0000 and
    /// passes the ≥0.95 bar.
    func testThePassingCorpusScoresAtOrAboveTheBar() throws {
        let rows = try ContextResolutionHarness.loadRows(
            corpusURL: try fixtureDirectory.appendingPathComponent("passing-corpus.json"))
        let classes = rows.map(ContextResolutionHarness.classify)
        let score = try ContextResolutionScorer.score(classes)

        XCTAssertEqual(
            classes.count, 22,
            "the passing corpus must seed exactly the matrix's 22 rows")
        XCTAssertEqual(
            score.correctCount, 22,
            "the passing corpus is all-correct by construction — its rows are the matrix's rows")
        XCTAssertEqual(
            score.percentage, 1.0,
            "22/22 correct must score exactly 1.0")
        XCTAssertTrue(
            score.passes,
            "1.0000 ≥ 0.95 — the passing corpus must pass")
    }

    /// The planted corpus — 2 misresolutions in 22 (a wrong bundle ID and a wrong selection) —
    /// scores ≈ 0.909 and fails loudly. A gate that cannot fail proves nothing, so the harness
    /// asserts the failure.
    func testThePlantedCorpusFailsLoudly() throws {
        let rows = try ContextResolutionHarness.loadRows(
            corpusURL: try fixtureDirectory.appendingPathComponent("planted-failure-corpus.json"))
        let classes = rows.map(ContextResolutionHarness.classify)
        let score = try ContextResolutionScorer.score(classes)

        XCTAssertEqual(classes.count, 22, "the planted corpus must also seed 22 rows")
        XCTAssertEqual(
            score.correctCount, 20,
            "two planted misresolutions in 22 rows must score 20 correct")
        XCTAssertEqual(
            score.percentage, 20.0 / 22.0, accuracy: 0.0001,
            "20/22 ≈ 0.909 — below the bar")
        XCTAssertFalse(
            score.passes,
            "0.909 < 0.95 — the planted corpus must fail, loudly, in the harness")
    }

    /// The boundary is honest: 1 miss in 22 = 21/22 ≈ 0.9545 ≥ 0.95 — it passes at the bar by
    /// design, the `TurnCommitmentHarnessTests` late-commit case's shape.
    func testOneMissInTwentyTwoPassesAtTheBar() throws {
        let rows = try ContextResolutionHarness.loadRows(
            corpusURL: try fixtureDirectory.appendingPathComponent("passing-corpus.json"))
        var boundaryRows = rows
        boundaryRows[0] = ContextResolutionRow(
            app: rows[0].app, bundleID: "com.apple.Mail", windowTitle: rows[0].windowTitle,
            selection: rows[0].selection, expectedBundleID: rows[0].expectedBundleID,
            expectedSelectedText: rows[0].expectedSelectedText)
        let score = try ContextResolutionScorer.score(
            boundaryRows.map(ContextResolutionHarness.classify))

        XCTAssertEqual(
            score.correctCount, 21,
            "exactly one planted misresolution in 22 rows")
        XCTAssertEqual(
            score.percentage, 21.0 / 22.0, accuracy: 0.0001,
            "21/22 ≈ 0.9545 — at the bar")
        XCTAssertTrue(
            score.passes,
            "0.9545 ≥ 0.95 — one miss in 22 passes by design")
    }

    /// An empty corpus throws — a harness that cannot measure must never read green.
    func testAnEmptyCorpusThrows() {
        XCTAssertThrowsError(
            try ContextResolutionScorer.score([]),
            "an empty corpus cannot be measured and must throw")
    }

    /// Vacuity guards: the corpus is non-empty, every row carries a non-empty bundle ID, and
    /// the scorer's denominator counts what it says it counts.
    func testTheCorpusIsNonEmptyAndEveryRowCarriesANonEmptyBundleID() throws {
        let rows = try ContextResolutionHarness.loadRows(
            corpusURL: try fixtureDirectory.appendingPathComponent("passing-corpus.json"))
        XCTAssertFalse(rows.isEmpty, "an empty corpus would read green vacuously")
        XCTAssertTrue(
            rows.allSatisfy { !$0.bundleID.isEmpty && !$0.expectedBundleID.isEmpty },
            "every corpus row must carry a non-empty bundle ID and expected bundle ID")
        XCTAssertTrue(
            rows.allSatisfy { !$0.app.isEmpty },
            "every corpus row must name its app — the matrix row it was seeded from")
    }

    /// The scorer's denominator counts what it says: the class array's count is the corpus's
    /// row count, and correct + misresolved equals it.
    func testTheScorersDenominatorCountsTheCorpus() throws {
        let rows = try ContextResolutionHarness.loadRows(
            corpusURL: try fixtureDirectory.appendingPathComponent("passing-corpus.json"))
        let classes = rows.map(ContextResolutionHarness.classify)
        let score = try ContextResolutionScorer.score(classes)

        XCTAssertEqual(score.totalCount, classes.count)
        XCTAssertEqual(
            score.correctCount + classes.filter { $0 == .misresolved }.count, score.totalCount,
            "correct + misresolved must equal the denominator")
    }
}