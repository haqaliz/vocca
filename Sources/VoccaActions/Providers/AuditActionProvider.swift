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

import VoccaCore

/// A real ``ActionProvider`` over the local audit log — **the second implementation behind the
/// seam** (`audit-provider`, C13 slice 2).
///
/// | Tool | Blast radius | What it does |
/// |---|---|---|
/// | `audit.count` | read-only | Reports how many entries the log holds |
/// | `audit.clear` | destructive | Removes every entry — irreversible |
///
/// ## Why this provider, of all the ones C13 wants
///
/// Not because it is the most useful. Because it is the one that could be **real** without
/// crossing a boundary: `VoccaActions` declares exactly `["VoccaCore"]` — asserted by *equality*
/// in `VoccaActionsTargetTests` — and `ModuleBoundaryTests` rule 3 forbids an adapter importing
/// any Vocca module other than the core. The audit store already lives in this module, so it is
/// the one genuine capability reachable from here without either a boundary violation or a
/// composition-root wiring slice that does not exist yet. `ShellProvider` was rejected as
/// self-contradictory in a slice whose premise is safety-before-capability, and an MCP provider
/// needs the transport this module is linted against (deviation D2).
///
/// The point of shipping it is `CAPABILITY_ROADMAP.md` guardrail 7 — *a seam with one
/// implementation is not a seam; it's an assertion* — which `action-safety-spine` recorded
/// **unmet** (D3), because ``NullActionProvider`` serves no tools and therefore made every
/// provider-shaped acceptance range over nothing.
///
/// ## Why this is an `actor`, and why that was impossible a unit ago
///
/// ``FileSystemActionAuditStore`` is an actor with `async throws` methods. Under the seam as
/// `action-safety-spine` shipped it — synchronous, non-throwing, on the C12 D1 posture — there
/// was **no conformance to write**: a `nonisolated` synchronous witness cannot await an actor.
/// That is the finding that produced `async-seam`, and this type is the thing it was produced
/// for. Both witnesses here are actor-isolated and `async`; nothing in the seam changed to
/// accommodate them, which is the test the seam had to pass.
///
/// ## ⚠️ `audit.clear` leaves the log holding exactly one entry. That is not a bug.
///
/// **Clearing the audit log is itself an auditable action**, so the order of "clear" and "record
/// the clear" decides whether the log is tamper-evident:
///
/// - Record **before** clearing → the clear erases its own trace. The log reads empty and looks
///   untouched — an action silently emptied the record of itself.
/// - Record **after** clearing → the record of the clear survives, as ordinal 1. The log says what
///   happened to it.
///
/// The second is correct, and the shape of the layering produces it: this provider *clears*, and
/// the gate's caller writes the entry afterwards. A reader who sees "after a clear the log holds
/// one entry" and reaches for a fix would be removing the only evidence that the log was cleared.
/// The property is asserted end to end — with its counterfactual — in `AuditActionProviderTests`,
/// rather than left to the layering to imply.
///
/// ## What it is not
///
/// It names no transport and spawns nothing: the module's prohibition lint is untouched by this
/// file, and the only I/O it performs is the store's own, on one local directory. Nothing here is
/// wired into the composition root — this aspect ships an implementation, not a surface.
public actor AuditActionProvider: ActionProvider {

    /// The identifier a caller names this provider by when building an invocation.
    ///
    /// Exposed as a constant because an invocation is plain data built by the caller: a call site
    /// that spelled the string itself would drift from the one the audit log attributes entries to.
    public static let providerID = "dev.vocca.audit"

    /// The read-only tool: how many entries the log holds.
    public static let countToolID = "audit.count"

    /// The destructive tool: remove them all.
    public static let clearToolID = "audit.clear"

    /// Bounded reason keys — never messages, for the same reason ``ActionOutcome/failed(reasonKey:)``
    /// says: the audit entry is byte-pinned and free-form error text would smuggle unbounded bytes
    /// onto disk.
    static let unknownToolReasonKey = "provider.unknownTool"
    static let clearFailedReasonKey = "audit.clearFailed"

    private let store: FileSystemActionAuditStore

    /// - Parameter store: The log this provider reads and clears. Injected rather than resolved,
    ///   so a test drives a real store over a temporary directory and the shipped composition can
    ///   hand over the same store the gate's caller records into — two stores over one directory
    ///   would be two writers of one ordinal sequence.
    public init(store: FileSystemActionAuditStore) {
        self.store = store
    }

    /// The two tools, in the order a reader should meet them: the harmless one first.
    ///
    /// `nonisolated` because the requirement is synchronous and the answer is a constant — there is
    /// no state here to protect. A third tool added to this list without a row in the test suite's
    /// radius table fails there before it can reach a user.
    public nonisolated var toolIDs: [String] { [Self.countToolID, Self.clearToolID] }

    /// Renders what the tool *would* do, concretely — by reading the log, which is the whole reason
    /// this operation is `async`.
    ///
    /// The count in the sentence is read from the directory at describe time, so a confirmation
    /// says "Permanently delete 12 entries…" rather than "clear the audit log" — the vague copy
    /// C13 names as the specific failure to avoid. The read is a read: nothing here writes, and
    /// a dry-run that stops after this call leaves the directory byte-identical.
    ///
    /// An unserved tool is refused **before the store is touched at all** — the `ContextConsentGate`
    /// never-read shape. There is nothing sensitive in a count, but a provider that reads on the
    /// way to saying "I don't serve that" is a provider whose refusals are not free, and the
    /// cheapest place to keep that property is the day it costs nothing.
    public func describe(_ invocation: ActionInvocation) async -> ActionSummary {
        switch invocation.toolID {
        case Self.countToolID:
            let held = await store.list().count
            return ActionSummary(
                sentence: "The action audit log holds \(held) \(Self.entryNoun(held)).",
                blastRadius: .readOnly)

        case Self.clearToolID:
            let doomed = await store.list().count
            return ActionSummary(
                sentence: "Permanently delete \(doomed) \(Self.entryNoun(doomed)) from the "
                    + "action audit log. This cannot be undone.",
                blastRadius: .destructive)

        default:
            return ActionSummary(
                sentence: "Vocca's audit provider does not serve the tool "
                    + "'\(invocation.toolID)'. Nothing will happen.",
                blastRadius: .readOnly)
        }
    }

    /// Performs the tool. Reachable only with a token the gate alone can mint.
    ///
    /// The clear is the real one: it removes every committed file in the log's directory, and the
    /// record of *this* invocation lands afterwards — see the type documentation for why that order
    /// is the tamper-evident one.
    ///
    /// **The honest limitation on `audit.count`.** The seam has no result channel: an invocation
    /// returns an ``ActionOutcome`` and nothing else, so the number a caller actually consumes is
    /// the one in ``describe(_:)``'s sentence. The read here is real — the directory is listed —
    /// but the outcome is unconditionally successful, because the store answers an unreadable
    /// directory as an *empty log* rather than as a failure (its reader-tolerance policy: one bad
    /// file must never cost the rest of the log). A count that cannot fail is therefore a fact
    /// about the store's reads, recorded here rather than papered over with a failure this code
    /// could not honestly produce.
    ///
    /// An unknown tool is ``ActionOutcome/failed(reasonKey:)`` with a bounded key — never a trap,
    /// and never a silent success. It is a failure rather than ``ActionOutcome/notInvoked``
    /// because the gate reached this provider and this provider could not do what it was asked;
    /// `.notInvoked` is reserved for the case where nothing was attempted at all.
    public func invoke(_ invocation: ActionInvocation, confirmation: ActionConfirmation) async
        -> ActionOutcome
    {
        switch invocation.toolID {
        case Self.countToolID:
            _ = await store.list()
            return .succeeded

        case Self.clearToolID:
            do {
                try await store.clear()
            } catch {
                return .failed(reasonKey: Self.clearFailedReasonKey)
            }
            return .succeeded

        default:
            return .failed(reasonKey: Self.unknownToolReasonKey)
        }
    }

    /// `entry` or `entries` — because a sentence a person is asked to approve must not say
    /// "1 entries".
    private static func entryNoun(_ count: Int) -> String {
        count == 1 ? "entry" : "entries"
    }
}
