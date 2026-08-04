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

// MARK: - Why this file has two suites

/// macOS binds every TCC permission grant to a bundle identifier plus a code signature, so the
/// six facts asserted here are the difference between "the microphone works" and "the microphone
/// silently returns nothing, with no prompt and no error anywhere". Three of them are load-bearing
/// in exactly that way:
///
/// - `NSMicrophoneUsageDescription` present and non-empty,
/// - `com.apple.security.device.audio-input` in the entitlements,
/// - `com.apple.security.app-sandbox` **not** in the entitlements.
///
/// With hardened runtime on and the audio-input entitlement missing, `AVCaptureDevice` is denied
/// without ever prompting. A missing usage string fails the same silent way. Neither produces a
/// diagnostic, so a test is the only cheap way to find out.
///
/// Those facts live in two places that can disagree, and both are checked:
///
/// | Suite | Reads | Runs under `swift test`? |
/// |---|---|---|
/// | ``BundleConfigurationTests`` | `App/Info.plist`, `App/Vocca.entitlements`, `Vocca.xcodeproj/project.pbxproj` | always |
/// | ``BuiltBundleTests`` | the built `Vocca.app` and its embedded code signature | only when a bundle exists — see below |
///
/// The first suite is not a weaker copy of the second. It asserts the same six properties against
/// the files that *produce* the bundle **and** asserts the project wiring that makes those files
/// load-bearing (`INFOPLIST_FILE`, `CODE_SIGN_ENTITLEMENTS`, `GENERATE_INFOPLIST_FILE = NO`,
/// hardened runtime on, sandbox off). A correct `Info.plist` that Xcode never reads is precisely
/// the failure a source-only check would otherwise miss, so the wiring is checked too.
///
/// The second suite is the end-to-end confirmation: it reads the processed plist Xcode actually
/// emitted and the entitlements `codesign` actually embedded.
///
/// ## How the built-bundle suite is meant to be run
///
/// ```sh
/// xcodebuild -project Vocca.xcodeproj -scheme Vocca -configuration Debug \
///     -derivedDataPath .build/xcode build
/// swift test --filter BuiltBundleTests
/// ```
///
/// The `-derivedDataPath` is what makes the bundle findable: the suite looks in
/// `.build/xcode/Build/Products/*/Vocca.app` relative to the package root. `VOCCA_APP_BUNDLE=<path>`
/// overrides that for a bundle built somewhere else.
///
/// ## What happens when there is no bundle
///
/// A plain `swift test` on a machine that never ran `xcodebuild` **skips** this suite, because CI
/// deliberately does not build the Xcode project (that needs signing) and a hard failure would make
/// the suite red for everyone.
///
/// The skip is engineered not to be mistakable for a pass:
///
/// 1. it prints a multi-line banner to stderr naming the assertions that were **not** evaluated,
/// 2. `XCTSkip` reports the tests as skipped, not passed, in the run summary,
/// 3. setting `VOCCA_APP_BUNDLE` converts "no bundle" from a skip into a **failure**, so the
///    documented command above can never go green without measuring a real bundle,
/// 4. a bundle whose plist or entitlements disagree with the checked-in sources is a **failure**,
///    not a pass — a stale `.app` asserting yesterday's plist is the same vacuous green in slower
///    motion,
/// 5. and the six properties are never left unmeasured regardless, because
///    ``BundleConfigurationTests`` asserts every one of them and cannot skip.
private enum BundleTestSupport {

    static let expectedBundleIdentifier = "dev.vocca.Vocca"
    static let requiredEntitlement = "com.apple.security.device.audio-input"
    static let forbiddenEntitlements = [
        "com.apple.security.app-sandbox",
        "com.apple.security.cs.disable-library-validation",
    ]

    /// Environment variable naming an explicit `.app` to test. When set, a missing bundle is a
    /// failure rather than a skip.
    static let bundlePathVariable = "VOCCA_APP_BUNDLE"

    /// Derived-data location the documented `xcodebuild` invocation writes to, relative to the
    /// package root. Kept under `.build/` so `.gitignore` already covers it.
    static let conventionalDerivedData = ".build/xcode"

    /// Walks up from `filePath` to the directory containing `Package.swift`. Mirrors the other
    /// harness suites; never hardcodes an absolute path.
    static func packageRoot(from filePath: String = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path)
            {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw BundleTestError.packageRootNotFound(startingFrom: filePath)
    }

    static func readPropertyList(at url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BundleTestError.fileMissing(path: url.path, underlying: "\(error)")
        }
        guard
            let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else {
            throw BundleTestError.notADictionaryPropertyList(path: url.path)
        }
        return plist
    }
}

enum BundleTestError: Error, CustomStringConvertible {
    case packageRootNotFound(startingFrom: String)
    case fileMissing(path: String, underlying: String)
    case notADictionaryPropertyList(path: String)
    case projectUnreadable(path: String, detail: String)
    case targetNotFound(name: String, available: [String])
    case noBuildConfigurations(target: String)
    case codesignFailed(status: Int32, stderr: String)
    case entitlementsUnreadable(detail: String)

    var description: String {
        switch self {
        case .packageRootNotFound(let path):
            return "Could not locate Package.swift by walking up from \(path)"
        case .fileMissing(let path, let underlying):
            return "Could not read \(path): \(underlying)"
        case .notADictionaryPropertyList(let path):
            return "\(path) is not a dictionary property list"
        case .projectUnreadable(let path, let detail):
            return """
                Could not read \(path) as a property list: \(detail).
                This is a failure rather than a skip on purpose: an unreadable project file means \
                the bundle-configuration assertions were evaluated against nothing.
                """
        case .targetNotFound(let name, let available):
            return """
                No native target named '\(name)' in the Xcode project. Targets present: \
                \(available.sorted().joined(separator: ", ")).
                """
        case .noBuildConfigurations(let target):
            return """
                Target '\(target)' has no build configurations, so every build-setting assertion \
                below would have iterated over an empty collection and passed while checking \
                nothing.
                """
        case .codesignFailed(let status, let stderr):
            return "`codesign -d --entitlements` failed with status \(status): \(stderr)"
        case .entitlementsUnreadable(let detail):
            return "Could not parse the embedded entitlements: \(detail)"
        }
    }
}

// MARK: - Always-on: the sources of truth, and the wiring that makes them count

/// Asserts the six required bundle properties against the files that produce the bundle, plus the
/// Xcode build settings that make those files load-bearing.
///
/// This suite has no external requirement — no Xcode, no prior build, no network — so it runs on
/// every `swift test` and cannot skip.
final class BundleConfigurationTests: XCTestCase {

    private func infoPlist() throws -> [String: Any] {
        try BundleTestSupport.readPropertyList(
            at: try BundleTestSupport.packageRoot().appendingPathComponent("App/Info.plist"))
    }

    private func entitlements() throws -> [String: Any] {
        try BundleTestSupport.readPropertyList(
            at: try BundleTestSupport.packageRoot().appendingPathComponent("App/Vocca.entitlements")
        )
    }

    // MARK: Info.plist

    func testInfoPlistDeclaresTheFrozenBundleIdentifier() throws {
        let plist = try infoPlist()
        XCTAssertEqual(
            plist["CFBundleIdentifier"] as? String, BundleTestSupport.expectedBundleIdentifier,
            """
            CFBundleIdentifier must be '\(BundleTestSupport.expectedBundleIdentifier)'. macOS keys \
            TCC grants on the bundle identifier, so changing it after release silently revokes \
            every existing user's Microphone and Accessibility permission.
            """)
    }

    func testInfoPlistDeclaresANonEmptyMicrophoneUsageDescription() throws {
        let plist = try infoPlist()
        let usage = plist["NSMicrophoneUsageDescription"] as? String
        XCTAssertNotNil(
            usage,
            """
            NSMicrophoneUsageDescription is missing from App/Info.plist. Without it macOS denies \
            microphone access and never shows a prompt — the app receives silence and no error.
            """)
        XCTAssertFalse(
            (usage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            """
            NSMicrophoneUsageDescription is present but empty. An empty string is treated as \
            missing: the prompt has nothing to display and access is denied the same silent way.
            """)
    }

    func testInfoPlistMarksTheAppAsAnAgent() throws {
        let plist = try infoPlist()
        XCTAssertEqual(
            plist["LSUIElement"] as? Bool, true,
            """
            LSUIElement must be true. Vocca is a background agent with a floating widget; without \
            this the app takes a Dock icon and a menu bar, and stealing focus breaks text injection \
            into whatever app the user was actually typing in.
            """)
    }

    func testInfoPlistDeclaresTheRemainingRequiredBundleKeys() throws {
        let plist = try infoPlist()
        for key in [
            "CFBundleName", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion",
        ] {
            let value = plist[key] as? String
            XCTAssertNotNil(value, "App/Info.plist is missing \(key)")
            XCTAssertFalse((value ?? "").isEmpty, "App/Info.plist has an empty \(key)")
        }
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(
            plist["LSMinimumSystemVersion"] as? String, "15.0",
            "LSMinimumSystemVersion must match the package's .macOS(.v15) platform floor")
    }

    // MARK: Entitlements

    func testEntitlementsGrantAudioInput() throws {
        let entitlements = try entitlements()
        XCTAssertEqual(
            entitlements[BundleTestSupport.requiredEntitlement] as? Bool, true,
            """
            \(BundleTestSupport.requiredEntitlement) must be present and true. Under hardened \
            runtime — which this target enables — its absence makes macOS deny the microphone \
            *without prompting*: no dialog, no error, just silence.
            """)
    }

    func testEntitlementsOmitTheSandboxAndLibraryValidationOptOut() throws {
        let entitlements = try entitlements()
        for forbidden in BundleTestSupport.forbiddenEntitlements {
            XCTAssertNil(
                entitlements[forbidden],
                """
                \(forbidden) must not appear in App/Vocca.entitlements.
                app-sandbox would confine Vocca to a container and cut off the Accessibility API \
                and system-wide text injection the whole product depends on; \
                cs.disable-library-validation weakens the hardened runtime for no benefit Vocca \
                needs.
                """)
        }
    }

    func testEntitlementsFileContainsNothingElse() throws {
        let entitlements = try entitlements()
        XCTAssertEqual(
            Set(entitlements.keys), [BundleTestSupport.requiredEntitlement],
            """
            App/Vocca.entitlements must declare exactly one entitlement. Every additional \
            entitlement widens what the signed binary is permitted to do and must be argued for \
            individually, not inherited by accident.
            """)
    }

    // MARK: The wiring — Xcode must actually use those two files

    func testXcodeProjectUsesTheCheckedInPlistAndEntitlements() throws {
        let settings = try buildSettingsPerConfiguration()
        for (configuration, values) in settings {
            XCTAssertEqual(
                values["INFOPLIST_FILE"], "App/Info.plist",
                """
                Configuration '\(configuration)' does not point INFOPLIST_FILE at App/Info.plist, \
                so every assertion this suite makes about that file describes a file the build \
                ignores.
                """)
            XCTAssertEqual(
                values["CODE_SIGN_ENTITLEMENTS"], "App/Vocca.entitlements",
                """
                Configuration '\(configuration)' does not point CODE_SIGN_ENTITLEMENTS at \
                App/Vocca.entitlements, so the audio-input entitlement is never embedded and the \
                microphone fails silently at runtime.
                """)
            XCTAssertEqual(
                values["GENERATE_INFOPLIST_FILE"], "NO",
                """
                Configuration '\(configuration)' has GENERATE_INFOPLIST_FILE set to \
                '\(values["GENERATE_INFOPLIST_FILE"] ?? "<unset>")'. When YES, Xcode synthesises \
                its own Info.plist from INFOPLIST_KEY_* settings and the checked-in file stops \
                being the source of truth.
                """)
        }
    }

    func testXcodeProjectEnablesHardenedRuntimeAndLeavesTheSandboxOff() throws {
        let settings = try buildSettingsPerConfiguration()
        for (configuration, values) in settings {
            XCTAssertEqual(
                values["ENABLE_HARDENED_RUNTIME"], "YES",
                "Configuration '\(configuration)' must enable the hardened runtime")
            XCTAssertNotEqual(
                values["ENABLE_APP_SANDBOX"], "YES",
                """
                Configuration '\(configuration)' enables the app sandbox. Xcode injects \
                com.apple.security.app-sandbox into the signed entitlements when this is YES, even \
                though App/Vocca.entitlements does not mention it — which would sandbox Vocca \
                without a single line of the entitlements file changing.
                """)
        }
    }

    /// Release builds must carry exactly the entitlements `App/Vocca.entitlements` declares, and
    /// nothing Xcode decided to add.
    ///
    /// Measured, not assumed: `CODE_SIGN_IDENTITY = "-"` makes Xcode treat the build as a
    /// development signing and inject `com.apple.security.get-task-allow` — and it did so in
    /// **Release** as well as Debug, which is not the usual behaviour and is why this is asserted
    /// rather than trusted. That entitlement lets any process running as the same user attach a
    /// debugger and read the process's memory, which for Vocca means live transcripts; it is also
    /// rejected outright by notarization. `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` removes it, and
    /// the Release bundle then embeds the audio-input entitlement alone.
    ///
    /// Debug keeps the injection, deliberately — without `get-task-allow` no debugger can attach to
    /// a debug build at all.
    func testReleaseBuildsDoNotInheritInjectedDebugEntitlements() throws {
        let settings = try buildSettingsPerConfiguration()
        XCTAssertEqual(
            settings["Release"]?["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"], "NO",
            """
            The Release configuration must set CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO. With it \
            unset, Xcode injects com.apple.security.get-task-allow into the signed Release binary: \
            any same-user process can then attach a debugger and read whatever Vocca is holding, \
            which is exactly the audio and transcripts this project promises never leave the \
            machine under the user's control. Notarization rejects it too.
            """)
    }

    func testProductBundleIdentifierAgreesWithTheInfoPlist() throws {
        let settings = try buildSettingsPerConfiguration()
        for (configuration, values) in settings {
            XCTAssertEqual(
                values["PRODUCT_BUNDLE_IDENTIFIER"], BundleTestSupport.expectedBundleIdentifier,
                """
                Configuration '\(configuration)' declares a PRODUCT_BUNDLE_IDENTIFIER that differs \
                from the CFBundleIdentifier in App/Info.plist. The two are separate values that \
                both reach the signed product — Xcode signs and provisions against the build \
                setting — and letting them drift is how an app ends up signed under an identity \
                that has none of the user's TCC grants.
                """)
        }
    }

    // MARK: Project parsing

    /// Build settings for the `Vocca` native target, one dictionary per build configuration.
    ///
    /// `project.pbxproj` is an OpenStep property list, which `PropertyListSerialization` reads
    /// natively — so this is a structural read of the real project file, not a regex over its text,
    /// and it needs no Xcode installation. Anything unparseable throws rather than returning an
    /// empty result, and an empty configuration set throws too: iterating zero configurations would
    /// make every assertion above pass while checking nothing.
    private func buildSettingsPerConfiguration() throws -> [String: [String: String]] {
        let projectFile = try BundleTestSupport.packageRoot()
            .appendingPathComponent("Vocca.xcodeproj/project.pbxproj")

        let data: Data
        do {
            data = try Data(contentsOf: projectFile)
        } catch {
            throw BundleTestError.fileMissing(path: projectFile.path, underlying: "\(error)")
        }

        let root: [String: Any]
        do {
            guard
                let parsed = try PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any]
            else {
                throw BundleTestError.projectUnreadable(
                    path: projectFile.path, detail: "top level is not a dictionary")
            }
            root = parsed
        } catch let error as BundleTestError {
            throw error
        } catch {
            throw BundleTestError.projectUnreadable(
                path: projectFile.path, detail: "\(error)")
        }

        guard let objects = root["objects"] as? [String: [String: Any]] else {
            throw BundleTestError.projectUnreadable(
                path: projectFile.path, detail: "no 'objects' dictionary")
        }

        let nativeTargets = objects.filter { $0.value["isa"] as? String == "PBXNativeTarget" }
        guard
            let target = nativeTargets.first(where: { $0.value["name"] as? String == "Vocca" })?
                .value
        else {
            throw BundleTestError.targetNotFound(
                name: "Vocca",
                available: nativeTargets.compactMap { $0.value["name"] as? String })
        }

        guard
            let listIdentifier = target["buildConfigurationList"] as? String,
            let list = objects[listIdentifier],
            let configurationIdentifiers = list["buildConfigurations"] as? [String]
        else {
            throw BundleTestError.noBuildConfigurations(target: "Vocca")
        }

        var result: [String: [String: String]] = [:]
        for identifier in configurationIdentifiers {
            guard let configuration = objects[identifier],
                let name = configuration["name"] as? String
            else { continue }
            let raw = configuration["buildSettings"] as? [String: Any] ?? [:]
            result[name] = raw.compactMapValues { $0 as? String }
        }

        guard !result.isEmpty else {
            throw BundleTestError.noBuildConfigurations(target: "Vocca")
        }
        return result
    }
}

// MARK: - The built bundle itself

/// Asserts the same six properties against a real, built, signed `Vocca.app`: the processed
/// `Info.plist` Xcode emitted and the entitlements `codesign` embedded.
///
/// See the file header for how to run this and for exactly what happens when no bundle exists.
final class BuiltBundleTests: XCTestCase {

    // MARK: Locating the bundle

    private enum BundleLocation {
        case found(URL)
        /// No bundle, and none was demanded — skip, loudly.
        case absent(reason: String)
    }

    private func locateBundle() throws -> URL {
        switch try discoverBundle() {
        case .found(let url):
            return url
        case .absent(let reason):
            let banner = """

                ================================================================================
                SKIPPED: BuiltBundleTests — NO BUILT Vocca.app WAS FOUND. NOTHING WAS MEASURED.
                --------------------------------------------------------------------------------
                \(reason)

                These assertions were NOT evaluated against a bundle:
                  - CFBundleIdentifier == \(BundleTestSupport.expectedBundleIdentifier)
                  - NSMicrophoneUsageDescription present and non-empty
                  - LSUIElement == true
                  - entitlements contain \(BundleTestSupport.requiredEntitlement)
                  - entitlements omit \(BundleTestSupport.forbiddenEntitlements.joined(separator: ", "))
                  - hardened runtime is on in the embedded signature
                  - the bundle was built from the checked-in App/ sources
                  - no test-only target leaked into the bundle

                To run them:
                  xcodebuild -project Vocca.xcodeproj -scheme Vocca -configuration Debug \\
                      -derivedDataPath \(BundleTestSupport.conventionalDerivedData) build
                  swift test --filter BuiltBundleTests

                Set \(BundleTestSupport.bundlePathVariable)=/path/to/Vocca.app to test a bundle
                built elsewhere; with that variable set, a missing bundle FAILS instead of skipping.

                BundleConfigurationTests still asserted all six properties against
                App/Info.plist, App/Vocca.entitlements and Vocca.xcodeproj — this skip leaves the
                end-to-end confirmation unmeasured, not the properties themselves.
                ================================================================================

                """
            FileHandle.standardError.write(Data(banner.utf8))
            throw XCTSkip("No built Vocca.app found — see the banner above. \(reason)")
        }
    }

    private func discoverBundle() throws -> BundleLocation {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment[BundleTestSupport.bundlePathVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty
        {
            let url = URL(fileURLWithPath: explicit)
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Contents/Info.plist").path)
            {
                return .found(url)
            }
            // Deliberately a failure, not a skip: someone asked for a specific bundle by name.
            // Skipping here would let the documented run command report success having measured
            // nothing at all.
            XCTFail(
                """
                \(BundleTestSupport.bundlePathVariable) is set to '\(explicit)' but there is no \
                app bundle there (expected \(explicit)/Contents/Info.plist). Refusing to skip: an \
                explicitly named bundle that does not exist is a broken invocation, not an absent \
                optional dependency.
                """)
            throw BundleTestError.fileMissing(
                path: url.appendingPathComponent("Contents/Info.plist").path,
                underlying: "named by \(BundleTestSupport.bundlePathVariable)")
        }

        let productsRoot = try BundleTestSupport.packageRoot()
            .appendingPathComponent(BundleTestSupport.conventionalDerivedData)
            .appendingPathComponent("Build/Products")

        let configurations =
            (try? FileManager.default.contentsOfDirectory(
                at: productsRoot, includingPropertiesForKeys: nil)) ?? []
        let bundles = configurations
            .map { $0.appendingPathComponent("Vocca.app") }
            .filter {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("Contents/Info.plist").path)
            }
            .sorted { $0.path < $1.path }

        if let bundle = bundles.first {
            return .found(bundle)
        }
        return .absent(
            reason:
                "Looked for */Vocca.app under \(productsRoot.path) and found none, and \(BundleTestSupport.bundlePathVariable) is unset."
        )
    }

    // MARK: Staleness

    /// Fails when the bundle under test was built from a different `App/Info.plist` or
    /// `App/Vocca.entitlements` than the one currently checked in.
    ///
    /// A stale `.app` is the same vacuous green as no `.app`, only harder to notice: yesterday's
    /// bundle happily satisfies every assertion in this suite while today's plist is broken. Since
    /// the bundle is discovered rather than built, nothing else here would catch that.
    ///
    /// It compares *values*, not timestamps. An earlier version compared modification dates and was
    /// wrong in a way worth recording: Xcode's copy task is content-hashed, so touching
    /// `App/Info.plist` made the mtime check fail and a rebuild did **not** clear it — the file's
    /// content had not changed, so nothing was re-copied. A test that goes red and stays red
    /// through the fix it recommends teaches people to ignore it.
    func testBuiltBundleWasBuiltFromTheCheckedInSources() throws {
        let bundle = try locateBundle()
        let root = try BundleTestSupport.packageRoot()

        let source = try BundleTestSupport.readPropertyList(
            at: root.appendingPathComponent("App/Info.plist"))
        let built = try BundleTestSupport.readPropertyList(
            at: bundle.appendingPathComponent("Contents/Info.plist"))

        // Xcode adds build-provenance keys (DTXcode, BuildMachineOSBuild, ...), so this compares
        // the keys the source declares rather than the two dictionaries.
        for key in source.keys.sorted() {
            XCTAssertEqual(
                String(describing: built[key] ?? "<absent>"),
                String(describing: source[key] ?? "<absent>"),
                """
                The built bundle's \(key) does not match App/Info.plist, so the bundle under test \
                was produced from a different version of that file and everything this suite says \
                about it describes stale output. Rebuild:
                  xcodebuild -project Vocca.xcodeproj -scheme Vocca -configuration Debug \
                -derivedDataPath \(BundleTestSupport.conventionalDerivedData) build
                """)
        }

        let sourceEntitlements = try BundleTestSupport.readPropertyList(
            at: root.appendingPathComponent("App/Vocca.entitlements"))
        let embedded = try embeddedEntitlements(of: bundle)
        for key in sourceEntitlements.keys.sorted() {
            XCTAssertEqual(
                String(describing: embedded[key] ?? "<absent>"),
                String(describing: sourceEntitlements[key] ?? "<absent>"),
                """
                App/Vocca.entitlements declares \(key) but the signed bundle does not carry the \
                same value, so the bundle was signed from a different version of that file. \
                Rebuild before trusting the entitlement assertions in this suite.
                """)
        }
    }

    // MARK: Processed Info.plist

    func testBuiltBundleDeclaresTheFrozenBundleIdentifier() throws {
        let plist = try BundleTestSupport.readPropertyList(
            at: try locateBundle().appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(
            plist["CFBundleIdentifier"] as? String, BundleTestSupport.expectedBundleIdentifier,
            """
            The built bundle's CFBundleIdentifier is not \
            '\(BundleTestSupport.expectedBundleIdentifier)'. TCC grants are keyed on this string; \
            a change revokes every existing user's Microphone and Accessibility permission with no \
            warning and no way to migrate.
            """)
    }

    func testBuiltBundleDeclaresANonEmptyMicrophoneUsageDescription() throws {
        let plist = try BundleTestSupport.readPropertyList(
            at: try locateBundle().appendingPathComponent("Contents/Info.plist"))
        let usage = plist["NSMicrophoneUsageDescription"] as? String
        XCTAssertNotNil(
            usage,
            """
            The built bundle has no NSMicrophoneUsageDescription. macOS then denies the microphone \
            without ever prompting: no dialog, no error, no audio.
            """)
        XCTAssertFalse(
            (usage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "The built bundle's NSMicrophoneUsageDescription is empty, which macOS treats as absent")
    }

    func testBuiltBundleMarksTheAppAsAnAgent() throws {
        let plist = try BundleTestSupport.readPropertyList(
            at: try locateBundle().appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(
            plist["LSUIElement"] as? Bool, true,
            "The built bundle must set LSUIElement so Vocca runs as a background agent")
    }

    // MARK: Embedded entitlements

    func testBuiltBundleEmbedsTheAudioInputEntitlement() throws {
        let entitlements = try embeddedEntitlements(of: try locateBundle())
        XCTAssertEqual(
            entitlements[BundleTestSupport.requiredEntitlement] as? Bool, true,
            """
            The signed bundle does not carry \(BundleTestSupport.requiredEntitlement). Under \
            hardened runtime that means the microphone is denied with no prompt and no error — the \
            single most expensive silent failure this project can ship.
            Embedded entitlements were: \(entitlements.keys.sorted())
            """)
    }

    /// Checks the two forbidden entitlements are absent rather than checking the whole set for
    /// equality, because Xcode injects `com.apple.security.get-task-allow` into Debug builds so a
    /// debugger can attach. That one is legitimate and disappears in Release.
    /// ``BundleConfigurationTests.testEntitlementsFileContainsNothingElse`` is where the exact set
    /// is pinned, against the source file the build actually consumes.
    func testBuiltBundleDoesNotEmbedTheSandboxOrLibraryValidationOptOut() throws {
        let entitlements = try embeddedEntitlements(of: try locateBundle())
        for forbidden in BundleTestSupport.forbiddenEntitlements {
            XCTAssertNil(
                entitlements[forbidden],
                """
                The signed bundle carries \(forbidden), which App/Vocca.entitlements does not \
                declare — so a build setting injected it. Sandboxing cuts off the Accessibility \
                API and system-wide injection Vocca is built on.
                Embedded entitlements were: \(entitlements.keys.sorted())
                """)
        }
    }

    /// Asserts the `runtime` flag is actually in the embedded signature, which is a different
    /// claim from `ENABLE_HARDENED_RUNTIME = YES` in the project.
    ///
    /// They came apart in practice. With no codesigning identity on the machine Xcode falls back to
    /// ad-hoc signing and then **silently turns the hardened runtime back off**, emitting only
    /// `note: Disabling hardened runtime with ad-hoc codesigning` in a successful build log. The
    /// project said YES, the build said SUCCEEDED, and `codesign -d` reported `flags=0x2(adhoc)`
    /// with no `runtime`. `codesign` itself has no objection to an ad-hoc hardened binary — this is
    /// Xcode's own policy — so the target passes `--options=runtime` through
    /// `OTHER_CODE_SIGN_FLAGS`, after which the signature reads `flags=0x10002(adhoc,runtime)`.
    ///
    /// That override is why this assertion reads the signature rather than the build setting: a
    /// project-setting check would have gone green over a bundle with no hardened runtime at all,
    /// and every entitlement assertion above describes behaviour *under* hardened runtime.
    func testBuiltBundleIsSignedWithTheHardenedRuntime() throws {
        let bundle = try locateBundle()
        let output = try run("/usr/bin/codesign", ["-d", "--verbose=2", bundle.path])
        // codesign prints its report on stderr.
        let report = output.standardError + output.standardOutput
        XCTAssertTrue(
            report.contains("flags=") && report.contains("runtime"),
            """
            The built bundle is not signed with the hardened runtime. The entitlement assertions \
            above are about behaviour under hardened runtime, and TCC treats a non-hardened build \
            as a different, less trusted identity.
            codesign said:
            \(report)
            """)
    }

    // MARK: Test-only targets must not ship

    /// The package declares two test-only targets — `VoccaNetworkProbe` (an executable) and
    /// `CVoccaNetworkInterposer`, vended as the dynamic `_VoccaNetworkInterposerTestFixture`
    /// product. The app target links neither, but a dynamic-library product *is* embeddable, so
    /// "it currently isn't linked" is a fact about today's project file rather than a guarantee.
    /// This test makes it a guarantee.
    func testNoTestOnlyTargetLeakedIntoTheBundle() throws {
        let bundle = try locateBundle()
        let forbiddenSubstrings = ["NetworkInterposer", "NetworkProbe"]

        var offenders: [String] = []
        if let enumerator = FileManager.default.enumerator(
            at: bundle, includingPropertiesForKeys: nil)
        {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if forbiddenSubstrings.contains(where: { name.localizedCaseInsensitiveContains($0) }
                ) {
                    offenders.append(url.path)
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            Test-only artefacts are inside the shipped bundle: \
            \(offenders.sorted().joined(separator: ", ")).
            VoccaNetworkProbe and CVoccaNetworkInterposer exist only to prove the zero-network \
            invariant; the interposer is a dyld shim that hooks connect(2). Neither may ship.
            """)

        let executables = try FileManager.default.contentsOfDirectory(
            atPath: bundle.appendingPathComponent("Contents/MacOS").path)
        XCTAssertEqual(
            executables.sorted(), ["Vocca"],
            "Contents/MacOS must hold exactly one executable, the app itself")
    }

    // MARK: Subprocess plumbing

    private struct ProcessOutput {
        let standardOutput: String
        let standardError: String
        let rawStandardOutput: Data
        let status: Int32
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        // Drained before waiting: entitlement plists comfortably exceed a pipe buffer.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessOutput(
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self),
            rawStandardOutput: outData,
            status: process.terminationStatus)
    }

    /// Reads the entitlements `codesign` actually embedded in the signed bundle — not the source
    /// `.entitlements` file, which is only an input and can be ignored by the build.
    private func embeddedEntitlements(of bundle: URL) throws -> [String: Any] {
        let output = try run(
            "/usr/bin/codesign", ["-d", "--entitlements", ":-", "--xml", bundle.path])
        guard output.status == 0 else {
            throw BundleTestError.codesignFailed(
                status: output.status, stderr: output.standardError)
        }

        // Older codesign wraps the plist in a 0xfade7171 blob header; newer versions emit bare
        // XML. Slice from the XML prologue so both are handled without version sniffing.
        var data = output.rawStandardOutput
        if let prologue = data.range(of: Data("<?xml".utf8)) {
            data = data.subdata(in: prologue.lowerBound..<data.endIndex)
        }

        guard !data.isEmpty else {
            throw BundleTestError.entitlementsUnreadable(
                detail:
                    "codesign returned no entitlements at all for \(bundle.path). An unsigned or entitlement-free binary would make the 'forbidden entitlement absent' assertions pass trivially."
            )
        }

        do {
            guard
                let plist = try PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any]
            else {
                throw BundleTestError.entitlementsUnreadable(detail: "not a dictionary")
            }
            return plist
        } catch let error as BundleTestError {
            throw error
        } catch {
            throw BundleTestError.entitlementsUnreadable(detail: "\(error)")
        }
    }
}
