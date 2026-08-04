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

/// One forbidden import, located precisely enough to fix without searching.
private struct ForbiddenImport: Equatable, CustomStringConvertible {
    let file: String
    let module: String

    var description: String { "\(file): import \(module)" }
}

/// Enforces the invariant that makes this aspect testable at all: **`VoccaCore` contains no
/// system API.**
///
/// The reason is not taste. `CGEvent.tapCreate` returns `nil` without an Accessibility grant and
/// there is no programmatic route to TCC, so no hosted runner can ever be granted one. There is no
/// microphone on a runner, and `AVAudioSinkNode` is unsupported in manual rendering mode, so the
/// realtime capture path has no offline equivalent either. Anything that ends up below that seam
/// is untestable *forever* — not "untested for now".
///
/// `VoccaCore` is where every branch worth testing lives: the start and stop rules, the session
/// state machine, the watchdog policy. Keeping the system frameworks out of it is what keeps that
/// logic reachable from `swift test` on a machine with no permissions, no microphone and no
/// network. A convention would decay silently; this is the assertion that stops it.
///
/// Types that would otherwise pull a framework in are re-expressed in Vocca's own vocabulary —
/// `ModifierSet` rather than `CGEventFlags`, `RawKeyEvent` rather than `CGEvent`. The translation
/// happens in `VoccaHotkey`, at the seam, where it can be as untestable as it has to be.
final class CoreBoundaryTests: XCTestCase {

    /// The frameworks that would drag an untestable dependency into the pure module.
    ///
    /// `AppKit`/`Cocoa`/`SwiftUI` bring a run loop and a main-actor world; `CoreGraphics` and
    /// `ApplicationServices` bring the event tap; `AVFoundation`/`AVFAudio` bring the audio engine;
    /// `Carbon` brings the legacy hotkey registration; `IOKit` brings raw HID. Every one of them is
    /// legitimate somewhere in Vocca — none of them here.
    private static let forbiddenModules: Set<String> = [
        "AppKit", "Cocoa", "CoreGraphics", "AVFoundation", "AVFAudio", "Carbon",
        "ApplicationServices", "SwiftUI", "IOKit",
    ]

    private func voccaCoreRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaCore")
    }

    /// Every forbidden import under `root`, with the file that carries it.
    ///
    /// Throws — rather than returning `[]` — when there is nothing to scan. The two failure modes
    /// of a source lint are "found a violation" and "was pointed at nothing"; only the first is
    /// allowed to look different from success.
    ///
    /// Parsing is delegated to ``SwiftSourceScanner``, which already handles the forms a lint in
    /// this repository was previously blind to: access-level modifiers (`public import`,
    /// `package import`, ...), `@testable import`, kind-qualified imports
    /// (`import struct AVFoundation.AVAudioFormat`) and submodule imports
    /// (`import CoreGraphics.CGEvent`). Writing a second parser here would have meant repeating
    /// each of those misses.
    private func forbiddenImports(under root: URL) throws -> [ForbiddenImport] {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CoreBoundaryTestError.moduleDirectoryMissing(expectedAt: root.path)
        }

        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw CoreBoundaryTestError.noSwiftFilesScanned(under: root.path)
        }

        var violations: [ForbiddenImport] = []
        for file in files {
            for module in try SwiftSourceScanner.importedModuleNames(in: file)
            where Self.forbiddenModules.contains(module) {
                violations.append(
                    ForbiddenImport(file: file.lastPathComponent, module: module))
            }
        }
        return violations.sorted { $0.description < $1.description }
    }

    // MARK: - The invariant

    func testVoccaCoreImportsNoSystemFramework() throws {
        let violations = try forbiddenImports(under: voccaCoreRoot())
        XCTAssertEqual(
            violations, [],
            """
            VoccaCore must import no system framework, found: \
            \(violations.map(\.description).joined(separator: "; ")).

            VoccaCore is the one module in this aspect that a CI runner can execute in full: no \
            Accessibility grant, no microphone, no network. An import from \
            \(Self.forbiddenModules.sorted().joined(separator: ", ")) puts the logic behind it \
            below the system-API seam, where it is untestable forever rather than merely untested. \
            Express the system type in Vocca's own vocabulary here and translate at the seam in \
            VoccaHotkey / VoccaAudio instead.
            """)
    }

    // MARK: - Positive controls
    //
    // Two of them, and both share the exact mechanism the assertion above uses — the same
    // `forbiddenImports(under:)`. A test that only ever asserts "we found nothing" cannot tell
    // "nothing is there" from "I am not looking", which is how six checks in this repository came
    // to pass while measuring nothing.

    /// Proves the lint can see an import in every disguise, by writing each disguise to a scratch
    /// tree and requiring all of them back. If this fails, the assertion above is decorative.
    func testTheLintDetectsEveryDisguisedImportForm() throws {
        let scratch = URL(
            fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
        ).appendingPathComponent("vocca-core-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Every line here is a real Swift import form. The last three must *not* be reported:
        // two are commented out, and `Foundation` is not on the forbidden list.
        //
        // `@_implementationOnly` is in the fixture because it is the form that actually got
        // through: the parser inherited from ModuleBoundaryTests matched attributes against an
        // allow-list holding only `@testable`, so the line was not recognised as an import and
        // VoccaCore was reported clean while importing CoreGraphics. Found by breaching the real
        // tree during this task's positive control, not by reading the code.
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
            @preconcurrency import AppKit
                import AppKit
            import Foundation; import AppKit
            // import AppKit
            /* import Cocoa */
            """
        try source.write(
            to: scratch.appendingPathComponent("Disguises.swift"), atomically: true,
            encoding: .utf8)

        let found = Set(try forbiddenImports(under: scratch).map(\.module))
        XCTAssertEqual(
            found, Self.forbiddenModules,
            """
            The lint failed to see one or more forbidden imports it was shown. Missed: \
            \(Self.forbiddenModules.subtracting(found).sorted().joined(separator: ", ")). Each \
            form in the fixture is one a source lint in this repository has previously been blind \
            to; an import the lint cannot see is an import the lint permits.
            """)

        // AppKit is imported four times in the fixture — plain, `@preconcurrency`, indented, and
        // after a `;` — and commented out twice. Counting rather than testing membership is what
        // proves the scan is per-occurrence and not a per-file `contains`, and that the two
        // commented-out lines contribute nothing.
        let appKitCount = try forbiddenImports(under: scratch).filter { $0.module == "AppKit" }
            .count
        XCTAssertEqual(
            appKitCount, 4,
            """
            Expected the plain, @preconcurrency, indented and semicolon-separated `import AppKit` \
            — and neither commented-out import. Found \(appKitCount).
            """)
    }

    /// Proves the vacuity guard fires: pointed at a directory with no Swift in it, the scan throws
    /// rather than reporting a clean bill of health.
    func testTheLintFailsRatherThanPassingWhenThereIsNothingToScan() throws {
        let empty = URL(
            fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
        ).appendingPathComponent("vocca-core-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        XCTAssertThrowsError(try forbiddenImports(under: empty)) { error in
            XCTAssertTrue(
                error is CoreBoundaryTestError,
                "Expected the scan to refuse an empty tree, got \(error)")
        }

        let missing = empty.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertThrowsError(try forbiddenImports(under: missing)) { error in
            XCTAssertTrue(
                error is CoreBoundaryTestError,
                "Expected the scan to refuse a missing directory, got \(error)")
        }
    }

    // MARK: - The other half of the seam

    /// `@discardableResult` must not appear in `VoccaCore`.
    ///
    /// `decide(_:state:)` returns a ``Decision`` describing what the caller must do with the event
    /// — start, stop, or let it through. Swift already warns when a non-`Void` result is dropped,
    /// and CI fails on any warning, so "the caller forgot to act on the decision" is a build
    /// failure by default. `@discardableResult` is the single annotation that turns that
    /// protection off, and there is no call in a module of pure decision functions that needs it.
    ///
    /// This is a lint rather than a comment because the annotation is one line, reads as harmless,
    /// and the failure it enables — a decision computed and dropped, leaving the microphone open —
    /// is exactly the class of bug this aspect exists to prevent.
    func testVoccaCoreDeclaresNoDiscardableResults() throws {
        let root = try voccaCoreRoot()
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw CoreBoundaryTestError.noSwiftFilesScanned(under: root.path)
        }

        var offenders: [String] = []
        for file in files {
            let source = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            if source.contains("@discardableResult") {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(
            offenders, [],
            """
            @discardableResult found in VoccaCore: \(offenders.joined(separator: ", ")). Every \
            value this module returns is an instruction the caller has to carry out; the compiler \
            warning for an unused result is the only thing that makes forgetting one visible, and \
            CI turns that warning into a failure. Do not switch it off here.
            """)
    }
}
