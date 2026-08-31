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
        let consumer = "EquivalenceRealEngineRunner.swift"
        let allowedSightings: Set<String> = [namedFile, pinningTest, consumer]
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
            "streamChunkSamples must be defined in exactly the named file, consumed by the runner "
                + "and pinned here, got: \(sightings)")
    }

    // MARK: - The key-up cost accounting (Phase (d))

    /// The injected clock's reads are deterministic, so the accounting is pinned as exact
    /// deltas: batch = two reads straddling `transcribe`; key-up = the last chunk's delivery to
    /// the final (the `finish()` decode — the honest "cost at key-up"); streamed = first chunk
    /// to final. The read order is fixed: batch start, batch end, streamed start, last-chunk
    /// stamp (a one-chunk fixture), final.
    func testTheRunnerRecordsTheKeyUpAndBatchAndStreamedDurationsThroughTheInjectedClock()
        async throws
    {
        let engine = RunnerScriptedEngine(
            batchText: "the quick brown fox", partials: ["the quick"], finals: ["the quick brown fox"])
        let clock = ScriptedClock(readings: [
            .zero, .milliseconds(1_000), .milliseconds(2_000), .milliseconds(3_000),
            .milliseconds(4_000),
        ])
        let result = try await EquivalenceRealEngineRunner.run(
            engine: engine,
            fixtures: [makeFixture(name: "clean", sampleCount: 16_000)],
            toleranceTable: ProvisionalEquivalenceTolerances.table,
            suppression: { .notSuppressed },
            clock: clock)
        let record = result.fixtures[0]
        XCTAssertEqual(
            record.batchElapsed, .milliseconds(1_000),
            "batch cost: the two reads straddling transcribe")
        XCTAssertEqual(
            record.keyUpElapsed, .milliseconds(1_000),
            "key-up cost: the last chunk's delivery to the final — the finish() decode")
        XCTAssertEqual(
            record.streamedElapsed, .milliseconds(2_000),
            "streamed cost: first chunk to final — recorded, nothing claimed from it")
        XCTAssertEqual(record.partialsObserved, 1)
    }

    /// The zero-partials note renders **exactly** when `partialsObserved == 0` — "no partials
    /// before key-up — the key-up decode covers the full window (X ms)", a measured fact, not an
    /// assumption — and is absent when partials were observed.
    func testTheZeroPartialsNoteRendersExactlyWhenNoPartialsWereObserved() async throws {
        let noPartials = RunnerScriptedEngine(batchText: "a", partials: [], finals: ["a"])
        let zeroResult = try await EquivalenceRealEngineRunner.run(
            engine: noPartials,
            fixtures: [makeFixture(name: "clean", sampleCount: 16_000)],
            toleranceTable: ProvisionalEquivalenceTolerances.table,
            suppression: { .notSuppressed },
            clock: ScriptedClock(readings: [.zero, .zero, .zero, .zero, .zero]))
        let zeroTable = EquivalenceRowRenderer.renderTable(zeroResult)
        XCTAssertTrue(
            zeroTable.contains(
                "no partials before key-up — the key-up decode covers the full window (0 ms)"),
            "a fixture with zero partials says so with the key-up cost beside it, got: \(zeroTable)")

        let withPartials = RunnerScriptedEngine(batchText: "a", partials: ["a"], finals: ["a"])
        let partialResult = try await EquivalenceRealEngineRunner.run(
            engine: withPartials,
            fixtures: [makeFixture(name: "clean", sampleCount: 16_000)],
            toleranceTable: ProvisionalEquivalenceTolerances.table,
            suppression: { .notSuppressed },
            clock: ScriptedClock(readings: [.zero, .zero, .zero, .zero, .zero]))
        let partialTable = EquivalenceRowRenderer.renderTable(partialResult)
        XCTAssertFalse(
            partialTable.contains("no partials before key-up"),
            "the zero-partials note is absent when partials were observed, got: \(partialTable)")
        XCTAssertTrue(
            partialTable.contains("partials observed: 1 — key-up 0 ms vs batch 0 ms"),
            "the partials-observed row shows the key-up cost vs the full batch cost, got: "
                + "\(partialTable)")
    }

    // MARK: - The suppression discipline (Phase (c))

    /// An injected suppression read returning `.unreadable(errno:)` voids **every** row with the
    /// "treat every number below as void" reason (the ``describeSuppression`` wording) — the
    /// whole-run void: an unreadable state means the numbers cannot be trusted, so none of them
    /// may read as an answer.
    func testAnUnreadableSuppressionReadVoidsEveryRowWithTheTreatBelowAsVoidReason() async throws {
        let engine = RunnerScriptedEngine(
            batchText: "the quick brown fox", partials: [], finals: ["the quick brown fox"])
        let result = try await EquivalenceRealEngineRunner.run(
            engine: engine,
            fixtures: [makeFixture(name: "clean")],
            toleranceTable: ProvisionalEquivalenceTolerances.table,
            suppression: { .unreadable(errno: 42) },
            clock: BenchmarkClock())
        XCTAssertEqual(
            result.fixtures[0].verdict,
            .void(reason: "suppression state unreadable — treat every number below as void"))
        XCTAssertEqual(
            result.verdict,
            .void(reasons: ["suppression state unreadable — treat every number below as void"]))
        if case .unreadable(let code) = result.fixtures[0].suppression {
            XCTAssertEqual(code, 42, "the errno travels with the failure, never read at print time")
        } else {
            XCTFail("the unreadable state must be carried on the row")
        }
    }

    /// A suppressed (darwin-background) process still records — the state was entered and is
    /// named, so the row shows `1 (SUPPRESSED — darwin background)` beside the numbers. A
    /// throttled number is recorded as throttled, never presented as clean, never voided by
    /// throttling alone.
    func testASuppressedRunRecordsRowsWithTheSuppressionLabelBesideThem() async throws {
        let engine = StreamingStubEngine(
            identity: EngineIdentity(id: "stub", displayName: "Stub", isLocal: true),
            partials: ["the quick"],
            finalText: "the quick brown fox")
        let result = try await EquivalenceRealEngineRunner.run(
            engine: engine,
            fixtures: [makeFixture(name: "clean")],
            toleranceTable: ProvisionalEquivalenceTolerances.table,
            suppression: { .suppressed },
            clock: BenchmarkClock())
        XCTAssertEqual(
            result.fixtures[0].verdict, .pass,
            "throttling alone never voids a row — the state was entered and is named")
        if case .suppressed = result.fixtures[0].suppression {
        } else {
            XCTFail("the suppressed state must be carried on the row")
        }
        let row = EquivalenceRowRenderer.renderRow(result.fixtures[0])
        XCTAssertTrue(
            row.contains("1 (SUPPRESSED — darwin background)"),
            "the printed row labels the throttled state beside the numbers, got: \(row)")
    }

    /// An unexpected priority value is recorded with its label — never presented as clean,
    /// never voided.
    func testAnUnexpectedPriorityIsRecordedWithItsLabel() async throws {
        let engine = RunnerScriptedEngine(
            batchText: "a", partials: [], finals: ["a"])
        let result = try await EquivalenceRealEngineRunner.run(
            engine: engine,
            fixtures: [makeFixture(name: "clean")],
            toleranceTable: ProvisionalEquivalenceTolerances.table,
            suppression: { .other(5) },
            clock: BenchmarkClock())
        XCTAssertEqual(result.fixtures[0].verdict, .pass)
        if case .other(let value) = result.fixtures[0].suppression {
            XCTAssertEqual(value, 5)
        } else {
            XCTFail("the unexpected-priority state must be carried on the row")
        }
        let row = EquivalenceRowRenderer.renderRow(result.fixtures[0])
        XCTAssertTrue(
            row.contains("5 (unexpected priority)"),
            "the printed row labels the unexpected priority, got: \(row)")
    }

    /// The provisioning discipline, pinned as a string: the env-gated shell's missing-
    /// `VOCCA_MODEL_DIR` skip message names `Scripts/provision-asr-fixtures.sh` — the
    /// provisioning instruction is the loud part (`LatencyBenchmarkRealEngineTests.swift:93-95`
    /// wording, verbatim), so a founder who hits the skip is told how to un-skip it.
    func testTheEnvGatedShellSkippingNamesTheProvisioningScript() throws {
        let file = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Tests/HarnessTests/EquivalenceRealEngineTests.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(
            source.contains("VOCCA_LATENCY_BENCH"),
            "the first gate's skip names the latency var — the two-var gate shape")
        XCTAssertTrue(
            source.contains("\"set VOCCA_MODEL_DIR to a store-shaped version directory — see \""),
            "the missing-model-dir skip's sentence is the precedent's wording, verbatim")
        XCTAssertTrue(
            source.contains("Scripts/provision-asr-fixtures.sh"),
            "the missing-model-dir skip must name the provisioning script — an instruction, "
                + "not a bare var name")
    }

    // MARK: - The runner over scripted engines

    /// The equal script (partials + final == batch) through `StreamingStubEngine`: every row
    /// PASSes, the partial count is recorded, and the summary is GO.
    func testTheRunnerOverAnEqualStreamingScriptProducesAllPassRowsAndGo() async throws {
        let engine = StreamingStubEngine(
            identity: EngineIdentity(id: "stub", displayName: "Stub", isLocal: true),
            partials: ["the quick", "the quick brown"],
            finalText: "the quick brown fox")
        let result = try await EquivalenceRealEngineRunner.run(
            engine: engine,
            fixtures: [makeFixture(name: "clean")],
            toleranceTable: ProvisionalEquivalenceTolerances.table,
            suppression: { .notSuppressed },
            clock: BenchmarkClock())
        XCTAssertEqual(result.fixtures.count, 1)
        let record = result.fixtures[0]
        XCTAssertEqual(record.verdict, .pass)
        XCTAssertEqual(record.row.wer, 0)
        XCTAssertEqual(record.row.exactEqual, true)
        XCTAssertEqual(record.row.shape, .identical)
        XCTAssertEqual(
            record.partialsObserved, 2,
            "the equal script's partials are recorded — partials then exactly one final")
        XCTAssertEqual(result.verdict, .go)
    }

    /// The unequal script through a scripted double (the batch text differs from the streamed
    /// final — `StreamingStubEngine` structurally cannot differ, its `transcribe` and its
    /// stream's final share one text): FAIL rows, summary NO-GO, and **the run does not throw** —
    /// a blown equivalence is recorded, never a test failure.
    func testTheRunnerOverAnUnequalStreamingScriptProducesFailRowsAndNoGoWithoutThrowing()
        async throws
    {
        let engine = RunnerScriptedEngine(
            batchText: "the quick brown fox",
            partials: ["the quick"],
            finals: ["the quick red fox"])
        let result = try await EquivalenceRealEngineRunner.run(
            engine: engine,
            fixtures: [makeFixture(name: "clean")],
            toleranceTable: ProvisionalEquivalenceTolerances.table,
            suppression: { .notSuppressed },
            clock: BenchmarkClock())
        XCTAssertEqual(result.fixtures[0].verdict, .fail)
        XCTAssertEqual(result.fixtures[0].row.wer, 0.25, accuracy: 0.0001)
        XCTAssertEqual(result.fixtures[0].row.shape, .prefixThenDiverge(commonTokens: 2))
        XCTAssertEqual(result.fixtures[0].partialsObserved, 1)
        XCTAssertEqual(result.verdict, .noGo(fixtures: ["clean"]))
    }

    /// A batch-only engine (`StubEngine`) drives every row to VOID with the streaming reason —
    /// the guard-the-guard: a non-streaming engine compares batch against batch, and that must
    /// never be able to read as a PASS.
    func testTheRunnerOverABatchOnlyEngineVoidsEveryRowWithTheStreamingReason() async throws {
        let engine = StubEngine.parakeet()
        let result = try await EquivalenceRealEngineRunner.run(
            engine: engine,
            fixtures: [makeFixture(name: "clean")],
            toleranceTable: ProvisionalEquivalenceTolerances.table,
            suppression: { .notSuppressed },
            clock: BenchmarkClock())
        XCTAssertEqual(
            result.fixtures[0].verdict,
            .void(reason: "engine does not stream — batch-vs-batch comparison proves nothing"))
        XCTAssertEqual(
            result.verdict,
            .void(reasons: ["engine does not stream — batch-vs-batch comparison proves nothing"]))
    }

    /// A fixture with no tolerance and no `"clean"` fallback in the table fails loudly — a new
    /// fixture never defaults to a free pass.
    func testTheRunnerFailsLoudlyWhenTheToleranceTableLacksTheFixtureAndTheCleanFallback()
        async throws
    {
        let engine = RunnerScriptedEngine(
            batchText: "a", partials: [], finals: ["a"])
        do {
            _ = try await EquivalenceRealEngineRunner.run(
                engine: engine,
                fixtures: [makeFixture(name: "clean")],
                toleranceTable: ["spike-clip": 0.05],
                suppression: { .notSuppressed },
                clock: BenchmarkClock())
            XCTFail("a table without the fixture or the clean fallback must fail loudly")
        } catch let error as EquivalenceRealEngineRunnerError {
            XCTAssertEqual(error, .missingTolerance(fixture: "clean"))
        }
    }

    /// A stream that yields no final is a loud named failure carrying the fixture and the
    /// partial ledger — never a fabricated verdict row.
    func testTheRunnerFailsLoudlyWhenTheStreamYieldsNoFinal() async throws {
        let engine = RunnerScriptedEngine(
            batchText: "the quick brown fox", partials: ["the quick"], finals: [])
        do {
            _ = try await EquivalenceRealEngineRunner.run(
                engine: engine,
                fixtures: [makeFixture(name: "clean")],
                toleranceTable: ProvisionalEquivalenceTolerances.table,
                suppression: { .notSuppressed },
                clock: BenchmarkClock())
            XCTFail("a stream with no final must fail loudly")
        } catch let error as EquivalenceRealEngineRunnerError {
            XCTAssertEqual(
                error, .noFinal(fixture: "clean", partialsObserved: 1),
                "the error names the fixture and the partial ledger")
        }
    }

    /// A stream that yields two finals is equally loud — exactly one final is the seam's
    /// contract, and a comparison over two is not a comparison.
    func testTheRunnerFailsLoudlyWhenTheStreamYieldsTwoFinals() async throws {
        let engine = RunnerScriptedEngine(
            batchText: "a", partials: [], finals: ["a", "a"])
        do {
            _ = try await EquivalenceRealEngineRunner.run(
                engine: engine,
                fixtures: [makeFixture(name: "clean")],
                toleranceTable: ProvisionalEquivalenceTolerances.table,
                suppression: { .notSuppressed },
                clock: BenchmarkClock())
            XCTFail("a stream with two finals must fail loudly")
        } catch let error as EquivalenceRealEngineRunnerError {
            XCTAssertEqual(
                error, .multipleFinals(fixture: "clean", finals: 2, partialsObserved: 0),
                "the error names the fixture and the ledger")
        }
    }

    /// A transcript attributed to another engine is a loud named failure on **both** sides —
    /// invariant I1, enforced by the runner, never a silently misattributed row.
    func testTheRunnerFailsLoudlyOnAMisattributedTranscript() async throws {
        let other = EngineIdentity(id: "other", displayName: "Other", isLocal: true)
        let engine = RunnerScriptedEngine(
            batchText: "a", partials: [], finals: ["a"], transcriptIdentity: other)
        do {
            _ = try await EquivalenceRealEngineRunner.run(
                engine: engine,
                fixtures: [makeFixture(name: "clean")],
                toleranceTable: ProvisionalEquivalenceTolerances.table,
                suppression: { .notSuppressed },
                clock: BenchmarkClock())
            XCTFail("a misattributed transcript must fail loudly")
        } catch let error as EquivalenceRealEngineRunnerError {
            XCTAssertEqual(
                error, .attributionMismatch(fixture: "clean", expected: engine.identity, actual: other),
                "the error names the fixture and both identities")
        }
    }

    // MARK: - Test helper

    /// One fixture case for the runner-over-stub rows — the buffer's content is irrelevant to
    /// the scripted engines, but the length drives the chunking (32 000 samples → two chunks).
    private func makeFixture(name: String = "clean", sampleCount: Int = 32_000) -> ASRFixtureCase {
        ASRFixtureCase(
            name: name,
            buffer: VoccaCore.AudioBuffer(
                samples: [Float](repeating: 0, count: sampleCount), sampleRate: 16_000),
            goldenText: "unused by the runner — the comparison is batch vs streamed final")
    }

    /// The accounting pin's clock: returns a fixed reading sequence, then holds the last reading —
    /// the runner's read order is deterministic, so each duration is an exact, hand-asserted
    /// delta. `@unchecked Sendable` for the ``BenchmarkClock`` reason: the reads are serialized
    /// by the awaits between them (batch reads, then streamed start, then the producer's
    /// last-chunk stamp, then the final), single-writer, sequential.
    private final class ScriptedClock: MonotonicClock, @unchecked Sendable {
        private let readings: [Duration]
        private var index = 0

        init(readings: [Duration]) {
            self.readings = readings
        }

        var now: Duration {
            defer { index += 1 }
            return readings[min(index, readings.count - 1)]
        }
    }

    /// The scripted double for the runner rows: the batch side (`transcribe`) speaks
    /// `batchText`, the streamed side yields `partials` then `finals` (each final one
    /// `isFinal == true` transcript). `StreamingStubEngine` cannot carry an unequal script —
    /// its `transcribe` and its stream's final share one text — so the unequal, no-final,
    /// two-final and misattributed rows live here, one file, with the script as the test's
    /// ground truth.
    private actor RunnerScriptedEngine: ASREngine {
        let identity: EngineIdentity
        let supportsStreaming = true
        let batchText: String
        let partials: [String]
        let finals: [String]
        let transcriptIdentity: EngineIdentity

        init(
            batchText: String,
            partials: [String],
            finals: [String],
            transcriptIdentity: EngineIdentity? = nil
        ) {
            self.identity = EngineIdentity(id: "runner-scripted", displayName: "Runner scripted", isLocal: true)
            self.batchText = batchText
            self.partials = partials
            self.finals = finals
            self.transcriptIdentity = transcriptIdentity ?? self.identity
        }

        func prepare() async throws {}

        func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
            Transcript(
                text: batchText, segments: [], engine: transcriptIdentity, isFinal: true,
                audioDuration: buffer.audioDuration)
        }

        nonisolated func stream(
            _ chunks: AsyncStream<AudioBuffer>
        ) -> AsyncThrowingStream<Transcript, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    await self.runStream(chunks, continuation: continuation)
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }

        private func runStream(
            _ chunks: AsyncStream<AudioBuffer>,
            continuation: AsyncThrowingStream<Transcript, Error>.Continuation
        ) async {
            for await _ in chunks {}
            for partial in partials {
                continuation.yield(Transcript(
                    text: partial, segments: [], engine: transcriptIdentity, isFinal: false,
                    audioDuration: 0))
            }
            for final in finals {
                continuation.yield(Transcript(
                    text: final, segments: [], engine: transcriptIdentity, isFinal: true,
                    audioDuration: 0))
            }
            continuation.finish()
        }
    }

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