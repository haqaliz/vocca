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

/// Raised when this suite's own scan of `Tests/` cannot be evaluated meaningfully.
private enum PackageRootConsolidationTestError: Error, CustomStringConvertible {
    case directoryMissing(name: String, expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .directoryMissing(let name, let expectedAt):
            return """
                Expected directory '\(name)' does not exist at \(expectedAt). This check cannot \
                tell "no walker copies here" from "nothing was scanned here" unless the directory \
                it is scanning actually exists.
                """
        case .noSwiftFilesScanned(let under):
            return
                "No .swift files were found under \(under) — this check was not evaluated against anything"
        }
    }
}

/// Guards the outcome of consolidating the package-root walk (see ``PackageRootLocator``): that
/// there is exactly **one** implementation of it reachable from `swift test`, plus the one
/// structurally-forced second copy in the Xcode-only bridge target.
///
/// Before consolidation there were five: one each in `LicenseHeaderTests`, `ModuleBoundaryTests`,
/// `ZeroNetworkTests`, `BundleConfigurationTests`, and `Tests/XcodeHarnessBridge/PackageSuiteBridge.swift`.
/// Five copies of a path walk every suite depends on is one silent divergence away from two
/// suites disagreeing about which tree they are linting — the previous aspect's review flagged
/// this and deferred it only until "a third appears". It has.
final class PackageRootConsolidationTests: XCTestCase {

    /// Every copy so far — including ``PackageRootLocator`` itself — wrote this exact loop line
    /// to walk upward from a file looking for `Package.swift`:
    ///
    ///     while dir.pathComponents.count > 1 {
    ///
    /// That is a distinctive enough fingerprint for "this function performs the package-root
    /// walk" without parsing Swift: nothing else in this repository has a variable named `dir`
    /// bounded by `.pathComponents.count`, and a reformatted walk that changed this line would be
    /// a rewrite of the algorithm, not an incidental style diff.
    private static let walkFingerprint = "while dir.pathComponents.count > 1 {"

    /// Counts fingerprint occurrences across every `.swift` file directly or transitively under
    /// `directory`, relative to the package root. Fails rather than returning zero silently if
    /// the directory is missing or empty of Swift sources, so a moved or deleted directory cannot
    /// make this check pass by scanning nothing.
    private func walkImplementationCount(under directory: String) throws -> Int {
        let root = try PackageRootLocator.find(from: #filePath).appendingPathComponent(directory)
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw PackageRootConsolidationTestError.directoryMissing(
                name: directory, expectedAt: root.path)
        }

        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw PackageRootConsolidationTestError.noSwiftFilesScanned(under: root.path)
        }

        var count = 0
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            for line in content.components(separatedBy: "\n")
            where line.trimmingCharacters(in: .whitespaces) == Self.walkFingerprint {
                count += 1
            }
        }
        return count
    }

    func testScansAtLeastOneSwiftFileInEachTestDirectory() throws {
        XCTAssertGreaterThan(try SwiftSourceScanner.swiftFiles(under: PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Tests/HarnessTests")).count, 0)
        XCTAssertGreaterThan(try SwiftSourceScanner.swiftFiles(under: PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Tests/XcodeHarnessBridge")).count, 0)
    }

    /// `Tests/HarnessTests` is built by `swift test` and may hold only the one canonical
    /// implementation, ``PackageRootLocator``.
    func testExactlyOnePackageRootWalkImplementationUnderHarnessTests() throws {
        let count = try walkImplementationCount(under: "Tests/HarnessTests")
        XCTAssertEqual(
            count, 1,
            """
            Expected exactly one implementation of the Package.swift upward walk under \
            Tests/HarnessTests (PackageRootLocator), found \(count). Every suite that needs the \
            package root must call PackageRootLocator.find(from:) rather than reimplementing the \
            walk.
            """)
    }

    /// `Tests/XcodeHarnessBridge` is a separate, Xcode-only compilation unit — not a target in
    /// `Package.swift`, so it has no module boundary through which it could import
    /// `PackageRootLocator`. Its own copy is structural, not an oversight, and is accounted for
    /// here explicitly rather than by loosening the HarnessTests count above.
    func testExactlyOnePackageRootWalkImplementationUnderXcodeHarnessBridge() throws {
        let count = try walkImplementationCount(under: "Tests/XcodeHarnessBridge")
        XCTAssertEqual(
            count, 1,
            """
            Expected exactly one implementation of the Package.swift upward walk under \
            Tests/XcodeHarnessBridge, found \(count). That target cannot import \
            PackageRootLocator (see PackageRootLocator's doc comment for why), so it is allowed \
            exactly one copy of its own — no more, no fewer.
            """)
    }
}
