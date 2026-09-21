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
import VoccaCore
import XCTest

/// The persisted per-tool enablement and MCP server configuration — the `enablement-store`
/// aspect's whole contract (`action-surface-wiring` PRD R1 + R4, N1's deferral from
/// `action-safety-spine`).
///
/// ## Why this file exists at all
///
/// Slice 1 deferred persisted enablement to "the slice that introduces real tools to enable".
/// Real tools exist (`MCPProvider`, `AuditActionProvider`); nothing persists enablement or
/// server configuration. Without this store, M7's default-off is forgettable every launch —
/// the enablement set would have to be rebuilt by hand each run — and a server configuration
/// cannot exist at all.
///
/// ## The privacy boundary is the schema's shape
///
/// The file holds `servers` and `enablement` rows and nothing else: **no sentence, no raw tool
/// arguments, no transcript text can reach it** (the byte-pin asserts it on the artifact, in
/// the `ActionAuditEntry` shape). The enablement row is two identifiers because
/// `ActionEnablement` membership is by whole `ActionInvocation` — and an invocation carries
/// `arguments` only at call time, never in a persisted row. The wire vocabulary is excluded by
/// construction: there is no field, and a hand-edited file that grows one is refused rather
/// than read (the unknown-key pin, the `ModelManifest` wildcard-key precedent).
///
/// ## The shape of the assertions
///
/// Everything load-bearing runs through the real store over real temp directories, with the
/// file-system seam injected where the claim is about the commit protocol (tmp + rename-over,
/// the audit store's precedent) or about a torn write. The byte pin reads the encoded bytes
/// and the file's own key sets, never a reader's opinion of them.
final class ActionConfigStoreTests: XCTestCase {

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-action-config-\(UUID().uuidString)")
    }

    private func makeInvocation(
        providerID: String = "dev.vocca.mcp", toolID: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(providerID: providerID, toolID: toolID),
            "a non-empty provider id and tool id must construct an invocation", file: file,
            line: line)
    }

    private func makeServer(
        id: String, name: String = "Stub Server", executablePath: String = "/usr/local/bin/stub",
        arguments: [String] = []
    ) -> MCPServerConfiguration {
        MCPServerConfiguration(
            id: id, name: name, executablePath: executablePath, arguments: arguments)
    }

    private func makeRow(
        providerID: String = "dev.vocca.mcp", toolID: String
    ) -> ActionConfigEnablementRow {
        ActionConfigEnablementRow(providerID: providerID, toolID: toolID)
    }

    /// The stored file's bytes, read with `FileManager` directly — the assertions below are
    /// about the artifact, not about a reader's opinion of it.
    private func fileBytes(in directory: URL) -> Data? {
        FileManager.default.contents(
            atPath: directory.appendingPathComponent("action-config.json").path)
    }

    // MARK: - 1. Round trip and the enablement mapping (acceptance 1)

    /// **Save servers + enablement rows, reload, and the semantics are byte-identical** — the
    /// file is the whole of the store's memory, so a reload through the same directory cannot
    /// disagree with what was saved.
    func testServersAndEnablementRowsRoundTripByteIdentically() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ActionConfig(
            servers: [
                makeServer(
                    id: "server-a", name: "Files", executablePath: "/usr/local/bin/files",
                    arguments: ["--headless"]),
                makeServer(id: "server-b", name: "Chat", executablePath: "/opt/chat/chat"),
            ],
            enablement: [
                makeRow(toolID: "list-files"),
                makeRow(toolID: "send-message"),
                makeRow(providerID: "dev.vocca.audit", toolID: "audit.clear"),
            ])

        let store = ActionConfigStore(directory: directory)
        try await store.save(config)
        let savedBytes = try XCTUnwrap(
            fileBytes(in: directory),
            "vacuity guard: the save must have written the file, or the round trip proves nothing")

        let reloaded = await store.load()

        XCTAssertEqual(reloaded, config, "the reloaded config is exactly what was saved")
        XCTAssertEqual(
            try await store.load(), reloaded,
            "and a second load over the same directory agrees with the first — the file, never "
                + "a held value, is the store's memory")
        let unchangedBytes = try XCTUnwrap(
            fileBytes(in: directory), "vacuity guard: the file must still exist after the loads")
        XCTAssertEqual(
            unchangedBytes, savedBytes,
            "loading must never rewrite the file — a failed parse or a tolerated row must not "
                + "change the bytes a user can see and edit")
    }

    /// **Enablement rows map 1:1 to `ActionEnablement` membership — absent is off.**
    ///
    /// Membership is by whole ``ActionInvocation`` (the ``ActionEnablement`` contract): a row
    /// names a provider *and* a tool, and the store's mapping never invents a tool a row does
    /// not name. The row that was never present stays disabled — there is no third state.
    func testEnablementRowsMapOneToOneToActionEnablementMembershipAndAbsentIsOff() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ActionConfig(
            servers: [makeServer(id: "server-a")],
            enablement: [
                makeRow(toolID: "list-files"),
                makeRow(toolID: "delete-downloads"),
            ])
        try await ActionConfigStore(directory: directory).save(config)

        let enablement = await ActionConfigStore(directory: directory).loadEnablement()

        XCTAssertEqual(
            enablement,
            ActionEnablement([
                try makeInvocation(toolID: "list-files"),
                try makeInvocation(toolID: "delete-downloads"),
            ]),
            "the membership is exactly the rows — one invocation per row, arguments always nil")
        XCTAssertTrue(
            enablement.isEnabled(try makeInvocation(toolID: "list-files")),
            "a row present means enabled")
        XCTAssertTrue(
            enablement.isEnabled(try makeInvocation(toolID: "delete-downloads")),
            "and so does the second row")
        XCTAssertFalse(
            enablement.isEnabled(try makeInvocation(toolID: "send-message")),
            "absent is off: a tool no row names is disabled — the row that was never present "
                + "must not read as enabled")
        XCTAssertFalse(
            enablement.isEnabled(
                try makeInvocation(providerID: "dev.vocca.other", toolID: "list-files")),
            "membership is by whole invocation, not by tool name alone: enabling one provider's "
                + "list-files must not enable another provider's")
    }

    /// **A fresh directory enables nothing at all** — the shipped posture (M7) has no file
    /// spelling.
    func testAnAbsentFileEnablesNothing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let enablement = await ActionConfigStore(directory: directory).loadEnablement()

        XCTAssertEqual(
            enablement, .none,
            "no file means no enablement — default off has exactly one spelling, and it is empty")
        XCTAssertFalse(
            enablement.isEnabled(try makeInvocation(toolID: "list-files")),
            "and membership is off for every invocation, however plausible")
    }

    /// **Enablement rows are tolerant of stale tool ids**: a tool a server no longer lists keeps
    /// its row, and the file still decodes.
    ///
    /// The server list and the enablement set are deliberately not cross-checked — the store is
    /// not the discoverer of tools (the Actions-tab aspect owns discovery), and a row for a tool
    /// that has temporarily vanished must survive the round trip rather than be pruned on load.
    func testAStaleToolRowKeepsItsRowAndDecodeStaysValid() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ActionConfig(
            servers: [makeServer(id: "server-a")],
            enablement: [
                makeRow(toolID: "list-files"),
                makeRow(toolID: "tool-that-server-a-no-longer-lists"),
            ])
        try await ActionConfigStore(directory: directory).save(config)

        let reloaded = await ActionConfigStore(directory: directory).load()

        XCTAssertEqual(
            reloaded.enablement.count, 2,
            "both rows survive — a stale row is a fact about enablement, not a decode error")
        XCTAssertTrue(
            reloaded.enablement.contains(makeRow(toolID: "tool-that-server-a-no-longer-lists")),
            "and the stale row is the one that survives intact")
        XCTAssertTrue(
            await ActionConfigStore(directory: directory).loadEnablement().isEnabled(
                try makeInvocation(toolID: "tool-that-server-a-no-longer-lists")),
            "a stale tool stays enabled while its row exists — re-enabling a tool a server "
                + "lists again must not require the user to re-enable it")
    }

    // MARK: - 2. Tolerant decode (acceptance 2)

    /// **A garbage file loads as an empty config, loudly, and the file is never rewritten.**
    ///
    /// The audit store's `load()` precedent, whole: a corrupt file must never be fatal and must
    /// never be silently empty — the injected log is the loud half, asserted rather than hoped.
    /// The file's bytes are asserted unchanged afterwards: "empty config" is a reading, never a
    /// repair that replaces what the user can go and look at.
    func testAGarbageFileLoadsAsEmptyConfigLoudlyAndIsNeverRewritten() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("{ this is not a config".utf8)
        try garbage.write(to: directory.appendingPathComponent("action-config.json"))

        let complaints = ComplaintRecorder()
        let loaded = await ActionConfigStore(directory: directory, log: complaints.log).load()

        XCTAssertEqual(
            loaded, .empty,
            "a corrupt file is an empty config to a reader — never a throw, never a partial read")
        XCTAssertEqual(
            complaints.recorded.count, 1,
            "exactly one complaint — the skip is loud, or it is invisible: \(complaints.recorded)")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("action-config.json")),
            garbage,
            "the corrupt file's bytes are untouched — a failed load must never rewrite the "
                + "user's file")
    }

    /// **An unreadable file is the same tolerance, through the other half of the seam** — the
    /// read that cannot happen is not a crash either.
    func testAnUnreadableFileLoadsAsEmptyConfigLoudly() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"servers\":[],\"enablement\":[]}".utf8)
            .write(to: directory.appendingPathComponent("action-config.json"))

        let complaints = ComplaintRecorder()
        let loaded = await ActionConfigStore(
            directory: directory, fileSystem: NilReadingActionConfigFileSystem(),
            log: complaints.log
        ).load()

        XCTAssertEqual(loaded, .empty, "an unreadable file is an empty config, never a throw")
        XCTAssertEqual(complaints.recorded.count, 1, "and the failure is loud: \(complaints.recorded)")
    }

    /// The static decoder is **never throwing**, whatever it is handed — "never throws" is only
    /// a claim until something ugly is handed to it.
    func testTheDecoderNeverThrowsWhateverItIsHanded() {
        let complaints = ComplaintRecorder()
        for bytes in [Data(), Data([0xff, 0xfe, 0x00]), Data("[]".utf8), Data("{}".utf8)] {
            XCTAssertNil(
                ActionConfigStore.decode(bytes, onInvalidElement: complaints.log),
                "undecodable bytes answer nil — a corrupt file must never be fatal")
        }
        XCTAssertEqual(
            complaints.recorded.count, 4, "every rejection is reported: \(complaints.recorded)")
    }

    /// **A file with an unknown key is refused, at every level of the shape** — the byte-pin's
    /// decode half, in the ``ActionAuditEntry`` precedent.
    ///
    /// Three planted files, one per level: an extra top-level key (a `sentence` a transcript
    /// would travel in), an extra key on a server object, and an extra key on an enablement row
    /// (a `rawArguments` a tool call would travel in). Each is refused — `nil` plus exactly one
    /// loud complaint — because a config read with a field this build cannot name is a config
    /// read wrongly.
    func testAFileWithAnUnknownKeyIsRefusedPerTheBytePin() {
        let complaints = ComplaintRecorder()
        let planted: [String] = [
            #"{"servers":[],"enablement":[],"sentence":"forward my bank statement"}"#,
            #"{"servers":[{"id":"s","name":"n","executablePath":"/x","arguments":[],"secret":"s3"}"#
                + #"],"enablement":[]}"#,
            #"{"servers":[],"enablement":[{"providerID":"p","toolID":"t","rawArguments":"hunter2"}]}"#,
        ]

        for file in planted {
            XCTAssertNil(
                ActionConfigStore.decode(
                    Data(file.utf8), onInvalidElement: complaints.log),
                "a key this build cannot name is not a value to approximate: \(file)")
        }
        XCTAssertEqual(
            complaints.recorded.count, 3,
            "every planted file is refused loudly, once each: \(complaints.recorded)")
    }

    // MARK: - 3. The byte-level pin (acceptance 3)

    /// **The encoder emits exactly the named fields, and no sentence or raw tool arguments can
    /// reach the bytes.**
    ///
    /// The key-set pins are the strong half, in the ``ActionAuditEntry`` shape: the top level is
    /// exactly `servers` + `enablement`, a server is exactly its four fields, and a row is
    /// exactly `providerID` + `toolID`. A tenth field — a `sentence`, a `rawArguments`, a
    /// transcript — fails this on the day it is added, which is what makes the no-payload
    /// decision cheaply reversible rather than remembered.
    ///
    /// The control strings are the defence-in-depth half, and both are made non-vacuous: the
    /// sentence is the shape of text a transcript would travel in, and the raw-argument string
    /// is asserted to be *representable* in the action vocabulary (an ``ActionInvocation``
    /// carries it) before its absence from the file is asserted — the leak would have a field
    /// to travel in and a value to carry.
    func testTheEncodedBytesCarryExactlyTheNamedFieldsAndNoSentenceOrArguments() throws {
        let sentence = "please forward my bank statement to the auditor"
        let rawArguments = "wallet-seed-hunter2-do-not-persist"
        let invocation = try XCTUnwrap(
            ActionInvocation(
                providerID: "dev.vocca.mcp", toolID: "send-message", arguments: rawArguments),
            "vacuity guard: the raw-argument control string must be representable in the action "
                + "vocabulary — an unrepresentable string proves nothing about the file")
        XCTAssertEqual(
            invocation.arguments, rawArguments,
            "vacuity guard: the string really is the invocation's payload before the pin runs")

        let config = ActionConfig(
            servers: [
                makeServer(
                    id: "server-a", name: "Files", executablePath: "/usr/local/bin/files",
                    arguments: ["--headless", "--no-colour"]),
                makeServer(id: "server-b", name: "Chat", executablePath: "/opt/chat/chat"),
            ],
            enablement: [
                makeRow(toolID: "list-files"),
                makeRow(toolID: "send-message"),
                makeRow(providerID: "dev.vocca.audit", toolID: "audit.clear"),
            ])
        XCTAssertFalse(config.servers.isEmpty && config.enablement.isEmpty, "vacuity guard")

        let data = try ActionConfigStore.encode(config)
        let text = String(decoding: data, as: UTF8.self)

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("the encoded bytes must decode as a JSON object")
        }
        XCTAssertEqual(
            Set(object.keys), ["servers", "enablement"],
            """
            the top level is exactly the two named sections. A sentence field, a transcript \
            field or a raw-arguments field fails here on the day it is added. Got: \
            \(Set(object.keys).sorted())
            """)
        let servers = try XCTUnwrap(object["servers"] as? [[String: Any]])
        XCTAssertEqual(
            servers.count, 2,
            "vacuity guard: the pin runs against a genuinely populated server list")
        for server in servers {
            XCTAssertEqual(
                Set(server.keys), ["id", "name", "executablePath", "arguments"],
                "a server is exactly its four named fields — the stdio transport contract's "
                    + "configuration, no more: \(server.keys.sorted())")
        }
        let rows = try XCTUnwrap(object["enablement"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3, "vacuity guard: the pin runs against populated rows")
        for row in rows {
            XCTAssertEqual(
                Set(row.keys), ["providerID", "toolID"],
                """
                an enablement row is exactly its two identifiers — membership is by whole \
                ActionInvocation, and arguments travel only at call time, never in a persisted \
                row. A rawArguments key here would be the exact leak this pin exists for: \
                \(row.keys.sorted())
                """)
        }

        XCTAssertFalse(
            text.contains(sentence),
            "no sentence can reach the file — there is no field to carry it. Bytes: \(text)")
        XCTAssertFalse(
            text.contains(rawArguments),
            """
            no raw tool argument can reach the file — the row's key set is pinned above, and the \
            control string is absent here. If this fails, the defect is the persistence, never \
            this assertion: the enablement row is a fact about membership, while arguments are \
            arbitrary text an intent layer built against an untrusted server's schema. \
            Bytes: \(text)
            """)
    }

    /// The pinned file round-trips through the decoder, whole — a pin satisfied by an encoder
    /// that writes bytes nothing can read would be a file that looks like config and is none.
    func testThePinnedConfigRoundTripsThroughTheDecoder() throws {
        let config = ActionConfig(
            servers: [
                makeServer(
                    id: "server-a", name: "Files", executablePath: "/usr/local/bin/files",
                    arguments: ["--headless"])
            ],
            enablement: [makeRow(toolID: "list-files")])
        let complaints = ComplaintRecorder()

        let decoded = ActionConfigStore.decode(
            try ActionConfigStore.encode(config), onInvalidElement: complaints.log)

        XCTAssertEqual(decoded, config, "the round trip is lossless — that is the persistence")
        XCTAssertEqual(complaints.recorded, [], "and silent: \(complaints.recorded)")
    }

    // MARK: - 4. Atomicity (acceptance 4)

    /// A save is the **atomic temp-write-then-rename pair**, recorded through the injected seam —
    /// the audit store's commit protocol, for the config file.
    func testASaveIsATempWriteRenamedOverTheFileName() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingActionConfigFileSystem(directory: directory)
        let store = ActionConfigStore(directory: directory, fileSystem: fileSystem)
        let config = ActionConfig(
            servers: [makeServer(id: "server-a")],
            enablement: [makeRow(toolID: "list-files")])

        try await store.save(config)

        let events = await fileSystem.events
        XCTAssertEqual(
            events, [.tempWrite("action-config.json.tmp"), .rename("action-config.json")],
            """
            the commit is a temp write renamed over the final name, in that order. The store \
            must not answer before the rename: a crash between the two steps must leave a file \
            nothing can read, never a half-written config that loads as truth.
            """)
    }

    /// **A torn write never yields a partially-committed file the store would load** — the
    /// failure the atomic pair exists for, simulated through the seam.
    ///
    /// The double writes the temp file for real and then throws at the rename — the crash
    /// between the two steps. The save fails loudly (a config the user believes persisted would
    /// be the silent loss), and the store's own reader — a fresh instance over the same
    /// directory — loads the empty config: the torn residue is a `.tmp`, and nothing reads a
    /// `.tmp`.
    func testATornCommitNeverYieldsAPartiallyCommittedFileTheStoreWouldLoad() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActionConfigStore(
            directory: directory, fileSystem: TornWriteActionConfigFileSystem())

        do {
            try await store.save(
                ActionConfig(
                    servers: [makeServer(id: "server-a")],
                    enablement: [makeRow(toolID: "list-files")]))
            XCTFail(
                "a commit that cannot rename must fail loudly — a caller that cannot tell thinks "
                    + "the config was persisted")
        } catch {
            // Expected: the torn commit surfaces to the caller.
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(
            names, ["action-config.json.tmp"],
            "the torn write leaves only the temp file — never a committed-looking name")
        let loaded = await ActionConfigStore(directory: directory).load()
        XCTAssertEqual(
            loaded, .empty,
            "and the store's own reader sees the empty config: a .tmp is not a config, however "
                + "well-formed its bytes are")
    }

    /// A `.tmp` file is **invisible to load by name**, and the next save's commit replaces it —
    /// recovery from a crash is a fresh save, not a repair of the residue.
    func testATempFileIsInvisibleToLoadAndTheNextSaveRecovers() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let orphan = directory.appendingPathComponent("action-config.json.tmp")
        try ActionConfigStore.encode(
            ActionConfig(
                servers: [makeServer(id: "server-a")],
                enablement: [makeRow(toolID: "list-files")])
        ).write(to: orphan)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: orphan.path),
            "vacuity guard: the mid-commit file must actually be on disk for its invisibility "
                + "to mean anything")

        let loaded = await ActionConfigStore(directory: directory).load()
        XCTAssertEqual(
            loaded, .empty,
            "a .tmp is not the config file — the name is the whole of the atomic protocol's "
                + "read side")

        let config = ActionConfig(
            servers: [makeServer(id: "server-b", name: "Recovery")],
            enablement: [makeRow(toolID: "list-files")])
        try await ActionConfigStore(directory: directory).save(config)
        let reloaded = await ActionConfigStore(directory: directory).load()
        XCTAssertEqual(
            reloaded, config,
            "the next save commits over the residue — recovery is a fresh atomic commit, never "
                + "a repair of the torn file")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(
            names, ["action-config.json"],
            "and the directory holds exactly the one committed file afterwards")
    }

    // MARK: - 5. The caps, and the path rule (acceptance 5)

    /// **More than eight servers are refused loudly, and the eighth saves.**
    ///
    /// A cap refused rather than clamped: a config the store silently shrinks is a server the
    /// user believes configured. The refusal happens before anything touches the file system —
    /// nothing is written, not even a directory.
    func testMoreThanEightServersAreRefusedLoudlyAndEightSave() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let eight = ActionConfig(
            servers: (1...8).map { makeServer(id: "server-\($0)") },
            enablement: [])
        let store = ActionConfigStore(directory: directory)
        try await store.save(eight)
        XCTAssertEqual(
            (try? await store.load())?.servers.count, 8,
            "vacuity guard: exactly eight servers save and reload — the cap is inclusive")

        let nine = ActionConfig(
            servers: (1...9).map { makeServer(id: "server-\($0)") },
            enablement: [])
        do {
            try await store.save(nine)
            XCTFail("a ninth server must be refused — a cap that clamps is a lie to the user")
        } catch let error as ActionConfigStoreError {
            XCTAssertEqual(
                error, .tooManyServers(9),
                "the refusal names the count, so the caller can tell the user what was refused")
        }
        XCTAssertNil(
            fileBytes(in: directory),
            "nothing was written by the refused save — the refusal is before the file system, "
                + "and the directory may not even exist")
    }

    /// **More than 512 enablement rows are refused loudly, and the 512th saves** — the
    /// consent-store cap, for enablement.
    func testMoreThan512EnablementRowsAreRefusedLoudlyAnd512Save() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let atTheCap = ActionConfig(
            servers: [makeServer(id: "server-a")],
            enablement: (1...512).map { makeRow(toolID: "tool-\($0)") })
        let store = ActionConfigStore(directory: directory)
        try await store.save(atTheCap)
        XCTAssertEqual(
            (try? await store.load())?.enablement.count, 512,
            "vacuity guard: exactly 512 rows save and reload — the cap is inclusive")

        let oneOver = ActionConfig(
            servers: [makeServer(id: "server-a")],
            enablement: (1...513).map { makeRow(toolID: "tool-\($0)") })
        do {
            try await store.save(oneOver)
            XCTFail("a 513th row must be refused — a cap that clamps is a lie to the user")
        } catch let error as ActionConfigStoreError {
            XCTAssertEqual(
                error, .tooManyEnablementRows(513),
                "the refusal names the count, so the caller can tell the user what was refused")
        }
        XCTAssertNil(fileBytes(in: directory), "and nothing was written by the refused save")
    }

    /// **An empty `executablePath` is refused at save** — a server without a path is not a
    /// server, and the stdio transport's configuration contract (an absolute path, no PATH
    /// lookup) has no reading of "" that means anything.
    func testAnEmptyExecutablePathIsRefusedAtSaveLoudly() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ActionConfigStore(directory: directory)
        let config = ActionConfig(
            servers: [makeServer(id: "server-a", executablePath: "")],
            enablement: [])
        do {
            try await store.save(config)
            XCTFail(
                "a server with no executable path must be refused — a configured server that "
                    + "cannot be launched is a failure the user is told about at save time, "
                    + "never at the moment they try to use it")
        } catch let error as ActionConfigStoreError {
            XCTAssertEqual(
                error, .emptyExecutablePath,
                "the refusal names the rule: no path, no server")
        }
        XCTAssertNil(fileBytes(in: directory), "and nothing was written by the refused save")
    }

    // MARK: - 6. Persistence across instances (acceptance 6)

    /// **Two store instances over the same directory see the same config** — the file, never a
    /// held value, is the memory, so no coordination between instances is possible or needed.
    func testTwoStoresOverTheSameDirectorySeeTheSameConfig() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ActionConfig(
            servers: [makeServer(id: "server-a")],
            enablement: [makeRow(toolID: "list-files")])
        try await ActionConfigStore(directory: directory).save(config)

        let second = await ActionConfigStore(directory: directory).load()
        let third = await ActionConfigStore(directory: directory).load()

        XCTAssertEqual(second, config, "a second instance reads what the first wrote")
        XCTAssertEqual(third, config, "and a third reads the same — no instance has a private view")
    }

    // MARK: - 7. Where the file lives, and what the store reaches (acceptance 7, plan edge cases)

    /// **No file is created until the first save** — an absent file is the normal first-launch
    /// state, not something to repair by writing an empty config behind the user's back.
    func testNoFileIsCreatedUntilTheFirstSave() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let loaded = await ActionConfigStore(directory: directory).load()

        XCTAssertEqual(loaded, .empty, "an absent file is the empty config")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "and the directory does not even exist afterwards — load creates nothing, writes "
                + "nothing, and leaves the disk exactly as it found it")
    }

    /// The file lives at `<applicationSupport>/Vocca/action-config.json` — beside the consent
    /// and usage stores, resolved as a pure function of what the file system answered.
    func testTheDefaultDirectoryIsBesideTheOtherVoccaStores() {
        let resolved = ActionConfigStore.defaultDirectory(
            applicationSupport: URL(fileURLWithPath: "/tmp/AppSupport"),
            home: URL(fileURLWithPath: "/tmp/home"))
        XCTAssertEqual(
            resolved.path, "/tmp/AppSupport/Vocca",
            "the config lives in the app's own folder, pinned — a rename is a reviewed edit "
                + "rather than an orphaned file on every user's disk")

        let fallback = ActionConfigStore.defaultDirectory(
            applicationSupport: nil, home: URL(fileURLWithPath: "/tmp/home"))
        XCTAssertEqual(
            fallback.path, "/tmp/home/Library/Application Support/Vocca",
            "and the fallback is the same location reached the long way, not a different one")
    }

    /// **The store's own files reach no network name and spawn no child** — acceptance 7's
    /// headless half, scanned with the transport-prohibition detector over exactly the four
    /// `Config/` files this aspect ships.
    ///
    /// The zero-network probe's drive line belongs to the wiring aspect; what this aspect owns
    /// is the structural claim that its own four files cannot be where a connection or a spawn
    /// appears. The detector is the transport lint's own, so this cannot disagree with the lint
    /// about what counts as a family.
    func testTheConfigFilesReachNoNetworkName() throws {
        let configRoot = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaActions/Config")
        let files = SwiftSourceScanner.swiftFiles(under: configRoot)
        XCTAssertFalse(
            files.isEmpty,
            "vacuity guard: the four Config/ files must exist to be scanned — an empty scan "
                + "proves nothing")

        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let identifiers = ActionTransportProhibitionTests.transportIdentifiers(
                inSource: source)
            if !identifiers.isEmpty {
                offenders.append("\(file.lastPathComponent): \(identifiers.joined(separator: ", "))")
            }
        }
        XCTAssertEqual(
            offenders, [],
            """
            a Config/ file names a transport family (a socket family or a spawn family): \
            \(offenders.joined(separator: "; ")). The store persists enablement; the moment a \
            config file can open a connection or launch a child, the zero-network and \
            no-spawn invariants have a second door that no probe watches.
            """)
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

/// What the config store's file-system seam records, in order — the **atomic-pair protocol** the
/// durability claim is carried by (the audit store's `ActionAuditFileSystemEvent` shape).
enum ActionConfigFileSystemEvent: Equatable {
    /// The temp file was written — not yet readable, not yet committed.
    case tempWrite(String)
    /// The temp file was renamed over the config name — the commit point.
    case rename(String)
}

/// An ``ActionConfigFileSystem`` over a real temp directory whose every commit is recorded as
/// the atomic temp-write/rename pair. The commit is `replaceItemAt`, mirroring the shipped
/// adapter.
actor RecordingActionConfigFileSystem: ActionConfigFileSystem {
    private(set) var events: [ActionConfigFileSystemEvent] = []
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
        events.append(.tempWrite(url.lastPathComponent))
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        events.append(.rename(destination.lastPathComponent))
    }

    func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// The seam whose rename always fails after the temp write succeeded — the crash between the
/// two steps of the atomic pair, simulated.
struct TornWriteActionConfigFileSystem: ActionConfigFileSystem {
    struct Refused: Error {}

    func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        throw Refused()
    }

    func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// The seam that answers "the file exists" and then cannot read it — the unreadable half of the
/// tolerance policy, driven through the injected log.
struct NilReadingActionConfigFileSystem: ActionConfigFileSystem {
    func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
    }

    func read(_ url: URL) async -> Data? {
        nil
    }

    func fileExists(atPath path: String) async -> Bool {
        true
    }
}