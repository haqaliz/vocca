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

/// Raised when an injection boundary scan cannot be evaluated meaningfully — the directory is
/// gone, or it holds none of the files the pin exists to police. Either way the lint measured
/// nothing, and a lint that silently measures nothing is worse than no lint: it reports a
/// boundary that is not being held (the `CoreBoundaryTests` vacuity doctrine, restated here
/// because each of these pins is an absence claim that an empty scan would "verify" trivially).
private enum InjectionBoundaryPinError: Error, CustomStringConvertible {
    case noSwiftFilesScanned(under: String)
    case expectedFilesNotScanned(missing: [String], under: String)

    var description: String {
        switch self {
        case .noSwiftFilesScanned(let under):
            return """
                No .swift files were found under \(under) — the boundary was not evaluated \
                against anything. This is the vacuous green this check exists to prevent, so it \
                is a failure, not a pass.
                """
        case .expectedFilesNotScanned(let missing, let under):
            return """
                Under \(under), the scan never reached \(missing.sorted().joined(separator: ", ")). \
                A file that was renamed or moved silently shrinks every absence pin that names it; \
                the pin fails instead.
                """
        }
    }
}

/// Phase F of `injector-seam` (`plan_20260809.md` §4): the absence and boundary pins for the
/// injection vocabulary and the ladder.
///
/// Five pins, and all five are *negative* claims about the code, pinned as scans rather than
/// assumed at review:
///
/// - ``testNoTranscriptLostCaseExists`` — I1's "a transcript is never lost" is load-bearing, so
///   the state that violates it must not be *spellable*; the absence is verified, not believed;
/// - ``testNoInjectionVocabularyNamesASystemIdentifier`` and
///   ``testTheLadderDecisionFilesNameNoSystemIdentifier`` — the new vocabulary and the decision
///   files name no system API in code (doc comments may, and do — the seam is documented in
///   prose, exactly as ``TextInjector``'s documentation names the APIs the adapters own);
/// - ``testInjectionDecisionReadsNoClockOfItsOwn`` — the `CoreBoundaryTests.swift:707` rule,
///   extended to the ladder's pure files: time enters only through the injected
///   ``MonotonicClock``;
/// - ``testTheLadderFilesHoldNoMutableGlobalState`` — the `CoreBoundaryTests.swift:537` rule,
///   scoped to the storage spellings, because the ladder's `@MainActor` isolation is a
///   legitimate shipped decision, not mutable global state.
///
/// Every pin shares its exact scan with a positive control, per the repository's doctrine: a
/// test that only ever asserts "we found nothing" cannot tell "nothing is there" from "I am not
/// looking".
final class InjectionBoundaryPins: XCTestCase {

    // MARK: - Shared machinery

    /// The new injection vocabulary in `VoccaCore` — the files the identifier boundary covers.
    ///
    /// A closed, reviewed list, like H7's
    /// ``HotkeySeamBoundaryTests/filesPermittedToNameEventTypes``: a file that joins the
    /// vocabulary is covered only once it is added here, so adding one is an edit this pin sees
    /// in review.
    private static let expectedInjectionVocabularyFiles = [
        "InjectionRung.swift", "TargetContext.swift", "InjectionResult.swift",
        "FailsafeReason.swift", "HeldTranscript.swift", "TranscriptHolder.swift",
        "TextInjector.swift", "VoccaError.swift",
    ]

    /// The ladder's files in `VoccaInject` — every file the decision half of the seam owns.
    private static let expectedLadderFiles = [
        "InjectionLadderDecision.swift", "LadderInjector.swift", "InjectionRungStrategy.swift",
        "InjectionStrategyOrder.swift", "InjectionAllowlist.swift", "FailsafeHandoff.swift",
    ]

    /// Every `.swift` file at or below `root`, refusing to scan nothing.
    private static func scannedFiles(under root: URL) throws -> [URL] {
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw InjectionBoundaryPinError.noSwiftFilesScanned(under: root.path)
        }
        return files
    }

    /// `file`'s path relative to `rootPath` (a resolved root path), for failure messages.
    ///
    /// Symlinks are resolved before the subtraction — the H7 lesson: a root reached through a
    /// symlink (every macOS temporary directory is one) yields absolute paths that do not begin
    /// with the root's own.
    private static func relativePath(of file: URL, under rootPath: String) -> String {
        file.resolvingSymlinksInPath().path
            .replacingOccurrences(of: rootPath + "/", with: "")
    }

    private static func makeScratchDirectory(named prefix: String) throws -> URL {
        let url = URL(
            fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
        ).appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func packageRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath)
    }

    private func voccaCoreRoot() throws -> URL {
        try packageRoot().appendingPathComponent("Sources/VoccaCore")
    }

    private func ladderRoot() throws -> URL {
        try packageRoot().appendingPathComponent("Sources/VoccaInject/Ladder")
    }

    // MARK: - Pin 1: the state I1 forbids must not be spellable

    /// Every file under `root` whose *code* contains the literal `transcriptLost`, relative
    /// paths.
    ///
    /// Throws rather than returning `[]` when there is nothing to scan — same vacuity doctrine
    /// as ``CoreBoundaryTests``. Comments are stripped first, for the same reason
    /// `mutableGlobalStateMarkers` strips: a doc comment may name the forbidden state while
    /// stating the prohibition, and a comment about the absence is not the state.
    private static func transcriptLostOccurrences(under root: URL) throws -> [String] {
        let rootPath = root.resolvingSymlinksInPath().path
        var occurrences: [String] = []
        for file in try scannedFiles(under: root) {
            let code = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            if code.contains("transcriptLost") {
                occurrences.append(relativePath(of: file, under: rootPath))
            }
        }
        return occurrences.sorted()
    }

    /// **`VoccaCore` contains no `transcriptLost` — the state I1 forbids cannot be spelled.**
    ///
    /// "A transcript is never lost" is the first of the product's two invariants, load-bearing
    /// in a way no other negative claim in this file is: every failure mode the ladder aspect
    /// exists to close is a route to that state, and `ARCHITECTURE.md:199` states the
    /// prohibition directly — "there is no `case transcriptLost`", because a transcript that
    /// reaches the failsafe is a *successful* outcome, never a loss.
    ///
    /// ## The doctrine: a negative about a state must verify the state
    ///
    /// The behavioural suite cannot fail on this. ``InjectionLadderTests`` proves that in every
    /// injected failure combination the handoff received the transcript — but a `transcriptLost`
    /// case added to ``FailsafeReason`` (a reason that lies about the cause) or a
    /// `transcriptLost` field added to ``InjectionResult`` (a result that claims a loss) would
    /// be legal to every one of those tests: the fault-injection suite constructs results by
    /// hand and could go on constructing non-loss ones forever. The only assertion that fails
    /// when the state appears is one that scans for the spelling itself — so the absence is
    /// pinned, not assumed. `FailsafeReason` and `InjectionResult` are the two places such a
    /// case could arrive, and both fall under this one module-wide scan.
    ///
    /// The scan is over *code*: ``TextInjector``'s documentation names the forbidden case while
    /// stating the prohibition ("there is no `case transcriptLost`"), and that comment must not
    /// count.
    func testNoTranscriptLostCaseExists() throws {
        let occurrences = try Self.transcriptLostOccurrences(under: try voccaCoreRoot())

        XCTAssertEqual(
            occurrences, [],
            """
            `transcriptLost` appears in VoccaCore code: \(occurrences.joined(separator: ", ")). \
            I1 makes a lost transcript the one state the ladder may never produce; a spelling of \
            it in code is a case that can be constructed or a field that can be set. Exhaustion \
            is `.exhausted`, the failsafe outcome is a successful InjectionResult, and neither \
            FailsafeReason nor InjectionResult may ever grow a loss-shaped case.
            """)

        // Positive control, sharing the scan: shown the identifier in code, the scan must report
        // it; shown the same identifier only in a comment, it must not.
        let scratch = try Self.makeScratchDirectory(named: "vocca-transcript-lost")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try """
            public enum State {
                case transcriptLost
                // case transcriptLost — commented out, must not be counted
            }
            """.write(
                to: scratch.appendingPathComponent("Loss.swift"), atomically: true,
                encoding: .utf8)
        XCTAssertEqual(
            try Self.transcriptLostOccurrences(under: scratch), ["Loss.swift"],
            "The scan cannot see the identifier it was shown, so it permits it.")
    }

    // MARK: - Pins 2 and 3: the system-identifier boundary

    /// One forbidden identifier in the injection vocabulary or the ladder, located precisely
    /// enough to fix without searching.
    private struct SystemIdentifierSighting: Equatable, CustomStringConvertible {
        let file: String
        let identifier: String

        var description: String { "\(file): \(identifier)" }
    }

    /// The identifier prefixes the injection vocabulary and the ladder's decision files must not
    /// name in code.
    ///
    /// `NSPasteboard` is subsumed by `NS`, and is listed anyway: the pasteboard family is the
    /// clipboard rung's whole world, and the point of the pin is that the *vocabulary* and the
    /// *decision* never carry it — the rung adapters (adapters aspect) are where system
    /// vocabulary belongs, in their own module.
    private static let forbiddenSystemIdentifierPrefixes = [
        "AX", "Pasteboard", "NSPasteboard", "CGEvent", "NS", "Carbon", "ApplicationServices",
    ]

    /// Every occurrence of a forbidden system identifier in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. The prefix rule with a trailing
    /// identifier tail is the H7 mechanism (`HotkeySeamBoundaryTests`): `CGEvent` covers
    /// `CGEventFlags`, `CGEventSource` and every other member of the family by construction,
    /// which is why this is a prefix rule and not a list of names somebody has to keep current.
    private static func systemIdentifiers(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b(" + forbiddenSystemIdentifierPrefixes.joined(separator: "|")
            + ")[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    /// Every forbidden-identifier sighting under `root`, one entry per occurrence.
    private static func systemIdentifierSightings(
        under root: URL
    ) throws -> [SystemIdentifierSighting] {
        let rootPath = root.resolvingSymlinksInPath().path
        var sightings: [SystemIdentifierSighting] = []
        for file in try scannedFiles(under: root) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for identifier in systemIdentifiers(inSource: source) {
                sightings.append(
                    SystemIdentifierSighting(
                        file: relativePath(of: file, under: rootPath), identifier: identifier))
            }
        }
        return sightings.sorted { $0.description < $1.description }
    }

    /// **The injection vocabulary names no system identifier in code.**
    ///
    /// These eight files are the whole new surface of the seam: the types every consumer reads
    /// and every rung returns. Their boundary is `VoccaCore`'s import-free boundary — and the
    /// import allow-list is exactly what cannot hold it. An identifier needs no import:
    /// `bundleID` is the whole point of ``TargetContext``, while a field spelled `pasteboard`,
    /// or a type named after an AX family member, would carry the adapters' vocabulary into the
    /// core for no cost anyone would notice at review. ``CoreBoundaryTests`` keeps the module
    /// free of *imports*; this pin keeps the new vocabulary free of *names*.
    ///
    /// Comments are stripped first: these files document the seam in prose, and the docs should
    /// name the APIs they defer to (``TargetContext``'s tells you the `AXElementRef` decision,
    /// ``InjectionRungStrategy``'s names the rung adapters). The H7 rule — a doc comment may
    /// name a forbidden API, code may not — is the same one.
    ///
    /// The scan is scoped to the eight new files, not the whole module: the module's import
    /// boundary is ``CoreBoundaryTests``'s job, and vocabulary that predates this aspect has its
    /// own reviews. The vacuity guard fails loudly if any of the eight has been renamed or
    /// moved.
    func testNoInjectionVocabularyNamesASystemIdentifier() throws {
        let coreRoot = try voccaCoreRoot()
        let expected = Set(Self.expectedInjectionVocabularyFiles)
        let files = try Self.scannedFiles(under: coreRoot)
            .filter { expected.contains($0.lastPathComponent) }
        let found = Set(files.map(\.lastPathComponent))
        guard found == expected else {
            throw InjectionBoundaryPinError.expectedFilesNotScanned(
                missing: expected.subtracting(found).sorted(), under: coreRoot.path)
        }

        var sightings: [SystemIdentifierSighting] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for identifier in Self.systemIdentifiers(inSource: source) {
                sightings.append(
                    SystemIdentifierSighting(
                        file: file.lastPathComponent, identifier: identifier))
            }
        }

        XCTAssertEqual(
            sightings, [],
            """
            A system identifier in VoccaCore's injection vocabulary: \
            \(sightings.map(\.description).joined(separator: "; ")). An identifier needs no \
            import, so the import allow-list cannot see it arrive. The vocabulary is the seam's \
            contract; system types belong to the rung adapters, in their own module.
            """)
    }

    /// **The ladder's decision files name no system identifier in code.**
    ///
    /// `VoccaInject` is an adapter module, so it *may* name system APIs — but the ladder's pure
    /// files are the decision half of the seam, and the whole decision table must keep running
    /// on a runner with no permissions: no AX, no pasteboard. A `CGEvent` or `AX` type here is a
    /// decision moved below the seam, or a leak of the adapters' vocabulary into the half that
    /// must stay pure. The default allowlist, the order, the rung-strategy seam and the failsafe
    /// handoff are all part of that decision surface, so all six files under `Ladder/` are in
    /// scope — and the directory scan covers any file that joins them automatically.
    ///
    /// `VoccaInject/Placeholder.swift` is deliberately outside the scan: it predates the aspect
    /// and is a placeholder, not a decision.
    func testTheLadderDecisionFilesNameNoSystemIdentifier() throws {
        let ladderRoot = try ladderRoot()
        let files = try Self.scannedFiles(under: ladderRoot)
        let scanned = Set(files.map(\.lastPathComponent))
        let missing = Set(Self.expectedLadderFiles).subtracting(scanned)
        guard missing.isEmpty else {
            throw InjectionBoundaryPinError.expectedFilesNotScanned(
                missing: missing.sorted(), under: ladderRoot.path)
        }

        let sightings = try Self.systemIdentifierSightings(under: ladderRoot)

        XCTAssertEqual(
            sightings, [],
            """
            A system identifier in the ladder's decision files: \
            \(sightings.map(\.description).joined(separator: "; ")). The ladder decides what the \
            rung adapters' answers *mean*; naming the system in the decision is a decision that \
            moved below the seam, where CI cannot reach it.
            """)
    }

    /// Positive control shared by the two identifier pins: the scan's full walk — directory
    /// enumeration, comment stripping and the prefix rule — run against a planted tree.
    ///
    /// Every listed prefix must be seen in code and none in comments, and the shipped
    /// vocabulary (`clipboardPaste`, whose spelling resists the `Pasteboard` prefix only by case
    /// and boundary) must not fire. A lint that misses any of the seven forms permits it; a lint
    /// that fires on the vocabulary is a lint someone loosens.
    func testTheSystemIdentifierScanSeesAPlantedIdentifier() throws {
        let scratch = try Self.makeScratchDirectory(named: "vocca-injection-boundary")
        defer { try? FileManager.default.removeItem(at: scratch) }

        try """
            func resolve() -> AXUIElement? {
                let pb: PasteboardHandle = NSPasteboard.general
                let event = CGEventSource(stateID: .hidSystemState)
                let window: NSWindow? = nil
                let carbon = CarbonTie()
                let services = ApplicationServicesHandle()
                return nil
            }
            // AXElementRef and NSWindow are commented out: neither may be counted.
            """.write(
                to: scratch.appendingPathComponent("Planted.swift"), atomically: true,
                encoding: .utf8)
        try """
            let rung = InjectionRung.clipboardPaste
            let context = TargetContext(bundleID: nil, windowTitle: nil, isSecureInput: false)
            let order = DefaultInjectionStrategyOrder(allowlist: EmptyInjectionAllowlist())
            """.write(
                to: scratch.appendingPathComponent("Clean.swift"), atomically: true,
                encoding: .utf8)

        let sightings = try Self.systemIdentifierSightings(under: scratch)
        let found = Set(sightings.map(\.identifier))
        let expected: Set<String> = [
            "AXUIElement", "PasteboardHandle", "NSPasteboard", "CGEventSource", "NSWindow",
            "CarbonTie", "ApplicationServicesHandle",
        ]
        XCTAssertEqual(
            found, expected,
            """
            The lint failed to see one or more planted identifiers, or reported a clean file. \
            Missed: \(expected.subtracting(found).sorted().joined(separator: ", ")). Spurious: \
            \(found.subtracting(expected).sorted().joined(separator: ", ")). Each prefix in the \
            fixture is one the seam is defined by; an identifier the lint cannot see is an \
            identifier the lint permits.
            """)
        XCTAssertTrue(
            sightings.allSatisfy { $0.file == "Planted.swift" },
            "Unexpected file attribution: \(Set(sightings.map(\.file)).sorted())")
    }

    // MARK: - Pin 4: no clock of its own

    /// The clocks that need no import, and are therefore invisible to any import allow-list.
    ///
    /// The same pair ``CoreBoundaryTests`` bans, for the same reason: both are standard-library
    /// types, so the module boundary cannot see either one arrive.
    private static let standardLibraryClocks = ["ContinuousClock", "SuspendingClock"]

    /// **The ladder's pure files read no standard-library clock.**
    ///
    /// `plan_20260809.md` §3 requires `elapsed` to be accumulated from the injected
    /// ``MonotonicClock`` — deltas, never a wall clock — so the ladder's ≤100 ms budget test is
    /// deterministic. The `CoreBoundaryTests.swift:707` rule exists because `ContinuousClock`
    /// and `SuspendingClock` are standard-library types: they need no import, so the import
    /// boundary cannot see them arrive, and a clock read in the session machine left its whole
    /// ceiling untestable with the lint green. `VoccaInject`'s ladder files are the same shape:
    /// the module may import Foundation, but the decision must not read a clock it was not
    /// handed. `MonotonicClock` is the only way time enters.
    func testInjectionDecisionReadsNoClockOfItsOwn() throws {
        let ladderRoot = try ladderRoot()
        var offenders: [String] = []
        for file in try Self.scannedFiles(under: ladderRoot) {
            let code = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            for clock in Self.standardLibraryClocks where code.contains(clock) {
                offenders.append("\(file.lastPathComponent): \(clock)")
            }
        }
        XCTAssertEqual(
            offenders.sorted(), [],
            """
            A standard-library clock read in the ladder: \
            \(offenders.sorted().joined(separator: "; ")). These need no import, so the module \
            boundary cannot see them arrive. `elapsed` must come from the injected \
            MonotonicClock — a clock read here makes the budget test wait for real time, which \
            means it will not be written.
            """)

        // Positive control, sharing the scan's mechanism: shown both clocks, it must report both,
        // and it must ignore one that is only mentioned in a comment.
        let fixture = SwiftSourceScanner.stripComments(
            from: """
                let deadline = ContinuousClock().now + .seconds(120)
                let other = SuspendingClock.now
                // ContinuousClock is what the ladder must not reach for.
                """)
        XCTAssertEqual(
            Set(Self.standardLibraryClocks.filter { fixture.contains($0) }),
            Set(Self.standardLibraryClocks),
            "The lint cannot see a standard-library clock it was shown, so it permits one.")
    }

    // MARK: - Pin 5: no mutable global state

    /// Every spelling of mutable global state the ladder must not hold, found in `source`.
    ///
    /// The `CoreBoundaryTests.swift:537` rule, scoped deliberately. The CoreBoundaryTests list
    /// is `nonisolated(unsafe)`, `@MainActor`, `@globalActor`, `@unchecked Sendable` and the
    /// stored `static var` — and the ladder pins the same list **minus `@MainActor`**, for a
    /// reason that is the point of this pin:
    ///
    /// - `nonisolated(unsafe)` and `@unchecked Sendable` are the two annotations that mark
    ///   mutable storage as safe to share without isolation. Each is how a cache would be
    ///   smuggled into a module that has no business holding one — a total no test can reach;
    /// - a *stored* `static var` is the storage itself (the computed form is not, which is what
    ///   keeps every `CaseIterable.allCases` out of this);
    /// - `@globalActor` would *create* a new global isolation domain inside the ladder — the one
    ///   place a running total could live and never be seen.
    ///
    /// `@MainActor` is absent deliberately. The shipped Phase C ladder annotates
    /// ``InjectionLadderDecision`` and ``LadderInjector`` `@MainActor` because the injected
    /// ``MonotonicClock`` is not `Sendable` and the whole latency path lives in one isolation
    /// domain (`ARCHITECTURE.md:271`). An isolation annotation is not mutable global state — it
    /// puts code in a *domain*, it does not create storage — and the CoreBoundaryTests ban exists
    /// because *VoccaCore* must be isolation-free; VoccaInject has no such rule. Banning
    /// `@MainActor` here would fail on the shipped decision and get this lint deleted.
    ///
    /// Comments are stripped first, so a doc comment discussing the prohibition does not trip it.
    private static func mutableGlobalStateMarkers(in source: String) -> [String] {
        let stripped = SwiftSourceScanner.stripComments(from: source)
        var found = ["nonisolated(unsafe)", "@unchecked Sendable", "@globalActor"]
            .filter { stripped.contains($0) }

        let storedStaticVar = try? NSRegularExpression(
            pattern: #"static\s+var\s+\w+\s*(?::[^={}\n]+)?="#)
        let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        let matches = storedStaticVar?.numberOfMatches(in: stripped, range: range) ?? 0
        found.append(contentsOf: repeatElement("stored static var", count: matches))
        return found
    }

    /// **The ladder's files hold no mutable global state.**
    ///
    /// The decision must be re-runnable against any input with no memory of the previous run —
    /// every row of the decision table is a pure function of its injected inputs, and a running
    /// total would desynchronise the trace the way the session machine's would have (the Handy
    /// #840 class of defect). Storage in these files has exactly one legitimate place: the
    /// injected seams, whose handles arrive through the `LadderInjector`'s initialiser, never as
    /// globals.
    func testTheLadderFilesHoldNoMutableGlobalState() throws {
        let ladderRoot = try ladderRoot()
        var offenders: [String] = []
        for file in try Self.scannedFiles(under: ladderRoot) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for marker in Self.mutableGlobalStateMarkers(in: source) {
                offenders.append("\(file.lastPathComponent): \(marker)")
            }
        }
        XCTAssertEqual(
            offenders.sorted(), [],
            """
            Mutable global state in the ladder: \(offenders.sorted().joined(separator: "; ")). A \
            ladder run must be re-runnable against any input with no memory of the previous run; \
            a total lives in exactly these spellings. Inject the state, like the clock and the \
            allowlist already are.
            """)

        // Positive control, sharing the scan: every storage spelling must be seen, and a
        // commented-out one must not be.
        let caught = Self.mutableGlobalStateMarkers(
            in: """
                nonisolated(unsafe) var held = 0
                enum Held { static var total = 0 }
                enum Typed { static var total: Int = 0 }
                @globalActor actor Custom {}
                final class Cache: @unchecked Sendable { var value = 0 }
                // nonisolated(unsafe) var commentedOut = 0
                """)
        XCTAssertEqual(
            Set(caught),
            ["nonisolated(unsafe)", "@globalActor", "@unchecked Sendable", "stored static var"],
            "The lint cannot see a spelling of mutable global state, so it permits it.")
        XCTAssertEqual(
            caught.filter { $0 == "stored static var" }.count, 2,
            "Both the inferred and the annotated stored form must be seen, not just one.")

        // The load-bearing negative control: the shipped isolation annotation must not fire. A
        // lint that fails on @MainActor here fails on legitimate code and gets deleted.
        let mustNotFire = Self.mutableGlobalStateMarkers(
            in: """
                @MainActor
                public struct LadderInjector: TextInjector {
                    public static var allCases: [InjectionRung] {
                        [.clipboardPaste, .keystrokeSynthesis]
                    }
                    static let permitted: Set<String> = []
                    var local = 0
                }
                """)
        XCTAssertEqual(
            mustNotFire, [],
            """
            The lint reported \(mustNotFire) for the shipped @MainActor isolation, a computed \
            `static var`, a `static let`, or a local. @MainActor is an isolation domain, not \
            mutable global state — and the CoreBoundaryTests ban exists because VoccaCore must \
            be isolation-free, which VoccaInject is not required to be.
            """)
    }
}
