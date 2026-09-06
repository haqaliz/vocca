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

/// One session's latency record — the ledger's unit (spec §3): one record per session, from
/// begin to finalize.
///
/// The record exists across the whole session and grows: ``spans`` are appended in call order
/// between begin and finalize, and ``outcome`` and ``engine`` are set at finalize. It records
/// durations and classes only — never audio, never text (plan §5).
///
/// ``engine`` is attribution, non-optional once a transcription was attempted (C2's rule,
/// scoped honestly): non-nil for every route that asked the engine — ``SessionOutcomeClass/lost``
/// included, since a lost transcript is one the engine produced; nil only on the routes that
/// never asked, ``SessionOutcomeClass/aborted`` (Escape before anything was asked) and
/// ``SessionOutcomeClass/emptySkip`` (no audio — the injector was skipped).
///
/// ``kind`` is which composition produced the session — real work or onboarding's setup demo
/// (``SessionKind``). It is set at finalize with the rest, from a value fixed when the injector
/// was chosen; nothing on any route reads it, and no class means anything different because of
/// it. It exists so a reader counting P0's numbers off these records can leave a setup demo out
/// of them without losing sight of it.
public struct SessionRecord: Sendable, Equatable {
    /// The stable opaque handle the ledger mints at ``LatencyRecorder/beginSession()``.
    ///
    /// `Hashable` because the ledger keys its store by it; equality is value equality on the
    /// wrapping ``rawValue``. Monotonic *minting* is the ledger's job (Phase 3) — this type is
    /// just the stable value, stdlib-only, with a public init so the ledger and the harness can
    /// construct one (the ``InjectionResult`` plain-public precedent).
    public struct ID: Sendable, Hashable {
        /// The wrapped value.
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
    }

    /// The session this record describes — the value ``LatencyRecorder/beginSession()`` returned.
    public var id: ID
    /// How the session ended — set at finalize.
    public var outcome: SessionOutcomeClass
    /// The measured spans, in the order they were recorded (spec A2).
    public var spans: [LatencySpan]
    /// Which engine produced the transcript, when one was asked; nil only on the
    /// never-asked paths (`aborted`/`emptySkip`).
    public var engine: EngineIdentity?
    /// Whether this was real work or onboarding's TRY IT — the composition that delivered it.
    public var kind: SessionKind

    /// Plain memberwise and public — the ledger and the harness build records by hand.
    public init(
        id: ID, outcome: SessionOutcomeClass, spans: [LatencySpan], engine: EngineIdentity?,
        kind: SessionKind
    ) {
        self.id = id
        self.outcome = outcome
        self.spans = spans
        self.engine = engine
        self.kind = kind
    }
}
