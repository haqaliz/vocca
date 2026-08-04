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
    case scannedDirectoryMatchedNothing(name: String, extensions: [String], at: String)

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
                directory in `scanRules` is what puts it under the licence rule, and a \
                name that resolves to nothing enforces nothing — the suite would stay green while \
                that directory's files went unchecked, or while the directory was moved somewhere \
                the rule does not reach. If it was deliberately removed, remove it from \
                `scanRules` in the same change so the decision is visible in review.
                """
        case .scannedDirectoryMatchedNothing(let name, let extensions, let at):
            return """
                The scan rule for '\(name)' (\(at)) matched no files with any of the extensions \
                \(extensions.sorted().joined(separator: ", ")). The directory exists but the rule \
                is enforcing nothing, which is the same vacuous green as a missing directory — \
                and it is how a renamed extension (.sh -> .bash, .yml -> .yaml) would quietly \
                drop a whole directory out of the licence rule. Either the extension list is \
                wrong or the rule should be removed.
                """
        }
    }
}

/// One directory under the licence rule, the extensions it covers there, and the comment marker
/// those files use.
///
/// A single flat list of directories was not enough once the rule grew past Swift: shell scripts
/// and the CI workflow are shipped, reviewable source too, and they comment with `#`, not `//`.
private struct ScanRule {
    /// Path relative to the package root. May be nested (`.github/workflows`).
    let directory: String
    let extensions: Set<String>
    /// The line-comment marker the header is written with in these files.
    let commentMarker: String
}

/// Enforces that every source file under `Sources/`, `Tests/`, `App/`, `Scripts/` and
/// `.github/workflows/` (except the SwiftPM manifest `Package.swift`, which must start with a
/// `// swift-tools-version:` comment) begins with the exact Apache-2.0 header block.
final class LicenseHeaderTests: XCTestCase {
    /// Directories scanned, relative to the package root, with what is covered in each.
    ///
    /// `App/` holds the Xcode app target's sources. It is outside the SwiftPM package, so it is
    /// invisible to every other harness suite — which is exactly why it has to be named here. The
    /// licence is a distribution obligation on shipped code, and `App/` is the only source in this
    /// repository that literally ships.
    ///
    /// `Scripts/` and `.github/workflows/` were added because the rule was covering less than it
    /// appeared to. Every file in both already carried the header, or was expected to, with
    /// nothing checking — the licence rule stopped at the three Swift directories, so a new script
    /// could be added with no header and the suite would stay green. (`ci.yml` in fact had none.)
    /// Shell scripts that create code-signing identities and a workflow that defines what CI
    /// proves are as much a part of this project as its Swift is, and they are the files most
    /// likely to be copied out of it.
    private static let scanRules: [ScanRule] = [
        // C and headers are included because the package contains `.c`/`.h` sources; a
        // `//`-comment header is valid in both.
        ScanRule(directory: "Sources", extensions: ["swift", "c", "h"], commentMarker: "//"),
        ScanRule(directory: "Tests", extensions: ["swift", "c", "h"], commentMarker: "//"),
        ScanRule(directory: "App", extensions: ["swift", "c", "h"], commentMarker: "//"),
        ScanRule(directory: "Scripts", extensions: ["sh"], commentMarker: "#"),
        ScanRule(directory: ".github/workflows", extensions: ["yml", "yaml"], commentMarker: "#"),
    ]

    /// The header text, without a comment marker. Rendered per rule by ``expectedHeader(marker:)``.
    private static let headerLines = [
        "Copyright 2026 The Vocca Authors",
        "",
        "Licensed under the Apache License, Version 2.0 (the \"License\");",
        "you may not use this file except in compliance with the License.",
        "You may obtain a copy of the License at",
        "",
        "    http://www.apache.org/licenses/LICENSE-2.0",
        "",
        "Unless required by applicable law or agreed to in writing, software",
        "distributed under the License is distributed on an \"AS IS\" BASIS,",
        "WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.",
        "See the License for the specific language governing permissions and",
        "limitations under the License.",
    ]

    /// The header as it must appear in a file commented with `marker`. A blank header line is
    /// `marker` alone with no trailing space, which is what the files actually contain.
    private static func expectedHeader(marker: String) -> String {
        headerLines
            .map { $0.isEmpty ? marker : "\(marker) \($0)" }
            .joined(separator: "\n")
    }

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

    private func sourceFiles(under root: URL, extensions: Set<String>) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator where extensions.contains(url.pathExtension) {
            results.append(url)
        }
        return results
    }

    /// Every covered source file under ``scanRules``, paired with the header it must carry,
    /// excluding `Package.swift` (which is not under any scanned directory, but is guarded against
    /// explicitly in case that changes).
    ///
    /// Each named directory must exist, and each rule must match at least one file.
    /// `FileManager.enumerator` on a path that is not there yields nothing rather than failing, so
    /// a missing directory contributes zero files and the remaining ones keep the suite green —
    /// which is how listing `App` here could look like enforcement while enforcing nothing.
    /// Verified: moving `App/` aside left this suite 2/2. The per-rule non-empty check closes the
    /// same hole one level down, where the directory is present but its extension list has stopped
    /// matching anything in it.
    private func filesRequiringHeader() throws -> [(file: URL, expectedHeader: String)] {
        let packageRoot = try findPackageRoot(from: #filePath)
        var files: [(file: URL, expectedHeader: String)] = []

        for rule in Self.scanRules {
            let dir = packageRoot.appendingPathComponent(rule.directory)
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw LicenseHeaderTestError.scannedDirectoryMissing(
                    name: rule.directory, expectedAt: dir.path)
            }

            let matched = sourceFiles(under: dir, extensions: rule.extensions)
                .filter { $0.lastPathComponent != "Package.swift" }
            guard !matched.isEmpty else {
                throw LicenseHeaderTestError.scannedDirectoryMatchedNothing(
                    name: rule.directory, extensions: Array(rule.extensions), at: dir.path)
            }

            let header = Self.expectedHeader(marker: rule.commentMarker)
            files.append(contentsOf: matched.map { (file: $0, expectedHeader: header) })
        }

        guard !files.isEmpty else {
            throw LicenseHeaderTestError.noSourceFilesScanned(root: packageRoot.path)
        }
        return files
    }

    /// A shebang is permitted — and only a shebang — before the header. An executable script has
    /// no choice: `#!/bin/bash` must be the first line or the kernel will not use the interpreter.
    /// Anything else before the header is rejected, so this cannot become "the header appears
    /// somewhere near the top".
    private func bodyAfterOptionalShebang(_ content: String) -> String {
        guard content.hasPrefix("#!"), let newline = content.firstIndex(of: "\n") else {
            return content
        }
        return String(content[content.index(after: newline)...])
    }

    func testScansAtLeastOneFile() throws {
        let files = try filesRequiringHeader()
        XCTAssertGreaterThan(
            files.count, 0,
            "Expected to find at least one covered source file under the scanned directories, found none"
        )
    }

    func testEverySourceFileStartsWithApacheLicenseHeader() throws {
        let files = try filesRequiringHeader()
        var offending: [String] = []
        for (file, expectedHeader) in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            if !bodyAfterOptionalShebang(content).hasPrefix(expectedHeader) {
                offending.append(file.path)
            }
        }
        XCTAssertTrue(
            offending.isEmpty,
            "The following files are missing the required Apache-2.0 license header: \(offending.sorted().joined(separator: ", "))"
        )
    }
}
