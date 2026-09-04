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

@preconcurrency import AVFoundation
import Foundation
import VoccaASR
import VoccaCore
import VoccaText
import XCTest

/// The cleanup eval harness's acceptance surface (spec B2–B6): the corpus loader's loud-failure
/// contract, the headless stand-in run, the latency gate, the single-source provisional table,
/// and the env-gated real run. Everything over scratch directories or the checked-in
/// `Tests/CleanupPairs/` corpus — no network, no window server, no founder artifacts.
///
/// The loader rows (B2) come first: a harness that cannot measure must never read green, so a
/// pair missing its golden, a missing class tag, an unknown tag, an empty directory and a
/// corpus below the named minimum all fail loudly — in the `ASRFixtureSuite` loader shape.
final class CleanupEvalHarnessTests: XCTestCase {

    private var scratchRoots: [URL] = []

    override func tearDown() {
        for root in scratchRoots {
            try? FileManager.default.removeItem(at: root)
        }
        scratchRoots = []
        super.tearDown()
    }

    /// A fresh temporary directory for this test's corpus; torn down with the rest of the
    /// scratch roots.
    private func makeScratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-cleanup-eval-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scratchRoots.append(root)
        return root
    }

    /// Writes one `<name>.{raw,clean,class}.txt` triple into `directory` — the pair format the
    /// corpus ships in.
    private func writeTriple(
        _ name: String, raw: String, clean: String, className: CleanupPairClass,
        in directory: URL
    ) throws {
        try Data(raw.utf8).write(to: directory.appendingPathComponent("\(name).raw.txt"))
        try Data(clean.utf8).write(to: directory.appendingPathComponent("\(name).clean.txt"))
        try Data(className.rawValue.utf8)
            .write(to: directory.appendingPathComponent("\(name).class.txt"))
    }

    // MARK: - B2: the loader's contract

    /// Discovery keys on the `.raw.txt` suffix only: twenty triples load as exactly twenty
    /// pairs with names and class tags intact — and a `dictionary.json` or `FIXTURES.md` in the
    /// same directory is never misread as a pair. Twenty keeps this scratch corpus above the
    /// vacuity minimum the loader's guard enforces (a corpus that small cannot read green).
    func testLoadPairsFindsEveryPairUnderTheDirectory() throws {
        let root = try makeScratchRoot()
        for index in 0..<CleanupPairSuite.minimumMeaningfulCorpusSize {
            try writeTriple(
                "pair-\(String(format: "%02d", index))",
                raw: "um raw \(index)", clean: "Clean \(index).",
                className: index % 2 == 0 ? .fillers : .punctuation, in: root)
        }
        try Data(#"[{"source":"kawa","replacement":"Kawa"}]"#.utf8)
            .write(to: root.appendingPathComponent("dictionary.json"))
        try Data("# provenance".utf8).write(to: root.appendingPathComponent("FIXTURES.md"))

        let pairs = try CleanupPairSuite.loadPairs(from: root)
        XCTAssertEqual(
            pairs.map(\.name),
            (0..<CleanupPairSuite.minimumMeaningfulCorpusSize).map {
                String(format: "pair-%02d", $0)
            },
            "every triple found, sorted, with dictionary.json and FIXTURES.md ignored")
        XCTAssertEqual(
            pairs.map(\.className),
            (0..<CleanupPairSuite.minimumMeaningfulCorpusSize).map {
                $0 % 2 == 0 ? CleanupPairClass.fillers : .punctuation
            },
            "the class tags arrive intact")
        XCTAssertEqual(pairs[0].raw, "um raw 0")
        XCTAssertEqual(pairs[0].clean, "Clean 0.")
    }

    /// A wav-only corpus — every pair present as `.wav` + `.clean.txt` + `.class.txt` with no
    /// `.raw.txt` — loads zero pairs: discovery keys on the `.raw.txt` suffix only, so the F2
    /// convention's `.wav` sidecar alone is never a pair (the `dictionary.json`/`FIXTURES.md`
    /// half of the same rule is pinned above). Green on arrival — it pins the loader's
    /// discovery rule so the procedure docs' claim is testable, and a future discovery change
    /// breaks loudly.
    func testAWavOnlyCorpusWithoutRawTextsThrowsNoPairsFound() throws {
        let root = try makeScratchRoot()
        for index in 0..<CleanupPairSuite.minimumMeaningfulCorpusSize {
            let name = String(format: "pair-%02d", index)
            try Data().write(to: root.appendingPathComponent("\(name).wav"))
            try Data("Clean \(index).".utf8)
                .write(to: root.appendingPathComponent("\(name).clean.txt"))
            try Data((index % 2 == 0 ? CleanupPairClass.fillers : .punctuation).rawValue.utf8)
                .write(to: root.appendingPathComponent("\(name).class.txt"))
        }
        try Data(#"[{"source":"kawa","replacement":"Kawa"}]"#.utf8)
            .write(to: root.appendingPathComponent("dictionary.json"))
        try Data("# provenance".utf8).write(to: root.appendingPathComponent("FIXTURES.md"))

        XCTAssertThrowsError(try CleanupPairSuite.loadPairs(from: root)) { error in
            XCTAssertEqual(error as? CleanupPairSuiteError, .noPairsFound(root.path))
        }
    }

    /// A pair without its `.clean.txt` is a broken fixture and must fail loudly, naming the
    /// pair and the expected golden path — the `missingGolden` shape (`ASRFixtureSuite.swift:69-72`).
    func testAPairMissingItsCleanTargetThrowsNamingThePair() throws {
        let root = try makeScratchRoot()
        try Data("raw".utf8).write(to: root.appendingPathComponent("broken.raw.txt"))
        XCTAssertThrowsError(try CleanupPairSuite.loadPairs(from: root)) { error in
            XCTAssertEqual(
                error as? CleanupPairSuiteError,
                .missingCleanTarget(
                    pair: "broken",
                    expectedAt: root.appendingPathComponent("broken.clean.txt").path))
        }
    }

    /// An empty directory has nothing to measure and must fail loudly — the `noFixturesFound`
    /// shape (`ASRFixtureSuite.swift:64-66`).
    func testAnEmptyDirectoryThrowsNoPairsFound() throws {
        let root = try makeScratchRoot()
        XCTAssertThrowsError(try CleanupPairSuite.loadPairs(from: root)) { error in
            XCTAssertEqual(error as? CleanupPairSuiteError, .noPairsFound(root.path))
        }
    }

    /// The vacuity guard: a corpus below the named minimum cannot read green — 5 pairs throw
    /// `corpusBelowMinimum` naming the minimum, and a corpus at the minimum loads.
    func testACorpusBelowTheNamedMinimumFailsTheVacuityGuard() throws {
        let root = try makeScratchRoot()
        for index in 0..<5 {
            try writeTriple(
                "pair-\(index)", raw: "raw \(index)", clean: "Clean \(index).",
                className: .fillers, in: root)
        }
        XCTAssertThrowsError(try CleanupPairSuite.loadPairs(from: root)) { error in
            XCTAssertEqual(
                error as? CleanupPairSuiteError,
                .corpusBelowMinimum(
                    found: 5, minimum: CleanupPairSuite.minimumMeaningfulCorpusSize))
        }

        let atMinimum = try makeScratchRoot()
        for index in 0..<CleanupPairSuite.minimumMeaningfulCorpusSize {
            try writeTriple(
                "pair-\(index)", raw: "raw \(index)", clean: "Clean \(index).",
                className: .fillers, in: atMinimum)
        }
        XCTAssertEqual(
            try CleanupPairSuite.loadPairs(from: atMinimum).count,
            CleanupPairSuite.minimumMeaningfulCorpusSize,
            "a corpus at the minimum loads — the guard is a floor, not a ceiling")
    }

    /// A pair without its `.class.txt` sidecar cannot print a per-class breakdown — a broken
    /// fixture, failing loudly and naming the pair and the expected sidecar path.
    func testAPairMissingItsClassTagThrowsNamingThePair() throws {
        let root = try makeScratchRoot()
        try Data("raw".utf8).write(to: root.appendingPathComponent("untagged.raw.txt"))
        try Data("clean.".utf8).write(to: root.appendingPathComponent("untagged.clean.txt"))
        XCTAssertThrowsError(try CleanupPairSuite.loadPairs(from: root)) { error in
            XCTAssertEqual(
                error as? CleanupPairSuiteError,
                .missingClassTag(
                    pair: "untagged",
                    expectedAt: root.appendingPathComponent("untagged.class.txt").path))
        }
    }

    /// A class tag the six-class vocabulary does not know fails loudly, naming the pair and the
    /// rejected tag — a typo in a sidecar must not silently land in no class's tally.
    func testAnUnknownClassTagThrowsNamingThePair() throws {
        let root = try makeScratchRoot()
        try Data("raw".utf8).write(to: root.appendingPathComponent("mystery.raw.txt"))
        try Data("clean.".utf8).write(to: root.appendingPathComponent("mystery.clean.txt"))
        try Data("bogus-class".utf8)
            .write(to: root.appendingPathComponent("mystery.class.txt"))
        XCTAssertThrowsError(try CleanupPairSuite.loadPairs(from: root)) { error in
            XCTAssertEqual(
                error as? CleanupPairSuiteError,
                .unknownClassTag(pair: "mystery", tag: "bogus-class"))
        }
    }

    // MARK: - B5/B6: the provisional targets and the latency gate

    /// The checked-in stand-in corpus, cleaned by the shipped rules with the corpus's
    /// dictionary, must land under the provisional p50 budget — measured with the real clock,
    /// through the gate's own arithmetic (the `ARCHITECTURE.md:310` budget).
    func testTheCorpusCleansUnderTheProvisionalP50Budget() async throws {
        let pairs = try CleanupPairSuite.loadPairs()
        let pairsDirectory = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Tests/CleanupPairs")
        let dictionary = await FileSystemDictionaryStore(directory: pairsDirectory).load()
        let p50 = CleanupLatencyGate.measureRulesP50(
            pairs: pairs, dictionary: dictionary, clock: ContinuousMonotonicClock())
        let verdict = CleanupLatencyGate.evaluate(p50: p50)
        XCTAssertTrue(
            verdict.passed,
            "stand-in corpus p50 \(verdict.p50) must be under the provisional budget "
                + "\(verdict.threshold) — a corpus the rules cannot clean fast measures nothing")
    }

    /// The load-bearing half of the gate: a pathological dictionary rule must genuinely blow the
    /// 10 ms budget, so the gate can fail before any real regression can slip. A gate that
    /// cannot fail proves nothing (`benchmark-gate/spec.md:27-29`).
    func testASeededSlowRuleFailsTheLatencyGate() {
        let pathologicalText = String(repeating: "a", count: 8000)
        let slowRule = ReplacementRule(
            source: String(repeating: "a", count: 4000) + "z",
            replacement: "x", caseSensitive: false, wordBoundary: false)
        let pairs = (0..<20).map { index in
            CleanupPair(
                name: "slow-\(index)", raw: pathologicalText, clean: "clean.",
                className: .fillers)
        }
        let p50 = CleanupLatencyGate.measureRulesP50(
            pairs: pairs, dictionary: [slowRule], clock: ContinuousMonotonicClock())
        let verdict = CleanupLatencyGate.evaluate(p50: p50)
        XCTAssertFalse(
            verdict.passed,
            "a seeded-slow rule must blow the \(verdict.threshold) budget — measured p50 "
                + "\(verdict.p50); a gate that cannot fail proves nothing")
    }

    /// The gate's threshold IS the provisional table: deleting the table breaks the gate (the
    /// `LatencyBenchmarkTests.swift` consumption shape).
    func testTheLatencyGateConsumesTheProvisionalTable() {
        XCTAssertEqual(
            CleanupLatencyGate.threshold, ProvisionalCleanupTargets.rulesPathP50,
            "the gate consumes the provisional rules-path budget — deleting the table breaks "
                + "the gate")
    }

    /// The one named table exists and carries the provisional figures (`ROADMAP.md:137`,
    /// `ARCHITECTURE.md:310`).
    func testTheProvisionalTargetsExistAndAreMarkedProvisional() {
        XCTAssertEqual(
            ProvisionalCleanupTargets.preferenceMinimum, 0.80,
            "the P1 gate's blind pairwise-preference minimum (ROADMAP.md:137)")
        XCTAssertEqual(
            ProvisionalCleanupTargets.rulesPathP50, .milliseconds(10),
            "the rules-path p50 budget (ARCHITECTURE.md:310)")
    }

    // MARK: - B3: the headless stand-in run

    /// The stand-in run scores the whole checked-in corpus through the real rules: the report
    /// covers every pair, the per-class tallies cover all six classes, the percentage equals
    /// the scorer's exact arithmetic — and, the recovery guarantee, **every non-planted pair
    /// is recovered by the shipped rules** (the planted pair is the one loss the scorer can
    /// count).
    func testTheStandInRunScoresTheWholeCorpusWithPerClassTalliesAndAPercentage() async throws {
        let pairs = try CleanupPairSuite.loadPairs()
        let dictionary = try await loadCorpusDictionary()
        let report = try await CleanupEvalRun.runHeadless(pairs: pairs, dictionary: dictionary)

        XCTAssertEqual(
            report.verdicts.count, pairs.count,
            "the report must cover every pair in the corpus")
        XCTAssertEqual(
            Set(report.verdicts.map(\.name)), Set(pairs.map(\.name)),
            "every pair named, exactly once")

        let plantedName = "numbers-units-planted-raw-preferred"
        for verdict in report.verdicts where verdict.name != plantedName {
            XCTAssertEqual(
                verdict.preference, .cleanedPreferred,
                "every non-planted stand-in pair must be recovered by the shipped rules: "
                    + "\(verdict.name) is \(verdict.preference) — fix the golden, not the test")
        }

        XCTAssertEqual(
            Set(report.perClassTallies.keys), Set(CleanupPairClass.allCases),
            "the per-class tallies cover all six classes")
        for className in CleanupPairClass.allCases {
            let expectedCount = pairs.filter { $0.className == className }.count
            XCTAssertEqual(
                report.perClassTallies[className]?.values.reduce(0, +), expectedCount,
                "class \(className.rawValue): tallies must account for every pair in the class")
        }

        let expectedPercentage = try CleanupPairwiseScorer.preferencePercentage(report.verdicts)
        XCTAssertEqual(
            report.percentage, expectedPercentage,
            "the reported percentage is the scorer's exact arithmetic")
    }

    /// The planted raw-preferred pair is counted as a loss through the real engine and the
    /// oracle — **the scorer can lose, or it measures nothing** (the can-lose proof).
    func testThePlantedRawPreferredPairIsCountedRawPreferred() async throws {
        let pairs = try CleanupPairSuite.loadPairs()
        let dictionary = try await loadCorpusDictionary()
        let report = try await CleanupEvalRun.runHeadless(pairs: pairs, dictionary: dictionary)

        let planted = report.verdicts.first {
            $0.name == "numbers-units-planted-raw-preferred"
        }
        XCTAssertEqual(
            planted?.preference, .rawPreferred,
            "the planted pair must count as a loss through the real engine — raw == golden, "
                + "and the rules rewrite the number word")
    }

    /// The stand-in run is deterministic: two runs, identical verdicts and percentage — the
    /// mechanism cannot be judged on a number that moves between invocations.
    func testTheStandInRunIsDeterministic() async throws {
        let pairs = try CleanupPairSuite.loadPairs()
        let dictionary = try await loadCorpusDictionary()
        let first = try await CleanupEvalRun.runHeadless(pairs: pairs, dictionary: dictionary)
        let second = try await CleanupEvalRun.runHeadless(pairs: pairs, dictionary: dictionary)
        XCTAssertEqual(first.verdicts, second.verdicts)
        XCTAssertEqual(first.percentage, second.percentage)
    }

    /// The run prints the record — the percentage, the per-class breakdown and the seed —
    /// through its injected printer, so the human-facing record exists and the test can hold it.
    func testTheStandInRunPrintsTheReport() async throws {
        let pairs = try CleanupPairSuite.loadPairs()
        let dictionary = try await loadCorpusDictionary()
        let spy = PrinterSpy()
        let report = try await CleanupEvalRun.runHeadless(
            pairs: pairs, dictionary: dictionary, printer: { spy.append($0) })

        XCTAssertFalse(spy.lines.isEmpty, "the run must print its record")
        XCTAssertTrue(
            spy.lines.contains { $0 == "preference=95.8%" },
            "the record must carry the exact preference percentage (23 of 24 pairs preferred "
                + "— the planted pair is the one loss), got: \(spy.lines)")
        XCTAssertTrue(
            spy.lines.contains { $0.lowercased().contains("5eedc0de") },
            "the record must carry the seed, got: \(spy.lines)")
        for className in CleanupPairClass.allCases {
            XCTAssertTrue(
                spy.lines.contains { $0.contains(className.rawValue) },
                "the record must carry the \(className.rawValue) class tally, got: \(spy.lines)")
        }
        XCTAssertEqual(report.seed, CleanupEvalRun.headlessSeed)
    }

    /// The corpus's shared dictionary, loaded from the checked-in `Tests/CleanupPairs`
    /// directory — the `user-dictionary` store reading `<dir>/dictionary.json`.
    private func loadCorpusDictionary() async throws -> [ReplacementRule] {
        let pairsDirectory = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Tests/CleanupPairs")
        return await FileSystemDictionaryStore(directory: pairsDirectory).load()
    }

    // MARK: - B4: the env-gated real run

    /// The env-gated runner fails loudly when the pairs directory is missing — a named error
    /// carrying the `VOCCA_CLEANUP_EVAL` name and the provisioning route (`SMOKE_CHECKLIST.md`
    /// step 73), the `RealEngineWERRunner` discipline.
    func testTheEnvGatedRunnerFailsLoudlyWhenThePairsDirectoryIsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-no-such-pairs-directory")
        do {
            _ = try await CleanupEvalRun.runFromDirectory(
                missing, answersURL: missing.appendingPathComponent("answers.tsv"))
            XCTFail("a missing pairs directory must throw, never read green")
        } catch let error as CleanupEvalRunError {
            XCTAssertEqual(error, .pairsDirectoryMissing(path: missing.path))
            let description = String(describing: error)
            XCTAssertTrue(
                description.contains("VOCCA_CLEANUP_EVAL"),
                "the error must name the environment variable, got: \(description)")
            XCTAssertTrue(
                description.contains("73"),
                "the error must point at the smoke step, got: \(description)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// The ballot-and-verdict flow is order-independent and never gates: a losing run (every
    /// answer one side) still returns the report, prints the seed beside the verdicts, and
    /// never throws on a below-target result — the run records, the founder re-baselines
    /// (`LatencyBenchmarkRealEngineTests`'s recorded-not-gated discipline).
    func testTheBallotAndVerdictFlowIsOrderIndependentAndNeverGates() throws {
        let names = (0..<20).map { String(format: "pair-%02d", $0) }
        let pairs = names.map {
            CleanupPair(name: $0, raw: "um raw", clean: "Clean.", className: .fillers)
        }
        let seed: UInt64 = 0x1234_5678
        let answers = Dictionary(uniqueKeysWithValues: names.map { ($0, BlindJudgeAnswer.left) })
        let spy = PrinterSpy()

        let report = try CleanupEvalRun.runReal(
            pairs: pairs, dictionary: [], answers: answers, seed: seed,
            printer: { spy.append($0) })

        let presentations = CleanupEvalRun.presentations(for: names, seed: seed)
        for (index, pair) in pairs.enumerated() {
            let expected = CleanupPairwiseScorer.verdict(
                judgeAnswer: answers[pair.name]!, presentation: presentations[index])
            XCTAssertEqual(
                report.verdicts[index].preference, expected,
                "\(pair.name): the verdict must follow the comparator's mapping for the seed")
        }
        XCTAssertEqual(
            report.percentage,
            try CleanupPairwiseScorer.preferencePercentage(report.verdicts),
            "the report carries the scorer's exact arithmetic")
        XCTAssertTrue(
            spy.lines.contains {
                $0.contains(String(seed, radix: 16, uppercase: true)) && $0.contains("pair-")
            },
            "the seed must be printed beside the verdict rows, got: \(spy.lines)")
        XCTAssertTrue(
            spy.lines.contains { $0.contains("RECORDED") },
            "the run must print the recorded-not-gated comparison line, got: \(spy.lines)")
    }

    /// The env-gated two-invocation flow, driven headlessly over a scratch stub corpus at the
    /// vacuity floor (the B2 stand-in pattern — no founder recording, no env var): the first
    /// invocation prints a seeded, side-blind ballot whose seed round-trips through
    /// `answers.tsv`'s first line; the second invocation prints the verdict rows through the
    /// same presentations. M4a's acceptance, headless.
    func testTheFirstInvocationPrintsASeededBallotAndTheSecondPrintsVerdicts() throws {
        let root = try makeScratchRoot()
        for index in 0..<CleanupPairSuite.minimumMeaningfulCorpusSize {
            try writeTriple(
                "pair-\(String(format: "%02d", index))",
                raw: "um raw \(index)", clean: "Clean \(index).",
                className: index % 2 == 0 ? .fillers : .punctuation, in: root)
        }
        let pairs = try CleanupPairSuite.loadPairs(from: root)

        // First invocation: the seeded ballot prints through the injected printer.
        let ballot = PrinterSpy()
        let seed = try CleanupEvalRun.runFirstInvocation(
            pairs: pairs, printer: { ballot.append($0) })

        // The printed seed is the `parseAnswers` spelling — bare hex after `seed=`. Swift's
        // radix parser rejects an `0x` prefix, so the bare spelling is load-bearing.
        let seedLine = try XCTUnwrap(ballot.lines.first, "the ballot must open with the seed line")
        XCTAssertTrue(seedLine.hasPrefix("seed="), "the seed line's spelling, got: \(seedLine)")
        let printedHex = String(seedLine.dropFirst("seed=".count))
        XCTAssertNotNil(UInt64(printedHex, radix: 16), "the printed seed must parse as hex")
        XCTAssertNil(UInt64("0x1A", radix: 16), "the parser rejects an 0x prefix — the bare spelling is load-bearing")
        XCTAssertEqual(seed, UInt64(printedHex, radix: 16), "the returned seed must be the printed one")
        XCTAssertNotEqual(seed, CleanupEvalRun.headlessSeed, "the real ballot must not reuse the stand-in's fixed seed")

        // The exact ballot grammar — the side-blindness pin: one seed line, then per pair
        // exactly the shapes `## <name> [<class>]`, `A: <text>`, `B: <text>`, `answer: ` and
        // nothing else — no label, no side-identifying column, so a future "which side is
        // cleaned" line breaks this test.
        XCTAssertEqual(
            ballot.lines.count, 1 + 4 * pairs.count,
            "the ballot must hold the seed line and exactly four lines per pair, got: \(ballot.lines)")
        let byName = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0) })
        let presentations = CleanupEvalRun.presentations(for: pairs.map(\.name), seed: seed)
        let presentationByName = Dictionary(
            uniqueKeysWithValues: pairs.enumerated().map {
                ($0.element.name, presentations[$0.offset])
            })
        for (offset, name) in CleanupPairwiseScorer.presentedOrder(pairs.map(\.name), seed: seed)
            .enumerated()
        {
            let pair = byName[name]!
            let block = Array(ballot.lines[(offset * 4 + 1)..<(offset * 4 + 5)])
            XCTAssertEqual(block[0], "## \(pair.name) [\(pair.className.rawValue)]")
            let rawFirst = presentationByName[name] == .rawFirst
            XCTAssertEqual(block[1], "A: \(rawFirst ? pair.raw : pair.clean)")
            XCTAssertEqual(block[2], "B: \(rawFirst ? pair.clean : pair.raw)")
            XCTAssertEqual(block[3], "answer: ")
        }

        // The founder's file, simulated: `seed\t<hex>` then one answer row per pair — a mixed
        // set carrying tie and noPreference rows (they round-trip and the denominator rule is
        // the scorer's, already pinned).
        var answerLines = ["seed\t" + printedHex]
        for (index, pair) in pairs.enumerated() {
            let word: String
            switch index % 4 {
            case 0: word = "left"
            case 1: word = "noPreference"
            case 2: word = "right"
            default: word = "tie"
            }
            answerLines.append("\(pair.name)\t\(word)")
        }
        let answersURL = root.appendingPathComponent("answers.tsv")
        try Data(answerLines.joined(separator: "\n").utf8).write(to: answersURL)

        // Second invocation: the same seed re-derives the same presentations, and the verdicts
        // map through them.
        let parsed = try CleanupEvalRun.parseAnswers(answersURL)
        XCTAssertEqual(parsed.seed, seed, "the answers file's seed must match the printed seed")

        let record = PrinterSpy()
        let report = try CleanupEvalRun.runReal(
            pairs: pairs, dictionary: [], answers: parsed.answers, seed: parsed.seed,
            printer: { record.append($0) })

        for (index, pair) in pairs.enumerated() {
            let expected = CleanupPairwiseScorer.verdict(
                judgeAnswer: parsed.answers[pair.name]!, presentation: presentations[index])
            XCTAssertEqual(
                report.verdicts[index].preference, expected,
                "\(pair.name): the verdict must follow the comparator's mapping for the seed")
        }
        XCTAssertEqual(
            report.percentage,
            try CleanupPairwiseScorer.preferencePercentage(report.verdicts),
            "the report carries the scorer's exact arithmetic")

        let seedHex = "0x" + String(seed, radix: 16, uppercase: true)
        let verdictRows = record.lines.filter { $0.contains("\t") && $0.contains("seed=") }
        XCTAssertEqual(verdictRows.count, pairs.count, "one verdict row per pair")
        for pair in pairs {
            XCTAssertTrue(
                verdictRows.contains {
                    $0.hasPrefix("\(pair.name)\t") && $0.contains("seed=\(seedHex)")
                },
                "the seed must be printed beside every verdict row, got: \(record.lines)")
        }
        XCTAssertTrue(
            record.lines.contains {
                $0.hasPrefix("preference=") && $0.contains("%")
            },
            "the record must carry the preference percentage, got: \(record.lines)")
        XCTAssertTrue(
            record.lines.contains { $0.contains("\ttie\t") },
            "the tie verdict rows must appear, got: \(record.lines)")
        XCTAssertTrue(
            record.lines.contains { $0.contains("\tnoPreference\t") },
            "the noPreference verdict rows must appear, got: \(record.lines)")
        for className in CleanupPairClass.allCases {
            XCTAssertTrue(
                record.lines.contains { $0.hasPrefix("\(className.rawValue): ") },
                "the record must carry the \(className.rawValue) class tally, got: \(record.lines)")
        }
        XCTAssertTrue(
            record.lines.contains { $0.contains("RECORDED") },
            "the run must print the recorded-not-gated comparison line, got: \(record.lines)")
    }

    /// An answers file that cannot score everything must not read green: a missing pair's
    /// answer and an answer naming a pair the corpus does not hold both fail loudly, listing
    /// the gap.
    func testMissingOrUnknownAnswersFailLoudly() throws {
        let pairs = (0..<3).map {
            CleanupPair(name: "pair-\($0)", raw: "raw", clean: "Clean.", className: .fillers)
        }
        let complete = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, BlindJudgeAnswer.tie) })

        var missingOne = complete
        missingOne.removeValue(forKey: "pair-1")
        XCTAssertThrowsError(
            try CleanupEvalRun.runReal(
                pairs: pairs, dictionary: [], answers: missingOne, seed: 1)
        ) { error in
            XCTAssertEqual(error as? CleanupEvalRunError, .answersMissingPair(name: "pair-1"))
        }

        var withUnknown = complete
        withUnknown["mystery-pair"] = .left
        XCTAssertThrowsError(
            try CleanupEvalRun.runReal(
                pairs: pairs, dictionary: [], answers: withUnknown, seed: 1)
        ) { error in
            XCTAssertEqual(
                error as? CleanupEvalRunError, .unknownPairInAnswers(name: "mystery-pair"))
        }
    }

    /// The env-gated real scoring run: skips **visibly** without `VOCCA_CLEANUP_EVAL`; with it
    /// set, a missing pairs directory is a **hard failure** (the variable was set — a skip
    /// would misread as "CI didn't run it"), a missing answers file skips naming the answers
    /// path (first invocation prints the ballot), and a complete F2 directory records — never
    /// gates — through the real run.
    func testTheRealScoringRunSkipsVisiblyWithoutTheEnvVarAndRecordsWhenSet() async throws {
        guard let envValue = ProcessInfo.processInfo.environment["VOCCA_CLEANUP_EVAL"] else {
            throw XCTSkip(
                "set VOCCA_CLEANUP_EVAL to the F2 pairs directory — see "
                    + "docs/SMOKE_CHECKLIST.md step 73")
        }
        let pairsDirectory = URL(fileURLWithPath: envValue)
        let answersURL = pairsDirectory.appendingPathComponent("answers.tsv")
        guard FileManager.default.fileExists(atPath: pairsDirectory.path) else {
            XCTFail(
                "VOCCA_CLEANUP_EVAL is set but the directory does not exist: "
                    + "\(pairsDirectory.path) — provision the F2 corpus per "
                    + "docs/SMOKE_CHECKLIST.md step 73")
            return
        }

        // A ballot that cannot be scored must not print: a wav sidecar without the engine is a
        // hard fail, ordered before the first-invocation branch.
        let hasWavs = try FileManager.default.contentsOfDirectory(
            at: pairsDirectory, includingPropertiesForKeys: nil)
            .contains { $0.pathExtension == "wav" }
        if hasWavs, ProcessInfo.processInfo.environment["VOCCA_MODEL_DIR"] == nil {
            XCTFail(
                "an F2 pair carries a .wav sidecar but VOCCA_MODEL_DIR is unset — provision "
                    + "the engine via Scripts/provision-asr-fixtures.sh first")
            return
        }

        guard FileManager.default.fileExists(atPath: answersURL.path) else {
            // The first invocation: print the seeded ballot. A corpus that cannot measure must
            // fail loudly rather than print a ballot for it.
            let pairs = try CleanupPairSuite.loadPairs(from: pairsDirectory)
            CleanupEvalRun.runFirstInvocation(pairs: pairs)
            throw XCTSkip(
                "ballot printed at \(pairsDirectory.path) — answer answers.tsv per SMOKE step "
                    + "73, then re-run")
        }

        var pairs = try CleanupPairSuite.loadPairs(from: pairsDirectory)
        if hasWavs {
            // The optional engine half: a pair's raw side is the real engine's transcript of
            // the recording (the `.raw.txt` is ignored for that pair), attributed to the
            // Parakeet identity — the I1 discipline. Construction mirrors
            // `ParakeetEngineWERTests`; the transport is a stub URL because a present and
            // verified model never reaches it.
            let modelDir = ProcessInfo.processInfo.environment["VOCCA_MODEL_DIR"]!
            let manifestURL = try PackageRootLocator.find(from: #filePath)
                .appendingPathComponent(
                    "Sources/VoccaASR/Models/Manifests/parakeet-tdt-0.6b-v3.json")
            let manifest = try ModelManifest.load(from: Data(contentsOf: manifestURL))
            let modelDirectory = URL(fileURLWithPath: modelDir)
            let store = ModelStore(
                rootURL: modelDirectory.deletingLastPathComponent()
                    .deletingLastPathComponent())
            let engine = ParakeetEngine(
                store: store,
                manifest: manifest,
                transport: DefaultModelTransport(
                    baseURL: URL(string: "https://unused.invalid")!),
                clock: ContinuousMonotonicClock())
            try await engine.prepare()

            var substituted: [CleanupPair] = []
            for pair in pairs {
                let wavURL = pairsDirectory.appendingPathComponent("\(pair.name).wav")
                guard FileManager.default.fileExists(atPath: wavURL.path) else {
                    substituted.append(pair)
                    continue
                }
                let samples = try readSamples16kMono(from: wavURL)
                let audio = VoccaCore.AudioBuffer(samples: samples, sampleRate: 16_000)
                let transcript = try await engine.transcribe(audio)
                XCTAssertEqual(
                    transcript.engine, ParakeetEngineIdentity.parakeet,
                    "the transcript must be attributed to the Parakeet identity (I1)")
                substituted.append(
                    CleanupPair(
                        name: pair.name, raw: transcript.text, clean: pair.clean,
                        className: pair.className))
            }
            pairs = substituted
        }

        let parsed = try CleanupEvalRun.parseAnswers(answersURL)
        let dictionary = await FileSystemDictionaryStore(directory: pairsDirectory).load()
        let spy = PrinterSpy()
        let report = try CleanupEvalRun.runReal(
            pairs: pairs, dictionary: dictionary, answers: parsed.answers,
            seed: parsed.seed, printer: { spy.append($0) })

        XCTAssertFalse(spy.lines.isEmpty, "the run must print its record")
        XCTAssertEqual(
            report.percentage,
            try CleanupPairwiseScorer.preferencePercentage(report.verdicts),
            "the record carries the scorer's exact arithmetic")
        XCTAssertTrue(
            spy.lines.contains { $0.contains("RECORDED") },
            "the comparison line must say recorded, never gated, got: \(spy.lines)")
    }

    /// The real run's recorded-not-gated comparison line reads the same table — the founder's
    /// run cannot print a verdict against a number that silently stopped existing.
    func testTheRealRunConsumesTheProvisionalPreferenceMinimum() {
        XCTAssertEqual(
            CleanupRealRunTargets.preferenceMinimum,
            ProvisionalCleanupTargets.preferenceMinimum,
            "the real run consumes the provisional preference minimum — deleting the table "
                + "breaks the founder's comparison line")
    }

    /// The provisional figure appears in exactly the named table and the test that pins it —
    /// nowhere else in `Sources/` or `Tests/` — so the P1-gate number cannot drift into a
    /// second home. The scan carries the vacuity guard in both directions: the named table's
    /// sighting exists, and the scanned tree is non-empty.
    func testThePreferenceMinimumAppearsNowhereOutsideTheNamedFile() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let namedTable = "ProvisionalCleanupTargets.swift"
        let pinningTest = "CleanupEvalHarnessTests.swift"
        let allowedSightings: Set<String> = [namedTable, pinningTest]

        var sightings: [String: Int] = [:]
        for tree in [root.appendingPathComponent("Sources"), root.appendingPathComponent("Tests")] {
            for file in SwiftSourceScanner.swiftFiles(under: tree) {
                let content = try String(contentsOf: file, encoding: .utf8)
                if content.contains("0.80") {
                    sightings[file.lastPathComponent, default: 0] += 1
                }
            }
        }

        XCTAssertFalse(sightings.isEmpty, "vacuity guard: the scan saw no files at all")
        XCTAssertEqual(
            Set(sightings.keys), allowedSightings,
            "0.80 must live in exactly the named table and its pinning test, got: \(sightings)")
        XCTAssertEqual(
            sightings[namedTable], 1,
            "the named table's own sighting must exist — the vacuity guard's second direction")
    }
}

/// The corpus's shared dictionary, loaded from the checked-in `Tests/CleanupPairs` directory —
/// the `user-dictionary` store reading `<dir>/dictionary.json`.
private final class PrinterSpy: @unchecked Sendable {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}

/// The `answers.tsv` verdict words — `left|right|tie|noPreference` — parsed from the founder's
/// ballot answers.
extension BlindJudgeAnswer {
    init?(tsvWord: String) {
        switch tsvWord {
        case "left": self = .left
        case "right": self = .right
        case "tie": self = .tie
        case "noPreference": self = .noPreference
        default: return nil
        }
    }
}

/// Reads any WAV into 16 kHz mono Float32 — the ASR seam's format — the F2 recording contract
/// (`SMOKE_CHECKLIST.md` step 73). The same AVFoundation conversion the ASR fixture suite uses;
/// a recording the harness cannot load must fail loudly, not read green.
private func readSamples16kMono(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else {
        throw CleanupEvalRunError.recordingUnreadable(path: url.path)
    }
    try file.read(into: buffer)
    let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
        throw CleanupEvalRunError.recordingUnreadable(path: url.path)
    }
    let ratio = target.sampleRate / file.processingFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
        throw CleanupEvalRunError.recordingUnreadable(path: url.path)
    }
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, outStatus in
        outStatus.pointee = .haveData
        return buffer
    }
    guard status != .error else {
        throw CleanupEvalRunError.recordingUnreadable(path: url.path)
    }
    guard let channels = output.floatChannelData else {
        throw CleanupEvalRunError.recordingUnreadable(path: url.path)
    }
    return Array(UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength)))
}

/// The real run's recorded-not-gated comparison line reads this constant — the B6 consumption
/// pin — so the founder's run cannot print a verdict against a number that silently stopped
/// existing, and the provisional table stays the one place the figure lives.
enum CleanupRealRunTargets {
    static let preferenceMinimum = ProvisionalCleanupTargets.preferenceMinimum
}

/// The rules-path latency gate (B5) — a test-only mechanism over the pure rules function.
///
/// CI asserts two things and no more: the stand-in corpus lands under the provisional p50
/// budget (a mechanism check over a pure stdlib function), and a seeded-slow rule genuinely
/// fails the gate (a gate that cannot fail proves nothing — `benchmark-gate/spec.md:27-29`).
/// The product number comes from the founder's env-gated run, which records, never gates.
enum CleanupLatencyGate {

    /// One gate verdict: the measured p50, the threshold it was judged against, and the pass.
    struct Verdict: Equatable {
        let p50: Duration
        let threshold: Duration
        let passed: Bool
    }

    /// The threshold IS the provisional table — deleting the table breaks the gate.
    static var threshold: Duration { ProvisionalCleanupTargets.rulesPathP50 }

    static func evaluate(p50: Duration) -> Verdict {
        let threshold = threshold
        return Verdict(p50: p50, threshold: threshold, passed: p50 < threshold)
    }

    /// Nearest-rank percentile over `values`, or `nil` when there are no samples — a harness
    /// with nothing measured must not divide by nothing.
    static func percentile(_ values: [Duration], _ p: Double) -> Duration? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = min(Int((Double(sorted.count) * p).rounded(.up)), sorted.count) - 1
        return sorted[max(rank, 0)]
    }

    /// One `RulesCleanup.clean` call per pair, p50 over the samples — measured with the
    /// injected clock (the pure function itself carries no clock).
    static func measureRulesP50(
        pairs: [CleanupPair],
        dictionary: [ReplacementRule],
        clock: any MonotonicClock
    ) -> Duration {
        let samples = pairs.map { pair in
            let start = clock.now
            _ = RulesCleanup.clean(pair.raw, dictionary: dictionary)
            return clock.now - start
        }
        return percentile(samples, 0.50) ?? .zero
    }
}

/// Why the env-gated real run failed, named — the `RealEngineWERRunner` discipline: a founder
/// run that cannot score everything must say so, listing the gap.
enum CleanupEvalRunError: Error, Equatable, CustomStringConvertible {
    /// The `VOCCA_CLEANUP_EVAL` pairs directory does not exist.
    case pairsDirectoryMissing(path: String)
    /// The answers file has no answer for a pair in the corpus.
    case answersMissingPair(name: String)
    /// The answers file names a pair the corpus does not hold.
    case unknownPairInAnswers(name: String)
    /// A line of `answers.tsv` is not `name<TAB>left|right|tie|noPreference`, or the seed line
    /// is missing.
    case malformedAnswers(line: String)
    /// An F2 recording (`<name>.wav`) cannot be read into the seam's 16 kHz mono format.
    case recordingUnreadable(path: String)

    var description: String {
        switch self {
        case .pairsDirectoryMissing(let path):
            return "VOCCA_CLEANUP_EVAL points at a directory that does not exist: \(path) — "
                + "record the F2 corpus there per docs/SMOKE_CHECKLIST.md step 73"
        case .answersMissingPair(let name):
            return "answers.tsv has no answer for pair \(name) — a run that cannot score "
                + "everything must not read green"
        case .unknownPairInAnswers(let name):
            return "answers.tsv names pair \(name), which the corpus does not hold — a typo "
                + "must not silently vanish into no pair"
        case .malformedAnswers(let line):
            return "malformed answers.tsv line: \"\(line)\" — expected name<TAB>"
                + "left|right|tie|noPreference, with a first line seed<TAB><hex>"
        case .recordingUnreadable(let path):
            return "cannot read the F2 recording at \(path) into 16 kHz mono — the recording "
                + "contract is per docs/SMOKE_CHECKLIST.md step 73"
        }
    }
}

/// The headless stand-in run (B3): the shipped rules over the checked-in corpus with the oracle
/// judge — the CI-runnable half of the eval harness.
///
/// Text in, text out: the corpus arrives as `CleanupPair`s, the verdicts come from the pure
/// scorer's oracle, and no transport exists to touch — the family is lint-pinned never to name
/// `URLSession` (`ModelDownloaderSeamTests` B3 row). The printed record carries the exact
/// preference percentage, the per-class tallies and the seed, through an injected printer (the
/// default writes to stdout) so the human-facing record exists and tests can hold it.
enum CleanupEvalRun {

    /// The run's record: every pair's verdict, the aggregate percentage, the per-class tallies
    /// and the seed the presentation would use — reproducible, and `Sendable`.
    struct Report: Sendable {
        let verdicts: [PairVerdict]
        let percentage: Double
        let perClassTallies: [CleanupPairClass: [PairwisePreference: Int]]
        let seed: UInt64
    }

    /// The stand-in corpus's fixed seed — two runs of the mechanism land on the same record.
    static let headlessSeed: UInt64 = 0x5EED_C0DE

    /// Scores every pair through `RulesCleanup.clean` and the oracle, computes the aggregate
    /// and the tallies, prints the record, and returns it.
    @discardableResult
    static func runHeadless(
        pairs: [CleanupPair],
        dictionary: [ReplacementRule],
        seed: UInt64 = headlessSeed,
        printer: @escaping @Sendable (String) -> Void = { print($0) }
    ) async throws -> Report {
        let verdicts = pairs.map { pair in
            let produced = RulesCleanup.clean(pair.raw, dictionary: dictionary)
            return PairVerdict(
                name: pair.name,
                preference: CleanupPairwiseScorer.oracleVerdict(
                    raw: pair.raw, produced: produced, golden: pair.clean),
                className: pair.className)
        }
        let percentage = try CleanupPairwiseScorer.preferencePercentage(verdicts)

        var perClassTallies: [CleanupPairClass: [PairwisePreference: Int]] = [:]
        for className in CleanupPairClass.allCases {
            perClassTallies[className] = [:]
        }
        for verdict in verdicts {
            perClassTallies[verdict.className, default: [:]][verdict.preference, default: 0] += 1
        }

        printer(String(format: "preference=%.1f%%", percentage * 100))
        printer("seed=0x" + String(seed, radix: 16, uppercase: true))
        for className in CleanupPairClass.allCases {
            let tallies = perClassTallies[className] ?? [:]
            let cleaned = tallies[.cleanedPreferred, default: 0]
            let raw = tallies[.rawPreferred, default: 0]
            let other = tallies[.tie, default: 0] + tallies[.noPreference, default: 0]
            printer("\(className.rawValue): cleaned \(cleaned), raw \(raw), no-preference \(other)")
        }

        return Report(
            verdicts: verdicts,
            percentage: percentage,
            perClassTallies: perClassTallies,
            seed: seed)
    }

    // MARK: - The env-gated real half (B4)

    /// The per-pair presentations for a ballot, deterministic in the seed: one generator draw
    /// per pair, even → `rawFirst`. Both `printBallot` and `runReal` derive the same order from
    /// the same seed — the seed embedded in `answers.tsv` is what makes the two invocations
    /// present the same sides.
    static func presentations(for names: [String], seed: UInt64) -> [PairPresentation] {
        var generator = SeededGenerator(seed: seed)
        return names.map { _ in
            generator.next() % 2 == 0 ? PairPresentation.rawFirst : .cleanedFirst
        }
    }

    /// Parses `<pairsDir>/answers.tsv`: a first line `seed<TAB><hex>` (the ballot-time seed, so
    /// both invocations present the same order), then one `name<TAB>left|right|tie|noPreference`
    /// line per pair. Anything else is a named error listing the line.
    static func parseAnswers(
        _ url: URL
    ) throws -> (seed: UInt64, answers: [String: BlindJudgeAnswer]) {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let seedLine = lines.first, seedLine.hasPrefix("seed\t"),
            let seed = UInt64(seedLine.dropFirst("seed\t".count), radix: 16)
        else {
            throw CleanupEvalRunError.malformedAnswers(line: lines.first ?? "")
        }
        var answers: [String: BlindJudgeAnswer] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2,
                let verdict = BlindJudgeAnswer(tsvWord: String(parts[1]))
            else {
                throw CleanupEvalRunError.malformedAnswers(line: line)
            }
            answers[String(parts[0])] = verdict
        }
        return (seed, answers)
    }

    /// The env-gated flow's first invocation: a fresh seed, then the ballot printed through
    /// the injected printer — the seed the judge's `answers.tsv` first line must match
    /// (`seed\t<hex>`, the `=` → `\t` substitution). No file IO — the founder authors
    /// `answers.tsv` by hand.
    static func runFirstInvocation(
        pairs: [CleanupPair],
        printer: @escaping @Sendable (String) -> Void = { print($0) }
    ) -> UInt64 {
        let seed = UInt64.random(in: .min ... .max)
        printBallot(pairs: pairs, seed: seed, printer: printer)
        return seed
    }

    /// Prints the founder's reading copy: the seed at the top, then every pair in the seeded
    /// presentation order as `A:`/`B:` texts with its class tag and a blank answer column. The
    /// judge answers `left|right|tie|noPreference` per pair — never seeing labels.
    static func printBallot(
        pairs: [CleanupPair],
        seed: UInt64,
        printer: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        printer("seed=" + String(seed, radix: 16, uppercase: true))
        let names = pairs.map(\.name)
        let presentations = presentations(for: names, seed: seed)
        for name in CleanupPairwiseScorer.presentedOrder(names, seed: seed) {
            guard let index = names.firstIndex(of: name) else { continue }
            let pair = pairs[index]
            let sideA =
                presentations[index] == .rawFirst ? pair.raw : pair.clean
            let sideB =
                presentations[index] == .rawFirst ? pair.clean : pair.raw
            printer("## \(pair.name) [\(pair.className.rawValue)]")
            printer("A: \(sideA)")
            printer("B: \(sideB)")
            printer("answer: ")
        }
    }

    /// The founder's run: blind answers mapped through the seed's presentation order into
    /// verdicts. **Records, never gates** — a below-target percentage is printed as a
    /// RECORDED comparison line, never thrown (`LatencyBenchmarkRealEngineTests` discipline).
    @discardableResult
    static func runReal(
        pairs: [CleanupPair],
        dictionary: [ReplacementRule],
        answers: [String: BlindJudgeAnswer],
        seed: UInt64,
        printer: @escaping @Sendable (String) -> Void = { print($0) }
    ) throws -> Report {
        for pair in pairs where answers[pair.name] == nil {
            throw CleanupEvalRunError.answersMissingPair(name: pair.name)
        }
        for name in answers.keys where !pairs.contains(where: { $0.name == name }) {
            throw CleanupEvalRunError.unknownPairInAnswers(name: name)
        }

        let names = pairs.map(\.name)
        let presentations = presentations(for: names, seed: seed)
        let seedHex = "0x" + String(seed, radix: 16, uppercase: true)

        let verdicts = pairs.enumerated().map { index, pair in
            let verdict = CleanupPairwiseScorer.verdict(
                judgeAnswer: answers[pair.name]!, presentation: presentations[index])
            printer("\(pair.name)\t\(verdictLabel(verdict))\tseed=\(seedHex)")
            return PairVerdict(
                name: pair.name, preference: verdict, className: pair.className)
        }
        let percentage = try CleanupPairwiseScorer.preferencePercentage(verdicts)

        var perClassTallies: [CleanupPairClass: [PairwisePreference: Int]] = [:]
        for className in CleanupPairClass.allCases {
            perClassTallies[className] = [:]
        }
        for verdict in verdicts {
            perClassTallies[verdict.className, default: [:]][verdict.preference, default: 0] += 1
        }

        printer(String(format: "preference=%.1f%%", percentage * 100))
        for className in CleanupPairClass.allCases {
            let tallies = perClassTallies[className] ?? [:]
            printer(
                "\(className.rawValue): cleaned \(tallies[.cleanedPreferred, default: 0]), "
                    + "raw \(tallies[.rawPreferred, default: 0])")
        }
        printer(
            "verdict \(String(format: "%.0f%%", percentage * 100)) vs provisional "
                + "\(CleanupRealRunTargets.preferenceMinimum): RECORDED, not gated — the "
                + "founder re-baselines (SMOKE_CHECKLIST.md step 73)")

        return Report(
            verdicts: verdicts,
            percentage: percentage,
            perClassTallies: perClassTallies,
            seed: seed)
    }

    /// The founder-machine entry point: everything a run needs from one directory — the pairs
    /// (missing directory is a named error naming `VOCCA_CLEANUP_EVAL`), the answers file and
    /// the dictionary.
    static func runFromDirectory(
        _ pairsDirectory: URL,
        answersURL: URL,
        printer: @escaping @Sendable (String) -> Void = { print($0) }
    ) async throws -> Report {
        guard FileManager.default.fileExists(atPath: pairsDirectory.path) else {
            throw CleanupEvalRunError.pairsDirectoryMissing(path: pairsDirectory.path)
        }
        let parsed = try parseAnswers(answersURL)
        let pairs = try CleanupPairSuite.loadPairs(from: pairsDirectory)
        let dictionary = await FileSystemDictionaryStore(directory: pairsDirectory).load()
        return try runReal(
            pairs: pairs, dictionary: dictionary, answers: parsed.answers,
            seed: parsed.seed, printer: printer)
    }

    /// The verdict's word on the ballot-answer rows — the human-readable record.
    private static func verdictLabel(_ preference: PairwisePreference) -> String {
        switch preference {
        case .cleanedPreferred: return "cleanedPreferred"
        case .rawPreferred: return "rawPreferred"
        case .tie: return "tie"
        case .noPreference: return "noPreference"
        }
    }
}
