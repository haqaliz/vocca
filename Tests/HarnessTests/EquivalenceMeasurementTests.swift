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
import VoccaCore
import XCTest

/// The streamed-vs-batch equivalence machinery, table-tested — Phase (a) of the
/// equivalence-measurement plan: the comparison, the token-diff shape, the verdict decision and
/// the rendered rows exist as pure code over scripted strings.
///
/// The load-bearing rows are the guard-the-guard pair: an **equal** pair must PASS and a
/// **seeded unequal** pair must FAIL — a gate that cannot fail proves nothing, so the seeded
/// pair is this phase's proof that the verdict can be negative at all.
final class EquivalenceMeasurementTests: XCTestCase {

    // MARK: - The comparison

    /// An equal pair: WER 0, exact, `.identical` — and a PASS verdict within any tolerance.
    func testAnEqualPairScoresZeroExactAndIdenticalAndPasses() {
        let row = StreamedVsBatchComparison.compare(
            fixtureName: "clean",
            batchText: "the quick brown fox",
            streamedFinalText: "the quick brown fox")
        XCTAssertEqual(row.wer, 0)
        XCTAssertTrue(row.exactEqual)
        XCTAssertEqual(row.shape, .identical)
        XCTAssertEqual(
            StreamedVsBatchComparison.decide(
                row: row, tolerance: 0.05, preconditions: EquivalencePreconditions()),
            .pass)
    }

    /// The normalization row: punctuation that the WER tokenizer strips is not a divergence —
    /// "the quick brown fox!" and "the quick brown fox" are the same tokens.
    func testPunctuationOnlyDifferencesAreStillIdentical() {
        let row = StreamedVsBatchComparison.compare(
            fixtureName: "clean",
            batchText: "The quick, brown fox!",
            streamedFinalText: "the quick brown fox")
        XCTAssertEqual(row.wer, 0)
        XCTAssertFalse(row.exactEqual, "the raw strings differ — exact equality is about text")
        XCTAssertEqual(row.shape, .identical)
    }

    /// The seeded unequal pair: one word differs after a two-word shared prefix — WER 0.25,
    /// not exact, `.prefixThenDiverge(2)` — and a FAIL verdict at the provisional tolerance.
    func testASeededUnequalPairScoresPositiveAndFails() {
        let row = StreamedVsBatchComparison.compare(
            fixtureName: "clean",
            batchText: "the quick brown fox",
            streamedFinalText: "the quick red fox")
        XCTAssertEqual(row.wer, 0.25, accuracy: 0.0001)
        XCTAssertFalse(row.exactEqual)
        XCTAssertEqual(row.shape, .prefixThenDiverge(commonTokens: 2))
        XCTAssertEqual(
            StreamedVsBatchComparison.decide(
                row: row, tolerance: 0.05, preconditions: EquivalencePreconditions()),
            .fail)
    }

    /// The shape the roadmap's "only the tail is unprocessed" premise predicts is
    /// `.prefixThenDiverge`; a pair whose first tokens already differ is `.wholesaleDrift` —
    /// the shape that contradicts it.
    func testAWholesaleDriftPairReportsTheShape() {
        let row = StreamedVsBatchComparison.compare(
            fixtureName: "noisy",
            batchText: "the quick brown fox",
            streamedFinalText: "jumped over the lazy dog")
        XCTAssertEqual(row.shape, .wholesaleDrift)
    }

    /// Both-empty is the sub-minimum row: `.identical`, WER 0 — never a crash, never a
    /// fabricated divergence.
    func testBothEmptyIsIdenticalWithZeroWer() {
        let row = StreamedVsBatchComparison.compare(
            fixtureName: "two-hundred-ms", batchText: "", streamedFinalText: "")
        XCTAssertEqual(row.shape, .identical)
        XCTAssertEqual(row.wer, 0)
        XCTAssertEqual(
            StreamedVsBatchComparison.decide(
                row: row, tolerance: 0.05, preconditions: EquivalencePreconditions()),
            .pass)
    }

    /// One side empty with the other not: no shared leading token — `.wholesaleDrift`.
    func testOneSideEmptyIsWholesaleDrift() {
        let row = StreamedVsBatchComparison.compare(
            fixtureName: "clean", batchText: "a b", streamedFinalText: "")
        XCTAssertEqual(row.shape, .wholesaleDrift)
    }

    // MARK: - The verdict decision

    /// Any unmet precondition voids the row with a named reason — SMOKE rule 1: void, not fail.
    func testUnreadableSuppressionVoidsEveryRow() {
        let row = StreamedVsBatchComparison.compare(
            fixtureName: "clean",
            batchText: "the quick brown fox",
            streamedFinalText: "the quick brown fox")
        XCTAssertEqual(
            StreamedVsBatchComparison.decide(
                row: row,
                tolerance: 0.05,
                preconditions: EquivalencePreconditions(suppressionReadable: false)),
            .void(reason: "suppression state unreadable — treat every number below as void"))
    }

    /// A non-streaming engine would compare batch against batch — a comparison that proves
    /// nothing must read VOID with the named reason, never a silent PASS.
    func testANonStreamingEngineVoidsWithTheNamedReason() {
        let row = StreamedVsBatchComparison.compare(
            fixtureName: "clean",
            batchText: "the quick brown fox",
            streamedFinalText: "the quick brown fox")
        XCTAssertEqual(
            StreamedVsBatchComparison.decide(
                row: row,
                tolerance: 0.05,
                preconditions: EquivalencePreconditions(engineStreams: false)),
            .void(reason: "engine does not stream — batch-vs-batch comparison proves nothing"))
    }

    /// A fixture whose side is missing (no final yielded) is void, never a fabricated
    /// PASS/FAIL — and the side is named.
    func testAMissingSideVoidsWithTheSideNamed() {
        let row = StreamedVsBatchComparison.compare(
            fixtureName: "clean",
            batchText: "the quick brown fox",
            streamedFinalText: "the quick brown fox")
        XCTAssertEqual(
            StreamedVsBatchComparison.decide(
                row: row,
                tolerance: 0.05,
                preconditions: EquivalencePreconditions(batchPresent: false)),
            .void(reason: "missing side: batch"))
        XCTAssertEqual(
            StreamedVsBatchComparison.decide(
                row: row,
                tolerance: 0.05,
                preconditions: EquivalencePreconditions(streamedFinalPresent: false)),
            .void(reason: "missing side: streamed final"))
    }

    // MARK: - The run summary verdict

    /// Every row passes → GO.
    func testTheSummaryVerdictIsGoOnlyWhenEveryRowPasses() {
        let result = EquivalenceRunResult(
            fixtures: [makeRecord(batch: "a", streamed: "a"), makeRecord(batch: "b", streamed: "b")],
            verdict: .go)
        XCTAssertEqual(EquivalenceRunVerdict.decide(records: result.fixtures), .go)
    }

    /// One fail among passes → NO-GO, naming the fixture.
    func testOneFailMakesTheSummaryNoGoNamingTheFixture() {
        let result = EquivalenceRunResult(
            fixtures: [
                makeRecord(batch: "a", streamed: "a"),
                makeRecord(batch: "the quick brown fox", streamed: "the quick red fox"),
                makeRecord(batch: "c", streamed: "c"),
            ],
            verdict: .go)
        XCTAssertEqual(
            EquivalenceRunVerdict.decide(records: result.fixtures),
            .noGo(fixtures: ["clean"]))
    }

    /// Two fails name both fixtures.
    func testTwoFailsNameBothFixtures() {
        let result = EquivalenceRunResult(
            fixtures: [
                makeRecord(fixture: "clean", batch: "the quick brown fox", streamed: "the quick red fox"),
                makeRecord(fixture: "noisy", batch: "the quick brown fox", streamed: "the quick red fox"),
            ],
            verdict: .go)
        XCTAssertEqual(
            EquivalenceRunVerdict.decide(records: result.fixtures),
            .noGo(fixtures: ["clean", "noisy"]))
    }

    /// Void-only → VOID, naming the reasons.
    func testVoidOnlyMakesTheSummaryVoidNamingTheReasons() {
        let result = EquivalenceRunResult(
            fixtures: [
                makeRecord(batch: "a", streamed: "a", preconditions: EquivalencePreconditions(engineStreams: false)),
                makeRecord(batch: "b", streamed: "b", preconditions: EquivalencePreconditions(suppressionReadable: false)),
            ],
            verdict: .go)
        XCTAssertEqual(
            EquivalenceRunVerdict.decide(records: result.fixtures),
            .void(reasons: [
                "engine does not stream — batch-vs-batch comparison proves nothing",
                "suppression state unreadable — treat every number below as void",
            ]))
    }

    /// Any fail wins over voids — NO-GO, never a VOID that hides the blown tolerance.
    func testAFailAlongsideVoidsIsStillNoGo() {
        let result = EquivalenceRunResult(
            fixtures: [
                makeRecord(batch: "the quick brown fox", streamed: "the quick red fox"),
                makeRecord(batch: "b", streamed: "b", preconditions: EquivalencePreconditions(engineStreams: false)),
            ],
            verdict: .go)
        XCTAssertEqual(
            EquivalenceRunVerdict.decide(records: result.fixtures),
            .noGo(fixtures: ["clean"]))
    }

    /// Passes alongside voids → VOID — a run with a voided row is never GO.
    func testPassesAlongsideVoidsAreVoidNotGo() {
        let result = EquivalenceRunResult(
            fixtures: [
                makeRecord(batch: "a", streamed: "a"),
                makeRecord(batch: "b", streamed: "b", preconditions: EquivalencePreconditions(engineStreams: false)),
            ],
            verdict: .go)
        XCTAssertEqual(
            EquivalenceRunVerdict.decide(records: result.fixtures),
            .void(reasons: ["engine does not stream — batch-vs-batch comparison proves nothing"]))
    }

    // MARK: - The renderer

    /// A row renders every column: fixture, WER, exact, shape, key-up cost, suppression.
    func testTheRendererProducesARowWithAllColumns() {
        let result = EquivalenceRunResult(
            fixtures: [makeRecord(batch: "a", streamed: "a")],
            verdict: .go)
        let row = EquivalenceRowRenderer.renderRow(result.fixtures[0])
        XCTAssertTrue(row.contains("clean"), "the fixture name is the first column, got: \(row)")
        XCTAssertTrue(row.contains("0.000"), "the WER is a three-decimal number, got: \(row)")
        XCTAssertTrue(row.contains("yes"), "exact equality is spelled yes, got: \(row)")
        XCTAssertTrue(row.contains("identical"), "the shape column, got: \(row)")
        XCTAssertTrue(row.contains("n/a"), "a row with no measured key-up cost prints n/a, got: \(row)")
        XCTAssertTrue(
            row.contains("0 (NOT suppressed)"),
            "the suppression column is the describeSuppression wording, got: \(row)")
    }

    /// A measured key-up cost prints beside the row instead of n/a.
    func testTheRendererPrintsAMeasuredKeyUpCost() {
        let result = EquivalenceRunResult(
            fixtures: [makeRecord(batch: "a", streamed: "a", keyUp: .milliseconds(1_234))],
            verdict: .go)
        let row = EquivalenceRowRenderer.renderRow(result.fixtures[0])
        XCTAssertTrue(row.contains("1234 ms"), "the measured key-up cost, got: \(row)")
        XCTAssertFalse(row.contains("n/a"), "a measured cost never prints n/a, got: \(row)")
    }

    /// The table renders the header, then one row and one detail line per fixture.
    func testTheRendererProducesTheVerdictTable() {
        let result = EquivalenceRunResult(
            fixtures: [
                makeRecord(fixture: "clean", batch: "a", streamed: "a"),
                makeRecord(fixture: "noisy", batch: "the quick brown fox", streamed: "the quick red fox"),
            ],
            verdict: .go)
        let table = EquivalenceRowRenderer.renderTable(result)
        let lines = table.split(separator: "\n")
        XCTAssertTrue(table.contains("fixture"), "the header names the columns")
        XCTAssertTrue(table.contains("suppression"), "the header names the suppression column")
        XCTAssertEqual(lines.count, 5, "header + one row and one detail line per fixture, got: \(table)")
        XCTAssertTrue(lines[1].contains("clean"), "the first row is the clean fixture, got: \(table)")
        XCTAssertTrue(lines[1].contains("0.000"), "the first row's WER, got: \(table)")
        XCTAssertTrue(lines[3].contains("noisy"), "the second row is the noisy fixture, got: \(table)")
        XCTAssertTrue(
            lines[3].contains("prefix-diverge(2)"),
            "the second row's shape names the shared-prefix boundary, got: \(table)")
        XCTAssertTrue(
            lines[2].contains("no partials before key-up"),
            "the detail line under a zero-partials row says so, got: \(table)")
    }

    // MARK: - The one-file tables and constants

    /// The whisper exclusion note is the exact named sentence — whisper's final equals batch by
    /// construction (M6), so the harness is Parakeet-only and the print output says why.
    func testTheWhisperExclusionNoteIsTheNamedSentence() {
        XCTAssertEqual(
            EquivalenceRowRenderer.whisperExclusionNote,
            "whisper.cpp needs no equivalence run: its final equals batch by construction "
                + "(repeated whisper_full on the growing buffer; the final is the last full decode).")
    }

    /// The provisional tolerance table is placeholder-seeded by decision: all six discovered
    /// fixtures at 0.05, consumed with the `table[name] ?? table["clean"]` fallback shape of the
    /// WER runner — and a table without even the fallback answers nil, never a free pass.
    func testTheProvisionalToleranceTableIsPlaceholderSeededWithTheCleanFallback() {
        let table = ProvisionalEquivalenceTolerances.table
        XCTAssertEqual(
            Set(table.keys),
            ["clean", "spike-clip", "accented", "noisy", "sixty-second", "two-hundred-ms"])
        XCTAssertTrue(
            table.values.allSatisfy { $0 == 0.05 },
            "placeholder-seeded by decision — every fixture at 0.05 until the founder's first run")
        XCTAssertEqual(
            ProvisionalEquivalenceTolerances.tolerance(for: "clean", in: table), 0.05)
        XCTAssertEqual(
            ProvisionalEquivalenceTolerances.tolerance(for: "spike-clip", in: table), 0.05)
        XCTAssertEqual(
            ProvisionalEquivalenceTolerances.tolerance(for: "future-fixture", in: table), 0.05,
            "an unknown fixture falls back to the clean tolerance — the WER runner's shape")
        XCTAssertNil(
            ProvisionalEquivalenceTolerances.tolerance(for: "x", in: ["a": 1.0]),
            "a table without the clean fallback answers nil — the runner fails loudly from it")
    }

    /// The placeholder table lives in one file: a dictionary-style `": 0.05,"` row appears
    /// nowhere outside `EquivalenceMeasurement.swift` — so the table cannot drift into a second
    /// home. The pattern is deliberately the dictionary-row shape rather than the bare literal:
    /// `0.05` is also a common amplitude/seconds literal elsewhere in the suite
    /// (`WaveformMappingTests`, `WhisperCoreTests`), and those are not tolerances. Comments are
    /// stripped first, and the vacuity guard runs in both directions (the ``WarmStartRatioTests``
    /// precedent).
    func testThePlaceholderToleranceLiteralLivesInOneFile() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let namedTable = "EquivalenceMeasurement.swift"
        let allowedSightings: Set<String> = [namedTable]
        let pattern = #"": 0\.05,"#

        var sightings: [String: Int] = [:]
        for tree in [root.appendingPathComponent("Sources"), root.appendingPathComponent("Tests")] {
            for file in SwiftSourceScanner.swiftFiles(under: tree) {
                let content = try String(contentsOf: file, encoding: .utf8)
                let stripped = SwiftSourceScanner.stripComments(from: content)
                if stripped.range(of: pattern, options: .regularExpression) != nil {
                    sightings[file.lastPathComponent, default: 0] += 1
                }
            }
        }

        XCTAssertFalse(sightings.isEmpty, "vacuity guard: the scan saw no files at all")
        XCTAssertEqual(
            Set(sightings.keys), allowedSightings,
            "a tolerance-shaped 0.05 row must live in exactly the named table, got: \(sightings)")
        XCTAssertEqual(
            sightings[namedTable], 1,
            "the named table's own sighting must exist — the vacuity guard's second direction")
    }

    /// The 1 s chunk constant is single-sourced: `streamChunkSamples` appears in exactly the
    /// named file and this pinning test, and its value is the interchange rate's.
    func testTheStreamChunkSamplesConstantIsSingleSourced() throws {
        XCTAssertEqual(
            EquivalenceMeasurementTargets.streamChunkSamples,
            Int(AudioBuffer.interchangeSampleRate),
            "the chunk is 1 s at the interchange rate — 16 000 samples")

        let root = try PackageRootLocator.find(from: #filePath)
        let namedFile = "EquivalenceMeasurement.swift"
        let pinningTest = "EquivalenceMeasurementTests.swift"
        let allowedSightings: Set<String> = [namedFile, pinningTest]
        let pattern = #"\bstreamChunkSamples\b"#

        var sightings: [String: Int] = [:]
        for tree in [root.appendingPathComponent("Sources"), root.appendingPathComponent("Tests")] {
            for file in SwiftSourceScanner.swiftFiles(under: tree) {
                let content = try String(contentsOf: file, encoding: .utf8)
                let stripped = SwiftSourceScanner.stripComments(from: content)
                if stripped.range(of: pattern, options: .regularExpression) != nil {
                    sightings[file.lastPathComponent, default: 0] += 1
                }
            }
        }

        XCTAssertFalse(sightings.isEmpty, "vacuity guard: the scan saw no files at all")
        XCTAssertEqual(
            Set(sightings.keys), allowedSightings,
            "streamChunkSamples must live in exactly the named file and its pinning test, got: "
                + "\(sightings)")
    }

    // MARK: - Test helper

    /// Builds one fixture record through the shipped machinery: the comparison first, then the
    /// verdict over the given tolerance and preconditions — never a hand-constructed verdict.
    private func makeRecord(
        fixture: String = "clean",
        batch: String,
        streamed: String,
        tolerance: Double = 0.05,
        preconditions: EquivalencePreconditions = EquivalencePreconditions(),
        partials: Int = 0,
        suppression: DarwinSuppression = .notSuppressed,
        keyUp: Duration? = nil,
        batchElapsed: Duration? = nil
    ) -> EquivalenceFixtureRecord {
        let row = StreamedVsBatchComparison.compare(
            fixtureName: fixture, batchText: batch, streamedFinalText: streamed)
        let verdict = StreamedVsBatchComparison.decide(
            row: row, tolerance: tolerance, preconditions: preconditions)
        return EquivalenceFixtureRecord(
            row: row,
            verdict: verdict,
            batchElapsed: batchElapsed,
            keyUpElapsed: keyUp,
            streamedElapsed: nil,
            partialsObserved: partials,
            suppression: suppression)
    }
}