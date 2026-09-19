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
import VoccaActions
import VoccaCore
import XCTest

/// ``AuditActionProvider`` — the **second real ``ActionProvider``** (`audit-provider`, C13
/// slice 2), and the suite that decides whether guardrail 7 is met or only claimed.
///
/// ## Why these assertions are shaped this way
///
/// Guardrail 7 — *a seam with one implementation is not a seam; it's an assertion* — was recorded
/// **unmet** by `action-safety-spine` (deviation D3): `NullActionProvider` serves no tools, so
/// every acceptance the slice wrote about providers ranged over a thing that does nothing. Two of
/// the tests below were not *expressible* before a real provider existed, and they are the reason
/// this unit exists rather than a different, easier one:
///
/// - **The real-provider refusal.** Slice 1's load-bearing test — a destructive invocation without
///   a confirmation is refused *by attempting the call* — ran against a stub. Here it runs against
///   a provider that would really delete a real directory's contents, and the refusal is asserted
///   on the directory rather than on the decision alone.
/// - **Dry-run leaves the log byte-identical.** "Zero side effects" was previously a call count on
///   a stub. Against a provider whose side effect is files on disk, it can be the bytes themselves.
///
/// Every test drives a **real ``FileSystemActionAuditStore`` over a real temporary directory**.
/// Nothing here is stubbed: the counts are read from the file system and the clear removes files.
/// A version of this suite that faked either would leave D3 standing while reporting it closed.
///
/// ## The ordering this suite pins (the interesting part)
///
/// Clearing the audit log is itself an auditable action, so the order of "clear" and "record the
/// clear" decides whether the log is tamper-evident:
///
/// - Record **before** clearing → the clear erases its own trace. The log reads empty and looks
///   untouched.
/// - Record **after** clearing → the log reads "cleared", surviving as ordinal 1.
///
/// The second is correct, and
/// ``testClearingTheLogLeavesExactlyOneEntryTheRecordOfItsOwnClearing`` asserts it end to end —
/// including the counterfactual, because the property is only convincing if the wrong order is
/// shown to be wrong on the same real store.
///
/// Note the layering: the **provider** clears, and the gate's **caller** writes the entry. The
/// natural order is therefore the correct one — which is exactly why it is asserted rather than
/// trusted, since nothing in the types enforces it.
final class AuditActionProviderTests: XCTestCase {

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-audit-provider-\(UUID().uuidString)")
    }

    private func makeInvocation(
        toolID: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(providerID: AuditActionProvider.providerID, toolID: toolID),
            "a non-empty provider id and tool id must construct an invocation", file: file,
            line: line)
    }

    /// Writes `count` real entries into `store`, through the store's own writing path.
    ///
    /// Seeded as refusals because a refusal is a real event the log exists to hold and needs no
    /// provider to produce — the point of the seed is that the files exist, not what they say.
    @discardableResult
    private func seed(_ count: Int, into store: FileSystemActionAuditStore) async throws
        -> [ActionAuditEntry]
    {
        let seeded = try XCTUnwrap(
            ActionInvocation(providerID: "dev.vocca.seed", toolID: "seed"),
            "the seed invocation must construct")
        var entries: [ActionAuditEntry] = []
        for index in 1...max(1, count) where count > 0 {
            entries.append(
                try await store.record(
                    seeded, decision: .declined(.toolNotEnabled),
                    at: .seconds(index)))
        }
        return entries
    }

    /// Every committed file in `directory`, name to bytes.
    ///
    /// Read with `FileManager` rather than through the store, because the claim
    /// ``testADryRunOfTheClearLeavesTheLogByteIdentical`` makes is about the directory and not
    /// about a reader's opinion of it.
    private func committedBytes(in directory: URL) throws -> [String: Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var bytes: [String: Data] = [:]
        for name in names.sorted() {
            bytes[name] = try Data(
                contentsOf: directory.appendingPathComponent(name))
        }
        return bytes
    }

    // MARK: - 1. The tool list

    /// Exactly two tools, each at the radius it declares — swept over the advertised list so that
    /// a third tool added later fails **here** first, before it can reach a user.
    ///
    /// The radius is asserted through ``ActionProvider/describe(_:)`` rather than read from a
    /// table, because the radius the gate branches on is the one `describe` returns; a table that
    /// agreed with a different `describe` would prove nothing about what the gate does.
    func testItExposesExactlyTheTwoAuditToolsWithTheirDeclaredBlastRadii() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = AuditActionProvider(store: FileSystemActionAuditStore(directory: directory))

        XCTAssertEqual(
            provider.toolIDs, ["audit.count", "audit.clear"],
            "the provider serves exactly the read and the destructive tool, in that order")

        let expected: [String: BlastRadius] = [
            "audit.count": .readOnly,
            "audit.clear": .destructive,
        ]
        XCTAssertEqual(
            Set(provider.toolIDs), Set(expected.keys),
            "every advertised tool must have a declared radius — a tool added to the list without "
                + "a row here is a tool nobody classified")

        for toolID in provider.toolIDs {
            let summary = await provider.describe(try makeInvocation(toolID: toolID))
            XCTAssertEqual(
                summary.blastRadius, expected[toolID],
                "\(toolID) must describe itself at its declared radius")
            XCTAssertFalse(
                summary.sentence.isEmpty,
                "\(toolID) must render a sentence — an empty one is a provider defect")
        }

        XCTAssertTrue(
            BlastRadius.destructive.requiresConfirmation,
            "the suite's premise: the clear tool is on the side of the one branch point that "
                + "requires a human yes")
        XCTAssertFalse(
            BlastRadius.readOnly.requiresConfirmation,
            "and the count tool is on the side that does not")
    }

    // MARK: - 2. A real read of a real directory

    /// ``audit.count`` reports the **real** number of entries on disk, and follows it when it
    /// changes.
    ///
    /// Asserted twice over one store, because a provider that returned a constant would satisfy a
    /// single-count check. The domain is non-empty by construction — three files really exist
    /// before the first read.
    func testTheCountToolReportsTheRealNumberOfEntriesInTheLog() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemActionAuditStore(directory: directory)
        let provider = AuditActionProvider(store: store)
        let count = try makeInvocation(toolID: "audit.count")

        try await seed(3, into: store)
        let seeded = await store.list().count
        XCTAssertEqual(seeded, 3, "the seed must really have written three entries")
        var summary = await provider.describe(count)
        XCTAssertTrue(
            summary.sentence.contains("3"),
            "the count must be the directory's, not a constant: \(summary.sentence)")

        try await seed(2, into: store)
        summary = await provider.describe(count)
        XCTAssertTrue(
            summary.sentence.contains("5"),
            "the count must follow the directory — two more entries, two more counted: "
                + "\(summary.sentence)")
        XCTAssertFalse(
            summary.sentence.contains("3 "),
            "the earlier count must not survive into the later sentence")
    }

    // MARK: - 3. Concrete, which is why `describe` is async

    /// The summaries are **concrete**: they name the number.
    ///
    /// This is the requirement that forced ``ActionProvider/describe(_:)`` to become `async`
    /// (`async-seam`, the card's scope change). A synchronous `describe` could not read the
    /// directory, so it could only have said "clear the audit log" — the vague copy C13 names as
    /// the specific failure to avoid. The assertion is exact-string, so vagueness is a test
    /// failure rather than a judgement call.
    func testTheCountAndClearSummariesAreConcreteAndNameTheNumber() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemActionAuditStore(directory: directory)
        let provider = AuditActionProvider(store: store)

        try await seed(12, into: store)
        var counted = await provider.describe(try makeInvocation(toolID: "audit.count"))
        var clearing = await provider.describe(try makeInvocation(toolID: "audit.clear"))
        XCTAssertEqual(
            counted.sentence, "The action audit log holds 12 entries.",
            "the read tool must name the count it read")
        XCTAssertEqual(
            clearing.sentence,
            "Permanently delete 12 entries from the action audit log. This cannot be undone.",
            "the destructive tool must say how many entries go, and that it is permanent")

        try await store.clear()
        try await seed(1, into: store)
        counted = await provider.describe(try makeInvocation(toolID: "audit.count"))
        clearing = await provider.describe(try makeInvocation(toolID: "audit.clear"))
        XCTAssertEqual(
            counted.sentence, "The action audit log holds 1 entry.",
            "one entry is one entry — a sentence a person reads must not say `1 entries`")
        XCTAssertEqual(
            clearing.sentence,
            "Permanently delete 1 entry from the action audit log. This cannot be undone.",
            "and the same for the destructive sentence")
    }

    // MARK: - 4. The ordering this aspect pins

    /// **After ``audit.clear`` the log is not empty: it holds exactly one entry, the record of its
    /// own clearing.**
    ///
    /// A log that an action can silently empty is not an audit log. The test drives the real
    /// sequence — gate, provider, then the caller's record — and then drives the *wrong* order on
    /// the same real store to show what it would have cost: an entry written before the clear is
    /// deleted by the clear, and the log reads untouched.
    func testClearingTheLogLeavesExactlyOneEntryTheRecordOfItsOwnClearing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemActionAuditStore(directory: directory)
        let provider = AuditActionProvider(store: store)
        let clear = try makeInvocation(toolID: "audit.clear")

        try await seed(3, into: store)
        let decision = await ActionGate.submit(
            clear, to: provider, enablement: ActionEnablement([clear]), policy: .none,
            approval: .granted)

        XCTAssertEqual(
            decision.outcome, ActionOutcome.succeeded,
            "the provider must really have cleared the log")
        let emptied = await store.list()
        XCTAssertEqual(
            emptied, [],
            "the clear must genuinely empty the directory — a provider that reported success "
                + "without removing the files would close guardrail 7 with a lie")

        // The record lands *after* the clear. This is the caller's ordering, not the provider's,
        // which is exactly why it is asserted here rather than assumed from the layering.
        try await store.record(clear, decision: decision, at: .seconds(9))

        let entries = await store.load()
        XCTAssertEqual(
            entries.count, 1,
            "the log must not be empty after a clear: it holds the record of its own clearing")
        let record = try XCTUnwrap(entries.first)
        XCTAssertEqual(record.id, 1, "and it survives as ordinal 1 — the log starts again from it")
        XCTAssertEqual(record.toolID, "audit.clear")
        XCTAssertEqual(record.providerID, AuditActionProvider.providerID)
        XCTAssertEqual(record.decision, .confirmed)
        XCTAssertEqual(record.outcome, .succeeded)
        XCTAssertEqual(
            record.summary, "Permanently delete 3 entries from the action audit log. "
                + "This cannot be undone.",
            "the surviving record says concretely what was destroyed")

        // The counterfactual, on the same real store: record first, then clear.
        let wrongOrder = await ActionGate.submit(
            clear, to: provider, enablement: ActionEnablement([clear]), policy: .none,
            approval: .granted,
            mode: .dryRun)
        try await store.record(clear, decision: wrongOrder, at: .seconds(10))
        let beforeTheWrongOrderedClear = await store.list().count
        XCTAssertEqual(
            beforeTheWrongOrderedClear, 2, "the premise: two entries exist before the clear")
        _ = await ActionGate.submit(
            clear, to: provider, enablement: ActionEnablement([clear]), policy: .none,
            approval: .granted)
        let afterTheWrongOrderedClear = await store.list()
        XCTAssertEqual(
            afterTheWrongOrderedClear, [],
            "recording before the clear erases its own trace — the log reads empty and looks "
                + "untouched, which is the failure the record-after order exists to prevent")
    }

    // MARK: - 5. The real-provider refusal (slice 1's load-bearing test, at last)

    /// ``audit.clear`` through the gate **without** an approval is refused, and the log is
    /// unchanged — asserted on the directory's bytes, not on the decision alone.
    ///
    /// Slice 1 could only run this against a stub whose "side effect" was a counter. Here the
    /// provider would really delete the files, so the refusal is worth something: the call was
    /// attempted and the directory is byte-identical afterwards.
    func testTheClearIsRefusedWithoutAConfirmationAndTheLogIsUnchanged() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemActionAuditStore(directory: directory)
        let provider = AuditActionProvider(store: store)
        let clear = try makeInvocation(toolID: "audit.clear")

        try await seed(4, into: store)
        let before = try committedBytes(in: directory)
        XCTAssertEqual(before.count, 4, "the domain must be non-empty — there is something to lose")

        let decision = await ActionGate.submit(
            clear, to: provider, enablement: ActionEnablement([clear]), policy: .none)

        guard case .confirmationRequired(let summary) = decision else {
            return XCTFail("a destructive tool without an approval must be refused: \(decision)")
        }
        XCTAssertEqual(summary.blastRadius, .destructive)
        XCTAssertFalse(decision.reachedTheProvider, "the acting half must not have been reached")
        XCTAssertNil(decision.outcome, "a refusal has no outcome — nothing was attempted")
        XCTAssertEqual(
            try committedBytes(in: directory), before,
            "the refused clear must leave every entry exactly as it was")
    }

    // MARK: - 6. Dry-run, in bytes

    /// A dry-run of ``audit.clear`` leaves the directory **byte-identical** — the strongest
    /// available form of "zero side effects", and only assertable now that the provider's side
    /// effect is real files.
    func testADryRunOfTheClearLeavesTheLogByteIdentical() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemActionAuditStore(directory: directory)
        let provider = AuditActionProvider(store: store)
        let clear = try makeInvocation(toolID: "audit.clear")

        try await seed(5, into: store)
        let before = try committedBytes(in: directory)
        XCTAssertEqual(before.count, 5, "five real files must exist for the comparison to mean any")

        let decision = await ActionGate.submit(
            clear, to: provider, enablement: ActionEnablement([clear]), policy: .none,
            approval: .granted,
            mode: .dryRun)

        guard case .previewed(let summary) = decision else {
            return XCTFail("a dry-run must stop at the preview, approved or not: \(decision)")
        }
        XCTAssertEqual(
            summary.sentence,
            "Permanently delete 5 entries from the action audit log. This cannot be undone.",
            "the rehearsal still renders the concrete sentence — describing is not acting")
        XCTAssertEqual(
            try committedBytes(in: directory), before,
            "a rehearsed clear must leave the log byte-identical: same names, same bytes")
    }

    // MARK: - 7. The read-only path

    /// ``audit.count`` runs directly: enabled, no approval, no token asked for — and it changes
    /// nothing.
    func testTheReadOnlyCountRunsDirectlyWithNoApprovalAndChangesNothing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemActionAuditStore(directory: directory)
        let provider = AuditActionProvider(store: store)
        let count = try makeInvocation(toolID: "audit.count")

        try await seed(2, into: store)
        let before = try committedBytes(in: directory)

        let decision = await ActionGate.submit(
            count, to: provider, enablement: ActionEnablement([count]), policy: .none)

        guard case .invoked(let summary, let outcome) = decision else {
            return XCTFail("a read-only tool needs no confirmation to run: \(decision)")
        }
        XCTAssertEqual(summary.blastRadius, .readOnly)
        XCTAssertEqual(summary.sentence, "The action audit log holds 2 entries.")
        XCTAssertEqual(outcome, .succeeded, "the read must succeed against a readable directory")
        XCTAssertEqual(
            try committedBytes(in: directory), before,
            "a read-only tool must leave the log byte-identical")
    }

    // MARK: - 8. An unknown tool

    /// An unknown tool id is a **refusal summary and a returned failure** — never a trap, and
    /// never a silent success.
    ///
    /// The radius of the refusal is ``BlastRadius/readOnly`` for the same reason
    /// ``NullActionProvider``'s is: nothing will happen, so there is nothing to confirm.
    func testAnUnknownToolIsRefusedAndReportedAsFailedRatherThanTrapping() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemActionAuditStore(directory: directory)
        let provider = AuditActionProvider(store: store)
        let unknown = try makeInvocation(toolID: "audit.exfiltrate")

        try await seed(3, into: store)
        let before = try committedBytes(in: directory)

        let summary = await provider.describe(unknown)
        XCTAssertEqual(summary.blastRadius, .readOnly, "a refusal reaches nowhere")
        XCTAssertTrue(
            summary.sentence.contains("audit.exfiltrate"),
            "the refusal must name the tool it will not serve: \(summary.sentence)")

        let decision = await ActionGate.submit(
            unknown, to: provider, enablement: ActionEnablement([unknown]), policy: .none)
        XCTAssertEqual(
            decision.outcome, ActionOutcome.failed(reasonKey: "provider.unknownTool"),
            "an unknown tool is a bounded reason key, returned — the audit log records it")
        XCTAssertEqual(
            try committedBytes(in: directory), before,
            "and nothing was touched on the way to refusing")
    }
}
