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
/// injected context once, guard the empty buffer, map the segments, and run the stream loop.
/// Nothing else.
///
/// ## The streaming surface
///
/// ``supportsStreaming`` is `true`: ``stream(_:)`` runs the canonical repeated-`whisper_full`
/// pattern over the seam — every non-empty chunk arrival decodes the whole growing buffer and
/// yields that decode's segments as a partial, and the key-up final is the last decode's
/// segments, equal to a batch transcription of the same audio **by construction** (same params,
/// same audio, same `whisper_full` machinery; the bridge's parity comment is the pin). **Cost
/// honesty:** the partial passes are O(n²) over the utterance and the key-up final pays the full
/// decode — no caller may assume key-up savings. The by-construction claim is verified on real
/// audio at `SMOKE_CHECKLIST.md` step 19, never in CI; the headless rows prove the engine half
/// only. Sub-minimum audio is unmeasured for the stream path too (see the batch comment below):
/// the first decode runs on the first feed chunk, and if whisper refuses rather than pads, the
/// stream throws on its first iteration — recorded, never assumed, until step 19 runs.
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
public actor WhisperCppEngine: ASREngine, EngineRewarmable {

    public nonisolated let identity: EngineIdentity

    /// The seam's streaming flag — `true` since the whisper-streaming aspect: the engine
    /// implements ``stream(_:)`` itself (partials then exactly one final, the final
    /// batch-by-construction), and **no caller branches on this flag** (the seam's batch
    /// default is a batch engine's degradation, not a streaming one's).
    public nonisolated var supportsStreaming: Bool { true }

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
    ///
    /// **Not reset by ``rewarm()``** — `firstAfterLaunch` stays launch-only, so a re-warm can
    /// never pollute the 1.2 launch bound: the first transcribe after a re-warm is warm.
    private var transcribedSinceLoad = false

    /// The in-flight re-warm, while one is running — what a transcription arriving mid-re-warm
    /// awaits (the Q5 ordering pin: the first dictation after idle is deterministically warm).
    /// `nil` when no re-warm is in flight.
    private var rewarmInFlight: Task<Void, Error>?

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

    /// The idle re-warm (`rewarm-after-idle`): makes the model resident again as if freshly
    /// prepared, through the seam's `reprepare` — **swap-on-success**, so a failure anywhere
    /// leaves the previous context fully usable. The readiness gate is never touched: a session
    /// starting mid-re-warm is never refused, and a failed re-warm never closes the gate.
    ///
    /// The body runs as an unstructured task so a transcription arriving mid-re-warm can await
    /// the in-flight re-warm (``rewarmInFlight``) — the Q5 ordering pin, engine half. The task
    /// is awaited by this method itself, so the resolver's single-flight slot covers the whole
    /// re-warm; a transcribe's `try?` on the task swallows the error (already surfaced to this
    /// method's caller), so a failed re-warm never blocks a transcription.
    ///
    /// `transcribedSinceLoad` is deliberately **not** reset — the first transcribe after a
    /// re-warm records `.warmTranscribe`, never a second `.firstAfterLaunch`.
    ///
    /// - Throws: ``VoccaError/modelUnavailable(_:reason:)`` on an unloaded engine (the resolver
    ///   routes the unprepared case; the guard exists so a silent no-op is impossible) or when
    ///   the reload fails.
    public func rewarm() async throws {
        guard loadState.hasLoaded else {
            throw VoccaError.modelUnavailable(
                identity, reason: "the model is not loaded; call prepare() first")
        }
        let task = Task { try await self.performRewarm() }
        rewarmInFlight = task
        defer { rewarmInFlight = nil }
        try await task.value
    }

    /// The re-warm body: download-if-missing (a no-op when the version is present and verified),
    /// then the seam's `reprepare` from the resolved model file URL. A failure records the
    /// attempt and rethrows ``VoccaError/modelUnavailable(_:reason:)`` with the previous
    /// context untouched.
    private func performRewarm() async throws {
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
            try context.reprepare(modelFileURL: modelFileURL)
            loadState.complete()
            await timing.record(.rewarm, elapsed: clock.now - start)
        } catch {
            loadState.fail()
            throw VoccaError.modelUnavailable(
                identity,
                reason: "the whisper model could not be re-warmed: \(error)")
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
        if let rewarmInFlight {
            try? await rewarmInFlight.value
        }
        guard loadState.hasLoaded else {
            throw VoccaError.modelUnavailable(
                identity, reason: "the model is not loaded; call prepare() first")
        }
        // Empty only, deliberately — no sub-minimum guard like `ParakeetEngine`'s.
        //
        // The seam requires a too-short buffer to answer empty rather than throw, and whisper.cpp
        // is understood to satisfy that by padding its input to the 30 s window and returning zero
        // segments (which maps to empty text) rather than refusing, so no threshold applies here.
        //
        // **That is reasoning about the C library, not a measurement**: no whisper model has run
        // on this machine, and `SMOKE_CHECKLIST.md` step 19 is still the engine's first real
        // execution. A guessed threshold would be worse than none — it would answer empty for
        // audio whisper would have transcribed — so if step 19 shows whisper *does* refuse short
        // audio, the fix is its own measured constant here, mirroring Parakeet's.
        //
        // The stream path runs the same policy, and its sub-minimum row is unverified exactly like
        // the batch's: the first decode happens on the first feed chunk (no accumulation
        // threshold, no throttle — decode every chunk), so whisper's short-audio behavior —
        // pad to the 30 s window and return zero segments, or refuse — is unmeasured for the
        // stream too, and a refusal would throw on the first iteration, honestly surfacing as
        // `.reasonOnly(.transcriptionFailed)` rather than hiding. If step 19 shows a refusal,
        // the fix is one measured constant mirroring `ParakeetEngine.isBelowSDKMinimum`,
        // applied to both `transcribe` and `stream`, in exactly one place — never a threshold
        // guessed from reasoning about the C library.
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

    /// Streaming transcription — the seam's partials-then-exactly-one-final shape, in the
    /// ``StreamingStubEngine/stream(_:)`` form (`ASRTestDoubles.swift:172-184`): `nonisolated`
    /// because the seam's requirement is synchronous, with the producer task carrying the
    /// asynchrony, and a consumer that stops early cancels the producer (``onTermination``).
    ///
    /// **Cost honesty** (`whisper-streaming` spec requirement 4): every chunk arrival decodes
    /// the whole growing buffer, so the partial passes are O(n²) over the utterance, and the
    /// key-up final pays the full decode — **no caller may assume key-up savings**. The final
    /// equals a batch transcription of the same audio **by construction** (same params, same
    /// audio, same `whisper_full` machinery — the bridge's parity comment is the pin), a claim
    /// verified on real audio at `SMOKE_CHECKLIST.md` step 19, never in CI.
    public nonisolated func stream(
        _ chunks: AsyncStream<AudioBuffer>
    ) -> AsyncThrowingStream<Transcript, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runStream(chunks, continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// The stream body — actor-isolated, in the batch default's shape (`ASREngine.swift:90-108`)
    /// with the whisper loop: each non-empty chunk arrival appends to the growing buffer and
    /// runs one full decode of it through the seam, yielding the decode's segments as a
    /// partial; the chunk source's end (or cancellation) falls through to exactly one final —
    /// the last decode's segments, batch-equivalent by construction. A decode failure finishes
    /// the stream throwing ``VoccaError/transcriptionFailed(_:underlying:)`` with the cause
    /// intact and nothing yielded after the throw; an empty stream (zero chunks, or only empty
    /// ones) is answered above the context, exactly as the batch empty-buffer policy dictates.
    private func runStream(
        _ chunks: AsyncStream<AudioBuffer>,
        continuation: AsyncThrowingStream<Transcript, Error>.Continuation
    ) async {
        guard loadState.hasLoaded else {
            continuation.finish(throwing: VoccaError.modelUnavailable(
                identity, reason: "the model is not loaded; call prepare() first"))
            return
        }
        var samples: [Float] = []
        var missingSampleCount = 0
        var lastSegments: [WhisperSegment] = []
        var lastDecodeElapsed: Duration?
        for await chunk in chunks {
            guard !Task.isCancelled else { break }
            // No C call for silence — the batch empty-buffer policy (`:173-190`), stream-shaped:
            // an empty chunk adds nothing and is not worth a full decode of the same buffer.
            guard !chunk.samples.isEmpty else { continue }
            samples.append(contentsOf: chunk.samples)
            // The completeness link (I1), accumulated with a cap: a missing count never exceeds
            // the samples it describes.
            missingSampleCount = min(
                missingSampleCount + chunk.missingSampleCount, samples.count)
            let start = clock.now
            do {
                lastSegments = try context.transcribeStreaming(samples: samples)
            } catch {
                continuation.finish(throwing: VoccaError.transcriptionFailed(
                    identity, underlying: error))
                return
            }
            lastDecodeElapsed = clock.now - start
            continuation.yield(WhisperTranscriptMapper.map(
                segments: lastSegments,
                duration: Double(samples.count) / Double(AudioBuffer.interchangeSampleRate),
                missingSampleCount: missingSampleCount,
                isFinal: false))
        }
        // Timing (decision: only the final decode is recorded): the last decode's elapsed under
        // the transcribedSinceLoad split, flipped only on success — a zero-decode stream
        // records nothing and does not consume the one-shot firstAfterLaunch slot.
        if let lastDecodeElapsed {
            if transcribedSinceLoad {
                await timing.record(.warmTranscribe, elapsed: lastDecodeElapsed)
            } else {
                await timing.record(.firstAfterLaunch, elapsed: lastDecodeElapsed)
                transcribedSinceLoad = true
            }
        }
        // Exactly one final: the last decode's segments. Cancellation still yields it — a
        // terminated continuation ignores the yield — and a consumer that ended the stream
        // early is the pipeline's own guard's business, never a throw.
        continuation.yield(WhisperTranscriptMapper.map(
            segments: lastSegments,
            duration: Double(samples.count) / Double(AudioBuffer.interchangeSampleRate),
            missingSampleCount: missingSampleCount,
            isFinal: true))
        continuation.finish()
    }
}
