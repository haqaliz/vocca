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

    /// The complete list of products permitted to opt out of the shipping set by wearing a
    /// leading underscore.
    ///
    /// A **closed** vocabulary, deliberately. `shippingTargets` treats a leading underscore as
    /// "not API", and while that set was open, renaming a single product was enough to lift a real
    /// module out of the zero-network invariant: change `.library(name: "VoccaSpeech")` to
    /// `"_VoccaSpeech"`, stop driving it from the probe, add it to the exclusion list, and the
    /// suite went green with VoccaSpeech no longer covered at all. Two edited lines, one of them a
    /// single character. The round-3 "something must ship" guard only caught the version of that
    /// attack which underscored *every* product.
    ///
    /// Pinning it literally means a product can still be marked not-API — but not silently, and
    /// not by a contributor who is really just trying to make a coverage failure go away.
    static let permittedUnderscoredProducts: Set<String> = ["_VoccaNetworkInterposerTestFixture"]

    /// Targets that are part of something the package actually vends.
    ///
    /// Computed as the transitive closure of every product whose name does not begin with `_`,
    /// the Swift convention for "not API". That makes "does this ship?" a structural question
    /// about the manifest rather than a claim in a comment — which is what allows the coverage
    /// exclusion list in `ZeroNetworkTests` to be self-defending. The underscore vocabulary is
    /// closed by ``permittedUnderscoredProducts``, so opting out is not self-service.
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

    /// Target kinds the probe has no way to drive, and which therefore must be neither required
    /// nor able to consume a coverage exclusion.
    ///
    /// The distinction is "does this target contain code of *ours* that the probe can execute",
    /// not "is this importable" and not "is this important". Importability is the wrong test and
    /// saying it was importability made this list look wrong: a `system` target is perfectly
    /// importable — that is its entire purpose, it vends a module map over a library that is
    /// already on the machine — and it is on this list anyway. It belongs here because the module
    /// it vends is *not part of this package*. There is no Vocca source file in it, so there is
    /// nothing in it for the default-configuration path to run through and nothing the probe
    /// could drive even with a perfect `import`.
    ///
    /// The same reasoning covers the rest, by a different route: a `binary` target is a prebuilt
    /// `.xcframework` whose sources are not here, a `plugin` runs at build time in a separate
    /// process rather than inside the app, and a `macro` implementation runs inside the compiler.
    /// All four are reachable from a shipping product, so the exclusion guard correctly refuses to
    /// let them be excluded — but none can be exercised by the probe. Without this carve-out the
    /// guard becomes *unsatisfiable* for such a target: impossible to satisfy, impossible to
    /// exclude, and the cheapest way out for whoever hits it is to weaken the check. That is not
    /// hypothetical — `whisper.cpp` ships as an xcframework and is two capabilities away.
    ///
    /// These kinds are not a hole in the invariant. Code that *uses* one — the Swift wrapper
    /// around the xcframework, the module that imports the system library — lives in a regular
    /// target, and that target is still required to be driven.
    static let nonDrivableTargetTypes: Set<String> = ["binary", "plugin", "macro", "system"]

    /// Every target that could hold Swift code the probe can drive: not a test, and not one of the
    /// kinds above. Names are irrelevant to this — only the manifest's own `type` is used.
    var drivableTargetNames: Set<String> {
        Set(
            targets.values
                .filter { $0.type != "test" && !Self.nonDrivableTargetTypes.contains($0.type) }
                .map(\.name))
    }

    /// Targets the manifest declares that the probe cannot drive, by name.
    var nonDrivableTargetNames: Set<String> {
        Set(
            targets.values
                .filter { Self.nonDrivableTargetTypes.contains($0.type) }
                .map(\.name))
    }

    // MARK: - Loading

    static func load(packageRoot: URL) throws -> PackageManifest {
        // Created explicitly: `dump-package` builds nothing, so it never creates the directory
        // named by `--scratch-path`. Leaving that to SwiftPM meant the cleanup below failed on a
        // path that had never existed, and that failure surfaced in place of the real error —
        // which cost real time to diagnose during review. Creating it keeps cleanup silent and
        // keeps failures saying what actually went wrong.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-manifest-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
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

        let manifest = PackageManifest(targets: targets, products: products)

        // The same class of hole one level down, and the more dangerous one: the exclusion defence
        // is "you may not exclude a target that ships", enforced by testing membership of
        // `shippingTargets`. If that set is empty, *nothing* ships, so every exclusion is
        // permitted and the defence evaporates silently while the suite stays green. A package
        // that vends nothing is a bug in the manifest, not a licence to exclude everything.
        guard !manifest.shippingTargets.isEmpty else {
            throw PackageManifestError.noShippingTargets(productNames: products.keys.sorted())
        }

        // Checked before the manifest is handed out, because everything downstream trusts
        // "underscored means test-only" and that claim is only true while this set is closed.
        let unsanctioned = products.keys
            .filter { $0.hasPrefix("_") && !Self.permittedUnderscoredProducts.contains($0) }
            .sorted()
        guard unsanctioned.isEmpty else {
            throw PackageManifestError.unsanctionedUnderscoredProducts(names: unsanctioned)
        }
        return manifest
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
    case noShippingTargets(productNames: [String])
    case unsanctionedUnderscoredProducts(names: [String])

    var description: String {
        switch self {
        case .dumpFailed(let status, let stderr):
            return "`swift package dump-package` failed with status \(status): \(stderr)"
        case .malformedDump(let detail):
            return "Could not read `swift package dump-package` output: \(detail)"
        case .emptyManifest:
            return
                "`swift package dump-package` reported no targets or no products — refusing to check module coverage against an empty manifest"
        case .noShippingTargets(let productNames):
            return """
                No target in this package is reachable from a product whose name does not begin \
                with `_`, so the manifest says Vocca ships nothing. Declared products: \
                \(productNames.joined(separator: ", ")).
                This is refused rather than tolerated because the coverage exclusion guard is built \
                on "you may not exclude a target that ships" — with an empty shipping set every \
                exclusion would be permitted and the guard would pass while enforcing nothing. If \
                the package genuinely vends nothing, fix the manifest.
                """
        case .unsanctionedUnderscoredProducts(let names):
            return """
                These products are named with a leading underscore, which marks them as not-API \
                and removes them and their targets from the shipping set: \
                \(names.joined(separator: ", ")).
                Only \(PackageManifest.permittedUnderscoredProducts.sorted().joined(separator: ", ")) \
                may do that. Opting a product out of the shipping set also opts it out of the \
                zero-network invariant, which is not something a contributor may do silently — \
                renaming one product was enough to lift a whole module out of coverage. If the \
                product genuinely is a test fixture, add it to \
                `PackageManifest.permittedUnderscoredProducts` in the same change, so the decision \
                is visible in review.
                """
        }
    }
}
