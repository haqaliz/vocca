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

import CoreML
import FluidAudio
import Foundation
import Synchronization
import VoccaCore

/// The Silero VAD adapter's SDK-side knobs, carried as plain data (S1's other half).
///
/// These are the values FluidAudio's own plain-data configs take: `speechThreshold` is
/// ``VadConfig/defaultThreshold`` (the onset threshold), `negativeThresholdOffset` and
/// `speechPadding` are ``VadSegmentationConfig``'s. The defaults are the SDK's own and are pinned
/// against it by `SileroVADAdapterTests`, so a drift on either side fails rather than silently
/// retunes the detector.
public struct SileroVADConfiguration: Sendable, Hashable {
    /// The model-probability onset threshold — FluidAudio's `VadConfig.defaultThreshold` (0.85).
    public var speechThreshold: Float

    /// How far below the onset threshold the offset threshold sits — FluidAudio's
    /// `VadSegmentationConfig.negativeThresholdOffset` (0.15). The hysteresis pair.
    public var negativeThresholdOffset: Float

    /// Seconds of padding the SDK's state machine puts around a speech segment (0.1).
    public var speechPadding: Double

    public init(
        speechThreshold: Float = 0.85,
        negativeThresholdOffset: Float = 0.15,
        speechPadding: Double = 0.1
    ) {
        self.speechThreshold = speechThreshold
        self.negativeThresholdOffset = negativeThresholdOffset
        self.speechPadding = speechPadding
    }
}

/// The seam/SDK boundary mapping, as pure data — the only part of the adapter headless CI can
/// execute besides `chunked`.
///
/// `minSpeechDuration`/`minSilenceDuration` come from the seam's ``VADConfiguration`` hold times;
/// `speechThreshold`/`negativeThresholdOffset`/`speechPadding` from ``SileroVADConfiguration``.
/// The adapter builds the SDK's `VadConfig`/`VadSegmentationConfig` from this at the boundary,
/// with the SDK's remaining fields left at their own defaults.
public struct SileroVADDerivedConfig: Sendable, Hashable {
    public let speechThreshold: Float
    public let negativeThresholdOffset: Float
    public let speechPadding: Double
    public let minSpeechDuration: Double
    public let minSilenceDuration: Double
}

/// The ``VoiceActivityDetector`` seam's real implementation: Silero VAD through FluidAudio's
/// `VadManager`, in the one module permitted to name the SDK (H8b, `ParakeetSeamTests` — this
/// file is the family's second permitted entry).
///
/// ## What this file is, and is not
///
/// It is the adapter — thin glue, in the `ParakeetEngine` shape: **CI never executes a model
/// line of it** (no CoreML model reaches a hosted runner), and that is acceptable because
/// everything this file *decides* lives in its pure half — ``derivedConfig(from:sdk:)`` and
/// ``chunked(_:frame:chunkSize:)`` — where `SileroVADAdapterTests` reaches it. What remains
/// here is translation only: accumulate frames to the SDK's chunk boundary, map the seam's
/// config onto the SDK's, bridge the seam's synchronous `classify` onto the SDK actor, and map
/// the SDK's hysteresis events onto ``SpeechActivity``.
///
/// ## The conversion is identity — there is none
///
/// ``AudioBuffer/samples`` is already `[Float]` **16 kHz mono** (`AudioBuffer.swift:36-88`,
/// asserted at its init) and `VadManager.processStreamingChunk` takes `[Float]` at
/// `VadManager.sampleRate` (16000) — so the adapter hands the seam's samples through
/// sample-for-sample (`chunked` pins it). No resampler, no `VoccaAudio` (which this module may
/// not import), no format conversion anywhere on this path.
///
/// ## The decision granularity is the model's 256 ms chunk
///
/// The SDK processes 4096 new samples per call (256 ms @ 16 kHz, plus its 64-sample context —
/// `VadManager.swift:22-26`). The adapter accumulates frames until a 4096-sample chunk
/// completes and answers from the current state in between: a sub-chunk frame carries no model
/// evidence yet, so it returns the current ``SpeechActivity`` without touching the model. The
/// loop's barge-in path runs on the continuous capture stream, where chunks complete every
/// 256 ms; the seam's per-frame vocabulary is served at that granularity (recorded).
///
/// ## The hysteresis mapping, honestly
///
/// The seam's `onsetRMS`/`offsetRMS` are **energy-domain evidence levels with no Silero
/// analogue** — the model's probability thresholds (`speechThreshold` /
/// `negativeThresholdOffset`, the SDK's own hysteresis pair) are the real levels. The SDK's
/// streaming state machine flips onset on the first above-threshold chunk (no min-speech hold
/// in that path), so the real adapter's onset is **SDK-timed**; the adapter deliberately does
/// not re-implement the seam's hold on top of the SDK's state machine (double state machines
/// would drift, and a hold would delay the barge-in-critical onset). `minimumSpeech` rides into
/// the SDK's `minSpeechDuration` — the segmentation surface's field — and `minimumSilence` into
/// `minSilenceDuration`, which the streaming path does honour.
///
/// ## The sync→actor bridge, and its cost
///
/// The seam is synchronous by contract (a per-frame decision cannot afford an actor hop) and
/// the SDK is an actor, so `classify` bridges: a `Task` runs
/// `manager.processStreamingChunk(...)` and signals a `DispatchSemaphore` the caller waits on,
/// with the result crossing the boundary in a `Mutex` box written once and read once after the
/// signal (the `SpeechDriveBox` discipline, with the house's `Mutex`). **The cost is recorded
/// honestly: `classify` blocks its caller for the model's per-chunk processing** — the
/// env-gated suite measures it as `VAD-CLASSIFY-LATENCY` (recorded, never gated), and the
/// 200 ms budget decomposition is the barge-in-loop aspect's.
///
/// ## The offline guarantee, and the pure init
///
/// ``ModelHub/offlineMode`` is set to `true` at construction (the `ParakeetEngine` precedent)
/// and re-asserted before any load, so the SDK's own download machinery would throw
/// `DownloadError.networkDisabled` rather than egress — and the adapter only ever takes the
/// **pre-loaded init** `VadManager(config:vadModel:)` with an `MLModel` read from the injected
/// local directory (`MLModel.load(contentsOf:)` — a local file read; no URL is ever handed to
/// any SDK surface, and the ModelHub download inits are never reachable from here). The load is
/// **lazy** — `init` stores plain data and touches nothing (no model bytes, no directory reads,
/// no network), which is what makes the probe's construct leg possible — and a failed load is
/// **memoized**: the same clear error fails every subsequent chunk-completing classify, never a
/// retry, never a download.
///
/// ## Recorded risk note (F1)
///
/// The SDK's own doc comment says, verbatim: "**Beta Status**: This VAD implementation is
/// currently in beta. While it performs well in testing environments, it has not been
/// extensively tested in production environments. Use with caution in production
/// applications." — recorded as an adapter risk note, not a blocker.
///
/// ## Why `@unchecked Sendable`
///
/// The seam is `Sendable` and the adapter carries mutable state (the accumulator, the SDK's
/// streaming state, the lazily constructed manager, the memoized failure), so the class is the
/// boundary that declares the conformance — the `KokoroEngine`/`SystemSynthesizer` warrant
/// shape: **every byte of mutable state lives under one `Mutex`**, the manager never leaves
/// this class, and the `Task`'s result box is a `Mutex` of its own (no `@unchecked` box).
///
/// ## The CoreML import, confined
///
/// This file imports `CoreML` for exactly two names — `MLModel` and `MLModelConfiguration` —
/// and the H8b family lint confines both to this file along with the VAD/EOU SDK names, so the
/// import cannot quietly spread.
public final class SileroVAD: VoiceActivityDetector, @unchecked Sendable {

    /// The seam's hysteresis, carried verbatim.
    public let configuration: VADConfiguration

    /// The staged model directory — plain data, injected from the composition root. The adapter
    /// never resolves a store path, never touches the C2 store, and never downloads.
    private let modelDirectory: URL

    /// The SDK-side knobs — plain data, the N1-style tuning surface.
    private let sdkConfiguration: SileroVADConfiguration

    /// All mutable state, under one lock.
    private let lock = Mutex<SileroVADState>(SileroVADState())

    /// Stores plain data and touches nothing — the model load is lazy (see the type's doc
    /// comment). The one global write is the offline pin, which reaches no model and no network.
    public init(
        configuration: VADConfiguration,
        modelDirectory: URL,
        sdkConfiguration: SileroVADConfiguration = .init()
    ) {
        self.configuration = configuration
        self.modelDirectory = modelDirectory
        self.sdkConfiguration = sdkConfiguration
        ModelHub.offlineMode = true
    }

    /// The recorded, clear failure of the last load attempt — `nil` until a load attempt failed.
    ///
    /// Memoized: once set it never changes and no retry happens (the `KokoroEngine` memoized
    /// failure precedent). A retry policy is the composition root's concern, recorded.
    public var loadFailureDescription: String? {
        lock.withLock { $0.loadFailure }
    }

    /// Classifies one frame: the frame's samples are accumulated to the SDK's 4096-sample
    /// boundary and the state is advanced by every completed chunk.
    ///
    /// - An empty frame carries no evidence and returns the current state — no model touch.
    /// - A frame that cannot complete a 4096-sample chunk returns the current state — no model
    ///   touch (the real decision granularity is the model's 256 ms chunk).
    /// - The first chunk-completing call attempts the lazy load; a failure is recorded (see
    ///   ``loadFailureDescription``) and answered with `.silence`, memoized.
    public func classify(_ frame: AudioBuffer) -> SpeechActivity {
        if frame.samples.isEmpty {
            return lock.withLock { $0.currentActivity }
        }

        let (chunks, remainder) = Self.chunked(lock.withLock { $0.accumulator }, frame: frame)
        lock.withLock { $0.accumulator = remainder }
        guard !chunks.isEmpty else {
            return lock.withLock { $0.currentActivity }
        }

        for chunk in chunks {
            process(chunk)
        }
        return lock.withLock { $0.currentActivity }
    }

    // MARK: - The pure half

    /// Maps the seam's config onto the SDK's, field for field.
    ///
    /// The seam's hold times ride into the SDK's duration fields; the SDK's threshold/padding
    /// values ride into their own fields. `onsetRMS`/`offsetRMS` have no Silero analogue and are
    /// deliberately not mapped (the type's doc comment carries the recorded nuance).
    public static func derivedConfig(
        from configuration: VADConfiguration, sdk: SileroVADConfiguration
    ) -> SileroVADDerivedConfig {
        SileroVADDerivedConfig(
            speechThreshold: sdk.speechThreshold,
            negativeThresholdOffset: sdk.negativeThresholdOffset,
            speechPadding: sdk.speechPadding,
            minSpeechDuration: configuration.minimumSpeech,
            minSilenceDuration: configuration.minimumSilence)
    }

    /// Appends `frame`'s samples to `accumulator` and extracts every complete `chunkSize`-sample
    /// chunk, returning the remainder for the next frame.
    ///
    /// This is the identity conversion made testable: the chunks are the frames' samples
    /// concatenated **sample-for-sample** — no resampling, no reordering — and the boundary is
    /// the SDK's own `VadManager.chunkSize` (4096 samples, 256 ms @ 16 kHz).
    public static func chunked(
        _ accumulator: [Float], frame: AudioBuffer, chunkSize: Int = 4096
    ) -> (chunks: [[Float]], remainder: [Float]) {
        var pending = accumulator
        pending.append(contentsOf: frame.samples)
        guard pending.count >= chunkSize else { return ([], pending) }

        var chunks: [[Float]] = []
        var index = 0
        while pending.count - index >= chunkSize {
            chunks.append(Array(pending[index..<(index + chunkSize)]))
            index += chunkSize
        }
        return (chunks, Array(pending[index...]))
    }

    // MARK: - The SDK bridge

    /// Runs one completed chunk through the SDK actor and advances the state.
    ///
    /// A memoized failure short-circuits: no retry, no download — the same recorded error fails
    /// every subsequent chunk.
    private func process(_ chunk: [Float]) {
        if lock.withLock({ $0.loadFailure }) != nil { return }

        let streamState = lock.withLock { $0.streamState }
        let segmentation = Self.segmentationConfig(
            from: Self.derivedConfig(from: configuration, sdk: sdkConfiguration))

        // The sync→actor bridge: the seam is synchronous, the SDK is an actor. The result box is
        // written once by the Task and read once after the signal — the `SpeechDriveBox`
        // discipline with the house's `Mutex`.
        let semaphore = DispatchSemaphore(value: 0)
        let box = Mutex<ChunkOutcome?>(nil)
        Task {
            let outcome: ChunkOutcome
            do {
                let manager = try await self.manager()
                let result = try await manager.processStreamingChunk(
                    chunk, state: streamState ?? .initial(), config: segmentation)
                outcome = .result(result)
            } catch {
                outcome = .failure(Self.describe(error))
            }
            box.withLock { $0 = outcome }
            semaphore.signal()
        }
        semaphore.wait()

        guard let outcome = box.withLock({ $0 }) else { return }
        switch outcome {
        case .result(let result):
            lock.withLock { state in
                state.streamState = result.state
                if let event = result.event {
                    switch event.kind {
                    case .speechStart:
                        state.currentActivity = .speech
                    case .speechEnd:
                        state.currentActivity = .silence
                    }
                }
            }
        case .failure(let description):
            lock.withLock { state in
                if state.loadFailure == nil {
                    state.loadFailure = description
                }
                state.currentActivity = .silence
            }
        }
    }

    /// The lazily constructed SDK manager, memoized along with any failure.
    ///
    /// Only the pre-loaded init is reachable: the model is read from the injected directory with
    /// a local `MLModel.load(contentsOf:)`, and the manager is built with
    /// `VadManager(config:vadModel:)`. `ModelHub.offlineMode` is re-asserted before the load so
    /// even a hypothetical miss would throw `networkDisabled` rather than egress.
    private func manager() async throws -> VadManager {
        if let manager = lock.withLock({ $0.manager }) { return manager }

        ModelHub.offlineMode = true
        let modelURL = modelDirectory.appendingPathComponent(ModelNames.VAD.sileroVadFile)
        do {
            let model = try await MLModel.load(
                contentsOf: modelURL, configuration: MLModelConfiguration())
            let manager = VadManager(
                config: VadConfig(defaultThreshold: sdkConfiguration.speechThreshold),
                vadModel: model)
            lock.withLock { state in
                if state.manager == nil {
                    state.manager = manager
                }
            }
            return manager
        } catch {
            throw SileroVADLoadError.modelUnavailable(
                modelPath: modelURL.path, underlying: String(describing: error))
        }
    }

    /// The SDK's segmentation config built from the derived mapping — the remaining fields at
    /// the SDK's own defaults.
    private static func segmentationConfig(
        from derived: SileroVADDerivedConfig
    ) -> VadSegmentationConfig {
        VadSegmentationConfig(
            minSpeechDuration: derived.minSpeechDuration,
            minSilenceDuration: derived.minSilenceDuration,
            speechPadding: derived.speechPadding,
            negativeThresholdOffset: derived.negativeThresholdOffset)
    }

    /// Renders an error for the recorded surface: the adapter's own load error as written,
    /// anything else as thrown.
    private static func describe(_ error: Error) -> String {
        if let loadError = error as? SileroVADLoadError { return loadError.description }
        return String(describing: error)
    }

    /// The bridge's result, crossing from the Task to the blocked caller.
    private enum ChunkOutcome: Sendable {
        case result(VadStreamResult)
        case failure(String)
    }
}

/// Why the Silero VAD model could not be loaded — the clear, recorded error surface.
///
/// The description names the expected model path so the failure is diagnosable without a
/// debugger, and states the offline posture so nobody reads it as a missing download.
public enum SileroVADLoadError: Error, CustomStringConvertible {
    /// The staged model could not be loaded from `modelPath`; `underlying` is the SDK/CoreML
    /// error as thrown. The adapter never downloads — a provisioning fix is the remedy.
    case modelUnavailable(modelPath: String, underlying: String)

    public var description: String {
        switch self {
        case .modelUnavailable(let modelPath, let underlying):
            return
                "the Silero VAD model could not be loaded from \(modelPath): \(underlying) — the "
                + "adapter never downloads; provision the model with Scripts/provision-vad-fixtures.sh"
        }
    }
}

/// The adapter's mutable state, guarded by ``SileroVAD/lock``.
///
/// ``accumulator`` is the sub-chunk remainder; ``streamState`` is the SDK's own hysteresis state
/// (nil until the first completed chunk); ``manager`` is the lazily constructed SDK manager;
/// ``currentActivity`` is the seam's last decision (the answer for frames that carry no
/// completed chunk); ``loadFailure`` is the memoized load failure.
private struct SileroVADState {
    var accumulator: [Float] = []
    var streamState: VadStreamState?
    var manager: VadManager?
    var currentActivity: SpeechActivity = .silence
    var loadFailure: String?
}