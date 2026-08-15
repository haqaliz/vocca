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

/// One held-out raw→clean pair (`eval-harness/spec.md:24-36`): the as-spoken/ASR-raw side, the
/// golden clean target, and the class tag the per-class tallies are broken out by. The F2
/// corpus uses the identical triple format.
struct CleanupPair: Sendable, Equatable {
    /// The pair's base name — `<name>.raw.txt` etc. on disk.
    let name: String
    /// The as-spoken / ASR-raw side — what `RulesCleanup` is scored on.
    let raw: String
    /// The golden clean target — what should have been typed.
    let clean: String
    /// The pair's class tag — one of the six rule classes.
    let className: CleanupPairClass
}

/// Why a corpus failed to load, named — the harness cannot measure nothing, so every broken
/// shape fails loudly in the `ASRFixtureSuite`/`RealEngineWERRunner` discipline.
enum CleanupPairSuiteError: Error, Equatable, CustomStringConvertible {
    /// The directory held no `.raw.txt` pair at all.
    case noPairsFound(String)
    /// A pair's `.clean.txt` golden is absent.
    case missingCleanTarget(pair: String, expectedAt: String)
    /// A pair's `.class.txt` sidecar is absent.
    case missingClassTag(pair: String, expectedAt: String)
    /// A pair's class tag is not one of the six vocabulary words.
    case unknownClassTag(pair: String, tag: String)
    /// The corpus loaded but holds fewer pairs than the named minimum — a trimmed corpus must
    /// not read green.
    case corpusBelowMinimum(found: Int, minimum: Int)

    var description: String {
        switch self {
        case .noPairsFound(let path):
            return "no .raw.txt pairs found under \(path) — the harness has nothing to measure"
        case .missingCleanTarget(let pair, let expectedAt):
            return "pair \(pair) has no golden clean target at \(expectedAt) — a pair without "
                + "its golden is a broken fixture"
        case .missingClassTag(let pair, let expectedAt):
            return "pair \(pair) has no class tag at \(expectedAt) — a pair without a class "
                + "cannot print a per-class breakdown"
        case .unknownClassTag(let pair, let tag):
            return "pair \(pair) carries unknown class tag \"\(tag)\" — expected one of "
                + CleanupPairClass.allCases.map(\.rawValue).joined(separator: ", ")
        case .corpusBelowMinimum(let found, let minimum):
            return "corpus holds \(found) pairs, below the minimum \(minimum) — a corpus that "
                + "small cannot measure anything meaningful"
        }
    }
}

/// The cleanup pair corpus's discovery (`eval-harness/spec.md:24-36`, B2): pairs are triples of
/// siblings `<name>.raw.txt` + `<name>.clean.txt` + `<name>.class.txt`, and the loader is the
/// `ASRFixtureSuite` shape — discovery keys on the `.raw.txt` suffix only, so `dictionary.json`
/// and `FIXTURES.md` in the same directory are never misread as pairs; a missing golden, a
/// missing class tag, an unknown tag, an empty directory and a below-minimum corpus all throw a
/// named error. **A harness that cannot measure must never read green.**
enum CleanupPairSuite {

    /// The vacuity floor: a corpus below this many pairs cannot read green (spec §2.3 — the
    /// shipped stand-in corpus sits at 24, above it).
    static let minimumMeaningfulCorpusSize = 20

    /// Loads every pair under `pairsDirectory` (default `Tests/CleanupPairs` at the package
    /// root — the checked-in stand-in corpus).
    static func loadPairs(from pairsDirectory: URL? = nil) throws -> [CleanupPair] {
        let directory: URL
        if let pairsDirectory {
            directory = pairsDirectory
        } else {
            directory = try PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Tests/CleanupPairs")
        }
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        let rawFiles = entries.filter {
            $0.lastPathComponent.hasSuffix(".raw.txt")
        }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        guard !rawFiles.isEmpty else {
            throw CleanupPairSuiteError.noPairsFound(directory.path)
        }

        let pairs = try rawFiles.map { rawFile -> CleanupPair in
            let name = String(rawFile.lastPathComponent.dropLast(".raw.txt".count))
            let cleanURL = directory.appendingPathComponent("\(name).clean.txt")
            guard fileManager.fileExists(atPath: cleanURL.path) else {
                throw CleanupPairSuiteError.missingCleanTarget(
                    pair: name, expectedAt: cleanURL.path)
            }
            let classURL = directory.appendingPathComponent("\(name).class.txt")
            guard fileManager.fileExists(atPath: classURL.path) else {
                throw CleanupPairSuiteError.missingClassTag(
                    pair: name, expectedAt: classURL.path)
            }
            let tag = try String(contentsOf: classURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let className = CleanupPairClass(rawValue: tag) else {
                throw CleanupPairSuiteError.unknownClassTag(pair: name, tag: tag)
            }
            let raw = try String(contentsOf: rawFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = try String(contentsOf: cleanURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CleanupPair(name: name, raw: raw, clean: clean, className: className)
        }

        guard pairs.count >= minimumMeaningfulCorpusSize else {
            throw CleanupPairSuiteError.corpusBelowMinimum(
                found: pairs.count, minimum: minimumMeaningfulCorpusSize)
        }
        return pairs
    }
}
