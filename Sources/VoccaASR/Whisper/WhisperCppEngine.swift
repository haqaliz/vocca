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
import VoccaCore

/// The second real ``ASREngine``: whisper.cpp large-v3-turbo over the one-file C bridge
/// (`WhisperCAPI.swift`, the seam `WhisperSeamTests` pins), loaded from the Vocca-managed model
/// store — the C3 swap half of the "second engine" promise (`CAPABILITY_ROADMAP.md`, I4).
///
/// ## What this file is, and is not
///
/// It is the engine actor — thin orchestration, in the Parakeet adapter's exact shape: **CI never
/// executes a line of its inference**, because the whisper model cannot reach a hosted runner,
/// and that is acceptable because everything this file *decides* lives above it, in
/// ``WhisperTranscriptMapper``, ``WhisperLoadState``, ``WhisperCppParameters`` and
/// ``WhisperCppEngineIdentity`` — all headless, all in `WhisperCoreTests`, and in the engine's own
/// `WhisperEngineTests`, which drive a **stub context** through the same public surface. The
/// decisions here are reduced to: download-if-missing through the store once, prepare the
/// injected context once, guard the empty buffer, map the segments. Nothing else.
///
/// ## The whisper names stop here
///
/// This file is whisper-**name-free** by construction: it talks to the C API through the
/// ``WhisperContext`` seam and never names a `whisper_`/`WHISPER_` identifier or `import whisper`
/// — the two-sided lint in `WhisperSeamTests` would fail the build if it did. The context
/// instance lives in this actor's isolation domain (it is the non-`Sendable` ``MonotonicClock``
/// precedent), and the C API is single-threaded per context (`plan_20260810.md` §6): the actor
/// serialises every call, which is what makes the C pointer safe without a lock.
///
/// ## The seam's contract, honoured
///
/// - **Attribution:** every transcript carries ``WhisperCppEngineIdentity/whisper`` — the mapper
///   sets it, so mis-attribution is structurally impossible (I1).
/// - **Empty buffer:** a valid empty transcript, never an error — kept above the C API, whose
///   answer to empty samples is not something this adapter should rely on (PRD M3).
/// - **Errors:** every prepare-path failure (store, missing file, context creation) surfaces as
///   ``VoccaError/modelUnavailable(_:reason:)`` with the cause in the reason; every transcribe
///   failure as ``VoccaError/transcriptionFailed(_:underlying:)`` with the cause intact.
public actor WhisperCppEngine: ASREngine {

    public nonisolated let identity: EngineIdentity

    public nonisolated var supportsStreaming: Bool { false }

    /// The store that downloads and verifies the model — the only way model bytes enter the
    /// machine, and the engine's only contact with the outside world (`spec.md` criterion 5).
    private let store: ModelStore

    /// The pinned artifact this engine loads: the version directory and the file list.
    private let manifest: ModelManifest

    /// The seam the store downloads through — injected so tests never touch the network.
    private let transport: any ModelTransport

    /// The injected clock: cold-load and warm-transcribe spans are measured against it (C7's
    /// latency ledger, PRD S1) — the same role the Parakeet engine's clock plays.
    private let clock: any MonotonicClock

    /// The local-only latency ledger (PRD S1) — the same `EngineTiming` the Parakeet engine
    /// records into; whisper's `prepare`/`transcribe` mirror its kinds exactly.
    private let timing: EngineTiming

    /// The transcription parameters, translated to the C API by the bridge — injected so the
    /// default (threads, language, tier) is replaceable without touching the C surface.
    private let parameters: WhisperCppParameters

    /// The injected inference context: ``WhisperCAPI`` in production, a stub in every test —
    /// the seam that keeps this actor whisper-name-free and CI-runnable.
    private let context: any WhisperContext

    /// The load-once bookkeeping: `prepare()` runs the load only when this says it may.
    private var loadState = WhisperLoadState()

    /// Whether any transcription has completed since the load — the split between
    /// ``EngineTiming/Kind/firstAfterLaunch`` and ``EngineTiming/Kind/warmTranscribe``, the
    /// Parakeet engine's `transcribedSinceLoad` rule.
    private var transcribedSinceLoad = false

    public init(
        store: ModelStore,
        manifest: ModelManifest,
        transport: any ModelTransport,
        clock: any MonotonicClock,
        timing: EngineTiming = EngineTiming(),
        parameters: WhisperCppParameters = .init(),
        context: any WhisperContext = WhisperCAPI()
    ) {
        self.store = store
        self.manifest = manifest
        self.transport = transport
        self.clock = clock
        self.timing = timing
        self.parameters = parameters
        self.context = context
        self.identity = WhisperCppEngineIdentity.whisper
    }

    /// Loads the model exactly once and keeps it resident — the C2 warm load-once promise,
    /// inherited by the second engine.
    ///
    /// Order: download-if-missing through the store (a no-op when the version is present and
    /// verified), then the injected context's creation from the resolved model file URL
    /// (`<version-dir>/<file>`). A failure anywhere leaves the engine not-loaded
    /// (``WhisperLoadState``) so the next `prepare` retries, and surfaces as
    /// ``VoccaError/modelUnavailable(_:reason:)`` with the underlying cause in the reason.
    public func prepare() async throws {
        guard !loadState.hasLoaded else { return }
        guard let file = manifest.files.first else {
            throw VoccaError.modelUnavailable(
                identity, reason: "the manifest declares no model files to load")
        }
        loadState.beginAttempt()
        let start = clock.now
        do {
            try await store.downloadIfMissing(manifest: manifest, transport: transport)
            let modelFileURL = await store.baseURL(for: manifest.engineID, version: manifest.version)
                .appendingPathComponent(file.name)
            try context.prepare(modelFileURL: modelFileURL)
            loadState.complete()
            await timing.record(.coldLoad, elapsed: clock.now - start)
        } catch {
            loadState.fail()
            throw VoccaError.modelUnavailable(
                identity,
                reason: "the whisper model could not be loaded: \(error)")
        }
    }

    /// Transcribes one buffer of 16 kHz mono audio through the loaded context.
    ///
    /// - An empty buffer is a valid empty transcript, never an error (PRD M3) — answered above
    ///   the context, which is never called for it.
    /// - The completeness count travels with the buffer (``AudioBuffer/missingSampleCount``) and
    ///   is carried onto the transcript — short audio never masquerades as complete (I1).
    /// - Any context failure surfaces as ``VoccaError/transcriptionFailed(_:underlying:)`` with
    ///   the underlying error intact — attributable to this engine, never swallowed.
    public func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        guard loadState.hasLoaded else {
            throw VoccaError.modelUnavailable(
                identity, reason: "the model is not loaded; call prepare() first")
        }
        if buffer.samples.isEmpty {
            return WhisperTranscriptMapper.map(
                segments: [], duration: buffer.audioDuration,
                missingSampleCount: buffer.missingSampleCount)
        }
        let start = clock.now
        do {
            let segments = try context.transcribe(samples: buffer.samples)
            let elapsed = clock.now - start
            if transcribedSinceLoad {
                await timing.record(.warmTranscribe, elapsed: elapsed)
            } else {
                await timing.record(.firstAfterLaunch, elapsed: elapsed)
                transcribedSinceLoad = true
            }
            return WhisperTranscriptMapper.map(
                segments: segments, duration: buffer.audioDuration,
                missingSampleCount: buffer.missingSampleCount)
        } catch {
            throw VoccaError.transcriptionFailed(identity, underlying: error)
        }
    }
}
