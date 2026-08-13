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

/// The closed four spans the P0 loop can measure, in pipeline order.
///
/// `CaseIterable` exists so the harness can pin the set in one line (`LatencyVocabularyTests`),
/// the ``InjectionRung`` precedent: a fifth name is a deliberate change that re-tests every
/// consumer of the ledger, not a quiet addition to the vocabulary.
public enum SpanName: Sendable, Equatable, CaseIterable {
    /// The gap between the session's end and the capture graph's `stop()` returning. Closed on
    /// the *caller* of `stop()`, above the realtime callback — never on the realtime thread
    /// (spec "Isolation decisions").
    case captureClose
    /// The engine's transcription window: the audio handed over to the transcript returned.
    case asr
    /// C5's cleanup span. **Vocabulary with a `notPresent` state**: C5 is unbuilt, so the ledger
    /// must never fabricate a duration for a span that never ran (spec A2).
    case cleanup
    /// The ladder's injection window, from `TargetContext` resolution to the result.
    case inject
}

/// One measured slice of a session, as the ledger records it.
///
/// `elapsed` is a `Duration` *delta* handed in by the caller — time enters `VoccaCore` only
/// through the injected ``MonotonicClock``, and this struct never reads one (spec A7). It records
/// durations and classes only, never audio, never text (plan §5).
///
/// The presence state is the anti-fabrication guard: ``LatencySpan/Presence/notPresent`` is a
/// distinct state from a recorded elapsed of zero, so the ledger can represent "this span never
/// ran" without writing a `0` (spec A2). The only sanctioned construction paths are the two
/// factories below — a `0` for a span that never ran can never be written by accident.
public struct LatencySpan: Sendable, Equatable {
    /// Whether the span ran. `notPresent` never carries a duration.
    public enum Presence: Sendable, Equatable {
        /// The span ran, and ``LatencySpan/elapsed`` is a measured reading — including a
        /// legitimate zero, which is still `recorded`.
        case recorded
        /// The span never ran (C5's cleanup today). ``LatencySpan/elapsed`` is never read in
        /// this state.
        case notPresent
    }

    /// Which slice of the session this is.
    public var name: SpanName
    /// Whether the span ran.
    public var presence: Presence
    /// The measured duration, when `presence == .recorded`.
    public var elapsed: Duration

    /// The only way to build a recorded span: the caller states the duration explicitly.
    public static func recorded(name: SpanName, elapsed: Duration) -> LatencySpan {
        LatencySpan(name: name, presence: .recorded, elapsed: elapsed)
    }

    /// The cleanup span before C5: present in the record as `notPresent`, never a fabricated
    /// zero (spec A2).
    public static func cleanupNotPresent() -> LatencySpan {
        LatencySpan(name: .cleanup, presence: .notPresent, elapsed: .zero)
    }
}
