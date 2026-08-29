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
import VoccaText
import XCTest

/// The cleanup config store's contract (spec B3): `<directory>/cleanup-config.json`, read
/// tolerantly over the ``CleanupConfigFileSystem`` seam — the store executes in CI over real
/// temp directories (the `FileSystemDictionaryStore` precedent, `spec.md:59-60`).
///
/// The load contract mirrors the dictionary store's: a missing file is the default silently, a
/// valid file decodes, and a corrupt file degrades to the default with one loud log — **and the
/// file is never rewritten**. A failed parse must never clobber the user's hand-edit
/// (`FileSystemDictionaryStore.swift:88-89`).
final class CleanupConfigStoreTests: XCTestCase {

    /// **B3 — a missing file loads the default silently.** The absent file is the default
    /// configuration (rules, zero network) — not an error, and no log: the zero-network probe
    /// runs exactly this path.
    func testAMissingFileLoadsTheDefaultSilently() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = LogCollector()
        let store = CleanupConfigStore(directory: directory, log: { logs.append($0) })

        let config = await store.load()

        XCTAssertEqual(config, .defaultConfig, "an absent file is the default config")
        XCTAssertTrue(
            logs.entries.isEmpty,
            "a missing file must load silently — it is the default, not a failure")
    }

    /// **B3 — a valid file decodes to its config.**
    func testAValidFileDecodes() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = #"{"provider":"ollama","ollama":{"endpoint":"http://localhost:11434","model":"llama3.1"}}"#
        try json.write(
            to: directory.appendingPathComponent("cleanup-config.json"), atomically: true,
            encoding: .utf8)
        let logs = LogCollector()
        let store = CleanupConfigStore(directory: directory, log: { logs.append($0) })

        let config = await store.load()

        XCTAssertEqual(config.provider, .ollama)
        XCTAssertEqual(config.ollama?.endpoint, "http://localhost:11434")
        XCTAssertEqual(config.ollama?.model, "llama3.1")
        XCTAssertTrue(logs.entries.isEmpty)
    }

    /// **B3 — a corrupt file degrades to the default with one loud log and is never rewritten.**
    /// A failed parse must not clobber the user's hand-edit; the bytes on disk after the load
    /// are exactly the bytes before it.
    func testACorruptFileDegradesLoudlyAndIsNeverRewritten() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("definitely not json".utf8)
        let fileURL = directory.appendingPathComponent("cleanup-config.json")
        try corrupt.write(to: fileURL)
        let logs = LogCollector()
        let store = CleanupConfigStore(directory: directory, log: { logs.append($0) })

        let config = await store.load()

        XCTAssertEqual(config, .defaultConfig, "a corrupt file is the default, never a crash")
        XCTAssertEqual(
            logs.entries.count, 1,
            "a corrupt file must degrade loudly, not silently")
        let after = try Data(contentsOf: fileURL)
        XCTAssertEqual(
            after, corrupt,
            "a failed parse must never rewrite the user's file")
    }

    // MARK: - The save path (`cleanup-tab` Phase 1)

    /// **A written config round-trips through `load()`.**
    ///
    /// The load-bearing half is the *fresh* store: the config comes back from the bytes on disk,
    /// not from the instance that wrote it. A save that only satisfied its own writer would be
    /// exactly the pretend-fidelity the load-only doc comment refused to ship
    /// (`CleanupConfigStore.swift:52-57`).
    func testAWrittenConfigRoundTripsThroughLoad() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = CleanupConfig(
            provider: .ollama,
            ollama: OllamaCleanupConfig(endpoint: "http://localhost:11434", model: "llama3.1"),
            byok: nil)

        try await CleanupConfigStore(directory: directory).save(written)

        let logs = LogCollector()
        let reloaded = await CleanupConfigStore(directory: directory, log: { logs.append($0) })
            .load()
        XCTAssertEqual(reloaded, written, "the file the settings surface writes is the file the resolver reads")
        XCTAssertTrue(
            logs.entries.isEmpty,
            "a config Vocca itself wrote must not come back through the degrade path")
    }

    /// **A save writes the directory into existence.** The settings surface is reachable before
    /// anything else has created `~/Library/Application Support/Vocca`, and a first save that
    /// threw `NSFileNoSuchFileError` would lose the user's choice on the one machine state that
    /// is guaranteed to happen once — the `FileSystemDictionaryStore.save(_:)` contract.
    func testASaveCreatesTheDirectory() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        try await CleanupConfigStore(directory: directory).save(.defaultConfig)

        let reloaded = await CleanupConfigStore(directory: directory).load()
        XCTAssertEqual(reloaded, .defaultConfig)
    }

    /// **A save preserves the block the user is not currently on.**
    ///
    /// `CleanupConfig.tolerantDecode(_:log:)` already promises it — "a `provider: ollama` file may
    /// still carry a valid `byok` block the future settings surface round-trips"
    /// (`CleanupConfig.swift:69-71`). This is that surface, so this is where the promise becomes
    /// a test: switching back to the cloud rung must not cost the endpoint the user typed.
    func testASavePreservesTheUnselectedBlock() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = CleanupConfig(
            provider: .rules,
            ollama: OllamaCleanupConfig(endpoint: "http://localhost:11434", model: "llama3.1"),
            byok: ByokCleanupConfig(endpoint: "https://api.example.com/v1", model: "gpt-4o-mini"))

        try await CleanupConfigStore(directory: directory).save(written)

        let reloaded = await CleanupConfigStore(directory: directory).load()
        XCTAssertEqual(reloaded.provider, .rules)
        XCTAssertEqual(reloaded.ollama, written.ollama, "the Ollama block survives a switch away from it")
        XCTAssertEqual(reloaded.byok, written.byok, "and so does the BYOK block")
    }

    /// **The written file stays hand-editable.** The file is still a supported edit surface
    /// (`prd.md` M7), so a save must not turn it into one line of escaped JSON: keys are sorted so
    /// the bytes are stable across saves, the object is pretty-printed so a person can read it,
    /// and slashes are not escaped so an endpoint reads as an endpoint rather than as
    /// `http:\/\/localhost`.
    func testTheWrittenFileStaysHandEditable() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = CleanupConfig(
            provider: .byok,
            ollama: nil,
            byok: ByokCleanupConfig(endpoint: "https://api.example.com/v1", model: "gpt-4o-mini"))

        try await CleanupConfigStore(directory: directory).save(written)

        let text = try String(
            contentsOf: directory.appendingPathComponent("cleanup-config.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\n"), "pretty-printed, so a person can still edit it")
        XCTAssertTrue(
            text.contains("https://api.example.com/v1"),
            "an endpoint reads as an endpoint — slashes are not escaped")
        let byokIndex = try XCTUnwrap(text.range(of: "\"byok\""))
        let providerIndex = try XCTUnwrap(text.range(of: "\"provider\""))
        XCTAssertTrue(
            byokIndex.lowerBound < providerIndex.lowerBound,
            "keys are sorted, so two saves of the same config produce the same bytes")
    }

    /// **Two saves of the same config produce identical bytes.** The stable-key claim above, made
    /// as the property it exists for: a file that re-ordered itself between runs is one that shows
    /// up in a diff having changed nothing (`FileSystemDictionaryStore.encode(_:)`).
    func testTwoSavesOfTheSameConfigProduceIdenticalBytes() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = CleanupConfig(
            provider: .ollama,
            ollama: OllamaCleanupConfig(endpoint: "http://localhost:11434", model: "llama3.1"),
            byok: ByokCleanupConfig(endpoint: "https://api.example.com/v1", model: nil))
        let fileURL = directory.appendingPathComponent("cleanup-config.json")
        let store = CleanupConfigStore(directory: directory)

        try await store.save(written)
        let first = try Data(contentsOf: fileURL)
        try await store.save(written)
        let second = try Data(contentsOf: fileURL)

        XCTAssertEqual(first, second)
    }

    /// **The config file never holds the BYOK key** (R4). The key lives in the Keychain, behind
    /// the existing `KeyProvider` seam, and `cleanup-config.json` is a plain file in Application
    /// Support that a user is invited to open. This asserts the absence rather than trusting the
    /// type not to grow a field: the whole written document is searched for every spelling a key
    /// field would plausibly take.
    func testTheWrittenFileNeverHoldsTheBYOKKey() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = CleanupConfig(
            provider: .byok,
            ollama: nil,
            byok: ByokCleanupConfig(endpoint: "https://api.example.com/v1", model: "gpt-4o-mini"))

        try await CleanupConfigStore(directory: directory).save(written)

        let text = try String(
            contentsOf: directory.appendingPathComponent("cleanup-config.json"), encoding: .utf8)
            .lowercased()
        for forbidden in ["key", "token", "secret", "authorization", "bearer", "credential"] {
            XCTAssertFalse(
                text.contains(forbidden),
                "the config file must never carry key material — it lives in the Keychain "
                    + "(found \"\(forbidden)\")")
        }
    }

    /// **A failed write never corrupts the file it failed to replace.**
    ///
    /// The atomic pair is temp-write then rename, so a failure at either step leaves the committed
    /// file untouched — the same guarantee `load()` already makes for a failed parse. The bytes
    /// after the throw are byte-for-byte the bytes before it, and the save throws rather than
    /// reporting a success that did not happen.
    func testAFailedWriteLeavesTheExistingFileIntact() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("cleanup-config.json")
        let existing = Data(#"{"provider":"rules"}"#.utf8)
        try existing.write(to: fileURL)
        let store = CleanupConfigStore(
            directory: directory, fileSystem: FailingWriteConfigFileSystem())

        do {
            try await store.save(
                CleanupConfig(
                    provider: .byok, ollama: nil,
                    byok: ByokCleanupConfig(endpoint: "https://api.example.com/v1", model: nil)))
            XCTFail("a save that could not write must throw, never report a success")
        } catch {
            // The expected direction: the caller is told.
        }

        XCTAssertEqual(
            try Data(contentsOf: fileURL), existing,
            "a failed write must leave the user's file exactly as it was")
    }

    // MARK: - Fixtures

    /// A fresh throwaway directory for one test.
    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-cleanup-config-\(UUID().uuidString)")
    }
}

/// A config file-system double whose write always fails — the failed-save proof. Reads are real
/// enough for the store to work; only the write direction is broken, which is the one the test is
/// about.
private struct FailingWriteConfigFileSystem: CleanupConfigFileSystem {
    struct WriteRefused: Error {}

    func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to url: URL) async throws {
        throw WriteRefused()
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        throw WriteRefused()
    }
}
