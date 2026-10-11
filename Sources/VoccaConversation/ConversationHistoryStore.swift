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
import OSLog
import VoccaCore

/// **The conversation store's file-system seam — the one file in `VoccaConversation` permitted
/// to name `FileManager`** (the `conversation` row in `InjectionSeamBoundaryTests`' per-seam
/// FileManager table, beside the journal, dictionary, config, strategy, usage, consent and
/// actions seams' adapters).
///
/// Raw operations only, in the strategy adapter's shape: directory creation, the atomic
/// temp-write-then-rename commit, reads, an existence check and removal. Nothing here decides.
/// Which row is unreadable, what version is accepted, what the caps are and when a commit
/// happens are ``ConversationHistoryStore``'s questions, answered over this seam — a second
/// `FileManager`-naming file in the module would be a conversation-store decision that escaped
/// the headless suite forever.
public protocol ConversationFileSystem: Sendable {
    /// Create `url` (and its parents), as `FileManager` would with
    /// `withIntermediateDirectories: true`.
    func createDirectory(at url: URL) async throws

    /// Write `data` to `url`.
    func write(_ data: Data, to url: URL) async throws

    /// Move the file at `source` over `destination` — the commit point of the atomic pair.
    /// Succeeds whether or not `destination` already exists: an overwrite is a replace, not a
    /// refusal.
    func moveItem(at source: URL, to destination: URL) async throws

    /// Delete the file at `url`. Called only for a file the store has just seen exist, so a
    /// missing one may throw — the store's own ``ConversationHistoryStore/clear()`` asks first.
    func removeItem(at url: URL) async throws

    /// The file's bytes, or `nil` if it cannot be read.
    func read(_ url: URL) async -> Data?

    /// Whether a file exists at `path`.
    func fileExists(atPath path: String) async -> Bool
}

/// The seam's only `FileManager` implementation — translation with no decisions in it.
public struct DefaultConversationFileSystem: ConversationFileSystem {
    public init() {}

    public func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    public func moveItem(at source: URL, to destination: URL) async throws {
        // The atomic replace, not `moveItem`: `FileManager.moveItem` refuses an existing
        // destination (NSFileWriteFileExistsError), which — in the strategy store, where this
        // was learned — made every save after the first fail once the file existed. A history
        // appended turn by turn is exactly that shape: the first turn would persist and every
        // turn after it would throw. `replaceItemAt` is the same rename-over commit and
        // succeeds whether or not the destination is there.
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
    }

    public func removeItem(at url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }

    public func read(_ url: URL) async -> Data? {
        FileManager.default.contents(atPath: url.path)
    }

    public func fileExists(atPath path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// One completed CONVERSING turn: what the user said, what Vocca replied, and whether the reply
/// was interrupted by a barge-in. This is the whole record — **no wall-clock time, no session
/// ID, no bundle ID, no other metadata**; order is the only thing bound to a turn, and it is
/// carried by the array.
public struct ConversationTurn: Equatable, Sendable {
    /// The cleaned utterance the user spoke.
    public let utterance: String

    /// The reply text that was committed to speak.
    public let reply: String

    /// Whether a barge-in interrupted this turn's reply. `false` for a turn as recorded.
    public let interrupted: Bool

    /// A turn. `interrupted` defaults to `false` — a freshly recorded turn is not interrupted.
    public init(utterance: String, reply: String, interrupted: Bool = false) {
        self.utterance = utterance
        self.reply = reply
        self.interrupted = interrupted
    }
}

/// The bounded, purged conversation history on disk — `<directory>/conversation.json` — and the
/// ``ConversationRecording`` the driver is handed at composition.
///
/// It is the ``PersistentUsageStore``/``PersistentConsentStore`` shape deliberately: a store
/// over a directory, with the decisions — the caps, the tolerant per-row decode, the oldest-first
/// eviction, the truncation — belonging above the file system where a headless suite can drive
/// them, and nothing but path resolution and raw I/O below.
///
/// ## The format
///
/// ```json
/// { "version": 1,
///   "turns": [
///     { "utterance": "…", "reply": "…", "interrupted": false },
///     { "utterance": "…", "reply": "…", "interrupted": true } ] }
/// ```
///
/// Version 1 is the first version and there is no migration machinery. The version gate refuses
/// a file a later build wrote rather than guessing at a format this build has never seen.
///
/// ## The bounds, and the deliberate divergence
///
/// ``maximumTurns`` is 50 and ``maximumTextCharacters`` is 2000 (the bubble's render cap value,
/// reused — one documented bound). At the turn cap the **oldest turn is evicted**: a deliberate,
/// recorded divergence from the settings stores' refuse-never-clamp, following the
/// RecoveryJournal precedent, because a history that silently stops recording is worse than one
/// that discloses a finite window ("keeps the last 50 turns"). An over-cap text is
/// **truncated**, not refused, for the same reason — and truncation counts characters, never
/// bytes, so a multi-byte UTF-8 scalar is never split. The bounds are re-applied on the way in
/// too: a hand-edited file holding more than the window loads bounded.
///
/// ## Tolerant on the way in, and loud about it
///
/// Four gates refuse a whole file — a top level that is not an object, a `version` this build
/// has never seen, no `turns` list, and a read that answered `nil` — and each emits exactly one
/// line through the injected ``log``. Below them, each turn row is decoded on its own, and a row
/// that cannot be read is skipped with one line of its own rather than costing the file. Nothing
/// is repaired: a refused file and a skipped row are both left exactly as the user wrote them,
/// because a load that rewrites is a load that can delete history the user opened the file to
/// read. **A load never writes.**
///
/// ## Concurrency contract
///
/// Single process, one actor: ``load()`` once at launch, then ``recordTurn(utterance:reply:)``
/// / ``markLastTurnInterrupted()`` / ``clear()`` mutate the held turns and persist the **whole
/// list** atomically — a racing pair of records ends with one complete file, never a partial
/// one. The atomic rename means a concurrent read sees the old or the new complete file. An
/// actor is the honest Swift 6 shape for that state, the ``PersistentUsageStore`` precedent.
///
/// ## Failure contract
///
/// ``recordTurn(utterance:reply:)`` and ``markLastTurnInterrupted()`` never throw — the
/// ``ConversationRecording`` contract — so a persist failure is logged through ``log`` and the
/// in-memory turn stays; the conversation is never interrupted by a filed history. ``load()``
/// never throws and never writes. Only ``clear()`` throws, when a file that *is* there could not
/// be removed: the caller's state says the history is gone and the disk disagrees, and only the
/// caller can say so out loud.
public actor ConversationHistoryStore: ConversationRecording {
    /// The directory the history lives in. The file is always `<directory>/conversation.json`.
    public let directory: URL

    private let maximumTurns: Int
    private let maximumTextCharacters: Int
    private let fileSystem: ConversationFileSystem
    private let onChange: @Sendable (Int) -> Void
    private let log: @Sendable (String) -> Void
    private var held: [ConversationTurn] = []

    /// The history's file name, in one place, because it is the persisted spelling: changing it
    /// orphans every existing install's window rather than migrating it.
    public static let fileName = "conversation.json"

    /// The turn cap — the disclosed window ("keeps the last 50 turns"). At the cap the oldest
    /// turn is evicted (the divergence the type's doc comment records).
    public static let maximumTurns = 50

    /// The per-text cap — the bubble's render value, reused so the surface and the store share
    /// one bound. Over-cap texts are truncated at this many **characters**, never bytes.
    public static let maximumTextCharacters = 2000

    /// The suffix of the temp file mid-commit — never readable, never loaded.
    private static let tempSuffix = ".tmp"

    /// The format's version, in one place so ``encode(_:)`` and the version gate in
    /// ``decode(_:onInvalidRow:)`` cannot drift into writing one number and accepting another.
    /// Version 1 is the first version and there is no migration machinery.
    private static let formatVersion = 1

    /// The file itself — `<directory>/conversation.json`.
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// A store over `directory`. The directory is created on the first persist; a store over a
    /// directory that does not exist is an empty history, not an error.
    ///
    /// The caps are composition-root-settable (defaulting to the disclosed ``maximumTurns`` /
    /// ``maximumTextCharacters``) so a future surface can tighten the window without a store
    /// rewrite. ``onChange`` is the menu-condition fold's source: it fires with the new count
    /// after every record, after a clear and after the launch load — never after a barge-in
    /// mark, which changes no count. Defaults are no-ops, so an unwired store is byte-identical
    /// to one whose caller ignored the signal.
    ///
    /// The `log` closure is the loud half of the corruption and failure policy — every skipped
    /// row, every refused file and every failed persist goes through it, injectable so the
    /// loudness is asserted rather than hoped.
    public init(
        directory: URL,
        maximumTurns: Int = ConversationHistoryStore.maximumTurns,
        maximumTextCharacters: Int = ConversationHistoryStore.maximumTextCharacters,
        fileSystem: ConversationFileSystem = DefaultConversationFileSystem(),
        onChange: @escaping @Sendable (Int) -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "conversation-history").error("\($0)")
        }
    ) {
        self.directory = directory
        self.maximumTurns = maximumTurns
        self.maximumTextCharacters = maximumTextCharacters
        self.fileSystem = fileSystem
        self.onChange = onChange
        self.log = log
    }

    /// A store over the default location (`ARCHITECTURE.md`'s Application Support table):
    /// `~/Library/Application Support/Vocca/conversation.json`. The fallback keeps the store
    /// working even if the Application Support directory is unavailable to resolve — a
    /// defensive default, not a decision about where the history lives.
    public init() {
        self.init(
            directory: Self.defaultDirectory(
                applicationSupport: FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                ).first,
                home: FileManager.default.homeDirectoryForCurrentUser))
    }

    /// Where ``init()`` puts the history, as a pure function of what the file system answered —
    /// `<applicationSupport>/Vocca`, or `<home>/Library/Application Support/Vocca` when
    /// Application Support could not be resolved.
    ///
    /// Separated from ``init()`` because the fallback is otherwise unreachable in a test: the
    /// only way to drive it through the initialiser is a machine whose Application Support does
    /// not resolve, and the only way to check the resolved branch is to write into the
    /// developer's own. A pure function makes both assertable without a test ever creating a
    /// file where a real install keeps its conversation.
    static func defaultDirectory(applicationSupport: URL?, home: URL) -> URL {
        let base =
            applicationSupport ?? home.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Vocca")
    }

    // MARK: - The persisted shape

    /// The versioned top-level container — this file's own private Codable shape, written but
    /// never decoded as a whole: a load takes the top level apart with `JSONSerialization` so
    /// one bad row cannot cost the file.
    private struct PersistedFile: Encodable {
        let version: Int
        let turns: [PersistedTurn]
    }

    /// One turn's row. Exactly the three fields — no timestamp, no ID, no session.
    private struct PersistedTurn: Codable {
        let utterance: String
        let reply: String
        let interrupted: Bool
    }

    // MARK: - Encoding

    /// Encode the turns the way a persist writes them: strict `JSONEncoder` over the versioned
    /// wrapper with **sorted keys**, so the bytes are stable across calls and processes — a
    /// hand-editable, auditable file must not re-order itself between runs. In-memory turns are
    /// trusted: a persist only ever writes state the store itself bounded.
    public static func encode(_ turns: [ConversationTurn]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            PersistedFile(
                version: formatVersion,
                turns: turns.map {
                    PersistedTurn(
                        utterance: $0.utterance, reply: $0.reply, interrupted: $0.interrupted)
                }))
    }

    // MARK: - Decoding

    /// Decode the file the way ``load()`` reads it: `JSONSerialization` for the top level, then
    /// **one `JSONDecoder` per turn row**.
    ///
    /// The per-row decode is the whole point of not handing the file to a single decoder: a
    /// user's window must not be lost because one row was hand-edited into nonsense. A row that
    /// cannot be read — bad JSON, a missing field, a field of the wrong type — is **skipped**
    /// with one `onInvalidRow` call, and the readable remainder loads. The caps are not applied
    /// here; ``load()`` bounds what this returns, so decoding stays shape-only.
    ///
    /// Three gates refuse the whole file with one `onInvalidRow` call each and no partial
    /// belief: a top level that is not a JSON object, a `version` that is not ``formatVersion``
    /// (a version-2 file a later build wrote is loaded empty rather than guessed at), and a
    /// `turns` field that is missing or not a list.
    ///
    /// Never throws, and a load never writes: a file this build cannot interpret is not a file
    /// this build may overwrite.
    public static func decode(
        _ data: Data,
        onInvalidRow: @escaping @Sendable (String) -> Void
    ) -> [ConversationTurn] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let file = object as? [String: Any]
        else {
            onInvalidRow(
                "conversation-history: the file's top level is not a JSON object; loading an "
                    + "empty history")
            return []
        }
        guard let version = file["version"] as? Int, version == formatVersion else {
            onInvalidRow(
                "conversation-history: unknown conversation.json version; loading an empty "
                    + "history")
            return []
        }
        guard let rows = file["turns"] as? [Any] else {
            onInvalidRow(
                "conversation-history: conversation.json holds no turns list; loading an empty "
                    + "history")
            return []
        }

        var turns: [ConversationTurn] = []
        for (index, row) in rows.enumerated() {
            guard JSONSerialization.isValidJSONObject(row),
                let rowData = try? JSONSerialization.data(withJSONObject: row),
                let persisted = try? JSONDecoder().decode(PersistedTurn.self, from: rowData)
            else {
                onInvalidRow("conversation-history: skipping unreadable turn row at index \(index)")
                continue
            }
            turns.append(
                ConversationTurn(
                    utterance: persisted.utterance, reply: persisted.reply,
                    interrupted: persisted.interrupted))
        }
        return turns
    }

    // MARK: - Bounding

    /// Apply the one set of bounds in one place: truncate each text at the character cap
    /// (`String.prefix` counts characters, so a multi-byte UTF-8 scalar is never split) and keep
    /// the newest ``maximumTurns`` turns. Applied on record and on load alike, so the held list
    /// and the file can never exceed the disclosed window.
    private func bounded(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        var boundedTurns = turns.map {
            ConversationTurn(
                utterance: String($0.utterance.prefix(maximumTextCharacters)),
                reply: String($0.reply.prefix(maximumTextCharacters)),
                interrupted: $0.interrupted)
        }
        if boundedTurns.count > maximumTurns {
            boundedTurns.removeFirst(boundedTurns.count - maximumTurns)
        }
        return boundedTurns
    }

    // MARK: - Load, record, mark, clear

    /// The turns on disk, bounded, or the empty history. Never throws and never writes: a
    /// missing file is the empty history silently — a first run is not an error — and an
    /// unreadable one is the empty history with one loud line. Replaces the held turns, returns
    /// them, and fires ``onChange`` with the new count (the launch-load contract).
    @discardableResult
    public func load() async -> [ConversationTurn] {
        let url = fileURL
        guard await fileSystem.fileExists(atPath: url.path) else {
            held = []
            onChange(0)
            return []
        }
        guard let data = await fileSystem.read(url) else {
            log("conversation-history: could not read \(url.path); loading an empty history")
            held = []
            onChange(0)
            return []
        }
        held = bounded(Self.decode(data, onInvalidRow: log))
        onChange(held.count)
        return held
    }

    /// The turns held, in append order. The surface's read-on-open entry point; the file is read
    /// by ``load()`` at launch.
    public func currentTurns() -> [ConversationTurn] {
        held
    }

    /// Append one completed turn and persist the whole list atomically.
    ///
    /// Failure-tolerant by contract (``ConversationRecording``): the in-memory turn stays, the
    /// persist failure is logged, and no error reaches the conversation. `interrupted` is
    /// `false` — a fresh turn startles no one.
    public func recordTurn(utterance: String, reply: String) async {
        held = bounded(held + [ConversationTurn(utterance: utterance, reply: reply)])
        onChange(held.count)
        await persist()
    }

    /// Mark the most recent turn interrupted and persist — the barge-in mark. With no turns
    /// this is a no-op and writes nothing; marking an already-interrupted turn is a no-op too.
    /// No ``onChange`` fires: the count did not change.
    public func markLastTurnInterrupted() async {
        guard let last = held.last, !last.interrupted else { return }
        held[held.count - 1] = ConversationTurn(
            utterance: last.utterance, reply: last.reply, interrupted: true)
        await persist()
    }

    /// Delete `conversation.json`, so that the next ``load()`` answers the empty history, and
    /// empty the held turns.
    ///
    /// **Deletion, not a save of nothing.** The user is told the file goes (the Settings Forget
    /// action and the menu bar's row), and this is the page where the product's claims are
    /// supposed to be checkable — an empty file left where the copy says there is none would be
    /// a small lie told on the privacy screen.
    ///
    /// Asked-then-removed rather than removed-and-ignore-the-error: `FileManager.removeItem`
    /// fails for a missing file and for a file that cannot be deleted, and swallowing both would
    /// make a permission failure look exactly like a first run. A missing file returns quietly;
    /// a removal that fails throws, and the caller says so — and the held turns are untouched in
    /// that case, because the disk still has them.
    public func clear() async throws {
        let url = fileURL
        guard await fileSystem.fileExists(atPath: url.path) else {
            held = []
            onChange(0)
            return
        }
        try await fileSystem.removeItem(at: url)
        held = []
        onChange(0)
    }

    /// The atomic persist: create the directory, encode, temp-write
    /// `<dir>/conversation.json.tmp`, rename it over `<dir>/conversation.json`. The pair is the
    /// durability claim — the bytes become visible at the rename or not at all — and the stray
    /// `.tmp` a crash leaves behind is never read, because only `conversation.json` is ever
    /// loaded.
    ///
    /// Failure is logged, never thrown: this is the ``ConversationRecording`` path, and a
    /// filed history must not interrupt the conversation.
    private func persist() async {
        do {
            try await fileSystem.createDirectory(at: directory)
            let data = try Self.encode(held)
            let tempURL = directory.appendingPathComponent(Self.fileName + Self.tempSuffix)
            try await fileSystem.write(data, to: tempURL)
            try await fileSystem.moveItem(at: tempURL, to: fileURL)
        } catch {
            log(
                "conversation-history: could not persist to \(fileURL.path); the in-memory "
                    + "history is not on disk: \(error)")
        }
    }
}