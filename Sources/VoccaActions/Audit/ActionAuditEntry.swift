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

/// What the log says happened to an action, in the vocabulary the file is written in
/// (`action-safety-spine` PRD §5).
///
/// Four cases, and they are **not** ``ActionDecision``'s four. The gate's enum answers *what the
/// gate did*; this one answers the question a person opens the log to ask — *did a human have to
/// say yes, and did anything run?* ``autoRanReadOnly`` and ``confirmed`` both reached a provider
/// and are kept apart because the difference between them is the whole of the confirmation
/// contract; ``refused`` covers every way the gate stopped an action, whether it was declined
/// before the provider was asked or stopped for want of an approval.
///
/// The raw values **are** the persisted vocabulary. Renaming a case renames it on disk, which is
/// why they are written out here rather than derived: a log whose vocabulary drifts between builds
/// reconstructs nothing.
public enum ActionAuditDecision: String, Sendable, Equatable, CaseIterable {
    /// Read-only, so it ran without anyone being asked. The one case where nothing was confirmed
    /// and something still happened.
    case autoRanReadOnly

    /// It reached far enough to need a human's yes, and had one.
    case confirmed

    /// The gate stopped it: declined before any provider call, or halted for want of an approval.
    /// **Nothing ran** — see ``ActionAuditEntry/outcome``, which is `.notInvoked` in both shapes.
    case refused

    /// A rehearsal. Described only; the acting half of the seam was never reached.
    case dryRun
}

/// One line of the local audit log — the record C13's third acceptance leg reconstructs from
/// (`action-safety-spine` PRD §5, M6).
///
/// ## What it holds, and the one thing it deliberately does not
///
/// The nine fields are the PRD's, exactly: the write ordinal, the monotonic instant as its two
/// `Duration` components, the attribution, the effective blast radius, the decision, the outcome,
/// and the concrete sentence the gate rendered.
///
/// **Raw tool arguments are not persisted.** The rendered sentence is what the user was actually
/// asked about, and it is what reconstructs the decision they faced; raw arguments are unbounded,
/// arbitrary text. The honest cost, stated rather than buried: if you later need to prove exactly
/// which argument value was transmitted, the summary is a *rendering*, not the value. That loss is
/// deliberate, bought for a bounded and human-reviewable file, and it is cheaply reversible — the
/// entry's byte-level pin fails loudly on the day a tenth field is added, which is what the pin is
/// for.
///
/// ## Why the instant is two integers and never a date
///
/// `capturedAt`'s reason, restated: a wall-clock reading lies across an NTP step or a daylight-
/// saving change, so every time value in this tree travels as a monotonic `Duration` since an
/// arbitrary process-local origin. `Duration.components` and
/// `Duration(secondsComponent:attosecondsComponent:)` round-trip without loss, so the pair *is*
/// the instant rather than an approximation of it. The consequence is worth naming: two entries
/// from different runs of the app are not comparable, because their origins differ. Ordering
/// within a run is ``id``'s job, and ordering is what the log needs.
///
/// ## The radius is optional, and the nil is a fact rather than a gap
///
/// A tool declined before any provider call was never described, so nothing classified it. The
/// entry classifies nothing in that case: an invented radius in an audit log is a fabricated fact,
/// and `readOnly` — the plausible-looking default — would be the dangerous one to invent. The
/// field is always written, as `null`, so the file's key set does not vary between entries.
public struct ActionAuditEntry: Codable, Equatable, Sendable {
    /// The write ordinal — monotonically increasing, assigned by the store, the eviction key and
    /// the reason lexicographic file order is numeric order.
    public let id: Int

    /// The monotonic instant the decision was made, as its seconds component. **Never a wall
    /// clock.**
    public let instantSeconds: UInt64

    /// The monotonic instant's attoseconds component.
    public let instantAttoseconds: UInt64

    /// The provider that owned the tool.
    public let providerID: String

    /// The tool within that provider.
    public let toolID: String

    /// The radius the gate **acted on** — the provider's claim after the local policy's
    /// escalation, never the claim itself. `nil` when the action was declined before anything was
    /// described.
    public let blastRadius: BlastRadius?

    /// Whether a human's yes was needed, and whether anything ran.
    public let decision: ActionAuditDecision

    /// What came of it. `.notInvoked` for everything the gate stopped — a refusal recorded as a
    /// failure would read as an action that ran badly, about an action Vocca stopped on purpose.
    public let outcome: ActionOutcome

    /// The concrete sentence the gate rendered, bounded to
    /// ``maximumSummaryUTF8Bytes`` — or, for an action declined before anything was described, the
    /// gate's own bounded decline key. The log still says why, and says it in a vocabulary rather
    /// than in free text.
    public let summary: String

    // MARK: - The bound

    /// The largest summary that reaches the file, in UTF-8 bytes.
    ///
    /// A provider renders the sentence, so its length is not ours to trust, and an unbounded field
    /// is an unbounded file. 1 KB is generous for a sentence a person is expected to read in a
    /// confirmation dialog.
    public static let maximumSummaryUTF8Bytes = 1024

    /// The bound, in **the one place it lives**: every construction path routes through here, the
    /// decoder included, so there is no second rule to keep in step with this one.
    ///
    /// Truncation rather than refusal, because an audit entry dropped for being verbose is the one
    /// failure an audit log must not have. It cuts at whole `Character`s: slicing the byte buffer
    /// at 1024 splits any multi-byte character that straddles the boundary and writes a file that
    /// is not valid UTF-8 at all.
    public static func boundedSummary(_ sentence: String) -> String {
        guard sentence.utf8.count > maximumSummaryUTF8Bytes else { return sentence }
        var bounded = ""
        var bytes = 0
        for character in sentence {
            let size = character.utf8.count
            guard bytes + size <= maximumSummaryUTF8Bytes else { break }
            bounded.append(character)
            bytes += size
        }
        return bounded
    }

    // MARK: - Construction

    /// The entry a gate decision becomes.
    ///
    /// The derivation is the whole of the mapping, and it is here rather than at a call site so
    /// that every recorder makes the same record of the same decision:
    ///
    /// - A **declined** action was never described, so it carries no radius and no sentence — the
    ///   bounded decline key stands in for the sentence nobody rendered.
    /// - **Confirmation required** and **previewed** both carry the sentence that *was* rendered
    ///   and the radius the gate acted on, and neither reached a provider.
    /// - An **invoked** action is ``ActionAuditDecision/confirmed`` or
    ///   ``ActionAuditDecision/autoRanReadOnly`` according to
    ///   ``BlastRadius/requiresConfirmation`` read from the **effective** radius — the same single
    ///   branch point the gate itself used, so the log cannot disagree with the gate about why
    ///   something was allowed to run.
    ///
    /// - Parameters:
    ///   - id: The write ordinal. The store assigns it; nothing else should.
    ///   - instant: A monotonic reading. The module owns no clock — `VoccaCore`'s ban on
    ///     `Foundation.Date` is the reason there is none to own — so the caller supplies it, and
    ///     supplying a wall-clock-derived value is the one way to break the contract this type
    ///     documents.
    ///   - invocation: What was submitted.
    ///   - decision: What the gate decided.
    public init(
        id: Int, instant: Duration, invocation: ActionInvocation, decision: ActionDecision
    ) {
        self.id = id
        let components = instant.components
        self.instantSeconds = UInt64(max(0, components.seconds))
        self.instantAttoseconds = UInt64(max(0, components.attoseconds))
        self.providerID = invocation.providerID
        self.toolID = invocation.toolID

        switch decision {
        case .declined(let reason):
            self.blastRadius = nil
            self.decision = .refused
            self.outcome = .notInvoked
            self.summary = Self.boundedSummary(reason.reasonKey)

        case .confirmationRequired(let summary):
            self.blastRadius = summary.blastRadius
            self.decision = .refused
            self.outcome = .notInvoked
            self.summary = Self.boundedSummary(summary.sentence)

        case .previewed(let summary):
            self.blastRadius = summary.blastRadius
            self.decision = .dryRun
            self.outcome = .notInvoked
            self.summary = Self.boundedSummary(summary.sentence)

        case .invoked(let summary, let outcome):
            self.blastRadius = summary.blastRadius
            self.decision =
                summary.blastRadius.requiresConfirmation ? .confirmed : .autoRanReadOnly
            self.outcome = outcome
            self.summary = Self.boundedSummary(summary.sentence)
        }
    }

    // MARK: - The persisted shape

    private enum CodingKeys: String, CodingKey {
        case id, instantSeconds, instantAttoseconds, providerID, toolID, blastRadius, decision,
            outcome, summary
    }

    /// The persisted vocabulary for ``BlastRadius``.
    ///
    /// Declared here rather than as a conformance on the enum because `VoccaCore` owns the
    /// classification and this module owns the file: a `Codable` conformance in the core would
    /// make every future rename of a case a silent change to a format the core cannot see. The
    /// switches are exhaustive in both directions, so a fourth radius is a compile error here —
    /// where the decision about what it is called on disk belongs.
    private enum PersistedRadius: String {
        case readOnly, destructive, outwardFacing

        init(_ radius: BlastRadius) {
            switch radius {
            case .readOnly: self = .readOnly
            case .destructive: self = .destructive
            case .outwardFacing: self = .outwardFacing
            }
        }

        var radius: BlastRadius {
            switch self {
            case .readOnly: return .readOnly
            case .destructive: return .destructive
            case .outwardFacing: return .outwardFacing
            }
        }
    }

    /// The persisted vocabulary for ``ActionOutcome``, as a nested object.
    ///
    /// An object rather than a composite string (`"failed:provider.diskFull"`) so that the reason
    /// key stays a value a reader can read, and so that the pin can assert the outcome's own key
    /// set as well as the entry's. The field count stays at the PRD's nine either way.
    private enum PersistedOutcomeKind: String {
        case succeeded, failed, notInvoked
    }

    private enum OutcomeKeys: String, CodingKey {
        case kind, reasonKey
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(instantSeconds, forKey: .instantSeconds)
        try container.encode(instantAttoseconds, forKey: .instantAttoseconds)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(toolID, forKey: .toolID)
        if let blastRadius {
            try container.encode(PersistedRadius(blastRadius).rawValue, forKey: .blastRadius)
        } else {
            // Written as an explicit null rather than omitted: the file's key set must not vary
            // between entries, or the byte-level pin's key-set equality would hold only for
            // whichever entry a test happened to encode.
            try container.encodeNil(forKey: .blastRadius)
        }
        try container.encode(decision.rawValue, forKey: .decision)
        try container.encode(summary, forKey: .summary)

        var outcomeContainer = container.nestedContainer(
            keyedBy: OutcomeKeys.self, forKey: .outcome)
        switch outcome {
        case .succeeded:
            try outcomeContainer.encode(PersistedOutcomeKind.succeeded.rawValue, forKey: .kind)
        case .failed(let reasonKey):
            try outcomeContainer.encode(PersistedOutcomeKind.failed.rawValue, forKey: .kind)
            try outcomeContainer.encode(reasonKey, forKey: .reasonKey)
        case .notInvoked:
            try outcomeContainer.encode(PersistedOutcomeKind.notInvoked.rawValue, forKey: .kind)
        }
    }

    /// Decodes an entry, **refusing** one whose vocabulary this build cannot name.
    ///
    /// Schema drift and corruption are the same event to a reader: a radius or a decision that
    /// names no case is not a value to approximate, because an audit entry read wrongly is worse
    /// than one not read at all. The throw lands in the store's skip path with every other
    /// unreadable file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.instantSeconds = try container.decode(UInt64.self, forKey: .instantSeconds)
        self.instantAttoseconds = try container.decode(UInt64.self, forKey: .instantAttoseconds)
        self.providerID = try container.decode(String.self, forKey: .providerID)
        self.toolID = try container.decode(String.self, forKey: .toolID)

        if try container.decodeNil(forKey: .blastRadius) {
            self.blastRadius = nil
        } else {
            let raw = try container.decode(String.self, forKey: .blastRadius)
            guard let persisted = PersistedRadius(rawValue: raw) else {
                throw ActionAuditEntryError.unknownVocabulary(field: "blastRadius", value: raw)
            }
            self.blastRadius = persisted.radius
        }

        let decisionRaw = try container.decode(String.self, forKey: .decision)
        guard let decision = ActionAuditDecision(rawValue: decisionRaw) else {
            throw ActionAuditEntryError.unknownVocabulary(field: "decision", value: decisionRaw)
        }
        self.decision = decision

        // Bounded on the way in as well as on the way out: the file is user-visible and
        // hand-editable, and the bound is a property of what this type holds rather than of what
        // the encoder happened to write. Same one function, so there is no second rule.
        self.summary = Self.boundedSummary(try container.decode(String.self, forKey: .summary))

        let outcomeContainer = try container.nestedContainer(
            keyedBy: OutcomeKeys.self, forKey: .outcome)
        let kindRaw = try outcomeContainer.decode(String.self, forKey: .kind)
        guard let kind = PersistedOutcomeKind(rawValue: kindRaw) else {
            throw ActionAuditEntryError.unknownVocabulary(field: "outcome", value: kindRaw)
        }
        switch kind {
        case .succeeded:
            self.outcome = .succeeded
        case .failed:
            self.outcome = .failed(
                reasonKey: try outcomeContainer.decode(String.self, forKey: .reasonKey))
        case .notInvoked:
            self.outcome = .notInvoked
        }
    }
}

/// What an entry cannot be read as.
///
/// One case: a persisted value naming no case of an enum this build knows. It is an error rather
/// than a tolerated default because the store's tolerance is *skip the file loudly*, not *guess at
/// its meaning*.
public enum ActionAuditEntryError: Error, Equatable {
    /// A persisted field held a value outside its vocabulary — schema drift or corruption.
    case unknownVocabulary(field: String, value: String)
}
