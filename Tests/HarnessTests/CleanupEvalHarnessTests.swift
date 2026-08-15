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

    /// Discovery keys on the `.raw.txt` suffix only: two triples load as exactly two pairs with
    /// names and class tags intact — and a `dictionary.json` or `FIXTURES.md` in the same
    /// directory is never misread as a pair.
    func testLoadPairsFindsEveryPairUnderTheDirectory() throws {
        let root = try makeScratchRoot()
        try writeTriple(
            "a-one", raw: "um raw one", clean: "One.", className: .fillers, in: root)
        try writeTriple(
            "b-two", raw: "raw two", clean: "Two.", className: .punctuation, in: root)
        try Data(#"[{"source":"kawa","replacement":"Kawa"}]"#.utf8)
            .write(to: root.appendingPathComponent("dictionary.json"))
        try Data("# provenance".utf8).write(to: root.appendingPathComponent("FIXTURES.md"))

        let pairs = try CleanupPairSuite.loadPairs(from: root)
        XCTAssertEqual(
            pairs.map(\.name), ["a-one", "b-two"],
            "both triples found, sorted, with dictionary.json and FIXTURES.md ignored")
        XCTAssertEqual(
            pairs.map(\.className), [.fillers, .punctuation],
            "the class tags arrive intact")
        XCTAssertEqual(pairs[0].raw, "um raw one")
        XCTAssertEqual(pairs[0].clean, "One.")
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
}
