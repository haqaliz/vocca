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

/// Raised when the prohibition cannot be evaluated meaningfully, so that scanning nothing is a
/// failure rather than a pass.
private enum ActionTransportTestError: Error, CustomStringConvertible {
    case moduleDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .moduleDirectoryMissing(let expectedAt):
            return """
                The VoccaActions module directory does not exist at \(expectedAt). The transport \
                prohibition is asserted by scanning that tree; if the module has moved or been \
                renamed, this lint enforces nothing.
                """
        case .noSwiftFilesScanned(let under):
            return """
                No .swift files were found under \(under) — the prohibition was not evaluated \
                against anything. That is the vacuous green this check exists to prevent, so it \
                is a failure.
                """
        }
    }
}

/// The transport prohibition over `VoccaActions` (`transport-prohibition`, deviation **D2**).
///
/// ## Why this exists — do not delete it as redundant
///
/// A reader who opens this file, sees a transport lint over a module that contains no transport,
/// and concludes it is decoration will be reasoning correctly from incomplete facts. The missing
/// facts are these, measured in this unit's Phase 2 dig and recorded as **D2**:
///
/// 1. **Vocca's permanent release blocker is a zero-network CI test driven by a `dyld`
///    interposer**, and that interposer **counts loopback as NETWORK on purpose**
///    (`Sources/CVoccaNetworkInterposer/interposer.c:69-73`: "Loopback counts as NETWORK on
///    purpose … the opt-in local LLM lives on loopback, and the invariant is meant to catch it
///    becoming reachable by default"). So an MCP server reached on `127.0.0.1` over HTTP/SSE is
///    a **violation of the invariant**, not a local convenience. **Stdio is the only transport
///    the invariant permits.**
///
/// 2. **But a stdio server is a spawned child, and the interposer cannot follow it.**
///    `DYLD_INSERT_LIBRARIES` is stripped *and purged* from the environment of a restricted
///    child, so `/usr/bin/env node server.js`, any `/bin/sh -c` wrapper, and any Apple platform
///    binary run **blind**. One hop launders the insertion for the entire descendant tree.
///
/// 3. **Therefore the failure mode is a green test while a child egresses.** The `audit-log`
///    aspect's `PROBE-ACTIONS` proves the audit *store* reaches no network name; it says nothing
///    whatsoever about a transport spawned out from under it.
///
/// This lint **cannot fix that** — nothing at this layer can. What it does is make reaching for a
/// transport or a subprocess a **reviewed edit** rather than an accident, so the false green
/// cannot be introduced silently. The day someone needs `Process` here to speak stdio to an MCP
/// server, they must come to this file and say so in a permitted-set entry, and the review that
/// entry forces is the whole mechanism. Deleting the lint deletes the review.
///
/// ## That day came: `stdio-transport`, 2026-09-21
///
/// The permitted set holds exactly one entry, and the review it forced produced an answer that is
/// worth reading before the code. **The honest answer to D2 is that the child does not stay
/// observable.** It cannot be made to. The claim had to change instead, and the shape it changed
/// into is `BYOKCleanupProvider`'s: BYOK is not an *exception* to the zero-network test, it is
/// **unreachable in the default configuration** — so the test stays true *and verifiable* rather
/// than true-with-a-footnote. The transport takes the same shape. See the entry's own comment on
/// ``filesPermittedToNameATransport``, which is where the answer lives.
///
/// ## That day came again: `shell-provider`, 2026-09-22
///
/// The second entry is the shell executor, and it owes the same answer and a harsher version
/// of it: **a shell child is even less observable than an MCP child.** The MCP child was one
/// blind hop; a shell child is the same hop with a shell in front of it, and the restricted
/// child purges `DYLD_*` from the environment it passes on, so the interposer cannot see the
/// shell's egress or anything the shell spawns behind it. Nothing at this layer changes that
/// — so the claim narrows in writing exactly as it did before: **the default configuration
/// cannot create a shell child either.** The provider is not wired into the shipped
/// composition, so the probe never reaches a spawn. See the entry's own comment for the full
/// record — and the two tests this widening ships with: the set pin and the pending-entry
/// record, below.
///
/// ## Forbidden families
///
/// `URLSession`, `NW`, `Network`, `Process`, `posix_spawn`, `NSTask`, `system` — the two doors
/// out of the process (a socket opened here, a child spawned to open one elsewhere), as
/// identifier *prefix* families in the ``ModelDownloaderSeamTests`` shape.
///
/// Exactly **two** files under `Sources/VoccaActions/` may name any of them — the stdio
/// transport and the shell executor, and nothing else. The prohibition therefore has three
/// legs now, where an empty permitted set needed only one:
///
/// - **(a)** no *unpermitted* file names a family;
/// - **(b)** every *existing* permitted file **does** name one — which stopped being vacuous
///   the day the set gained its first entry, and is the ``ModelDownloaderSeamTests`` leg: a
///   permitted file that no longer names `Process` means the spawn moved somewhere this lint
///   cannot see, and the one-sided check that nothing else names it would pass while the
///   confinement was gone;
/// - **(c)** every permitted path that exists was actually scanned — a permitted entry pointing
///   at a deleted or moved file permits nothing and hides that it permits nothing.
///
/// Both entries are **live**: each names a file that exists. A permitted entry that names a
/// file which does not exist yet is a **pending** entry, permitting nothing — that vacuity was
/// recorded rather than passed over while the shell executor was pending, and the record died
/// with the file: the moment `Execution/ShellExecutor.swift` landed, legs (b) and (c) began to
/// apply to the entry.
///
/// The vacuity is closed from the other side as well: the scanned file list is asserted non-empty,
/// every scanned file is asserted to exist, and scanning nothing throws
/// (``testScanningNothingFailsRatherThanPassing``).
///
/// ## Two traps this module makes likely, and how each is resolved
///
/// **(a) `system` is a substring of `FileSystem`.** This module ships
/// `Audit/ActionAuditFileSystem.swift`, and `ActionAuditFileSystem` / `FileSystemActionAuditStore`
/// run through all three of its files. A substring or case-insensitive match would fire on every
/// one of them and the lint would be unusable on day one. The match is therefore anchored to an
/// **identifier start** (`\b` before a family that begins with a word character) and is
/// **case-sensitive**, so `FileSystem` — where `System` sits mid-identifier and capitalised — is
/// not a sighting. That is asserted against a sample *and* against the shipped file itself, in
/// ``testTheFileSystemFamilyIsNotASystemSighting`` and
/// ``testTheShippedFileSystemSeamFileIsNotASighting``, rather than hoped for.
///
/// **(b) `Process` prefixes ordinary words.** `Processing` and `Processor` match the family and
/// are **deliberately kept as sightings**. This is the same prefix-family shape that makes
/// `URLSession` catch `URLSessionConfiguration`, and the asymmetry of the two errors decides it: a
/// lint that misses `Process(` is worthless, while one that also flags `Processing` costs a
/// rename. The decision is pinned by ``testTheProcessFamilyDeliberatelyCatchesPrefixedWords`` so
/// that a future reader finds a recorded choice rather than an accident — and so that anyone
/// narrowing the family has to delete an assertion that says why not to. Lowercase `processed` /
/// `processing` are **not** sightings, because the families are case-sensitive; that is the
/// bound on the false-positive cost, and it is pinned in the same test.
///
/// ## Why `VoccaCore/Actions/` is out of scope — resolved, do not re-open
///
/// The spec asked whether the prohibition should also cover the seam in `VoccaCore/Actions/`.
/// **No, and the reason is structural rather than a judgement call.** `VoccaCore`'s import
/// allow-list is **empty** (`Tests/HarnessTests/CoreBoundaryTests.swift:116`) — not even
/// Foundation. `URLSession`, `Process` and `NSTask` are Foundation; `NW*` is Network.framework;
/// `posix_spawn` and `system` are Darwin. Every forbidden family is unreachable there because
/// `CoreBoundaryTests` already fails on *any* import at all, transitively. A second lint would
/// assert something a strictly stronger check already guarantees, and would carry its own
/// maintenance for no coverage. `Sources/VoccaNetworkProbe/` is out of scope too: its
/// `ActionAuditDrive.swift` names the action vocabulary but is the probe, not the module.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name the families to explain what
/// is forbidden — the comment you are reading now is the most transport-naming text in the
/// repository and must not trip its own lint, which is asserted in
/// ``testThisFilesOwnRationaleCommentDoesNotTripTheLint``. It is **not** string-literal aware
/// (see ``SwiftSourceScanner``), so an identifier inside a literal would be reported; the planted
/// samples below live in literals and are the reason this file is not itself in the scan root.
/// Neither limit matters for the claim: a *type or call in code* cannot appear under
/// `Sources/VoccaActions/` without a reviewed edit here.
final class ActionTransportProhibitionTests: XCTestCase {

    // MARK: - The prohibition

    /// The module this lint governs, relative to `Sources/`.
    private static let moduleDirectory = "VoccaActions"

    /// The forbidden identifier families.
    ///
    /// Two doors out of the process, and both are closed: a socket opened here (`URLSession`,
    /// `NW`, `Network`) and a child spawned to open one elsewhere (`Process`, `posix_spawn`,
    /// `NSTask`, `system`) — the second being the one the interposer goes blind through, which is
    /// the whole of D2 above.
    private static let forbiddenFamilies = [
        "URLSession", "NW", "Network", "Process", "posix_spawn", "NSTask", "system",
    ]

    /// Files permitted to name a forbidden family, relative to `Sources/`. **Exactly two**, and
    /// each entry is the reviewed edit this lint exists to force.
    ///
    /// ## The answer to D2, which this entry owes the review
    ///
    /// The question was: *how does the spawned transport stay observable when
    /// `DYLD_INSERT_LIBRARIES` does not survive the hop?*
    ///
    /// **It does not. The child is not observable, and no mitigation makes it so.** Measured in
    /// the C13 slice-1 dig: a restricted child ignores `DYLD_INSERT_LIBRARIES` *and purges
    /// `DYLD_*` from the environment it passes on*, so `/usr/bin/env node server.js`, any shell
    /// wrapper and any Apple platform binary are **blind** to the interposer. One hop launders the
    /// insertion for the entire descendant tree. There is nothing to add here that would change
    /// that, and an answer claiming otherwise would be claiming something measurably false.
    ///
    /// **So the claim is not "we watch it" — it is that the DEFAULT CONFIGURATION CANNOT CREATE
    /// ONE.** No server is configured out of the box, so the probe never reaches a spawn and the
    /// zero-network assertion stays true *and verifiable*: there is no child for it to be blind
    /// to. The transport declares `spawnsSubprocess = true` so a composition root folds the fact
    /// rather than remembering it, constructing it spawns nothing, and
    /// `StdioMCPTransportTests.testNothingOutsideTheTransportFileConstructsTheStdioTransport`
    /// asserts that nothing under `Sources/` outside the transport's own file names the type. A
    /// *configured* server is a trust the user extends to **that server's author**, stated in the
    /// docs rather than implied away.
    ///
    /// This is the `BYOKCleanupProvider` precedent, and it is the reason this entry is admissible
    /// at all: **BYOK is not an exception to the zero-network test — it is unreachable by
    /// default.** A sentence that survives a `PROBE-*` run because the code path was never reached
    /// is worth more than a sentence that survives because an exception was written for it.
    ///
    /// ## The second entry: `shell-provider`, 2026-09-22 — D2 answered for a shell child
    ///
    /// The first entry warned what a second would cost, and it was right: two files that may
    /// each spawn are two places the review has to be repeated and one place it will not be.
    /// The second entry is nevertheless made, because the shell provider needs `Process` and
    /// the alternative — an exception to the lint — is the one thing that costs more than the
    /// second review. The answer the entry owes is D2 asked of a *shell* child, and it is the
    /// first answer, harsher:
    ///
    /// **A shell child is even less observable than an MCP child.** The MCP child was one blind
    /// hop; the shell child is the same hop with a shell in front of it, and the blindness is
    /// inherited — the restricted child purges `DYLD_INSERT_LIBRARIES` from the environment it
    /// passes on, so the zero-network interposer cannot see a shell child's egress, nor
    /// anything the shell spawns behind it. There is no mitigation at this layer, and an answer
    /// claiming one would be claiming something measurably false.
    ///
    /// **So the claim narrows in writing exactly as it did for the transport: the DEFAULT
    /// CONFIGURATION CANNOT CREATE A SHELL CHILD.** The provider is not wired into the shipped
    /// composition, so the probe never reaches a spawn and the zero-network assertion stays
    /// true *and verifiable*: there is no child for it to be blind to. Configuring a shell
    /// command is the same trust extended to the command's author, stated in the docs rather
    /// than implied away.
    ///
    /// And what the lint still does is unchanged: **reaching for `Process` anywhere else is a
    /// reviewed edit.** Leg (a) still fails any third file, and this widening ships a planted
    /// control that proves it against the real scan —
    /// ``testAPlantedThirdFileNamingAProcessFamilyStillFailsTheLint``. The entry landed
    /// **with its file**: `Execution/ShellExecutor.swift` exists, so the vacuity the widening
    /// briefly carried is gone and legs (b) and (c) and the count equality now apply to it —
    /// the entry stopped being a promise and became a confinement the day the executor shipped.
    private static let filesPermittedToNameATransport: Set<String> = [
        "VoccaActions/MCP/StdioMCPTransport.swift",
        "VoccaActions/Execution/ShellExecutor.swift",
    ]

    /// Every occurrence of a forbidden family in `source`, comments removed first.
    ///
    /// A pure function over a string — never re-implemented per call site — so it can be run
    /// against source that violates the rule, which is the only way to know it would catch one.
    /// See ``testTheLintDetectsPlantedTransports``.
    ///
    /// The alternation is sorted **longest first** so that a family which is a prefix of another
    /// cannot shadow it: without this, `NW` would be tried before `Network` and the reported
    /// identifier would depend on table order rather than on the text.
    static func transportIdentifiers(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let alternatives = forbiddenFamilies
            .sorted { ($0.count, $0) > ($1.count, $1) }
            .joined(separator: "|")
        let pattern = "\\b(" + alternatives + ")[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    // MARK: - Roots

    private func packageRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath)
    }

    private func sourcesRoot() throws -> URL {
        try packageRoot().appendingPathComponent("Sources")
    }

    private func moduleRoot() throws -> URL {
        try sourcesRoot().appendingPathComponent(Self.moduleDirectory)
    }

    /// A scanned file's path as the permitted set spells it: **relative to `Sources/`**, so an
    /// entry reads `VoccaActions/MCP/…` and says which module it permits.
    ///
    /// Module-relative keys would have read `MCP/…`, which names a directory that exists in more
    /// than one module and would make a permitted entry ambiguous the day a second module grew a
    /// transport lint of its own.
    private func relativeToSources(_ file: URL) throws -> String {
        let sources = try sourcesRoot().path
        guard file.path.hasPrefix(sources + "/") else { return file.path }
        return String(file.path.dropFirst(sources.count + 1))
    }

    /// Every sighting under `root`, keyed by path relative to `root`, plus the files scanned.
    ///
    /// Throws rather than returning an empty dictionary when the directory is missing or holds no
    /// Swift files: "no file names a transport" and "no file was read" are the same green and must
    /// not be.
    private func scan(under root: URL) throws -> (sightings: [String: [String]], scanned: [URL]) {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ActionTransportTestError.moduleDirectoryMissing(expectedAt: root.path)
        }
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw ActionTransportTestError.noSwiftFilesScanned(under: root.path)
        }

        var byFile: [String: [String]] = [:]
        for file in files {
            let relative = try relativeToSources(file)
            let source = try String(contentsOf: file, encoding: .utf8)
            let identifiers = Self.transportIdentifiers(inSource: source)
            if !identifiers.isEmpty {
                byFile[relative] = identifiers
            }
        }
        return (byFile, files)
    }

    /// The prohibition itself, in three legs: no unpermitted file names a forbidden family, every
    /// permitted file still does, every permitted path is real — and the scan was not vacuous.
    ///
    /// Legs (a) and (b) are independent claims and neither is sufficient alone, which is the same
    /// reasoning ``ModelDownloaderSeamTests`` records: "nothing else names `Process`" passes if
    /// the permitted file lost its implementation too (a spawn that moved, invisibly), and "the
    /// permitted file names `Process`" passes if three files do (a confinement that has sprung a
    /// leak).
    func testNoFileInVoccaActionsMayNameATransportOrSubprocessFamily() throws {
        let root = try moduleRoot()
        let result = try scan(under: root)

        XCTAssertFalse(
            result.scanned.isEmpty,
            "the scanned file list must be non-empty — scanning no file passes 'no file names a "
                + "transport' vacuously, which is the only way this lint can lie")
        for file in result.scanned {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: file.path),
                "every scanned file must exist — a file read out from under the scan passes "
                    + "vacuously: \(file.path)")
        }

        let permitted = Self.filesPermittedToNameATransport
        let scannedRelative = Set(try result.scanned.map { try relativeToSources($0) })

        // Leg (a): nothing outside the permitted set names a family.
        let offenders = result.sightings.filter { !permitted.contains($0.key) }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            a transport or subprocess family is named inside VoccaActions: \
            \(offenders.mapValues { $0.sorted() }.sorted { $0.key < $1.key }).
            Loopback counts as network in the interposer, and a spawned child runs outside it \
            entirely — see this file's documentation for D2 before making this pass. Widening \
            the permitted set is a reviewed edit that owes the review an answer to D2, not a \
            formatting change; there are exactly two entries — the stdio transport and the \
            shell executor — and a spawn anywhere else is a confinement that has sprung a leak.
            """)

        // Legs (b) and (c): every permitted entry names one and was actually scanned — both
        // entries are live now; the shell executor's pending period ended when its file landed.
        for file in permitted.sorted().filter(scannedRelative.contains) {
            // Leg (b): every existing permitted file still names one. Vacuous until the set
            // gained its first entry; the whole point of the entry is that this leg watches
            // something.
            XCTAssertFalse(
                result.sightings[file]?.isEmpty ?? true,
                """
                \(file) is permitted to name a transport or subprocess family and names none. \
                Either the spawn moved somewhere this lint cannot see — which is the failure this \
                permission exists to make visible — or the permission has outlived its reason and \
                should be removed rather than kept as a standing exception.
                """)

            // Leg (c): every existing permitted path is real and was actually scanned. A
            // permission pointing at a moved file permits nothing, and hides that it permits
            // nothing.
            XCTAssertTrue(
                scannedRelative.contains(file),
                """
                the permitted path \(file) was not among the scanned files. A permitted entry \
                that names nothing real is an exception nobody can find and nobody reviews.
                """)
        }

        // Exactly the *live* permitted entries may name a family — both are live now.
        XCTAssertEqual(
            result.sightings.count, permitted.intersection(scannedRelative).count,
            "exactly the live permitted entries may name a transport or subprocess family, got "
                + "\(result.sightings.keys.sorted())")
    }

    // MARK: - The permitted set

    /// The permitted set holds **exactly the two reviewed entries**, spelled exactly.
    ///
    /// This is the assertion the reviewed-edit mechanism rests on: changing the set — widening,
    /// narrowing, retyping a path — is a change to this file and to this list. A typo that
    /// points at a file that never existed would otherwise be indistinguishable from a
    /// deliberate entry, which is what leg (c) and this pin exist to make visible.
    func testThePermittedSetHoldsExactlyTheTwoReviewedEntries() {
        XCTAssertEqual(
            Self.filesPermittedToNameATransport,
            [
                "VoccaActions/MCP/StdioMCPTransport.swift",
                "VoccaActions/Execution/ShellExecutor.swift",
            ],
            """
            the permitted set must be exactly the two reviewed entries — the stdio transport \
            and the shell executor. Any change to the set is a reviewed edit and must land \
            here, in this assertion, with the D2 answer the entry owes.
            """)
    }

    /// The file that makes trap (a) live.
    ///
    /// Asserted to exist and to be scanned, because
    /// ``testTheFileSystemFamilyIsNotASystemSighting`` is theatre if the `FileSystem`-named types
    /// it defends against have been renamed away. A trap test must be watching something real.
    func testTheFileSystemNamedSeamFileIsStillInTheScan() throws {
        let root = try moduleRoot()
        let result = try scan(under: root)
        let relative = try result.scanned.map { try relativeToSources($0) }
        XCTAssertTrue(
            relative.contains("VoccaActions/Audit/ActionAuditFileSystem.swift"),
            """
            the FileSystem-named seam file is no longer in the scan: \(relative.sorted()).
            The `system`-inside-`FileSystem` trap test defends against types that this file \
            declares; if it has moved, re-point that test at wherever they live now rather than \
            leaving it guarding nothing.
            """)
    }

    /// Trap (a), against the shipped file rather than a sample: the real
    /// `ActionAuditFileSystem.swift` must produce no sighting.
    ///
    /// The sample-based test below proves the detector's *rule*; this one proves the rule holds
    /// against the actual text that motivated it, which is the claim a reviewer cares about.
    func testTheShippedFileSystemSeamFileIsNotASighting() throws {
        let url = try moduleRoot().appendingPathComponent("Audit/ActionAuditFileSystem.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            source.contains("FileSystem"),
            "the shipped file must still name FileSystem — otherwise this test watches nothing")
        XCTAssertEqual(
            Self.transportIdentifiers(inSource: source), [],
            "the shipped FileSystem seam must not read as a `system` sighting")
    }

    // MARK: - Vacuity

    /// Scanning nothing **fails**.
    ///
    /// The single most likely way for this lint to stop working is not a bad regex but a moved
    /// module: rename `Sources/VoccaActions/` and a scan that returned an empty dictionary would
    /// report "no file names a transport" forever. Both the missing directory and the
    /// directory-with-no-Swift-files cases are therefore driven here and must throw.
    func testScanningNothingFailsRatherThanPassing() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vocca-transport-lint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        XCTAssertThrowsError(
            try scan(under: empty),
            "a directory with no Swift files must throw — an empty result is the vacuous green")

        let missing = empty.appendingPathComponent("does-not-exist")
        XCTAssertThrowsError(
            try scan(under: missing),
            "a missing module directory must throw — a moved module must break this lint loudly")
    }

    // MARK: - Planted controls

    /// The lint's negative control: planted source is caught, and the exact identifiers are named.
    ///
    /// A lint that has only ever seen a clean tree is a lint nobody has watched work. Both doors
    /// out of the process are planted so that **every** family is observed firing at least once:
    /// the socket families here, the subprocess families in
    /// ``testTheLintDetectsPlantedSubprocessFamilies``.
    func testTheLintDetectsPlantedTransports() {
        let source = """
            import Foundation
            import Network

            struct Leak {
                let client = URLSession.shared
                var config: URLSessionConfiguration { .default }
                let connection: NWConnection? = nil
                func spawn() { _ = Process() }
            }
            """
        XCTAssertEqual(
            Self.transportIdentifiers(inSource: source),
            ["Network", "URLSession", "URLSessionConfiguration", "NWConnection", "Process"],
            """
            the detector must find every planted family in order, including the prefix members \
            (`URLSessionConfiguration`) the family rule exists to cover and the `NW` type that \
            `Network` must not shadow.
            """)
    }

    /// The other half of the planted control: the subprocess families, which are the ones D2 is
    /// actually about — the interposer follows a socket and goes blind through a child.
    func testTheLintDetectsPlantedSubprocessFamilies() {
        let source = """
            import Darwin

            func run() {
                var pid: pid_t = 0
                _ = posix_spawn(&pid, "/bin/sh", nil, nil, nil, nil)
                _ = NSTask()
                _ = system("node server.js")
            }
            """
        XCTAssertEqual(
            Self.transportIdentifiers(inSource: source),
            ["posix_spawn", "NSTask", "system"],
            "every subprocess family must be watched firing — these are the D2 families")
    }

    /// The widening's own control: a **third** file naming a subprocess family still fails.
    ///
    /// A widening that weakened the lint would be invisible in the clean tree — nothing else
    /// names a family, so leg (a) would have nothing to trip on and the suite would stay green.
    /// So a real file is planted in the module and the **real scan** is run against it: the
    /// widened permitted set must still report the planted file as an offender. This is the
    /// string-level controls' end-to-end counterpart — it exercises the actual scan of the
    /// actual module with the actual permitted set, and it is what "the widening did not
    /// weaken leg (a)" means rather than hopes.
    ///
    /// The probe is planted **at the module root, in its own uniquely named file**, and only
    /// that file is removed afterwards. The widening's first draft planted it in
    /// `Execution/` and removed the directory — which was safe while `Execution/` held nothing
    /// real, and destructive from the day the executor's files landed there: the cleanup would
    /// have deleted the very confinement this control exists to guard.
    func testAPlantedThirdFileNamingAProcessFamilyStillFailsTheLint() throws {
        let root = try moduleRoot()
        let planted = root.appendingPathComponent("LintPlantedProbe.swift")
        defer { try? FileManager.default.removeItem(at: planted) }
        try """
            import Foundation

            struct LintPlantedProbe {
                func run() { _ = Process() }
            }
            """.write(to: planted, atomically: true, encoding: .utf8)

        let relative = try relativeToSources(planted)
        XCTAssertFalse(
            Self.filesPermittedToNameATransport.contains(relative),
            "the planted file must not be a permitted entry, or this control watches nothing")

        let result = try scan(under: root)
        XCTAssertEqual(
            result.sightings[relative], ["Process"],
            "the widened lint must still see the planted file's Process: \(result.sightings)")

        let offenders = result.sightings.filter {
            !Self.filesPermittedToNameATransport.contains($0.key)
        }
        XCTAssertTrue(
            offenders.keys.contains(relative),
            """
            leg (a) must still fail for a third file: the offenders \(offenders.keys.sorted()) \
            do not include the planted \(relative). The widening must not have made unpermitted \
            sightings permissible.
            """)
    }

    // MARK: - Trap (a): `system` inside `FileSystem`

    /// `FileSystem` is not a `system` sighting.
    ///
    /// The sample is the module's real vocabulary. A substring match or a case-insensitive one
    /// would report four sightings here and the lint would have been disabled the day it landed;
    /// the identifier-start anchor and case sensitivity are what make it usable, and this is the
    /// test that says so out loud rather than leaving it to be rediscovered.
    func testTheFileSystemFamilyIsNotASystemSighting() {
        let source = """
            import Foundation

            public protocol ActionAuditFileSystem: Sendable {
                func createDirectory(at path: String) throws
            }

            public struct FileSystemActionAuditStore {
                private let fileSystem: any ActionAuditFileSystem
            }
            """
        XCTAssertTrue(
            source.contains("FileSystem"),
            "the sample must still name FileSystem — otherwise this trap test watches nothing")
        XCTAssertEqual(
            Self.transportIdentifiers(inSource: source), [],
            """
            `system` must be matched only at an identifier start and case-sensitively: \
            `FileSystem`, `ActionAuditFileSystem`, `FileSystemActionAuditStore` and `fileSystem` \
            are the module's own vocabulary, not the C `system(3)` this family forbids.
            """)
    }

    // MARK: - Trap (b): `Process` as a prefix of ordinary words

    /// The recorded decision on trap (b): the `Process` family **is** a prefix family, and
    /// `Processing` / `Processor` are sightings on purpose.
    ///
    /// Kept deliberately, not by oversight. `Process` catching `Processing` is the same rule that
    /// makes `URLSession` catch `URLSessionConfiguration`, and the two possible errors are not
    /// symmetric: missing `Process(` defeats the lint entirely, while flagging `Processing` costs
    /// a rename and a permitted-set comment. Narrowing the family means deleting this assertion,
    /// which is the point — the narrowing should have to argue with a recorded decision.
    ///
    /// The second half bounds the cost: the families are case-sensitive, so lowercase `processed`
    /// and `processing` are not sightings and ordinary local names are untouched. `AudioProcessor`
    /// is not a sighting either, because the match is anchored to an identifier start.
    func testTheProcessFamilyDeliberatelyCatchesPrefixedWords() {
        let flagged = """
            struct Processor {
                var state: Processing?
                func spawn() { _ = Process() }
            }
            """
        XCTAssertEqual(
            Self.transportIdentifiers(inSource: flagged),
            ["Processor", "Processing", "Process"],
            """
            the Process family is a prefix family on purpose — `Processing` and `Processor` are \
            accepted false positives, because a lint that misses `Process(` is worthless while \
            one that flags `Processing` costs a rename.
            """)

        let notFlagged = """
            struct AudioProcessor {
                func processed(_ frames: [Float]) -> [Float] { frames }
                var processing = false
            }
            """
        XCTAssertEqual(
            Self.transportIdentifiers(inSource: notFlagged), [],
            """
            the false positive is bounded: the match is case-sensitive and anchored to an \
            identifier start, so lowercase `processed` / `processing` and the mid-identifier \
            `Processor` in `AudioProcessor` are not sightings.
            """)
    }

    // MARK: - Comment-strip controls

    /// A doc comment may name every forbidden family — which is what lets this file document what
    /// it forbids, and lets the module document it too.
    func testADocCommentNamingTheFamiliesDoesNotTripTheLint() {
        let source = """
            /// Forbidden here: `URLSession`, `NWConnection`, `Network`, `Process`,
            /// `posix_spawn`, `NSTask` and `system` — an MCP server on 127.0.0.1 over HTTP/SSE
            /// is a violation, and a spawned child is invisible to the interposer.
            /* Block form too: URLSession, Process, posix_spawn. */
            import Foundation
            """
        XCTAssertEqual(
            Self.transportIdentifiers(inSource: source), [],
            "comments must be stripped before the scan, in both line and block form")
    }

    /// The comment-strip control that is not hypothetical: **this file's own D2 rationale**.
    ///
    /// The type documentation above names `URLSession`, `Process`, `NSTask`, `posix_spawn` and
    /// `127.0.0.1`, which makes it the most transport-naming prose in the repository. If the lint
    /// tripped on its own explanation, the explanation would be the first thing deleted — and the
    /// explanation is the deliverable. So the file's preamble (licence, rationale, imports, up to
    /// the type declaration) is scanned and must be clean.
    ///
    /// The phrases are asserted **present first**, deliberately: a rationale that was trimmed
    /// away would make "the preamble is clean" pass for the wrong reason, and this control would
    /// stop watching exactly when the comment it guards had gone.
    func testThisFilesOwnRationaleCommentDoesNotTripTheLint() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        guard let declaration = source.range(of: "final class ActionTransportProhibitionTests")
        else {
            return XCTFail("could not locate this suite's declaration — the preamble is undefined")
        }
        let preamble = String(source[source.startIndex..<declaration.lowerBound])

        for phrase in ["URLSession", "Process", "NSTask", "posix_spawn", "127.0.0.1", "D2"] {
            XCTAssertTrue(
                preamble.contains(phrase),
                """
                the D2 rationale must still name \(phrase) — this control exists to prove the \
                rationale can be written, and a trimmed rationale would make it pass vacuously. \
                Restore the explanation rather than relaxing this assertion.
                """)
        }
        XCTAssertEqual(
            Self.transportIdentifiers(inSource: preamble), [],
            "this file's own rationale comment must not trip the lint it explains")
    }
}
