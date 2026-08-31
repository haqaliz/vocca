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

import AVFoundation
import FluidAudio
import Foundation
import VoccaCore

/// The first real ``ASREngine``: Parakeet TDT 0.6B v3 via FluidAudio, loaded from the Vocca-managed
/// model store, in the one file in `Sources/` permitted to name the SDK (H8b, `ParakeetSeamTests`).
///
/// ## What this file is, and is not
///
/// It is the adapter — thin glue, in the tap-adapter's exact shape (`CLAUDE.md`): **CI never
/// executes a line of it**, because the CoreML model cannot reach a hosted runner, and that is
/// acceptable because everything this file *decides* lives above it, in
/// ``ParakeetTranscriptMapper``, ``ParakeetLoadState``, ``EngineTiming`` and
/// ``ParakeetEngineIdentity`` — all headless, all in `ParakeetCoreTests`. The decisions here are
/// reduced to: set the offline flag, call the injected loader once, call the manager, map the
/// result through the mapper. Nothing else.
///
/// ## The offline guarantee
///
/// ``ModelHub/offlineMode`` is set to `true` at construction — before any loader exists — so the
/// SDK's own download machinery throws `DownloadError.networkDisabled` instead of egressing
/// (measured in the F1 spike). Models reach the machine only through ``ModelStore`` and the
/// injected transport; FluidAudio never fetches.
///
/// ## The streaming surface
///
/// ``supportsStreaming`` is `true`: the sliding-window adapter (`SlidingWindowAsrManager`, SDK
/// defaults only — the founder decision) drives ``stream(_:)``. The manager's lifecycle is **one
/// fresh manager per `stream()` call**: the SDK's `finish()` permanently ends its input stream
/// and `reset()` cannot revive it, so a manager serves exactly one session, with the retained
/// ``AsrModels`` re-loaded into each fresh one (the per-session load cost is unmeasured — the
/// env-gated run observes it and the equivalence-measurement aspect records it, never this one).
/// Every decision the stream makes is above this file — the partial/final mapping and the
/// sub-minimum answer are ``ParakeetTranscriptMapper`` and ``isBelowSDKMinimum`` — leaving this
/// file translation only, exactly as the batch half.
///
/// ## The layout
///
/// The spike measured that `AsrModels.load(from: D)` resolves the file home to
/// `<D.parent>/<repo.folderName>/` (`spike_20260809.md` §2), so the load directory is
/// `<version>/<sdkDirectory>` — exactly where the SDK-shaped manifest commits its files
/// (`ModelStore`, `ModelManifest.sdkDirectory`).
public actor ParakeetEngine: ASREngine, EngineRewarmable {

    public nonisolated let identity: EngineIdentity

    /// The seam's streaming flag — `true` since the sliding-window adapter: a streaming engine
    /// implements ``stream(_:)`` itself, and **no caller branches on this flag** (the seam's
    /// batch default is a batch engine's degradation, not a streaming one's).
    public nonisolated var supportsStreaming: Bool { true }

    /// The store that downloads and verifies the model — the only way model bytes enter the
    /// machine (the first named network type, `ARCHITECTURE.md:16`, amended).
    private let store: ModelStore

    /// The pinned artifact this engine loads: the version directory and the SDK layout.
    private let manifest: ModelManifest

    /// The seam the store downloads through — injected so tests never touch the network.
    private let transport: any ModelTransport

    /// The local-only latency ledger (PRD S1).
    private let timing: EngineTiming

    /// The injected clock: cold-load and warm-transcribe spans are measured against it.
    private let clock: any MonotonicClock

    /// The seam between this adapter and the SDK's model loading — injectable so the failure path
    /// (a missing or corrupt model) is testable without a model on disk. The default is the real
    /// `AsrModels.load(from:)` call; a test injects a throwing stand-in.
    private let modelLoader: @Sendable (URL) async throws -> AsrModels

    /// The load-once bookkeeping: `prepare()` runs the load only when this says it may.
    private var loadState = ParakeetLoadState()

    /// The loaded manager — `nil` until `prepare()` completes.
    private var manager: AsrManager?

    /// The loaded models, retained for the streaming sessions: each `stream()` call constructs a
    /// fresh ``SlidingWindowAsrManager`` and re-loads this in-memory value (a finished manager's
    /// input stream cannot be revived), so the models must outlive the batch manager.
    private var models: AsrModels?

    /// The TDT decoder state, threaded through every transcription call.
    private var decoderState: TdtDecoderState?

    /// Whether any transcription has completed since the load — the split between
    /// ``EngineTiming/Kind/firstAfterLaunch`` and ``EngineTiming/Kind/warmTranscribe``.
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
        modelLoader: (@Sendable (URL) async throws -> AsrModels)? = nil
    ) {
        // Before any loader exists: the SDK's download path must be structurally unable to
        // egress (spike finding — the flag is readable and enforced).
        ModelHub.offlineMode = true
        self.store = store
        self.manifest = manifest
        self.transport = transport
        self.clock = clock
        self.timing = timing
        self.identity = ParakeetEngineIdentity.parakeet
        self.modelLoader = modelLoader ?? Self.defaultModelLoader
    }

    /// Whether the SDK's own transcribe guard would refuse this buffer — the decision behind the
    /// empty answer in ``transcribe(_:)``, lifted out so it is reachable by a test.
    ///
    /// `transcribe(_:)` itself is executed by nothing in CI (the adapter needs a real CoreML model
    /// and a real ANE), and the guard sits *after* the not-loaded check, so nothing about it could
    /// be asserted in place. This is the same move the tap adapter made: the decision moves above
    /// the seam and is tested there, leaving translation behind.
    ///
    /// The threshold is the SDK's, read live rather than copied, so the two cannot drift into
    /// disagreement — the failure mode of a copy is answering empty for audio FluidAudio would
    /// happily have transcribed.
    static func isBelowSDKMinimum(_ buffer: VoccaCore.AudioBuffer) -> Bool {
        Self.isBelowSDKMinimum(sampleCount: buffer.samples.count, sampleRate: buffer.sampleRate)
    }

    /// The same decision in sample-count form — the stream's carrier: the adapter accumulates a
    /// **total** sample count across the chunk stream and answers a single empty final below the
    /// minimum regardless of anything the SDK says (the stream form of the seam's empty-buffer
    /// policy). The buffer form delegates here so the batch and stream paths ask one question.
    static func isBelowSDKMinimum(sampleCount: Int, sampleRate: Int) -> Bool {
        sampleCount < Self.minimumRequiredSamples(sampleRate: sampleRate)
    }

    /// **The SDK's minimum, read live** — the one line the composition root may call to build
    /// the speculative feed's sub-minimum predicate (`speculative-feed` phase (e)):
    /// `ASRConstants` is FluidAudio's and the H8b lint keeps that family in this file, so the
    /// composition root names `ParakeetEngine` and never `ASRConstants`. The threshold travels
    /// in the SDK's own units (raw samples at the interchange rate), exactly as
    /// ``isBelowSDKMinimum(_:)`` compares it.
    public static func minimumRequiredSamples(sampleRate: Int) -> Int {
        ASRConstants.minimumRequiredSamples(forSampleRate: sampleRate)
    }

    /// The real loader: manual `AsrModels.load(from:)` from the Vocca-managed directory, with
    /// the SDK's defaults (`.v3`, `.int8`) — never any download API (offline mode forbids it).
    private static let defaultModelLoader: @Sendable (URL) async throws -> AsrModels = { directory in
        try await AsrModels.load(from: directory)
    }

    /// The directory the SDK resolves its file home to: `<version>/<sdkDirectory>`, falling back
    /// to the engine id (which is the SDK's repo folder name for Parakeet) for a flat manifest.
    private func loadDirectory() async -> URL {
        await store.baseURL(for: manifest.engineID, version: manifest.version)
            .appendingPathComponent(manifest.sdkDirectory ?? identity.id, isDirectory: true)
    }

    /// Loads the model exactly once and keeps it resident — the C2 warm load-once promise
    /// (`CAPABILITY_ROADMAP.md:58`, amended: launch preload is C7's).
    ///
    /// Order: download-if-missing through the store (a no-op when the version is present and
    /// verified), then the injected loader, then the manager. A failure anywhere leaves the
    /// engine not-loaded (``ParakeetLoadState``) so the next `prepare` retries, and surfaces as
    /// ``VoccaError/modelUnavailable(_:reason:)`` with the underlying cause in the reason.
    public func prepare() async throws {
        guard !loadState.hasLoaded else { return }
        loadState.beginAttempt()
        let start = clock.now
        do {
            try await store.downloadIfMissing(manifest: manifest, transport: transport)
            let models = try await modelLoader(await loadDirectory())
            self.models = models
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
            self.decoderState = try TdtDecoderState()
            loadState.complete()
            await timing.record(.coldLoad, elapsed: clock.now - start)
        } catch {
            loadState.fail()
            throw VoccaError.modelUnavailable(
                identity,
                reason: "the Parakeet model could not be loaded: \(error)")
        }
    }

    /// The idle re-warm (`rewarm-after-idle`): makes the model resident again as if freshly
    /// prepared, **load-new-then-swap** — the fresh manager and decoder are built and loaded
    /// before the old ones are replaced, so a failure anywhere leaves the previous load fully
    /// usable. The readiness gate is never touched: a session starting mid-re-warm is never
    /// refused, and a failed re-warm never closes the gate.
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
    /// the injected loader, a **fresh** manager and decoder, then the swap. A failure records
    /// the attempt and rethrows ``VoccaError/modelUnavailable(_:reason:)`` with the old
    /// manager/decoder untouched.
    private func performRewarm() async throws {
        loadState.beginAttempt()
        let start = clock.now
        do {
            try await store.downloadIfMissing(manifest: manifest, transport: transport)
            let models = try await modelLoader(await loadDirectory())
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
            self.decoderState = try TdtDecoderState()
            loadState.complete()
            await timing.record(.rewarm, elapsed: clock.now - start)
        } catch {
            loadState.fail()
            throw VoccaError.modelUnavailable(
                identity,
                reason: "the Parakeet model could not be re-warmed: \(error)")
        }
    }

    /// Transcribes one buffer of 16 kHz mono audio through the loaded manager.
    ///
    /// - A buffer the SDK cannot process is a valid empty transcript, never an error (PRD M3) —
    ///   kept above the SDK, whose answer to such a buffer is not something this adapter should
    ///   rely on. That covers the empty buffer *and* the merely-too-short one: FluidAudio's
    ///   transcribe guard throws `ASRError.invalidAudioData` below
    ///   ``ASRConstants/minimumAudioDurationSeconds`` (0.3 s, 4 800 samples at 16 kHz), which
    ///   reached the user as the `.transcriptionFailed` notice — "Voice processing failed" — for
    ///   nothing worse than a quick tap of the hotkey. The seam's own worked example is that case:
    ///   it promises "a 20 ms press captures almost nothing, and silence is a transcript, not an
    ///   error", and a 20 ms press is 320 samples, not zero, so only the sub-minimum guard makes
    ///   that sentence true.
    ///
    ///   The threshold is read from `ASRConstants` rather than written as 0.3 here, so it tracks
    ///   the SDK's own guard instead of drifting from it — the two must agree or this returns
    ///   empty for audio the SDK would have transcribed.
    /// - The completeness count travels with the buffer (``AudioBuffer/missingSampleCount``) and
    ///   is carried onto the transcript — short audio never masquerades as complete (I1).
    /// - Any SDK failure surfaces as ``VoccaError/transcriptionFailed(_:underlying:)`` —
    ///   attributable to this engine, never swallowed.
    public func transcribe(_ buffer: VoccaCore.AudioBuffer) async throws -> Transcript {
        if let rewarmInFlight {
            try? await rewarmInFlight.value
        }
        guard let manager, var decoderState else {
            throw VoccaError.modelUnavailable(
                identity, reason: "the model is not loaded; call prepare() first")
        }
        if Self.isBelowSDKMinimum(buffer) {
            return ParakeetTranscriptMapper.transcript(
                text: "", for: buffer, engine: identity,
                missingSampleCount: buffer.missingSampleCount)
        }
        let start = clock.now
        do {
            let result = try await manager.transcribe(
                buffer.samples, decoderState: &decoderState, language: nil)
            self.decoderState = decoderState
            let elapsed = clock.now - start
            if transcribedSinceLoad {
                await timing.record(.warmTranscribe, elapsed: elapsed)
            } else {
                await timing.record(.firstAfterLaunch, elapsed: elapsed)
                transcribedSinceLoad = true
            }
            return ParakeetTranscriptMapper.transcript(
                text: result.text, for: buffer, engine: identity,
                missingSampleCount: buffer.missingSampleCount)
        } catch {
            throw VoccaError.transcriptionFailed(identity, underlying: error)
        }
    }

    /// Streaming transcription — the seam's partials-then-exactly-one-final shape, in the
    /// ``StreamingStubEngine/stream(_:)`` form (`ASRTestDoubles.swift:172-184`): `nonisolated`
    /// because the seam's requirement is synchronous, with the producer task carrying the
    /// asynchrony, and a consumer that stops early cancels the producer (``onTermination``).
    public nonisolated func stream(
        _ chunks: AsyncStream<VoccaCore.AudioBuffer>
    ) -> AsyncThrowingStream<Transcript, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runStream(chunks, continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// The stream body — actor-isolated, the ``StreamingStubEngine/runStream(_:continuation:)``
    /// shape (`ASRTestDoubles.swift:197-238`), driven by a fresh ``SlidingWindowAsrManager`` per
    /// call: the SDK's `finish()` permanently ends its input stream and `reset()` cannot revive
    /// it, so a manager serves exactly one session, with the retained models re-loaded into it.
    ///
    /// Termination is driven **only by the chunk stream**: the chunk stream's end is the finish
    /// signal (the seam has no caller-side finish call), and the updates stream ending on its own
    /// ends the partials task silently — the adapter cannot hang on a silent SDK. Exactly one
    /// final is yielded, from exactly one place, after the partials task has drained, so a
    /// consumer never sees a partial after the final. The batch timing path is deliberately not
    /// mirrored here: the pipeline owns the ASR span, and real numbers are the
    /// equivalence-measurement aspect's.
    private func runStream(
        _ chunks: AsyncStream<VoccaCore.AudioBuffer>,
        continuation: AsyncThrowingStream<Transcript, Error>.Continuation
    ) async {
        guard let models else {
            continuation.finish(throwing: VoccaError.modelUnavailable(
                identity, reason: "the model is not loaded; call prepare() first"))
            return
        }
        let manager = SlidingWindowAsrManager(config: .default)
        let engineIdentity = identity
        let partialsTask = Task {
            for await update in await manager.transcriptionUpdates {
                guard !Task.isCancelled else { break }
                continuation.yield(ParakeetTranscriptMapper.partial(
                    text: update.text, engine: engineIdentity))
            }
        }
        do {
            try await manager.loadModels(models)
            try await manager.startStreaming()
        } catch {
            partialsTask.cancel()
            continuation.finish(throwing: VoccaError.transcriptionFailed(
                identity, underlying: error))
            return
        }

        var totalSampleCount = 0
        var lastMissing = 0
        for await chunk in chunks {
            guard !Task.isCancelled else {
                partialsTask.cancel()
                continuation.finish(throwing: CancellationError())
                return
            }
            totalSampleCount += chunk.samples.count
            lastMissing = chunk.missingSampleCount
            do {
                let pcm = try Self.pcmBuffer(for: chunk)
                await manager.streamAudio(pcm)
            } catch {
                partialsTask.cancel()
                continuation.finish(throwing: VoccaError.transcriptionFailed(
                    identity, underlying: error))
                return
            }
        }
        guard !Task.isCancelled else {
            partialsTask.cancel()
            continuation.finish(throwing: CancellationError())
            return
        }

        let text: String
        if Self.isBelowSDKMinimum(
            sampleCount: totalSampleCount, sampleRate: AudioBuffer.interchangeSampleRate)
        {
            // The sub-minimum stream answers a single empty final, never a throw — even if the
            // SDK's finish throws under the covers (`try?` + discard): the recognizer task still
            // completes, which is all this call is for.
            _ = try? await manager.finish()
            text = ""
        } else {
            do {
                text = try await manager.finish()
            } catch {
                partialsTask.cancel()
                continuation.finish(throwing: VoccaError.transcriptionFailed(
                    identity, underlying: error))
                return
            }
        }
        // Drain the partials task before the final: cancelling the consumer ends its iteration
        // (an `AsyncStream` iteration ends on its consuming task's cancellation), and awaiting it
        // guarantees every partial that will ever be yielded lands before the final — the seam's
        // partials-then-final ordering, deterministic rather than raced.
        partialsTask.cancel()
        await partialsTask.value
        guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }
        continuation.yield(ParakeetTranscriptMapper.final(
            text: text, forSampleCount: totalSampleCount, engine: identity,
            missingSampleCount: lastMissing))
        continuation.finish()
    }

    /// A 16 kHz mono Float32 `AVAudioPCMBuffer` carrying one seam chunk — the SDK's input shape
    /// (`SlidingWindowAsrManager.streamAudio` accepts any format and converts; seam buffers are
    /// already the interchange format, so this is a copy into the SDK's container, never a
    /// conversion).
    ///
    /// AVFoundation names are permitted in this one file: the H8b discipline confines the SDK's
    /// own names, and the buffer type the SDK's stream API speaks is a system framework type a
    /// streaming adapter cannot translate without.
    private static func pcmBuffer(for chunk: VoccaCore.AudioBuffer) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let capacity = AVAudioFrameCount(max(1, chunk.samples.count))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ParakeetStreamError.pcmBufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        if !chunk.samples.isEmpty, let channel = buffer.floatChannelData?[0] {
            chunk.samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: source.count)
            }
        }
        return buffer
    }
}

/// The stream adapter's own failure vocabulary — the one thing the SDK has no error for (a PCM
/// buffer allocation failing). SDK errors map to ``VoccaError/transcriptionFailed(_:underlying:)``
/// intact; this one is Vocca's, in the same wrapper.
private enum ParakeetStreamError: Error {
    case pcmBufferAllocationFailed
}

/// The default ``MonotonicClock`` implementation for the engine: `ContinuousClock`, the
/// standard library's monotonic clock — the same role `SessionWatchdog`'s injected clock plays,
/// here in the adapter module (Core may not read a clock of its own; the adapter may).
///
/// The origin is captured at construction, so ``now`` is a `Duration` since a process-local
/// origin — the ``MonotonicClock`` contract exactly, with no wall-clock semantics anywhere.
public struct ContinuousMonotonicClock: MonotonicClock, Sendable {
    private let origin = ContinuousClock.now

    public init() {}

    public var now: Duration { ContinuousClock.now - origin }
}
