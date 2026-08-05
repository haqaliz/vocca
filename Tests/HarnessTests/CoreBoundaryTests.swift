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
    /// Extend only with a reviewed reason. While this is empty, `VoccaCore` imports nothing, and
    /// every indirect route into it is closed by that alone — there is no sibling to carry a
    /// re-export and no module whose types could be aliased. Adding one entry ends that, and the
    /// transitive rule below covers only part of what it lets in. Read these three before adding
    /// anything:
    ///
    /// 1. **A `typealias` is not a re-export and is not caught.** A permitted sibling with
    ///    `import AppKit` and `public typealias VoccaWindow = NSWindow` puts an `NSWindow` in
    ///    `VoccaCore` with this suite green. The rule deliberately ignores a sibling's *plain*
    ///    imports — reporting them would flag every legitimate adapter and get the lint deleted —
    ///    so the cost of that trade-off lands here.
    /// 2. **Module layout is assumed to be `Sources/<ModuleName>`.** No target in `Package.swift`
    ///    uses a custom `path:` today. If one ever does, the transitive walk cannot find its
    ///    directory and skips it silently.
    /// 3. **Only `@_exported` propagates.** That is correct for Swift, but it means the rule
    ///    answers "what does this module re-export", not "what can this module see".
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

    /// Everything reachable in `VoccaCore` through a chain of re-exports, that `permitted` does not
    /// cover.
    ///
    /// `@_exported import X` in module `M` makes `X`'s API visible to everyone importing `M`, so a
    /// lint that reads only the importing file cannot see it arrive. Imports that are not
    /// directories under `sourcesRoot` — the standard library, a system framework — are skipped:
    /// there is no source of ours to read.
    ///
    /// **Walked to a fixpoint, not one hop.** If `VoccaCore` imports `A`, `A` re-exports `B`, and
    /// `B` re-exports `AppKit`, then `AppKit` is visible in `VoccaCore` — re-export is transitive.
    /// One hop caught that case only incidentally, because `B` was not on the allow-list; put two
    /// Vocca modules on the list and the second hop went invisible. The worklist below follows
    /// every permitted re-export edge and reports the rest, so the depth of the chain does not
    /// matter.
    private func disallowedReExports(
        reachableFrom moduleRoot: URL, permitted: Set<String>, sourcesRoot: URL, displayRoot: URL
    ) throws -> [DisallowedImport] {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: moduleRoot.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CoreBoundaryTestError.moduleDirectoryMissing(expectedAt: moduleRoot.path)
        }
        let rootFiles = SwiftSourceScanner.swiftFiles(under: moduleRoot)
        guard !rootFiles.isEmpty else {
            throw CoreBoundaryTestError.noSwiftFilesScanned(under: moduleRoot.path)
        }

        var queue = try rootFiles.flatMap { try SwiftSourceScanner.importedModuleNames(in: $0) }
            .sorted()
        var visited: Set<String> = []
        var violations: [DisallowedImport] = []

        while let module = queue.popLast() {
            guard visited.insert(module).inserted else { continue }

            let siblingRoot = sourcesRoot.appendingPathComponent(module)
            var siblingIsDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: siblingRoot.path, isDirectory: &siblingIsDirectory),
                siblingIsDirectory.boolValue
            else { continue }

            for file in SwiftSourceScanner.swiftFiles(under: siblingRoot) {
                for statement in try SwiftSourceScanner.importStatements(in: file)
                where statement.isReExported {
                    if permitted.contains(statement.module) {
                        // Permitted, so not a violation — but its own re-exports ride along into
                        // VoccaCore too, so keep walking.
                        queue.append(statement.module)
                    } else {
                        violations.append(
                            DisallowedImport(
                                file: displayPath(of: file, from: displayRoot),
                                module: statement.module, via: module))
                    }
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
    /// allow-list is empty. Three fake modules in a scratch tree, forming a two-hop chain:
    /// `FakeCore` imports `FakeAdapter`, which re-exports `FakeRelay`, which re-exports `AppKit`.
    ///
    /// The second hop is the point. A one-hop rule caught the first version of this route only
    /// because the intermediate module was not on the allow-list; with both permitted, the
    /// framework arrives and a one-hop walk sees nothing.
    func testTheLintDetectsAFrameworkArrivingThroughAReExport() throws {
        let scratch = try makeScratchDirectory(named: "vocca-core-reexport")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let core = scratch.appendingPathComponent("FakeCore", isDirectory: true)
        let adapter = scratch.appendingPathComponent("FakeAdapter", isDirectory: true)
        let relay = scratch.appendingPathComponent("FakeRelay", isDirectory: true)
        for directory in [core, adapter, relay] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        try "import FakeAdapter\n".write(
            to: core.appendingPathComponent("Core.swift"), atomically: true, encoding: .utf8)
        try "@_exported import FakeRelay\nimport Foundation\n".write(
            to: adapter.appendingPathComponent("Adapter.swift"), atomically: true, encoding: .utf8)
        try "@_exported import AppKit\n".write(
            to: relay.appendingPathComponent("Relay.swift"), atomically: true, encoding: .utf8)

        let permitted: Set<String> = ["FakeAdapter", "FakeRelay"]

        // The direct rule is satisfied — FakeCore imports only what it is allowed to. That is what
        // makes this route interesting: it is invisible to the assertion everyone would write.
        XCTAssertEqual(
            try disallowedImports(under: core, permitted: permitted, displayRoot: scratch), [],
            "The direct rule should be satisfied here, or this control is testing the wrong thing.")

        let violations = try disallowedReExports(
            reachableFrom: core, permitted: permitted, sourcesRoot: scratch, displayRoot: scratch)
        XCTAssertEqual(
            violations,
            [DisallowedImport(file: "FakeRelay/Relay.swift", module: "AppKit", via: "FakeRelay")],
            """
            The transitive rule missed a re-export two hops out. This is the route that put \
            CGEventFlags and NSApplication inside VoccaCore with the whole suite green, one link \
            longer: the walk must follow a permitted module's own re-exports, not stop at the \
            first hop.
            """)

        // Neither the adapter's plain `import Foundation` nor its permitted re-export of
        // FakeRelay is a violation. Over-reporting would make the rule unusable and get it deleted.
        XCTAssertFalse(
            violations.contains { $0.module == "Foundation" || $0.module == "FakeRelay" },
            """
            A plain import, or a re-export of a permitted module, must not be reported. Found: \
            \(violations.map(\.description))
            """)
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

        // The same guard on the transitive walk, which has its own copy of it. That copy was
        // never exercised: `disallowedReExports` returns `[]` both when nothing re-exports
        // anything and when it was handed a directory with no Swift in it, so the rule that walks
        // nothing today would have reported a clean bill of health for a VoccaCore that had moved.
        XCTAssertThrowsError(
            try disallowedReExports(
                reachableFrom: empty, permitted: [], sourcesRoot: empty, displayRoot: empty)
        ) { error in
            XCTAssertTrue(
                error is CoreBoundaryTestError,
                "Expected the re-export walk to refuse an empty tree, got \(error)")
        }
        XCTAssertThrowsError(
            try disallowedReExports(
                reachableFrom: missing, permitted: [], sourcesRoot: empty, displayRoot: empty)
        ) { error in
            XCTAssertTrue(
                error is CoreBoundaryTestError,
                "Expected the re-export walk to refuse a missing directory, got \(error)")
        }
    }

    // MARK: - The other half of the seam

    /// `@discardableResult` must not appear in `VoccaCore`.
    ///
    /// `decide(_:state:config:)` returns a `Decision` describing what the caller must do with the
    /// event.
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

    /// `VoccaCore` must hold no mutable global state.
    ///
    /// This is the structural half of the prohibition `decide(_:state:config:)` is written under:
    /// modifier state is derived from the event in hand and never accumulated. `decide` is a free
    /// function, so it has no storage of its own — the *only* place a running total could live is a
    /// mutable global. Each token below is a deliberate annotation, and none of them belongs in a
    /// module of pure decision functions.
    ///
    /// **This list is not exhaustive and must not be described as though it were.** Task 3's report
    /// claimed the escape hatches were "enumerable and exactly what the lint matches"; that was one
    /// notch too strong, and the reviewer demonstrated it. A `final class ... @unchecked Sendable`
    /// holding a `var`, reached through a global `let`, is mutable global state carrying no
    /// annotation on the global itself. `@unchecked Sendable` is on the list below now because of
    /// that, but closing one route does not close the class — a mutable value can always be hidden
    /// behind another layer of type.
    ///
    /// So this lint is one of two defences and never the argument on its own. The behavioural half
    /// lives in `SessionDecisionTests`: the purity test evaluates the same inputs forwards and
    /// backwards and requires identical answers, which is what state carried between calls fails.
    /// On the reviewer's cache that half failed immediately and loudly while this half still
    /// passed — which is the division of labour working, not a hole. A lint cannot see state
    /// smuggled behind a type; a property test cannot see state that has not yet desynchronised.
    func testVoccaCoreHoldsNoMutableGlobalState() throws {
        let moduleRoot = try voccaCoreRoot()
        let files = SwiftSourceScanner.swiftFiles(under: moduleRoot)
        guard !files.isEmpty else {
            throw CoreBoundaryTestError.noSwiftFilesScanned(under: moduleRoot.path)
        }

        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for marker in Self.mutableGlobalStateMarkers(in: source) {
                offenders.append("\(displayPath(of: file, from: try sourcesRoot())): \(marker)")
            }
        }
        XCTAssertEqual(
            offenders.sorted(), [],
            """
            Mutable global state in VoccaCore: \(offenders.sorted().joined(separator: "; ")).

            A running modifier total is the Handy #840 defect — v0.2.0 accumulated on \
            flagsChanged and desynchronised permanently after one missed event, leaving the \
            microphone open — and a global is the only place one could live in a module of free \
            functions. Derive modifier state from event.modifiers, every time.
            """)

        // Positive control, sharing the scan. Both halves are needed and the second one is not
        // decoration: the first version of this lint matched `static var` as a bare substring and
        // failed on `RetainedEndReason.allCases`, which is a *computed* property that CaseIterable
        // requires to be a `var`. A lint that fires on correct code gets loosened or deleted, so
        // the false positive is pinned here alongside the true ones.
        let caught = Self.mutableGlobalStateMarkers(
            in: """
                nonisolated(unsafe) var heldModifiers = ModifierSet()
                enum Held { static var modifiers = ModifierSet() }
                enum Typed { static var modifiers: ModifierSet = [] }
                @MainActor final class Isolated {}
                @globalActor actor Custom {}
                final class ModifierCache: @unchecked Sendable { var held = ModifierSet() }
                // nonisolated(unsafe) var commentedOut = 0
                """)
        XCTAssertEqual(
            Set(caught),
            [
                "nonisolated(unsafe)", "@MainActor", "@globalActor", "@unchecked Sendable",
                "stored static var",
            ],
            "The lint cannot see a spelling of mutable global state, so it permits it.")
        XCTAssertEqual(
            caught.filter { $0 == "stored static var" }.count, 2,
            "Both the inferred and the annotated stored form must be seen, not just one.")

        let mustNotFire = Self.mutableGlobalStateMarkers(
            in: """
                public static var allCases: [RetainedEndReason] {
                    [.keyUp] + SystemTrigger.allCases.map(RetainedEndReason.systemEvent)
                }
                static let permitted: Set<String> = []
                var local = 0
                """)
        XCTAssertEqual(
            mustNotFire, [],
            """
            The lint reported \(mustNotFire) for a computed `static var`, a `static let`, or a \
            local. None of the three is global mutable state, and a lint that fails on correct \
            code is a lint someone loosens.
            """)
    }

    /// Every spelling of mutable global state Swift 6 still permits, found in `source`.
    ///
    /// Swift 6's strict concurrency already rejects an unannotated global `var` or stored
    /// `static var` outright — the compiler's own fix-its name the ways out, and these are they.
    /// `actor` is deliberately absent: task 4's session may legitimately be one, and forbidding it
    /// would be a lint written against the next unit of work rather than against the defect.
    /// `static let` is absent because an immutable constant is not state.
    ///
    /// Comments are stripped first, so a doc comment discussing the prohibition does not trip it.
    private static func mutableGlobalStateMarkers(in source: String) -> [String] {
        let stripped = SwiftSourceScanner.stripComments(from: source)
        var found = ["nonisolated(unsafe)", "@MainActor", "@globalActor", "@unchecked Sendable"]
            .filter { stripped.contains($0) }

        // A *stored* static var: `static var x =` or `static var x: T =`. A computed one is
        // `static var x: T {` and has no `=` before the brace, which is what keeps `allCases` and
        // every other CaseIterable conformance out of this.
        let storedStaticVar = try? NSRegularExpression(
            pattern: #"static\s+var\s+\w+\s*(?::[^={}\n]+)?="#)
        let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        let matches = storedStaticVar?.numberOfMatches(in: stripped, range: range) ?? 0
        found.append(contentsOf: repeatElement("stored static var", count: matches))
        return found
    }

    // MARK: - The custody funnel

    /// Every file under `root` that calls `.make(` on something, one entry per call.
    ///
    /// Deliberately textual and deliberately blunt: it matches *any* `.make(`, not
    /// `SessionOutcome.make(` specifically, so a call written through a typealias, a generic
    /// parameter or a local binding is still counted. Over-matching costs a rename; under-matching
    /// costs the guarantee.
    private func outcomeConstructionSites(under root: URL) throws -> [String] {
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw CoreBoundaryTestError.noSwiftFilesScanned(under: root.path)
        }
        var sites: [String] = []
        for file in files {
            let source = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            let calls = source.components(separatedBy: ".make(").count - 1
            sites.append(contentsOf: repeatElement(file.lastPathComponent, count: calls))
        }
        return sites.sorted()
    }

    /// **There is exactly one place in `VoccaCore` where a `SessionOutcome` comes into existence.**
    ///
    /// `spec.md` asks for one `endSession(reason:)` funnel that every stop path goes through. That
    /// is a property of the *machine*, and the machine can satisfy it while some other file in the
    /// module quietly builds an outcome of its own — at which point the reviewed mapping from cause
    /// to fate is no longer the only mapping, and "a transcript is never lost" is back to being a
    /// rule someone has to remember.
    ///
    /// `SessionOutcome.make(reason:audio:)` is public and sealed, so it is *the* constructor; what
    /// this pins is that it is called once, from the funnel, and nowhere else. A behavioural test
    /// cannot see this: a second call site produces perfectly correct-looking outcomes.
    func testTheSessionMachineIsTheOnlyPlaceAnOutcomeIsConstructed() throws {
        XCTAssertEqual(
            try outcomeConstructionSites(under: try voccaCoreRoot()), ["SessionMachine.swift"],
            """
            A SessionOutcome is constructed somewhere other than the single custody funnel in \
            SessionMachine.endSession(reason:). Every terminal path must go through that one \
            reviewed switch — it is what makes "every stop rule hands its audio downstream" a \
            property of the code rather than of everyone who edits it.
            """)

        // Positive control, sharing the scan. Two call sites in two files must both be found, and
        // a commented-out one must not be: a lint that cannot see a second call site permits one.
        let scratch = try makeScratchDirectory(named: "vocca-outcome-sites")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try "let a = SessionOutcome.make(reason: r, audio: b)\n// SessionOutcome.make(reason: r, audio: b)\n"
            .write(
                to: scratch.appendingPathComponent("First.swift"), atomically: true, encoding: .utf8)
        try "func f() { _ = Outcome.make(reason: r, audio: b); _ = O.make(reason: r, audio: b) }\n"
            .write(
                to: scratch.appendingPathComponent("Second.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try outcomeConstructionSites(under: scratch),
            ["First.swift", "Second.swift", "Second.swift"],
            "The scan cannot see a second construction site, so it permits one.")

        let empty = try makeScratchDirectory(named: "vocca-outcome-empty")
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertThrowsError(try outcomeConstructionSites(under: empty)) { error in
            XCTAssertTrue(error is CoreBoundaryTestError, "Expected a refusal, got \(error)")
        }
    }

    /// **`VoccaCore` reads no clock of its own**, and the import allow-list cannot say so.
    ///
    /// `spec.md` requires the ceiling and poll tests to be deterministic and instant, which requires
    /// the clock to be injected. `testVoccaCoreImportsOnlyWhatIsExplicitlyPermitted` removes `Date`,
    /// `DispatchTime` and `mach_absolute_time` by removing Foundation, Dispatch and Darwin — and
    /// stops there, because `ContinuousClock` and `SuspendingClock` are **standard library** types.
    /// They need no import at all, so an allow-list of imports cannot see either one arrive, and
    /// `ContinuousClock().now` inside the session machine would leave the whole ceiling untestable
    /// with the boundary lint green.
    ///
    /// One line closes it. `MonotonicClock` is the only way time enters this module.
    func testVoccaCoreReadsNoClockOfItsOwn() throws {
        let moduleRoot = try voccaCoreRoot()
        let files = SwiftSourceScanner.swiftFiles(under: moduleRoot)
        guard !files.isEmpty else {
            throw CoreBoundaryTestError.noSwiftFilesScanned(under: moduleRoot.path)
        }

        var offenders: [String] = []
        for file in files {
            let source = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            for clock in Self.standardLibraryClocks where source.contains(clock) {
                offenders.append("\(displayPath(of: file, from: try sourcesRoot())): \(clock)")
            }
        }
        XCTAssertEqual(
            offenders.sorted(), [],
            """
            VoccaCore reads a standard-library clock: \(offenders.sorted().joined(separator: "; ")).

            These need no import, so the boundary lint above cannot see them. A clock read here \
            makes the ceiling test wait 120 s to find out whether the ceiling fires, which means it \
            will not be written. Take a MonotonicClock instead — the caller owns the real one.
            """)

        // Positive control, sharing the scan's mechanism: shown both clocks, it must report both,
        // and it must ignore the one that is only mentioned in a comment.
        let scratch = try makeScratchDirectory(named: "vocca-core-clock")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try """
            let deadline = ContinuousClock().now + .seconds(120)
            let other = SuspendingClock.now
            // ContinuousClock is what this module must not reach for.
            """.write(
                to: scratch.appendingPathComponent("Clocks.swift"), atomically: true,
                encoding: .utf8)
        let fixture = SwiftSourceScanner.stripComments(
            from: try String(
                contentsOf: scratch.appendingPathComponent("Clocks.swift"), encoding: .utf8))
        XCTAssertEqual(
            Set(Self.standardLibraryClocks.filter { fixture.contains($0) }),
            Set(Self.standardLibraryClocks),
            "The lint cannot see a standard-library clock it was shown, so it permits one.")
    }

    /// The clocks that need no import, and are therefore invisible to the allow-list.
    ///
    /// `Foundation`'s `Date` and `UTCClock` are absent deliberately: they are already unreachable,
    /// and a lint that repeats another lint's job fails in two places when the rule changes.
    private static let standardLibraryClocks = ["ContinuousClock", "SuspendingClock"]

    /// Two properties of `SessionOutcome` that no other test in this suite can fail on.
    ///
    /// Both are source pins, for the same reason `@discardableResult` above is one: each is a small
    /// edit that reads as harmless and silently removes an invariant, and neither is visible to a
    /// behavioural test written in this module.
    ///
    /// 1. **`<Audio: CapturedAudio>`.** Widen it back to `Sendable` and `SessionOutcome<[Float]?>`
    ///    type-checks again, which makes `.completed(reason: .ceilingReached, audio: nil)` legal —
    ///    "ended a session without producing audio", type-approved. `SessionVocabularyTests`
    ///    catches that only through a conformance query on `Optional`, which a blanket conformance
    ///    would satisfy; this catches the constraint being dropped outright.
    /// 2. **`case cancelled(Seal)`.** The seal is what makes `make(reason:audio:)` the only route
    ///    to a `Content` rather than merely the intended one. Take it off this case and a sibling
    ///    file can mint `.cancelled` directly, which is a stop rule routed to the discard path
    ///    with no reason attached — the one thing the split enum exists to prevent.
    func testSessionOutcomeKeepsItsAudioConstraintAndItsSealedCancellation() throws {
        let file = try voccaCoreRoot().appendingPathComponent("SessionOutcome.swift")
        let source = SwiftSourceScanner.stripComments(
            from: try String(contentsOf: file, encoding: .utf8))

        XCTAssertTrue(
            source.contains("<Audio: CapturedAudio>"),
            """
            SessionOutcome no longer constrains its audio to CapturedAudio. Widened to Sendable, \
            Optional satisfies it again and `.completed(reason: .ceilingReached, audio: nil)` \
            becomes legal — a session that ended without producing the audio it owes downstream, \
            with the property test that is supposed to catch that passing while emitting nothing.
            """)
        XCTAssertTrue(
            source.contains("case cancelled(Seal)"),
            """
            SessionOutcome.Content.cancelled no longer demands a Seal. Without it any file in this \
            module can construct the discard case directly, and the single-funnel guarantee — that \
            the mapping from EndReason to fate exists in exactly one reviewed switch — is gone.
            """)
    }
}
