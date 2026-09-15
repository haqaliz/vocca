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

/// Raised when the scan cannot be evaluated meaningfully, so that measuring nothing is a failure
/// rather than a pass.
private enum VoiceDetectionSeamTestError: Error, CustomStringConvertible {
    case seamDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .seamDirectoryMissing(let expectedAt):
            return """
                The voice-detection seam's module directory does not exist at \(expectedAt). The \
                voice-detection confinement is asserted by scanning the source tree; if the module \
                has moved or been renamed, this lint enforces nothing.
                """
        case .noSwiftFilesScanned(let under):
            return """
                No .swift files were found under \(under) — the confinement was not evaluated \
                against anything. That is the vacuous green this check exists to prevent, so it is \
                a failure.
                """
        }
    }
}

/// The voice-detection family lint (`plan_20260915.md` Phase 3): **within `VoccaCore`, each of
/// the four seam names may appear only in its permitted files** — the declaration, the
/// conformance that must name the protocol, and nothing else.
///
/// The same shape as the Kokoro runtime confinement (`KokoroSeamBoundaryTests`) and the AVFAudio
/// confinement (`SpeechSeamBoundaryTests`), adapted to a **per-family table**: where those lints
/// confine one adapter file, the voice-detection vocabulary has two seams and two pure fallbacks,
/// each with its own permitted-file set —
///
/// - `VoiceActivityDetector` → the protocol file and `EnergyVAD.swift` (its conformance);
/// - `EnergyVAD` → `EnergyVAD.swift` only (one file, strictly);
/// - `TurnDetector` → the protocol file and `SilenceThresholdDetector.swift` (its conformance);
/// - `SilenceThresholdDetector` → `SilenceThresholdDetector.swift` only.
///
/// The family is an identifier prefix (`\b(name)[A-Za-z0-9_]*`), so every member is covered by
/// construction — a leaked `EnergyVADDouble` or `SilenceThresholdDetectorTuned` trips the lint
/// the same as the name itself. This is the third layer of the no-branch pin (R2: callers never
/// branch on implementation): a caller physically cannot branch on an implementation it cannot
/// name outside that implementation's one file.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name the families to explain what
/// is confined. It is not string-literal aware (see ``SwiftSourceScanner``). Both are deliberate
/// trade-offs of a text scan; what matters is that a *type in code* cannot appear without a
/// reviewed edit to the permitted table below.
///
/// ## Who must amend this lint
///
/// The `sdk-adapters` aspect does **not** touch this lint: its `SileroVAD` / EOU adapters live in
/// `VoccaASR`, governed by that module's H8b amendment. The `barge-in-loop` aspect **must**
/// amend the two seam-name rows (`VoiceActivityDetector`, `TurnDetector`) when its loop file
/// names the seams — the loop is the first legitimate caller, and its sighting is a reviewed
/// edit to this table, never a lint deletion.
final class VoiceDetectionSeamBoundaryTests: XCTestCase {

    /// The module the seams live in — the scan root.
    private static let seamModuleRoot = "VoccaCore"

    /// The permitted-file table, keyed by identifier-prefix family, relative to
    /// ``seamModuleRoot``.
    ///
    /// **Each entry is reviewed, and nothing joins a set without a reason.** `EnergyVAD` and
    /// `SilenceThresholdDetector` are one file each, strictly — the fallbacks are the only
    /// places those names may appear.
    private static let permittedFilesByFamily: [String: Set<String>] = [
        "VoiceActivityDetector": [
            "VoiceDetection/VoiceActivityDetector.swift",
            "VoiceDetection/EnergyVAD.swift",
            "TurnTaking/TurnTakingLoop.swift",
        ],
        "EnergyVAD": [
            "VoiceDetection/EnergyVAD.swift"
        ],
        "TurnDetector": [
            "TurnDetection/TurnDetector.swift",
            "TurnDetection/SilenceThresholdDetector.swift",
            "TurnTaking/TurnTakingLoop.swift",
        ],
        "SilenceThresholdDetector": [
            "TurnDetection/SilenceThresholdDetector.swift"
        ],
    ]

    /// Every occurrence of the family's identifier prefix in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsAPlantedEnergyVADUse``.
    private static func familyIdentifiers(inSource source: String, family: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b(" + family + ")[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    private func sourcesRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath).appendingPathComponent("Sources")
    }

    /// Every sighting of one family under the seam's module root.
    private func sightings(under root: URL, family: String) throws -> [String: [String]] {
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw VoiceDetectionSeamTestError.noSwiftFilesScanned(under: root.path)
        }

        var byFile: [String: [String]] = [:]
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let source = try String(contentsOf: file, encoding: .utf8)
            let identifiers = Self.familyIdentifiers(inSource: source, family: family)
            if !identifiers.isEmpty {
                byFile[relative] = identifiers
            }
        }
        return byFile
    }

    /// The whole of the confinement, per family: every sighting sits in a permitted file, and
    /// the permitted files are the only ones permitted.
    ///
    /// Two independent claims, because either one failing alone still passes a one-sided check:
    /// "no other file names the family" passes if the permitted files *also* lost their
    /// implementations (the family used everywhere else — vacuous), and "the permitted files
    /// name the family" passes if three files do (the seam has sprung a leak).
    func testEachFamilyIsConfinedToItsPermittedFiles() throws {
        let root = try sourcesRoot().appendingPathComponent(Self.seamModuleRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw VoiceDetectionSeamTestError.seamDirectoryMissing(expectedAt: root.path)
        }

        for family in Self.permittedFilesByFamily.keys.sorted() {
            guard let permitted = Self.permittedFilesByFamily[family] else { continue }
            let sightings = try sightings(under: root, family: family)

            let offenders = sightings.keys.filter { !permitted.contains($0) }
            XCTAssertTrue(
                offenders.isEmpty,
                "the \(family) family is named outside its permitted files: \(offenders.sorted())")

            XCTAssertFalse(
                permitted.isEmpty,
                "the permitted set for \(family) must not be empty — an empty set passes 'no file names it' vacuously")
            for file in permitted.sorted() {
                XCTAssertFalse(
                    sightings[file]?.isEmpty ?? true,
                    "the permitted file \(file) must actually name the \(family) family — a "
                        + "permitted file that does not means the family moved somewhere else and "
                        + "the lint cannot see it")
            }
            XCTAssertEqual(
                sightings.count, permitted.count,
                "exactly the permitted set may name the \(family) family, got \(sightings.keys.sorted())")
        }
    }

    /// The lint's negative control: a planted `EnergyVAD` use is caught — both the name itself
    /// and a second-implementation prefix, in the shapes a leaked fallback would actually use
    /// them.
    func testTheLintDetectsAPlantedEnergyVADUse() {
        let source = """
            import VoccaCore

            struct EnergyVADDouble: VoiceActivityDetector {
                var configuration: VADConfiguration
                mutating func classify(_ frame: AudioBuffer) -> SpeechActivity { .silence }
            }

            func leak(_ detector: EnergyVAD) -> SpeechActivity { .silence }
            """
        let identifiers = Self.familyIdentifiers(inSource: source, family: "EnergyVAD")
        XCTAssertEqual(
            identifiers, ["EnergyVADDouble", "EnergyVAD"],
            "the detector must find the planted second implementation and the planted use of the "
                + "fallback itself")
    }

    /// The `SilenceThresholdDetector` planted twin — the turn seam's fallback leaks the same
    /// way.
    func testTheLintDetectsAPlantedSilenceThresholdDetectorUse() {
        let source = """
            import VoccaCore

            struct SilenceThresholdDetectorTuned: TurnDetector {
                func decide(_ pause: AudioBuffer, utterance: AudioBuffer) -> TurnScore {
                    TurnScore(score: 0, commitment: .keepListening)
                }
            }

            func leak(_ detector: SilenceThresholdDetector) -> TurnScore {
                TurnScore(score: 0, commitment: .keepListening)
            }
            """
        let identifiers = Self.familyIdentifiers(inSource: source, family: "SilenceThresholdDetector")
        XCTAssertEqual(
            identifiers, ["SilenceThresholdDetectorTuned", "SilenceThresholdDetector"],
            "the detector must find the planted second implementation and the planted use of the "
                + "fallback itself")
    }

    /// A doc comment may name the families — the scanner strips comments, which is what lets
    /// the seam files' documentation explain what is confined without tripping the lint.
    func testADocCommentNamingTheFamiliesDoesNotTripTheLint() {
        let source = """
            /// The voice-detection vocabulary: VoiceActivityDetector and EnergyVAD on one seam,
            /// TurnDetector and SilenceThresholdDetector on the other — confined by
            /// VoiceDetectionSeamBoundaryTests.
            import VoccaCore
            """
        for family in Self.permittedFilesByFamily.keys.sorted() {
            XCTAssertTrue(
                Self.familyIdentifiers(inSource: source, family: family).isEmpty,
                "comments must be stripped before the \(family) scan")
        }
    }
}