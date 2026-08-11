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
/// ## The layout
///
/// The spike measured that `AsrModels.load(from: D)` resolves the file home to
/// `<D.parent>/<repo.folderName>/` (`spike_20260809.md` §2), so the load directory is
/// `<version>/<sdkDirectory>` — exactly where the SDK-shaped manifest commits its files
/// (`ModelStore`, `ModelManifest.sdkDirectory`).
public actor ParakeetEngine: ASREngine {

    public nonisolated let identity: EngineIdentity

    public nonisolated var supportsStreaming: Bool { false }

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

    /// The TDT decoder state, threaded through every transcription call.
    private var decoderState: TdtDecoderState?

    /// Whether any transcription has completed since the load — the split between
    /// ``EngineTiming/Kind/firstAfterLaunch`` and ``EngineTiming/Kind/warmTranscribe``.
    private var transcribedSinceLoad = false

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

    /// Transcribes one buffer of 16 kHz mono audio through the loaded manager.
    ///
    /// - An empty buffer is a valid empty transcript, never an error (PRD M3) — kept above the
    ///   SDK, whose answer to empty samples is not something this adapter should rely on.
    /// - The completeness count travels with the buffer (``AudioBuffer/missingSampleCount``) and
    ///   is carried onto the transcript — short audio never masquerades as complete (I1).
    /// - Any SDK failure surfaces as ``VoccaError/transcriptionFailed(_:underlying:)`` —
    ///   attributable to this engine, never swallowed.
    public func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        guard let manager, var decoderState else {
            throw VoccaError.modelUnavailable(
                identity, reason: "the model is not loaded; call prepare() first")
        }
        if buffer.samples.isEmpty {
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
