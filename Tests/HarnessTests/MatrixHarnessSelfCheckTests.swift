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
import XCTest

/// The matrix harness's headless contract, driven the way ``ProvisioningScriptTests`` drives
/// the provisioning script: a `Process` spawning `/bin/bash` with the script's own path —
/// never a copy of the script's logic.
///
/// The load-bearing pin is the **byte-compare normalization**: the harness compares the field's
/// captured bytes against `PHRASE` (`Scripts/injection-matrix.sh:66`), and the engine + rules
/// pipeline injects a capitalized, terminal-punctuated transcript ("The quick brown fox jumps
/// over the lazy dog.") — so a raw byte compare can never pass. The 2026-09-05 control-row run
/// surfaced exactly this: `session opened` + `delivery rung=clipboardPaste` were in the log,
/// yet every row failed `bytes_matched: false`. The self-check must fail loudly if the compare
/// regresses to the raw form, and pass with the normalized form.
///
/// Self-check needs no application, no grant and no window server (`injection-matrix.sh:186-190`).
final class MatrixHarnessSelfCheckTests: XCTestCase {

    private struct ScriptResult {
        let status: Int32
        let output: String
    }

    private var scriptURL: URL {
        get throws {
            try PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Scripts/injection-matrix.sh")
        }
    }

    private func runScript(arguments: [String]) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [try scriptURL.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return ScriptResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? "")
    }

    /// The self-check's own gate: the byte-compare treats the pipeline's punctuated transcript
    /// as matching the phrase, and a genuinely different transcript as a mismatch.
    func testTheSelfCheckPinsTheByteCompareNormalization() throws {
        let result = try runScript(arguments: ["--self-check"])
        XCTAssertEqual(
            result.status, 0,
            "the self-check must pass; output: \(result.output)")
        XCTAssertTrue(
            result.output.contains("phrase compare"),
            "the self-check must exercise the compare normalization; output: \(result.output)")
    }
}