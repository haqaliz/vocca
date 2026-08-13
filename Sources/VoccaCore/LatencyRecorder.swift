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

/// The seam the wiring records latency through — the ledger's three entry points, as a
/// protocol (spec §5).
///
/// The only shipped conformance is the ``LatencyLedger`` actor (Phase 3, in `VoccaCore`); the
/// seam exists so the engines, the injector and the pipeline can record spans from their own
/// contexts without `VoccaCore` importing anything. All three entry points are `async` because
/// the ledger is an actor (spec A8), and the protocol is `Sendable` so it crosses module
/// boundaries. A session is referred to by the ``SessionRecord.ID`` ``beginSession()`` minted —
/// never by a fresh value.
///
/// The two mutating entry points return a `Bool`: `true` when the write was accepted, `false`
/// when it was refused — a duplicate span name, a write for an unknown id, a write after
/// finalize (spec A3, plan §6). Refusals fail loudly in a test, never silently in production;
/// `VoccaCore` permits no `@discardableResult`, so a caller that ignores the answer gets an
/// unused-result warning, which CI turns into a failure.
public protocol LatencyRecorder: Sendable {
    /// Begins a session and mints its ``SessionRecord.ID`` — the handle every later call uses.
    func beginSession() async -> SessionRecord.ID

    /// Records one span for a session, appended in call order. `false` if the session is
    /// unknown or already finalized, or the span name is a duplicate.
    func recordSpan(_ span: LatencySpan, for sessionID: SessionRecord.ID) async -> Bool

    /// Closes a session with its outcome class and engine attribution. `false` if the id is
    /// unknown or already finalized.
    func finalize(id: SessionRecord.ID, outcome: SessionOutcomeClass, engine: EngineIdentity?) async -> Bool
}
