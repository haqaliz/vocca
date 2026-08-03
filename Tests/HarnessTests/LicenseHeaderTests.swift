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
    case noSwiftFilesScanned(root: String)

    var description: String {
        switch self {
        case .packageRootNotFound(let path):
            return "Could not locate Package.swift by walking up from \(path)"
        case .noSwiftFilesScanned(let root):
            return
                "No .swift files were found under \(root) — the license header rule was not evaluated against anything"
        }
    }
}

/// Enforces that every `.swift` file under `Sources/` and `Tests/` (except the SwiftPM manifest
/// `Package.swift`, which must start with a `// swift-tools-version:` comment) begins with the
/// exact Apache-2.0 header block.
final class LicenseHeaderTests: XCTestCase {
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

    private func swiftFiles(under root: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            results.append(url)
        }
        return results
    }

    /// Every `.swift` file under `Sources/` and `Tests/`, excluding `Package.swift` (which is not
    /// under either directory, but is guarded against explicitly in case that ever changes).
    private func filesRequiringHeader() throws -> [URL] {
        let packageRoot = try findPackageRoot(from: #filePath)
        var files: [URL] = []
        for subdirectory in ["Sources", "Tests"] {
            let dir = packageRoot.appendingPathComponent(subdirectory)
            files.append(contentsOf: swiftFiles(under: dir))
        }
        files = files.filter { $0.lastPathComponent != "Package.swift" }

        guard !files.isEmpty else {
            throw LicenseHeaderTestError.noSwiftFilesScanned(root: packageRoot.path)
        }
        return files
    }

    func testScansAtLeastOneFile() throws {
        let files = try filesRequiringHeader()
        XCTAssertGreaterThan(
            files.count, 0,
            "Expected to find at least one .swift file under Sources/ or Tests/, found none")
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
