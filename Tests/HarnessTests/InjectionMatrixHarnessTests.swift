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

/// **The injection matrix harness's own contract** (`matrix-smoke/spec.md` AC 1–2).
///
/// The matrix itself cannot run here — it needs a window server, Automation grants for two dozen
/// applications, a real microphone, a real pasteboard session, and for one of its rows, a week of
/// wall-clock time. What *can* run is the harness's self-check, and running it here is the whole
/// point: the row table lives in `Scripts/injection-matrix.sh` and the rows it drives are written
/// out in `docs/SMOKE_CHECKLIST.md`, which are one artifact in two files. A row added to one and
/// not the other is either a row nobody runs or a row nobody defined, and that drift is silent
/// unless something executes the check.
///
/// The tests below also make sure the check **can fail**. A self-check that passes on a mutilated
/// row table proves nothing, so two rows plant a violation in a copy of the script and require it
/// to be caught — the seeded-slow-injector discipline the latency and cleanup gates already use.
final class InjectionMatrixHarnessTests: XCTestCase {

    private var scratchRoots: [URL] = []

    override func tearDown() {
        for root in scratchRoots {
            try? FileManager.default.removeItem(at: root)
        }
        scratchRoots = []
        super.tearDown()
    }

    private struct ScriptResult {
        let status: Int32
        let output: String
    }

    private var repositoryRoot: URL {
        get throws { try PackageRootLocator.find(from: #filePath) }
    }

    private var scriptURL: URL {
        get throws { try repositoryRoot.appendingPathComponent("Scripts/injection-matrix.sh") }
    }

    @discardableResult
    private func run(_ script: URL, _ arguments: [String]) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ScriptResult(
            status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// A copy of the shipped script with one substitution applied, so a planted violation is
    /// tested against the real logic rather than against a re-implementation of it. The copy
    /// keeps the same relative depth so its `REPO_ROOT` still finds the checklist.
    private func scriptCopy(replacing old: String, with new: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-matrix-\(UUID().uuidString)")
        scratchRoots.append(root)
        let scripts = root.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        // The copy's REPO_ROOT is this scratch directory, so give it the real docs tree to grep.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try repositoryRoot.appendingPathComponent("docs/SMOKE_CHECKLIST.md"),
            to: root.appendingPathComponent("docs/SMOKE_CHECKLIST.md"))

        let source = try String(contentsOf: try scriptURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains(old), "The planted-violation anchor is no longer in the script.")
        let copy = scripts.appendingPathComponent("injection-matrix.sh")
        try source.replacingOccurrences(of: old, with: new)
            .write(to: copy, atomically: true, encoding: .utf8)
        return copy
    }

    // MARK: - The shipped harness

    /// The script parses. A harness nobody can run is a harness that does not exist, and its
    /// first real execution is a founder in front of twenty applications.
    func testTheHarnessIsSyntacticallyValid() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", try scriptURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus, 0,
            "Scripts/injection-matrix.sh does not parse:\n"
            + String(decoding: data, as: UTF8.self))
    }

    /// The self-check passes on the shipped table — and its output states the two numbers the
    /// gate is made of, so a table that quietly shrank below the 20-app bar is visible here.
    func testTheSelfCheckPassesAndReportsTheBar() throws {
        let result = try run(try scriptURL, ["--self-check"])
        XCTAssertEqual(result.status, 0, "self-check failed:\n\(result.output)")
        XCTAssertTrue(
            result.output.contains("20 deliverable"),
            """
            The matrix no longer has twenty deliverable rows. ROADMAP.md:172 judges P2 on a 20+ \
            app matrix, and the denominator of the >=95% figure is exactly this count.
            Output:
            \(result.output)
            """)
        XCTAssertTrue(
            result.output.contains("19 of 20"),
            "The self-check no longer states the >=95% bar it is measuring against.")
    }

    /// `--dry-run` must exit zero on a machine with none of the matrix applications — a CI runner
    /// is exactly that machine, and a dry run that failed there would make the mode useless for
    /// the one thing it is for.
    func testTheDryRunExitsZeroAndListsEveryRow() throws {
        let result = try run(try scriptURL, ["--dry-run"])
        XCTAssertEqual(result.status, 0, "dry-run failed:\n\(result.output)")
        for row in ["Notes", "Slack", "GoogleDocs", "Ghostty", "PasswordField"] {
            XCTAssertTrue(
                result.output.contains(row), "The dry run does not list the \(row) row.")
        }
    }

    /// An unknown argument is a loud, named failure rather than a silent full run — the script
    /// convention (`provision-cleanup-fixtures.sh`), and here it also means a typo cannot
    /// accidentally start driving twenty applications.
    func testAnUnknownArgumentIsRefused() throws {
        let result = try run(try scriptURL, ["--everything"])
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.output.contains("unknown argument"))
    }

    /// `--row` with a name the table does not have fails rather than running the whole matrix.
    func testAnUnknownRowIsRefused() throws {
        let result = try run(try scriptURL, ["--row", "Emacs"])
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.output.contains("no row named"))
    }

    // MARK: - The self-check can fail

    /// A row renamed in the script but not in the checklist is caught. This is the drift the
    /// check exists for: the two files are one artifact, and nothing else compares them.
    func testTheSelfCheckCatchesARowMissingFromTheChecklist() throws {
        let copy = try scriptCopy(
            replacing: "\"Notes|Notes|native-appkit|allowlist|accessibility|a new note\"",
            with: "\"Nootes|Notes|native-appkit|allowlist|accessibility|a new note\"")
        let result = try run(copy, ["--self-check"])
        XCTAssertNotEqual(
            result.status, 0,
            "A row that exists in the harness and not in the checklist passed the self-check.")
        XCTAssertTrue(result.output.contains("not named in the smoke checklist"))
    }

    /// A known-hostile row that expects a rung is caught. Secure Input refuses *before* any rung
    /// is attempted, so a row expecting one would pass for the exact failure it exists to forbid
    /// — the checklist's second preamble rule, enforced mechanically.
    func testTheSelfCheckCatchesAHostileRowThatExpectsARung() throws {
        let copy = try scriptCopy(
            replacing: "\"1Password|1Password|known-hostile|—|none|a password field\"",
            with: "\"1Password|1Password|known-hostile|—|clipboardPaste|a password field\"")
        let result = try run(copy, ["--self-check"])
        XCTAssertNotEqual(result.status, 0, "A hostile row expecting a rung passed the check.")
        XCTAssertTrue(result.output.contains("expects a rung"))
    }

    /// A rung outside the ladder's own vocabulary is caught — a row expecting something the log
    /// can never name is a row that can never pass, and would silently drag the number down.
    func testTheSelfCheckCatchesAnInventedRung() throws {
        let copy = try scriptCopy(
            replacing: "|clipboardPaste|an untitled buffer", with: "|magic|an untitled buffer")
        let result = try run(copy, ["--self-check"])
        XCTAssertNotEqual(result.status, 0, "A row expecting an invented rung passed the check.")
        XCTAssertTrue(result.output.contains("which the ladder never names"))
    }
}
