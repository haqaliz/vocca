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
        try corrupt.write(to: fileURL, atomically: true)
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

    // MARK: - Fixtures

    /// A fresh throwaway directory for one test.
    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-cleanup-config-\(UUID().uuidString)")
    }
}
