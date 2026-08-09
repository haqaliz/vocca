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
private enum InjectionSeamTestError: Error, CustomStringConvertible {
    case seamDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .seamDirectoryMissing(let expectedAt):
            return """
                A seam's permitted file directory does not exist at \(expectedAt). H7 is asserted \
                by scanning the source tree; if the seam's adapter has moved or been renamed, this \
                lint enforces nothing.
                """
        case .noSwiftFilesScanned(let under):
            return """
                No .swift files were found under \(under) — H7 was not evaluated against anything. \
                That is the vacuous green this check exists to prevent, so it is a failure.
                """
        }
    }
}

/// One place a CoreGraphics event type was named, located precisely enough to fix without
/// searching.
private struct EventTypeSighting: Equatable, CustomStringConvertible {
    let file: String
    let identifier: String

    var description: String { "\(file): \(identifier)" }
}

/// Acceptance H7, amended by the injection-adapters aspect: **no CoreGraphics event type escapes
/// a seam's one permitted implementation file.**
///
/// H7 began as a single-file rule over the whole tree: `CGEvent.tapCreate` returns `nil` without
/// an Accessibility grant and no hosted runner can be granted one, so anything phrased in terms of
/// `CGEvent` is untestable *forever* rather than untested for now. `HotkeyEventSource` yields plain
/// `RawKeyEvent` values and the flag translation takes a `UInt64`, and that is what puts every
/// branch worth testing on the reachable side.
///
/// The injection ladder's keystroke rung needed a second `CGEvent`-naming file — `VoccaInject`'s
/// keystroke adapter — and the amendment is **per-seam, not per-file-anything-goes**: the tap seam
/// keeps its rule untouched, and the keystroke seam gains one permitted file of its own.
/// ``filesPermittedToNameEventTypesBySeam`` is the table. Every seam has exactly one entry, and
/// nothing else ever joins a seam's entry.
///
/// ## Where the rules live
///
/// This file is the table's home: the per-seam count test (``testEachSeamPermitsExactlyOneFile``,
/// the successor of `HotkeySeamBoundaryTests`' `testAtMostOneFileMayNameEventTypes`, replaced
/// rather than weakened), the tree-wide scan against the table's union, the two-sided pins, the
/// laundering-route rules and every positive control moved here with them. `HotkeySeamBoundaryTests`
/// keeps only the tap module's own vacuity guard, and the amended doctrine in its header.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name `CGEventFlags` to explain what
/// it is translating — which the translation's does, at length, and should. It is not string-literal
/// aware (see ``SwiftSourceScanner``), so an event type inside a literal would be missed. Both are
/// deliberate trade-offs of a text scan; what matters is that a *type in code* cannot appear
/// without a reviewed edit to the table below.
final class InjectionSeamBoundaryTests: XCTestCase {

    /// Files allowed to name a CoreGraphics event type, relative to `Sources/`, keyed by seam.
    ///
    /// **One file per seam, and nothing else ever joins a seam's entry.** A second file in a seam
    /// means the seam has sprung a leak and the decision that leaked with it is now somewhere CI
    /// cannot reach.
    ///
    /// The tap seam is the phase-4 rule, untouched by the amendment. The keystroke seam is the
    /// injection-adapters addition: `VoccaInject`'s keystroke adapter is the sole `CGEvent`-naming
    /// file in that module, exactly as the tap adapter is in `VoccaHotkey`'s.
    private static let filesPermittedToNameEventTypesBySeam: [String: Set<String>] = [
        "tap": ["VoccaHotkey/CGEventTapSource.swift"],
        "keystroke": ["VoccaInject/Keystroke/KeystrokeSource.swift"],
    ]

    /// The table flattened — every permitted file in every seam. The tree-wide scan is aimed at
    /// this set.
    private static var filesPermittedToNameEventTypes: Set<String> {
        Set(filesPermittedToNameEventTypesBySeam.values.flatMap { $0 })
    }

    /// The identifier prefixes that constitute the seam. `CGEvent` covers `CGEventFlags`,
    /// `CGEventTap`, `CGEventTapProxy`, `CGEventType`, `CGEventSource` and every other member of
    /// the family by construction, which is why this is a prefix rule and not a list of names
    /// somebody has to keep current.
    ///
    /// `CGKeyCode` and `CFRunLoop` are beyond the three types `spec.md` names, and are here because
    /// review found them to be the two that would carry the seam anyway. `CGKeyCode` is only a
    /// `UInt16` typealias, so it looks harmless — but a signature phrased in it is a signature that
    /// needs CoreGraphics to read, which is the whole of what H7 is about. `CFRunLoopSource` is how
    /// a tap is attached, and a tap handle that escapes as a run-loop source has escaped just as
    /// completely as one that escapes as a `CFMachPort`.
    private static let forbiddenIdentifierPrefixes = [
        "CGEvent", "CFMachPort", "CGKeyCode", "CFRunLoop",
    ]

    /// Every occurrence of a forbidden identifier in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsAPlantedEventType``.
    private static func eventTypeIdentifiers(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b(" + forbiddenIdentifierPrefixes.joined(separator: "|") + ")[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    private func sourcesRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath).appendingPathComponent("Sources")
    }

    /// Every sighting under `root`, honouring `permitted`.
    ///
    /// Factored out of the real-tree test so that the **same code** can be run against a planted
    /// tree. A lint whose positive control exercises a re-implementation of itself proves only that
    /// the re-implementation works; this way the control walks the directory exactly as the real
    /// check does, which is where the subdirectory question lives.
    /// Symlinks are resolved on **both** sides before the prefix is removed, and that is not
    /// defensive padding: a root reached through a symlink — every macOS temporary directory is one,
    /// and a repository checked out under one behaves the same — yields absolute paths that do not
    /// begin with the root's own, so the subtraction produces a mangled relative path. The permitted
    /// list is keyed on that path, so the failure is a lint that names files nobody can find and
    /// silently stops matching its own allow-list.
    private static func sightings(
        under root: URL, permitting permitted: Set<String>
    ) throws -> [EventTypeSighting] {
        let rootPath = root.resolvingSymlinksInPath().path
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw InjectionSeamTestError.noSwiftFilesScanned(under: root.path)
        }

        var sightings: [EventTypeSighting] = []
        for file in files {
            let relativePath = file.resolvingSymlinksInPath().path
                .replacingOccurrences(of: rootPath + "/", with: "")
            guard !permitted.contains(relativePath) else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for identifier in eventTypeIdentifiers(inSource: source) {
                sightings.append(EventTypeSighting(file: relativePath, identifier: identifier))
            }
        }
        return sightings
    }

    // MARK: - H7 against the real tree

    /// The tree-wide scan, aimed at the table: no CoreGraphics event type is named outside the
    /// seams' one permitted file each.
    ///
    /// Every seam in the table must still have its directory, or the scan is measuring a tree the
    /// table no longer describes — the same guard the original lint kept on the tap adapter's
    /// module, held per seam.
    func testNoCoreGraphicsEventTypeEscapesTheSeamTable() throws {
        let root = try sourcesRoot()
        for seam in Self.filesPermittedToNameEventTypesBySeam.keys.sorted() {
            guard let files = Self.filesPermittedToNameEventTypesBySeam[seam] else { continue }
            for relativePath in files {
                let directory = root.appendingPathComponent(relativePath)
                    .deletingLastPathComponent()
                guard FileManager.default.fileExists(atPath: directory.path) else {
                    throw InjectionSeamTestError.seamDirectoryMissing(expectedAt: directory.path)
                }
            }
        }

        let sightings = try Self.sightings(
            under: root, permitting: Self.filesPermittedToNameEventTypes)

        XCTAssertEqual(
            sightings, [],
            """
            H7: a CoreGraphics event type is named outside its seam's permitted file. Found: \
            \(sightings.map(\.description).joined(separator: "; ")). Everything phrased in terms of \
            these types is unreachable from CI forever — tapCreate returns nil without an \
            Accessibility grant and TCC cannot be granted on a hosted runner. Move the logic above \
            the seam, or, if this genuinely is a seam's adapter, add its path to its seam's entry in \
            filesPermittedToNameEventTypesBySeam as a reviewed edit.
            """)
    }

    /// The "one file per seam" claim, enforced rather than asserted in a comment.
    ///
    /// The successor of `HotkeySeamBoundaryTests`' `testAtMostOneFileMayNameEventTypes`, replaced
    /// rather than weakened: the old test counted one file tree-wide, which a second seam would
    /// have to break by opening its own file. The per-seam count is the amended rule — every seam
    /// has exactly one file, and a seam entry with a second file fails here.
    func testEachSeamPermitsExactlyOneFile() {
        XCTAssertFalse(
            Self.filesPermittedToNameEventTypesBySeam.isEmpty,
            """
            The seam table must not be empty — an empty table passes "no file names the family" \
            vacuously, and a seam with no file is a seam whose adapter has moved without the \
            amendment noticing.
            """)
        for seam in Self.filesPermittedToNameEventTypesBySeam.keys.sorted() {
            XCTAssertEqual(
                Self.filesPermittedToNameEventTypesBySeam[seam]?.count, 1,
                """
                H7 permits one file per seam. The \(seam) seam permits \
                \(Self.filesPermittedToNameEventTypesBySeam[seam]?.sorted().joined(separator: ", ") ?? "none"). \
                A second entry means a decision has moved below the seam, where no CI run can reach it.
                """)
        }
    }

    /// **Every permitted file actually names its family** — the two-sided pin, in the H8
    /// `DefaultModelTransport` shape (`ModelDownloaderSeamTests.testExactlyOneFileInSourcesMayNameURLSession`).
    ///
    /// Two independent claims, because either one failing alone still passes a one-sided check:
    /// "no other file names the family" passes if a permitted file *also* lost its implementation
    /// (the family used everywhere else — vacuous), and "a permitted file names the family" passes
    /// if several do (the seam has sprung a leak). The tap file's side has held since phase 4; the
    /// keystroke side is what makes the amendment load-bearing — a keystroke adapter that stopped
    /// naming `CGEvent` means the keystroke half moved somewhere this lint cannot see.
    func testEachPermittedFileActuallyNamesItsFamily() throws {
        let root = try sourcesRoot()
        let permitted = Self.filesPermittedToNameEventTypes
        XCTAssertFalse(
            permitted.isEmpty,
            "the permitted set must not be empty — an empty set passes 'no file names it' vacuously")

        for relativePath in permitted.sorted() {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            XCTAssertFalse(
                Self.eventTypeIdentifiers(inSource: source).isEmpty,
                """
                \(relativePath) is permitted to name CoreGraphics event types, but names none. A \
                permitted file that does not name its family means the family moved somewhere else \
                and the lint cannot see it.
                """)
        }

        // The exact-set claim needs the whole tree including the permitted files — which is what
        // `permitting: []` is for: the scan's skip list is empty, so nothing is excluded and the
        // set of sighting-bearing files must be exactly the table's union.
        let allSightings = try Self.sightings(under: root, permitting: [])
        XCTAssertEqual(
            Set(allSightings.map(\.file)), permitted,
            """
            exactly the permitted set may name the family: \
            \(permitted.sorted().joined(separator: ", ")), got \
            \(Set(allSightings.map(\.file)).sorted().joined(separator: ", ")). A file outside the \
            table with a sighting is a leak; a permitted file without one is a vacuous pin.
            """)
    }

    // MARK: - Laundering routes, re-aimed at the table

    /// Every `typealias` declared in any file that is permitted to name event types.
    ///
    /// The reason this is a rule at all: the lint matches identifier *text*, so once a seam's
    /// adapter file is on the permitted list, `public typealias TapHandle = CFMachPort` declared
    /// **there** and used anywhere else in `Sources/` is invisible to it. Review verified that —
    /// `eventTypeIdentifiers(inSource: "func arm(_ h: TapHandle) -> RawKeyEvent? { nil }")` returns
    /// nothing. The permitted file is the one place a rename like that would be both legal and
    /// useless to detect afterwards, so the permission to name the types comes with a prohibition on
    /// re-exporting them under another name.
    ///
    /// No permitted file declares an alias today, so the real-tree run is a clean pass rather than a
    /// demonstration — which is why it has a positive control below as well.
    private static func typealiasNames(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        guard
            let regex = try? NSRegularExpression(
                pattern: "\\btypealias\\s+([A-Za-z_][A-Za-z0-9_]*)")
        else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range(at: 1), in: code).map { String(code[$0]) }
        }
    }

    func testAPermittedFileMayNotReExportAnEventTypeUnderAnotherName() throws {
        let root = try sourcesRoot()
        for relativePath in Self.filesPermittedToNameEventTypes.sorted() {
            let file = root.appendingPathComponent(relativePath)
            let aliases = Self.typealiasNames(
                inSource: try String(contentsOf: file, encoding: .utf8))
            XCTAssertEqual(
                aliases, [],
                """
                \(relativePath) is permitted to name CoreGraphics event types, so a typealias \
                declared there launders one past this lint everywhere else in Sources/. Found: \
                \(aliases.joined(separator: ", ")). Express the seam in VoccaCore types instead.
                """)
        }
    }

    /// Every re-export of something that is not ours.
    ///
    /// **This is a rule and not a list of frameworks, and the difference was earned twice.**
    ///
    /// The first version of this check held five names that say what they are — CoreGraphics,
    /// CoreFoundation, ApplicationServices, Carbon, IOKit. Review broke it: `@_exported import
    /// AppKit` planted in the real tree left the suite green at 182/0, because AppKit re-exports
    /// CoreGraphics and is the import a macOS app is overwhelmingly more likely to write. The
    /// proposed fix was five more names. Probing the SDK before adopting them showed the list
    /// approach is worse than it looks in *both* directions — measured with
    /// `swiftc -swift-version 6 -target arm64-apple-macos15 -typecheck` over `import <F>` plus each
    /// forbidden type, 2026-08-05:
    ///
    /// | Re-exporting this | brings in |
    /// |---|---|
    /// | CoreGraphics, ApplicationServices, Carbon, AppKit, Cocoa, Quartz, QuartzCore, **SwiftUI** | the whole family — `CGEventFlags`, `CGKeyCode`, `CFMachPort`, `CFRunLoopSource` |
    /// | CoreFoundation, **Foundation**, IOKit, CoreServices | the tap-handle half — `CFMachPort`, `CFRunLoopSource`, but no `CGEvent*` |
    /// | Combine, Darwin | nothing |
    ///
    /// So the proposed list would have added `CoreServices`, which carries no `CGEvent` type at all,
    /// while still missing **SwiftUI** — the one import `VoccaUI` certainly will have — and
    /// **Foundation**, which carries `CFMachPort`, the tap handle itself. A list of frameworks is an
    /// exclusion list that needs maintaining, and it had already gone stale twice before anyone
    /// wrote a second module.
    ///
    /// The general rule costs nothing, because **it fires only on `@_exported`**. Every module here
    /// may `import AppKit`, `import SwiftUI` and `import Foundation` as freely as it likes; what it
    /// may not do is hand them on to its own importers. Nothing in `Sources/` re-exports anything
    /// today, and there is no reason it ever should.
    ///
    /// Separated into a named function rather than inlined for a second measured reason: the
    /// real-tree check walks a clean tree, so a predicate answering "never a violation" left it
    /// passing. That mutation survived until this and ``coreGraphicsTypesExtended(inSource:)`` were
    /// pulled out to where a positive control can run them against source that violates the rule.
    private static func forbiddenReExports(inSource source: String) -> [String] {
        reExportedModules(inSource: source).filter { !isVoccaModule($0) }
    }

    /// A **re-exported** import makes the imported module's whole API visible to everything that
    /// imports the re-exporting module — with no import line in any of those files for a lint to
    /// see.
    ///
    /// `SwiftSourceScanner` already surfaces this (``SwiftSourceScanner/ImportStatement/isReExported``)
    /// because `CoreBoundaryTests` needed it; H7 needs it for a different reason. The identifier scan
    /// is blind to it in the direction that matters here: `@_exported import CoreGraphics` contains no
    /// forbidden identifier at all, because the *module* is not called `CGEvent`.
    private static func reExportedModules(inSource source: String) -> [String] {
        SwiftSourceScanner.importStatements(inSource: source).filter(\.isReExported).map(\.module)
    }

    /// Whether a module is one of this package's own.
    ///
    /// The only re-exports permitted anywhere in `Sources/`. Re-exporting a *Vocca* module is a
    /// module-boundary question — `CoreBoundaryTests` and `ModuleBoundaryTests` already own it, and
    /// `SwiftSourceScanner` surfaces `isReExported` for exactly that reason — and it cannot carry a
    /// CoreGraphics type in, because no Vocca module may name one.
    private static func isVoccaModule(_ module: String) -> Bool {
        module.hasPrefix("Vocca") || module.hasPrefix("CVocca")
    }

    func testNoFileInSourcesReExportsAModuleThatIsNotOurs() throws {
        let root = try sourcesRoot()
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw InjectionSeamTestError.noSwiftFilesScanned(under: root.path)
        }

        var offenders: [String] = []
        for file in files {
            let relativePath = file.path.replacingOccurrences(of: root.path + "/", with: "")
            for module in Self.forbiddenReExports(
                inSource: try String(contentsOf: file, encoding: .utf8))
            {
                offenders.append("\(relativePath): @_exported import \(module)")
            }
        }

        XCTAssertEqual(
            offenders, [],
            """
            A file re-exports a module that is not ours: \(offenders.joined(separator: "; ")). \
            Every module that imports this one now has that framework's types in scope without an \
            import line of its own — and for AppKit, Cocoa, Quartz, QuartzCore, SwiftUI, Carbon and \
            ApplicationServices those types include the whole CGEvent family, while Foundation and \
            CoreFoundation carry CFMachPort. That is a hole the identifier scan structurally cannot \
            see, because the line that opens it contains no forbidden identifier. Import it \
            normally instead: a plain `import` is unaffected by this rule.
            """)
    }

    /// The permitted files are held to the stricter form: they may re-export **nothing at all**.
    ///
    /// Each is one of the files that legitimately speaks CoreGraphics, so each is a file where a
    /// re-export would look natural and would be maximally damaging. Vacuous today, and paired with
    /// a positive control for exactly that reason.
    func testAPermittedFileMayNotReExportAnythingAtAll() throws {
        let root = try sourcesRoot()
        for relativePath in Self.filesPermittedToNameEventTypes.sorted() {
            let file = root.appendingPathComponent(relativePath)
            let reExports = Self.reExportedModules(
                inSource: try String(contentsOf: file, encoding: .utf8))
            XCTAssertEqual(
                reExports, [],
                """
                \(relativePath) is permitted to name CoreGraphics event types, and re-exports \
                \(reExports.joined(separator: ", )")). That hands the types it is trusted with to \
                every module that imports this one. Express the seam in VoccaCore types instead.
                """)
        }
    }

    /// Every type an `extension` extends, by name.
    ///
    /// The laundering route the `typealias` rule does not cover, and the one a reviewer reaches for
    /// next. In a permitted file, `extension CFMachPort: TapHandle {}` names the type legally — and
    /// from then on `any TapHandle` reaches it from anywhere in `Sources/` under a name the
    /// identifier scan has no reason to object to. It is the typealias hole wearing a protocol.
    private static func extendedTypeNames(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        guard
            let regex = try? NSRegularExpression(
                pattern: "\\bextension\\s+([A-Za-z_][A-Za-z0-9_.]*)")
        else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range(at: 1), in: code).map { String(code[$0]) }
        }
    }

    /// The violations, for the same reason ``forbiddenReExports(inSource:)`` is separated out: the
    /// files this is applied to declare no extension at all, so a predicate that never reports a
    /// violation passes the real-tree check — measured, as a surviving mutant, before it was pulled
    /// out here.
    private static func coreGraphicsTypesExtended(inSource source: String) -> [String] {
        extendedTypeNames(inSource: source).filter { name in
            forbiddenIdentifierPrefixes.contains { name.hasPrefix($0) }
        }
    }

    func testAPermittedFileMayNotExtendACoreGraphicsTypeUnderALocalProtocol() throws {
        let root = try sourcesRoot()
        for relativePath in Self.filesPermittedToNameEventTypes.sorted() {
            let file = root.appendingPathComponent(relativePath)
            let extended = Self.coreGraphicsTypesExtended(
                inSource: try String(contentsOf: file, encoding: .utf8))
            XCTAssertEqual(
                extended, [],
                """
                \(relativePath) extends \(extended.joined(separator: ", ")). A conformance declared \
                there gives the extended CoreGraphics type a second name — the protocol's — that \
                every other file in Sources/ may use without naming the type at all.
                """)
        }
    }

    // MARK: - Positive controls

    /// A rule that has only ever run against a tree satisfying it is a rule nobody has watched
    /// work. Each shape below is one somebody would plausibly write.
    func testTheLintDetectsAPlantedEventType() {
        XCTAssertEqual(
            Self.eventTypeIdentifiers(inSource: "func f(flags: CGEventFlags) {}"),
            ["CGEventFlags"],
            "A type in a signature is the leak that matters most — it escapes to every caller.")

        XCTAssertEqual(
            Self.eventTypeIdentifiers(inSource: "let tap: CFMachPort? = nil"),
            ["CFMachPort"],
            "The tap handle is as much a part of the seam as the event is.")

        XCTAssertEqual(
            Self.eventTypeIdentifiers(
                inSource: "func cb(_ proxy: CGEventTapProxy, _ type: CGEventType) {}"),
            ["CGEventTapProxy", "CGEventType"],
            "The prefix rule must cover the whole family without anyone listing its members.")

        XCTAssertEqual(
            Self.eventTypeIdentifiers(
                inSource: "func attach(_ src: CFRunLoopSource, _ code: CGKeyCode) {}"),
            ["CFRunLoopSource", "CGKeyCode"],
            """
            The two review found would carry the seam anyway. CGKeyCode is only a UInt16 typealias, \
            but a signature phrased in it still needs CoreGraphics to read.
            """)
    }

    /// The positive control for the `typealias` rule, which is otherwise vacuous until a permitted
    /// file declares one.
    ///
    /// The second assertion is the one that matters: it demonstrates the *hole* the rule closes —
    /// the aliased use site is invisible to the identifier scan, which is precisely why the alias
    /// has to be forbidden at its declaration instead.
    func testTheTypealiasRuleDetectsALaunderedEventType() {
        XCTAssertEqual(
            Self.typealiasNames(inSource: "public typealias TapHandle = CFMachPort"),
            ["TapHandle"],
            "An alias declared in a permitted file is what the rule is for.")

        XCTAssertEqual(
            Self.eventTypeIdentifiers(inSource: "func arm(_ h: TapHandle) -> RawKeyEvent? { nil }"),
            [],
            """
            And this is why: the aliased use site is invisible to the identifier scan. Without the \
            declaration-site rule, one typealias in a permitted file reopens H7 across the whole \
            of Sources/ with this suite green.
            """)

        XCTAssertEqual(
            Self.typealiasNames(inSource: "// typealias TapHandle = CFMachPort"),
            [],
            "A commented-out alias is not a declaration.")
    }

    /// **A nested alias, and the extension in another file that uses it.**
    ///
    /// The composite a reviewer constructs next: the alias is not at file scope, so a rule that
    /// looked for a top-level declaration would miss it, and the use site is an `extension` in a
    /// different file — which is where the type would have been named if it had been named at all.
    ///
    /// Three assertions, and the middle one is why the first is not optional: with the declaration
    /// undetected, both use sites scan clean and H7 is reopened across the whole tree with this
    /// suite green.
    func testTheTypealiasRuleSeesANestedDeclarationAndTheExtensionThatUsesIt() {
        XCTAssertEqual(
            Self.typealiasNames(
                inSource: """
                    public enum Seam {
                        public typealias Handle = CFMachPort
                    }
                    """),
            ["Handle"],
            "An alias nested inside a type launders just as completely as one at file scope.")

        XCTAssertEqual(
            Self.eventTypeIdentifiers(inSource: "extension Seam.Handle { func arm() {} }"),
            [],
            """
            The extension on the nested alias is invisible to the identifier scan — which is the \
            whole reason the alias has to be caught at its declaration instead.
            """)

        XCTAssertEqual(
            Self.eventTypeIdentifiers(inSource: "extension CFMachPort { func arm() {} }"),
            ["CFMachPort"],
            "...while an extension that names the type outright is still caught, in any file.")
    }

    /// The positive controls for the two rules added with the seam. Both would otherwise be clean
    /// passes rather than demonstrations: the permitted files re-export and extend nothing, and
    /// nothing in `Sources/` re-exports anything at all.
    func testTheReExportAndExtensionRulesDetectTheirOwnLaunderingRoutes() {
        XCTAssertEqual(
            Self.reExportedModules(inSource: "@_exported import CoreGraphics"),
            ["CoreGraphics"],
            "A re-exported framework is the hole the identifier scan structurally cannot see.")

        XCTAssertEqual(
            Self.eventTypeIdentifiers(inSource: "@_exported import CoreGraphics"),
            [],
            """
            ...and this is why it needs its own rule: the module is not called CGEvent, so the \
            identifier scan finds nothing to object to in the line that opens the hole.
            """)

        XCTAssertEqual(
            Self.reExportedModules(inSource: "import CoreGraphics"),
            [],
            "An ordinary import re-exports nothing and must not be reported as if it did.")

        XCTAssertEqual(
            Self.extendedTypeNames(inSource: "extension CFMachPort: TapHandle {}"),
            ["CFMachPort"],
            "A conformance declared on a CoreGraphics type is the typealias hole wearing a protocol.")

        XCTAssertEqual(
            Self.eventTypeIdentifiers(inSource: "func arm(_ handle: any TapHandle) {}"),
            [],
            "And the use site of that protocol is invisible, exactly as the aliased one is.")

        XCTAssertEqual(
            Self.extendedTypeNames(inSource: "extension SessionMachine {}"),
            ["SessionMachine"],
            """
            The extension scan must see ordinary extensions too, or the filter below would be \
            applied to an empty list and the rule would pass for any file.
            """)

        // And the two **predicates**, not only the scans they are built on. Both real-tree checks
        // iterate an empty permitted list or a clean tree, so a predicate that answered "never a
        // violation" left them passing — measured, as two surviving mutants, before these ran.
        XCTAssertEqual(
            Self.coreGraphicsTypesExtended(inSource: "extension CFMachPort: TapHandle {}"),
            ["CFMachPort"],
            "The extension rule's predicate reported no violation for an outright violation.")
        XCTAssertEqual(
            Self.coreGraphicsTypesExtended(inSource: "extension SessionMachine {}"),
            [],
            "...and it must not report one for an ordinary extension, or every file is an offender.")
        XCTAssertEqual(
            Self.forbiddenReExports(inSource: "@_exported import CoreGraphics"),
            ["CoreGraphics"],
            "The re-export rule's predicate reported no violation for an outright violation.")

        // The three review planted in the real tree and watched pass, plus the two the probe found
        // that its proposed fix would still have missed. Each is asserted by name rather than as a
        // count, because the defect was a *specific* framework being absent from a list — and a
        // count over a list is satisfied by any five names at all.
        for framework in ["AppKit", "Cocoa", "Quartz", "SwiftUI", "Foundation"] {
            XCTAssertEqual(
                Self.forbiddenReExports(inSource: "@_exported import \(framework)"),
                [framework],
                """
                `@_exported import \(framework)` was not reported. Measured against the SDK: it \
                brings CoreGraphics event types or CFMachPort into scope for every importer, with \
                no forbidden identifier on the line that does it.
                """)
        }

        XCTAssertEqual(
            Self.forbiddenReExports(inSource: "@_exported import VoccaCore"),
            [],
            """
            A re-export of a Vocca module is a module-boundary question that CoreBoundaryTests and \
            ModuleBoundaryTests already own, and it cannot carry a CoreGraphics type in, because no \
            Vocca module may name one.
            """)
        XCTAssertEqual(
            Self.forbiddenReExports(inSource: "import AppKit"),
            [],
            """
            A plain import must not be reported. This rule fires only on `@_exported`, and that is \
            what makes listing AppKit, SwiftUI and Foundation free: every module may import them.
            """)
    }

    /// **The scan reaches subdirectories**, proven by planting a violation in one and requiring the
    /// real scanning code to report it.
    ///
    /// `Sources/VoccaHotkey/` is flat today and `ARCHITECTURE.md` §3 lays every other module out with
    /// subdirectories, so a seam's adapter will very likely land in one — the keystroke adapter
    /// already does. If the walk stopped at the top level — a plausible edit, `contentsOfDirectory`
    /// for `enumerator` — every H7 test in this file would keep passing while enforcing nothing
    /// about the file that matters most.
    func testTheScanReachesAViolationPlantedInASubdirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-h7-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("VoccaHotkey/Tap/Deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "let tap: CFMachPort? = nil\n".write(
            to: nested.appendingPathComponent("Buried.swift"), atomically: true, encoding: .utf8)
        try "let flags: CGEventFlags = []\n".write(
            to: root.appendingPathComponent("VoccaHotkey/Shallow.swift"), atomically: true,
            encoding: .utf8)

        XCTAssertEqual(
            try Self.sightings(under: root, permitting: []).sorted(by: { $0.file < $1.file }),
            [
                EventTypeSighting(
                    file: "VoccaHotkey/Shallow.swift", identifier: "CGEventFlags"),
                EventTypeSighting(
                    file: "VoccaHotkey/Tap/Deep/Buried.swift", identifier: "CFMachPort"),
            ],
            "A CoreGraphics type buried in a subdirectory was not reported.")

        // And the permission is keyed to the full relative path, so permitting the shallow file
        // does not accidentally permit the deep one — or the reverse.
        XCTAssertEqual(
            try Self.sightings(under: root, permitting: ["VoccaHotkey/Shallow.swift"]),
            [
                EventTypeSighting(
                    file: "VoccaHotkey/Tap/Deep/Buried.swift", identifier: "CFMachPort")
            ],
            "Permitting one file permitted another, or failed to permit the one named.")
    }

    /// Comments are stripped before the scan, and that is load-bearing rather than incidental: the
    /// translation's documentation has to be able to name the type it translates from, or the
    /// reason the constants are transcribed by hand cannot be written down at all.
    func testTheLintIgnoresEventTypesNamedInComments() {
        XCTAssertEqual(
            Self.eventTypeIdentifiers(
                inSource: """
                    /// Transcribed from CGEventFlags, deliberately not imported.
                    // See CGEventTypes.h.
                    let controlBit: UInt64 = 0x0004_0000
                    """),
            [],
            "A doc comment naming the type must not trip the lint.")

        XCTAssertEqual(
            Self.eventTypeIdentifiers(
                inSource: """
                    /// Transcribed from CGEventFlags.
                    let flags: CGEventFlags = []
                    """),
            ["CGEventFlags"],
            """
            ...but stripping comments must not make the lint blind to real code beside them. \
            Without this, the previous assertion could be satisfied by a scan that gives up on any \
            file containing a comment.
            """)
    }
}
