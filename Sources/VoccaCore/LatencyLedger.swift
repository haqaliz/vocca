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

/// The bounded, in-memory latency ledger — the only shipped ``LatencyRecorder`` conformance
/// (spec §3, §5).
///
/// One record per session: ``LatencyRecorder/beginSession()`` mints the ``SessionRecord.ID`` and
/// opens the session's span list; spans are appended in call order between begin and finalize;
/// ``LatencyRecorder/finalize(id:outcome:engine:)`` closes the session with its outcome class and
/// engine attribution, and the record enters ``snapshot()``/``describe()``. A session that never
/// finalizes leaves nothing observable: the record's data accumulates from begin, but a
/// ``SessionRecord`` — which carries a concrete ``SessionOutcomeClass`` — is materialised only at
/// finalize, so the ledger can never present an unended session under a class it never got.
///
/// ## Bounded
///
/// ``maximumRetainedRecords`` is the fixed cap: at finalize, the oldest complete record drops
/// first. The ledger is append-only within a run and in-memory by construction — it records
/// durations and classes only, never audio, never text (plan §5).
///
/// ## Time
///
/// The ledger **reads no clock of any kind** (spec "Isolation decisions", A7). Spans arrive
/// already-measured: the caller owns the injected ``MonotonicClock`` and hands in a `Duration`
/// *delta*; recording is a pure append of caller-measured deltas, so the ledger can neither
/// fabricate nor distort a duration. A span that never ran stays ``LatencySpan/Presence/notPresent``
/// — never a fabricated `0`.
///
/// ## Refusals
///
/// Every mutating entry point returns a `Bool`: `false` for a duplicate span name, a write for an
/// unknown id, or a write after finalize (spec A3, plan §6). Refusals fail loudly in a test —
/// `VoccaCore` permits no `@discardableResult`, so an ignored answer is a compiler warning and a
/// CI failure — never a crash, never a silent drop.
public actor LatencyLedger: LatencyRecorder {
    /// The fixed cap on retained complete records: at the cap, the oldest drops first. Pinned by
    /// `LatencyLedgerTests.testBoundedTheOldestDropsTheNewestSurvivesAndTheCapHolds`; changing it
    /// is a deliberate decision that re-tests every consumer.
    public static let maximumRetainedRecords = 512

    /// The next id ``LatencyRecorder/beginSession()`` mints — monotonically increasing actor
    /// state, so mint order is id order and the cap's drop-oldest rule is well-defined.
    private var nextSessionID = 0

    /// The open sessions: the spans recorded so far, keyed by the minted id. A session leaves this
    /// the moment it finalizes.
    private var inFlight: [SessionRecord.ID: Pending] = [:]

    /// The complete records, in finalize order, bounded by ``maximumRetainedRecords``.
    private var records: [SessionRecord] = []

    /// The span list of a session that has begun but not yet finalized. Never observable: it
    /// becomes a ``SessionRecord`` — which needs its concrete outcome class — only at finalize.
    private struct Pending {
        var spans: [LatencySpan] = []
    }

    public init() {}

    public func beginSession() async -> SessionRecord.ID {
        let id = SessionRecord.ID(rawValue: nextSessionID)
        nextSessionID += 1
        inFlight[id] = Pending()
        return id
    }

    public func recordSpan(_ span: LatencySpan, for sessionID: SessionRecord.ID) async -> Bool {
        guard var pending = inFlight[sessionID] else { return false }
        guard !pending.spans.contains(where: { $0.name == span.name }) else { return false }
        pending.spans.append(span)
        inFlight[sessionID] = pending
        return true
    }

    public func finalize(
        id: SessionRecord.ID, outcome: SessionOutcomeClass, engine: EngineIdentity?
    ) async -> Bool {
        guard let pending = inFlight.removeValue(forKey: id) else { return false }
        records.append(SessionRecord(id: id, outcome: outcome, spans: pending.spans, engine: engine))
        if records.count > Self.maximumRetainedRecords {
            records.removeFirst(records.count - Self.maximumRetainedRecords)
        }
        return true
    }

    /// The complete records, oldest first (finalize order, bounded). An in-flight session — begun
    /// but not finalized — is not observable here, because it has no outcome class yet.
    public func snapshot() async -> [SessionRecord] {
        records
    }

    /// A pure, deterministic, `String`-only rendering of every complete record, in mint order.
    ///
    /// Deterministic by construction: records are rendered in ``SessionRecord/ID/rawValue``
    /// order regardless of finalize order, and a session's spans keep the order they were
    /// recorded in. A ``LatencySpan/Presence/notPresent`` span renders as `notPresent` — never a
    /// fabricated duration.
    public func describe() async -> String {
        let ordered = records.sorted { $0.id.rawValue < $1.id.rawValue }
        return ordered.map { record in
            let classLabel: String
            switch record.outcome {
            case .delivered(let rung, let verified):
                classLabel = "delivered(\(rung), \(verified))"
            case .failsafeHeld:
                classLabel = "failsafeHeld"
            case .aborted:
                classLabel = "aborted"
            case .failed:
                classLabel = "failed"
            case .emptySkip:
                classLabel = "emptySkip"
            }
            let spans = record.spans.map { span in
                switch span.presence {
                case .recorded:
                    return "\(span.name) \(span.elapsed)"
                case .notPresent:
                    return "\(span.name) notPresent"
                }
            }.joined(separator: ", ")
            let engineText = record.engine.map { "engine \($0.id)" } ?? "engine none"
            return "session \(record.id.rawValue): \(classLabel), \(spans), \(engineText)"
        }.joined(separator: "\n")
    }
}
