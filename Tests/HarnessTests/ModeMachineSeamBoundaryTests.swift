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

/// Raised when the scan cannot be evaluated meaningfully, so that measuring nothing is a failure
/// rather than a pass (the `KokoroSeamTestError` shape).
private enum ModeMachineSeamTestError: Error, CustomStringConvertible {
    case moduleDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .moduleDirectoryMissing(let expectedAt):
            return """
                The VoccaCore module directory does not exist at \(expectedAt). The mode-family \
                confinement is asserted by scanning the source tree; if the module has moved or \
                been renamed, this lint enforces nothing.
                """
        case .noSwiftFilesScanned(let under):
            return """
                No .swift files were found under \(under) — the confinement was not evaluated \
                against anything. That is the vacuous green this check exists to prevent, so it \
                is a failure.
                """
        }
    }
}

/// The mode-machine family lint and the `TextInjector`-prohibition scan (`mode-machine` Phase 3):
/// the `KokoroSeamBoundaryTests` shape exactly.
///
/// ## The mode family
///
/// Within `VoccaCore`, the four names of the mode machine's surface live only in the files
/// below — a second implementer, or a decision, cannot appear where CI cannot see it. The
/// permitted maps are per-family:
///
/// - `SessionModeMachine` → `Mode/SessionModeMachine.swift` only — the machine is the one file
///   that may name itself;
/// - `ModeSession` → the record, the machine (mints and carries it), and the effect (hands it
///   out inside `.stopped`);
/// - `SessionModeIntent` → the input enum and the machine's funnel;
/// - `SessionModeEffect` → the effect enum and the machine's funnel.
///
/// A constructor row pins **minting**: files containing `ModeSession(` (the constructor) are
/// `{Mode/SessionModeMachine.swift}` exactly — "minted only at a start" as a scan, the
/// `SessionOutcome.make`-one-place discipline's sibling (`CoreBoundaryTests.swift:635-678`).
///
/// ## The prohibition row
///
/// Code-level `TextInjector` sightings within `VoccaCore` are confined to
/// `{TextInjector.swift, DictationPipeline.swift}` exactly — today's verified set; the converse
/// path names it nowhere. A planted converse-path file naming the injector fails this row —
/// this is the roadmap acceptance test's CI leg (`CAPABILITY_ROADMAP.md:319`), and the
/// **`converse-wiring` aspect must amend this row** (or add a `VoccaBootstrap` leg) when its
/// converse files land — the recorded amendment obligation (`plan_20260915.md:249-252` shape).
/// The type-level half is D3/D6: the machine's surface carries no injector, so a converse
/// driver has nothing to reach.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name the family to explain what
/// is confined. It is not string-literal aware (see ``SwiftSourceScanner``). Both are deliberate
/// trade-offs of a text scan; what matters is that a *type in code* cannot appear without a
/// reviewed edit to the permitted lists below.
///
/// The `widget-converse` aspect must not touch this lint: its projections live in `VoccaUI`,
/// governed by its own boundary suites.
final class ModeMachineSeamBoundaryTests: XCTestCase {

    /// The module the machine lives in — the scan root.
    private static let seamModuleRoot = "VoccaCore"

    /// The four families of the mode machine's surface, each with the files permitted to name
    /// it (relative to ``seamModuleRoot``). **Each list is deliberate; nothing joins it without
    /// a reviewed edit.**
    private static let modeFamilies: [(name: String, permitted: Set<String>)] = [
        (
            "SessionModeMachine",
            ["Mode/SessionModeMachine.swift"]
        ),
        (
            "ModeSession",
            [
                "Mode/ModeSession.swift", "Mode/SessionModeMachine.swift",
                "Mode/SessionModeEffect.swift",
            ]
        ),
        (
            "SessionModeIntent",
            ["Mode/SessionModeIntent.swift", "Mode/SessionModeMachine.swift"]
        ),
        (
            "SessionModeEffect",
            ["Mode/SessionModeEffect.swift", "Mode/SessionModeMachine.swift"]
        ),
    ]

    /// The files permitted to name `TextInjector` in code — the dictation path's two files, and
    /// nothing else, **until the `converse-wiring` aspect amends this row** for its own files.
    private static let filesPermittedToNameTheInjector: Set<String> = [
        "TextInjector.swift", "DictationPipeline.swift"
    ]

    private func sourcesRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath).appendingPathComponent("Sources")
    }

    /// Every occurrence of a family identifier in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsAPlantedModeMachineUse``.
    private static func familyIdentifiers(inSource source: String, family: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b" + family + "[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    /// Every `TextInjector` occurrence in `source`, comments removed first.
    private static func injectorIdentifiers(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        guard let regex = try? NSRegularExpression(pattern: "\\bTextInjector\\b") else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    /// How many times `ModeSession(` — the constructor — appears in `source`, comments removed
    /// first. The minting row counts constructor calls, not mentions.
    private static func modeSessionConstructorCount(inSource source: String) -> Int {
        let code = SwiftSourceScanner.stripComments(from: source)
        return code.components(separatedBy: "ModeSession(").count - 1
    }

    /// Every sighting of `family` under `root`, honouring `permitted`.
    private func sightings(of family: String, under root: URL) throws -> [String: [String]] {
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw ModeMachineSeamTestError.noSwiftFilesScanned(under: root.path)
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

    // MARK: - The mode family

    /// The whole of the confinement, per family: every sighting sits in the permitted files, and
    /// the permitted files are the only ones permitted.
    ///
    /// Two independent claims per family, because either one failing alone still passes a
    /// one-sided check: "no other file names the family" passes if the permitted files *also*
    /// lost their implementation (the family used everywhere else — vacuous), and "the permitted
    /// files name the family" passes if three files do (the seam has sprung a leak). The
    /// non-vacuous guards are the `KokoroSeamBoundaryTests` ones verbatim: the permitted set is
    /// never empty, each permitted file must actually name its family, and the sighting count
    /// equals the permitted count.
    func testTheModeFamilyLivesOnlyInItsPermittedFiles() throws {
        let root = try sourcesRoot().appendingPathComponent(Self.seamModuleRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ModeMachineSeamTestError.moduleDirectoryMissing(expectedAt: root.path)
        }

        for (name, permitted) in Self.modeFamilies {
            let sightings = try sightings(of: name, under: root)

            let offenders = sightings.keys.filter { !permitted.contains($0) }
            XCTAssertTrue(
                offenders.isEmpty,
                "family \(name) is named outside its permitted files: \(offenders.sorted())")

            XCTAssertFalse(
                permitted.isEmpty,
                "the permitted list for \(name) must not be empty — an empty list passes "
                    + "'no file names it' vacuously")
            for file in permitted {
                XCTAssertFalse(
                    sightings[file]?.isEmpty ?? true,
                    "the permitted file \(file) must actually name the family \(name) — a "
                        + "permitted file that does not means the family moved somewhere else "
                        + "and the lint cannot see it")
            }
            XCTAssertEqual(
                sightings.count, permitted.count,
                "exactly the permitted set may name \(name), got \(sightings.keys.sorted())")
        }
    }

    /// **`ModeSession` is minted only at a start**: `ModeSession(` — the constructor — appears
    /// in exactly one file, the machine's. A second construction site is a second mint, which
    /// is how carryover gets a second subject (the `SessionOutcome.make`-one-place discipline's
    /// sibling).
    func testModeSessionIsMintedOnlyAtAStart() throws {
        let root = try sourcesRoot().appendingPathComponent(Self.seamModuleRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ModeMachineSeamTestError.moduleDirectoryMissing(expectedAt: root.path)
        }
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw ModeMachineSeamTestError.noSwiftFilesScanned(under: root.path)
        }

        var mintSites: [String: Int] = [:]
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let code = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            let count = Self.modeSessionConstructorCount(inSource: code)
            if count > 0 {
                mintSites[relative] = count
            }
        }
        XCTAssertEqual(
            mintSites, ["Mode/SessionModeMachine.swift": 1],
            """
            A ModeSession is constructed somewhere other than the machine's mint. The record is \
            the reset carrier — minted at every .start and replaced, so carryover is \
            unrepresentable; a second construction site is how the reset stops being total.
            """)
    }

    // MARK: - The prohibition row

    /// **Code-level `TextInjector` sightings in `VoccaCore` are confined to the dictation
    /// path's two files** — the roadmap acceptance's CI leg (`CAPABILITY_ROADMAP.md:319`): in
    /// converse mode no `TextInjector` call is ever made, because nothing on the converse
    /// surface names it. The `converse-wiring` aspect **must amend this row** when its converse
    /// files land (the recorded amendment obligation).
    ///
    /// Comments are stripped first, so the six doc-comment sightings (the seam's own docs,
    /// `CleanupProvider`, `InjectionResult`, `OnboardingTranscriptSink`, `InjectionStrategyStore`)
    /// do not count — but a doc comment may explain the prohibition.
    func testTextInjectorIsNamedOnlyInTheDictationPathFiles() throws {
        let root = try sourcesRoot().appendingPathComponent(Self.seamModuleRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ModeMachineSeamTestError.moduleDirectoryMissing(expectedAt: root.path)
        }
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw ModeMachineSeamTestError.noSwiftFilesScanned(under: root.path)
        }

        var sightings: [String: [String]] = [:]
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let code = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            let identifiers = Self.injectorIdentifiers(inSource: code)
            if !identifiers.isEmpty {
                sightings[relative] = identifiers
            }
        }

        XCTAssertFalse(
            Self.filesPermittedToNameTheInjector.isEmpty,
            "the permitted set must not be empty — an empty list passes 'no file names it' vacuously")
        for file in Self.filesPermittedToNameTheInjector {
            XCTAssertFalse(
                sightings[file]?.isEmpty ?? true,
                "the permitted file \(file) must actually name the injector — a permitted file "
                    + "that does not means the injector moved somewhere else and the lint cannot see it")
        }
        XCTAssertEqual(
            Set(sightings.keys), Self.filesPermittedToNameTheInjector,
            """
            The injector is named in code outside the dictation path: \
            \(sightings.keys.sorted()). In converse mode no TextInjector call is ever made \
            (CAPABILITY_ROADMAP.md:319) — a converse-path file that names it is a conversation \
            reaching for the injection ladder. If the naming file is a deliberate dictate-path \
            change, amend the permitted set in review; the converse-wiring aspect owns the \
            amendment when its files land.
            """)
    }

    // MARK: - Controls

    /// The lint's negative control for the families: planted source is caught — every family
    /// member, in the shapes a leaked implementer would actually use them.
    func testTheLintDetectsAPlantedModeMachineUse() {
        let source = """
            import VoccaCore

            public struct Leak {
                public let machine: SessionModeMachine<AudioBuffer>
                public var intent: SessionModeIntent? { nil }
                public var effect: SessionModeEffect<AudioBuffer>? { nil }
                public var record: ModeSession<AudioBuffer>? { nil }
            }
            """
        for (name, _) in Self.modeFamilies {
            let identifiers = Self.familyIdentifiers(inSource: source, family: name)
            XCTAssertEqual(
                identifiers, [name],
                "the detector must find every planted \(name) member")
        }
    }

    /// A planted second construction site is caught by the minting row.
    func testTheLintDetectsAPlantedModeSessionMint() {
        let source = """
            func forward(_ record: ModeSession<AudioBuffer>) {}

            let minted = ModeSession(mode: .dictation, epoch: 1)
            """
        XCTAssertEqual(
            Self.modeSessionConstructorCount(inSource: source), 1,
            "the minting detector cannot see a second ModeSession( site, so it permits one")
    }

    /// The prohibition's negative control: a converse-shaped file naming the injector is
    /// caught — the detector that proves the CI leg can see a violation.
    func testTheLintDetectsAPlantedInjectorInAConverseFile() {
        let source = """
            import VoccaCore

            public struct ConverseDriver {
                public let injector: any TextInjector
            }
            """
        let identifiers = Self.injectorIdentifiers(inSource: source)
        XCTAssertEqual(
            identifiers, ["TextInjector"],
            "the prohibition detector cannot see an injector it was shown, so it permits one")
    }

    /// A doc comment may name the family and the injector — the scanner strips comments, which
    /// is what lets the machine's documentation explain what it confines without tripping the
    /// lint.
    func testADocCommentNamingTheFamilyDoesNotTripTheLint() {
        let source = """
            /// The one place SessionModeMachine, SessionModeIntent, SessionModeEffect and
            /// ModeSession may all meet — the machine's funnel. The converse path never names
            /// TextInjector.
            import VoccaCore
            """
        for (name, _) in Self.modeFamilies {
            XCTAssertTrue(
                Self.familyIdentifiers(inSource: source, family: name).isEmpty,
                "comments must be stripped before the scan")
        }
        XCTAssertTrue(
            Self.injectorIdentifiers(inSource: source).isEmpty,
            "comments must be stripped before the scan")
    }
}