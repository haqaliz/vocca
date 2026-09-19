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

/// The append-only action audit log — the `audit-log` aspect's whole contract
/// (`action-safety-spine` PRD M6/G3, C13's third acceptance leg).
///
/// ## What the log is for, and why the assertions are shaped this way
///
/// C13's acceptance is *reconstruction*: every executed action must be recoverable from the file
/// the store wrote, in order, with the decision that let it run and the outcome it produced. The
/// reconstruction test therefore drives real submissions through ``ActionGate`` against
/// ``RecordingActionProvider`` — the executing stub (PRD M10) — rather than hand-building entries.
/// A log asserted over hand-built values proves the encoder round-trips; it does not prove the
/// thing the gate decided is the thing the file holds.
///
/// **The domain is non-empty by construction and it is asserted.** PRD §6/C1 records that G3 was
/// vacuous as first drafted: with only `NullActionProvider` in the tree, "every executed action is
/// reconstructible" ranges over nothing at all. Every test here that claims something about
/// executed actions first asserts that something executed.
///
/// ## Append-only is by directory, never by file mode
///
/// Nothing in this repository appends to a file. The journal's shape is the house convention and
/// this store follows it exactly: one file per event, named by a zero-padded 8-digit write ordinal
/// so that lexicographic order *is* numeric order, committed as a `.tmp` write renamed over the
/// final name. A crash between the two steps leaves a `.tmp` that neither ``load()`` nor ``list()``
/// can see — never a readable partial entry.
final class ActionAuditStoreTests: XCTestCase {

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-action-audit-\(UUID().uuidString)")
    }

    private func makeInvocation(
        providerID: String = "dev.vocca.stub", toolID: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(providerID: providerID, toolID: toolID),
            "a non-empty provider id and tool id must construct an invocation", file: file,
            line: line)
    }

    /// The committed entry files in `directory`, ascending — read with `FileManager` directly
    /// rather than through the store, so that eviction and the `.tmp` protocol are asserted on the
    /// directory itself and not on a reader's opinion of it.
    private func committedFileNames(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }

    /// The distinctive sentence the stub renders, so an assertion can tell one entry from another.
    private func sentence(of entry: ActionAuditEntry) -> String { entry.summary }

    // MARK: - 1. Reconstruction (C13 acceptance leg 3, PRD G3)

    /// **Every executed action is reconstructible from the log, in order, with its decision and
    /// outcome intact** — driven through the gate, against a provider that genuinely executes.
    ///
    /// Six submissions covering the whole of ``ActionDecision``: a read-only tool that ran without
    /// being asked about, a confirmed destructive one that succeeded, a confirmed outward-facing
    /// one that *failed*, a destructive one refused for want of an approval, a dry-run, and a
    /// declined tool that was never described. Reloading through a **second store over the same
    /// directory** is the reconstruction claim: the first store's memory plays no part.
    func testEveryExecutedActionIsReconstructibleInOrderWithItsDecisionAndOutcome() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let listFiles = try makeInvocation(toolID: "list-files")
        let deleteDownloads = try makeInvocation(toolID: "delete-downloads")
        let sendMessage = try makeInvocation(toolID: "send-message")

        let readOnly = RecordingActionProvider(
            toolIDs: ["list-files"], describedRadius: .readOnly)
        let destructive = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive)
        let outward = RecordingActionProvider(
            toolIDs: ["send-message"], describedRadius: .outwardFacing,
            behavior: .executes(.failed(reasonKey: "provider.rateLimited")))

        let enabled = ActionEnablement([listFiles, deleteDownloads, sendMessage])
        let store = FileSystemActionAuditStore(directory: directory)

        let submissions: [(ActionInvocation, ActionDecision)] = [
            (listFiles, await ActionGate.submit(listFiles, to: readOnly, enablement: enabled)),
            (
                deleteDownloads,
                await ActionGate.submit(
                    deleteDownloads, to: destructive, enablement: enabled, approval: .granted)
            ),
            (
                sendMessage,
                await ActionGate.submit(
                    sendMessage, to: outward, enablement: enabled, approval: .granted)
            ),
            (
                deleteDownloads,
                await ActionGate.submit(deleteDownloads, to: destructive, enablement: enabled)
            ),
            (
                deleteDownloads,
                await ActionGate.submit(
                    deleteDownloads, to: destructive, enablement: enabled, approval: .granted,
                    mode: .dryRun)
            ),
            (
                listFiles,
                await ActionGate.submit(listFiles, to: readOnly, enablement: ActionEnablement())
            ),
        ]

        for (index, submission) in submissions.enumerated() {
            _ = try await store.record(
                submission.0, decision: submission.1, at: .seconds(100 + index))
        }

        XCTAssertEqual(
            readOnly.executionCount + destructive.executionCount + outward.executionCount, 3,
            """
            vacuity guard: three of the six submissions must genuinely have reached a provider. \
            With nothing executing, "every executed action is reconstructible" ranges over an \
            empty set and passes while witnessing nothing (PRD §6/C1).
            """)

        let reloaded = await FileSystemActionAuditStore(directory: directory).load()

        XCTAssertEqual(
            reloaded.count, 6,
            "every submission is on the record — a refusal is an event the log exists to hold")
        XCTAssertEqual(
            reloaded.map(\.id), [1, 2, 3, 4, 5, 6],
            "the write ordinals reconstruct the order the submissions were made in")
        XCTAssertEqual(
            reloaded.map(\.toolID),
            [
                "list-files", "delete-downloads", "send-message", "delete-downloads",
                "delete-downloads", "list-files",
            ],
            "each entry is attributed to the tool that was submitted")
        XCTAssertEqual(
            reloaded.map(\.providerID), Array(repeating: "dev.vocca.stub", count: 6),
            "and to the provider that owns it")
        XCTAssertEqual(
            reloaded.map(\.decision),
            [.autoRanReadOnly, .confirmed, .confirmed, .refused, .dryRun, .refused],
            """
            the decision the gate made survives the round trip. Read-only ran without a human \
            being asked; two ran on a confirmation; one was refused for want of one; one was a \
            rehearsal; one was declined before the provider was ever asked what it would do.
            """)
        XCTAssertEqual(
            reloaded.map(\.outcome),
            [
                .succeeded, .succeeded, .failed(reasonKey: "provider.rateLimited"), .notInvoked,
                .notInvoked, .notInvoked,
            ],
            """
            and so does the outcome. Only the three that reached a provider carry one that is not \
            `.notInvoked` — the log's one real question is whether this actually ran.
            """)
        XCTAssertTrue(
            sentence(of: reloaded[1]).contains("delete-downloads"),
            "the concrete sentence the gate rendered is the record of what the user faced: "
                + "\(sentence(of: reloaded[1]))")
    }

    // MARK: - 2. Ordinals

    /// Ordinals are monotonic and **survive a reload** — the counter is rebuilt from the entries on
    /// disk, never held only in memory (the journal's precedent).
    ///
    /// The second store is constructed after the first is gone. A counter that lived in the process
    /// would restart at 1 here and overwrite the first three entries, which is the failure mode
    /// this test exists for: an audit log that silently overwrites its own history.
    func testOrdinalsAreMonotonicAndSurviveAReload() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invocation = try makeInvocation(toolID: "list-files")

        var first: FileSystemActionAuditStore? = FileSystemActionAuditStore(directory: directory)
        for index in 0..<3 {
            _ = try await first?.record(
                invocation, decision: Self.ranReadOnly(invocation), at: .seconds(index))
        }
        first = nil

        let second = FileSystemActionAuditStore(directory: directory)
        let fourth = try await second.record(
            invocation, decision: Self.ranReadOnly(invocation), at: .seconds(3))

        XCTAssertEqual(
            fourth.id, 4,
            "the ordinal continues from what is on disk — a counter rebuilt from the directory, "
                + "not one that restarts with the process")
        let ordinals = await second.list()
        XCTAssertEqual(
            ordinals, [1, 2, 3, 4],
            "the ordinals are contiguous and ascending, which is what makes oldest-first eviction "
                + "a comparison of integers and nothing else")
        XCTAssertEqual(
            committedFileNames(in: directory),
            ["00000001.json", "00000002.json", "00000003.json", "00000004.json"],
            "entries are named by a zero-padded 8-digit ordinal, so lexicographic order is "
                + "numeric order for any realistic log lifetime")
    }

    // MARK: - 3. The atomic commit, and the `.tmp` file it leaves behind on a crash

    /// A save is the **atomic temp-write-then-rename pair**, recorded through the injected seam.
    func testASaveIsATempWriteRenamedOverTheEntryName() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = RecordingActionAuditFileSystem(directory: directory)
        let store = FileSystemActionAuditStore(directory: directory, fileSystem: fileSystem)
        let invocation = try makeInvocation(toolID: "list-files")

        _ = try await store.record(
            invocation, decision: Self.ranReadOnly(invocation), at: .seconds(1))

        let events = await fileSystem.events
        XCTAssertEqual(
            events, [.tempWrite("00000001.json.tmp"), .rename("00000001.json")],
            """
            the commit is a temp write renamed over the entry name, in that order. The store must \
            not answer before the rename: a crash between the two steps must leave a file nothing \
            can read, never a half-written entry that loads as truth.
            """)
    }

    /// A `.tmp` file mid-commit is **neither readable nor listable as an entry**, and does not
    /// consume an ordinal.
    ///
    /// The crash this simulates is the one the atomic pair exists for. The file left behind holds
    /// perfectly valid JSON — the point is that the *name* is what makes it invisible, so a partial
    /// write (which would not) is invisible for the same reason.
    func testATempFileMidCommitIsNeitherReadableNorListable() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invocation = try makeInvocation(toolID: "list-files")
        let store = FileSystemActionAuditStore(directory: directory)
        let committed = try await store.record(
            invocation, decision: Self.ranReadOnly(invocation), at: .seconds(1))

        let orphan = directory.appendingPathComponent("00000002.json.tmp")
        try FileSystemActionAuditStore.encode(committed).write(to: orphan)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: orphan.path),
            "vacuity guard: the mid-commit file must actually be on disk for its invisibility to "
                + "mean anything")

        let reader = FileSystemActionAuditStore(directory: directory)
        let listed = await reader.list()
        let loaded = await reader.load()
        XCTAssertEqual(listed, [1], "a .tmp file is not an entry")
        XCTAssertEqual(loaded.count, 1, "and it is not loaded")
        let next = try await reader.record(
            invocation, decision: Self.ranReadOnly(invocation), at: .seconds(2))
        XCTAssertEqual(
            next.id, 2,
            "nor does it reserve an ordinal — an uncommitted write leaves no trace in the "
                + "numbering")
    }

    // MARK: - 4. Tolerant decode

    /// A corrupt entry is **skipped**, the injected callback fires, and the store still loads
    /// everything else. It never throws.
    ///
    /// One bad file must never cost the log. The callback is the loud half: a skip nobody can
    /// observe is indistinguishable from an entry that was never written.
    func testACorruptEntryIsSkippedLoudlyAndTheRestStillLoads() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invocation = try makeInvocation(toolID: "list-files")
        let writer = FileSystemActionAuditStore(directory: directory)
        for index in 0..<3 {
            _ = try await writer.record(
                invocation, decision: Self.ranReadOnly(invocation), at: .seconds(index))
        }
        try Data("{ this is not an entry".utf8)
            .write(to: directory.appendingPathComponent("00000002.json"))

        let complaints = ComplaintRecorder()
        let store = FileSystemActionAuditStore(
            directory: directory, log: complaints.log)
        let loaded = await store.load()

        XCTAssertEqual(
            loaded.map(\.id), [1, 3],
            "the readable entries load; the corrupt one is skipped rather than fatal")
        XCTAssertEqual(
            complaints.recorded.count, 1,
            "exactly one complaint — the skip is loud, or it is invisible: \(complaints.recorded)")
        XCTAssertTrue(
            complaints.recorded.joined().contains("00000002"),
            "the complaint names the file, so the user can go and look at it: "
                + "\(complaints.recorded)")
    }

    /// An entry naming a decision, radius or outcome this build does not know is routed into the
    /// same skip path — schema drift is corruption, not a value to guess at.
    func testAnEntryNamingAnUnknownVocabularyIsSkippedRatherThanGuessedAt() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let drifted = """
            {"blastRadius":"planetary","decision":"whoKnows","id":1,"instantAttoseconds":0,\
            "instantSeconds":7,"outcome":{"kind":"succeeded"},"providerID":"dev.vocca.stub",\
            "summary":"Stub would run list-files.","toolID":"list-files"}
            """
        try Data(drifted.utf8).write(to: directory.appendingPathComponent("00000001.json"))

        let complaints = ComplaintRecorder()
        let loaded = await FileSystemActionAuditStore(directory: directory, log: complaints.log)
            .load()

        XCTAssertEqual(
            loaded, [],
            "a radius and a decision this build cannot name are not values to approximate — an "
                + "audit entry read wrongly is worse than one not read at all")
        XCTAssertEqual(complaints.recorded.count, 1, "and the skip is loud: \(complaints.recorded)")
    }

    /// The decoder is `static`, pure and **never throws** — asserted against bytes chosen to break
    /// it, because "never throws" is only a claim until something ugly is handed to it.
    func testTheDecoderNeverThrowsWhateverItIsHanded() {
        let complaints = ComplaintRecorder()
        for bytes in [Data(), Data([0xff, 0xfe, 0x00]), Data("[]".utf8), Data("{}".utf8)] {
            XCTAssertNil(
                FileSystemActionAuditStore.decode(bytes, onInvalidElement: complaints.log),
                "undecodable bytes answer nil — a corrupt file must never be fatal")
        }
        XCTAssertEqual(
            complaints.recorded.count, 4, "every rejection is reported: \(complaints.recorded)")
    }

    // MARK: - 5. The cap, and clearing

    /// The cap evicts **oldest-first by ordinal**, and it is enforced **on write**.
    ///
    /// Eviction on write is the deliberate choice (spec's open question): the cap is a fact about
    /// the directory, not about a reader. The assertion is therefore on the files on disk, read
    /// with `FileManager` directly — a store that evicted only in `load()` would leave the user's
    /// disk growing without bound while every test that asked the store looked green.
    func testTheCapEvictsOldestFirstByOrdinalOnWrite() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invocation = try makeInvocation(toolID: "list-files")
        let store = FileSystemActionAuditStore(directory: directory, capacity: 3)

        for index in 0..<5 {
            _ = try await store.record(
                invocation, decision: Self.ranReadOnly(invocation), at: .seconds(index))
        }

        XCTAssertEqual(
            committedFileNames(in: directory),
            ["00000003.json", "00000004.json", "00000005.json"],
            """
            the three newest entries survive and the two oldest are gone from the directory \
            itself. The cap is enforced at the moment of writing, so it bounds the file system \
            rather than bounding what a reader chooses to return.
            """)
        let surviving = await store.load().map(\.id)
        XCTAssertEqual(surviving, [3, 4, 5], "and the reader agrees")
    }

    /// Clearing empties the directory of entries.
    func testClearingEmptiesTheDirectory() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invocation = try makeInvocation(toolID: "list-files")
        let store = FileSystemActionAuditStore(directory: directory)
        for index in 0..<3 {
            _ = try await store.record(
                invocation, decision: Self.ranReadOnly(invocation), at: .seconds(index))
        }
        XCTAssertEqual(
            committedFileNames(in: directory).count, 3, "vacuity guard: there is something to clear")

        try await store.clear()

        let remaining = await store.load()
        XCTAssertEqual(committedFileNames(in: directory), [], "the entries are gone from disk")
        XCTAssertEqual(remaining, [], "and the log reads empty")
    }

    // MARK: - 6. The byte-level pin

    /// **The aspect's central promise, asserted on the artifact.** A genuinely populated entry
    /// encodes to an object whose keys are exactly the nine PRD §5 fields, holding no time of day,
    /// no ISO-8601 marker, no Zulu suffix and no epoch-shaped integer.
    ///
    /// ## The one deliberate difference from every other byte pin in this tree
    ///
    /// **`summary` is permitted to carry text, and that is the point of the field.** The consent
    /// pin (`PersistentConsentStoreTests.swift:469`) and the usage pin forbid text outright,
    /// because a bundle ID and a bucket count are all those files need and any prose in them would
    /// be a transcript leak. This file is different in kind: it is the record of *what the user was
    /// asked to approve*, and C13 requires that question to be concrete ("send this message to
    /// #general", never "execute slack_post"). A summary with no content would defeat the log's
    /// only purpose. A later reader who "fixes" this to match its ancestors would be deleting the
    /// audit log's evidence, not tightening its privacy.
    ///
    /// What is still forbidden is unchanged: **raw tool arguments are not persisted** (PRD §5) —
    /// the rendered sentence is a bounded rendering, not a wire dump — and no wall-clock reading
    /// reaches the file in any shape.
    ///
    /// ## What each half is worth
    ///
    /// The key-set pin is the strong half: a tenth field — a `rawArguments`, an `approvedBy`, a
    /// `wallClock` — fails this on the day it is added, which is exactly what the PRD promises
    /// when it calls the no-raw-arguments decision "cheaply reversible". The time regexes are the
    /// defence-in-depth half, and one of them had to be scoped rather than deleted: see below.
    func testTheEncodedEntryCarriesTheNineFieldsAndNoWallClockTime() throws {
        let invocation = try makeInvocation(toolID: "delete-downloads")
        let summary = ActionSummary(
            sentence: "Delete 3 files in ~/Downloads.", blastRadius: .destructive)
        let entry = ActionAuditEntry(
            id: 7, instant: .seconds(12345) + .milliseconds(678), invocation: invocation,
            decision: .invoked(summary: summary, outcome: .failed(reasonKey: "provider.diskFull")))

        XCTAssertFalse(
            entry.summary.isEmpty,
            "vacuity guard: the pin must run against an entry whose summary is genuinely populated")
        XCTAssertFalse(
            entry.providerID.isEmpty || entry.toolID.isEmpty,
            "vacuity guard: the attribution must be populated too")
        XCTAssertEqual(
            entry.blastRadius, .destructive,
            "vacuity guard: the entry under test carries a classified radius, so the assertions "
                + "below are made against a fully-populated entry rather than a sparse one")

        let data = try FileSystemActionAuditStore.encode(entry)
        let text = String(decoding: data, as: UTF8.self)

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("the encoded bytes must decode as a JSON object")
        }
        XCTAssertEqual(
            Set(object.keys),
            [
                "id", "instantSeconds", "instantAttoseconds", "providerID", "toolID",
                "blastRadius", "decision", "outcome", "summary",
            ],
            """
            the entry's keys must be exactly the nine PRD §5 fields. A raw-arguments field, an \
            approver name or a wall-clock field fails here on the day it is added — the PRD calls \
            the no-raw-arguments decision cheaply reversible precisely because this pin makes the \
            reversal loud. Got: \(Set(object.keys).sorted())
            """)
        XCTAssertEqual(
            Set((object["outcome"] as? [String: Any])?.keys ?? [:].keys), ["kind", "reasonKey"],
            "the outcome's own keys are pinned for the same reason the top level's are")

        // The sentence is asserted on the bytes with a slash-free fragment and on the decoded
        // value in full: `JSONEncoder` escapes a forward slash (`~\/Downloads`), which is the
        // format's business and not the pin's. Reaching for `.withoutEscapingSlashes` to make a
        // substring match would be changing what every user's file looks like to suit a test.
        XCTAssertTrue(
            text.contains("Delete 3 files in"),
            """
            the summary carries its text, and this assertion is here to say so deliberately. \
            Every other byte pin in this tree forbids text; this one requires it, because the \
            sentence is the record of what the user was asked. Bytes: \(text)
            """)
        XCTAssertEqual(
            object["summary"] as? String, "Delete 3 files in ~/Downloads.",
            "and it survives the format intact — the escaping is JSON's, not a truncation")

        XCTAssertNil(
            text.range(of: "[0-9]:[0-9]", options: .regularExpression),
            "the entry must hold no time of day — a colon between two digits is the HH:MM shape. "
                + "Bytes: \(text)")
        for (name, pattern) in [
            ("an ISO-8601 date-time marker", "[0-9]{4}-[0-9]{2}-[0-9]{2}T"),
            ("a Zulu suffix", "[0-9]Z"),
        ] {
            XCTAssertNil(
                text.range(of: pattern, options: .regularExpression),
                """
                the entry must hold no wall-clock timestamp: found \(name). The instant is a \
                monotonic Duration's two components, never a clock reading — a wall clock lies \
                across an NTP step or a DST change. Bytes: \(text)
                """)
        }

        // The epoch-shaped check, scoped rather than deleted. `instantAttoseconds` is a count of
        // attoseconds within a second, so it is up to 18 digits wide by construction and contains
        // a 10-digit run whenever it is non-zero; `instantSeconds` is a monotonic uptime that
        // could in principle reach ten digits on a machine that never rebooted. Both would trip
        // the ancestors' bare `[0-9]{10}` for reasons that have nothing to do with a wall clock.
        // Deleting the check would give up its protection over every *other* field, so it is
        // scoped to the bytes outside the two instant fields, and the instants are pinned
        // separately below against the exact components they were built from.
        var outsideTheInstants = text
        for key in ["instantSeconds", "instantAttoseconds"] {
            guard let value = object[key] else { continue }
            outsideTheInstants = outsideTheInstants.replacingOccurrences(
                of: "\"\(key)\":\(value)", with: "\"\(key)\":")
        }
        XCTAssertNil(
            outsideTheInstants.range(of: "[0-9]{10}", options: .regularExpression),
            """
            no field outside the two monotonic instant components may hold an epoch-shaped \
            integer: a ten-digit number anywhere else is a Unix timestamp wearing a different \
            field's name. Bytes: \(outsideTheInstants)
            """)
        XCTAssertEqual(
            object["instantSeconds"] as? UInt64, 12345,
            "the persisted seconds component is exactly the Duration the caller passed — no clock "
                + "was read behind the caller's back")
        XCTAssertEqual(
            object["instantAttoseconds"] as? UInt64, 678_000_000_000_000_000,
            "and so is the attoseconds component — the pair round-trips a Duration without loss")
    }

    /// The entry the pin encoded round-trips back through the decoder, whole.
    ///
    /// Without this leg the pin could be satisfied by an encoder that writes correct-looking bytes
    /// nothing can read — a file that looks like an audit log and reconstructs nothing.
    func testThePinnedEntryRoundTripsThroughTheDecoder() throws {
        let invocation = try makeInvocation(toolID: "delete-downloads")
        let entry = ActionAuditEntry(
            id: 7, instant: .seconds(12345) + .milliseconds(678), invocation: invocation,
            decision: .invoked(
                summary: ActionSummary(
                    sentence: "Delete 3 files in ~/Downloads.", blastRadius: .destructive),
                outcome: .failed(reasonKey: "provider.diskFull")))
        let complaints = ComplaintRecorder()

        let decoded = FileSystemActionAuditStore.decode(
            try FileSystemActionAuditStore.encode(entry), onInvalidElement: complaints.log)

        XCTAssertEqual(decoded, entry, "the round trip is lossless — that is the reconstruction")
        XCTAssertEqual(complaints.recorded, [], "and silent: \(complaints.recorded)")
    }

    // MARK: - 7. The summary bound

    /// `summary` is bounded at 1 KB of UTF-8 **in exactly one place**, asserted at the boundary and
    /// one byte over it.
    ///
    /// A provider renders the sentence, so its length is not ours to trust: an unbounded field is
    /// an unbounded file. The bound is a truncation rather than a refusal because an audit entry
    /// that is dropped for being verbose is the one failure an audit log must not have.
    func testTheSummaryIsBoundedAtOneKilobyteOfUTF8() throws {
        let invocation = try makeInvocation(toolID: "delete-downloads")
        let atTheBoundary = String(repeating: "a", count: 1024)
        let oneOver = String(repeating: "a", count: 1025)

        XCTAssertEqual(
            atTheBoundary.utf8.count, ActionAuditEntry.maximumSummaryUTF8Bytes,
            "vacuity guard: the boundary string is exactly the bound")

        let kept = ActionAuditEntry(
            id: 1, instant: .seconds(1), invocation: invocation,
            decision: .previewed(ActionSummary(sentence: atTheBoundary, blastRadius: .readOnly)))
        XCTAssertEqual(
            kept.summary, atTheBoundary,
            "a summary exactly at the bound is kept whole — the bound is inclusive, and an "
                + "off-by-one here silently truncates every sentence in the log")

        let truncated = ActionAuditEntry(
            id: 2, instant: .seconds(1), invocation: invocation,
            decision: .previewed(ActionSummary(sentence: oneOver, blastRadius: .readOnly)))
        XCTAssertEqual(
            truncated.summary.utf8.count, ActionAuditEntry.maximumSummaryUTF8Bytes,
            "one byte over the bound truncates to it")
    }

    /// Truncation respects character boundaries: a sentence cut at 1 KB never produces invalid
    /// UTF-8 or a replacement character.
    ///
    /// The obvious implementation — cut the byte buffer at 1024 — splits a multi-byte character
    /// whenever one straddles the boundary, and the file it writes is then not valid UTF-8 at all.
    func testTruncationNeverSplitsACharacter() {
        // Three-byte characters: 342 of them is 1026 bytes, so the 1024-byte boundary falls one
        // byte into the 342nd character — the split this test exists to refuse.
        let straddling = String(repeating: "あ", count: 342)
        XCTAssertEqual(straddling.utf8.count, 1026, "vacuity guard: the boundary falls mid-character")

        let bounded = ActionAuditEntry.boundedSummary(straddling)

        XCTAssertLessThanOrEqual(
            bounded.utf8.count, ActionAuditEntry.maximumSummaryUTF8Bytes, "the bound holds")
        XCTAssertEqual(
            bounded.utf8.count, 1023,
            "and it stops at the last whole character before the bound — 341 three-byte characters")
        XCTAssertFalse(
            bounded.unicodeScalars.contains("\u{FFFD}"),
            "no replacement character: a truncation that splits a character writes a file that is "
                + "not valid UTF-8")
        XCTAssertEqual(
            String(decoding: Data(bounded.utf8), as: UTF8.self), bounded,
            "the bounded string survives a UTF-8 round trip intact")
    }

    /// The bound reaches the **file**, not merely the in-memory value: an oversized sentence
    /// recorded through the store is bounded on disk too.
    func testTheBoundReachesTheFile() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invocation = try makeInvocation(toolID: "delete-downloads")
        let store = FileSystemActionAuditStore(directory: directory)

        _ = try await store.record(
            invocation,
            decision: .previewed(
                ActionSummary(
                    sentence: String(repeating: "b", count: 4096), blastRadius: .readOnly)),
            at: .seconds(1))

        let entries = await store.load()
        let reloaded = try XCTUnwrap(entries.first)
        XCTAssertEqual(
            reloaded.summary.utf8.count, ActionAuditEntry.maximumSummaryUTF8Bytes,
            "the bound is applied before the bytes are written, so an unbounded provider cannot "
                + "grow the file past it")
    }

    // MARK: - 8. A refusal is not a failure (R8)

    /// **A refused action is distinguishable from a failed one in the persisted entry.**
    ///
    /// R8 — "actions do something destructive the user didn't intend" — turns on exactly this
    /// distinction. "Vocca stopped this" and "this ran and went wrong" are different events, and a
    /// log that conflated them could not answer the only question it exists for. The distinction is
    /// carried by two fields at once, so neither alone is load-bearing: `decision` says whether a
    /// human's yes was present, `outcome` says whether anything was attempted.
    func testARefusedActionIsDistinguishableFromAFailedOneOnDisk() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invocation = try makeInvocation(toolID: "delete-downloads")
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive,
            behavior: .executes(.failed(reasonKey: "provider.diskFull")))
        let enabled = ActionEnablement([invocation])
        let store = FileSystemActionAuditStore(directory: directory)

        let refused = await ActionGate.submit(invocation, to: provider, enablement: enabled)
        let failed = await ActionGate.submit(
            invocation, to: provider, enablement: enabled, approval: .granted)
        let declined = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement())
        for (index, decision) in [refused, failed, declined].enumerated() {
            _ = try await store.record(invocation, decision: decision, at: .seconds(index))
        }

        XCTAssertEqual(
            provider.executionCount, 1,
            "vacuity guard: exactly one of the three genuinely reached the provider")

        let entries = await store.load()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(
            entries[0].decision, .refused,
            "no approval was given, so nothing was allowed to try")
        XCTAssertEqual(
            entries[0].outcome, .notInvoked,
            "and the outcome says so: a refusal recorded as a failure would read as an action "
                + "that ran badly, about an action Vocca stopped on purpose")
        XCTAssertEqual(entries[1].decision, .confirmed, "the second had its yes")
        XCTAssertEqual(
            entries[1].outcome, .failed(reasonKey: "provider.diskFull"),
            "and it ran and failed — the reason key is bounded, never an error message")
        XCTAssertEqual(
            entries[2].decision, .refused, "a disabled tool is refused before anything is asked")
        XCTAssertEqual(entries[2].outcome, .notInvoked)
        XCTAssertNotEqual(
            entries[0].outcome, entries[1].outcome,
            "the two are not the same event and the file must not be able to claim they are")
    }

    /// A tool declined before any provider call records **no radius** and the gate's bounded
    /// decline key — because nothing was ever described.
    ///
    /// The never-read property (PRD M7) is visible in the file: a radius invented for an action
    /// nobody classified would be a fabrication, and the one that matters most (`readOnly`) would
    /// be the dangerous one to guess.
    func testADeclinedActionRecordsNoRadiusAndTheBoundedDeclineKey() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invocation = try makeInvocation(toolID: "delete-downloads")
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], behavior: .failsTheTestIfInvoked)
        let store = FileSystemActionAuditStore(directory: directory)

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement())
        _ = try await store.record(invocation, decision: decision, at: .seconds(1))

        XCTAssertEqual(
            provider.describeCount, 0,
            "vacuity guard: the provider was never asked what the tool would do")

        let recorded = await store.load()
        let entry = try XCTUnwrap(recorded.first)
        XCTAssertNil(
            entry.blastRadius,
            "nothing classified this action, so the entry classifies nothing — an invented radius "
                + "in an audit log is a fabricated fact")
        XCTAssertEqual(
            entry.summary, "gate.toolNotEnabled",
            "with no sentence to record, the entry carries the gate's own bounded decline key: "
                + "the log still says why, and says it in a vocabulary, never in free text")
    }

    /// The radius recorded is the **effective** one — the provider's claim after the local policy's
    /// escalation, never the claim itself.
    ///
    /// A provider that labels a destructive tool read-only is exactly the case the escalate-only
    /// policy exists for, and an audit log that recorded the claim would report the lie back as
    /// fact.
    func testTheRecordedRadiusIsTheEffectiveOneNotTheProvidersClaim() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invocation = try makeInvocation(toolID: "delete-downloads")
        let lying = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .readOnly)
        let policy = ActionRadiusPolicy([
            ActionRadiusPolicy.Floor(invocation: invocation, radius: .outwardFacing)
        ])
        let store = FileSystemActionAuditStore(directory: directory)

        let decision = await ActionGate.submit(
            invocation, to: lying, enablement: ActionEnablement([invocation]), policy: policy,
            approval: .granted)
        _ = try await store.record(invocation, decision: decision, at: .seconds(1))

        XCTAssertEqual(
            lying.describeCount, 1, "vacuity guard: the provider really did make its claim")
        let recorded = await store.load()
        let entry = try XCTUnwrap(recorded.first)
        XCTAssertEqual(
            entry.blastRadius, .outwardFacing,
            "the entry records the radius the gate acted on. Recording the claim the gate had "
                + "already refused to believe would put the lie in the audit log as fact")
        XCTAssertEqual(
            entry.decision, .confirmed,
            "and the decision follows the effective radius: the escalation is what turned an "
                + "auto-run into an action that needed a yes")
    }

    // MARK: - 9. Failing loudly

    /// **A store whose directory cannot be created fails loudly to its caller.**
    ///
    /// An audit log that silently loses entries is worse than none: it reports a clean history of
    /// an action that happened. The caller must be able to see that the record was not made.
    func testAStoreThatCannotCreateItsDirectoryFailsLoudlyToItsCaller() async throws {
        let directory = Self.tempDirectory()
        let invocation = try makeInvocation(toolID: "delete-downloads")
        let store = FileSystemActionAuditStore(
            directory: directory, fileSystem: UncreatableDirectoryActionAuditFileSystem())

        do {
            _ = try await store.record(
                invocation, decision: Self.ranReadOnly(invocation), at: .seconds(1))
            XCTFail(
                "a store that cannot create its directory must throw. Swallowing the failure "
                    + "leaves the caller believing an action was recorded when nothing was written")
        } catch {
            // Expected: the failure reaches the caller.
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "and nothing was written — the throw is not a report of a partial success")
    }

    // MARK: - 10. Where the log lives

    /// The default directory is `actions/` under Vocca's Application Support folder — beside
    /// `recovery/`, resolved as a **pure function** of what the file system answered.
    ///
    /// Pure because the fallback is otherwise unreachable in a test (`PersistentUsageStore`'s
    /// precedent): driving it through an initializer needs a machine whose Application Support does
    /// not resolve, and checking the resolved branch means writing into the developer's own.
    func testTheDefaultDirectoryIsActionsBesideTheOtherVoccaStores() {
        let resolved = FileSystemActionAuditStore.defaultDirectory(
            applicationSupport: URL(fileURLWithPath: "/tmp/AppSupport"),
            home: URL(fileURLWithPath: "/tmp/home"))
        XCTAssertEqual(
            resolved.path, "/tmp/AppSupport/Vocca/actions",
            "the log lives in actions/ under the app's own folder — pinned, so a rename is a "
                + "reviewed edit rather than an orphaned directory on every user's disk")

        let fallback = FileSystemActionAuditStore.defaultDirectory(
            applicationSupport: nil, home: URL(fileURLWithPath: "/tmp/home"))
        XCTAssertEqual(
            fallback.path, "/tmp/home/Library/Application Support/Vocca/actions",
            "and the fallback is the same location reached the long way, not a different one")
    }

    // MARK: - Helpers

    /// A read-only decision built without the gate, for the tests whose subject is the store rather
    /// than the gate's reasoning.
    private static func ranReadOnly(_ invocation: ActionInvocation) -> ActionDecision {
        .invoked(
            summary: ActionSummary(
                sentence: "Stub would run \(invocation.toolID).", blastRadius: .readOnly),
            outcome: .succeeded)
    }
}

// MARK: - Test doubles

/// A recorder for the store's injected log — the loud half of the corruption policy, made
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

/// What the audit store's file-system seam records, in order — the **atomic-pair protocol** the
/// durability claim is carried by (the consent store's `ConsentFileSystemEvent` shape).
enum ActionAuditFileSystemEvent: Equatable {
    /// The temp file was written — not yet readable, not yet committed.
    case tempWrite(String)
    /// The temp file was renamed over the entry name — the commit point.
    case rename(String)
}

/// An ``ActionAuditFileSystem`` over a real temp directory whose every commit is recorded as the
/// atomic temp-write/rename pair. The commit is `replaceItemAt`, mirroring the shipped adapter.
actor RecordingActionAuditFileSystem: ActionAuditFileSystem {
    private(set) var events: [ActionAuditFileSystemEvent] = []
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

    func contentsOfDirectory(atPath path: String) async -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    func removeItem(at url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// The seam that cannot make the directory — the loud-failure half.
struct UncreatableDirectoryActionAuditFileSystem: ActionAuditFileSystem {
    struct Refused: Error {}

    func createDirectory(at url: URL) async throws { throw Refused() }
    func write(_ data: Data, to url: URL) async throws { throw Refused() }
    func moveItem(at source: URL, to destination: URL) async throws { throw Refused() }
    func read(_ url: URL) async -> Data? { nil }
    func contentsOfDirectory(atPath path: String) async -> [String]? { nil }
    func removeItem(at url: URL) async throws { throw Refused() }
}
