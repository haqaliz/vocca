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

/// The engine lifecycle for the dictation loop: **one engine for the process**, resolved from
/// the selection at the first preparation, warmed once by a background `prepare()`, and gated —
/// the session refuses honestly (PRD R5's `.modelUnavailable`) whenever ``engineIfReady()``
/// answers `nil`.
///
/// This is the `loop-wiring` Task 2 half of PRD R2 (`prd.md:73-78`): "the selected engine
/// resolves once at launch and `prepare()` runs in the background with the existing download
/// UI". It stays Core-owned by construction — the ``EngineBuilding`` closure is injected, so
/// this type never names `VoccaASR`; the composition root supplies the builder that maps the
/// selection to the shipped engines (Parakeet at C2, whisper.cpp at C3) behind the seam.
///
/// ## The three promises
///
/// - **Resolve-once.** The builder runs at most once for the life of the process, with the
///   selection this resolver was given. A second `prepareIfNeeded()` after success is a no-op;
///   after a *failure* it retries on the **same** engine — resolution is never repeated, only
///   preparation is.
/// - **Single-flight, background preparation.** Concurrent `prepareIfNeeded()` calls share one
///   warm-up: the second awaits the in-flight one instead of starting a second (the ``ModelStore``
///   one-flight guard, `ModelStore.swift:59-62,134-139`). The root fires it from a background
///   task at launch; the caller never blocks on anything but the seam's own async work.
/// - **The readiness gate.** ``engineIfReady()`` answers only the engine whose `prepare()`
///   succeeded, and ``isPrepared`` is `true` only then. A failure surfaces its reason to the
///   caller — the underlying error intact, never stringified — and leaves the gate closed, so a
///   session that starts while the model is still downloading refuses honestly instead of
///   recording into a void.
///
/// ## Why an actor
///
/// The resolver holds mutable state — the resolved engine, the prepared flag, the in-flight
/// task — and `VoccaCore` imports nothing, so there is no lock or semaphore available
/// (`CoreBoundaryTests` keeps `Foundation`, `Dispatch` and `Darwin` out of the module, and the
/// clock lint closes `ContinuousClock`'s own route in). An actor is the module's only
/// concurrency primitive, and it is the honest one: the state is genuinely actor-isolated
/// state, exactly as ``ModelStore``'s is.
public actor DictationEngineResolver {

    /// How an `EngineSelection` becomes a running engine. The closure is the whole of the
    /// `VoccaASR` contact: Core names the seam and the vocabulary, and the composition root
    /// supplies the construction.
    public typealias EngineBuilding =
        @Sendable (EngineSelection) async throws -> any ASREngine

    /// The selection this resolver runs — fixed for its whole life, by design.
    ///
    /// `nonisolated` so a caller in another module can read it without an `await`. It is an
    /// immutable `Sendable` value, so there is nothing to isolate; the annotation is required only
    /// because a cross-module actor `let` is isolated by default. The composition root reads it
    /// synchronously on the main actor to answer "which engine is Vocca using?" — the Settings
    /// label, and the guard that makes a no-op selection change a no-op.
    ///
    /// A *change* of selection is a new resolver, never a write here: resolve-once is the whole
    /// contract above, and a mutable selection would let one process's `isPrepared` describe an
    /// engine it never built.
    public nonisolated let selection: EngineSelection

    /// The builder that maps ``selection`` to a running engine. Called at most once.
    private let building: EngineBuilding

    /// The one engine this process resolved — set the moment the builder answers, kept across a
    /// failed `prepare()` so a retry re-warms the same engine instead of re-resolving.
    private var engine: (any ASREngine)?

    /// Whether the resolved engine's `prepare()` has succeeded. The readiness gate's own flag:
    /// ``engineIfReady()`` keys on this, never on the engine's presence.
    private var prepared = false

    /// The warm-up currently in flight, if any — the one-flight guard. A second call that
    /// arrives while this is set awaits it and returns; it is cleared on success *and* on
    /// failure, so a failed prepare never poisons the next attempt (`ModelStore.swift:59-62`).
    private var inFlightPrepare: Task<Void, Error>?

    /// - Parameters:
    ///   - selection: The engine the process will run — the composition root's picker answer.
    ///   - building: The engine construction, injected so this type never names an engine
    ///     module. Throws when the engine cannot be built (a missing model store, say); the
    ///     throw surfaces through ``prepareIfNeeded()`` and a later call retries.
    public init(selection: EngineSelection, building: @escaping EngineBuilding) {
        self.selection = selection
        self.building = building
    }

    /// Whether the resolved engine's `prepare()` has succeeded. `false` until then — and
    /// forever if the last attempt failed.
    public var isPrepared: Bool { prepared }

    /// The readiness gate: the resolved engine when it is prepared, `nil` otherwise.
    ///
    /// The session start reads this *before* the microphone opens — an unprepared engine
    /// refuses honestly with the `.modelUnavailable` notice (PRD R5) and no audio is ever
    /// captured into a void (`spec.md:29`, "the mic never opens").
    public func engineIfReady() -> (any ASREngine)? {
        prepared ? engine : nil
    }

    /// Resolves the engine (once) and warms it (single-flight), and answers only when it is
    /// ready to transcribe.
    ///
    /// Safe to call from anywhere at any time: concurrent calls share one warm-up, a call after
    /// success is a no-op, and a call after a failure retries `prepare()` on the already
    /// resolved engine — the builder is never asked twice. The failure surfaces to the caller
    /// as a throw, with the underlying error intact.
    ///
    /// ## Cancellation
    ///
    /// The warm-up runs in an unstructured task so that concurrent callers can share it; a
    /// cancelled caller does not reach the in-flight work by inheritance, so the handler bridges
    /// the gap exactly as ``ModelStore``'s does — cancelling the caller cancels the shared
    /// warm-up, which surfaces as `CancellationError` to every caller awaiting it
    /// (`ModelStore.swift:170-178`).
    public func prepareIfNeeded() async throws {
        if prepared {
            return
        }
        if let inFlight = inFlightPrepare {
            try await inFlight.value
            return
        }
        let task = Task {
            try await self.resolveAndPrepare()
        }
        inFlightPrepare = task
        defer { inFlightPrepare = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Build once, prepare once, mark prepared — the whole lifecycle, run under the one-flight
    /// guard.
    private func resolveAndPrepare() async throws {
        let engine: any ASREngine
        if let existing = self.engine {
            // Already resolved — a retry after a failed prepare re-warms the same engine.
            engine = existing
        } else {
            engine = try await building(selection)
            self.engine = engine
        }
        try await engine.prepare()
        prepared = true
    }
}
