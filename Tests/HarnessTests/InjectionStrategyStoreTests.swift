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
import VoccaCore
@testable import VoccaInject
import XCTest

/// C8's strategy store — the `store-seam` aspect's S1–S14, written before the store exists
/// (`plan_20260827.md` Phase 1). Failing to compile is the red state: no
/// `InjectionStrategyStore` is in scope yet.
///
/// Like the dictionary and journal stores, `FileManager` works on a hosted runner, so the real
/// ``PersistentInjectionStrategyStore`` runs here against real temp directories: corrupt files
/// are skipped loudly and never rewritten, saves are the atomic temp-write→rename pair, and a
/// missing file loads empty silently. The injected ``InjectionStrategyFileSystem`` seam is
/// exercised through three doubles in this file — a recording actor (S1/S3's pair), a failing
/// rename (the torn half, S2), and a refusing create-directory (S13, the refused-write
/// contract) — mirroring the dictionary's.
final class InjectionStrategyStoreTests: XCTestCase {

    // MARK: - The bounded store (S1)

    /// The remembered-apps cap is the ``LatencyLedger.maximumRetainedRecords`` shape: a named
    /// value whose **definition** (`maximumRememberedApps = 512`) lives in exactly the one Core
    /// file and this pinning test — the ``WarmStartRatio`` single-source precedent. The bare
    /// `512` numeral and the name itself legitimately appear elsewhere (the ledger's own cap,
    /// and the stores' constructor defaults referencing the constant by name), so the scan pins
    /// the definition, not the identifier or the numeral: a second *definition* of the bound
    /// under another name would be a second home.
    func testTheRememberedAppsCapLivesOnlyInTheNamedConstant() throws {
        XCTAssertEqual(InjectionStrategyStoreConstants.maximumRememberedApps, 512)

        let root = try PackageRootLocator.find(from: #filePath)
        let namedFile = "InjectionStrategyStore.swift"
        let pinningTest = "InjectionStrategyStoreTests.swift"
        let allowedSightings: Set<String> = [namedFile, pinningTest]
        let pattern = #"maximumRememberedApps = 512"#
        var sightings: [String: Int] = [:]
        for tree in [root.appendingPathComponent("Sources"), root.appendingPathComponent("Tests")] {
            for file in SwiftSourceScanner.swiftFiles(under: tree) {
                let content = try String(contentsOf: file, encoding: .utf8)
                if SwiftSourceScanner.stripComments(from: content).contains(pattern) {
                    sightings[file.lastPathComponent, default: 0] += 1
                }
            }
        }

        XCTAssertFalse(sightings.isEmpty, "vacuity guard: the scan saw no files at all")
        XCTAssertEqual(
            Set(sightings.keys), allowedSightings,
            "the cap's definition must live in exactly the named Core file and its pinning test, got: \(sightings)")
        XCTAssertEqual(
            sightings[namedFile], 1,
            "the named file's own definition must exist — the vacuity guard's second direction")
    }

    // MARK: - S4 · the missing file

    /// A store over an absent directory loads `[]` — no error, no log: the missing file is the
    /// empty memory, not a failure (`spec.md` S4, the silent-launch contract).
    func testMissingFileLoadsEmptySilently() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = LogCollector()
        let store = PersistentInjectionStrategyStore(
            directory: directory, log: { logs.append($0) })

        let loaded = await store.load()

        XCTAssertEqual(loaded, [], "an absent file is an empty memory, not an error")
        XCTAssertTrue(logs.entries.isEmpty, "a missing file must load silently")
    }

    // MARK: - S5 · corrupt elements

    /// A mixed file — one valid strategy, a wrong-typed element, a missing-field element and a
    /// non-object fragment — loads the valid one, emits exactly one loud log per skipped
    /// element, and never rewrites the file: the bytes are byte-identical afterwards.
    func testCorruptElementsAreSkippedLoudlyAndTheFileIsNeverRewritten() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
            {
              "version": 1,
              "strategies": [
                {"bundleID": "com.example.app", "demotedRungs": ["accessibility"], "learnedAllowlist": true, "reprobeWindows": ["accessibility", 1700000000], "overrideRungs": null},
                {"bundleID": 42},
                {"bundleID": "com.example.missing"},
                "not an object"
              ]
            }
            """
        try json.write(
            to: directory.appendingPathComponent("strategies.json"), atomically: true,
            encoding: .utf8)
        let logs = LogCollector()
        let store = PersistentInjectionStrategyStore(
            directory: directory, log: { logs.append($0) })

        let loaded = await store.load()

        XCTAssertEqual(
            loaded,
            [InjectionStrategy(
                bundleID: "com.example.app",
                demotedRungs: [.accessibility],
                learnedAllowlist: true,
                reprobeWindows: [.accessibility: 1_700_000_000])],
            "the valid element must load; each corrupt one must be skipped")
        XCTAssertEqual(logs.entries.count, 3, "exactly one loud log per skipped element")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("strategies.json")),
            Data(json.utf8),
            "a tolerant load must never rewrite the user's file")
    }

    // MARK: - S6 · a top level that is not an object

    /// A file whose top level is not an object at all loads empty with exactly one loud log —
    /// and the file on disk is byte-identical afterwards.
    func testWholeFileThatIsNotAnObjectLoadsEmptyWithOneLoudLog() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = #"[{"bundleID": "com.example.app"}]"#
        try json.write(
            to: directory.appendingPathComponent("strategies.json"), atomically: true,
            encoding: .utf8)
        let logs = LogCollector()
        let store = PersistentInjectionStrategyStore(
            directory: directory, log: { logs.append($0) })

        let loaded = await store.load()

        XCTAssertEqual(loaded, [], "a non-object top level is an empty memory, not a throw")
        XCTAssertEqual(logs.entries.count, 1, "a non-object top level is exactly one loud refusal")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("strategies.json")),
            Data(json.utf8),
            "a failed parse must never rewrite the user's file")
    }

    // MARK: - S7 · unknown version

    /// A file a future version wrote — `"version": 2` — and a version-less object both load
    /// empty with exactly one loud log each, bytes unchanged: version-tolerant, never mis-read
    /// (X5).
    func testUnknownVersionLoadsEmptyWithOneLoudLog() async throws {
        for json in [
            #"{"version": 2, "strategies": [{"bundleID": "com.example.app"}]}"#,
            #"{"strategies": [{"bundleID": "com.example.app"}]}"#,
        ] {
            let directory = Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try json.write(
                to: directory.appendingPathComponent("strategies.json"), atomically: true,
                encoding: .utf8)
            let logs = LogCollector()
            let store = PersistentInjectionStrategyStore(
                directory: directory, log: { logs.append($0) })

            let loaded = await store.load()

            XCTAssertEqual(
                loaded, [],
                "an unknown or missing version must load empty — never be mis-read")
            XCTAssertEqual(
                logs.entries.count, 1,
                "an unknown or missing version is exactly one loud refusal")
            XCTAssertEqual(
                try? Data(contentsOf: directory.appendingPathComponent("strategies.json")),
                Data(json.utf8),
                "a version rejection must never rewrite the user's file")
        }
    }

    // MARK: - S8 · the stray temp

    /// A stray `strategies.json.tmp` from a crash is never read: planted beside the committed
    /// file, load returns the committed content only.
    func testAStrayTempFileFromACrashIsNeverRead() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let v1 = Self.appStrategy()
        try await PersistentInjectionStrategyStore(directory: directory).save([v1])
        try "torn write, never renamed".write(
            to: directory.appendingPathComponent("strategies.json.tmp"), atomically: true,
            encoding: .utf8)

        let store = PersistentInjectionStrategyStore(directory: directory)
        let loaded = await store.load()

        XCTAssertEqual(
            loaded, [v1],
            "the committed content is what loads; a stray .tmp must never be read as memory")
    }

    // MARK: - S1 · update is the atomic pair

    /// The protocol half: `update` is recorded as exactly the atomic pair — temp written, then
    /// renamed over the committed name. The real file holds the encoded strategies, and no
    /// `.tmp` remains.
    func testUpdateIsAnAtomicTempWriteThenRenamePair() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingInjectionStrategyFileSystem(directory: directory)
        let store = PersistentInjectionStrategyStore(
            directory: directory, fileSystem: fileSystem)
        let strategy = Self.appStrategy()

        let accepted = try await store.update(strategy)

        XCTAssertTrue(accepted, "a new app under the cap is accepted")
        let events = await fileSystem.events
        XCTAssertEqual(
            events,
            [.tempWrite("strategies.json.tmp"), .rename("strategies.json")],
            "a durable update is exactly two events: temp written, then renamed into place")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("strategies.json")),
            try PersistentInjectionStrategyStore.encode([strategy]),
            "the committed file must hold the encoded strategies")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("strategies.json.tmp").path),
            "no .tmp may remain after a completed update")
    }

    // MARK: - S3 · save is the same pair, byte-stable

    /// The wholesale path is the same atomic pair — and `.sortedKeys` makes it byte-stable:
    /// save → read bytes → save again → identical bytes.
    func testSaveIsAnAtomicTempWriteThenRenamePair() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingInjectionStrategyFileSystem(directory: directory)
        let store = PersistentInjectionStrategyStore(
            directory: directory, fileSystem: fileSystem)
        let strategies = [Self.appStrategy(), Self.slackStrategy()]

        try await store.save(strategies)
        let firstBytes = try Data(contentsOf: directory.appendingPathComponent("strategies.json"))

        let events = await fileSystem.events
        XCTAssertEqual(
            events,
            [.tempWrite("strategies.json.tmp"), .rename("strategies.json")],
            "a durable save is exactly two events: temp written, then renamed into place")
        XCTAssertEqual(
            firstBytes, try PersistentInjectionStrategyStore.encode(strategies),
            "the committed file must hold the encoded strategies")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("strategies.json.tmp").path),
            "no .tmp may remain after a completed save")

        try await store.save(strategies)
        let secondBytes = try Data(contentsOf: directory.appendingPathComponent("strategies.json"))
        XCTAssertEqual(
            firstBytes, secondBytes,
            "a save of the same set must produce byte-identical file — .sortedKeys, not chaos")
    }

    // MARK: - S2 · the torn update

    /// The torn half: a rename that throws after the temp write lands leaves the committed file
    /// at v1's bytes — never partial — and the leftover `.tmp` is never readable as memory: a
    /// fresh store over the real directory loads v1.
    func testAFailedUpdateAfterTheTempWriteLeavesThePreviousCommittedContent() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let v1 = Self.appStrategy()
        _ = try await PersistentInjectionStrategyStore(directory: directory).update(v1)
        let committedBefore = try Data(
            contentsOf: directory.appendingPathComponent("strategies.json"))

        let v2 = Self.slackStrategy()
        let torn = PersistentInjectionStrategyStore(
            directory: directory, fileSystem: FailingRenameInjectionStrategyFileSystem())
        do {
            _ = try await torn.update(v2)
            XCTFail("a rename that throws must surface as a failed update")
        } catch {
            // Expected — the torn update is the point of the test.
        }

        let committedAfter = try Data(
            contentsOf: directory.appendingPathComponent("strategies.json"))
        XCTAssertEqual(
            committedAfter, committedBefore,
            "the committed file must be the previous content, never partial")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("strategies.json.tmp").path),
            "the torn temp must remain on disk — that is what a crash between the pair leaves")

        let fresh = PersistentInjectionStrategyStore(directory: directory)
        let reloaded = await fresh.load()
        XCTAssertEqual(
            reloaded, [v1],
            "the leftover .tmp must never be readable as memory; the committed v1 is what loads")
    }

    // MARK: - S9 · round trip through the real store

    /// Two apps updated through the real store, a fresh store over the same directory: both
    /// load with rungs, windows and the override intact.
    func testRoundTripThroughTheRealStore() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentInjectionStrategyStore(directory: directory)
        let app = Self.appStrategy()
        let slack = Self.slackStrategy()

        _ = try await store.update(app)
        _ = try await store.update(slack)

        let fresh = PersistentInjectionStrategyStore(directory: directory)
        let loaded = await fresh.load()

        XCTAssertEqual(
            loaded, [app, slack],
            "both strategies must survive save and reload with rungs and timestamps intact")
    }

    // MARK: - S13 · the refused write

    /// The refused-write contract: a directory that cannot be created makes `update` throw —
    /// the strategies are not durable, and the caller must know (the journal's refused-write
    /// contract).
    func testUpdateThrowsWhenTheDirectoryCannotBeCreated() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentInjectionStrategyStore(
            directory: directory,
            fileSystem: RefusingCreateDirectoryInjectionStrategyFileSystem())

        do {
            _ = try await store.update(Self.appStrategy())
            XCTFail("update must throw when the directory cannot be created")
        } catch {
            // Expected — the throw is the contract.
        }
    }

    // MARK: - S10 · the cap refuses, never evicts (ephemeral)

    /// The ephemeral store at capacity 2: two new apps accepted; a third **new** app → `false`
    /// and not held; an update of a known app → `true`. Refusal, never eviction.
    func testCapRefusalForANewAppAndKnownAppsKeepFlowing() async throws {
        let store = EphemeralInjectionStrategyStore(capacity: 2)
        let app = Self.appStrategy()
        let slack = Self.slackStrategy()
        let third = InjectionStrategy(bundleID: "com.example.third")

        let first = try await store.update(app)
        let second = try await store.update(slack)
        let refused = try await store.update(third)
        let knownAgain = try await store.update(app)

        XCTAssertTrue(first, "the first new app fits")
        XCTAssertTrue(second, "the second new app fits")
        XCTAssertFalse(refused, "a third new app at capacity is refused, not evicted")
        let held = await store.load()
        XCTAssertFalse(
            held.contains(where: { $0.bundleID == "com.example.third" }),
            "a refused app is not held")
        XCTAssertTrue(knownAgain, "an update of a known app always succeeds")
    }

    // MARK: - S11 · a cap refusal is not a persist

    /// The persistent store at capacity 2: after two updates the file holds two entries; a
    /// refused third update leaves the file bytes untouched.
    func testCapRefusalLeavesTheFileUntouched() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentInjectionStrategyStore(directory: directory, capacity: 2)
        _ = try await store.update(Self.appStrategy())
        _ = try await store.update(Self.slackStrategy())
        let before = try Data(contentsOf: directory.appendingPathComponent("strategies.json"))

        let refused = try await store.update(InjectionStrategy(bundleID: "com.example.third"))

        XCTAssertFalse(refused, "a third new app at capacity is refused")
        XCTAssertEqual(
            try? Data(contentsOf: directory.appendingPathComponent("strategies.json")),
            before,
            "a refused update must not touch the file")
    }

    // MARK: - S12 · save bypasses the cap

    /// `save` is the deliberate wholesale write: three strategies into an at-capacity-2
    /// ephemeral store succeed and load — the reset-learned and editing paths are not subject
    /// to the learning cap.
    func testSaveReplacesTheWholeSetAndBypassesTheCap() async throws {
        let store = EphemeralInjectionStrategyStore(capacity: 2)
        _ = try await store.update(Self.appStrategy())
        _ = try await store.update(Self.slackStrategy())
        let three = [
            Self.appStrategy(), Self.slackStrategy(),
            InjectionStrategy(bundleID: "com.example.third"),
        ]

        try await store.save(three)

        let held = await store.load()
        XCTAssertEqual(held, three, "a deliberate save replaces the whole set, cap or not")
    }

    // MARK: - S14 · ephemeral semantics end to end

    /// Headless end to end over the ephemeral store: empty load → update two → load reflects
    /// both → `save([])` clears → load empty. No disk, no seam, no throws.
    func testEphemeralLearnUpdateAndResetRoundTrip() async throws {
        let store = EphemeralInjectionStrategyStore()

        let initial = await store.load()
        XCTAssertEqual(initial, [], "a fresh ephemeral store is empty")

        let app = Self.appStrategy()
        let slack = Self.slackStrategy()
        _ = try await store.update(app)
        _ = try await store.update(slack)

        let held = await store.load()
        XCTAssertEqual(held, [app, slack], "both updates are held")

        try await store.save([])

        let cleared = await store.load()
        XCTAssertEqual(cleared, [], "save([]) is the reset path")
    }

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-strategies-\(UUID().uuidString)")
    }

    /// A learned app: AX demoted with a re-probe window, mixed rungs, distinct epoch seconds.
    private static func appStrategy() -> InjectionStrategy {
        InjectionStrategy(
            bundleID: "com.example.app",
            demotedRungs: [.accessibility, .keystrokeSynthesis],
            learnedAllowlist: false,
            reprobeWindows: [.accessibility: 1_700_000_000, .keystrokeSynthesis: 1_700_604_800],
            overrideRungs: nil)
    }

    /// A promoted, overridden app: the learned allowlist and an absolute user pin.
    private static func slackStrategy() -> InjectionStrategy {
        InjectionStrategy(
            bundleID: "com.tinyspeck.slackmacgap",
            demotedRungs: [],
            learnedAllowlist: true,
            reprobeWindows: [:],
            overrideRungs: [.clipboardPaste, .accessibility])
    }
}

/// What the strategy store's file-system seam records, in order — the **atomic-pair protocol**
/// the durability claim is carried by (the dictionary's `DictionaryFileSystemEvent` shape).
enum InjectionStrategyFileSystemEvent: Equatable {
    /// The temp file was written — not yet readable, not yet committed.
    case tempWrite(String)
    /// The temp file was renamed over the entry name — the commit point.
    case rename(String)
}

/// An in-memory ``InjectionStrategyFileSystem`` whose every save is recorded as the atomic
/// temp-write/rename pair, against a real temp directory — the S1/S3 protocol half. The commit
/// is `replaceItemAt`, mirroring the shipped adapter (whose overwrite-succeeds commit is the
/// point of the pair), so a second save over the same file records the same two events.
actor RecordingInjectionStrategyFileSystem: InjectionStrategyFileSystem {
    private(set) var events: [InjectionStrategyFileSystemEvent] = []
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

/// The torn half of S1/S3: the temp write lands on disk, the rename throws.
struct FailingRenameInjectionStrategyFileSystem: InjectionStrategyFileSystem {
    func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        throw StrategyStoreTestError.renameFailed
    }

    func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// The refused-write contract: the directory cannot be created, so `update` must throw.
struct RefusingCreateDirectoryInjectionStrategyFileSystem: InjectionStrategyFileSystem {
    func createDirectory(at url: URL) async throws {
        throw StrategyStoreTestError.directoryRefused
    }

    func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// What a strategy-store failure is, for the throw tests — the specific error is the file
/// system's business; the contract is that `update` surfaces it.
enum StrategyStoreTestError: Error {
    /// The rename between the pair failed.
    case renameFailed
    /// The directory could not be created.
    case directoryRefused
}