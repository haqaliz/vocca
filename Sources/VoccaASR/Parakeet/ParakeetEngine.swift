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
    static func isBelowSDKMinimum(_ buffer: AudioBuffer) -> Bool {
        buffer.samples.count < Self.minimumRequiredSamples(sampleRate: buffer.sampleRate)
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
    public func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
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
