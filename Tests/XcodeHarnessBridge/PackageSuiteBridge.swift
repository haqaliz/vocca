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

// MARK: - Why this target exists

/// ⌘U in Xcode, connected to the suite that actually exists.
///
/// ## The problem
///
/// The real suite is a SwiftPM test target (`HarnessTests` in `Package.swift`). `Vocca.xcodeproj`
/// consumes the package through an `XCLocalSwiftPackageReference` at `relativePath = "."` — the
/// package and the project share a directory — and Xcode does not surface a local package's *test*
/// targets to such a project's scheme. Measured: seven forms of `<TestableReference>` naming
/// `HarnessTests` (`ReferencedContainer` as `container:`, `container:.`, `container:Vocca`,
/// `container:Package.swift`, `container:Vocca.xcodeproj`, with and without an `.xctest`
/// `BuildableName`) all end in
///
///     xcodebuild: error: Failed to build project Vocca with scheme Vocca.:
///     There are no test bundles available to test.
///
/// With `<Testables>` left empty, ⌘U instead reports "Scheme Vocca is not currently configured for
/// the test action" (`xcodebuild test` exits 66). Loud rather than silent, but it means the one
/// keystroke a developer reaches for runs none of the 33 assertions that gate this project.
///
/// ## Why not compile the harness into an Xcode test target
///
/// It was considered and it does not work. `ZeroNetworkTests` runs the `VoccaNetworkProbe`
/// executable with `lib_VoccaNetworkInterposerTestFixture.dylib` interposed, and locates both
/// beside its own test bundle. `VoccaNetworkProbe` is an executable *target* with no package
/// *product*, so Xcode cannot build it at all. An Xcode target compiling the same sources would
/// therefore be a suite that silently omits the zero-network invariant — the one test this project
/// calls a permanent release blocker. A second, weaker copy of the suite is worse than no ⌘U.
///
/// ## What this does instead
///
/// One test, which runs the real thing: `Scripts/test-with-floor.sh`, the same entry point all
/// three CI jobs use, including its test-count floor. It cannot drift from what CI runs, because it
/// is not a copy of what CI runs — it is a call to it. ⌘U is slower than `swift test` in a terminal
/// and that is the correct trade: it is a bridge for the developer who reaches for ⌘U, not the
/// primary way to run the suite.
final class PackageSuiteBridgeTests: XCTestCase {

    /// Walks up from this file to the directory holding `Package.swift`. Mirrors the harness
    /// suites; never hardcodes an absolute path.
    private func packageRoot(from filePath: String = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path)
            {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate Package.swift by walking up from \(filePath)")
    }

    func testThePackageSuitePassesIncludingItsTestCountFloor() throws {
        let root = try packageRoot()
        let script = root.appendingPathComponent("Scripts/test-with-floor.sh")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: script.path),
            """
            \(script.path) is missing or not executable. It is the entry point every CI job uses; \
            if it moved, this bridge and .github/workflows/ci.yml both need updating.
            """)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = root

        // The environment has to be scrubbed, and this is not defensive tidying — without it the
        // nested run HANGS, reproducibly and forever.
        //
        // `xctest` exports `XCTestConfigurationFilePath` and friends to describe *this* test
        // session. `swift test` ends in another `xctest`, which inherits them, concludes it is a
        // worker for the outer session, and waits for instructions that never come. Measured: two
        // runs, both stuck at "Test Case … started" with a live `xctest VoccaPackageTests.xctest`
        // process, killed by hand.
        //
        // The `DYLD_*` variables are the same class of problem one layer down: injecting the outer
        // bundle's dyld state into an unrelated process is how the zero-network interposer works,
        // and ZeroNetworkTests sets `DYLD_INSERT_LIBRARIES` itself. Anything inherited here would
        // silently change what that test measures.
        //
        // `TOOLCHAINS`/`SDKROOT`/`DEVELOPER_DIR`/`SWIFT_EXEC` are milder: they would point the
        // nested `swift` at a toolchain chosen by Xcode rather than the one on PATH, so the suite
        // would not be built the way `swift test` in a terminal or in CI builds it.
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys
        where key.hasPrefix("XCTest") || key.hasPrefix("DYLD_")
            || ["TOOLCHAINS", "SDKROOT", "DEVELOPER_DIR", "SWIFT_EXEC", "SWIFT_PLATFORM_TARGET"]
                .contains(key)
        {
            environment.removeValue(forKey: key)
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(
            process.terminationStatus, 0,
            """
            Scripts/test-with-floor.sh failed (exit \(process.terminationStatus)). This is the real \
            suite, run exactly as CI runs it. Its output:
            \(output)
            """)
    }
}
