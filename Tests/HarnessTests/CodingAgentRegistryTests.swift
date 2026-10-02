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
import Synchronization
import VoccaActions
import XCTest

/// The persisted coding-agent definitions store — the `agent-registry` aspect's whole contract
/// (`coding-agent-handoff` PRD R1, spec acceptance 1-8): **`coding-agents.json`**, the user's
/// hand-editable map from an agent id to the binary that runs, what it is told, where it works
/// and how long it may run.
///
/// ## What the file may and may not hold
///
/// The file holds **definitions only**: id, absolute executable path, fixed argv, an optional
/// absolute project directory, a timeout with a default, an optional environment, and an
/// optional plain-text clause. **No enablement, no timestamps and no `readOnly` ever reach it** —
/// enablement lives in `action-config.json`, and an agent is never read-only by construction.
/// The byte pin below asserts the key sets on the artifact, and a hand-edited file that grows
/// such a key is refused rather than read (the wildcard-key refusal precedent,
/// `ActionConfig.swift:57-71`).
///
/// ## The project directory is optional — absence is a row, not a violation
///
/// A row without a `projectDirectory` key — or with a blank one — is the **nil-directory
/// row**: valid, loading quietly, the arm-time resolution's row (an empty editor field
/// resolves the focused app's project at arm). Only a **filled-in** directory is judged: it
/// must be absolute and must not start with `~`, and a row that violates that is skipped
/// loudly. The encoder writes the absent spelling only — nil never becomes a blank key.
///
/// ## The two tolerances are one policy
///
/// Corrupt bytes are **never fatal** (absent/corrupt/oversized/wrong-version file → empty
/// registry, one loud log) and invalid rows are **never fatal either** (a duplicate id, an
/// over-long id, a non-string executable path, an out-of-range timeout or an over-cap argv or
/// environment is skipped loudly, the rest load) — the `ActionConfigStore` enablement-row skip
/// precedent, in the `IntentPhraseStore` `LossyRow` spelling. The F1 lesson holds: a `1` where
/// the schema demands a string is refused, never coerced.
///
/// ## The shape of the assertions
///
/// Everything load-bearing runs through the real store over real temp directories, with the
/// file-system seam injected where the claim is about the commit protocol (tmp + rename-over)
/// or about a torn write — the `ActionConfigStoreTests` shape, whose doubles this file reuses.
final class CodingAgentRegistryTests: XCTestCase {

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-coding-agents-\(UUID().uuidString)")
    }

    private static let fileName = "coding-agents.json"

    /// Writes `text` as the file's raw bytes — a hand-edit, which is the threat model.
    private func writeRaw(_ text: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: directory.appendingPathComponent(Self.fileName))
    }

    /// The stored file's bytes, read with `FileManager` directly — the assertions below are
    /// about the artifact, not about a reader's opinion of it.
    private func bytes(in directory: URL) -> Data? {
        FileManager.default.contents(
            atPath: directory.appendingPathComponent(Self.fileName).path)
    }

    private func jsonString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// One raw `agents[]` element, hand-written — every field optional so a planted row can
    /// omit exactly the field under test.
    private func agent(
        _ id: String, executable: String = "/usr/local/bin/code-agent",
        arguments: [String] = ["-serve"], projectDirectory: String? = "/Users/alice/Projects/work",
        timeout: Int? = 30, environment: [String: String]? = ["ANTHROPIC_API_KEY": "sk-test"],
        clause: String? = "Runs the coding agent."
    ) -> String {
        var fields = [
            "id": jsonString(id),
            "executablePath": jsonString(executable),
            "arguments":
                "[" + arguments.map { jsonString($0) }.joined(separator: ", ") + "]",
        ]
        if let projectDirectory { fields["projectDirectory"] = jsonString(projectDirectory) }
        if let timeout { fields["timeoutSeconds"] = "\(timeout)" }
        if let environment {
            fields["environment"] =
                "{"
                + environment.map { "\(jsonString($0.key)): \(jsonString($0.value))" }
                    .joined(separator: ", ")
                + "}"
        }
        if let clause { fields["clause"] = jsonString(clause) }
        return "{ " + fields.map { "\(jsonString($0.key)): \($0.value)" }.joined(separator: ", ")
            + " }"
    }

    private func file(_ rows: [String], version: String = "1") -> String {
        #"{"version": \#(version), "agents": [\#(rows.joined(separator: ", "))]}"#
    }

    /// A valid definition for assertions — force-unwrapped because the fixture's literals are
    /// all within the row's own contract.
    private func makeAgent(
        id: String, executablePath: String = "/usr/local/bin/code-agent",
        arguments: [String] = ["-serve"], projectDirectory: String? = "/Users/alice/Projects/work",
        timeoutSeconds: Int = 30, environment: [String: String]? = ["ANTHROPIC_API_KEY": "sk-test"],
        clause: String? = "Runs the coding agent."
    ) -> CodingAgentDefinition {
        CodingAgentDefinition(
            id: id, executablePath: executablePath, arguments: arguments,
            projectDirectory: projectDirectory, timeoutSeconds: timeoutSeconds,
            environment: environment, clause: clause)!
    }

    // MARK: - Acceptance 1 — absent is empty, quietly

    /// No file is the first-launch default: the empty registry, nothing to complain about, and
    /// nothing created on disk.
    func testAnAbsentFileIsTheEmptyRegistryAndLogsNothing() async {
        let directory = Self.tempDirectory()
        let complaints = ComplaintRecorder()

        let loaded = await CodingAgentRegistry(directory: directory, log: complaints.log).load()

        XCTAssertEqual(loaded, .empty)
        XCTAssertEqual(complaints.recorded, [])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "load creates nothing, writes nothing, and leaves the disk exactly as it found it")
    }

    // MARK: - Acceptance 2 — unreadable files are empty, loudly, and never rewritten

    /// A file that is not the shape — garbage, a non-object top level, a version this build
    /// does not read — loads empty with exactly one complaint each.
    func testAnUnreadableOrNonObjectOrWrongVersionFileIsEmptyWithOneLog() async throws {
        let cases = [
            "not json at all",
            #"[{"id": "a", "executablePath": "/bin/x"}]"#,
            file([agent("a")], version: "2"),
            file([agent("a")], version: "true"),
        ]
        for text in cases {
            let directory = Self.tempDirectory()
            try writeRaw(text, in: directory)
            let complaints = ComplaintRecorder()

            let loaded = await CodingAgentRegistry(directory: directory, log: complaints.log).load()

            XCTAssertEqual(loaded, .empty, "'\(text)' must load empty")
            XCTAssertEqual(complaints.recorded.count, 1, "'\(text)' must complain exactly once")
        }
    }

    /// A file over the byte cap is refused whole — never read partially.
    func testAnOversizeFileLoadsEmptyWithOneLog() async throws {
        let directory = Self.tempDirectory()
        let padding = String(repeating: " ", count: CodingAgentRegistry.maximumFileBytes)
        try writeRaw(file([agent("a")]) + padding, in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await CodingAgentRegistry(directory: directory, log: complaints.log).load()

        XCTAssertEqual(loaded, .empty)
        XCTAssertEqual(complaints.recorded.count, 1)
    }

    /// A failed load never rewrites the user's file: the bytes after equal the bytes before.
    func testLoadNeverWritesTheUsersFile() async throws {
        let directory = Self.tempDirectory()
        try writeRaw(#"{"version": 1, "agents": [ oops"#, in: directory)
        let before = bytes(in: directory)

        _ = await CodingAgentRegistry(directory: directory, log: { _ in }).load()

        XCTAssertEqual(bytes(in: directory), before)
    }

    /// A key this build cannot name is refused at **every level** of the shape — the byte-pin's
    /// decode half: an extra top-level key (an `enablement` section that belongs in the config
    /// store, never here) refuses the whole file; a `readOnly` field planted on a row refuses
    /// that row — an agent is never read-only, and the key set must not contain it.
    func testAnUnknownKeyIsRefusedAtEveryLevelOfTheShape() async throws {
        let directory = Self.tempDirectory()
        try writeRaw(
            file([
                agent("keeper"),
                #"{"id": "planted", "executablePath": "/usr/local/bin/code-agent", "arguments": ["-serve"], "projectDirectory": "/Users/alice/Projects/work", "timeoutSeconds": 30, "readOnly": true}"#,
            ]),
            in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await CodingAgentRegistry(directory: directory, log: complaints.log).load()

        XCTAssertEqual(
            loaded.agents.map(\.id), ["keeper"],
            "the row-level unknown key refuses that row, never its neighbours")
        XCTAssertEqual(complaints.recorded.count, 1, "and the row refusal is loud, once")

        // The top-level plant refuses the whole file, loudly, once.
        let topLevelDirectory = Self.tempDirectory()
        try writeRaw(
            #"{"version": 1, "agents": [], "enablement": []}"#, in: topLevelDirectory)
        let topLevelComplaints = ComplaintRecorder()
        let topLevelLoaded = await CodingAgentRegistry(
            directory: topLevelDirectory, log: topLevelComplaints.log).load()

        XCTAssertEqual(topLevelLoaded, .empty, "a top-level unknown key refuses the whole file")
        XCTAssertEqual(topLevelComplaints.recorded.count, 1)
    }

    // MARK: - Acceptance 3 — the F1 no-coercion rule

    /// The F1 lesson, named: a number or a string where the schema demands the other is
    /// refused, never coerced — `"executablePath": 1` cannot name a binary, and
    /// `"timeoutSeconds": "30"` cannot tell time.
    func testANonStringExecutablePathIsRefusedNeverCoerced() async throws {
        let directory = Self.tempDirectory()
        try writeRaw(
            file([
                #"{"id": "first", "executablePath": 1, "arguments": ["-serve"], "projectDirectory": "/Users/alice/Projects/work"}"#,
                #"{"id": "second", "executablePath": "/usr/local/bin/code-agent", "arguments": ["-serve"], "projectDirectory": "/Users/alice/Projects/work", "timeoutSeconds": "30"}"#,
                #"{"id": "third", "executablePath": true, "arguments": ["-serve"], "projectDirectory": "/Users/alice/Projects/work"}"#,
                agent("keeper"),
            ]),
            in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await CodingAgentRegistry(directory: directory, log: complaints.log).load()

        XCTAssertEqual(
            loaded.agents.map(\.id), ["keeper"],
            "the coerced rows are refused, never read as strings — the rest load")
        XCTAssertEqual(complaints.recorded.count, 3, "one loud complaint per refused row")
    }

    // MARK: - Acceptance 4 — the timeout semantics

    /// Absent `timeoutSeconds` defaults to 30; a timeout below 1 or above 600 is skipped
    /// loudly — refuse never clamp, and 0 is not the same fact as absent.
    func testATimeoutOutsideTheRangeIsSkippedLoudlyAndAbsentDefaultsToThirty() async throws {
        let directory = Self.tempDirectory()
        try writeRaw(
            file([
                agent("absent"),
                agent("zero", timeout: 0),
                agent("negative", timeout: -5),
                agent("over", timeout: 601),
                agent("ceiling", timeout: 600),
                agent("floor", timeout: 1),
            ]),
            in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await CodingAgentRegistry(directory: directory, log: complaints.log).load()

        XCTAssertEqual(
            loaded.agents.map(\.id), ["absent", "ceiling", "floor"],
            "0, -5 and 601 are skipped; 1, 600 and absent survive")
        XCTAssertEqual(
            loaded.agents[0].timeoutSeconds, 30,
            "absent means the default, not a zero that must be refused")
        XCTAssertEqual(loaded.agents[1].timeoutSeconds, 600, "the cap is inclusive")
        XCTAssertEqual(loaded.agents[2].timeoutSeconds, 1, "the floor is inclusive")
        XCTAssertEqual(complaints.recorded.count, 3, "one loud complaint per skipped row")
    }

    // MARK: - Acceptance 5 — the row caps

    /// A row over any of the named caps — more than 64 argv elements, more than 16 environment
    /// entries, a key or value over 256 characters, an id over 128 characters — is skipped
    /// loudly, never truncated; the valid rows load.
    func testRowsOverTheArgvEnvAndIDCapsAreSkippedLoudly() async throws {
        let directory = Self.tempDirectory()
        let longID = String(repeating: "x", count: CodingAgentRegistry.maximumIDLength + 1)
        let longKey = String(repeating: "k", count: 257)
        let longValue = String(repeating: "v", count: 257)
        try writeRaw(
            file([
                agent("keeper"),
                agent(
                    "many-args",
                    arguments: (1...CodingAgentRegistry.maximumArgumentCount + 1).map {
                        "arg\($0)"
                    }),
                agent(
                    "many-env",
                    environment: Dictionary(
                        uniqueKeysWithValues: (1...CodingAgentRegistry.maximumEnvironmentEntries + 1)
                            .map { ("K\($0)", "v") })),
                agent(longID),
                agent("long-env-key", environment: [longKey: "v"]),
                agent("long-env-value", environment: ["K": longValue]),
            ]),
            in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await CodingAgentRegistry(directory: directory, log: complaints.log).load()

        XCTAssertEqual(
            loaded.agents.map(\.id), ["keeper"],
            "each over-cap row is refused whole — never truncated into a different row")
        XCTAssertEqual(complaints.recorded.count, 5, "one loud complaint per skipped row")
    }

    // MARK: - Acceptance 6 — duplicate ids

    /// Two rows with the same id: the first wins, the duplicate is skipped loudly — the file's
    /// own order decides, and nothing downstream can see an ambiguity.
    func testADuplicateIDKeepsTheFirstRow() async throws {
        let directory = Self.tempDirectory()
        try writeRaw(
            file([
                agent("first", arguments: ["-serve"]),
                agent("first", arguments: ["-other"]),
                agent("second"),
            ]),
            in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await CodingAgentRegistry(directory: directory, log: complaints.log).load()

        XCTAssertEqual(loaded.agents.map(\.id), ["first", "second"])
        XCTAssertEqual(
            loaded.agents[0].arguments, ["-serve"],
            "the first row's whole definition wins — the duplicate never replaces any of it")
        XCTAssertEqual(complaints.recorded.count, 1, "the duplicate is loud, once")
    }

    // MARK: - The row-shape rules: absolute, non-empty paths

    /// `executablePath` is **absolute** — no PATH lookup, the MCP precedent — and non-empty;
    /// a **filled-in** `projectDirectory` is absolute too. A row that violates either is
    /// skipped loudly — but a row with no project directory at all (the blank spelling) is a
    /// **valid** nil-directory row: the arm-time resolution's row, never a violation.
    func testAnEmptyExecutableOrRelativePathIsSkippedAndABlankProjectDirectoryIsValid() async throws {
        let directory = Self.tempDirectory()
        try writeRaw(
            file([
                agent("empty-exec", executable: ""),
                agent("relative-exec", executable: "code-agent"),
                agent("tilde-exec", executable: "~/bin/code-agent"),
                agent("blank-project", projectDirectory: ""),
                agent("relative-project", projectDirectory: "Projects/work"),
                agent("keeper"),
            ]),
            in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await CodingAgentRegistry(directory: directory, log: complaints.log).load()

        XCTAssertEqual(
            loaded.agents.map(\.id), ["blank-project", "keeper"],
            "a binary that must be found through a PATH is a different contract — refused; a "
                + "blank project directory is the valid nil-directory row, never a violation")
        XCTAssertNil(
            loaded.agents[0].projectDirectory,
            "the blank spelling is the nil-directory row — the arm-time resolution's row")
        XCTAssertEqual(complaints.recorded.count, 5, "one loud complaint per skipped row")
    }

    /// **A blank or absent `projectDirectory` key is a valid nil-directory row, loading
    /// quietly** — the blank spelling (a hand-edit of the same fact) and the absent spelling
    /// are one row: valid, nil-directory, and no louder than any other valid row. The F1
    /// reading: a blank directory is the *same fact* as an absent one (unlike
    /// `timeoutSeconds: 0`, which the pinned tests call a different fact from absent), so
    /// nothing is being read as a different value, and nothing is owed a log.
    func testABlankOrAbsentProjectDirectoryKeyIsAValidNilDirectoryRow() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRaw(
            file([
                #"{"id": "blank", "executablePath": "/usr/local/bin/code-agent", "arguments": ["-serve"], "projectDirectory": "", "timeoutSeconds": 30}"#,
                #"{"id": "absent", "executablePath": "/usr/local/bin/code-agent", "arguments": ["-serve"], "timeoutSeconds": 30}"#,
            ]),
            in: directory)
        let complaints = ComplaintRecorder()

        let loaded = await CodingAgentRegistry(directory: directory, log: complaints.log).load()

        XCTAssertEqual(
            loaded.agents.map(\.id), ["blank", "absent"],
            "a blank or absent project directory is the valid nil-directory row — the "
                + "arm-time resolution's row, not a row to skip")
        XCTAssertNil(loaded.agents[0].projectDirectory, "the blank spelling reads as nil")
        XCTAssertNil(loaded.agents[1].projectDirectory, "the absent spelling reads as nil")
        XCTAssertEqual(
            complaints.recorded, [],
            "a valid row is not a failure — the quiet load is the honest load")
    }

    // MARK: - Acceptance 7 — save round trip and atomicity

    /// **Save, reload, and the semantics are byte-identical** — the file is the whole of the
    /// store's memory, so a reload through the same directory cannot disagree with what was
    /// saved, and loading never rewrites the bytes a user can see and edit.
    func testSaveRoundTripsAndLoadingNeverRewritesTheBytes() async throws {
        let directory = Self.tempDirectory()

        let file = CodingAgentFile(agents: [
            makeAgent(
                id: "planner",
                executablePath: "/usr/local/bin/code-agent",
                arguments: ["-serve", "--project"],
                projectDirectory: "/Users/alice/Projects/work",
                timeoutSeconds: 90,
                environment: ["ANTHROPIC_API_KEY": "sk-test", "VOCCA_AGENT": "1"],
                clause: "Plans and edits code in the active project."),
            makeAgent(
                id: "minimal", arguments: [], timeoutSeconds: 30, environment: nil,
                clause: nil),
        ])
        let store = CodingAgentRegistry(directory: directory)
        try await store.save(file)
        let savedBytes = try XCTUnwrap(
            bytes(in: directory),
            "vacuity guard: the save must have written the file, or the round trip proves nothing")

        let reloaded = await store.load()

        XCTAssertEqual(reloaded, file, "the reloaded registry is exactly what was saved")
        let secondLoad = await store.load()
        XCTAssertEqual(secondLoad, reloaded, "a second load agrees with the first")
        let unchangedBytes = try XCTUnwrap(
            bytes(in: directory), "vacuity guard: the file must still exist after the loads")
        XCTAssertEqual(
            unchangedBytes, savedBytes,
            "loading must never rewrite the file — a failed parse or a skipped row must not "
                + "change the bytes a user can see and edit")
    }

    /// **A nil-directory row round-trips with absence as its one spelling** — the row the
    /// editor's empty Project directory field saves (the arm-time resolution's row): save,
    /// and the file's bytes carry **no** `projectDirectory` key at all; reload, and the row
    /// comes back with nil, exactly as saved. Absence has one spelling — a nil directory is
    /// never encoded as a blank value.
    func testANilDirectoryRowRoundTripsWithAbsenceAsTheOneSpelling() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodingAgentRegistry(directory: directory)

        let file = CodingAgentFile(agents: [
            makeAgent(id: "detect-me", projectDirectory: nil, environment: nil, clause: nil)
        ])
        try await store.save(file)
        let text = String(decoding: try XCTUnwrap(bytes(in: directory)), as: UTF8.self)
        XCTAssertFalse(
            text.contains("projectDirectory"),
            "absence has one spelling — a nil directory encodes to no key at all, never a blank")

        let reloaded = await store.load()
        XCTAssertEqual(reloaded, file, "the reloaded registry is exactly what was saved")
        XCTAssertEqual(reloaded.agents.count, 1)
        XCTAssertNil(
            reloaded.agents[0].projectDirectory,
            "the nil-directory row survives the round trip as nil")
    }

    /// A save is the **atomic temp-write-then-rename pair**, recorded through the injected seam —
    /// the config store's commit protocol, for the registry file.
    func testASaveIsATempWriteRenamedOverTheFileName() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingActionConfigFileSystem(directory: directory)
        let store = CodingAgentRegistry(directory: directory, fileSystem: fileSystem)

        try await store.save(CodingAgentFile(agents: [makeAgent(id: "planner")]))

        let events = await fileSystem.events
        XCTAssertEqual(
            events, [.tempWrite("coding-agents.json.tmp"), .rename("coding-agents.json")],
            """
            the commit is a temp write renamed over the final name, in that order. The store \
            must not answer before the rename: a crash between the two steps must leave a file \
            nothing can read, never a half-written registry that loads as truth.
            """)
    }

    /// **A torn write never yields a partially-committed file the store would load** — the
    /// failure the atomic pair exists for, simulated through the seam.
    func testATornCommitNeverYieldsAPartiallyCommittedFileTheStoreWouldLoad() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodingAgentRegistry(
            directory: directory, fileSystem: TornWriteActionConfigFileSystem())

        do {
            try await store.save(CodingAgentFile(agents: [makeAgent(id: "planner")]))
            XCTFail(
                "a commit that cannot rename must fail loudly — a caller that cannot tell thinks "
                    + "the registry was persisted")
        } catch {
            // Expected: the torn commit surfaces to the caller.
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(
            names, ["coding-agents.json.tmp"],
            "the torn write leaves only the temp file — never a committed-looking name")
        let loaded = await CodingAgentRegistry(directory: directory).load()
        XCTAssertEqual(
            loaded, .empty,
            "and the store's own reader sees the empty registry: a .tmp is not a registry, "
                + "however well-formed its bytes are")
    }

    /// A `.tmp` file is **invisible to load by name**, and the next save's commit replaces it —
    /// recovery from a crash is a fresh save, not a repair of the residue.
    func testATempFileIsInvisibleToLoadAndTheNextSaveRecovers() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let orphan = directory.appendingPathComponent(Self.fileName + ".tmp")
        try CodingAgentRegistry.encode(
            CodingAgentFile(agents: [makeAgent(id: "stale")])
        ).write(to: orphan)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: orphan.path),
            "vacuity guard: the mid-commit file must actually be on disk for its invisibility "
                + "to mean anything")

        let loaded = await CodingAgentRegistry(directory: directory).load()
        XCTAssertEqual(
            loaded, .empty,
            "a .tmp is not the registry file — the name is the whole of the atomic protocol's "
                + "read side")

        let file = CodingAgentFile(agents: [makeAgent(id: "recovered")])
        try await CodingAgentRegistry(directory: directory).save(file)
        let reloaded = await CodingAgentRegistry(directory: directory).load()
        XCTAssertEqual(
            reloaded, file,
            "the next save commits over the residue — recovery is a fresh atomic commit, never "
                + "a repair of the torn file")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(
            names, [Self.fileName],
            "and the directory holds exactly the one committed file afterwards")
    }

    /// **Two store instances over the same directory see the same registry** — the file, never
    /// a held value, is the memory.
    func testTwoStoresOverTheSameDirectorySeeTheSameRegistry() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = CodingAgentFile(agents: [makeAgent(id: "planner")])
        try await CodingAgentRegistry(directory: directory).save(file)

        let second = await CodingAgentRegistry(directory: directory).load()
        let third = await CodingAgentRegistry(directory: directory).load()

        XCTAssertEqual(second, file, "a second instance reads what the first wrote")
        XCTAssertEqual(third, file, "and a third reads the same — no instance has a private view")
    }

    /// **More than 16 agents are refused loudly, and the 16th saves.** A cap refused rather
    /// than clamped: a registry the store silently shrinks is an agent the user believes
    /// configured.
    func testMoreThanSixteenAgentsAreRefusedLoudlyAndSixteenSave() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let atTheCap = CodingAgentFile(
            agents: (1...CodingAgentRegistry.maximumAgents).map { makeAgent(id: "agent-\($0)") })
        let store = CodingAgentRegistry(directory: directory)
        try await store.save(atTheCap)
        let reloadedAtTheCap = await store.load()
        XCTAssertEqual(
            reloadedAtTheCap.agents.count, CodingAgentRegistry.maximumAgents,
            "vacuity guard: exactly 16 agents save and reload — the cap is inclusive")

        let oneOver = CodingAgentFile(
            agents: (1...(CodingAgentRegistry.maximumAgents + 1)).map {
                makeAgent(id: "agent-\($0)")
            })
        do {
            try await store.save(oneOver)
            XCTFail("a 17th agent must be refused — a cap that clamps is a lie to the user")
        } catch let error as CodingAgentRegistryError {
            XCTAssertEqual(
                error, .tooManyAgents(CodingAgentRegistry.maximumAgents + 1),
                "the refusal names the count, so the caller can tell the user what was refused")
        }
        XCTAssertEqual(
            bytes(in: directory), try CodingAgentRegistry.encode(atTheCap),
            "the refused save left the previously committed file byte-identical — the refusal "
                + "happens before the file system is touched")
    }

    /// **A file over the 64 KB byte cap is refused loudly, and the prior file stays intact.**
    func testAFilesOverTheByteCapAreRefusedLoudlyAndThePriorFileStaysIntact() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CodingAgentRegistry(directory: directory)
        let prior = CodingAgentFile(agents: [makeAgent(id: "keeper")])
        try await store.save(prior)

        let overCap = CodingAgentFile(
            agents: (1...CodingAgentRegistry.maximumAgents).map {
                makeAgent(id: "big-\($0)", clause: String(repeating: "z", count: 5000))
            })
        do {
            try await store.save(overCap)
            XCTFail("a file over the byte cap must be refused — an unbounded file is a lie")
        } catch let error as CodingAgentRegistryError {
            guard case .fileTooLarge = error else {
                return XCTFail("the refusal must name the byte cap: \(error)")
            }
        }
        XCTAssertEqual(
            bytes(in: directory), try CodingAgentRegistry.encode(prior),
            "the refused save left the previously committed file byte-identical")
    }

    /// Sorted keys: the same table encodes to the same bytes every time, so a hand-edited,
    /// version-controlled file never re-orders itself between runs.
    func testEncodeIsByteStable() throws {
        let file = CodingAgentFile(agents: [makeAgent(id: "planner")])

        XCTAssertEqual(try CodingAgentRegistry.encode(file), try CodingAgentRegistry.encode(file))
    }

    // MARK: - Acceptance 8 — the byte-level pin

    /// **The encoder emits exactly the named fields, and no `readOnly` key can reach the
    /// bytes.**
    ///
    /// The key-set pins are the strong half: the top level is exactly `agents` + `version`, and
    /// an agent row is exactly its seven fields (five when `environment` and `clause` are
    /// absent, four when `projectDirectory` is nil too). A `readOnly` field fails here on the
    /// day it is added — an agent is never read-only, and the file's key set must not contain it.
    ///
    /// The presence assertions are the defence-in-depth half, and both are made non-vacuous: the
    /// file genuinely carries an environment and a clause, so an absence of the forbidden key is
    /// an absence in a populated file.
    func testTheEncodedBytesCarryExactlyTheNamedFieldsAndNoReadOnly() throws {
        let file = CodingAgentFile(agents: [
            makeAgent(
                id: "planner",
                executablePath: "/usr/local/bin/code-agent",
                arguments: ["-serve", "--project"],
                projectDirectory: "/Users/alice/Projects/work",
                timeoutSeconds: 90,
                environment: ["ANTHROPIC_API_KEY": "sk-test"],
                clause: "Plans and edits code in the active project."),
            makeAgent(id: "minimal", arguments: [], environment: nil, clause: nil),
            makeAgent(id: "detect-me", projectDirectory: nil, environment: nil, clause: nil),
        ])
        XCTAssertFalse(file.agents.isEmpty, "vacuity guard")

        let data = try CodingAgentRegistry.encode(file)
        let text = String(decoding: data, as: UTF8.self)

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("the encoded bytes must decode as a JSON object")
        }
        XCTAssertEqual(
            Set(object.keys), ["agents", "version"],
            """
            the top level is exactly the two named sections. An enablement section fails here \
            on the day it is added. Got: \(Set(object.keys).sorted())
            """)
        let agents = try XCTUnwrap(object["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.count, 3, "vacuity guard: the pin runs against populated rows")
        XCTAssertEqual(
            Set(agents[0].keys),
            ["arguments", "clause", "environment", "executablePath", "id", "projectDirectory",
                "timeoutSeconds"],
            "a populated agent is exactly its seven named fields — no enablement, no timestamp, "
                + "no readOnly: \(agents[0].keys.sorted())")
        XCTAssertEqual(
            Set(agents[1].keys),
            ["arguments", "executablePath", "id", "projectDirectory", "timeoutSeconds"],
            "the absent optionals stay absent — five fields, no readOnly: \(agents[1].keys.sorted())")
        XCTAssertEqual(
            Set(agents[2].keys),
            ["arguments", "executablePath", "id", "timeoutSeconds"],
            "a nil-directory row is exactly its four fields — the key absent, never blank: "
                + "\(agents[2].keys.sorted())")

        XCTAssertTrue(text.contains("ANTHROPIC_API_KEY"), "vacuity guard: env genuinely populated")
        XCTAssertTrue(
            text.contains("Plans and edits code in the active project."),
            "vacuity guard: a clause genuinely populated")
        XCTAssertFalse(text.contains("\"readOnly\""), "no readOnly key can reach the bytes")
        XCTAssertFalse(text.contains("\"enablement\""), "no enablement key can reach the bytes")
    }

    /// The pinned file round-trips through the decoder, whole — a pin satisfied by an encoder
    /// that writes bytes nothing can read would be a file that looks like a registry and is none.
    func testThePinnedFileRoundTripsThroughTheDecoder() throws {
        let file = CodingAgentFile(agents: [makeAgent(id: "planner")])
        let complaints = ComplaintRecorder()

        let decoded = CodingAgentRegistry.decode(
            try CodingAgentRegistry.encode(file), onInvalid: complaints.log)

        XCTAssertEqual(decoded, file, "the round trip is lossless — that is the persistence")
        XCTAssertEqual(complaints.recorded, [], "and silent: \(complaints.recorded)")
    }

    /// **The canonical bytes are pinned whole** — an empty registry is exactly the sorted-keys
    /// spelling of `{"version": 1, "agents": []}`, and a fixed table is the same table every
    /// time. A field added to the shape fails here on the day it lands.
    func testTheEncodedFileIsPinned() throws {
        let empty = CodingAgentFile.empty

        XCTAssertEqual(
            String(decoding: try CodingAgentRegistry.encode(empty), as: UTF8.self),
            #"{"agents":[],"version":1}"#,
            "the empty registry is exactly the canonical document — sorted keys, two sections")

        let fixed = CodingAgentFile(agents: [
            makeAgent(
                id: "planner", executablePath: "/usr/local/bin/code-agent",
                arguments: ["-serve"], projectDirectory: "/Users/alice/Projects/work",
                timeoutSeconds: 30, environment: nil, clause: nil)
        ])
        XCTAssertEqual(
            String(decoding: try CodingAgentRegistry.encode(fixed), as: UTF8.self),
            #"{"agents":[{"arguments":["-serve"],"executablePath":"\/usr\/local\/bin\/code-agent","id":"planner","projectDirectory":"\/Users\/alice\/Projects\/work","timeoutSeconds":30}],"version":1}"#,
            "a fixed table is the same bytes every time — sorted keys, optionals absent when nil")
    }

    /// **The nil-directory row's canonical bytes are pinned whole** — the shape an empty
    /// Project directory field saves (the arm-time resolution's row): every field but
    /// `projectDirectory`, which is **absent** — never blank, never a zero-length value.
    func testTheNilDirectoryRowIsPinnedWhole() throws {
        let file = CodingAgentFile(agents: [
            makeAgent(
                id: "planner", executablePath: "/usr/local/bin/code-agent",
                arguments: ["-serve"], projectDirectory: nil, timeoutSeconds: 30,
                environment: nil, clause: nil)
        ])

        XCTAssertEqual(
            String(decoding: try CodingAgentRegistry.encode(file), as: UTF8.self),
            #"{"agents":[{"arguments":["-serve"],"executablePath":"\/usr\/local\/bin\/code-agent","id":"planner","timeoutSeconds":30}],"version":1}"#,
            "the canonical nil-directory row carries no projectDirectory key — absence has one "
                + "spelling")
    }

    /// The static decoder is **never throwing**, whatever it is handed — "never throws" is only
    /// a claim until something ugly is handed to it.
    func testTheStaticDecoderNeverThrowsWhateverItIsHanded() {
        let complaints = ComplaintRecorder()
        let battery = [
            Data(), Data([0xff, 0xfe, 0x00]), Data("[]".utf8), Data("{}".utf8),
            Data(#"{"version":1}"#.utf8),
        ]
        for bytes in battery {
            XCTAssertEqual(
                CodingAgentRegistry.decode(bytes, onInvalid: complaints.log), .empty,
                "undecodable bytes answer the empty registry — a corrupt file must never be fatal")
        }
        XCTAssertEqual(
            complaints.recorded.count, battery.count,
            "every rejection is reported: \(complaints.recorded)")
    }

    // MARK: - Where the file lives

    /// The file lives at `<applicationSupport>/Vocca/coding-agents.json` — the
    /// `ActionConfigStore` directory shape, resolved as a pure function of what the file system
    /// answered.
    func testTheDefaultDirectoryIsApplicationSupportVocca() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support")

        XCTAssertEqual(
            CodingAgentRegistry.defaultDirectory(applicationSupport: support, home: home),
            support.appendingPathComponent("Vocca"))
        XCTAssertEqual(
            CodingAgentRegistry.defaultDirectory(applicationSupport: nil, home: home),
            support.appendingPathComponent("Vocca"))
    }
}

// MARK: - Test doubles

/// A recorder for the store's injected log — the loud half of the tolerance policy, made
/// observable so that "the skip is loud" is asserted rather than hoped.
private final class ComplaintRecorder: Sendable {
    private let messages = Mutex<[String]>([])

    var recorded: [String] { messages.withLock { $0 } }

    /// Captures `self` rather than the lock: `Mutex` is noncopyable, so it cannot be lifted into a
    /// local for the closure to hold.
    var log: @Sendable (String) -> Void {
        { message in self.messages.withLock { $0.append(message) } }
    }
}