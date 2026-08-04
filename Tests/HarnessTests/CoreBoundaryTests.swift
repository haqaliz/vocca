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

/// Raised when the `VoccaCore` scan cannot be evaluated meaningfully — the module directory is
/// gone, or it holds no Swift to read. Either way the lint measured nothing, and a lint that
/// silently measures nothing is worse than no lint: it reports a boundary that is not being held.
private enum CoreBoundaryTestError: Error, CustomStringConvertible {
    case moduleDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .moduleDirectoryMissing(let expectedAt):
            return """
                The VoccaCore module directory does not exist at \(expectedAt). The system-API \
                boundary is asserted by scanning that directory; if it has moved or been renamed, \
                this lint enforces nothing and every branch below the seam quietly becomes \
                untestable again.
                """
        case .noSwiftFilesScanned(let under):
            return """
                No .swift files were found under \(under) — the system-API boundary was not \
                evaluated against anything. This is the vacuous green this check exists to \
                prevent, so it is a failure, not a pass.
                """
        }
    }
}

/// One import `VoccaCore` is not allowed to have, located precisely enough to fix without
/// searching. `via` names the sibling module that re-exported it, when the import did not appear
/// in `VoccaCore`'s own text.
private struct DisallowedImport: Equatable, CustomStringConvertible {
    let file: String
    let module: String
    let via: String?

    var description: String {
        if let via {
            return "\(file): \(via) re-exports \(module)"
        }
        return "\(file): import \(module)"
    }
}

/// Enforces the invariant that makes this aspect testable at all: **`VoccaCore` reaches no system
/// API.**
///
/// The reason is not taste. `CGEvent.tapCreate` returns `nil` without an Accessibility grant and
/// there is no programmatic route to TCC, so no hosted runner can ever be granted one. There is no
/// microphone on a runner, and `AVAudioSinkNode` is unsupported in manual rendering mode, so the
/// realtime capture path has no offline equivalent either. Anything that ends up below that seam is
/// untestable *forever* — not "untested for now".
///
/// `VoccaCore` is where every branch worth testing lives: the start and stop rules, the session
/// state machine, the watchdog policy. Keeping the system frameworks out of it is what keeps that
/// logic reachable from `swift test` on a machine with no permissions, no microphone and no
/// network. A convention would decay silently; this is the assertion that stops it.
///
/// ## An allow-list, not a deny-list
///
/// The first version of this lint named nine forbidden frameworks. Two problems, both demonstrated
/// against a fully green suite:
///
/// 1. A deny-list only forbids what someone thought of. `Foundation`, `Dispatch` and `Darwin` were
///    all absent from it — and `spec.md` requires that no clock be reachable from this module,
///    because the ceiling and purity tests are meaningless if `Date()` or `mach_absolute_time()` is
///    one import away.
/// 2. It read `VoccaCore`'s own text only. `@_exported import AppKit` in `VoccaHotkey` (plausible:
///    it is the adapter, re-exporting the framework its API mentions) plus `import VoccaHotkey`
///    here put `CGEventFlags` and `NSApplication` inside `VoccaCore` with no forbidden import
///    anywhere in it, and the suite stayed green.
///
/// So the rule is inverted: `VoccaCore` may import what is on ``permittedImports`` and nothing
/// else. That list is **empty** — the module compiles today with zero imports, because `Duration`
/// and `OptionSet` are the standard library, which needs none — and an empty allow-list closes the
/// transitive route by construction, since the sibling import that would carry a re-export is
/// itself no longer permitted.
///
/// ``testNoModuleVoccaCoreImportsReExportsSomethingDisallowed`` enforces the transitive rule
/// anyway, for the day that list is not empty. It has a positive control, because a rule whose
/// precondition is currently false is a rule nobody has ever seen work.
final class CoreBoundaryTests: XCTestCase {

    /// What `VoccaCore` may import. **Empty**, deliberately.
    ///
    /// Extend only with a reviewed reason, and read the type's doc comment first: adding a *Vocca
    /// module* here reopens the re-export route, which is what the transitive rule is for.
    private static let permittedImports: Set<String> = []

    private func packageRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath)
    }

    private func sourcesRoot() throws -> URL {
        try packageRoot().appendingPathComponent("Sources")
    }

    private func voccaCoreRoot() throws -> URL {
        try sourcesRoot().appendingPathComponent("VoccaCore")
    }

    /// A path relative to `root` — `VoccaCore/Sub/Nested.swift`, not `Nested.swift`.
    ///
    /// The last path component alone became ambiguous the moment `VoccaCore` could grow a
    /// subdirectory: the scan recurses, and two files both called `Placeholder.swift` are
    /// indistinguishable in a failure message.
    private func displayPath(of file: URL, from root: URL) -> String {
        let filePath = file.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return file.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
    }

    /// Every import under `moduleRoot` that is not on `permitted`, with the file that carries it.
    ///
    /// Throws — rather than returning `[]` — when there is nothing to scan. The two failure modes
    /// of a source lint are "found a violation" and "was pointed at nothing"; only the first is
    /// allowed to look different from success.
    ///
    /// Parsing is delegated to ``SwiftSourceScanner``, which already handles the forms a lint in
    /// this repository was previously blind to: access-level modifiers (`public import`,
    /// `package import`, ...), any leading attribute (`@testable`, `@preconcurrency`,
    /// `@_implementationOnly`), kind-qualified imports (`import struct AVFoundation.AVAudioFormat`),
    /// submodule imports (`import CoreGraphics.CGEvent`) and `;`-separated statements. A second
    /// parser here would have repeated each of those misses.
    private func disallowedImports(
        under moduleRoot: URL, permitted: Set<String>, displayRoot: URL
    ) throws -> [DisallowedImport] {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: moduleRoot.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CoreBoundaryTestError.moduleDirectoryMissing(expectedAt: moduleRoot.path)
        }

        let files = SwiftSourceScanner.swiftFiles(under: moduleRoot)
        guard !files.isEmpty else {
            throw CoreBoundaryTestError.noSwiftFilesScanned(under: moduleRoot.path)
        }

        var violations: [DisallowedImport] = []
        for file in files {
            for statement in try SwiftSourceScanner.importStatements(in: file)
            where !permitted.contains(statement.module) {
                violations.append(
                    DisallowedImport(
                        file: displayPath(of: file, from: displayRoot), module: statement.module,
                        via: nil))
            }
        }
        return violations.sorted { $0.description < $1.description }
    }

    /// Everything re-exported by a module `moduleRoot` imports, that `permitted` does not cover.
    ///
    /// `@_exported import X` in module `M` makes `X`'s API visible to everyone importing `M`, so a
    /// lint that reads only the importing file cannot see it arrive. Imports that are not
    /// directories under `sourcesRoot` — the standard library, a system framework — are skipped:
    /// there is no source of ours to read.
    private func disallowedReExports(
        reachableFrom moduleRoot: URL, permitted: Set<String>, sourcesRoot: URL, displayRoot: URL
    ) throws -> [DisallowedImport] {
        let directImports = Set(
            try SwiftSourceScanner.swiftFiles(under: moduleRoot)
                .flatMap { try SwiftSourceScanner.importedModuleNames(in: $0) })

        var violations: [DisallowedImport] = []
        for imported in directImports.sorted() {
            let siblingRoot = sourcesRoot.appendingPathComponent(imported)
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(atPath: siblingRoot.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }

            for file in SwiftSourceScanner.swiftFiles(under: siblingRoot) {
                for statement in try SwiftSourceScanner.importStatements(in: file)
                where statement.isReExported && !permitted.contains(statement.module) {
                    violations.append(
                        DisallowedImport(
                            file: displayPath(of: file, from: displayRoot),
                            module: statement.module, via: imported))
                }
            }
        }
        return violations.sorted { $0.description < $1.description }
    }

    private func makeScratchDirectory(named prefix: String) throws -> URL {
        let url = URL(
            fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
        ).appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The invariant

    func testVoccaCoreImportsOnlyWhatIsExplicitlyPermitted() throws {
        let violations = try disallowedImports(
            under: voccaCoreRoot(), permitted: Self.permittedImports,
            displayRoot: try sourcesRoot())
        XCTAssertEqual(
            violations, [],
            """
            VoccaCore may import only \(Self.permittedImports.isEmpty
                ? "the Swift standard library — the allow-list is empty"
                : Self.permittedImports.sorted().joined(separator: ", ")). Found: \
            \(violations.map(\.description).joined(separator: "; ")).

            VoccaCore is the one module in this aspect a CI runner can execute in full: no \
            Accessibility grant, no microphone, no network. Anything imported here can put logic \
            below the system-API seam, where it is untestable forever rather than merely untested \
            — and Foundation, Dispatch and Darwin are on the wrong side of that line too, because \
            spec.md requires no clock be reachable from this module. Express the type in Vocca's \
            own vocabulary here and translate at the seam, in VoccaHotkey or VoccaAudio.

            If an import genuinely belongs, add it to permittedImports with a reason, and read \
            that property's doc comment first.
            """)
    }

    /// The transitive half: a permitted module must not smuggle a framework in by re-exporting it.
    ///
    /// Walks nothing today, by design — the allow-list is empty, so `VoccaCore` imports nothing.
    /// That is exactly why it has a positive control below rather than standing on its own.
    func testNoModuleVoccaCoreImportsReExportsSomethingDisallowed() throws {
        let violations = try disallowedReExports(
            reachableFrom: voccaCoreRoot(), permitted: Self.permittedImports,
            sourcesRoot: try sourcesRoot(), displayRoot: try sourcesRoot())
        XCTAssertEqual(
            violations, [],
            """
            A module VoccaCore imports re-exports something the allow-list does not permit: \
            \(violations.map(\.description).joined(separator: "; ")).

            `@_exported import X` makes X's API visible to everything that imports that module, so \
            the framework arrives inside VoccaCore without appearing in any of its files. Either \
            drop the re-export, or stop importing that module from VoccaCore.
            """)
    }

    // MARK: - Positive controls
    //
    // Three of them, and each shares the exact mechanism of the assertion it backs. A test that
    // only ever asserts "we found nothing" cannot tell "nothing is there" from "I am not looking",
    // which is how six checks in this repository came to pass while measuring nothing.

    /// Proves the lint can see an import in every disguise, by writing each disguise to a scratch
    /// tree and requiring all of them back. If this fails, the assertion above is decorative.
    func testTheLintDetectsEveryDisguisedImportForm() throws {
        let scratch = try makeScratchDirectory(named: "vocca-core-boundary")
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Every line here is a real Swift import form. The last two must *not* be reported: both
        // are commented out. `Foundation`, `Dispatch` and `Darwin` **are** reported, which is the
        // point of the inversion — a deny-list of system frameworks let all three through, and any
        // one of them hands task 4 a clock.
        //
        // `@_implementationOnly` is in the fixture because it is the form that actually got
        // through: the parser inherited from ModuleBoundaryTests matched attributes against an
        // allow-list holding only `@testable`, so the line was not recognised as an import at all
        // and VoccaCore was reported clean while importing CoreGraphics.
        let source = """
            import AppKit
            public import Cocoa
            internal import CoreGraphics
            package import AVFoundation
            private import AVFAudio
            fileprivate import Carbon
            @testable import ApplicationServices
            import struct SwiftUI.EnvironmentValues
            @_implementationOnly import IOKit.hid
            @_exported import Dispatch
            @preconcurrency import AppKit
                import AppKit
            import Darwin; import AppKit
            import Foundation
            // import Combine
            /* import Security */
            """
        try source.write(
            to: scratch.appendingPathComponent("Disguises.swift"), atomically: true,
            encoding: .utf8)

        let violations = try disallowedImports(under: scratch, permitted: [], displayRoot: scratch)
        let found = Set(violations.map(\.module))
        let expected: Set<String> = [
            "AppKit", "Cocoa", "CoreGraphics", "AVFoundation", "AVFAudio", "Carbon",
            "ApplicationServices", "SwiftUI", "IOKit", "Dispatch", "Darwin", "Foundation",
        ]
        XCTAssertEqual(
            found, expected,
            """
            The lint failed to see one or more imports it was shown. Missed: \
            \(expected.subtracting(found).sorted().joined(separator: ", ")). Spurious: \
            \(found.subtracting(expected).sorted().joined(separator: ", ")). Each form in the \
            fixture is one a source lint in this repository has been, or would have been, blind \
            to; an import the lint cannot see is an import the lint permits.
            """)

        // AppKit appears four times — plain, @preconcurrency, indented, and after a `;` — and is
        // commented out nowhere. Counting rather than testing membership proves the scan is
        // per-occurrence rather than a per-file `contains`, and that the two commented-out lines
        // contribute nothing.
        XCTAssertEqual(
            violations.filter { $0.module == "AppKit" }.count, 4,
            """
            Expected the plain, @preconcurrency, indented and semicolon-separated `import AppKit`, \
            and neither commented-out import.
            """)

        XCTAssertTrue(
            violations.allSatisfy { $0.file == "Disguises.swift" },
            "Unexpected file attribution: \(Set(violations.map(\.file)).sorted())")
    }

    /// Proves the transitive rule works, since the real assertion cannot exercise it while the
    /// allow-list is empty. Two fake modules in a scratch tree: a permitted sibling that
    /// re-exports AppKit, and a core that imports the sibling.
    func testTheLintDetectsAFrameworkArrivingThroughAReExport() throws {
        let scratch = try makeScratchDirectory(named: "vocca-core-reexport")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let core = scratch.appendingPathComponent("FakeCore", isDirectory: true)
        let adapter = scratch.appendingPathComponent("FakeAdapter", isDirectory: true)
        for directory in [core, adapter] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        try "import FakeAdapter\n".write(
            to: core.appendingPathComponent("Core.swift"), atomically: true, encoding: .utf8)
        try "@_exported import AppKit\nimport Foundation\n".write(
            to: adapter.appendingPathComponent("Adapter.swift"), atomically: true, encoding: .utf8)

        let permitted: Set<String> = ["FakeAdapter"]

        // The direct rule is satisfied — FakeCore imports only what it is allowed to. That is what
        // makes this route interesting: it is invisible to the assertion everyone would write.
        XCTAssertEqual(
            try disallowedImports(under: core, permitted: permitted, displayRoot: scratch), [],
            "The direct rule should be satisfied here, or this control is testing the wrong thing.")

        let violations = try disallowedReExports(
            reachableFrom: core, permitted: permitted, sourcesRoot: scratch, displayRoot: scratch)
        XCTAssertEqual(
            violations,
            [
                DisallowedImport(
                    file: "FakeAdapter/Adapter.swift", module: "AppKit", via: "FakeAdapter")
            ],
            """
            The transitive rule missed a re-export. This is the exact route that put CGEventFlags \
            and NSApplication inside VoccaCore with the whole suite green: @_exported import \
            AppKit in the adapter, plus an import of the adapter here.
            """)

        // The sibling's plain `import Foundation` is not a violation: it is not re-exported, so it
        // does not reach VoccaCore. Over-reporting would make the rule unusable and get it deleted.
        XCTAssertFalse(
            violations.contains { $0.module == "Foundation" },
            "A plain, non-re-exported import in a sibling module must not be reported.")
    }

    /// Proves the vacuity guard fires: pointed at a directory with no Swift in it, the scan throws
    /// rather than reporting a clean bill of health.
    func testTheLintFailsRatherThanPassingWhenThereIsNothingToScan() throws {
        let empty = try makeScratchDirectory(named: "vocca-core-empty")
        defer { try? FileManager.default.removeItem(at: empty) }

        XCTAssertThrowsError(
            try disallowedImports(under: empty, permitted: [], displayRoot: empty)
        ) { error in
            XCTAssertTrue(
                error is CoreBoundaryTestError,
                "Expected the scan to refuse an empty tree, got \(error)")
        }

        let missing = empty.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertThrowsError(
            try disallowedImports(under: missing, permitted: [], displayRoot: empty)
        ) { error in
            XCTAssertTrue(
                error is CoreBoundaryTestError,
                "Expected the scan to refuse a missing directory, got \(error)")
        }
    }

    // MARK: - The other half of the seam

    /// `@discardableResult` must not appear in `VoccaCore`.
    ///
    /// `decide(_:state:)` returns a ``Decision`` describing what the caller must do with the event.
    /// Swift warns when a non-`Void` result is dropped and CI fails on any warning, so a decision
    /// computed and thrown away does not reach `main` — see `Decision`'s own documentation for the
    /// precise, narrower claim. `@discardableResult` is the single annotation that turns that
    /// protection off, and no call in a module of pure decision functions needs it.
    ///
    /// This is a lint rather than a comment because the annotation is one line, reads as harmless,
    /// and the failure it enables — a decision computed and dropped, leaving the microphone open —
    /// is exactly the class of bug this aspect exists to prevent.
    func testVoccaCoreDeclaresNoDiscardableResults() throws {
        let moduleRoot = try voccaCoreRoot()
        let files = SwiftSourceScanner.swiftFiles(under: moduleRoot)
        guard !files.isEmpty else {
            throw CoreBoundaryTestError.noSwiftFilesScanned(under: moduleRoot.path)
        }

        var offenders: [String] = []
        for file in files {
            let source = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            if source.contains("@discardableResult") {
                offenders.append(displayPath(of: file, from: try sourcesRoot()))
            }
        }
        XCTAssertEqual(
            offenders, [],
            """
            @discardableResult found in VoccaCore: \(offenders.joined(separator: ", ")). Every \
            value this module returns is an instruction the caller has to carry out; the compiler \
            warning for an unused result is the only thing that makes dropping one visible, and \
            CI turns that warning into a failure. Do not switch it off here.
            """)
    }
}
