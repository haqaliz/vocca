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

/// The persisted `shell-commands.json` definitions store — the `command-registry` aspect's whole
/// contract (`shell-provider` PRD R1 + Data Model).
///
/// ## Why this file exists at all
///
/// The wedge's P4 promise is "voice → run commands / drive MCP tools / coding agents"
/// (`ROADMAP.md:41`). The MCP leg exists; the **run commands** leg does not. Before a
/// `ShellProvider` can describe or invoke anything, the configured command definitions must have
/// a single source of truth — this registry. No command exists unless it is configured here, and
/// nothing is configured out of the box.
///
/// ## What the file may and may not hold
///
/// The file holds **definitions only**: id, argv, the `readOnly` radius claim, the named
/// parameter slots, and an optional plain-text clause. **No enablement and no argument values
/// ever reach it** — enablement is membership in `ActionConfigStore` (providerID
/// `dev.vocca.shell` + command id), and argument values travel only at call time. The byte-pin
/// below asserts the key sets on the artifact, and a hand-edited file that grows such a key is
/// refused rather than read (the wildcard-key refusal precedent, `ActionConfig.swift:57-71`).
///
/// ## The two tolerances are one policy
///
/// Corrupt bytes are **never fatal** (absent/corrupt/unknown-key file → empty registry, one loud
/// log) and invalid rows are **never fatal either** (a duplicate id, an empty argv or an
/// over-long id is skipped loudly, the rest load) — the `ActionConfigStore` enablement-row skip
/// precedent. The difference between the two is which fact is being read: a file this build
/// cannot decode at all is a file read wrongly, while a row that fails validation is a row the
/// rest of the file can simply not include.
///
/// ## Destructive by default
///
/// An absent `readOnly` is `false` — the command claims the destructive radius (founder
/// decision, the MCP "absent means unsafe" precedent). `readOnly: true` is the only way to claim
/// a read-only radius, and the gate's escalate-only policy can only raise what the file claims,
/// never lower it.
///
/// ## The shape of the assertions
///
/// Everything load-bearing runs through the real store over real temp directories, with the
/// file-system seam injected where the claim is about the commit protocol (tmp + rename-over)
/// or about a torn write — the `ActionConfigStoreTests` shape, whose doubles this file reuses.
final class ShellCommandRegistryTests: XCTestCase {

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-shell-commands-\(UUID().uuidString)")
    }

    private func makeCommand(
        id: String, command: [String] = ["/bin/echo", "hello"],
        readOnly: Bool = false, parameters: [ShellCommandParameter] = [],
        clause: String? = nil
    ) -> ShellCommandDefinition {
        ShellCommandDefinition(
            id: id, command: command, readOnly: readOnly, parameters: parameters, clause: clause)
    }

    /// The stored file's bytes, read with `FileManager` directly — the assertions below are
    /// about the artifact, not about a reader's opinion of it.
    private func fileBytes(in directory: URL) -> Data? {
        FileManager.default.contents(
            atPath: directory.appendingPathComponent("shell-commands.json").path)
    }

    /// The PRD Data Model's example file, with a third command that omits `readOnly` and carries
    /// a named parameter — the absent-`readOnly` and parameters rows of acceptance 1.
    private static let wellFormedJSON = """
        {
          "version": 1,
          "commands": [
            {
              "id": "empty-downloads",
              "command": ["/usr/bin/find", "~/Downloads", "-type", "f", "-delete"],
              "readOnly": false,
              "parameters": [],
              "clause": "This cannot be undone."
            },
            {
              "id": "open-dashboard",
              "command": ["/usr/bin/open", "http://localhost:3000"],
              "readOnly": true,
              "parameters": [],
              "clause": "Opens the staging dashboard."
            },
            {
              "id": "list-backups",
              "command": ["/usr/bin/ls", "/var/backups"],
              "parameters": [{"name": "Backup set"}]
            }
          ]
        }
        """

    // MARK: - 1. Well-formed decode (acceptance 1)

    /// **A well-formed `shell-commands.json` decodes to the declared commands, with `readOnly`
    /// defaulting to `false` when absent.**
    ///
    /// The destructive-by-default rule is the founder decision at the heart of this aspect: a
    /// command whose file does not declare `readOnly: true` claims the destructive radius, and
    /// the gate's escalate-only policy can only raise what the file claims. The third command
    /// omits the key entirely and must read as `false`, never as `true` and never as an error.
    func testAWellFormedFileDecodesToTheDeclaredCommandsWithReadOnlyDefaultingToFalse() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.wellFormedJSON.utf8)
            .write(to: directory.appendingPathComponent("shell-commands.json"))

        let complaints = ComplaintRecorder()
        let loaded = await ShellCommandRegistry(directory: directory, log: complaints.log).load()

        let expected = ShellCommandFile(
            version: 1,
            commands: [
                makeCommand(
                    id: "empty-downloads",
                    command: ["/usr/bin/find", "~/Downloads", "-type", "f", "-delete"],
                    readOnly: false, parameters: [], clause: "This cannot be undone."),
                makeCommand(
                    id: "open-dashboard",
                    command: ["/usr/bin/open", "http://localhost:3000"],
                    readOnly: true, parameters: [], clause: "Opens the staging dashboard."),
                makeCommand(
                    id: "list-backups", command: ["/usr/bin/ls", "/var/backups"],
                    readOnly: false, parameters: [ShellCommandParameter(name: "Backup set")],
                    clause: nil),
            ])
        XCTAssertEqual(
            loaded, expected,
            "the declared commands decode exactly — order preserved, readOnly absent means false")
        XCTAssertEqual(
            complaints.recorded, [],
            "a well-formed file is read silently: \(complaints.recorded)")

        let staticDecoded = ShellCommandRegistry.decode(
            Data(Self.wellFormedJSON.utf8), onInvalidElement: complaints.log)
        XCTAssertEqual(
            staticDecoded, expected,
            "the static decoder agrees with the store's load — the file path and the bytes path "
                + "are the same reading")
    }

    // MARK: - 2. Tolerant decode (acceptance 2)

    /// **An absent file is the empty registry, and nothing is created** — the normal
    /// first-launch state is no file at all, not a file the store wrote behind the user's back.
    func testAnAbsentFileLoadsAsTheEmptyRegistryAndCreatesNothing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let complaints = ComplaintRecorder()
        let loaded = await ShellCommandRegistry(directory: directory, log: complaints.log).load()

        XCTAssertEqual(
            loaded, .empty,
            "no file means no commands — the registry has exactly one empty spelling")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "load creates nothing, writes nothing, and leaves the disk exactly as it found it")
        XCTAssertEqual(
            complaints.recorded, [],
            "absence is the normal state, not a failure — it is not even loud")
    }

    /// **A garbage file loads as the empty registry, loudly, and is never rewritten.**
    ///
    /// The `ActionConfigStore` precedent, whole: a corrupt file must never be fatal and must
    /// never be silently empty — the injected log is the loud half, asserted rather than hoped.
    /// The file's bytes are asserted unchanged afterwards: "empty registry" is a reading, never
    /// a repair that replaces what the user can go and look at.
    func testAGarbageFileLoadsAsTheEmptyRegistryLoudlyAndIsNeverRewritten() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("{ this is not a registry".utf8)
        try garbage.write(to: directory.appendingPathComponent("shell-commands.json"))

        let complaints = ComplaintRecorder()
        let loaded = await ShellCommandRegistry(directory: directory, log: complaints.log).load()

        XCTAssertEqual(
            loaded, .empty,
            "a corrupt file is an empty registry to a reader — never a throw, never a partial read")
        XCTAssertEqual(
            complaints.recorded.count, 1,
            "exactly one complaint — the skip is loud, or it is invisible: \(complaints.recorded)")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("shell-commands.json")),
            garbage,
            "the corrupt file's bytes are untouched — a failed load must never rewrite the "
                + "user's file")
    }

    /// **A boolean type confusion cannot claim read-only.** The MCP F1 lesson, applied here:
    /// `"readOnly": 1` must not read as the read-only radius — the destructive-by-default rule
    /// is the fail-safe, and a number where the schema demands a boolean is a corrupt file, not
    /// a claim.
    func testABooleanConfusionCannotClaimReadOnly() {
        let complaints = ComplaintRecorder()
        let planted = #"{"version":1,"commands":[{"id":"x","command":["/bin/echo","hi"],"readOnly":1,"parameters":[]}]}"#

        let decoded = ShellCommandRegistry.decode(
            Data(planted.utf8), onInvalidElement: complaints.log)

        XCTAssertNil(
            decoded,
            "a number in the readOnly slot is refused, never read as a claim of read-only — "
                + "absent means destructive is the fail-safe, and 1 must not defeat it")
        XCTAssertEqual(complaints.recorded.count, 1, "and the refusal is loud: \(complaints.recorded)")
    }

    /// **An unreadable file is the same tolerance, through the other half of the seam** — the
    /// read that cannot happen is not a crash either.
    func testAnUnreadableFileLoadsAsTheEmptyRegistryLoudly() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.wellFormedJSON.utf8)
            .write(to: directory.appendingPathComponent("shell-commands.json"))

        let complaints = ComplaintRecorder()
        let loaded = await ShellCommandRegistry(
            directory: directory, fileSystem: NilReadingActionConfigFileSystem(),
            log: complaints.log
        ).load()

        XCTAssertEqual(loaded, .empty, "an unreadable file is an empty registry, never a throw")
        XCTAssertEqual(complaints.recorded.count, 1, "and the failure is loud: \(complaints.recorded)")
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
            XCTAssertNil(
                ShellCommandRegistry.decode(bytes, onInvalidElement: complaints.log),
                "undecodable bytes answer nil — a corrupt file must never be fatal")
        }
        XCTAssertEqual(
            complaints.recorded.count, battery.count,
            "every rejection is reported: \(complaints.recorded)")
    }

    /// **A file with an unknown key is refused, at every level of the shape** — the byte-pin's
    /// decode half, in the ``ActionConfig`` precedent.
    ///
    /// Three planted files, one per level: an extra top-level key (an `enablement` section that
    /// belongs in the config store, never here), an extra key on a command row (a
    /// `rawArguments` a tool call would travel in), and an extra key on a parameter (an
    /// `arguments` slot). Each is refused — `nil` plus exactly one loud complaint — because a
    /// file read with a field this build cannot name is a file read wrongly, and the registry
    /// is shape-only by construction.
    func testAFileWithAnUnknownKeyIsRefusedPerTheBytePin() {
        let complaints = ComplaintRecorder()
        let planted: [String] = [
            #"{"version":1,"commands":[],"enablement":[]}"#,
            #"{"version":1,"commands":[{"id":"x","command":["/bin/echo","hi"],"readOnly":false,"parameters":[],"rawArguments":"hunter2"}]}"#,
            #"{"version":1,"commands":[{"id":"x","command":["/bin/echo","hi"],"readOnly":false,"parameters":[{"name":"Folder","arguments":"hunter2"}]}]}"#,
        ]

        for file in planted {
            XCTAssertNil(
                ShellCommandRegistry.decode(
                    Data(file.utf8), onInvalidElement: complaints.log),
                "a key this build cannot name is not a value to approximate: \(file)")
        }
        XCTAssertEqual(
            complaints.recorded.count, 3,
            "every planted file is refused loudly, once each: \(complaints.recorded)")
    }

    // MARK: - 3. Save round trip and atomicity (acceptance 3)

    /// **Save, reload, and the semantics are byte-identical** — the file is the whole of the
    /// store's memory, so a reload through the same directory cannot disagree with what was
    /// saved, and loading never rewrites the bytes a user can see and edit.
    func testSaveRoundTripsAndLoadingNeverRewritesTheBytes() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = ShellCommandFile(
            commands: [
                makeCommand(
                    id: "empty-downloads",
                    command: ["/usr/bin/find", "~/Downloads", "-type", "f", "-delete"],
                    readOnly: false, parameters: [], clause: "This cannot be undone."),
                makeCommand(
                    id: "open-dashboard",
                    command: ["/usr/bin/open", "http://localhost:3000"],
                    readOnly: true, parameters: [], clause: "Opens the staging dashboard."),
            ])
        let store = ShellCommandRegistry(directory: directory)
        try await store.save(file)
        let savedBytes = try XCTUnwrap(
            fileBytes(in: directory),
            "vacuity guard: the save must have written the file, or the round trip proves nothing")

        let reloaded = await store.load()

        XCTAssertEqual(reloaded, file, "the reloaded registry is exactly what was saved")
        let secondLoad = await store.load()
        XCTAssertEqual(
            secondLoad, reloaded,
            "and a second load over the same directory agrees with the first — the file, never "
                + "a held value, is the store's memory")
        let unchangedBytes = try XCTUnwrap(
            fileBytes(in: directory), "vacuity guard: the file must still exist after the loads")
        XCTAssertEqual(
            unchangedBytes, savedBytes,
            "loading must never rewrite the file — a failed parse or a skipped row must not "
                + "change the bytes a user can see and edit")
    }

    /// A save is the **atomic temp-write-then-rename pair**, recorded through the injected seam —
    /// the config store's commit protocol, for the registry file.
    func testASaveIsATempWriteRenamedOverTheFileName() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingActionConfigFileSystem(directory: directory)
        let store = ShellCommandRegistry(directory: directory, fileSystem: fileSystem)
        let file = ShellCommandFile(commands: [makeCommand(id: "list-files")])

        try await store.save(file)

        let events = await fileSystem.events
        XCTAssertEqual(
            events, [.tempWrite("shell-commands.json.tmp"), .rename("shell-commands.json")],
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
        let store = ShellCommandRegistry(
            directory: directory, fileSystem: TornWriteActionConfigFileSystem())

        do {
            try await store.save(ShellCommandFile(commands: [makeCommand(id: "list-files")]))
            XCTFail(
                "a commit that cannot rename must fail loudly — a caller that cannot tell thinks "
                    + "the registry was persisted")
        } catch {
            // Expected: the torn commit surfaces to the caller.
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(
            names, ["shell-commands.json.tmp"],
            "the torn write leaves only the temp file — never a committed-looking name")
        let loaded = await ShellCommandRegistry(directory: directory).load()
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
        let orphan = directory.appendingPathComponent("shell-commands.json.tmp")
        try ShellCommandRegistry.encode(
            ShellCommandFile(commands: [makeCommand(id: "stale")])
        ).write(to: orphan)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: orphan.path),
            "vacuity guard: the mid-commit file must actually be on disk for its invisibility "
                + "to mean anything")

        let loaded = await ShellCommandRegistry(directory: directory).load()
        XCTAssertEqual(
            loaded, .empty,
            "a .tmp is not the registry file — the name is the whole of the atomic protocol's "
                + "read side")

        let file = ShellCommandFile(commands: [makeCommand(id: "recovered")])
        try await ShellCommandRegistry(directory: directory).save(file)
        let reloaded = await ShellCommandRegistry(directory: directory).load()
        XCTAssertEqual(
            reloaded, file,
            "the next save commits over the residue — recovery is a fresh atomic commit, never "
                + "a repair of the torn file")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(
            names, ["shell-commands.json"],
            "and the directory holds exactly the one committed file afterwards")
    }

    /// **Two store instances over the same directory see the same registry** — the file, never
    /// a held value, is the memory, so no coordination between instances is possible or needed.
    func testTwoStoresOverTheSameDirectorySeeTheSameRegistry() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = ShellCommandFile(commands: [makeCommand(id: "list-files")])
        try await ShellCommandRegistry(directory: directory).save(file)

        let second = await ShellCommandRegistry(directory: directory).load()
        let third = await ShellCommandRegistry(directory: directory).load()

        XCTAssertEqual(second, file, "a second instance reads what the first wrote")
        XCTAssertEqual(third, file, "and a third reads the same — no instance has a private view")
    }

    // MARK: - 4. The caps (acceptance 3)

    /// **More than 64 commands are refused loudly, and the 64th saves.**
    ///
    /// A cap refused rather than clamped: a registry the store silently shrinks is a command the
    /// user believes configured. The refusal happens before anything touches the file system —
    /// the previously committed file stays byte-identical. 64 is a seed, like the C2 store's
    /// caps — a retune is a reviewed edit, not gospel.
    func testMoreThanSixtyFourCommandsAreRefusedLoudlyAndSixtyFourSave() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let atTheCap = ShellCommandFile(
            commands: (1...64).map { makeCommand(id: "command-\($0)") })
        let store = ShellCommandRegistry(directory: directory)
        try await store.save(atTheCap)
        let reloadedAtTheCap = await store.load()
        XCTAssertEqual(
            reloadedAtTheCap.commands.count, 64,
            "vacuity guard: exactly 64 commands save and reload — the cap is inclusive")

        let oneOver = ShellCommandFile(
            commands: (1...65).map { makeCommand(id: "command-\($0)") })
        do {
            try await store.save(oneOver)
            XCTFail("a 65th command must be refused — a cap that clamps is a lie to the user")
        } catch let error as ShellCommandRegistryError {
            XCTAssertEqual(
                error, .tooManyCommands(65),
                "the refusal names the count, so the caller can tell the user what was refused")
        }
        XCTAssertEqual(
            fileBytes(in: directory), try ShellCommandRegistry.encode(atTheCap),
            "the refused save left the previously committed file byte-identical — the refusal "
                + "happens before the file system is touched")
    }

    /// **A file over the 64 KB byte cap is refused loudly, and the prior file stays intact.**
    ///
    /// The second cap is on the encoded bytes themselves — a registry file is bounded, so a
    /// hand-edited file cannot grow without bound and a programmatic save cannot either.
    func testAFilesOverTheByteCapAreRefusedLoudlyAndThePriorFileStaysIntact() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ShellCommandRegistry(directory: directory)
        let prior = ShellCommandFile(commands: [makeCommand(id: "keeper")])
        try await store.save(prior)

        let overCap = ShellCommandFile(
            commands: (1...60).map {
                makeCommand(id: "big-\($0)", clause: String(repeating: "z", count: 1100))
            })
        do {
            try await store.save(overCap)
            XCTFail("a file over the byte cap must be refused — an unbounded file is a lie")
        } catch let error as ShellCommandRegistryError {
            guard case .fileTooLarge = error else {
                return XCTFail("the refusal must name the byte cap: \(error)")
            }
        }
        XCTAssertEqual(
            fileBytes(in: directory), try ShellCommandRegistry.encode(prior),
            "the refused save left the previously committed file byte-identical")
    }

    // MARK: - 5. Validation at decode (acceptance 4)

    /// **A row with a duplicate id / empty argv / over-long id / empty id / unnamed parameter is
    /// skipped loudly; the rest load.**
    ///
    /// The file is user-visible and hand-editable, so one bad row must never cost the rest of
    /// the registry — the enablement-row skip precedent. The first **valid** occurrence of an id
    /// wins, and a row the file would have to invent meaning for is dropped with its own loud
    /// complaint, never silently.
    func testInvalidRowsAreSkippedLoudlyAndTheRestLoad() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let planted = """
            {
              "version": 1,
              "commands": [
                {"id": "first", "command": ["/bin/echo", "one"], "parameters": []},
                {"id": "first", "command": ["/bin/echo", "duplicate"], "parameters": []},
                {"id": "no-argv", "command": [], "parameters": []},
                {"id": "\(String(repeating: "x", count: 129))", "command": ["/bin/echo", "long"], "parameters": []},
                {"id": "", "command": ["/bin/echo", "empty"], "parameters": []},
                {"id": "unnamed", "command": ["/bin/echo", "param"], "parameters": [{"name": ""}]},
                {"id": "second", "command": ["/bin/echo", "two"], "parameters": []}
              ]
            }
            """
        try Data(planted.utf8).write(to: directory.appendingPathComponent("shell-commands.json"))
        let plantedBytes = try Data(contentsOf: directory.appendingPathComponent("shell-commands.json"))

        let complaints = ComplaintRecorder()
        let loaded = await ShellCommandRegistry(directory: directory, log: complaints.log).load()

        XCTAssertEqual(
            loaded.commands.map(\.id), ["first", "second"],
            "the two valid rows load — the duplicate, the empty-argv row, the over-long id, the "
                + "empty id and the unnamed parameter are skipped, never fatal")
        XCTAssertEqual(
            loaded.commands[0].command, ["/bin/echo", "one"],
            "the first valid occurrence of an id wins — the duplicate never replaces it")
        XCTAssertEqual(
            complaints.recorded.count, 5,
            "each skipped row is loud, once: \(complaints.recorded)")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("shell-commands.json")),
            plantedBytes,
            "and the file's bytes are untouched — skipping is a reading, never a repair")
    }

    // MARK: - 6. The byte-level pin (acceptance 5)

    /// **The encoder emits exactly the named fields, and no enablement or argument-value key can
    /// reach the bytes.**
    ///
    /// The key-set pins are the strong half: the top level is exactly `version` + `commands`, a
    /// command is exactly its five fields, and a parameter is exactly `name`. An `enablement`
    /// section, an `arguments` slot or a `rawArguments` blob fails here on the day it is added —
    /// the registry is shape-only by construction, and this pin is what makes the
    /// never-persisted claim cheaply reversible rather than remembered.
    ///
    /// The presence assertions are the defence-in-depth half, and both are made non-vacuous: the
    /// file genuinely carries parameter names, clauses and an argv containing text, so an
    /// absence of the forbidden keys is an absence in a populated file.
    func testTheEncodedBytesCarryExactlyTheNamedFieldsAndNoArgumentValues() throws {
        let file = ShellCommandFile(
            commands: [
                makeCommand(
                    id: "empty-downloads",
                    command: ["/usr/bin/find", "~/Downloads", "-type", "f", "-delete"],
                    readOnly: false,
                    parameters: [
                        ShellCommandParameter(name: "Folder"),
                        ShellCommandParameter(name: "Depth"),
                    ],
                    clause: "This cannot be undone."),
                makeCommand(
                    id: "open-dashboard",
                    command: ["/usr/bin/open", "http://localhost:3000"],
                    readOnly: true, parameters: [], clause: "Opens the staging dashboard."),
            ])
        XCTAssertFalse(file.commands.isEmpty, "vacuity guard")

        let data = try ShellCommandRegistry.encode(file)
        let text = String(decoding: data, as: UTF8.self)

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("the encoded bytes must decode as a JSON object")
        }
        XCTAssertEqual(
            Set(object.keys), ["version", "commands"],
            """
            the top level is exactly the two named sections. An enablement section, an \
            arguments field or a rawArguments field fails here on the day it is added. Got: \
            \(Set(object.keys).sorted())
            """)
        let commands = try XCTUnwrap(object["commands"] as? [[String: Any]])
        XCTAssertEqual(commands.count, 2, "vacuity guard: the pin runs against populated rows")
        for command in commands {
            XCTAssertEqual(
                Set(command.keys), ["id", "command", "readOnly", "parameters", "clause"],
                "a command is exactly its five named fields — definitions only, no enablement, "
                    + "no call-time argument values: \(command.keys.sorted())")
        }
        let parameters = try XCTUnwrap(commands[0]["parameters"] as? [[String: Any]])
        XCTAssertEqual(parameters.count, 2, "vacuity guard: the pin runs against named slots")
        for parameter in parameters {
            XCTAssertEqual(
                Set(parameter.keys), ["name"],
                "a parameter is exactly its display name — the slot is positional, and a value "
                    + "key here would be the exact leak this pin exists for: \(parameter.keys.sorted())")
        }

        XCTAssertTrue(text.contains("Folder"), "vacuity guard: a named slot genuinely populated")
        XCTAssertTrue(
            text.contains("This cannot be undone."),
            "vacuity guard: a clause genuinely populated")
        XCTAssertFalse(text.contains("\"enablement\""), "no enablement key can reach the bytes")
        XCTAssertFalse(text.contains("\"arguments\""), "no arguments key can reach the bytes")
        XCTAssertFalse(text.contains("\"rawArguments\""), "no raw argument blob can reach the bytes")
        XCTAssertFalse(text.contains("\"value\""), "no call-time argument value key can reach the bytes")
    }

    /// The pinned file round-trips through the decoder, whole — a pin satisfied by an encoder
    /// that writes bytes nothing can read would be a file that looks like a registry and is none.
    func testThePinnedFileRoundTripsThroughTheDecoder() throws {
        let file = ShellCommandFile(
            commands: [
                makeCommand(
                    id: "list-files", readOnly: true,
                    parameters: [ShellCommandParameter(name: "Folder")],
                    clause: "Lists the folder.")
            ])
        let complaints = ComplaintRecorder()

        let decoded = ShellCommandRegistry.decode(
            try ShellCommandRegistry.encode(file), onInvalidElement: complaints.log)

        XCTAssertEqual(decoded, file, "the round trip is lossless — that is the persistence")
        XCTAssertEqual(complaints.recorded, [], "and silent: \(complaints.recorded)")
    }

    // MARK: - 7. Where the file lives

    /// **No file is created until the first save** — an absent file is the normal first-launch
    /// state, not something to repair by writing an empty registry behind the user's back.
    func testNoFileIsCreatedUntilTheFirstSave() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let loaded = await ShellCommandRegistry(directory: directory).load()

        XCTAssertEqual(loaded, .empty, "an absent file is the empty registry")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "and the directory does not even exist afterwards — load creates nothing, writes "
                + "nothing, and leaves the disk exactly as it found it")
    }

    /// The file lives at `<applicationSupport>/Vocca/shell-commands.json` — the
    /// `ActionConfigStore` directory shape (PRD Data Model), resolved as a pure function of what
    /// the file system answered.
    func testTheDefaultDirectoryIsBesideTheConfigStore() {
        let resolved = ShellCommandRegistry.defaultDirectory(
            applicationSupport: URL(fileURLWithPath: "/tmp/AppSupport"),
            home: URL(fileURLWithPath: "/tmp/home"))
        XCTAssertEqual(
            resolved.path, "/tmp/AppSupport/Vocca",
            "the registry lives in the app's own folder, beside action-config.json — pinned, a "
                + "rename is a reviewed edit rather than an orphaned file on every user's disk")

        let fallback = ShellCommandRegistry.defaultDirectory(
            applicationSupport: nil, home: URL(fileURLWithPath: "/tmp/home"))
        XCTAssertEqual(
            fallback.path, "/tmp/home/Library/Application Support/Vocca",
            "and the fallback is the same location reached the long way, not a different one")
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