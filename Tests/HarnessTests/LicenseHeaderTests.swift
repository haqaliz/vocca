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

/// Raised when the license header scan cannot be evaluated meaningfully: the package root is
/// missing, or nothing was found to scan.
private enum LicenseHeaderTestError: Error, CustomStringConvertible {
    case packageRootNotFound(startingFrom: String)
    case noSourceFilesScanned(root: String)
    case scannedDirectoryMissing(name: String, expectedAt: String)

    var description: String {
        switch self {
        case .packageRootNotFound(let path):
            return "Could not locate Package.swift by walking up from \(path)"
        case .noSourceFilesScanned(let root):
            return
                "No covered source files were found under \(root) — the license header rule was not evaluated against anything"
        case .scannedDirectoryMissing(let name, let expectedAt):
            return """
                The scanned directory '\(name)' does not exist at \(expectedAt). Naming a \
                directory in `scannedDirectories` is what puts it under the licence rule, and a \
                name that resolves to nothing enforces nothing — the suite would stay green while \
                that directory's files went unchecked, or while the directory was moved somewhere \
                the rule does not reach. If it was deliberately removed, remove it from \
                `scannedDirectories` in the same change so the decision is visible in review.
                """
        }
    }
}

/// Enforces that every source file under `Sources/`, `Tests/` and `App/` (except the SwiftPM
/// manifest `Package.swift`, which must start with a `// swift-tools-version:` comment) begins
/// with the exact Apache-2.0 header block.
final class LicenseHeaderTests: XCTestCase {
    /// Directories scanned, relative to the package root.
    ///
    /// `App/` holds the Xcode app target's sources. It is outside the SwiftPM package, so it is
    /// invisible to every other harness suite — which is exactly why it has to be named here. The
    /// licence is a distribution obligation on shipped code, and `App/` is the only source in this
    /// repository that literally ships.
    private static let scannedDirectories = ["Sources", "Tests", "App"]

    /// File extensions the header rule applies to. C and headers are included because the
    /// package contains `.c`/`.h` sources; a `//`-comment header is valid in both.
    private static let coveredExtensions: Set<String> = ["swift", "c", "h"]

    private static let expectedHeader = """
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
        """

    /// Walks up from `filePath` until it finds the directory containing `Package.swift`, then
    /// returns that directory. Never hardcodes an absolute path. Mirrors
    /// `ModuleBoundaryTests.findSourcesRoot(from:)`.
    private func findPackageRoot(from filePath: String) throws -> URL {
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw LicenseHeaderTestError.packageRootNotFound(startingFrom: filePath)
    }

    private func sourceFiles(under root: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator
        where Self.coveredExtensions.contains(url.pathExtension) {
            results.append(url)
        }
        return results
    }

    /// Every covered source file under ``scannedDirectories``, excluding `Package.swift` (which is
    /// not under any of them, but is guarded against explicitly in case that changes).
    ///
    /// Each named directory must exist. `FileManager.enumerator` on a path that is not there
    /// yields nothing rather than failing, so a missing directory contributes zero files and the
    /// remaining ones keep the suite green — which is how listing `App` here could look like
    /// enforcement while enforcing nothing. Verified: moving `App/` aside left this suite 2/2.
    private func filesRequiringHeader() throws -> [URL] {
        let packageRoot = try findPackageRoot(from: #filePath)
        var files: [URL] = []
        for subdirectory in Self.scannedDirectories {
            let dir = packageRoot.appendingPathComponent(subdirectory)
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw LicenseHeaderTestError.scannedDirectoryMissing(
                    name: subdirectory, expectedAt: dir.path)
            }
            files.append(contentsOf: sourceFiles(under: dir))
        }
        files = files.filter { $0.lastPathComponent != "Package.swift" }

        guard !files.isEmpty else {
            throw LicenseHeaderTestError.noSourceFilesScanned(root: packageRoot.path)
        }
        return files
    }

    func testScansAtLeastOneFile() throws {
        let files = try filesRequiringHeader()
        XCTAssertGreaterThan(
            files.count, 0,
            "Expected to find at least one covered source file under Sources/ or Tests/, found none")
    }

    func testEverySourceFileStartsWithApacheLicenseHeader() throws {
        let files = try filesRequiringHeader()
        var offending: [String] = []
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            if !content.hasPrefix(Self.expectedHeader) {
                offending.append(file.path)
            }
        }
        XCTAssertTrue(
            offending.isEmpty,
            "The following files are missing the required Apache-2.0 license header: \(offending.sorted().joined(separator: ", "))"
        )
    }
}
