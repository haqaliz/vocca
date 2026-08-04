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
/// ## How the built-bundle suite is meant to be run — this is the CI contract
///
/// ```sh
/// xcodebuild -project Vocca.xcodeproj -scheme Vocca -configuration Debug \
///     -derivedDataPath .build/xcode build
/// VOCCA_APP_BUNDLE=.build/xcode/Build/Products/Debug/Vocca.app swift test
/// ```
///
/// **Both lines, in that order, are what CI must run.** Ad-hoc signing needs no identity, no
/// keychain and no secrets — this repository's app target builds and signs on a machine where
/// `security find-identity -v -p codesigning` reports `0 valid identities found`, producing
/// `flags=0x10002(adhoc,runtime)` every time. So there is no reason for CI to skip this suite, and
/// with `VOCCA_APP_BUNDLE` set a missing bundle is a hard failure rather than a skip. That is the
/// path that must stay green.
///
/// The `-derivedDataPath` is what makes the bundle findable without the variable: the suite also
/// looks in `.build/xcode/Build/Products/*/Vocca.app` relative to the package root, which is what
/// makes a plain local `swift test` pick up a bundle you already built.
///
/// ## What happens when there is no bundle
///
/// A plain `swift test` on a machine that never ran `xcodebuild` **skips** this suite. That path
/// exists for local convenience only — so a quick `swift test` is not blocked on a bundle build.
/// It is not the path that guards anything; the two-line contract above is.
///
/// The skip is engineered not to be mistakable for a pass:
///
/// 1. it writes a multi-line banner naming the assertions that were **not** evaluated. The write
///    goes to `FileHandle.standardError`; SwiftPM merges the test process's streams, so under
///    `swift test` it surfaces on **stdout** (measured: `swift test >out 2>err` puts all eight
///    banners in `out` and none in `err`; running the `.xctest` bundle directly puts them on
///    stderr). Either way it is on screen and impossible to miss,
/// 2. `XCTSkip` reports the tests as skipped, not passed, in the run summary,
/// 3. setting `VOCCA_APP_BUNDLE` converts "no bundle" from a skip into a **failure**, so the CI
///    contract above can never go green without measuring a real bundle,
/// 4. a bundle whose plist or entitlements disagree with the checked-in sources is a **failure**,
///    not a pass — a stale `.app` asserting yesterday's plist is the same vacuous green in slower
///    motion,
/// 5. and the six properties are never left unmeasured regardless, because
///    ``BundleConfigurationTests`` asserts every one of them and cannot skip.
///
/// Point 5 is a floor, not a substitute, and the sandbox hole proved it: a project-level
/// `ENABLE_APP_SANDBOX = YES` once left `BundleConfigurationTests` 11/11 green while the built
/// bundle shipped `com.apple.security.app-sandbox`. `BuiltBundleTests` caught it and the source
/// checks did not, because only one of the two reads what was actually signed. That is the case
/// for running the CI contract rather than relying on the always-on suite.
private enum BundleTestSupport {

    static let expectedBundleIdentifier = "dev.vocca.Vocca"
    static let requiredEntitlement = "com.apple.security.device.audio-input"
    static let forbiddenEntitlements = [
        "com.apple.security.app-sandbox",
        "com.apple.security.cs.disable-library-validation",
    ]

    /// Deliberately **not** in ``forbiddenEntitlements``: Debug builds are supposed to carry it, and
    /// listing it there would make every Debug bundle red. That exemption is precisely why the
    /// configuration-aware check below has to exist — see ``BuildConfiguration``.
    static let debugOnlyInjectedEntitlement = "com.apple.security.get-task-allow"

    /// Non-Apple `Info.plist` key that records which build configuration produced a bundle.
    ///
    /// `App/Info.plist` sets it to the literal `$(CONFIGURATION)`; Xcode substitutes the real
    /// configuration name during the *Process Info.plist* phase. See ``BuildConfiguration`` for why
    /// the suite needs to know, and the plist's own comment for why the reference form is mandatory.
    static let buildConfigurationKey = "VoccaBuildConfiguration"

    /// The exact literal `App/Info.plist` must hold for ``buildConfigurationKey``.
    static let buildConfigurationReference = "$(CONFIGURATION)"

    /// The build configurations this suite knows the entitlement rules for.
    ///
    /// ## Why the suite needs this at all
    ///
    /// `com.apple.security.get-task-allow` lets any process running as the same user attach a
    /// debugger and read the process's memory — for Vocca that means live audio buffers and
    /// transcripts — and notarization rejects a binary carrying it. It is also *required* for Debug:
    /// without it no debugger can attach to a debug build at all. So it is legitimate in one
    /// configuration and disqualifying in the other, and a check with no notion of configuration has
    /// to permit it unconditionally.
    ///
    /// That was measured, not theorised. Deleting `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` from the
    /// Release configuration, rebuilding Release, and running the full `VOCCA_APP_BUNDLE=` contract
    /// gave **8/8 green against a Release bundle carrying `get-task-allow`**, for two independent
    /// structural reasons:
    ///
    /// 1. `get-task-allow` is absent from ``forbiddenEntitlements`` — as it must be, or Debug breaks;
    /// 2. ``BuiltBundleTests/testBuiltBundleWasBuiltFromTheCheckedInSources`` iterates the *source*
    ///    entitlement keys, so an entitlement present in the bundle and absent from
    ///    `App/Vocca.entitlements` is never looked at.
    ///
    /// ``BuiltBundleTests/testBuiltBundleEmbedsExactlyTheEntitlementsItsConfigurationAllows``
    /// closes both by asserting set-equality, with this type supplying the one permitted exception.
    enum BuildConfiguration: String, CaseIterable {
        case debug = "Debug"
        case release = "Release"

        /// Entitlements Xcode is permitted to inject for this configuration on top of everything
        /// `App/Vocca.entitlements` declares. Anything else in the signed bundle is a failure.
        var permittedInjectedEntitlements: Set<String> {
            switch self {
            case .debug: [BundleTestSupport.debugOnlyInjectedEntitlement]
            case .release: []
            }
        }
    }

    /// Environment variable naming the configuration the caller *believes* it is testing.
    ///
    /// When set it must equal the configuration the bundle itself reports, or the run fails. CI sets
    /// it in both bundle jobs, which is what stops the Release job from silently measuring a Debug
    /// bundle after a copy-pasted path — a mistake that is otherwise invisible, because a Debug
    /// bundle passes every Debug-legal assertion perfectly.
    static let expectedConfigurationVariable = "VOCCA_EXPECTED_CONFIGURATION"

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
    case noSourcesBuildPhase
    case codesignFailed(status: Int32, stderr: String)
    case entitlementsUnreadable(detail: String)
    case buildConfigurationUndetectable(bundle: String, reason: String)
    case buildConfigurationMismatch(bundle: String, reported: String, contradictedBy: String)

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
        case .noSourcesBuildPhase:
            return """
                The Vocca target has no PBXSourcesBuildPhase. This is refused rather than treated \
                as "compiles nothing", because an empty source list would satisfy the assertion \
                that the target compiles only the shim while compiling no shim at all.
                """
        case .codesignFailed(let status, let stderr):
            return "`codesign -d --entitlements` failed with status \(status): \(stderr)"
        case .entitlementsUnreadable(let detail):
            return "Could not parse the embedded entitlements: \(detail)"
        case .buildConfigurationUndetectable(let bundle, let reason):
            return """
                Could not determine which build configuration produced \(bundle): \(reason).
                This is a hard failure rather than a skip or a permissive default, and that is the \
                whole point of the check. The entitlement rules differ by configuration — Debug may \
                carry \(BundleTestSupport.debugOnlyInjectedEntitlement), Release may not — so a run \
                that cannot tell them apart has to allow the union, which is exactly the hole a \
                Release bundle carrying \(BundleTestSupport.debugOnlyInjectedEntitlement) walked \
                through 8/8 green.
                Fix the bundle, not the test: \(BundleTestSupport.buildConfigurationKey) must be \
                present in the built Contents/Info.plist with a substituted value. App/Info.plist \
                sets it to \(BundleTestSupport.buildConfigurationReference); if the built bundle \
                still shows that literal, Info.plist build-setting expansion has been turned off \
                (INFOPLIST_EXPAND_BUILD_SETTINGS), and if the key is missing entirely the bundle \
                predates this check and needs rebuilding.
                """
        case .buildConfigurationMismatch(let bundle, let reported, let contradictedBy):
            return """
                \(bundle) reports build configuration '\(reported)', but \(contradictedBy).
                Refusing to guess which is right. A bundle whose provenance is ambiguous is one \
                whose entitlement rules are ambiguous, and picking the more permissive reading is \
                how a Release binary keeps \(BundleTestSupport.debugOnlyInjectedEntitlement).
                """
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

    /// `App/Info.plist` must record the build configuration, and must do it as a *reference*.
    ///
    /// The literal `$(CONFIGURATION)` is not a stylistic choice, it is the entire security property.
    /// Xcode substitutes it at build time, so the value in a built bundle is a statement the build
    /// system made about itself and cannot be a claim the repository made on its behalf. Hardcoding
    /// `Debug` here would make every Release bundle self-identify as Debug, and
    /// ``BuiltBundleTests/testBuiltBundleEmbedsExactlyTheEntitlementsItsConfigurationAllows`` would
    /// then hand a shipping Release binary the `\(BundleTestSupport.debugOnlyInjectedEntitlement)`
    /// exemption — restoring the exact hole it was written to close, while staying green.
    ///
    /// Deliberately *not* added to ``BuiltBundleTests/pinnedKeysThatMayNotBeSubstituted``: this is
    /// the one key that must be substituted.
    func testInfoPlistDeclaresTheBuildConfigurationMarker() throws {
        let plist = try infoPlist()
        XCTAssertEqual(
            plist[BundleTestSupport.buildConfigurationKey] as? String,
            BundleTestSupport.buildConfigurationReference,
            """
            App/Info.plist must set \(BundleTestSupport.buildConfigurationKey) to exactly \
            '\(BundleTestSupport.buildConfigurationReference)', and currently sets it to \
            '\(String(describing: plist[BundleTestSupport.buildConfigurationKey] ?? "<absent>"))'.
            That key is how a built bundle tells the suite whether it is allowed to carry \
            \(BundleTestSupport.debugOnlyInjectedEntitlement). It has to be the build-setting \
            reference so the answer comes from the build rather than from this file: a hardcoded \
            'Debug' would let a Release bundle claim the debug exemption and ship an entitlement \
            that exposes live transcripts to any same-user process and fails notarization.
            Removing the key is not an option either — BuiltBundleTests fails closed when it cannot \
            classify a bundle.
            """)
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

    // MARK: The app target's source may not grow

    /// The exact code `App/VoccaApp.swift` is allowed to contain: comments and blank lines
    /// removed, every remaining line trimmed.
    ///
    /// Comments are excluded deliberately, and it makes the pin *stronger* rather than looser.
    /// Pinning the raw text would mean every prose improvement is a test edit, and a test that
    /// cries wolf on documentation changes gets updated reflexively — at which point it stops
    /// guarding the thing it exists for. Stripping comments cannot hide code: a line of Swift that
    /// does anything is not a comment.
    ///
    /// **Both** comment forms are stripped. The first version handled only `//`, so a `/* … */`
    /// block anywhere in the file tripped the pin — and the failure message then announced that
    /// code had been added with no guarantee behind it, which was false. A red that misdiagnoses
    /// its own cause is the failure shape this file has already had to remove twice.
    private static let expectedAppTargetSource = """
        import VoccaBootstrap
        @main
        enum VoccaApp {
        @MainActor
        static func main() {
        AppBootstrap.main()
        }
        }
        """

    /// Removes `/* … */` comments, preserving newlines so line-based filtering downstream still
    /// lines up. Nesting is not handled, matching every file this rule applies to — and an
    /// unterminated or nested block simply leaves text that fails the pin, which is the safe
    /// direction.
    private static func strippingBlockComments(from source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let characters = Array(source)
        var index = 0
        var depth = 0
        while index < characters.count {
            if index + 1 < characters.count, characters[index] == "/", characters[index + 1] == "*" {
                depth += 1
                index += 2
                continue
            }
            if depth > 0, index + 1 < characters.count, characters[index] == "*",
                characters[index + 1] == "/"
            {
                depth -= 1
                index += 2
                continue
            }
            if depth == 0 {
                result.append(characters[index])
            } else if characters[index] == "\n" {
                result.append("\n")
            }
            index += 1
        }
        return result
    }

    /// `App/VoccaApp.swift` must remain a shim that hands straight to ``AppBootstrap``.
    ///
    /// It is the only source in this repository outside the SwiftPM package, and that puts it
    /// outside `ModuleBoundaryTests` and — the one that matters — outside `VoccaNetworkProbe`. The
    /// zero-network invariant is a permanent release blocker and it says nothing about this file.
    /// `App/` is also, by convention, exactly where an update checker, a crash reporter or a
    /// Sparkle integration goes: the archetypal network callers, landing in the one place nothing
    /// is watching.
    ///
    /// A file-count assertion was considered and rejected: it stops a second file appearing and
    /// does nothing at all about two hundred lines going into the one file that is allowed to
    /// exist. Pinning the content is what actually closes the gap — anything added here fails,
    /// which sends the code to `AppBootstrap.configure(_:)` where the probe drives it.
    func testAppTargetSourceIsOnlyAShimToTheBootstrapModule() throws {
        let file = try BundleTestSupport.packageRoot()
            .appendingPathComponent("App/VoccaApp.swift")
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw BundleTestError.fileMissing(path: file.path, underlying: "\(error)")
        }

        let code =
            Self.strippingBlockComments(from: text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertEqual(
            code, Self.expectedAppTargetSource,
            """
            App/VoccaApp.swift no longer matches the @main shim exactly.
            This file is outside the SwiftPM package, so nothing drives it: the zero-network probe \
            cannot reach it and ModuleBoundaryTests cannot see it. Code here ships with no \
            automated guarantee behind it, which is why the shim is pinned rather than reviewed.
            Comments — both // and /* */ — are stripped before this comparison, so if the diff \
            above looks like prose, something in it is being parsed as code: an unterminated block \
            comment, or a `//` inside a string literal.
            If code was added, move it to AppBootstrap.configure(_:) in Sources/VoccaBootstrap, \
            which the probe calls on the default-configuration path. If the shim itself genuinely \
            has to change, update `expectedAppTargetSource` in the same change so the decision is \
            visible in review.
            """)
    }

    // MARK: The app target's source *set* may not grow either

    /// Every file `App/` is allowed to contain.
    private static let expectedAppDirectoryContents = [
        "Info.plist", "Vocca.entitlements", "VoccaApp.swift",
    ]

    /// The app target may compile exactly one file.
    ///
    /// ``testAppTargetSourceIsOnlyAShimToTheBootstrapModule`` pins the *contents* of
    /// `App/VoccaApp.swift`; this pins the *set*. Both are needed and neither substitutes for the
    /// other — I argued otherwise in round 1 and was wrong, in a way that was demonstrated rather
    /// than argued: adding `App/UpdateChecker.swift` (carrying the Apache header, so the licence
    /// suite was satisfied) with a `getaddrinfo("updates.vocca.dev", …)` in it, wired in with the
    /// three routine `project.pbxproj` entries Xcode writes when you drag a file into a target,
    /// shipped the hostname and seven `UpdateChecker` symbols inside `Contents/MacOS/Vocca` while
    /// the full suite reported **27/27, zero failures** under the CI contract.
    ///
    /// The content pin could not have caught it: `VoccaApp.swift` was never touched. Growth in one
    /// file and a second file are two different holes, and closing one says nothing about the
    /// other.
    ///
    /// Read from the `Sources` build phase rather than from the directory listing, because
    /// compilation is what actually matters — a `.swift` file sitting in `App/` unreferenced by the
    /// target ships nothing.
    func testAppTargetCompilesOnlyTheShim() throws {
        XCTAssertEqual(
            try appTargetSourceFileNames(), ["VoccaApp.swift"],
            """
            The Vocca app target compiles more than the @main shim.
            Sources under App/ are outside the SwiftPM package: VoccaNetworkProbe cannot drive \
            them, so the zero-network invariant — a permanent release blocker — says nothing about \
            them, and ModuleBoundaryTests cannot see them either. A file added here ships with no \
            automated guarantee behind it whatsoever.
            Put the code in a module under Sources/ instead. If it is start-up work, it belongs in \
            AppBootstrap.configure(_:), which the probe calls on the default-configuration path.
            """)
    }

    /// `App/` may hold exactly the three known files.
    ///
    /// A narrower check than the build-phase assertion above and kept alongside it deliberately:
    /// this one fails the moment an extra source appears on disk, before anyone wires it into the
    /// target, which is where the mistake is cheapest to undo. It also catches a stray resource
    /// being picked up by a copy phase.
    func testAppDirectoryHoldsOnlyTheKnownFiles() throws {
        let appDirectory = try BundleTestSupport.packageRoot().appendingPathComponent("App")
        let entries = try FileManager.default.contentsOfDirectory(atPath: appDirectory.path)
            .filter { $0 != ".DS_Store" }
            .sorted()
        XCTAssertEqual(
            entries, Self.expectedAppDirectoryContents,
            """
            App/ contains files this task does not know about.
            The app target is a shell: a plist, an entitlements file and a one-line @main shim. \
            Everything else belongs in a module under Sources/, where the zero-network probe and \
            ModuleBoundaryTests can reach it.
            If a file genuinely belongs here, add it to `expectedAppDirectoryContents` in the same \
            change so the decision is visible in review.
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

    /// The sandbox assertion demands an explicit `NO` rather than merely "not YES", and the
    /// difference is not pedantry — it was an exploited hole.
    ///
    /// ``buildSettingsPerConfiguration()`` reads the **target's** configurations only. Build
    /// settings inherit, so a setting the target never mentions can still be YES because the
    /// *project* said so. The earlier assertion was `XCTAssertNotEqual(values["ENABLE_APP_SANDBOX"],
    /// "YES")`, and an unset target value is `nil` — `nil != "YES"` passes. Setting
    /// `ENABLE_APP_SANDBOX = YES` at project level therefore left this suite 11/11 green while the
    /// built bundle shipped `com.apple.security.app-sandbox => true`, which would have cut Vocca
    /// off from the Accessibility API and system-wide injection entirely.
    ///
    /// Requiring the literal `NO` on the target closes it from both directions: the target-level
    /// value overrides any project-level or `.xcconfig` inheritance, and absence stops being a
    /// pass. The same reasoning applies to `ENABLE_HARDENED_RUNTIME` below, which was already
    /// asserted by equality and so was never exposed.
    func testXcodeProjectEnablesHardenedRuntimeAndLeavesTheSandboxOff() throws {
        let settings = try buildSettingsPerConfiguration()
        for (configuration, values) in settings {
            XCTAssertEqual(
                values["ENABLE_HARDENED_RUNTIME"], "YES",
                "Configuration '\(configuration)' must enable the hardened runtime")
            XCTAssertEqual(
                values["ENABLE_APP_SANDBOX"], "NO",
                """
                Configuration '\(configuration)' has ENABLE_APP_SANDBOX set to \
                '\(values["ENABLE_APP_SANDBOX"] ?? "<unset on the target>")'; it must be an \
                explicit NO on the target.
                Unset is not good enough. Build settings inherit, so an absent target value can \
                still be YES because the project or an .xcconfig said so — and Xcode then injects \
                com.apple.security.app-sandbox into the signed entitlements without a single line \
                of App/Vocca.entitlements changing. Sandboxing confines Vocca to a container and \
                cuts off the Accessibility API and the system-wide text injection the product is \
                built on.
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
    /// The parsed `objects` table and the `Vocca` native target within it.
    private func voccaTarget() throws -> (objects: [String: [String: Any]], target: [String: Any]) {
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
        return (objects, target)
    }

    /// The file names in the `Vocca` target's `Sources` build phase — the set of files the app
    /// target actually compiles.
    ///
    /// Resolved structurally: build phase → `PBXBuildFile` → its `fileRef` → the
    /// `PBXFileReference`'s `path`. A missing `Sources` phase throws rather than returning an empty
    /// list, because "compiles nothing" would satisfy an equality check against an empty
    /// expectation and is never a real state for an app target.
    private func appTargetSourceFileNames() throws -> [String] {
        let (objects, target) = try voccaTarget()

        guard let phaseIdentifiers = target["buildPhases"] as? [String],
            let sourcesPhase = phaseIdentifiers.lazy.compactMap({ objects[$0] })
                .first(where: { $0["isa"] as? String == "PBXSourcesBuildPhase" })
        else {
            throw BundleTestError.noSourcesBuildPhase
        }

        let buildFileIdentifiers = sourcesPhase["files"] as? [String] ?? []
        return
            buildFileIdentifiers
            .compactMap { objects[$0]?["fileRef"] as? String }
            .compactMap { objects[$0]?["path"] as? String }
            .map { ($0 as NSString).lastPathComponent }
            .sorted()
    }

    private func buildSettingsPerConfiguration() throws -> [String: [String: String]] {
        let (objects, target) = try voccaTarget()

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
                  - the embedded entitlement SET equals App/Vocca.entitlements, allowing
                    \(BundleTestSupport.debugOnlyInjectedEntitlement) only for a Debug bundle
                  - the bundle is the configuration the caller asked for
                  - hardened runtime is on in the embedded signature
                  - the bundle was built from the checked-in App/ sources
                  - no test-only target leaked into the bundle

                To run them — and this is what CI runs, so it is the path that must be green:
                  xcodebuild -project Vocca.xcodeproj -scheme Vocca -configuration Debug \\
                      -derivedDataPath \(BundleTestSupport.conventionalDerivedData) build
                  \(BundleTestSupport.bundlePathVariable)=\(BundleTestSupport.conventionalDerivedData)/Build/Products/Debug/Vocca.app swift test

                Ad-hoc signing needs no identity, keychain or secret, so there is no reason to skip
                this. With \(BundleTestSupport.bundlePathVariable) set, a missing bundle FAILS
                instead of skipping.

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

    /// Keys that must be literals in `App/Info.plist`, never `$(BUILD_SETTING)` references.
    ///
    /// These are the three the brief calls load-bearing, for the same reason it does: each fails
    /// silently at runtime — denied microphone with no prompt, or a focus-stealing agent — and each
    /// is asserted here against the file. Letting one become a reference would move the real value
    /// into `project.pbxproj` where those assertions do not look.
    private static let pinnedKeysThatMayNotBeSubstituted = [
        "CFBundleIdentifier", "NSMicrophoneUsageDescription", "LSUIElement",
    ]

    /// Whether a plist value is written as an Xcode build-setting reference, e.g.
    /// `$(MARKETING_VERSION)`. Only strings can be; anything else is a literal by construction.
    private func isBuildSettingReference(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return text.contains("$(")
    }

    /// Fails when the bundle under test was built from a different `App/Info.plist` or
    /// `App/Vocca.entitlements` than the one currently checked in.
    ///
    /// A stale `.app` is the same vacuous green as no `.app`, only harder to notice: yesterday's
    /// bundle happily satisfies every assertion in this suite while today's plist is broken. Since
    /// the bundle is discovered rather than built, nothing else here would catch that.
    ///
    /// It compares *values*, not timestamps, and it skips values Xcode is expected to rewrite.
    /// Two earlier versions were wrong in the same shape, which is why both are recorded here:
    ///
    /// - Comparing **modification dates** failed and *stayed* failed through a rebuild. Xcode's
    ///   copy task is content-hashed, so `touch App/Info.plist` changed no content and nothing was
    ///   re-copied.
    /// - Comparing every value **literally** trapped the standard Xcode idiom. `project.pbxproj`
    ///   defines `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` precisely so an Info.plist can
    ///   say `$(MARKETING_VERSION)`; making that edit left source `$(MARKETING_VERSION)` against
    ///   built `0.1.0`, red after a clean build, blaming staleness for a correct change.
    ///
    /// A test that goes red and stays red through the fix its own message recommends teaches people
    /// to ignore it, which costs more than the check is worth. So values containing `$(` are
    /// excluded from the comparison — Xcode is *supposed* to change those — and the failure message
    /// names substitution as the other possible cause.
    ///
    /// Excluding them is safe only because two things bound it: at least one literal key must
    /// remain to compare, and the three keys this task exists to pin may not be substituted at all
    /// (see ``pinnedKeysThatMayNotBeSubstituted``). Otherwise "make every value a build setting"
    /// would be a one-line route to a staleness check that compares nothing.
    func testBuiltBundleWasBuiltFromTheCheckedInSources() throws {
        let bundle = try locateBundle()
        let root = try BundleTestSupport.packageRoot()

        let source = try BundleTestSupport.readPropertyList(
            at: root.appendingPathComponent("App/Info.plist"))
        let built = try BundleTestSupport.readPropertyList(
            at: bundle.appendingPathComponent("Contents/Info.plist"))

        let substituted = source.keys.filter { isBuildSettingReference(source[$0]) }.sorted()

        for key in Self.pinnedKeysThatMayNotBeSubstituted {
            XCTAssertFalse(
                substituted.contains(key),
                """
                App/Info.plist sets \(key) to a build-setting reference \
                ('\(String(describing: source[key] ?? "<absent>"))'). That key must be a literal.
                It is one of the three this task exists to pin, and routing it through the project \
                file moves the real value out of the file every assertion here reads — the plist \
                would then agree with itself while the shipped bundle said something else. It also \
                removes the key from the staleness comparison below, which is the second cost.
                """)
        }

        // Xcode adds build-provenance keys (DTXcode, BuildMachineOSBuild, ...), so this compares
        // the keys the source declares rather than the two dictionaries.
        let comparable = source.keys.filter { !substituted.contains($0) }.sorted()

        XCTAssertFalse(
            comparable.isEmpty,
            """
            Every value in App/Info.plist is a build-setting reference, so this check compared \
            nothing and the bundle's provenance went unverified. Substituted keys: \
            \(substituted.joined(separator: ", ")).
            """)

        for key in comparable {
            XCTAssertEqual(
                String(describing: built[key] ?? "<absent>"),
                String(describing: source[key] ?? "<absent>"),
                """
                The built bundle's \(key) does not match App/Info.plist. Two causes, in order of \
                likelihood:
                  1. The bundle is stale — it was produced from an earlier version of that file, \
                and everything this suite says about it describes stale output. Rebuild:
                       xcodebuild -project Vocca.xcodeproj -scheme Vocca -configuration Debug \
                -derivedDataPath \(BundleTestSupport.conventionalDerivedData) build
                  2. Xcode rewrote the value on purpose. Values written as a build-setting \
                reference — '$(SOME_SETTING)' — are excluded from this comparison for exactly that \
                reason; a value that is transformed some *other* way is not, and this check would \
                need to learn about it.
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
    ///
    /// This test is therefore a *named-offender* check and always was. It is kept because it names
    /// the two entitlements whose presence has a specific, explainable consequence, but on its own
    /// it is not sufficient — see
    /// ``testBuiltBundleEmbedsExactlyTheEntitlementsItsConfigurationAllows``, which asserts the
    /// whole set and is what actually stops an unlisted entitlement from shipping.
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

    // MARK: The whole entitlement set, judged against the configuration that produced the bundle

    /// The signed bundle must carry **exactly** what `App/Vocca.entitlements` declares, plus only
    /// the injections its own build configuration permits.
    ///
    /// ## The hole this closes, which was measured rather than imagined
    ///
    /// Deleting `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` from the Release configuration, rebuilding
    /// Release and running the full `VOCCA_APP_BUNDLE=` contract produced **8/8 green against a
    /// Release bundle carrying `com.apple.security.get-task-allow`** — an entitlement that lets any
    /// same-user process attach a debugger and read Vocca's memory, meaning live audio and
    /// transcripts, and that notarization rejects outright. Two independent reasons, neither
    /// fixable by adding to a list:
    ///
    /// 1. ``BundleTestSupport/forbiddenEntitlements`` cannot name `get-task-allow`, because Debug
    ///    builds legitimately have it and would go permanently red.
    /// 2. ``testBuiltBundleWasBuiltFromTheCheckedInSources`` iterates the keys of the *source*
    ///    entitlements file, so an entitlement in the bundle that the source never mentions is
    ///    never examined. Every entitlement anyone would inject by accident has that exact shape.
    ///
    /// So the check is inverted: instead of enumerating what may not be there, assert the set and
    /// enumerate the small, configuration-specific set of exceptions. An entitlement nobody has
    /// thought of yet fails by default, which is the direction that survives contact with a
    /// build-setting change made two years from now.
    ///
    /// ``BundleConfigurationTests/testEntitlementsFileContainsNothingElse`` pins the source file to
    /// one entitlement; this pins the *signed artefact*, which is the thing that ships and the only
    /// one a build setting can quietly add to.
    func testBuiltBundleEmbedsExactlyTheEntitlementsItsConfigurationAllows() throws {
        let bundle = try locateBundle()
        let configuration = try buildConfiguration(of: bundle)

        let declared = Set(
            try BundleTestSupport.readPropertyList(
                at: try BundleTestSupport.packageRoot()
                    .appendingPathComponent("App/Vocca.entitlements")
            ).keys)
        let embedded = Set(try embeddedEntitlements(of: bundle).keys)
        let permitted = declared.union(configuration.permittedInjectedEntitlements)

        let injectionsAllowed = configuration.permittedInjectedEntitlements.sorted()
        let injectionSummary =
            injectionsAllowed.isEmpty ? "nothing at all" : injectionsAllowed.joined(separator: ", ")

        let unexpected = embedded.subtracting(permitted).sorted()
        XCTAssertTrue(
            unexpected.isEmpty,
            """
            The \(configuration.rawValue) bundle at \(bundle.path) is signed with entitlements \
            nothing declares: \(unexpected.joined(separator: ", ")).
            App/Vocca.entitlements declares \(declared.sorted().joined(separator: ", ")); a \
            \(configuration.rawValue) build may additionally carry \(injectionSummary).
            Anything beyond that came from a build setting rather than from a file anyone reviewed. \
            If it is \(BundleTestSupport.debugOnlyInjectedEntitlement) in a Release bundle, \
            CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO has been lost from the Release configuration: \
            restore it. Every entitlement widens what the signed binary may do and has to be argued \
            for in App/Vocca.entitlements, one at a time — not inherited.
            """)

        let missing = declared.subtracting(embedded).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            """
            App/Vocca.entitlements declares \(missing.joined(separator: ", ")) but the signed \
            \(configuration.rawValue) bundle does not carry \(missing.count == 1 ? "it" : "them"). \
            The entitlements file is an input the build is free to ignore — CODE_SIGN_ENTITLEMENTS \
            pointing somewhere else, or signing being skipped — and a missing \
            \(BundleTestSupport.requiredEntitlement) means the microphone is denied at runtime with \
            no prompt and no error.
            """)
    }

    /// Fails a run that is testing a different configuration than the caller believes it is.
    ///
    /// Without this the Release CI job's correctness rests on one path string. A Debug bundle
    /// satisfies every assertion in this suite — legitimately, it is a valid Debug bundle — so a
    /// copy-pasted `VOCCA_APP_BUNDLE` pointing at `…/Debug/Vocca.app` would leave the Release job
    /// green for the rest of the project's life while never once looking at a Release build. The
    /// job would exist, run, take four minutes, and prove nothing.
    ///
    /// Unset means unconstrained, which is the local-convenience path; it cannot weaken CI, because
    /// the workflow sets it in both bundle jobs and a workflow that stopped setting it is a visible
    /// diff.
    func testBundleUnderTestIsTheConfigurationTheCallerAskedFor() throws {
        let bundle = try locateBundle()
        let configuration = try buildConfiguration(of: bundle)

        guard
            let expected = ProcessInfo.processInfo.environment[
                BundleTestSupport.expectedConfigurationVariable]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty
        else { return }

        XCTAssertEqual(
            configuration.rawValue, expected,
            """
            \(BundleTestSupport.expectedConfigurationVariable) is '\(expected)' but the bundle at \
            \(bundle.path) was built \(configuration.rawValue). Whatever this run measured, it was \
            not the configuration it was asked to measure.
            """)
    }

    // MARK: Determining which configuration built the bundle

    /// Which build configuration produced `bundle`, or a thrown error — never a default.
    ///
    /// ## Why the marker key, and not the alternatives
    ///
    /// The obvious detector is the derived-data path component (`…/Build/Products/Release/…`) and it
    /// is the wrong one: it is a fact about where a file was copied to, not about how it was built.
    /// `cp -R` into another directory relabels it, `-derivedDataPath` is caller-supplied, and
    /// platform suffixes (`Release-maccatalyst`) break exact matching. Reading the Mach-O for
    /// optimisation hints infers the configuration instead of asking, and infers it from something
    /// a build setting can change independently.
    ///
    /// So the build system is asked directly: `App/Info.plist` carries
    /// `\(BundleTestSupport.buildConfigurationKey)` set to the literal
    /// `\(BundleTestSupport.buildConfigurationReference)`, which Xcode expands during *Process
    /// Info.plist*. The value in a built bundle is therefore something the build system wrote about
    /// itself. ``BundleConfigurationTests/testInfoPlistDeclaresTheBuildConfigurationMarker`` pins
    /// the source to the reference form so it can never become a claim the repository makes on the
    /// build's behalf.
    ///
    /// ## Failing closed, in all four ways it can fail
    ///
    /// A detector that answers "unknown" and lets the caller shrug is the same vacuous green this
    /// check exists to remove, so every one of these throws:
    ///
    /// - the key is absent (bundle predates the check, or the plist lost it);
    /// - the value still contains `$(` (expansion is off — the marker is a literal, not an answer);
    /// - the value is a configuration name the rules do not cover (a third configuration must state
    ///   its own entitlement policy before a bundle built from it can pass anything);
    /// - the value contradicts an unambiguous products-directory name.
    ///
    /// The last is corroboration only and is applied in one direction: the marker is authoritative,
    /// the path may only contradict it. A path component that is not exactly a known configuration
    /// name says nothing and is ignored, so an app copied elsewhere still classifies.
    ///
    /// ## What this does not defend against
    ///
    /// Stated precisely, because an earlier version of this comment claimed a tampered bundle
    /// "cannot" be misclassified, and it can. The corroborator only fires when the enclosing
    /// directory is *exactly* `Debug` or `Release`; copy a Release bundle to `…/out/Vocca.app`, or
    /// to `…/Release-fixed/`, and edit `Contents/Info.plist` to say `Debug`, and it classifies as
    /// Debug and is then permitted `get-task-allow`. Nothing here re-derives the configuration from
    /// the binary, and `BuiltBundleTests` deliberately compares the built plist against `App/`
    /// while excluding this key (the source holds the unexpanded `$(…)` reference, so it cannot be
    /// compared literally) — so an edited marker is not caught by the staleness check either.
    ///
    /// The bound this actually provides: a bundle produced by *this* build system reports the
    /// configuration *the build system itself* wrote, and cannot be relabelled by moving it or by a
    /// build setting. That is the real failure mode — a Release job silently measuring a Debug
    /// build — and it is closed. Defeating it takes a deliberate edit of a file inside a signed
    /// bundle, which breaks the signature that `testBuiltBundleIsSignedWithTheHardenedRuntime` and
    /// `codesign --verify` in `Scripts/sign.sh` both look at. This suite tests build outputs, not
    /// adversarially supplied ones; an attacker who can rewrite the bundle under test has already
    /// won more than this check.
    private func buildConfiguration(of bundle: URL) throws -> BundleTestSupport.BuildConfiguration {
        let plist = try BundleTestSupport.readPropertyList(
            at: bundle.appendingPathComponent("Contents/Info.plist"))

        guard let raw = plist[BundleTestSupport.buildConfigurationKey] as? String,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw BundleTestError.buildConfigurationUndetectable(
                bundle: bundle.path,
                reason:
                    "its Contents/Info.plist has no non-empty '\(BundleTestSupport.buildConfigurationKey)' key"
            )
        }

        guard !raw.contains("$(") else {
            throw BundleTestError.buildConfigurationUndetectable(
                bundle: bundle.path,
                reason:
                    "'\(BundleTestSupport.buildConfigurationKey)' is still the unexpanded literal '\(raw)', so Xcode did not substitute it"
            )
        }

        guard let configuration = BundleTestSupport.BuildConfiguration(rawValue: raw) else {
            throw BundleTestError.buildConfigurationUndetectable(
                bundle: bundle.path,
                reason:
                    "it was built with configuration '\(raw)', which has no entitlement policy here (known: \(BundleTestSupport.BuildConfiguration.allCases.map(\.rawValue).sorted().joined(separator: ", ")))"
            )
        }

        // Corroboration. Only an exact configuration name counts as a contradiction; anything else
        // is a directory that happens to hold an app and is ignored.
        let enclosing = bundle.deletingLastPathComponent().lastPathComponent
        if let fromPath = BundleTestSupport.BuildConfiguration(rawValue: enclosing),
            fromPath != configuration
        {
            throw BundleTestError.buildConfigurationMismatch(
                bundle: bundle.path,
                reported: configuration.rawValue,
                contradictedBy: "it sits in a build-products directory named '\(enclosing)'")
        }

        return configuration
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
    ///
    /// ## Why a regex and not two `contains` calls
    ///
    /// The first version of this asserted `report.contains("flags=") && report.contains("runtime")`
    /// over `codesign`'s whole report — which begins `Executable=<the path this test was handed>`.
    /// Measured: a bundle copied to `…/scratchpad/runtime/Vocca.app` and re-signed `--sign -`
    /// reports `flags=0x2(adhoc)`, has no hardened runtime whatsoever, and passes, because the word
    /// "runtime" is in its *path*. `VOCCA_APP_BUNDLE` is caller-supplied, so the input that decides
    /// the verdict is partly under the control of whoever runs the test.
    ///
    /// The flags line is therefore matched as a unit: `flags=0x…(` followed by a flag list that
    /// contains `runtime` before the closing paren. `0x10002(adhoc,runtime)` matches — an ad-hoc
    /// build with the runtime really enabled is what CI produces and is legitimate here.
    /// `0x2(adhoc)` does not, wherever the file happens to live.
    func testBuiltBundleIsSignedWithTheHardenedRuntime() throws {
        let bundle = try locateBundle()
        let output = try run("/usr/bin/codesign", ["-d", "--verbose=2", bundle.path])
        // codesign prints its report on stderr.
        let report = output.standardError + output.standardOutput

        let flagsPattern = try NSRegularExpression(pattern: #"flags=0x[0-9a-fA-F]+\([^)]*runtime"#)
        let hardened =
            flagsPattern.firstMatch(
                in: report, range: NSRange(report.startIndex..., in: report)) != nil

        // Reported separately, because "no flags line at all" and "a flags line without runtime"
        // are different failures: the first means codesign's output format changed underneath this
        // test and the assertion has stopped measuring anything, which is the worse of the two.
        let flagsLine = report.split(separator: "\n").first { $0.contains("flags=") }
        XCTAssertNotNil(
            flagsLine,
            """
            codesign's report for \(bundle.path) contains no 'flags=' line at all, so this test \
            cannot tell whether the hardened runtime is enabled. Its output format has changed; \
            fix the parser rather than the assertion.
            codesign said:
            \(report)
            """)

        XCTAssertTrue(
            hardened,
            """
            The built bundle is not signed with the hardened runtime. The entitlement assertions \
            above are about behaviour under hardened runtime, and TCC treats a non-hardened build \
            as a different, less trusted identity.
            Looked for 'runtime' inside the flag list of the signature's flags= line, which is \
            \(flagsLine.map(String.init) ?? "<no flags= line>"). Matching 'runtime' anywhere in \
            the report is not enough: codesign echoes the bundle path, so a bundle under a \
            directory named 'runtime' passed that check while signed flags=0x2(adhoc).
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
