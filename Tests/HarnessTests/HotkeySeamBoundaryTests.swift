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
private enum HotkeySeamTestError: Error, CustomStringConvertible {
    case moduleDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .moduleDirectoryMissing(let expectedAt):
            return """
                The VoccaHotkey module directory does not exist at \(expectedAt). H7 is asserted by \
                scanning the source tree; if the adapter has moved or been renamed, this lint \
                enforces nothing.
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

/// Acceptance H7: **no CoreGraphics event type escapes the tap's implementation file.**
///
/// The seam is the reason this aspect is testable at all. `CGEvent.tapCreate` returns `nil` without
/// an Accessibility grant and no hosted runner can be granted one, so anything phrased in terms of
/// `CGEvent` is untestable *forever* rather than untested for now. `HotkeyEventSource` yields plain
/// `RawKeyEvent` values and the flag translation takes a `UInt64`, and that is what puts every
/// branch worth testing on the reachable side.
///
/// The rule is therefore not "`VoccaHotkey` may not speak CoreGraphics" — it is an adapter, it must
/// — but "exactly one file may". ``filesPermittedToNameEventTypes`` is that list, and it is
/// **empty** today because the tap adapter does not exist yet: the translation this phase adds
/// takes and returns integers and enum values only.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name `CGEventFlags` to explain what
/// it is translating — which the translation's does, at length, and should. It is not string-literal
/// aware (see ``SwiftSourceScanner``), so an event type inside a literal would be missed. Both are
/// deliberate trade-offs of a text scan; what matters is that a *type in code* cannot appear
/// without a reviewed edit to the list below.
final class HotkeySeamBoundaryTests: XCTestCase {

    /// Files allowed to name a CoreGraphics event type, relative to `Sources/`.
    ///
    /// **Empty.** When the tap adapter lands, its one file goes here — and nothing else ever does.
    /// A second entry means the seam has sprung a leak and the decision that leaked with it is now
    /// somewhere CI cannot reach.
    private static let filesPermittedToNameEventTypes: Set<String> = []

    /// The identifier prefixes that constitute the seam. `CGEvent` covers `CGEventFlags`,
    /// `CGEventTap`, `CGEventTapProxy`, `CGEventType`, `CGEventSource` and every other member of
    /// the family by construction, which is why this is a prefix rule and not a list of names
    /// somebody has to keep current.
    private static let forbiddenIdentifierPrefixes = ["CGEvent", "CFMachPort"]

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

    // MARK: - H7 against the real tree

    func testNoCoreGraphicsEventTypeEscapesIntoTheSourceTree() throws {
        let root = try sourcesRoot()
        let adapterDirectory = root.appendingPathComponent("VoccaHotkey")
        guard FileManager.default.fileExists(atPath: adapterDirectory.path) else {
            throw HotkeySeamTestError.moduleDirectoryMissing(expectedAt: adapterDirectory.path)
        }

        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw HotkeySeamTestError.noSwiftFilesScanned(under: root.path)
        }

        var sightings: [EventTypeSighting] = []
        for file in files {
            let relativePath = file.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !Self.filesPermittedToNameEventTypes.contains(relativePath) else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for identifier in Self.eventTypeIdentifiers(inSource: source) {
                sightings.append(EventTypeSighting(file: relativePath, identifier: identifier))
            }
        }

        XCTAssertEqual(
            sightings, [],
            """
            H7: a CoreGraphics event type is named outside the tap's implementation file. Found: \
            \(sightings.map(\.description).joined(separator: "; ")). Everything phrased in terms of \
            these types is unreachable from CI forever — tapCreate returns nil without an \
            Accessibility grant and TCC cannot be granted on a hosted runner. Move the logic above \
            the seam, or, if this genuinely is the tap adapter, add its path to \
            filesPermittedToNameEventTypes as a reviewed edit.
            """)
    }

    /// The lint's own vacuity guard, stated as a fact rather than assumed: files were scanned, and
    /// the file this phase actually added was one of them.
    func testTheScanReachesTheAdapterModuleItIsMeantToPolice() throws {
        let root = try sourcesRoot()
        let scanned = SwiftSourceScanner.swiftFiles(under: root)
            .map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }

        XCTAssertTrue(
            scanned.contains("VoccaHotkey/HotkeyFlagTranslation.swift"),
            """
            The flag translation was not among the \(scanned.count) files scanned. Either it has \
            been renamed and this lint no longer covers it, or the scan is not reaching \
            VoccaHotkey at all.
            """)
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
