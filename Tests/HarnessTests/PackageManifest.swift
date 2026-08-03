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

import Foundation

/// The package's own manifest, read authoritatively rather than guessed at.
///
/// `ZeroNetworkTests` needs to know which modules exist and which of them ship, in order to fail
/// when a new one is added without being covered. Deriving that from directory-name conventions
/// is what let a `Sources/KokoroTTS/` module slip through: the check keyed on a `Vocca` prefix,
/// and a plausible real module name that does not carry it was invisible. This type keys on the
/// manifest instead, which is the actual source of truth.
///
/// It is loaded by running `swift package dump-package` rather than by parsing `Package.swift`
/// as text, so the reading cannot drift from what SwiftPM itself believes.
///
/// **The isolated scratch path is required, not tidiness.** SwiftPM takes an exclusive lock on
/// `.build` for the duration of a command, and these tests run *inside* `swift test` — which
/// holds that lock until the test process exits. Measured: a plain `swift package dump-package`
/// blocks on `Another instance of SwiftPM ... is already running`, i.e. it would deadlock
/// against its own parent. With `--scratch-path` pointed at a temporary directory it returns in
/// ~0.2s.
struct PackageManifest {

    struct Target {
        let name: String
        /// `regular`, `executable`, `test`, ...
        let type: String
        let dependencies: [String]
    }

    struct Product {
        let name: String
        let targets: [String]
    }

    let targets: [String: Target]
    let products: [String: Product]

    /// Targets that are part of something the package actually vends.
    ///
    /// Computed as the transitive closure of every product whose name does not begin with `_`,
    /// the Swift convention for "not API". That makes "does this ship?" a structural question
    /// about the manifest rather than a claim in a comment — which is what allows the coverage
    /// exclusion list in `ZeroNetworkTests` to be self-defending.
    var shippingTargets: Set<String> {
        var reached: Set<String> = []
        var queue: [String] = products.values
            .filter { !$0.name.hasPrefix("_") }
            .flatMap(\.targets)

        while let next = queue.popLast() {
            guard !reached.contains(next) else { continue }
            reached.insert(next)
            queue.append(contentsOf: targets[next]?.dependencies ?? [])
        }
        return reached
    }

    /// Every target that is not a test target — i.e. every module that could contain product
    /// code, whatever it happens to be named.
    var nonTestTargetNames: Set<String> {
        Set(targets.values.filter { $0.type != "test" }.map(\.name))
    }

    // MARK: - Loading

    static func load(packageRoot: URL) throws -> PackageManifest {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-manifest-scratch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swift", "package",
            "--package-path", packageRoot.path,
            "--scratch-path", scratch.path,
            "dump-package",
        ]
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()

        // Read before waiting: `dump-package` emits more than a pipe buffer's worth of JSON, and
        // draining only after exit would deadlock on a full pipe.
        let jsonData = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(
            decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PackageManifestError.dumpFailed(
                status: process.terminationStatus, stderr: errorText)
        }

        guard
            let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let rawTargets = root["targets"] as? [[String: Any]],
            let rawProducts = root["products"] as? [[String: Any]]
        else {
            throw PackageManifestError.malformedDump(String(decoding: jsonData, as: UTF8.self))
        }

        var targets: [String: Target] = [:]
        for rawTarget in rawTargets {
            guard let name = rawTarget["name"] as? String,
                let type = rawTarget["type"] as? String
            else {
                throw PackageManifestError.malformedDump("target entry missing name/type")
            }
            targets[name] = Target(
                name: name, type: type,
                dependencies: parseDependencies(rawTarget["dependencies"] as? [[String: Any]] ?? []))
        }

        var products: [String: Product] = [:]
        for rawProduct in rawProducts {
            guard let name = rawProduct["name"] as? String,
                let productTargets = rawProduct["targets"] as? [String]
            else {
                throw PackageManifestError.malformedDump("product entry missing name/targets")
            }
            products[name] = Product(name: name, targets: productTargets)
        }

        // Fails closed. A parsing regression that yielded an empty manifest would make every
        // coverage check in ZeroNetworkTests pass against nothing, which is precisely the vacuous
        // green those checks exist to prevent.
        guard !targets.isEmpty, !products.isEmpty else {
            throw PackageManifestError.emptyManifest
        }
        return PackageManifest(targets: targets, products: products)
    }

    /// SwiftPM encodes a dependency as a single-key object, e.g. `{"byName": ["VoccaCore", null]}`
    /// or `{"target": [...]}` / `{"product": [...]}`. Only the leading string is the name.
    private static func parseDependencies(_ raw: [[String: Any]]) -> [String] {
        raw.compactMap { entry in
            guard let payload = entry.values.first as? [Any] else { return nil }
            return payload.first as? String
        }
    }
}

enum PackageManifestError: Error, CustomStringConvertible {
    case dumpFailed(status: Int32, stderr: String)
    case malformedDump(String)
    case emptyManifest

    var description: String {
        switch self {
        case .dumpFailed(let status, let stderr):
            return "`swift package dump-package` failed with status \(status): \(stderr)"
        case .malformedDump(let detail):
            return "Could not read `swift package dump-package` output: \(detail)"
        case .emptyManifest:
            return
                "`swift package dump-package` reported no targets or no products — refusing to check module coverage against an empty manifest"
        }
    }
}
