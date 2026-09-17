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

import VoccaASR
import VoccaAudio
import VoccaCore
import VoccaHotkey
import VoccaText

extension AppBootstrap {

    /// **The converse composition's no-input-device answer** — the `RefusingAudioSource` twin
    /// for the `ContinuousAudioSource` seam: `start()` throws `.unavailable` (the graph refused
    /// to open), so the driver answers the refusal to its caller and nothing is started, no
    /// notice is owed. The two dictation graphs' tolerance precedent
    /// (`AppBootstrap.swift:277-304`) applied to the third graph.
    final class RefusingContinuousCapture: ContinuousAudioSource {

        public init() {}

        func start() throws -> AsyncStream<AudioBuffer> {
            throw ContinuousAudioSourceError.unavailable
        }

        func stop() {}
    }

    /// **The converse wiring recipe** (C11, R6 — C10's recorded handoff executed: "the
    /// capture-stream driver, the reply generator's slot, the recipe in `VoccaBootstrap`",
    /// `barge-in-loop/plan_20260915.md:877-881`): the third `AudioCaptureGraph` + the
    /// `StreamingCapture` over it (or ``RefusingContinuousCapture`` when the graph refuses —
    /// a hosted CI runner refuses at construction), the fallback-first VAD, the shipped turn
    /// detector, and the ``ConverseLoopDriver`` over the real adapters.
    ///
    /// ## Probe-safe by construction
    ///
    /// Nothing here starts, downloads, or blocks: the graph is constructed (tolerated),
    /// `StreamingCapture` constructs over it, `SileroVAD`/`KokoroEngine` construct pure
    /// (`KokoroEngine` touches the port only on the first non-empty `speak`), and the driver's
    /// recipes are lazy — the ASR resolver is read at the moment an utterance commits, the
    /// cleanup resolver at most once per session (the **converse** half — `resolve(mode:
    /// .conversing)`, per-mode selection landed by `per-mode-cleanup`), the synthesizer at the
    /// first reply. `async`
    /// only for the VAD's store read (`ModelStore` is an actor — presence is an `await`); the
    /// zero-network probe's `configure` call runs this whole recipe and stays green.
    ///
    /// ## The machine's converse slot
    ///
    /// The mode machine's converse start/stop slot (the `mode-machine` aspect's shipped effect
    /// vocabulary — `.started(.conversing)` / `.sessionControl(.conversing)` /
    /// `.stopped(.conversing)`) receives this driver's `start()`/`stop()`: the driver is the
    /// wiring the machine's converse slot receives. The machine's *owner* — the chord/menu
    /// routing that calls `observe` — is the later aspects' composition (converse-hotkey,
    /// widget-converse), recorded hand-off; the shape was verified compatible when this recipe
    /// landed.
    @MainActor
    public static func composeConverseWiring(
        clock: any MonotonicClock & Sendable,
        store: ModelStore,
        resolver: DictationEngineResolver,
        cleanupResolver: CleanupResolver,
        root: DictationLoopRoot
    ) async -> ConverseLoopDriver {
        // The third graph, with the configuration-change callback ending the converse session —
        // a device switch mid-capture is "the loop's trigger" (`StreamingCapture.swift:131-133`).
        // The driver is reached weakly through a box filled after the graph exists, the
        // `rootBox` precedent.
        let rootBox = WeakRootBox()
        rootBox.value = root
        let graph = try? AudioCaptureGraph(
            ringCapacity: AppBootstrap.ringCapacity,
            onConfigurationChange: { [weak rootBox] in
                Task { @MainActor in
                    guard let root = rootBox?.value else { return }
                    await root.converseDriver?.stop()
                }
            })

        // The capture: `StreamingCapture` over the graph when both construct (the schedule pair
        // is the `mainRunLoopFeedSchedule` shape — a fresh timer per capture, retained by the
        // schedule closure), else the honest refusal.
        let schedulePair = Self.mainRunLoopFeedSchedule()
        let capture: any ContinuousAudioSource
        if let graph,
            let streaming = try? StreamingCapture(
                graph: graph,
                schedule: schedulePair.schedule,
                unschedule: schedulePair.unschedule)
        {
            capture = streaming
        } else {
            capture = RefusingContinuousCapture()
        }

        // The VAD: the store's provisioned Silero model when present, else the shipped fallback
        // — the default work (G7). The construction reads the C10 sdk-adapters recipe's shape
        // (`SileroVAD(configuration:modelDirectory:)` — pure; the model load is lazy).
        let configuration = VADConfiguration(
            onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)
        let vad: any VoiceActivityDetector
        if let manifest = try? SileroVadModelManifest.load(),
            await store.isPresent(engineID: manifest.engineID, version: manifest.version)
        {
            vad = SileroVAD(
                configuration: configuration,
                modelDirectory: await store.baseURL(
                    for: manifest.engineID, version: manifest.version))
        } else {
            vad = EnergyVAD(configuration: configuration)
        }

        // The turn detector — the shipped fallback; the `ParakeetEOU` PENDING state is consumed
        // as-is, never re-litigated (O9).
        let turnDetector = SilenceThresholdDetector(
            configuration: SilenceThresholdConfiguration(
                commitAfterPause: 0.5, minimumUtteranceDuration: 0.2))

        let driver = ConverseLoopDriver(
            vad: vad,
            turnDetector: turnDetector,
            clock: clock,
            gate: EchoGate(),
            capture: capture,
            asrProvider: { await resolver.engineIfReady() },
            cleanupProvider: { try await cleanupResolver.resolve(mode: .conversing) },
            replyGenerator: EchoReplyGenerator(),
            synthesizer: { try await AppBootstrap.kokoroSynthesizer(store: store) },
            playback: SystemPlayback(level: .default, clock: clock),
            onStateChange: { state in
                Task { @MainActor in
                    rootBox.value?.converseStateSink?(state)
                }
            },
            failureSink: { failure in
                Task { @MainActor in
                    rootBox.value?.converseFailureSink?(failure)
                }
            })
        return driver
    }

    /// The speculative feed's timer as the ``RepeatingTimer`` seam's two operations — the
    /// `mainRunLoopFeedSchedule` shape (`AppBootstrap.swift:725-733`), file-local because the
    /// original is `private` to `AppBootstrap.swift`.
    private static func mainRunLoopFeedSchedule() -> (
        schedule: (Duration, @escaping () -> Void) -> Void,
        unschedule: () -> Void
    ) {
        let timer = MainRunLoopTimer()
        return (schedule: { timer.start(every: $0, $1) }, unschedule: { timer.stop() })
    }
}

/// The weak root reference the configuration-change callback and the state/failure sinks hop
/// through — the `WeakBox` shape (`AppBootstrap.swift:3251`), file-local because the original
/// is `private`.
private final class WeakRootBox: @unchecked Sendable {
    weak var value: DictationLoopRoot?
}