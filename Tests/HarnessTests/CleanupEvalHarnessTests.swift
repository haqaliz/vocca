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
    func testTheEnvGatedRunnerFailsLoudlyWhenThePairsDirectoryIsMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-no-such-pairs-directory")
        let answersURL = missing.appendingPathComponent("answers.tsv")
        XCTAssertThrowsError(try CleanupEvalRun.runFromDirectory(missing, answersURL: answersURL)) { error in
            XCTAssertEqual(
                error as? CleanupEvalRunError,
                .pairsDirectoryMissing(path: missing.path))
            let description = String(describing: error)
            XCTAssertTrue(
                description.contains("VOCCA_CLEANUP_EVAL"),
                "the error must name the environment variable, got: \(description)")
            XCTAssertTrue(
                description.contains("73"),
                "the error must point at the smoke step, got: \(description)")
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
        guard FileManager.default.fileExists(atPath: answersURL.path) else {
            throw XCTSkip(
                "VOCCA_CLEANUP_EVAL is set but answers.tsv is missing at \(answersURL.path) — "
                    + "the first invocation prints the ballot")
        }

        let hasWavs = try FileManager.default.contentsOfDirectory(
            at: pairsDirectory, includingPropertiesForKeys: nil)
            .contains { $0.pathExtension == "wav" }
        if hasWavs, ProcessInfo.processInfo.environment["VOCCA_MODEL_DIR"] == nil {
            XCTFail(
                "an F2 pair carries a .wav sidecar but VOCCA_MODEL_DIR is unset — provision "
                    + "the engine via Scripts/provision-asr-fixtures.sh first")
            return
        }

        let parsed = try CleanupEvalRun.parseAnswers(answersURL)
        let pairs = try CleanupPairSuite.loadPairs(from: pairsDirectory)
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
}
